defmodule DarkChonkyWhale.Executor.Runtimes.Python do
  @moduledoc """
  The Python runtime: run `code` as a `.py` script through `python3`, or
  `python` where that is the name (Windows, some venvs).

  The code is written to a temporary script rather than passed via `-c`, so
  its quoting survives untouched. The child gets `PYTHONIOENCODING=utf-8`:
  Python otherwise writes stdout in the locale's encoding (on Windows, the
  OEM codepage), while the runner's decoding pipeline expects UTF-8. A
  composition's own `:shell_env` wins over the pin.

  The `:python` environment overrides the selection: the program (name or
  path), or `{program, args}` where `args` precede the script.
  """

  @behaviour DarkChonkyWhale.Executor.Runtime

  alias DarkChonkyWhale.Executor.Runner

  @impl true
  def run(code, ctx) do
    with {:ok, {program, base_args}} <- python(ctx.env),
         {:ok, exe} <- executable(program),
         {:ok, plan} <- script_invocation(exe, base_args, code) do
      Runner.run(plan, utf8_env(ctx))
    end
  end

  defp python(env) do
    case Map.get(env, :python) do
      nil ->
        case System.find_executable("python3") || System.find_executable("python") do
          nil -> {:error, "python not found: neither python3 nor python is on PATH"}
          path -> {:ok, {path, []}}
        end

      {program, args} when is_binary(program) and is_list(args) ->
        {:ok, {program, args}}

      program when is_binary(program) ->
        {:ok, {program, []}}
    end
  end

  defp script_invocation(exe, base_args, code) do
    dir = Path.join(System.tmp_dir!(), "dcw-py-#{System.unique_integer([:positive])}")
    script = Path.join(dir, "script.py")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(script, code) do
      {:ok, %{exe: exe, args: base_args ++ [script], cwd: nil, script: script}}
    else
      {:error, reason} -> {:error, "cannot write #{script}: #{:file.format_error(reason)}"}
    end
  end

  # The composition's :shell_env wins over the pin (Map.put_new), so a
  # deliberate PYTHONIOENCODING there is honored.
  defp utf8_env(ctx) do
    shell_env =
      ctx.env
      |> Map.get(:shell_env, %{})
      |> Map.put_new("PYTHONIOENCODING", "utf-8")

    %{ctx | env: Map.put(ctx.env, :shell_env, shell_env)}
  end

  defp executable(program) do
    case System.find_executable(program) do
      nil -> {:error, "python not found: #{program}"}
      path -> {:ok, path}
    end
  end
end
