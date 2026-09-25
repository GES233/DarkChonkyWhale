# 黑色大肥鱼

> The name riffs on a moe-anthropomorphism meme on the Chinese internet that
> nicknamed DeepSeek's whale logo 「蓝色大肥鱼」 — "the blue chonky whale".
> This is the dark variant.

Elixir's DSH implementation.

## Built-in tools

Each tool is a plain module implementing `DarkChonkyWhale.Tool`; list the ones
a composition wants in the `:tools` component's config.

| Tool | Module | What it does |
| --- | --- | --- |
| `read` | `DarkChonkyWhale.Tools.Read` | Read a file with line numbers, paged |
| `write` | `DarkChonkyWhale.Tools.Write` | Create or overwrite a file |
| `edit` | `DarkChonkyWhale.Tools.Edit` | Replace a unique string, line-ending aware |
| `glob` | `DarkChonkyWhale.Tools.Glob` | Find files by pattern (`*`, `?`, `**`) |
| `grep` | `DarkChonkyWhale.Tools.Grep` | Search file contents by regex |
| `execute` | `DarkChonkyWhale.Tools.Executor` | Run code in a runtime (shell command, PowerShell, Python, Elixir) with a timeout and an output cap |
| `recompile` | `DarkChonkyWhale.Tools.Recompile` | Recompile and hot-swap changed modules (dev only, via `dexterous_hmr`) |

`glob` and `grep` share `DarkChonkyWhale.Tools.Walk`: a deterministic,
symlink-safe walk that prunes build output and vendored directories
(`.git`, `_build`, `deps`, `node_modules`, …). Override the prune list per
composition with the tool env's `:search_ignore_dirs`.

`execute` runs code in one of five runtimes, chosen by its `runtime`
argument:

- `shell` (default) — a shell command through the platform shell
  (`bash -c`/`sh -c` on POSIX, `cmd.exe /c` as the Windows last resort),
  with stderr merged and stdin closed, so a command that would prompt gets
  EOF instead of hanging.
- `powershell` — the code as a `.ps1` script through `pwsh`, or
  `powershell` where that is what the machine has.
- `python` — the code as a `.py` script through `python3`/`python`.
- `elixir` — the code evaluated in the agent's own BEAM, where it can see
  and touch the live system; nothing is isolated, and a timeout kills the
  evaluation but cannot undo its side effects.
- `elixir_subprocess` — the code as an `.exs` script through the `elixir`
  CLI, in a fresh VM.

A run that fails is a normal result (`exit status N` is appended); only a
run that outlives its timeout is an error, and it is killed. The tool env
can fix a `:shell`, `:powershell`, `:python` or `:elixir` program, plus
`:shell_timeout_ms`, `:shell_env` and `:max_output_bytes` defaults; each
call can override the timeout and the cap.

