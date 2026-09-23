defmodule DarkChonkyWhale.Tools.RecompileTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.Tools.Recompile

  setup do
    dir = Path.join(System.tmp_dir!(), "dcw-recompile-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # The HMR loop is a named singleton; leave no trace between tests.
    on_exit(fn ->
      if pid = Process.whereis(DexterousHMR), do: GenServer.stop(pid)
    end)

    {:ok, env: %{cwd: dir}, dir: dir}
  end

  test "outside :dev the cycle is refused, cleanly", %{env: env} do
    # Tests run under Mix.env() == :test, and dexterous_hmr's env guard
    # refuses non-:dev cycles unless a :compile_fun override is configured.
    assert {:error, "recompile refused: Mix.env() is not :dev"} = Recompile.execute(%{}, env)
  end

  test "with a compile_fun override the cycle runs and reports no changes", %{env: env} do
    put_compile_fun()

    assert {:ok, "recompiled: no changes"} = Recompile.execute(%{}, env)

    # The loop was started lazily by the tool.
    assert Process.whereis(DexterousHMR)
    # No loaded module comes from the empty temp dir.
    assert DexterousHMR.status().purge_queue == []
  end

  test "an explicit watch_dirs env overrides the default", %{env: env} do
    put_compile_fun()

    assert {:ok, "recompiled: no changes"} =
             Recompile.execute(%{}, Map.put(env, :watch_dirs, [env.cwd]))
  end

  # Application.put_env(key, nil) stores nil rather than deleting the key,
  # and Keyword.get(nil, ...) crashes dexterous_hmr's config resolution — so
  # restore "absent" with delete_env.
  defp put_compile_fun do
    old = Application.get_env(:dexterous_hmr, :config)
    Application.put_env(:dexterous_hmr, :config, compile_fun: fn -> :ok end)

    on_exit(fn ->
      if old,
        do: Application.put_env(:dexterous_hmr, :config, old),
        else: Application.delete_env(:dexterous_hmr, :config)
    end)
  end
end
