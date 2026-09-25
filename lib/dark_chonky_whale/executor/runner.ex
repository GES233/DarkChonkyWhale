defmodule DarkChonkyWhale.Executor.Runner do
  # Defined ahead of the moduledoc, which reads them.
  @kill_grace_ms 200

  @moduledoc """
  The port executor: given a *plan* — what to spawn — run it as a local
  subprocess and collect its output.

  This is the executor side of the `execute` tool's seam. Deciding what to
  spawn is each runtime's business (see `DarkChonkyWhale.Executor.Runtimes`);
  how it runs lives here, once. A composition that needs code to run
  elsewhere — WSL, over SSH, inside a sandbox — should be able to replace
  this module without touching the runtimes or the tool surface.

  stdout and stderr are merged. A settled process is a *result*, not an
  error: its output comes back, with `exit status N` appended when the
  process failed, so a failing test run reads like any other answer instead
  of a broken tool. Only a process that outlives its timeout is an error —
  it is killed (the whole tree: `taskkill /T` on Windows, a `pgrep` walk on
  POSIX) and what it printed so far is reported — so a wedged process
  (waiting on a prompt, serving a port) cannot wedge the turn.

  Output is capped: the head and the tail are kept and the middle is
  replaced by a byte count, so one runaway process cannot flood the session
  log. Output is expected to be UTF-8; on Windows, bytes that are not are
  transcoded from the OEM codepage (`chcp`'s answer — CP936 on a zh-CN
  machine), and only bytes no interpretation accepts become U+FFFD — tool
  output is persisted as JSON, which would refuse invalid bytes outright.
  """

  @typedoc """
  What to spawn: the executable, the argument vector, an optional cwd
  override (the cmd batch-file case), and a temporary script whose directory
  is deleted after the run.
  """
  @type plan :: %{
          exe: String.t(),
          args: [String.t()],
          cwd: String.t() | nil,
          script: String.t() | nil
        }

  @doc """
  Run a plan and collect its output.

  The context carries the working directory (`:cwd`), the tool environment
  (`:env` — its `:shell_env` is spelled out to the child in full), the
  `:timeout_ms` after which the process tree is killed, and the
  `:max_output_bytes` cap on the output.
  """
  @spec run(plan(), %{
          cwd: String.t(),
          env: map(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer()
        }) :: {:ok, String.t()} | {:error, String.t()}
  def run(plan, ctx) do
    try do
      exec(plan, ctx.cwd, ctx.env, ctx.timeout_ms, ctx.max_output_bytes)
    after
      if plan.script, do: File.rm_rf(Path.dirname(plan.script))
    end
  end

  @doc """
  Cap an already-collected output binary the way a port run's output is
  capped: head and tail kept, the middle replaced by a byte count, line
  endings normalized and the result decoded to valid UTF-8. A runtime with
  no port to collect from (the in-process Elixir runtime) reuses the same
  output policy through this.
  """
  @spec cap_output(binary(), pos_integer()) :: String.t()
  def cap_output(binary, max_bytes) when is_binary(binary) do
    fresh() |> absorb(binary, max_bytes) |> body()
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
        # Windows-only, ignored on POSIX: without :hide a .NET console child
        # (pwsh, powershell) attaches to the BEAM's console and writes there
        # instead of the pipe, so the port would collect nothing.
        :hide,
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
    |> decode()
    |> String.trim_trailing("\n")
  end

  # The marker sits on its own line, so it never glues onto the text before it
  # (there is no such text when the head is empty).
  defp elision_marker(omitted, ""), do: "... (#{omitted} bytes omitted) ...\n"
  defp elision_marker(omitted, _head), do: "\n... (#{omitted} bytes omitted) ...\n"

  defp normalize_eol(text), do: String.replace(text, "\r\n", "\n")

  # Tool output is persisted as JSON, so it must be valid UTF-8 — but a
  # console program does not necessarily write UTF-8: on Windows it writes
  # in the OEM codepage (`chcp`'s answer; CP936 on a zh-CN machine, CP437
  # on a Western one). Valid UTF-8 passes through untouched; anything else
  # is transcoded from the system codepage when one is known, and only
  # bytes that no interpretation accepts become U+FFFD.
  defp decode(binary), do: decode_as(binary, fallback_encoding())

  @doc false
  # The decoding decision with the codepage given explicitly — kept public
  # so the test suite can exercise pages this machine does not use.
  def decode_as(binary, encoding) do
    if String.valid?(binary), do: binary, else: transcode(binary, encoding)
  end

  defp transcode(binary, nil), do: scrub(binary)

  defp transcode(binary, encoding) do
    # use_utf_replacement replaces a byte no mapping accepts with U+FFFD
    # and carries on, so this never fails.
    Codepagex.to_string!(binary, encoding, Codepagex.use_utf_replacement())
  end

  # The fallback is the OEM codepage, asked of `chcp` once and cached. POSIX
  # locales other than UTF-8 are legacy enough that scrubbing is the honest
  # answer there.
  defp fallback_encoding do
    case :os.type() do
      {:win32, _} -> cached(:codepage, &detect_codepage/0)
      _posix -> nil
    end
  end

  defp cached(key, fun) do
    case :persistent_term.get({__MODULE__, key}, :unknown) do
      :unknown ->
        value = fun.()
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  # `chcp` prints the active code page, localized ("Active code page: 936" /
  # "活动代码页: 936") — the digits are the reliable part. A page with no
  # compiled table (65001/UTF-8 among them) means no transcoding.
  defp detect_codepage do
    with exe when is_binary(exe) <-
           System.find_executable("chcp.com") || System.find_executable("chcp"),
         {output, 0} <- System.cmd(exe, [], stderr_to_stdout: true),
         [digits] <- Regex.run(~r/\d+/, output),
         {number, ""} <- Integer.parse(digits) do
      codepage_name(number)
    else
      _other -> nil
    end
  rescue
    _exception -> nil
  end

  defp codepage_name(number) do
    Enum.find(
      ["VENDORS/MICSFT/WINDOWS/CP#{number}", "VENDORS/MICSFT/PC/CP#{number}"],
      &(&1 in compiled_codepages())
    )
  end

  defp compiled_codepages, do: cached(:codepages, &Codepagex.encoding_list/0)

  # The last resort for bytes no interpretation accepts. Both error kinds
  # consume one offending byte and carry on — `:incomplete` is not treated
  # as "the end", because the byte stream can be spliced mid-character where
  # the head meets the tail, and stopping there would drop the tail.
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
