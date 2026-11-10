-- Recover a turn where the model wrote a tool call as text (DSML, antml, and
-- other dialects) instead of emitting structured `tool_calls`.
--
-- It layers the `agent.stop` slot, which the agent loop fires only when a turn
-- ends without calling a tool. Returning `{ continue = <text> }` makes the loop
-- push a synthetic message and continue the same turn, so the model gets to
-- emit the call properly instead of the turn silently ending.
--
-- Detection is conservative: a missed call is a message whose TAIL ends in a
-- dialect closing tag. Prose that merely quotes a closer is followed by more
-- text and is ignored; a truncated block has no closer and is ignored.

local M = {
  -- Fires at most this many times per episode before giving up. The model
  -- usually emits the structured call on the first retry; more than a couple
  -- means it will not, and each retry is a model turn the user pays for.
  max_retries = 2,
  -- Off by default. When on, logs one debug line per finished turn with the
  -- whole hex-escaped message, so an uncovered spelling is captured. maki keeps
  -- debug lines only when MAKI_LOG=debug, so this is cheap until a developer
  -- asks for it.
  instrument = false,
}

-- Dialect modules, one per file. Each returns `{ name, tail_patterns, parse }`.
-- Assigned to a local first: `{ require(x) }` would spread require's multiple
-- return values (Lua 5.2+/Luau return loader data too), adding a stray element.
local dsml = require("toolcall_recovery.dialects.dsml")

local DIALECTS = { dsml }

local RETRY_MESSAGE = "You wrote a tool call as text instead of calling the tool. "
  .. "Call it now with the actual tool interface; do not describe the call."

-- Retries spent in the current episode. An episode is a run of consecutive
-- turn-ends (the retry we returned, and the stall it produced); anything else
-- starts a fresh episode with a fresh budget.
local retries = 0
-- The turn number of the last fire, or -1.
local last_fire_turn = -1

-- Clears the per-episode budget and the episode marker.
function M.reset()
  retries = 0
  last_fire_turn = -1
end

-- Whether `text` ends (modulo trailing whitespace) in a tool-call closing tag,
-- returning the matched tag or nil. Models spell the same closer many ways --
-- `</invoke>`, `</ invoke>`, `</｜DSML｜invoke>`, `</ parameter>` -- so each dialect
-- supplies permissive Lua patterns instead of exact bytes. A closer exists only
-- when the model finished a block, so text ending in one is a missed call.
local function closer_at_tail(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local tail = string.match(text, "^(.-)%s*$")
  for _, dialect in ipairs(DIALECTS) do
    for _, pattern in ipairs(dialect.tail_patterns) do
      local which = string.match(tail, pattern)
      if which then
        return which
      end
    end
  end
  return nil
end

-- Exposed for tests.
M.closer_at_tail = closer_at_tail

-- Lines of the instrument capture are capped so a runaway message cannot fill
-- the log; a real leaked call is far shorter than this.
local INSTRUMENT_MAX_BYTES = 8000
local INSTRUMENT_HALF = math.floor(INSTRUMENT_MAX_BYTES / 2)

-- Renders every byte that is not printable ASCII as \xNN, so the exact marker
-- bytes survive a log round-trip: the fullwidth bar, mojibake, and control
-- characters all stay distinguishable. Keeps the oldest bytes and drops the
-- middle if the message exceeds the cap, so both the start of the block and its
-- closing tag are visible.
local function hexdump(s)
  local body = tostring(s)
  local dropped = #body - INSTRUMENT_MAX_BYTES
  if dropped > 0 then
    body = body:sub(1, INSTRUMENT_HALF) .. "\n[... " .. dropped .. " bytes dropped ...]\n" .. body:sub(-INSTRUMENT_HALF)
  end
  return (body:gsub("[^%w%p ]", function(c)
    return "\\x" .. string.format("%02X", string.byte(c))
  end))
end

-- The `instrument` capture: one debug line per finished turn, matched or not, so
-- a spelling the patterns do not cover yet is recorded instead of passing
-- through unseen. `last_message` is dumped whole (hex-escaped) so a future
-- parser can be written against real samples; at the default log level (`info`)
-- this line is dropped, so it costs nothing until someone sets MAKI_LOG=debug.
local function instrument_tail(value, closer)
  maki.log.debug(
    string.format(
      "toolcall_recovery: tail (reason=%s, turn=%s, len=%d, closer=%s): %s",
      tostring(value.reason),
      tostring(value.num_turns),
      #tostring(value.last_message),
      closer or "-",
      hexdump(value.last_message)
    )
  )
end

local function fire(value)
  if type(value) ~= "table" then
    return false
  end
  -- A truncated turn (max_tokens) is a different failure.
  if value.reason == "max_tokens" then
    return false
  end
  -- A stall whose turn is not the one right after the last fire is a new
  -- episode, and gets a fresh budget. Without this a run of consecutive stalls
  -- pins the budget at max_retries and the plugin never fires again.
  local turn = tonumber(value.num_turns) or -1
  if last_fire_turn < 0 or turn ~= last_fire_turn + 1 then
    retries = 0
  end
  local closer = closer_at_tail(value.last_message)
  if M.instrument then
    instrument_tail(value, closer)
  end
  if not closer then
    return false
  end
  if retries >= M.max_retries then
    maki.log.warn(
      string.format(
        "toolcall_recovery: giving up after %d retries, closer=%s (turn=%s)",
        retries,
        closer,
        tostring(turn)
      )
    )
    return false
  end
  retries = retries + 1
  last_fire_turn = turn
  -- `info`, not `warn`: a recovery is the plugin working as intended. It is
  -- logged so a continued turn has a visible cause.
  maki.log.info(
    string.format(
      "toolcall_recovery: stalled turn (turn=%s, retry=%d/%d, closer=%s)",
      tostring(turn),
      retries,
      M.max_retries,
      closer
    )
  )
  return true
end

function M.setup(opts)
  for key, val in pairs(opts or {}) do
    if M[key] ~= nil then
      M[key] = val
    end
  end
  return M
end

maki.api.set_slot("agent.stop", function(prev, value)
  if fire(value) then
    return { continue = RETRY_MESSAGE }
  end
  return prev(value)
end)

return M
