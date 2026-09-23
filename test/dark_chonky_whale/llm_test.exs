defmodule DarkChonkyWhale.LLMTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.LLM
  alias DarkChonkyWhale.LLM.Client
  alias Dexterous.Context

  defmodule FakeBackend do
    @moduledoc false

    def stream_text(model, context, opts) do
      send(self(), {:backend_stream, model, context, opts})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [ReqLLM.StreamChunk.text("hel"), ReqLLM.StreamChunk.text("lo")],
         metadata_handle: nil,
         cancel: fn -> :ok end,
         model: model,
         context: context
       }}
    end

    def generate_text(model, context, opts) do
      send(self(), {:backend_generate, model, context, opts})
      {:ok, %{usage: %{input_tokens: 1, output_tokens: 2}}}
    end
  end

  setup do
    scope = :"llm_test_#{System.unique_integer([:positive])}"
    {:ok, ctx: Context.new(scope), scope: scope}
  end

  test "the component provides a configured :llm client", %{ctx: ctx, scope: scope} do
    {:ok, _fiber} =
      Context.use(ctx, LLM, model: "test:model", temperature: 0.5, backend: FakeBackend)

    client =
      eventually(fn ->
        case Context.get(ctx, :llm) do
          {:ok, client} -> client
          :error -> nil
        end
      end)

    assert %Client{model: "test:model", scope: ^scope, backend: FakeBackend, opts: opts} = client
    assert opts == [temperature: 0.5]
  end

  test "stream/3 runs the request through the llm/request waterfall", %{ctx: ctx, scope: scope} do
    {:ok, _} =
      Context.on(ctx, :"llm/request", fn request, next ->
        next.(%{request | model: "rewritten:model"})
      end)

    client = %Client{scope: scope, model: "orig:model", backend: FakeBackend}
    assert {:ok, _response} = Client.stream(client, "hi")

    assert_received {:backend_stream, "rewritten:model", %ReqLLM.Context{}, []}
  end

  test "stream/3 broadcasts every chunk as an llm/chunk event", %{ctx: ctx, scope: scope} do
    test_pid = self()

    {:ok, _} =
      Context.on(ctx, :"llm/chunk", fn chunk -> send(test_pid, {:chunk, chunk.text}) end)

    client = %Client{scope: scope, model: "test:model", backend: FakeBackend}
    {:ok, response} = Client.stream(client, "hi")

    assert [%{type: :content, text: "hel"}, %{type: :content, text: "lo"}] =
             Enum.to_list(response.stream)
    assert_received {:chunk, "hel"}
    assert_received {:chunk, "lo"}
  end

  test "generate/3 emits the settled usage", %{ctx: ctx, scope: scope} do
    test_pid = self()
    {:ok, _} = Context.on(ctx, :"llm/usage", fn event -> send(test_pid, {:usage, event}) end)

    client = %Client{scope: scope, model: "test:model", backend: FakeBackend}
    assert {:ok, %{usage: %{input_tokens: 1}}} = Client.generate(client, "hi")

    assert_received {:backend_generate, "test:model", %ReqLLM.Context{}, []}
    assert_received {:usage, %{usage: %{input_tokens: 1, output_tokens: 2}}}
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
