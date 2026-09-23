defmodule DarkChonkyWhale.Tools.ReadWriteTest do
  use ExUnit.Case, async: true

  alias DarkChonkyWhale.Tools.{Read, Write}

  setup do
    dir = Path.join(System.tmp_dir!(), "dcw-rw-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, env: %{cwd: dir}, dir: dir}
  end

  describe "write" do
    test "creates parent directories and writes content", %{env: env, dir: dir} do
      assert {:ok, result} =
               Write.execute(%{"file_path" => "a/b/c.txt", "content" => "x\ny"}, env)

      assert result =~ "wrote 2 lines"
      assert File.read!(Path.join(dir, "a/b/c.txt")) == "x\ny"
    end

    test "overwrites an existing file", %{env: env, dir: dir} do
      path = Path.join(dir, "f.txt")
      File.write!(path, "old")

      assert {:ok, _} = Write.execute(%{"file_path" => "f.txt", "content" => "new"}, env)
      assert File.read!(path) == "new"
    end

    test "accepts absolute paths", %{env: env, dir: dir} do
      path = Path.join(dir, "abs.txt")
      assert {:ok, _} = Write.execute(%{"file_path" => path, "content" => "abs"}, env)
      assert File.read!(path) == "abs"
    end
  end

  describe "read" do
    test "numbers lines", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "n.txt"), "one\ntwo\nthree")

      assert {:ok, "1\tone\n2\ttwo\n3\tthree"} =
               Read.execute(%{"file_path" => "n.txt"}, env)
    end

    test "pages with offset and limit, noting what was shown", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "p.txt"), Enum.map_join(1..10, "\n", &"line#{&1}"))

      assert {:ok, result} =
               Read.execute(%{"file_path" => "p.txt", "offset" => 3, "limit" => 2}, env)

      assert result == "3\tline3\n4\tline4\n... (10 lines total, showing 3-4)"
    end

    test "a non-UTF-8 (e.g. GBK) file reads with replacement chars", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "gbk.txt"), <<186, 72, 10, 76, 97, 10>>)

      assert {:ok, text} = Read.execute(%{"file_path" => "gbk.txt"}, env)
      assert String.valid?(text)
      refute text =~ <<186>>
      assert text =~ "La"
    end

    test "empty file, missing file, and past-the-end offset are plain answers", %{
      env: env,
      dir: dir
    } do
      File.write!(Path.join(dir, "e.txt"), "")
      File.write!(Path.join(dir, "n.txt"), "one\ntwo")

      assert {:ok, "(empty file)"} = Read.execute(%{"file_path" => "e.txt"}, env)
      assert {:error, message} = Read.execute(%{"file_path" => "missing.txt"}, env)
      assert message =~ "file not found"
      assert {:ok, result} = Read.execute(%{"file_path" => "n.txt", "offset" => 99}, env)
      assert result =~ "past the end"
    end
  end
end
