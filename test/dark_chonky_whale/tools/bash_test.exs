defmodule DarkChonkyWhale.Tools.BashTest do
  use ExUnit.Case, async: true

  alias DarkChonkyWhale.Tools.Bash

  # Shell-language-dependent cases (POSIX syntax, `sleep`, `printf`) are
  # guarded on a POSIX shell being available — the same idiom the search
  # tests use for symlinks, which Windows also cannot promise. `posix?/1` is a
  # plain function, so it cannot stand in a `with` guard; the guard is a
  # plain conditional instead.
  defp posix_shell do
    System.find_executable("bash") || System.find_executable("sh")
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "dcw-bash-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, env: %{cwd: dir}, dir: dir}
  end

  describe "bash" do
    test "runs a command and returns its output", %{env: env} do
      assert {:ok, "hello"} = Bash.execute(%{"command" => "echo hello"}, env)
    end

    test "a failing command is a result, not an error", %{env: env} do
      assert {:ok, output} = Bash.execute(%{"command" => "dcw_no_such_command_xyz"}, env)
      assert output =~ "exit status"
      refute output =~ "exit status 0"
    end

    test "runs in the composition's cwd, or the call's own", %{env: env, dir: dir} do
      assert {:ok, _} = Bash.execute(%{"command" => "echo x>made.txt"}, env)
      assert File.exists?(Path.join(dir, "made.txt"))

      assert {:ok, _} = Bash.execute(%{"command" => "echo x>made.txt", "cwd" => "sub"}, env)
      assert File.exists?(Path.join(dir, "sub/made.txt"))
    end

    test "refuses empty commands, bad cwds and missing shells", %{env: env} do
      assert {:error, "command is a required string"} = Bash.execute(%{}, env)
      assert {:error, "command must not be empty"} = Bash.execute(%{"command" => "  "}, env)

      assert {:error, "not a directory: " <> _} =
               Bash.execute(%{"command" => "echo hi", "cwd" => "nope"}, env)

      env = Map.put(env, :shell, "dcw_no_such_shell_xyz")

      assert {:error, "shell not found: dcw_no_such_shell_xyz"} =
               Bash.execute(%{"command" => "x"}, env)
    end

    test "an explicit shell and shell_env are honored", %{env: env} do
      if sh = posix_shell() do
        env =
          env
          |> Map.put(:shell, {sh, ["-c"]})
          |> Map.put(:shell_env, %{"DCW_TEST_VAR" => "from-env"})

        assert {:ok, "from-env"} = Bash.execute(%{"command" => "echo $DCW_TEST_VAR"}, env)

        # A sloppy numeric argument must not crash the call.
        assert {:ok, "hello"} =
                 Bash.execute(%{"command" => "echo hello", "timeout_ms" => "soon"}, env)
      end
    end

    test "closes stdin, so a command reading it does not hang", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})
        started = System.monotonic_time(:millisecond)

        assert {:ok, output} = Bash.execute(%{"command" => "cat", "timeout_ms" => 10_000}, env)

        assert output == "(no output)"
        assert System.monotonic_time(:millisecond) - started < 10_000
      end
    end

    test "kills a command that outlives its timeout, keeping what it printed", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})
        started = System.monotonic_time(:millisecond)

        assert {:error, message} =
                 Bash.execute(%{"command" => "echo before; sleep 30", "timeout_ms" => 300}, env)

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
                 Bash.execute(%{"command" => command, "max_output_bytes" => 200}, env)

        assert output =~ "bytes omitted"
        assert output =~ "line-0"
        assert output =~ "line-1999"
        assert byte_size(output) < 1_000
      end
    end

    test "scrubs bytes that are not valid UTF-8", %{env: env} do
      if sh = posix_shell() do
        env = Map.put(env, :shell, {sh, ["-c"]})

        assert {:ok, output} = Bash.execute(%{"command" => "printf 'a\\377b'"}, env)
        assert output == "a\uFFFDb"
        assert String.valid?(output)
      end
    end
  end
end
