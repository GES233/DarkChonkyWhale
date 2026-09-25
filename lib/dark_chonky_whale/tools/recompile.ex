defmodule DarkChonkyWhale.Tools.Recompile do
  @moduledoc """
  The `recompile` tool: recompile the running project and hot-swap the
  changed modules, so the agent can iterate on its own code without a
  restart.

  The heavy lifting is `dexterous_hmr`'s transactional cycle: diff loaded
  modules by md5, swap the changed ones, respawn the stale entries of every
  registered loader, roll back on failure. Plain modules (like the tools
  themselves) resolve their calls at call time, so a swapped module is live
  for the next tool call immediately.

  Availability follows the launch mode: recompiling needs Mix, which only
  exists under `mix run` (dev). Under an escript or a release the tool
  refuses cleanly instead of pretending to work.

  Environment:

    * `:watch_dirs` — source directories whose modules are diffed; defaults
      to `[<cwd>/lib]`
  """

  @behaviour DarkChonkyWhale.Tool

  @impl true
  def schema do
    %{
      name: "recompile",
      description:
        "Recompile the project and hot-swap the changed modules (dev only, " <>
          "running under `mix run`). Use after editing source files; tool and " <>
          "component changes take effect on the next call.",
      parameters: %{"type" => "object", "properties" => %{}}
    }
  end

  @impl true
  def execute(_args, env) do
    if Code.ensure_loaded?(Mix) do
      recompile(env)
    else
      {:error, "recompile is only available under `mix run` (dev); this runtime has no Mix"}
    end
  end

  defp recompile(env) do
    with {:ok, _pid} <- ensure_loop(),
         {:ok, report} <- DexterousHMR.trigger_compile(watch_dirs: watch_dirs(env)) do
      {:ok, render(report)}
    else
      {:error, :not_dev} ->
        {:error, "recompile refused: Mix.env() is not :dev"}

      {:error, reason} ->
        {:error, "recompile failed: #{inspect(reason)}"}
    end
  end

  defp ensure_loop do
    case Process.whereis(DexterousHMR) do
      nil -> DexterousHMR.start_link()
      pid -> {:ok, pid}
    end
  end

  # Access, not Map.get: a direct caller may hand over a keyword list.
  defp watch_dirs(env) do
    env[:watch_dirs] || [Path.join(env[:cwd] || File.cwd!(), "lib")]
  end

  defp render(report) do
    case report do
      %{compile: :ok, changed: []} ->
        "compiled, but no *loaded* module changed — new or not-yet-called " <>
          "modules activate lazily on first use; already-running fibers are unaffected"

      %{changed: []} ->
        "recompiled: no changes"

      %{changed: changed, accepted: accepted, reloaded: reloaded} ->
        "recompiled: #{inspect(changed)} changed" <>
          "; hot-swapped #{inspect(accepted)}" <>
          if(reloaded == [], do: "", else: "; reloaded entries #{inspect(reloaded)}")
    end
  end
end
