# AGENTS.md

Guidance for an AI agent or contributor working in this repo.

## What this is

A maki plugin that recovers a turn where the model wrote a tool call as text
(e.g. DeepSeek DSML markup in the assistant `content`) instead of emitting a
structured `tool_calls` field. It layers the `agent.stop` slot and answers with
`{ continue = <nudge> }` so the agent retries the same turn.

## Hard constraints

- **Conservative detection.** A missed call is a message whose **tail** ends in
  a dialect **closer**. Never match a closer that has text after it, and never
  fire on an opener alone. Prose that quotes markup must stay quiet.
- **Lightweight.** `closer_at_tail` runs inside the caller's task on every
  finished turn. Keep it a tail scan; do not scan the whole body or compile
  patterns per call.
- **Bounded retries.** `max_retries` (default 2) per stall episode. Do not
  raise it casually — each retry is a model turn the user pays for.
- **Do not parse or execute leaked calls.** The nudge stage asks the model to
  retry; the `parse` field on a dialect is reserved for a future opt-in stage
  and stays `nil` until that lands.
- **No `register_options`.** This is not a bundled plugin; maki rejects a
  `plugins.<name>` table for a plugin it does not ship and fails startup.
  Configuration goes through `M.setup(opts)`.

## Lua portability

The same files must load under **Luau**, **Lua 5.4**, and **Lua 5.1**:

- Write non-ASCII marker bytes as **decimal byte escapes**, never `\u{...}`
  (`\u` is Luau/5.4-only; Lua 5.1 reads it as a plain `u`). The fullwidth bar
  U+FF5C is `"\239\189\156"`. Get the bytes exactly right: a one-byte slip
  (`\239\188\156`, U+FF3C) looks identical in a terminal and matches nothing.
- Lua patterns have **no `|` alternation** in any of these. Emit one pattern per
  spelling.
- `?` binds to a **single** item, so an optional multi-byte sequence must be
  written as separate optional bytes/classes, not `bytes .. "?"`.
- `{ require(x) }` spreads `require`'s extra return values under Lua 5.2+/Luau.
  Assign to a local first, then use it.

## Testing

`tests/spec.lua` is standalone: it installs a minimal `maki` stub, requires the
module, and exercises `closer_at_tail` and the registered slot layer. Run it on
every installed interpreter:

```
lua5.4 tests/spec.lua
lua5.1 tests/spec.lua
```

Add a case for every recorded closer spelling and every negative (quoted
markup, openers, empty). Build marker strings from the shared `BAR`/`DSML`
locals rather than embedding raw multi-byte literals, so a fix in one place
covers the tests too.

## Slot contract

`agent.stop` fires with `{ reason, last_message, num_turns }`. `last_message` is
the first text block of the last assistant message. Returning
`{ continue = <string> }` makes the loop push a synthetic message and continue
(fired from `keep_going` in maki's `agent/run.rs`). Returning anything else, or
calling `prev(value)`, continues the chain untouched.

A layer on `agent.stop` must hold **every** permission or the host drops it,
silently, one warning per missing gap.

## Style

- No trivial comments. Each line earns its place.
- Consts at the top of the file.
- Descriptive names.
- Keep the module small: detection, dispatch, and the slot wiring only.
