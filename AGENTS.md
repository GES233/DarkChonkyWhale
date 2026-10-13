# AGENTS.md — working in `dark_chonky_whale`

"Elixir's DSH implementation" (`README.md`), named after the 「黑色大肥鱼」 meme:
a coding agent whose whole world is a durable session log, three pluggable
seams, and a small set of plain-module tools. Everything below was read out of
this tree; nothing is aspirational.

## Commands

```sh
mix compile            # deps are vendored in deps/ (git sparse checkout of GES233/Dexterous)
mix test               # 82 tests / 1 doctest, ~4s; many runtimes are skipped when absent
mix format             # .formatter.exs covers mix.exs, config/, lib/, test/ — NOT examples/
```

Note: `mix format --check-formatted` currently fails on
`lib/dark_chonky_whale/executor/runner.ex` and `.../runtimes/python.ex`
(formatting drift, not a bug). Running `mix format` fixes those two files only.

Run things without config: `mix run examples/session_demo.exs` needs no network.
`examples/smoke_llm.exs`, `examples/agent.exs`, `examples/multi_turn_agent.exs`
hit a live provider (API keys come from the gitignored `.env`, auto-loaded by
ReqLLM; `examples/agent.exs` defaults to `deepseek:deepseek-flash`).

## Architecture: three seams + one driver

A *composition* is a Dexterous `Context` scope + `DexterousLoader.Entry`
records. Coeffects are the seam handles; provisions are declared with
`use Dexterous.Component, provide: [...]`. Nothing global: a component's config
is given per entry, e.g. in `examples/agent.exs`.

| Seam | Provider (component) | Provision | Events |
| --- | --- | --- | --- |
| `:llm` | `DarkChonkyWhale.LLM` (config `:model` required; other keys pass through to ReqLLM) | `%LLM.Client{}` | `llm/request` (waterfall), `llm/chunk`, `llm/usage` (emits) |
| `:sessions` | `DarkChonkyWhale.Sessions` (config `:dir` required) | `%Sessions{}` | `session/event` (emit, per append) |
| `:tools` | `DarkChonkyWhale.Tools` (config `:tools`, `:env`) | `%Tools{}` registry | `tools/pre-execute` (waterfall over `%{name:, arguments:, decision:}`), `tools/post-execute` (emit) |

`DarkChonkyWhale.AgentLoop.run/4` is the driver: `turn/start` → loop of
`step/start`, stream via `Client.stream/3`, `assistant/message`, execute each
tool call through `Tools.execute/3`, `tool/result` → until a final answer or
`:max_steps_exceeded` (default 100); `turn/end` is appended in an `after` block
so a dying session cannot mask the real error. The loop keeps **no history of
its own** — the model's view is exactly `Session.messages/1`.

The executor is a fourth, internal seam: `Tools.Executor` (model-facing
surface) → `Executor.Runtime` behaviour (`run/2`) → a *plan* → `Executor.Runner`
(the only place a subprocess is actually spawned and only place that touches a
temp file).

## Module map

- `DarkChonkyWhale` — placeholder `hello/0` + doctest; `Application` starts an
  empty supervisor (components are not started there).
- `LLM` / `LLM.Client` — component and the client consumers get. `:backend`
  defaults to `ReqLLM` and is swapped for a fake in tests.
- `Sessions` / `Session` — store handle and the append-only JSONL log
  (`GenServer`). Log owns `seq`/`at`, persists before advancing memory,
  replays `session-<id>.jsonl` on open, broadcasts every append.
- `Tools` — registry + guarded pipeline (`lookup/2`, `schemas/1`,
  `execute/3`); typed results `{:ok, _}` | `{:error, %{type:, message:}}` with
  `:type ∈ {:unknown_tool, :denied, :crashed}`.
- `Tool` — the tool contract (`schema/0`, `execute/2`) plus `resolve_path/2`.
- `Tools.{Read, Write, Edit, Glob, Grep, Executor, Recompile}` — the built-ins.
  `Tools.Walk` is the shared deterministic, symlink-safe, prune-aware walk and
  glob compiler used by `glob`/`grep`.
- `Executor.Runner` — port executor: merges stdout/stderr, treats a settled
  process as a result (`exit status N` appended), kills the whole tree on
  timeout, caps output head+tail, normalizes EOL, transcodes OEM-codepage bytes.
- `Executor.Runtimes.{Shell, PowerShell, Python, Elixir, ElixirSubprocess}` —
  each a `Executor.Runtime`; the first four build plans, `Elixir` evaluates
  in-process with a stand-in group leader capturing IO.

## Invariants to respect

- **Tools never raise into the pipeline.** Return `{:ok, output}` /
  `{:error, reason}`; `Tools.execute/3` rescues/catches anything else as
  `:crashed`. Model-supplied args are string-keyed maps; env values are read
  with Access (`env[:cwd]`) because direct callers may pass a keyword list.
- **A failing process is not a tool error.** Only a timeout is `{:error, _}`
  in the executor; a failing test run comes back `{:ok, output}` with
  `exit status N`. Always keep this shape.
- **Nothing invalid-UTF-8 may reach JSON.** `Session` scrubs payloads on
  append; `Runner.decode_as/2` transcodes/scrubs console bytes. Tool output is
  persisted as JSON, which would refuse invalid bytes outright.
- **Model-visible means logged.** The only projection is `Session.messages/1`;
  markers (`turn/start`, `step/start`, …) and unknown event types are durable
  but skipped. Event payloads use **string** keys in `data`.
- **Plans are plain data; runtimes never touch the filesystem.** A plan is
  `%{exe, args, cwd, script}` where `script` is *content* and the `:script`
  atom marks where its path belongs; `Runner.run/2` writes it to a fresh temp
  dir and cleans up. Keep it that way — it is the documented opening for a
  remote/sandbox runner.
- **Moduledocs are the design record.** Modules carry long "why" comments
  (platform gotchas, WSL, codepages, HMR). Update them together with behaviour.
  Constants that moduledocs interpolate are declared *before* the moduledoc
  (`Executor`, `Runner`, `Walk`, `PowerShell`) — keep that order.
- **Config is per composition.** There is no global tool registry; a new tool
  must be added to the `tools:` list of each composition (see the `examples/`).

## Pitfalls

- `runtime: "elixir"` runs in *this* BEAM: no isolation, side effects are not
  undoable, a timeout only stops the damage. `elixir_subprocess` is the
  isolated one.
- `recompile` needs `Mix.env() == :dev` under `mix run`; it starts
  `DexterousHMR` lazily and refuses cleanly elsewhere. Tests override it with
  `:dexterous_hmr`'s `:compile_fun` config and must restore "absent" with
  `Application.delete_env/2` (`put_env(key, nil)` breaks `Keyword.get`).
- `DexterousHMR` is a named singleton; `test/.../recompile_test.exs` stops it
  in `on_exit`. Keep that hygiene for any test touching it.
- `Context.use/3` is asynchronous: tests and examples poll `Context.get/2` (see
  the `eventually/await` helpers) instead of assuming the provision is bound.
  Tests that use a shared scope / named process are `async: false`.
- Platform guards are load-bearing: POSIX-shell tests are wrapped in
  `if sh = posix_shell()`, symlink tests in `with :ok <- File.ln_s(...)`, and
  codepage assertions branch on the machine's `chcp`. Do not "simplify" them.
- Windows specifics, all deliberate: a `bash.exe` under `%SystemRoot%` is the
  WSL launcher and is refused; `cmd.exe` loses grandchildren's output (and
  quoted commands go through a temp `.cmd` instead); PowerShell scripts get a
  UTF-8 BOM and `-File`; Python is pinned to `PYTHONIOENCODING=utf-8` unless the
  composition's `:shell_env` overrides it.
- Codepagex only compiles the pages whitelisted in `config/config.exs`; adding
  one means changing that list and recompiling `codepagex`.
- `.formatter.exs` inputs exclude `examples/`; formatting them is not covered
  by `mix format`.
- `Tools.Walk` prunes by directory *name* (`.git`, `_build`, `deps`, …) and
  never follows symlinked dirs; override per call with `env[:search_ignore_dirs]`
  (`[]` walks everything reachable).
