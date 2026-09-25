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
         {:ok, exe} <- executable(program) do
      Runner.run(script_plan(exe, base_args, code), ctx)
    end
  end

  defp elixir(env) do
    case Map.get(env, :elixir) do
      nil -> {:ok, {"elixir", []}}
      {program, args} when is_binary(program) and is_list(args) -> {:ok, {program, args}}
      program when is_binary(program) -> {:ok, {program, []}}
    end
  end

  # The script goes to the runner as content, with the `:script` atom where
  # its path belongs in the argument vector.
  defp script_plan(exe, base_args, code) do
    %{exe: exe, args: base_args ++ [:script], cwd: nil, script: %{name: "script.exs", content: code}}
  end

  defp executable(program) do
    case System.find_executable(program) do
      nil -> {:error, "elixir not found: #{program}"}
      path -> {:ok, path}
    end
  end
end
