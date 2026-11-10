# Adding a dialect / parser

The plugin has two stages. Only the first exists today.

| Stage | Status | Job |
| --- | --- | --- |
| **Nudge** | implemented | Spot a turn that ended with a leaked tool-call block and ask the model to retry. |
| **Parse** | reserved, opt-in | Read the leaked call out of the text and run it, so the model need not retry. |

A dialect is one file under `lua/toolcall_recovery/dialects/`. It serves both
stages: `tail_patterns` for the nudge, `parse` for the parse stage.

## The dialect contract

A dialect module returns a table:

```lua
return {
  name = "dsml",             -- for logs and error messages
  tail_patterns = { ... },   -- the nudge stage
  parse = nil,               -- the parse stage; nil until it lands
}
```

Register it with one line in the `DIALECTS` list in `init.lua`:

```lua
local dsml = require("toolcall_recovery.dialects.dsml")
local antml = require("toolcall_recovery.dialects.antml")
local DIALECTS = { dsml, antml }
```

Assign the `require` to a local first. `{ require(x) }` would spread require's
extra return values under Lua 5.2+/Luau and put a path string in the list.

## Stage 1 — the nudge (`tail_patterns`)

`tail_patterns` is a list of Lua patterns, each matched against the **tail** of
the assistant message after trailing whitespace is trimmed, anchored with `$`.
`closer_at_tail` returns the first match, or `nil`.

Rules:

- **A closer only.** Match the closing tag of a tool block, never the opener.
  The whole design rests on "the block is finished", which is what the closer
  proves. An opener alone means a truncated block, which is a different failure.
- **Be permissive about spelling, strict about position.** Models vary the bar,
  the spaces, and the keyword. Cover the spellings, but anchor to `$` so a mere
  quote of the markup, with text after it, never matches.
- **Lua has no `|` alternation** in Luau, 5.4, or 5.1. Emit one pattern per
  spelling; the DSML dialect crosses its prefixes and keywords in a loop.

Write non-ASCII marker bytes as **decimal escapes**. `\u{...}` is Luau/5.4-only
and 5.1 reads it as a plain `u`. The fullwidth bar U+FF5C is `"\239\189\156"`.
Get the bytes exactly right: a one-byte slip (`\239\188\156`, U+FF3C) is
invisible in a terminal and matches nothing.

**Why the marker has several spellings.** The servers that leak these calls are
themselves inconsistent. SGLang
[#14695](https://github.com/sgl-project/sglang/issues/14695) shows a detokenizer
running `batch_decode(..., skip_special_tokens=True)` that **strips the
`DSML` markers**, so the same leak arrives as a bare `</invoke>` instead of the
full `</｜DSML｜DSML｜DSML｜invoke>`. vLLM
[#48931](https://github.com/vllm-project/vllm/issues/48931) shows the model
**omitting the outer wrapper** at long context. A dialect must therefore cover
the marker with and without the `DSML` text, and with and without the wrapper.

```lua
local BAR = "\239\189\156" -- U+FF5C FULLWIDTH VERTICAL LINE
local PREFIXES = { "", BAR, BAR .. "DSML" .. BAR }
local KEYWORDS = { "invoke", "parameter", "calls", "tool_calls", "function_calls" }
local tail_patterns = {}
for _, prefix in ipairs(PREFIXES) do
  for _, keyword in ipairs(KEYWORDS) do
    tail_patterns[#tail_patterns + 1] = "</" .. prefix .. "%s*" .. keyword .. ">$"
  end
end
```

## Stage 2 — the parse function (`parse`)

Not implemented. This is the shape it is intended to take, so a dialect can be
written against it now.

```lua
parse = function(text) ... end
```

- **Input:** the full `value.last_message` string. Not the trimmed tail — a
  parser needs the whole block, its opener, and its arguments.
- **Output:** `nil` when the text is not a parseable call, or a table:

  ```lua
  {
    tool = "read",                       -- the tool name
    input = { path = "/etc/hosts" },     -- a table matching the tool's input_schema
    dialect = "dsml",                    -- provenance
  }
  ```

  `input` must be a table, not a JSON string: the caller feeds it to
  `maki.agent.call_tool`, which wants a table.

- **Never throw on malformed input.** Return `nil`. A leaked call is already a
  degraded state; a second failure mode on top of it helps nobody.
- **Do not execute anything.** The parse function only decodes text into a
  tool name and input. Running the tool is the caller's job, under its own
  permission checks.

The parse stage will be opt-in (a config flag), off by default, because running
a leaked call means trusting model-emitted text as a real invocation.

## Getting real samples to write against

Turn on `instrument`:

```lua
require("toolcall_recovery").setup({ instrument = true })
```

Then run maki with `MAKI_LOG=debug`. Every finished turn logs one line:

```
toolcall_recovery: tail (reason=finished, turn=12, len=743, closer=-): <whole message, byte-escaped>
```

`closer=-` means the nudge stage did not match — that is the line worth
collecting for a new dialect or a parser. The message is dumped whole and
byte-escaped, so the exact marker bytes, spaces, and newlines survive into the
log. Copy it, unescape the `\xNN`, and you have the literal text to write the
parser against.

Grab the lines from the log:

```
grep -a "toolcall_recovery: tail" ~/.local/logs/maki/maki.log
```

## Tests

Add a case to `tests/spec.lua` for every recorded spelling (positive) and every
negative (quoted markup mid-message, an opener alone, empty input). Build marker
strings from the shared `BAR` local in the spec rather than embedding raw
multi-byte literals, so one fix covers the tests.

```
lua5.4 tests/spec.lua
lua5.1 tests/spec.lua
```
