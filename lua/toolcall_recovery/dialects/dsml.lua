-- DeepSeek DSML. The model sometimes writes a tool call as DSML markup in the
-- assistant `content` string instead of emitting structured `tool_calls`.
--
-- The nudge stage only needs the closing-tag patterns: a closer exists only when
-- the model FINISHED a tool-call block, so a message ending in one is an
-- obviously missed call, while prose that merely quotes a marker has text after
-- it. `parse` is nil until the parse stage lands.
--
-- U+FF5C (the fullwidth vertical bar inside DeepSeek's special tokens) is
-- written as its UTF-8 bytes so this works under Luau, Lua 5.4, and Lua 5.1
-- alike -- `\u{FF5C}` is Luau/5.4-only and Lua 5.1 would read it as plain "u".
--
-- The three bytes are exact: EF BD 9C. A one-byte slip (EF BC 9C, U+FF3C) looks
-- right in a terminal and matches nothing, which silently broke every
-- bar-spelled closer while the plain `</invoke>` spelling kept working.

local BAR = "\239\189\156"

-- Every prefix the model is recorded to put between `</` and the keyword:
--   empty           -- a confused model dropping the token entirely
--   BAR             -- the bare fullwidth-bar token
--   BAR .. "DSML" .. BAR -- the full special token
-- The third is what stalled this project's own sessions, and the middle `DSML`
-- is why matching on the bar-then-keyword form alone silently missed them. A
-- space may follow any prefix (the model writes BAR, space, keyword).
-- Lua patterns have no `|` alternation (5.1 and Luau lack it too), so each
-- prefix and keyword is crossed out into a pattern of its own.
local PREFIXES = { "", BAR, BAR .. "DSML" .. BAR }
local KEYWORDS = { "invoke", "parameter", "calls", "function_calls", "tool_calls" }

local tail_patterns = {}
for _, prefix in ipairs(PREFIXES) do
  for _, keyword in ipairs(KEYWORDS) do
    tail_patterns[#tail_patterns + 1] = "</" .. prefix .. "%s*" .. keyword .. ">$"
  end
end

return {
  name = "dsml",
  -- Matched against the message tail only (see closer_at_tail).
  tail_patterns = tail_patterns,
  parse = nil,
}
