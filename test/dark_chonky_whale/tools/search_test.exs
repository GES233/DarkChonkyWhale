defmodule DarkChonkyWhale.Tools.SearchTest do
  use ExUnit.Case, async: true

  alias DarkChonkyWhale.Tools.{Glob, Grep, Walk}

  setup do
    dir = Path.join(System.tmp_dir!(), "dcw-search-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    write = fn path, content ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      full
    end

    write.("lib/a.ex", "defmodule A do\n  # alpha\nend\n")
    write.("lib/nested/b.ex", "defmodule B do\n  # Beta\nend\n")
    write.("lib/notes.txt", "alpha delta\n")
    write.("deps/vendored/c.ex", "defmodule C do\n  # alpha\nend\n")
    write.("_build/dev/ignore.ex", "alpha\n")
    write.("bin/data.bin", <<0, 1, 2, 3, 0>>)

    env = %{cwd: dir, search_ignore_dirs: ["deps", "_build"]}
    {:ok, dir: dir, env: env}
  end

  describe "Walk" do
    test "walks in deterministic path order, pruning ignored directories", %{dir: dir, env: env} do
      files = Walk.files(dir, env)

      assert files == Enum.sort(files)

      assert Enum.map(files, &Walk.relative(&1, dir)) == [
               "bin/data.bin",
               "lib/a.ex",
               "lib/nested/b.ex",
               "lib/notes.txt"
             ]

      refute Enum.any?(files, &String.contains?(&1, "deps"))
      refute Enum.any?(files, &String.contains?(&1, "_build"))
    end

    test "prunes nothing when the ignore list is emptied", %{dir: dir} do
      files = Walk.files(dir, %{search_ignore_dirs: []})
      assert length(files) == 6
    end

    test "does not follow symlinked directory loops", %{dir: dir, env: env} do
      # Symlink creation needs privileges on Windows; without it the
      # walk-loop guarantee is simply untested here.
      with :ok <- File.ln_s(dir, Path.join(dir, "lib/loop")) do
        assert length(Walk.files(dir, env)) == 4
      end
    end

    test "relative/2 reports /-separated paths and slash/1 normalizes", %{dir: dir} do
      assert "lib/nested/b.ex" == Walk.relative(Path.join([dir, "lib", "nested", "b.ex"]), dir)
      assert "lib/a.ex" == Walk.slash(Path.join(["lib", "a.ex"]))
    end

    test "glob compilation supports *, ? and **, escaping literals" do
      assert Regex.match?(Walk.compile_glob("**/*.ex"), "lib/a.ex")
      assert Regex.match?(Walk.compile_glob("**/*.ex"), "lib/nested/b.ex")
      refute Regex.match?(Walk.compile_glob("**/*.ex"), "lib/notes.txt")

      assert Regex.match?(Walk.compile_glob("a?.ex"), "ab.ex")
      refute Regex.match?(Walk.compile_glob("a?.ex"), "a/b.ex")

      assert Regex.match?(Walk.compile_glob("*.ex"), "a.ex")
      refute Regex.match?(Walk.compile_glob("*.ex"), "lib/a.ex")
      refute Regex.match?(Walk.compile_glob("a.ex"), "axex")
    end
  end

  describe "glob" do
    test "finds files by pattern, paths relative to the cwd", %{env: env} do
      assert {:ok, "lib/a.ex\nlib/nested/b.ex"} = Glob.execute(%{"pattern" => "**/*.ex"}, env)
    end

    test "a path without / matches the file name at any depth", %{env: env} do
      assert {:ok, "lib/nested/b.ex"} = Glob.execute(%{"pattern" => "b.ex"}, env)
      assert {:ok, "lib/notes.txt"} = Glob.execute(%{"pattern" => "notes.txt"}, env)
    end

    test "honors an explicit path and a limit; paths are cwd-relative", %{env: env} do
      assert {:ok, "lib/a.ex\nlib/nested/b.ex"} =
               Glob.execute(%{"pattern" => "**/*.ex", "path" => "lib"}, env)

      assert {:ok, capped} = Glob.execute(%{"pattern" => "**/*", "limit" => 2}, env)
      assert capped =~ "... (4 matches in "
      assert capped =~ "showing 2)"
    end

    test "reports no matches and bad directories", %{env: env} do
      assert {:ok, "(no files matched in " <> _} = Glob.execute(%{"pattern" => "*.rs"}, env)

      assert {:error, "directory not found: " <> _} =
               Glob.execute(%{"pattern" => "*", "path" => "nope"}, env)

      assert {:error, "not a directory: " <> _} =
               Glob.execute(%{"pattern" => "*", "path" => "lib/a.ex"}, env)

      assert {:error, "pattern is a required string"} = Glob.execute(%{}, env)
    end
  end

  describe "grep" do
    test "finds matching lines as path:line:text, pruning ignored dirs", %{env: env} do
      assert {:ok, "lib/a.ex:2:  # alpha\nlib/notes.txt:1:alpha delta"} =
               Grep.execute(%{"pattern" => "alpha"}, env)
    end

    test "options make the search case-insensitive", %{env: env} do
      assert {:ok, "(no matches in " <> _} = Grep.execute(%{"pattern" => "beta"}, env)

      assert {:ok, "lib/nested/b.ex:2:  # Beta"} =
               Grep.execute(%{"pattern" => "beta", "options" => "i"}, env)
    end

    test "searches a single file and reports no matches", %{env: env} do
      assert {:ok, "lib/a.ex:1:defmodule A do"} =
               Grep.execute(%{"pattern" => "defmodule", "path" => "lib/a.ex"}, env)

      assert {:ok, "(no matches in " <> _} = Grep.execute(%{"pattern" => "zeta"}, env)
    end

    test "skips binary files", %{env: env} do
      assert {:ok, "(no matches in " <> _} =
               Grep.execute(%{"pattern" => ".", "path" => "bin/data.bin"}, env)
    end

    test "skips files over max_file_bytes", %{env: env} do
      assert {:ok, "(no matches in " <> _} =
               Grep.execute(%{"pattern" => "alpha", "max_file_bytes" => 3}, env)

      assert {:ok, _} = Grep.execute(%{"pattern" => "alpha", "max_file_bytes" => 10_000}, env)
    end

    test "caps the output at the limit", %{env: env} do
      assert {:ok, output} = Grep.execute(%{"pattern" => "alpha", "limit" => 1}, env)
      assert output == "lib/a.ex:2:  # alpha\n... (capped at 1 matching lines)"
    end

    test "truncates long lines", %{env: env} do
      File.write!(Path.join(env.cwd, "lib/long.txt"), String.duplicate("x", 50) <> " needle")

      assert {:ok, "lib/long.txt:1:xxxxxxxxxx..."} =
               Grep.execute(%{"pattern" => "needle", "max_line_chars" => 10}, env)
    end

    test "surfaces bad patterns and bad paths as errors", %{env: env} do
      assert {:error, "invalid pattern: " <> _} = Grep.execute(%{"pattern" => "("}, env)

      assert {:error, "path not found: " <> _} =
               Grep.execute(%{"pattern" => "a", "path" => "nope"}, env)

      assert {:error, "options must be a string" <> _} =
               Grep.execute(%{"pattern" => "a", "options" => 5}, env)

      assert {:error, "pattern is a required string"} = Grep.execute(%{}, env)
    end
  end
end
