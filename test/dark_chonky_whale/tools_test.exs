defmodule DarkChonkyWhale.ToolsTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.Tools
  alias Dexterous.Context

  defmodule Echo do
    @moduledoc false
    @behaviour DarkChonkyWhale.Tool

    @impl true
    def schema do
      %{
        name: "echo",
        description: "Echoes the arguments and the environment",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def execute(args, env) do
      send(self(), {:echo_executed, args})
      {:ok, %{"args" => args, "cwd" => env[:cwd]}}
    end
  end

  defmodule Crash do
    @moduledoc false
    @behaviour DarkChonkyWhale.Tool

    @impl true
    def schema do
      %{name: "crash", description: "Always fails", parameters: %{"type" => "object"}}
    end

    @impl true
    def execute(_args, _env), do: raise("boom")
  end

  setup do
    scope = :"tools_test_#{System.unique_integer([:positive])}"
    ctx = Context.new(scope)

    {:ok, _fiber} =
      Context.use(ctx, Tools, tools: [Echo, Crash], env: %{cwd: "/tmp/work"})

    registry =
      eventually(fn ->
        case Context.get(ctx, :tools) do
          {:ok, registry} -> registry
          :error -> nil
        end
      end)

    {:ok, ctx: ctx, scope: scope, registry: registry}
  end

  test "provides the registry with the tool schemas", %{registry: registry} do
    assert ["crash", "echo"] = registry |> Tools.schemas() |> Enum.map(& &1.name)
    assert {:ok, Echo} = Tools.lookup(registry, "echo")
    assert :error = Tools.lookup(registry, "nope")
  end

  test "execute runs the tool with the env and emits post-execute", %{
    ctx: ctx,
    registry: registry
  } do
    test_pid = self()

    {:ok, _} =
      Context.on(ctx, :"tools/post-execute", fn event -> send(test_pid, {:post, event}) end)

    assert {:ok, %{"args" => %{"x" => 1}, "cwd" => "/tmp/work"}} =
             Tools.execute(registry, "echo", %{"x" => 1})

    assert_received {:echo_executed, %{"x" => 1}}
    assert_received {:post, %{name: "echo", result: {:ok, _}, duration_ms: ms}}
    assert is_integer(ms)
  end

  test "a pre-execute listener may rewrite the arguments", %{ctx: ctx, registry: registry} do
    {:ok, _} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        next.(%{call | arguments: Map.put(call.arguments, "injected", true)})
      end)

    assert {:ok, %{"args" => %{"x" => 1, "injected" => true}}} =
             Tools.execute(registry, "echo", %{"x" => 1})
  end

  test "a pre-execute listener may deny the call; the tool never runs", %{
    ctx: ctx,
    registry: registry
  } do
    {:ok, _} =
      Context.on(ctx, :"tools/pre-execute", fn call, _next ->
        %{call | decision: {:deny, "not allowed"}}
      end)

    assert {:error, %{type: :denied, message: "not allowed"}} =
             Tools.execute(registry, "echo", %{})

    refute_received {:echo_executed, _}
  end

  test "unknown tools and crashes are typed errors, not exceptions", %{registry: registry} do
    assert {:error, %{type: :unknown_tool}} = Tools.execute(registry, "nope", %{})
    assert {:error, %{type: :crashed, message: "boom"}} = Tools.execute(registry, "crash", %{})
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      other ->
        other
    end
  end
end
