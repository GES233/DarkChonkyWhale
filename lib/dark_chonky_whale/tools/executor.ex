defmodule DarkChonkyWhale.Tools.Executor do
  # Defined ahead of the moduledoc, which reads them.
  @default_timeout_ms 30_000
  @max_timeout_ms 600_000
  @default_max_output_bytes 30_000

  @runtimes %{
    "shell" => DarkChonkyWhale.Executor.Runtimes.Shell,
    "powershell" => DarkChonkyWhale.Executor.Runtimes.PowerShell,
    "python" => DarkChonkyWhale.Executor.Runtimes.Python,
    "elixir" => DarkChonkyWhale.Executor.Runtimes.Elixir,
    "elixir_subprocess" => DarkChonkyWhale.Executor.Runtimes.ElixirSubprocess
  }

  @moduledoc """
  The `execute` tool: run a piece of code in one of five runtimes, chosen
  by the `runtime` argument (default `shell`).

  The runtimes:

    * `shell` — a shell command in the working directory, through the
      platform shell (`bash -c`/`sh -c` on POSIX; a POSIX shell found on
      PATH, else `cmd.exe /c`, on Windows). For everything the file tools
      cannot do — running the tests, `git`, a build, a formatter.
    * `powershell` — the code as a `.ps1` script through `pwsh`, or
      `powershell` where that is what the machine has.
    * `python` — the code as a `.py` script through `python3`/`python`.
    * `elixir` — the code evaluated in the agent's own BEAM, where it can
      see and touch the live system (a running session, a loaded module).
      Nothing is isolated and side effects cannot be rolled back; a timeout
      kills the evaluation but cannot undo what it already did.
    * `elixir_subprocess` — the code as an `.exs` script through the
      `elixir` CLI, in a fresh VM: Elixir on the same isolated pipeline as
      the other runtimes.

  A settled run is a *result*, not an error: its output comes back, with
  `exit status N` appended when a subprocess failed, so a failing test run
  reads like any other answer instead of a broken tool. Only a run that
  outlives its timeout is an error — it is killed and what it produced so
  far is reported — so a wedged run (waiting on a prompt, serving a port)
  cannot wedge the turn. Approval policy, if a composition wants one,
  belongs in a `:"tools/pre-execute"` listener; see `DarkChonkyWhale.Tools`.

  Output is capped at `:max_output_bytes` (default
  #{@default_max_output_bytes}): the head and the tail are kept and the
  middle is replaced by a byte count, so one runaway program cannot flood
  the session log. Subprocess output is expected to be UTF-8; on Windows,
  bytes that are not are transcoded from the OEM codepage (`chcp`'s answer —
  CP936 on a zh-CN machine), and only bytes no interpretation accepts become
  U+FFFD — tool output is persisted as JSON, which would refuse invalid
  bytes outright.

  Environment:

    * `:shell` — the shell program (name or path), or `{program, args}` where
      `args` precede the command; defaults to the platform shell.
    * `:powershell`, `:python`, `:elixir` — the same kind of override for
      the respective runtime's program.
    * `:shell_timeout_ms` — default timeout; capped at #{@max_timeout_ms}
    * `:shell_env` — extra environment variables for a subprocess, e.g.
      `%{"MIX_ENV" => "test"}`
    * `:max_output_bytes` — default output cap

  The `timeout_ms` and `max_output_bytes` arguments override the environment
  per call.

  ## The executor is a seam

  Deciding *what* to run is the tool surface and the runtimes
  (`DarkChonkyWhale.Executor.Runtimes`); *how* a subprocess runs is
  `DarkChonkyWhale.Executor.Runner`, a local port executor. A composition
  that needs code to run elsewhere — WSL, over SSH, inside a sandbox —
  should be able to replace the runner without touching the tool surface.
  Today only the local runner exists; the split is the opening.
  """

  @behaviour DarkChonkyWhale.Tool

  alias DarkChonkyWhale.Tool

  @impl true
  def schema do
    %{
      name: "execute",
      description:
        "Run code in a runtime: `shell` (default; tests, git, a build), " <>
          "`powershell`, `python`, `elixir_subprocess` (an .exs script in a " <>
          "fresh VM) or `elixir` (evaluated in the agent's own BEAM, where the " <>
          "code can see and modify the live system — side effects cannot be " <>
          "undone). Subprocess output merges stdout and stderr and is returned " <>
          "with `exit status N` appended on failure; in-process Elixir returns " <>
          "captured IO plus the inspected value. A run is killed after " <>
          "`timeout_ms` (default #{@default_timeout_ms}, capped at #{@max_timeout_ms}) " <>
          "and the output is capped at `max_output_bytes` (head and tail kept).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "code" => %{"type" => "string", "description" => "Code to run in the runtime"},
          "runtime" => %{
            "type" => "string",
            "enum" => Map.keys(@runtimes),
            "description" =>
              "The runtime to run the code in: shell (default), powershell, " <>
                "python, elixir (in the agent's BEAM), elixir_subprocess."
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory. Default: the composition's cwd."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Kill the run after this many ms."
          },
          "max_output_bytes" => %{
            "type" => "integer",
            "description" => "Cap on the output; the middle is elided."
          }
        },
        "required" => ["code"]
      }
    }
  end

  @impl true
  def execute(%{"code" => code} = args, env) when is_binary(code) do
    env = normalize_env(env)

    with :ok <- validate(code),
         {:ok, cwd} <- working_dir(args, env),
         {:ok, runtime} <- runtime(args) do
      runtime.run(code, %{
        cwd: cwd,
        env: env,
        timeout_ms: timeout_ms(args, env),
        max_output_bytes: max_output_bytes(args, env)
      })
    end
  end

  def execute(_args, _env), do: {:error, "code is a required string"}

  ## The call's knobs

  # The registry always hands over a map, but the in-process Elixir runtime
  # invites direct calls, where a keyword list is the natural literal —
  # `execute(%{"code" => "..."}, cwd: ".")`. `env[:cwd]` would take either
  # (Access does), while the `Map.get` reads below would raise BadMapError on
  # a list — accept both rather than failing halfway through the call.
  defp normalize_env(env) when is_list(env), do: Map.new(env)
  defp normalize_env(env) when is_map(env), do: env

  defp validate(code) do
    if String.trim(code) == "" do
      {:error, "code must not be empty"}
    else
      :ok
    end
  end

  defp working_dir(args, env) do
    dir =
      case Map.get(args, "cwd") do
        nil -> env[:cwd] || File.cwd!()
        given -> Tool.resolve_path(env, given)
      end

    if File.dir?(dir), do: {:ok, dir}, else: {:error, "not a directory: #{dir}"}
  end

  defp runtime(args) do
    name = Map.get(args, "runtime", "shell")

    case Map.fetch(@runtimes, name) do
      {:ok, runtime} -> {:ok, runtime}
      :error -> {:error, "unknown runtime: #{inspect(name)}"}
    end
  end

  # Model-supplied and env-supplied numbers: take the first that is a positive
  # integer and fall back otherwise, so a sloppy value in either place is
  # ignored rather than crashing the pipeline.
  defp timeout_ms(args, env) do
    args["timeout_ms"]
    |> positive(Map.get(env, :shell_timeout_ms), @default_timeout_ms)
    |> min(@max_timeout_ms)
  end

  defp max_output_bytes(args, env) do
    positive(args["max_output_bytes"], Map.get(env, :max_output_bytes), @default_max_output_bytes)
  end

  defp positive(value, _env_value, _default) when is_integer(value) and value > 0, do: value

  defp positive(_value, env_value, _default) when is_integer(env_value) and env_value > 0,
    do: env_value

  defp positive(_value, _env_value, default), do: default
end
