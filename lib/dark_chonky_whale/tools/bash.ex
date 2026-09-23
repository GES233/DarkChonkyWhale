defmodule DarkChonkyWhale.Tools.Bash do
  # Defined ahead of the moduledoc, which reads them.
  @default_timeout_ms 30_000
  @max_timeout_ms 600_000
  @default_max_output_bytes 30_000
  @kill_grace_ms 200
  @posix_shells ~w(sh bash dash zsh ksh ash busybox)

  @moduledoc """
  The `bash` tool: run a shell command in the working directory.

  For everything the file tools cannot do — running the tests, `git`, a
  build, a formatter. The command runs through the platform shell — `bash
  -c`, or `sh -c` where bash is absent, on POSIX; on Windows a `bash`/`sh`
  found on PATH, with `cmd.exe /c` as the last resort — with stdout and
  stderr merged, in the composition's cwd unless the call passes its own
  `cwd`.

  A settled command is a *result*, not an error: its output comes back, with
  `exit status N` appended when the command failed, so a failing test run
  reads like any other answer instead of a broken tool. Only a command that
  outlives its timeout is an error — it is killed and what it printed so far
  is reported — so a wedged command (waiting on a prompt, serving a port)
  cannot wedge the turn. Approval policy, if a composition wants one, belongs
  in a `:"tools/pre-execute"` listener; see `DarkChonkyWhale.Tools`.

  POSIX commands are given a closed stdin (`exec 0</dev/null`), so a command
  that would read from a terminal gets EOF instead of hanging until the
  timeout. On Windows a command containing a double quote is written to a
  temporary `.cmd` file and run from there, because `cmd.exe` re-parses the
  raw command line rather than an argument vector — a quoted argument cannot
  survive one as itself, and every `git commit -m "..."` would arrive
  mangled. Batch-file expansion (`%VAR%`) then applies to those commands in
  the usual way.

  Output is capped at `:max_output_bytes` (default
  #{@default_max_output_bytes}): the head and the tail are kept and the
  middle is replaced by a byte count, so one runaway command cannot flood the
  session log. Bytes that are not valid UTF-8 are scrubbed to U+FFFD on the
  way out — tool output is persisted as JSON, which would refuse them.

  Environment:

    * `:shell` — the shell program (name or path), or `{program, args}` where
      `args` precede the command; defaults to the platform shell.
    * `:shell_timeout_ms` — default command timeout; capped at #{@max_timeout_ms}
    * `:shell_env` — extra environment variables for the command, e.g.
      `%{"MIX_ENV" => "test"}`
    * `:max_output_bytes` — default output cap

  The `timeout_ms` and `max_output_bytes` arguments override the environment
  per call.

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
  output never arrives; redirect to a file and read it if you must. On
  POSIX without `pgrep`, a timeout kills only the shell's own process, not
  the whole tree.
  """

  @behaviour DarkChonkyWhale.Tool

  alias DarkChonkyWhale.Tool

  @impl true
  def schema do
    %{
      name: "bash",
      description:
        "Run a shell command (tests, git, a build) in the working directory. " <>
          "POSIX: `bash -c` / `sh -c`; Windows: `cmd.exe /c`. stdout and stderr " <>
          "are merged and stdin is closed. Returns the output, with `exit status N` " <>
          "appended when the command fails; the command is killed after " <>
          "`timeout_ms` (default #{@default_timeout_ms}, capped at #{@max_timeout_ms}) " <>
          "and the output is capped at `max_output_bytes` (head and tail kept).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to run"},
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory. Default: the composition's cwd."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Kill the command after this many ms."
          },
          "max_output_bytes" => %{
            "type" => "integer",
            "description" => "Cap on the output; the middle is elided."
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl true
  def execute(%{"command" => command} = args, env) when is_binary(command) do
    with :ok <- validate(command),
         {:ok, cwd} <- working_dir(args, env),
         {:ok, plan} <- build_plan(env, command, cwd) do
      try do
        exec(plan, cwd, env, timeout_ms(args, env), max_output_bytes(args, env))
      after
        if plan.script, do: File.rm_rf(Path.dirname(plan.script))
      end
    end
  end

  def execute(_args, _env), do: {:error, "command is a required string"}

  ## The call's knobs

  defp validate(command) do
    if String.trim(command) == "" do
      {:error, "command must not be empty"}
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

  ## How the command reaches the shell

  # A plan is what to spawn: the executable, the argument vector, an optional
  # cwd override (the batch-file case), and a temporary script to delete.
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
  # real working directory as its first act.
  defp batch_invocation(exe, base_args, command, cwd) do
    dir = Path.join(System.tmp_dir!(), "dcw-bash-#{System.unique_integer([:positive])}")
    name = "command.cmd"

    case write_batch(Path.join(dir, name), command, cwd) do
      :ok -> {:ok, %{exe: exe, args: base_args ++ [name], cwd: dir, script: Path.join(dir, name)}}
      {:error, message} -> {:error, message}
    end
  end

  defp write_batch(path, command, cwd) do
    # `@echo off` first, or cmd prints every line of the file into the output;
    # the code page is set to UTF-8 so a command line the model wrote in UTF-8
    # is read as itself; then the real working directory is entered. The body
    # is ordinary batch, so `%VAR%` expansion applies as it would in any `.cmd`.
    body =
      "@echo off\r\nchcp 65001 >nul\r\ncd /d \"" <>
        cwd <> "\"\r\n" <> crlf(command) <> "\r\n"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body) do
      :ok
    else
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp crlf(text), do: text |> normalize_eol() |> String.replace("\n", "\r\n")

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

  ## The run

  defp exec(plan, cwd, env, timeout_ms, max_bytes) do
    case open(plan, cwd, env) do
      {:ok, port} -> collect(port, fresh(), deadline(timeout_ms), timeout_ms, max_bytes)
      {:error, message} -> {:error, message}
    end
  end

  defp open(plan, cwd, env) do
    port =
      Port.open({:spawn_executable, plan.exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: Enum.map(plan.args, &to_charlist/1),
        cd: to_charlist(plan.cwd || cwd),
        env: child_env(env)
      ])

    # A port is linked to whoever opened it, and a crashing child must not
    # take the turn down with it.
    Process.unlink(port)
    {:ok, port}
  rescue
    exception -> {:error, "cannot start #{plan.exe}: #{Exception.message(exception)}"}
  end

  # The child gets the parent environment plus the composition's `:shell_env`,
  # spelled out in full: whether the port option replaces the inherited
  # environment or extends it is not worth depending on.
  defp child_env(env) do
    env
    |> Map.get(:shell_env, %{})
    |> Enum.reduce(System.get_env(), fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value))
    end)
    |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  ## Collecting the output

  defp fresh, do: %{head: "", tail: "", total: 0}

  defp collect(port, acc, deadline_at, timeout_ms, max_bytes) do
    remaining = max(deadline_at - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, absorb(acc, data, max_bytes), deadline_at, timeout_ms, max_bytes)

      {^port, {:exit_status, status}} ->
        # The exit message follows the child's last write, but a straggler
        # may still be in flight.
        acc = drain(port, acc, max_bytes, deadline(0))
        close(port)
        flush(port)
        {:ok, render(acc, status)}
    after
      remaining -> timed_out(port, acc, timeout_ms, max_bytes)
    end
  end

  defp timed_out(port, acc, timeout_ms, max_bytes) do
    kill(port)
    # Give the dying process a moment to flush what it already wrote.
    acc = drain(port, acc, max_bytes, deadline(@kill_grace_ms))
    close(port)
    flush(port)

    message = "timed out after #{timeout_ms}ms; the command was killed"
    body = acc |> body() |> String.trim_trailing("\n")

    {:error, if(body == "", do: message, else: message <> "\n" <> body)}
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> kill_os(pid)
      _other -> :ok
    end
  end

  # The child is a plain subprocess, not a session/group leader (`Port.open`
  # spawns with the BEAM's own process group), so `kill -- -pid` would target
  # whatever group happens to share that id — never do that. On Windows
  # `taskkill /T` walks the tree for us; on POSIX the descendants are
  # collected *before* the shell dies (an orphan is reparented and would no
  # longer be found), then the whole set is killed.
  defp kill_os(pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/T", "/PID", Integer.to_string(pid)],
          stderr_to_stdout: true
        )

      _posix ->
        kill_tree(pid)
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp kill_tree(pid) do
    Enum.each([pid | descendants(pid)], &signal/1)
  rescue
    # Enumerating descendants is best-effort; the child itself is not.
    _exception -> signal(pid)
  end

  # `pgrep` is absent on some minimal systems; then only the shell is killed.
  defp descendants(pid) do
    case System.find_executable("pgrep") do
      nil -> []
      _pgrep -> pgrep_children(pid, MapSet.new([pid]), [])
    end
  end

  # Depth-first over the process tree, `seen` guarding against a cycle should
  # one ever appear. Returns the descendant pids, in no particular order.
  defp pgrep_children(pid, seen, acc) do
    Enum.reduce(children_of(pid), {seen, acc}, fn child, {seen, acc} ->
      if MapSet.member?(seen, child) do
        {seen, acc}
      else
        seen = MapSet.put(seen, child)
        {seen, pgrep_children(child, seen, [child | acc])}
      end
    end)
    |> elem(1)
  end

  defp children_of(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.flat_map(&parse_pid/1)
      _other -> []
    end
  end

  defp parse_pid(text) do
    case Integer.parse(String.trim(text)) do
      {pid, ""} -> [pid]
      _other -> []
    end
  end

  defp signal(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _exception -> :ok
  end

  defp drain(port, acc, max_bytes, deadline_at) do
    remaining = max(deadline_at - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> drain(port, absorb(acc, data, max_bytes), max_bytes, deadline_at)
      {^port, {:exit_status, _status}} -> acc
    after
      remaining -> acc
    end
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  # Closing an already-closed port raises; the child may have died on its own
  # between the timeout firing and the kill landing.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  ## The output, capped and scrubbed

  # Keep the first and the last `max_bytes` bytes, counting what fell out of
  # the middle: for a failing build the head says what ran and the tail says
  # what broke.
  defp absorb(acc, data, max_bytes) do
    head_cap = div(max_bytes, 2)
    tail_cap = max_bytes - head_cap

    acc
    |> Map.update!(:total, &(&1 + byte_size(data)))
    |> fill_head(data, head_cap, tail_cap)
  end

  # Fill the head window, then everything past it overflows into the tail.
  defp fill_head(acc, data, head_cap, tail_cap) do
    space = head_cap - byte_size(acc.head)

    cond do
      space <= 0 ->
        push_tail(acc, data, tail_cap)

      byte_size(data) <= space ->
        %{acc | head: acc.head <> data}

      true ->
        <<fill::binary-size(^space), rest::binary>> = data
        push_tail(%{acc | head: acc.head <> fill}, rest, tail_cap)
    end
  end

  defp push_tail(acc, data, tail_cap) do
    combined = acc.tail <> data
    size = byte_size(combined)

    tail =
      if size > tail_cap, do: binary_part(combined, size - tail_cap, tail_cap), else: combined

    %{acc | tail: tail}
  end

  defp body(%{head: "", tail: ""}), do: ""

  defp body(acc) do
    # The head and the tail were kept verbatim; only the elided middle is
    # synthesized. When nothing was dropped the elision is empty and the two
    # halves join with no separator, so the output comes back byte for byte.
    omitted = acc.total - byte_size(acc.head <> acc.tail)
    elision = if omitted > 0, do: elision_marker(omitted, acc.head), else: ""

    (acc.head <> elision <> acc.tail)
    |> normalize_eol()
    |> scrub()
    |> String.trim_trailing("\n")
  end

  # The marker sits on its own line, so it never glues onto the text before it
  # (there is no such text when the head is empty).
  defp elision_marker(omitted, ""), do: "... (#{omitted} bytes omitted) ...\n"
  defp elision_marker(omitted, _head), do: "\n... (#{omitted} bytes omitted) ...\n"

  defp normalize_eol(text), do: String.replace(text, "\r\n", "\n")

  # Tool output is logged as JSON, so it must be valid UTF-8: a stray byte
  # from a binary file becomes U+FFFD instead of an encoding failure. Both
  # error kinds consume one offending byte and carry on — `:incomplete` is not
  # treated as "the end", because the byte stream can be spliced mid-character
  # where the head meets the tail, and stopping there would drop the tail.
  defp scrub(binary), do: binary |> scrub([]) |> IO.iodata_to_binary()

  defp scrub(<<>>, acc), do: Enum.reverse(acc)

  defp scrub(binary, acc) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      converted when is_binary(converted) ->
        Enum.reverse([converted | acc])

      {:incomplete, converted, <<_bad, rest::binary>>} ->
        scrub(rest, ["\uFFFD", converted | acc])

      {:error, converted, <<_bad, rest::binary>>} ->
        scrub(rest, ["\uFFFD", converted | acc])

      {:incomplete, converted, <<>>} ->
        Enum.reverse([converted | acc])

      {:error, converted, <<>>} ->
        Enum.reverse([converted | acc])
    end
  end

  ## Rendering

  defp render(acc, status), do: settle(body(acc), status)

  defp settle("", 0), do: "(no output)"
  defp settle(text, 0), do: text
  defp settle("", status), do: "exit status #{status}"
  defp settle(text, status), do: text <> "\nexit status #{status}"
end
