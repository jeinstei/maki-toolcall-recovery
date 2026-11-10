# AGENTS.md

Guidance for an AI agent or contributor working in this repo.

## What this is

A maki plugin that recovers a turn where the model wrote a tool call as text
(e.g. DeepSeek DSML markup in the assistant `content`) instead of emitting a
structured `tool_calls` field. It layers the `agent.stop` slot and answers with
`{ continue = <nudge> }` so the agent retries the same turn.

The failure is a known upstream bug in the serving stack's tool-call parser, not
a client problem. The README's "Why this happens" section lists the reports the
shipped patterns were written against (vLLM #48931 and its fixes #49117/#52645/
#55954; SGLang #40236→#40237, #23915, #14695). The `parse`-stage design borrows
the declared-tool-name validation those fixes use.

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

## Packaging and manifest

- A package loads every `plugin/*.lua` as chunks under one owner; the entry is
  `plugin/toolcall_recovery.lua` → `require("toolcall_recovery")`. The package's
  `require` root is sandboxed to its own `lua/`.
- `plugin.toml` is read from the package's own directory on every packaged path
  (managed `pack.add` or hand-placed). Only a config-dir plugin is governed by
  the config dir's `plugin.toml` instead.
- **Develop in the package layout, live.** Place the repo under a manual group so
  maki runs it straight from the working tree, no clone or commit:
  `mkdir -p ~/.local/share/maki/site/pack/dev/start` then
  `ln -sfn "$PWD" ~/.local/share/maki/site/pack/dev/start/maki-toolcall-recovery`.
  A hand-placed package is trusted like `init.lua` and grants what its own
  `plugin.toml` lists, with no approval prompt. `/reload` picks up edits.
  See maki's plugin guide: `site/docs/content/plugins/_index.md` (development
  loop) and `site/docs/content/packages/_index.md` (install by hand, manual
  groups).
- `min_maki_version` is set by the **permission set**, not by `agent.stop`.
  `agent.stop` + `{continue}` + all-permission pricing exist since `v0.5.7`, but
  the ten-variant `Permission` enum only exists from `v0.7.0` (`session_read` /
  `session_write` / `session_settings` / `input` arrived there). Hence `0.7.0`.
- Configuring a package-loaded plugin needs a custom `load` in `pack.add`, run as
  the package owner (a config-dir `init.lua` cannot `require` a package's
  sandboxed module).

## Gotchas

- **A tail closer that fires is always a real leaked call — even when the
  message is *about* leaks.** The model/provider spontaneously appends the DSML
  closer to the assistant content's tail, so prose explaining the plugin can end
  in a genuine appended closer. The classifier fires on that; it is correct, and
  cannot distinguish it from an intended call (same bytes). Mid-message quoted
  markers do **not** fire (tail-anchored), and the retry budget caps a run of
  such turns. The future parse stage is the real fix: validate the reconstructed
  tool name against the request's declared tools before acting.
- **`pack.add`'s `load` applies to every spec in the call.** `opts.load` is
  cloned onto each spec (`pack.rs`), so two packages in one call with one loader
  both get it — the second throws `module not found` under its own owner. Give
  each package that needs a loader its **own** `pack.add` call.
- **`require` in a package is sandboxed.** `require("toolcall_recovery")` from a
  config-dir `init.lua` will not reach a package's module; use the `load` hook.
- **Non-obvious default:** `instrument` is `false`, so a shipped install logs no
  per-turn tail. That is deliberate; `maki.log.debug` lines are dropped unless
  `MAKI_LOG=debug`.

## Style

- No trivial comments. Each line earns its place.
- Consts at the top of the file.
- Descriptive names.
- Keep the module small: detection, dispatch, and the slot wiring only.
