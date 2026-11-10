# maki-toolcall-recovery

NOTE: as of 10.11.2026, this plugin was AI-directed, but has not been completely
reviewed by a human.

Some OpenAI-compatible servers leak a tool call **as text** in the assistant
`content` — DeepSeek DSML markup, `antml`, and similar dialects — instead of
sending a structured `tool_calls` field. maki parses tools only from
`tool_calls`, so that turn ends with the model waiting for a result that never
comes, and you have to type "continue" by hand.

This plugin recovers that turn automatically.

## What it does

maki fires the `agent.stop` slot when a turn ends without calling a tool. When
the message is *obviously a missed call* — its text ends in a dialect closing
tag, e.g. the marker the model writes after a tool block — the plugin returns a
short nudge that makes the agent continue the same turn. The model then gets a
second chance to emit the call through the real tool interface.

A closer only appears once the model has finished writing a block, so the check
looks at the **end** of the message:

- a message ending in a tool-call closer → almost certainly a missed call → nudge
- prose that merely *quotes* markup (`the raw output has <…> in it`) → text
  follows the marker → ignored
- a truncated block with no closer → ignored

There is no false-positive on quoted markup: the closing tag has to be the last
thing in the message.

## Why this happens

This is not your imagination and not a context-length problem in the client. The
serving stack's tool-call parser sometimes fails to recognize a call the model
did emit, and returns the model's raw DSML markup in `content` with
`tool_calls` absent. The response is HTTP 200 with `finish_reason: "stop"`, so
the client (maki) reads a completed turn, ends the conversation, and the call is
silently dropped.

Two representative reports:

- **vLLM** [#48931](https://github.com/vllm-project/vllm/issues/48931) — DeepSeek
  intermittently omits the `<｜DSML｜DSML｜DSML｜tool_calls>` START wrapper while still
  emitting a well-formed invoke block; the parser anchors on that START token, so
  the whole block leaks as `content`.
- **SGLang** [#14695](https://github.com/sgl-project/sglang/issues/14695) — a
  detokenizer with `skip_special_tokens=True` strips the `｜DSML｜DSML｜DSML｜` markers, so
  the leak arrives with the marker text missing.

The fix belongs in the server. This plugin is a client-side workaround for the
stall these bugs cause, not a fix for them. It never parses or runs the leaked
call — it only asks the model to try again.

A content parser that reads the leaked call and runs it is a possible future,
opt-in stage. It is not implemented.

## Behaviors you should know

- **Conservative.** Only a closer at the very end of the message counts. Quoted
  or mid-sentence markup does not.
- **Bounded.** It nudges at most `max_retries` times (default 2) per stall
  episode. An episode is a run of consecutive stalled turns; any other turn
  ends it and resets the budget. After the budget, it gives up and lets the
  turn end normally, so a truly stuck model does not loop forever.

## Install

As a package, in your `init.lua`:

```lua
maki.pack.add({ "https://github.com/jeinstei/maki-toolcall-recovery" })
```

Then `/reload`.

## Configuration

This plugin is not a bundled plugin, so it does **not** use
`maki.api.register_options` (maki rejects a `plugins.<name>` table for a plugin
it does not ship, and startup fails). Options go through a `setup(opts)` call in
Lua, and **where you make that call depends on how the plugin is loaded.**

**Installed as a package** (the normal case), the module lives in the package's
own sandbox, so a config-dir `init.lua` cannot `require` it. Pass the custom
loader, which runs as the package owner and can. The loader applies to every
spec in its `pack.add` call, so give the package its own call:

```lua
maki.pack.add({
  { src = "https://github.com/jeinstei/maki-toolcall-recovery" },
}, {
  load = function(package)
    require("toolcall_recovery").setup({ max_retries = 2, instrument = false })
  end,
})
```

**Hand-placed for development** (`pack/dev/start/`, see Development), the package
still has no loader, so set the options in the entry file `plugin/toolcall_recovery.lua`:

```lua
require("toolcall_recovery").setup({ instrument = true })
```

**Loaded by a config-dir symlink**, the config-dir require root is trusted, so a
plain call from `init.lua` works:

```lua
require("toolcall_recovery").setup({ max_retries = 2, instrument = false })
```

| Option | Default | Meaning |
| --- | --- | --- |
| `max_retries` | `2` | How many nudges per stall episode before giving up. |
| `instrument` | `false` | Log one `debug` line per finished turn with the whole byte-escaped message, matched or not, so a spelling the patterns do not cover yet is captured. Needs `MAKI_LOG=debug` to appear. |

Both options and `min_maki_version` are documented, commented, in `plugin.toml`.
`max_retries` and `instrument` are **not** read from there: the manifest carries
permissions and version only, and options are set in Lua.

Logs go to maki's log file (`maki.env.logs_dir()`, Linux:
`~/.local/logs/maki/`). A recovery logs one `info` line; giving up after the
retry budget logs a `warn`.

## Permissions — read this

**The plugin requests every permission maki has.** Wrapping an `agent.*` slot
prices the whole set: any slot that steers what the agent does next is charged
at the host's ceiling. The code only reads `value.last_message` (a string) and
returns a `continue` string — it never touches the filesystem, the network,
processes, or the environment. But a grant is the plugin's blast radius, so
install this only if you trust the code. If the full grant is unacceptable, an
autocmd that calls `maki.agent.call_tool` is a narrower-grant alternative — at
the cost of not being able to return a verdict to the agent loop.

## Development

Place the repo under a manual package group and symlink it. Maki resolves the
symlink, so it runs the package straight from your working tree and `/reload`
picks up every edit — no clone, lockfile, or commit:

```sh
mkdir -p ~/.local/share/maki/site/pack/dev/start
ln -sfn "$PWD" ~/.local/share/maki/site/pack/dev/start/maki-toolcall-recovery
```

Run the specs with any installed Lua interpreter:

```
lua5.4 tests/spec.lua
lua5.1 tests/spec.lua
```

Contributor guidance — the dev loop, packaging, Lua portability, and the
detection contract — is in [AGENTS.md](AGENTS.md). Adding a dialect or a parser:
see [PARSERS.md](PARSERS.md).
