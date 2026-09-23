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
| `bash` | `DarkChonkyWhale.Tools.Bash` | Run a shell command (tests, git, a build) with a timeout and an output cap |
| `recompile` | `DarkChonkyWhale.Tools.Recompile` | Recompile and hot-swap changed modules (dev only, via `dexterous_hmr`) |

`glob` and `grep` share `DarkChonkyWhale.Tools.Walk`: a deterministic,
symlink-safe walk that prunes build output and vendored directories
(`.git`, `_build`, `deps`, `node_modules`, …). Override the prune list per
composition with the tool env's `:search_ignore_dirs`.

`bash` runs through the platform shell (`bash -c`/`sh -c` on POSIX,
`cmd.exe /c` on Windows) with stderr merged and stdin closed, so a command
that would prompt gets EOF instead of hanging. A command that fails is a
normal result (`exit status N` is appended); only a command that outlives
its timeout is an error, and it is killed. The tool env can fix a
`:shell`, a `:shell_timeout_ms`, a `:shell_env` and a `:max_output_bytes`
default; each call can override the timeout and the cap.

