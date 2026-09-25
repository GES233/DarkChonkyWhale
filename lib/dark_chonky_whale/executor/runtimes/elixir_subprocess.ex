defmodule DarkChonkyWhale.Executor.Runtimes.ElixirSubprocess do
  @moduledoc """
  The Elixir subprocess runtime: run `code` as an `.exs` script through the
  `elixir` CLI, in a fresh VM.

  This is Elixir on the same isolated pipeline as the other runtimes: the
  script sees the filesystem and the composition's cwd but nothing of the
  agent's own BEAM. For code that should see the live system, use the
  in-process Elixir runtime instead.

  The `:elixir` environment overrides the program: a name or path, or
  `{program, args}` where `args` precede the script.
  """

  @behaviour DarkChonkyWhale.Executor.Runtime

  alias DarkChonkyWhale.Executor.Runner

  @impl true
  def run(code, ctx) do
    with {:ok, {program, base_args}} <- elixir(ctx.env),
         {:ok, exe} <- executable(program),
         {:ok, plan} <- script_invocation(exe, base_args, code) do
      Runner.run(plan, ctx)
    end
  end

  defp elixir(env) do
    case Map.get(env, :elixir) do
      nil -> {:ok, {"elixir", []}}
      {program, args} when is_binary(program) and is_list(args) -> {:ok, {program, args}}
      program when is_binary(program) -> {:ok, {program, []}}
    end
  end

  defp script_invocation(exe, base_args, code) do
    dir = Path.join(System.tmp_dir!(), "dcw-exs-#{System.unique_integer([:positive])}")
    script = Path.join(dir, "script.exs")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(script, code) do
      {:ok, %{exe: exe, args: base_args ++ [script], cwd: nil, script: script}}
    else
      {:error, reason} -> {:error, "cannot write #{script}: #{:file.format_error(reason)}"}
    end
  end

  defp executable(program) do
    case System.find_executable(program) do
      nil -> {:error, "elixir not found: #{program}"}
      path -> {:ok, path}
    end
  end
end
