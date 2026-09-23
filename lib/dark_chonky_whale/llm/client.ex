defmodule DarkChonkyWhale.LLM.Client do
  @moduledoc """
  The `:llm` service consumers receive: a configured model plus the transport
  defaults, bound to a Dexterous scope so calls publish the seam's events.

  The vocabulary is ReqLLM's (`ReqLLM.Context`, `ReqLLM.Message`,
  `ReqLLM.StreamChunk`, `ReqLLM.Response`); the client adds the extension
  points:

    * `:"llm/request"` — a *waterfall* run per call over the normalized
      request (`%{model:, context:, opts:}`). Listeners may rewrite the
      model, the context or the options, or short-circuit the chain.
    * `:"llm/chunk"` — an *emit* per `ReqLLM.StreamChunk` as it flows
      through a streaming response.
    * `:"llm/usage"` — an *emit* carrying the usage map once a call has
      settled (after a generate, or when a stream finishes).

  The `:backend` module performs the actual call; it must expose
  `stream_text/3` and `generate_text/3` with ReqLLM's signatures. It defaults
  to `ReqLLM` itself and is replaced by a fake in tests.
  """

  alias Dexterous.Context

  defstruct [:scope, :model, opts: [], backend: ReqLLM]

  @typedoc "A configured LLM client, the value bound to the `:llm` coeffect."
  @type t :: %__MODULE__{
          scope: Context.scope(),
          model: term(),
          opts: keyword(),
          backend: module()
        }

  @typedoc "The normalized request passed through the `:\"llm/request\"` waterfall."
  @type request :: %{model: term(), context: ReqLLM.Context.t(), opts: keyword()}

  @request_event :"llm/request"
  @chunk_event :"llm/chunk"
  @usage_event :"llm/usage"

  @doc """
  Stream a completion: the request goes through the `:"llm/request"`
  waterfall, then the backend's `stream_text/3`. Returns the
  `ReqLLM.StreamResponse` with its chunk stream tapped to emit
  `:"llm/chunk"` per chunk and `:"llm/usage"` when the stream ends.
  """
  @spec stream(t(), ReqLLM.Context.t() | [ReqLLM.Message.t()] | String.t(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream(%__MODULE__{} = client, messages, opts \\ []) do
    request = request(client, messages, opts)

    with {:ok, response} <-
           client.backend.stream_text(request.model, request.context, request.opts) do
      {:ok, tap_stream(client.scope, response)}
    end
  end

  @doc """
  Generate a completion in one shot: the request goes through the
  `:"llm/request"` waterfall, then the backend's `generate_text/3`; a
  settled call's usage is emitted as `:"llm/usage"`.
  """
  @spec generate(t(), ReqLLM.Context.t() | [ReqLLM.Message.t()] | String.t(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def generate(%__MODULE__{} = client, messages, opts \\ []) do
    request = request(client, messages, opts)

    with {:ok, response} <-
           client.backend.generate_text(request.model, request.context, request.opts) do
      emit_usage(client.scope, Map.get(response, :usage))
      {:ok, response}
    end
  end

  ## Internal

  defp request(client, messages, opts) do
    ctx = Context.new(client.scope)

    %{model: client.model, context: to_context(messages), opts: Keyword.merge(client.opts, opts)}
    |> then(&Context.waterfall(ctx, @request_event, &1))
  end

  defp to_context(%ReqLLM.Context{} = context), do: context
  defp to_context(messages) when is_list(messages), do: ReqLLM.Context.new(messages)
  defp to_context(text) when is_binary(text), do: ReqLLM.Context.new([ReqLLM.Context.user(text)])

  # Tap the chunk stream: every chunk is broadcast as it flows; when the
  # stream ends (or is halted early), emit whatever usage the provider
  # collected — a stream consumed partially may have none.
  defp tap_stream(scope, %ReqLLM.StreamResponse{} = response) do
    ctx = Context.new(scope)

    tapped =
      Stream.transform(
        response.stream,
        fn -> nil end,
        fn chunk, acc ->
          Context.emit(ctx, @chunk_event, chunk)
          {[chunk], acc}
        end,
        fn _acc -> emit_usage(scope, stream_usage(response)) end
      )

    %{response | stream: tapped}
  end

  # StreamResponse.usage/1 blocks on the metadata handle; a response without
  # one (early halt, or a synthetic stream in tests) has no usage to report.
  defp stream_usage(response) do
    ReqLLM.StreamResponse.usage(response)
  catch
    _, _ -> nil
  end

  defp emit_usage(_scope, nil), do: :ok

  defp emit_usage(scope, usage) do
    ctx = Context.new(scope)
    Context.emit(ctx, @usage_event, %{usage: usage})
  end
end
