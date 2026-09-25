defmodule DarkChonkyWhale.Executor.Runtimes.Shell do
  @moduledoc """
  The shell runtime: run `code` through the platform shell — `bash -c`, or
  `sh -c` where bash is absent, on POSIX; on Windows a `bash`/`sh` found on
  PATH, with `cmd.exe /c` as the last resort.

  POSIX commands are given a closed stdin (`exec 0</dev/null`), so a command
  that would read from a terminal gets EOF instead of hanging until the
  timeout. On Windows a command containing a double quote is written to a
  temporary `.cmd` file and run from there, because `cmd.exe` re-parses the
  raw command line rather than an argument vector — a quoted argument cannot
  survive one as itself, and every `git commit -m "..."` would arrive
  mangled. Batch-file expansion (`%VAR%`) then applies to those commands in
  the usual way.

  ## Windows shell selection, and its limits

  The cwd picks the universe: a command should run where its working
  directory lives. On Windows the default is therefore the first
  `bash`/`sh` on PATH that does *not* live under `%SystemRoot%` — a
  `bash.exe` there is the WSL launcher, which would run the command inside
  a Linux install (different filesystem view, none of the project's tools
  on its PATH) and let none of its output back. Two gaps remain, by
  decision:

    * Discovery is PATH-only. A Git Bash that is installed but not on PATH
      (a stock Git for Windows lives in `C:\\Program Files\\Git\\bin`) is
      not found; point the `:shell` environment at it explicitly.
    * A working directory inside WSL (`\\\\wsl$\\…`) does not route into
      WSL — the tool refuses WSL rather than matching the cwd's universe.

  The last resort is `cmd.exe`, which as a port child shows builtins'
  output but loses what the programs it spawns write — `mix` runs, but its
  output never arrives; redirect to a file and read it if you must.

  The `:shell` environment overrides the selection: the shell program (name
  or path), or `{program, args}` where `args` precede the command.
  """

  @behaviour DarkChonkyWhale.Executor.Runtime

  alias DarkChonkyWhale.Executor.Runner

  @posix_shells ~w(sh bash dash zsh ksh ash busybox)

  @impl true
  def run(code, ctx) do
    with {:ok, plan} <- build_plan(ctx.env, code, ctx.cwd) do
      Runner.run(plan, ctx)
    end
  end

  ## How the command reaches the shell

  # A plan is what to spawn: the executable, the argument vector, an optional
  # cwd override (the batch-file case), and an optional script as content —
  # the runner writes and deletes it.
  defp build_plan(env, command, cwd) do
    {program, base_args} = shell(env)

    with {:ok, exe} <- executable(program) do
      invocation(exe, base_args, command, cwd)
    end
  end

  # The platform shell, unless the environment names one: `{program, args}`
  # (the shape `cmd.exe /c` needs, where the command comes last) or a bare
  # program, which then gets `-c` the way the POSIX shells take it.
  defp shell(env) do
    case Map.get(env, :shell) do
      nil -> default_shell()
      {program, args} when is_binary(program) and is_list(args) -> {program, args}
      program when is_binary(program) -> {program, ["-c"]}
    end
  end

  defp default_shell do
    case :os.type() do
      {:win32, _} ->
        # Prefer a POSIX shell when one is on PATH (Git Bash): as a port
        # child, cmd.exe loses the output of the external programs it spawns
        # (builtins work, grandchildren's stdio does not), which makes it
        # unusable beyond builtins. cmd.exe is the last resort.
        case find_posix_shell() do
          nil -> {System.get_env("COMSPEC") || "cmd.exe", ["/c"]}
          path -> {path, ["-c"]}
        end

      _posix ->
        {System.find_executable("bash") || "sh", ["-c"]}
    end
  end

  # `bash.exe` under %SystemRoot% is not a shell for this universe at all —
  # it is the WSL launcher: the command would run inside a Linux install
  # (different filesystem view, none of the project's tools on its PATH)
  # and its output never reaches the port, so every call would come back
  # empty. A real bash or sh (Git Bash, MSYS2, a scoop shim) is the only
  # acceptable answer; anything else on Windows is WSL or nothing.
  defp find_posix_shell do
    Enum.find_value(~w(bash sh), fn name ->
      case System.find_executable(name) do
        nil -> nil
        path -> if under_system_root?(path), do: nil, else: path
      end
    end)
  end

  defp under_system_root?(path) do
    # find_executable reports forward slashes on Windows, SystemRoot
    # backslashes; normalize before comparing.
    root = (System.get_env("SystemRoot") || "C:\\Windows") <> "\\"
    normalized = String.replace(path, "/", "\\")
    String.starts_with?(String.downcase(normalized), String.downcase(root))
  end

  # A POSIX shell takes the command as an argument, verbatim: an argument
  # vector carries any quoting it contains untouched, and the shell's stdin
  # is redirected shut first.
  defp invocation(exe, base_args, command, cwd) do
    cond do
      posix_shell?(exe) ->
        plan = %{
          exe: exe,
          args: base_args ++ ["exec 0</dev/null\n" <> command],
          cwd: nil,
          script: nil
        }

        {:ok, plan}

      cmd?(exe) and String.contains?(command, "\"") ->
        batch_invocation(exe, base_args, command, cwd)

      true ->
        {:ok, %{exe: exe, args: base_args ++ [command], cwd: nil, script: nil}}
    end
  end

  # The batch file is spawned with its own directory as the process cwd and
  # named by a bare basename — no quotes in the argument vector at all,
  # whatever spaces the temp directory contains — and the script `cd`s to the
  # real working directory as its first act. The content is handed to the
  # runner, which materializes it; `cwd: :script` points the process at the
  # directory the script lands in.
  defp batch_invocation(exe, base_args, command, cwd) do
    {:ok,
     %{
       exe: exe,
       args: base_args ++ ["command.cmd"],
       cwd: :script,
       script: %{name: "command.cmd", content: batch_body(command, cwd)}
     }}
  end

  # `@echo off` first, or cmd prints every line of the file into the output;
  # the code page is set to UTF-8 so a command line the model wrote in UTF-8
  # is read as itself; then the real working directory is entered. The body
  # is ordinary batch, so `%VAR%` expansion applies as it would in any `.cmd`.
  defp batch_body(command, cwd) do
    "@echo off\r\nchcp 65001 >nul\r\ncd /d \"" <> cwd <> "\"\r\n" <> crlf(command) <> "\r\n"
  end

  defp crlf(text), do: text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")

  defp posix_shell?(exe), do: shell_name(exe) in @posix_shells
  defp cmd?(exe), do: shell_name(exe) == "cmd"

  defp shell_name(exe) do
    exe
    |> Path.basename()
    |> String.downcase()
    |> String.replace_suffix(".exe", "")
  end

  defp executable(program) do
    case System.find_executable(program) do
      nil -> {:error, "shell not found: #{program}"}
      path -> {:ok, path}
    end
  end
end
