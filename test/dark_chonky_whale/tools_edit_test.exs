defmodule DarkChonkyWhale.Tools.EditTest do
  use ExUnit.Case, async: true

  alias DarkChonkyWhale.Tools.Edit

  setup do
    dir = Path.join(System.tmp_dir!(), "dcw-edit-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, env: %{cwd: dir}, dir: dir}
  end

  defp write(path, content), do: File.write!(path, content)

  defp edit(env, file, old, new) do
    Edit.execute(%{"file_path" => file, "old_string" => old, "new_string" => new}, env)
  end

  test "plain LF replace", %{env: env, dir: dir} do
    path = Path.join(dir, "a.txt")
    write(path, "one\ntwo\nthree\n")

    assert {:ok, result} = edit(env, "a.txt", "two", "TWO")
    assert result == "edited #{path}"
    assert File.read!(path) == "one\nTWO\nthree\n"
  end

  test "CRLF file: LF old_string matches, file stays CRLF byte for byte", %{env: env, dir: dir} do
    path = Path.join(dir, "win.txt")
    write(path, "one\r\ntwo\r\nthree\r\n")

    assert {:ok, result} = edit(env, "win.txt", "one\ntwo", "ONE\nTWO")
    assert result =~ "CRLF preserved"

    # The untouched tail keeps its CRLF endings; nothing is double-converted.
    assert File.read!(path) == "ONE\r\nTWO\r\nthree\r\n"
  end

  test "BOM and missing trailing newline are preserved", %{env: env, dir: dir} do
    path = Path.join(dir, "bom.txt")
    write(path, "\xEF\xBB\xBF" <> "one\r\ntwo")

    assert {:ok, _} = edit(env, "bom.txt", "two", "TWO")
    assert File.read!(path) == "\xEF\xBB\xBF" <> "one\r\nTWO"
  end

  test "mixed endings normalize to the dominant convention, with a note", %{env: env, dir: dir} do
    path = Path.join(dir, "mixed.txt")
    write(path, "a\r\nb\r\nc\nd\r\n")

    assert {:ok, result} = edit(env, "mixed.txt", "b", "B")
    assert result =~ "mixed line endings normalized to CRLF"
    assert File.read!(path) == "a\r\nB\r\nc\r\nd\r\n"
  end

  test "not found and not unique are plain errors", %{env: env, dir: dir} do
    path = Path.join(dir, "a.txt")
    write(path, "same\nsame\n")

    assert {:error, message} = edit(env, "a.txt", "missing", "x")
    assert message =~ "not found"

    assert {:error, message} = edit(env, "a.txt", "same", "x")
    assert message =~ "2 times"

    assert File.read!(path) == "same\nsame\n"
  end

  test "fuzzy fallback: trailing whitespace ignored, rest of file untouched", %{
    env: env,
    dir: dir
  } do
    path = Path.join(dir, "ws.txt")
    write(path, "keep\ntarget   \nkeep2\n")

    # The model's old_string omits the file's trailing spaces *within* the
    # matched lines — a single-line "target" would exact-match as a
    # substring, so the mismatch has to cross a line boundary to be fuzzy.
    assert {:ok, result} = edit(env, "ws.txt", "target\nkeep2", "done\ndone2")
    assert result =~ "ignoring trailing whitespace"

    # The matched lines are replaced; everything else byte-identical.
    assert File.read!(path) == "keep\ndone\ndone2\n"
  end

  test "bad calls are errors, not crashes", %{env: env, dir: dir} do
    path = Path.join(dir, "a.txt")
    write(path, "x\n")

    assert {:error, message} = edit(env, "a.txt", "", "y")
    assert message =~ "must not be empty"
    assert {:error, message} = edit(env, "a.txt", "x", "x")
    assert message =~ "identical"
    assert {:error, message} = Edit.execute(%{"file_path" => "a.txt"}, env)
    assert message =~ "required"
    assert {:error, message} = edit(env, "missing.txt", "x", "y")
    assert message =~ "file not found"
  end
end
