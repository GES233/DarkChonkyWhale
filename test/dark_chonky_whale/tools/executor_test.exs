defmodule DarkChonkyWhale.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias DarkChonkyWhale.Executor.Runner
  alias DarkChonkyWhale.Tools.Executor

  # Known byte sequences for the decoding tests: "中文" in CP936 (GBK) and
  # "日本語" in CP932 (Shift-JIS), verified against iconv.
  @gbk_bytes <<0xD6, 0xD0, 0xCE, 0xC4>>
  @sjis_bytes <<0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA>>
  # Shell-language-dependent cases (POSIX syntax, `sleep`, `printf`) are
  # guarded on a POSIX shell being available — the same idiom the search
  # tests use for symlinks, which Windows also cannot promise. The lookup
  # mirrors the shell runtime's own discovery: a `bash.exe` under
  # %SystemRoot% is the WSL launcher, not a shell for this universe — it
  # runs the command where none of the assertions apply and lets none of
  # its output back.
  defp posix_shell do
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

  # The same availability guards for the other runtimes, mirroring each
  # runtime's own discovery order.
  defp powershell, do: System.find_executable("pwsh") || System.find_executable("powershell")
  defp python, do: System.find_executable("python3") || System.find_executable("python")

  setup do
    dir = Path.join(System.tmp_dir!(), "dcw-executor-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, env: %{cwd: dir}, dir: dir}
  end

  # The test's own reading of the OEM codepage — deliberately not the
  # runner's, so a wrong answer on either side shows up as a failure instead
  # of the two agreeing.
  defp oem_codepage do
    with {:win32, _} <- :os.type(),
         exe when is_binary(exe) <- System.find_executable("chcp.com"),
         {output, 0} <- System.cmd(exe, [], stderr_to_stdout: true),
         [digits] <- Regex.run(~r/\d+/, output),
         {number, ""} <- Integer.parse(digits) do
      number
    else
      _other -> nil
    end
  end

  describe "output decoding" do
    test "valid UTF-8 passes through even under a legacy codepage" do
      assert Runner.decode_as("héllo 中文", "VENDORS/MICSFT/WINDOWS/CP936") == "héllo 中文"
    end

    test "GBK bytes transcode to UTF-8" do
      assert Runner.decode_as(@gbk_bytes, "VENDORS/MICSFT/WINDOWS/CP936") == "中文"
    end

    test "Shift-JIS bytes transcode to UTF-8" do
      assert Runner.decode_as(@sjis_bytes, "VENDORS/MICSFT/WINDOWS/CP932") == "日本語"
    end

    test "bytes no interpretation accepts become U+FFFD" do
      # 0xFF is neither a valid lead nor a valid trail byte in CP936.
      assert Runner.decode_as(<<"a", 0xFF, "b">>, "VENDORS/MICSFT/WINDOWS/CP936") == "a\uFFFDb"
      assert Runner.decode_as(<<"a", 0xFF, "b">>, nil) == "a\uFFFDb"
    end

    test "shell output in the OEM codepage comes back as UTF-8", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})
        # printf's octal escapes emit the raw GBK bytes of "中文".
        assert {:ok, output} = Executor.execute(%{"code" => ~S(printf '\326\320\316\304')}, env)
        assert String.valid?(output)

        case oem_codepage() do
          # The runner should have transcoded what printf emitted.
          936 -> assert output == "中文"
          # POSIX (or an unreadable codepage): each stray byte is scrubbed.
          _other -> assert output == String.duplicate("\uFFFD", 4)
        end
      end
    end
  end

  describe "shell runtime (the default)" do
    test "runs a command and returns its output", %{env: env} do
      assert {:ok, "hello"} = Executor.execute(%{"code" => "echo hello"}, env)
    end

    test "a keyword-list env is accepted, as direct callers write one", %{env: env, dir: dir} do
      assert {:ok, "hello"} = Executor.execute(%{"code" => "echo hello"}, cwd: dir)
      assert {:ok, _} = Executor.execute(%{"code" => "echo x>kw.txt"}, cwd: dir)
      assert File.exists?(Path.join(dir, "kw.txt"))
      # A sloppy keyword value falls back the same way a sloppy map value does.
      env = env |> Map.put(:shell_timeout_ms, -1) |> Map.to_list()
      assert {:ok, "hello"} = Executor.execute(%{"code" => "echo hello"}, env)
    end

    test "a failing command is a result, not an error", %{env: env} do
      assert {:ok, output} = Executor.execute(%{"code" => "dcw_no_such_command_xyz"}, env)
      assert output =~ "exit status"
      refute output =~ "exit status 0"
    end

    test "runs in the composition's cwd, or the call's own", %{env: env, dir: dir} do
      assert {:ok, _} = Executor.execute(%{"code" => "echo x>made.txt"}, env)
      assert File.exists?(Path.join(dir, "made.txt"))

      assert {:ok, _} = Executor.execute(%{"code" => "echo x>made.txt", "cwd" => "sub"}, env)
      assert File.exists?(Path.join(dir, "sub/made.txt"))
    end

    test "refuses empty code, bad cwds, unknown runtimes and missing shells", %{env: env} do
      assert {:error, "code is a required string"} = Executor.execute(%{}, env)
      assert {:error, "code must not be empty"} = Executor.execute(%{"code" => "  "}, env)

      assert {:error, "not a directory: " <> _} =
               Executor.execute(%{"code" => "echo hi", "cwd" => "nope"}, env)

      assert {:error, "unknown runtime: " <> _} =
               Executor.execute(%{"code" => "x", "runtime" => "cobol"}, env)

      env = Map.put(env, :shell, "dcw_no_such_shell_xyz")

      assert {:error, "shell not found: dcw_no_such_shell_xyz"} =
               Executor.execute(%{"code" => "x"}, env)
    end

    test "an explicit shell and shell_env are honored", %{env: env} do
      if sh = posix_shell() do
        env =
          env
          |> Map.put(:shell, {sh, ["-c"]})
          |> Map.put(:shell_env, %{"DCW_TEST_VAR" => "from-env"})

        assert {:ok, "from-env"} = Executor.execute(%{"code" => "echo $DCW_TEST_VAR"}, env)

        # A sloppy numeric argument must not crash the call.
        assert {:ok, "hello"} =
                 Executor.execute(%{"code" => "echo hello", "timeout_ms" => "soon"}, env)
      end
    end

    test "closes stdin, so a command reading it does not hang", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})
        started = System.monotonic_time(:millisecond)

        assert {:ok, output} = Executor.execute(%{"code" => "cat", "timeout_ms" => 10_000}, env)

        assert output == "(no output)"
        assert System.monotonic_time(:millisecond) - started < 10_000
      end
    end

    test "kills a command that outlives its timeout, keeping what it printed", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})
        started = System.monotonic_time(:millisecond)

        assert {:error, message} =
                 Executor.execute(
                   %{"code" => "echo before; sleep 30", "timeout_ms" => 300},
                   env
                 )

        assert message =~ "timed out after 300ms"
        assert message =~ "before"
        assert System.monotonic_time(:millisecond) - started < 10_000
      end
    end

    test "caps the output, keeping the head and the tail", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})

        command = "i=0; while [ $i -lt 2000 ]; do echo line-$i; i=$((i+1)); done"

        assert {:ok, output} =
                 Executor.execute(%{"code" => command, "max_output_bytes" => 200}, env)

        assert output =~ "bytes omitted"
        assert output =~ "line-0"
        assert output =~ "line-1999"
        assert byte_size(output) < 1_000
      end
    end

    test "invalid UTF-8 never escapes; its reading depends on the codepage", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})

        assert {:ok, output} = Executor.execute(%{"code" => "printf 'a\\377b'"}, env)
        assert String.valid?(output)

        case oem_codepage() do
          # 0xFF is unmappable in CP936, and there is no codepage on POSIX.
          page when page in [936, nil] -> assert output == "a\uFFFDb"
          # …but it is ÿ in the Western ANSI page.
          1252 -> assert output == "aÿb"
          _other -> assert output =~ ~r/\Aa.\z/s
        end
      end
    end
  end

  describe "powershell runtime" do
    test "runs a script and returns its output", %{env: env} do
      if powershell() do
        assert {:ok, "hello"} =
                 Executor.execute(
                   %{"runtime" => "powershell", "code" => "Write-Output hello"},
                   env
                 )
      end
    end

    test "a failing script is a result, not an error", %{env: env} do
      if powershell() do
        assert {:ok, output} =
                 Executor.execute(
                   %{"runtime" => "powershell", "code" => "Write-Output oops; exit 3"},
                   env
                 )

        assert output =~ "oops"
        assert output =~ "exit status 3"
      end
    end
  end

  describe "python runtime" do
    test "runs a script and returns its output", %{env: env} do
      if python() do
        assert {:ok, "hello"} =
                 Executor.execute(%{"runtime" => "python", "code" => "print('hello')"}, env)
      end
    end

    test "a failing script is a result, not an error", %{env: env} do
      if python() do
        assert {:ok, output} =
                 Executor.execute(
                   %{
                     "runtime" => "python",
                     "code" => "import sys\nprint('oops')\nsys.exit(3)"
                   },
                   env
                 )

        assert output =~ "oops"
        assert output =~ "exit status 3"
      end
    end
  end

  describe "elixir_subprocess runtime" do
    test "evaluates a script in a fresh VM", %{env: env} do
      if System.find_executable("elixir") do
        assert {:ok, "2"} =
                 Executor.execute(
                   %{"runtime" => "elixir_subprocess", "code" => "IO.puts(1 + 1)"},
                   env
                 )
      end
    end
  end

  describe "in-process elixir runtime" do
    test "renders the return value", %{env: env} do
      assert {:ok, "2"} = Executor.execute(%{"runtime" => "elixir", "code" => "1 + 1"}, env)
    end

    test "captures IO.puts output ahead of the return value", %{env: env} do
      assert {:ok, "hello\n:ok"} =
               Executor.execute(%{"runtime" => "elixir", "code" => ~s|IO.puts("hello")|}, env)
    end

    test "kills an evaluation that outlives its timeout", %{env: env} do
      started = System.monotonic_time(:millisecond)

      assert {:error, message} =
               Executor.execute(
                 %{"runtime" => "elixir", "code" => "Process.sleep(30_000)", "timeout_ms" => 300},
                 env
               )

      assert message =~ "timed out after 300ms"
      assert System.monotonic_time(:millisecond) - started < 10_000
    end

    test "a raised exception is an error, not a crash", %{env: env} do
      assert {:error, message} =
               Executor.execute(%{"runtime" => "elixir", "code" => ~s|raise "boom"|}, env)

      assert message =~ "boom"
    end
  end
end
