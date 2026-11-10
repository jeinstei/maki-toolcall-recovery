-- Standalone spec for the detection logic and the slot layer. Runs under Lua
-- 5.1, 5.4, or Luau: it installs a minimal `maki` stub, then requires the
-- module and exercises `closer_at_tail` and the registered `agent.stop` layer.
--
--   lua5.4 tests/spec.lua
--   lua5.1 tests/spec.lua

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local failures = {}

local function case(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(err)
  end
end

local function eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "") .. "\nexpected: " .. tostring(expected) .. "\n  actual: " .. tostring(actual))
  end
end

-- Minimal host stub: the module only needs `maki.api.set_slot` and `maki.log`.
local slots = {}
local debug_lines = {}
maki = {
  api = {
    set_slot = function(name, wrapper)
      slots[name] = wrapper
    end,
  },
  log = {
    warn = function() end,
    info = function() end,
    debug = function(msg)
      debug_lines[#debug_lines + 1] = msg
    end,
  },
}

local M = require("toolcall_recovery")

-- UTF-8 bytes of U+FF5C; portable across Luau, Lua 5.4 and Lua 5.1.
local BAR = "\239\189\156"

-- Positive: recorded stall tails (message ends in a dialect closer).
local DSML = BAR .. "DSML" .. BAR
for _, closer in ipairs({
  "</invoke>",
  "</" .. BAR .. "invoke>",
  "</" .. DSML .. "invoke>",
  "</" .. DSML .. " calls>",
  "</function_calls>",
}) do
  case("tail_" .. closer, function()
    eq(M.closer_at_tail('Let me read the file.\n<parameter name="path">/x</parameter>\n' .. closer), closer)
  end)
end

-- Regression: the stalled turns in this project's own sessions end in the full
-- special token -- `</` + BAR + "DSML" + BAR + keyword. The earlier patterns
-- went straight from the bar to the keyword, so they never matched these.
case("tail_full_dsml_token", function()
  local tail = "d recovered stall in session" .. "</" .. DSML .. "invoke>\n</" .. DSML .. " calls>"
  eq(M.closer_at_tail(tail), "</" .. DSML .. " calls>")
end)

-- Regression: the DSML spelling puts a space after the token, which `%s*` must
-- absorb.
case("tail_dsml_space_keyword", function()
  eq(M.closer_at_tail("check\n</" .. DSML .. " parameter>"), "</" .. DSML .. " parameter>")
end)

case("trailing_whitespace_ok", function()
  eq(M.closer_at_tail("Now let me read it.\n" .. "</invoke>" .. "\n\n"), "</invoke>")
end)

-- Negative: prose that QUOTES markup — a sentence continues after the token.
case("prose_after_closer", function()
  eq(M.closer_at_tail("the raw tool-call markup from issue #1505 follows </invoke> in the report"), nil)
end)

case("marker_mid_sentence", function()
  eq(M.closer_at_tail('use <parameter name="read"></parameter> to read a file, then continue'), nil)
end)

case("no_marker", function()
  eq(M.closer_at_tail("Here is the final answer. Nothing else to do."), nil)
end)

case("empty", function()
  eq(M.closer_at_tail(""), nil)
  eq(M.closer_at_tail(nil), nil)
end)

-- Negated: opener with no closer (truncation or a bare quote) must not fire.
case("opener_without_closer", function()
  eq(M.closer_at_tail('<invoke name="read">'), nil)
end)

-- The slot is registered, and passing a non-stall value through calls prev.
case("slot_registered", function()
  eq(type(slots["agent.stop"]), "function")
end)

-- The dialect module must be a table. Regression: `{ require(x) }` spreads
-- require's multiple return values (Lua 5.2+/Luau), so the dialect entry could
-- become a path string and `dialect.tail_patterns` would index a string.
case("dialect_is_a_table", function()
  local dsml = require("toolcall_recovery.dialects.dsml")
  eq(type(dsml), "table")
  eq(type(dsml.tail_patterns), "table")
end)

local BAR1 = "\239\189\156"
local slot = slots["agent.stop"]

-- A stall fires: returns { continue = ... }, never calls prev.
case("slot_fires_on_stall", function()
  M.reset()
  M.setup({ max_retries = 2 })
  local called_prev = false
  local prev = function()
    called_prev = true
    return { passthrough = true }
  end
  local out = slot(prev, {
    reason = "finished",
    last_message = 'Now let me read it.\n<parameter name="path">/x</parameter>\n</' .. BAR1 .. "parameter>",
  })
  eq(type(out), "table")
  eq(type(out.continue), "string")
  eq(called_prev, false, "a fired slot must not call prev")
end)

-- A non-stall passes through to prev unchanged.
case("slot_passes_through_non_stall", function()
  M.reset()
  M.setup({ max_retries = 2 })
  local seen
  local prev = function(v)
    seen = v
    return { passthrough = true }
  end
  local out = slot(prev, { reason = "finished", last_message = "Here is the answer." })
  eq(out.passthrough, true)
  eq(seen.last_message, "Here is the answer.")
end)

-- `instrument` captures every finished-turn tail, matched or not, as one debug
-- line -- the data a future parser is written against. Off, it logs nothing.
case("instrument_captures_unmatched_tail", function()
  M.reset()
  M.setup({ max_retries = 2, instrument = true })
  debug_lines = {}
  local prev = function()
    return { passthrough = true }
  end
  slot(prev, { reason = "finished", last_message = "no marker here at all\nplain prose" })
  eq(#debug_lines, 1, "instrument on must log one tail line")
  eq(string.find(debug_lines[1], "closer=-", 1, true) ~= nil, true)
end)

case("instrument_off_logs_nothing", function()
  M.reset()
  M.setup({ max_retries = 2, instrument = false })
  debug_lines = {}
  local prev = function()
    return { passthrough = true }
  end
  slot(prev, { reason = "finished", last_message = "plain prose, no closer" })
  eq(#debug_lines, 0, "instrument off must stay silent")
end)

-- A truncated turn is never recovered here.
case("slot_skips_max_tokens", function()
  M.reset()
  M.setup({ max_retries = 2 })
  local called_prev = false
  local prev = function()
    called_prev = true
    return { passthrough = true }
  end
  slot(prev, {
    reason = "max_tokens",
    last_message = 'reading\n<parameter name="path">/x</parameter>\n</' .. BAR1 .. "parameter>",
  })
  eq(called_prev, true)
end)

-- The retry budget is honored, then the slot stops firing.
case("slot_respects_budget", function()
  M.reset()
  M.setup({ max_retries = 2 })
  local prev = function()
    return { passthrough = true }
  end
  -- Consecutive turns are one episode.
  eq(type(slot(prev, { reason = "finished", num_turns = 5, last_message = "x\n</invoke>" }).continue), "string")
  eq(type(slot(prev, { reason = "finished", num_turns = 6, last_message = "x\n</invoke>" }).continue), "string")
  eq(
    slot(prev, { reason = "finished", num_turns = 7, last_message = "x\n</invoke>" }).passthrough,
    true,
    "third stall in the episode must pass through"
  )
end)

-- Regression: a run of consecutive stalls must not pin the budget forever. A
-- stall whose turn is not the one right after the last fire is a new episode.
case("slot_resets_budget_on_new_episode", function()
  M.reset()
  M.setup({ max_retries = 2 })
  local prev = function()
    return { passthrough = true }
  end
  eq(type(slot(prev, { reason = "finished", num_turns = 5, last_message = "x\n</invoke>" }).continue), "string")
  eq(type(slot(prev, { reason = "finished", num_turns = 6, last_message = "x\n</invoke>" }).continue), "string")
  eq(slot(prev, { reason = "finished", num_turns = 7, last_message = "x\n</invoke>" }).passthrough, true)
  -- A much later stall is a fresh episode and fires again.
  eq(
    type(slot(prev, { reason = "finished", num_turns = 50, last_message = "y\n</invoke>" }).continue),
    "string",
    "a new episode must refire"
  )
end)

if #failures > 0 then
  error(#failures .. " case(s) failed:\n\n" .. table.concat(failures, "\n\n"))
end

print("all spec cases passed")
