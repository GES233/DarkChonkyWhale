defmodule DarkChonkyWhale.Session do
  @moduledoc """
  One session log: an append-only sequence of durable events — the source of
  the context the model sees.

  An event is `%{seq, type, at, data}`; the log assigns the sequence number
  and the timestamp. Every append is persisted to `<dir>/session-<id>.jsonl`
  *before* the in-memory state moves, so a process loss never leaves memory
  ahead of the file; reopening the same id replays the file.

  The event vocabulary follows DSH's turn flow. Model-visible types, the ones
  the `messages/1` projection folds into `ReqLLM.Message`s:

    * `:"system/message"` — `%{content}`
    * `:"user/message"` — `%{content}`
    * `:"assistant/message"` — `%{content, tool_calls: [%{id, name, input}]}`
      (`tool_calls` optional)
    * `:"tool/result"` — `%{tool_call_id, name, output}`

  Turn/step markers (`:"turn/start"`, `:"step/start"`, …) and any other type
  are durable facts but not model-visible: the projection skips them.

  Every append is also broadcast on the scope's event bus as
  `:"session/event"` with `%{session: id, event: event}` — live consumers
  (UI, telemetry) subscribe there instead of polling the log.

  Known v1 gaps versus DSH's session log: no generation chain or format
  migrations, no sealing of interrupted tails, no enforcement of the
  "model-visible means logged" invariant, and assistant thinking parts are
  not yet preserved (structured reasoning parts with signatures need a
  richer `:"assistant/message"` payload).
  """

  use GenServer

  alias Dexterous.Context

  @type id :: term()
  @type event :: %{seq: non_neg_integer(), type: atom(), at: DateTime.t(), data: map()}

  ## API

  def start_link(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Append an event of `type` with `data`. Returns `{:ok, event}`."
  @spec append(pid(), atom(), map()) :: {:ok, event()}
  def append(pid, type, data) when is_atom(type) and is_map(data) do
    GenServer.call(pid, {:append, type, data})
  end

  @doc "All events, in order."
  @spec events(pid()) :: [event()]
  def events(pid), do: GenServer.call(pid, :events)

  @doc "The model-visible projection: events folded into `ReqLLM.Message`s."
  @spec messages(pid()) :: [ReqLLM.Message.t()]
  def messages(pid) do
    pid |> events() |> Enum.flat_map(&project/1)
  end

  defp project(%{type: :"system/message", data: data}) do
    [ReqLLM.Context.system(data["content"])]
  end

  defp project(%{type: :"user/message", data: data}) do
    [ReqLLM.Context.user(data["content"])]
  end

  defp project(%{type: :"assistant/message", data: data}) do
    tool_calls =
      for call <- data["tool_calls"] || [] do
        {call["name"], call["input"], [id: call["id"]]}
      end

    [ReqLLM.Context.assistant(data["content"] || "", tool_calls: tool_calls)]
  end

  defp project(%{type: :"tool/result", data: data}) do
    [ReqLLM.Context.tool_result_message(data["name"], data["tool_call_id"], data["output"])]
  end

  defp project(_event), do: []

  ## Server

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    dir = Keyword.fetch!(opts, :dir)
    scope = Keyword.fetch!(opts, :scope)
    File.mkdir_p!(dir)
    path = Path.join(dir, "session-#{id}.jsonl")

    {:ok, %{id: id, path: path, scope: scope, events: read_back(path)}}
  end

  @impl true
  def handle_call({:append, type, data}, _from, state) do
    event = %{
      seq: length(state.events),
      type: type,
      at: DateTime.utc_now(),
      data: sanitize(data)
    }

    persist!(state.path, event)
    broadcast(state.scope, state.id, event)

    {:reply, {:ok, event}, %{state | events: state.events ++ [event]}}
  end

  def handle_call(:events, _from, state) do
    {:reply, state.events, state}
  end

  ## Internal

  defp read_back(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&decode_line/1)
      |> Enum.to_list()
    else
      []
    end
  end

  defp persist!(path, event) do
    line =
      Jason.encode!(%{
        "seq" => event.seq,
        "type" => Atom.to_string(event.type),
        "at" => DateTime.to_iso8601(event.at),
        "data" => event.data
      })

    File.write!(path, line <> "\n", [:append])
  end

  # JSON is UTF-8, but payloads can carry raw bytes (e.g. GBK console output
  # captured by a tool). Scrub invalid UTF-8 to the replacement char rather
  # than let Jason raise and take the whole session process down.
  defp sanitize(term) when is_binary(term), do: String.replace_invalid(term)

  defp sanitize(term) when is_map(term),
    do: Map.new(term, fn {key, value} -> {sanitize(key), sanitize(value)} end)

  defp sanitize(term) when is_list(term), do: Enum.map(term, &sanitize/1)
  defp sanitize(term), do: term

  defp decode_line(line) do
    decoded = Jason.decode!(line)

    %{
      seq: decoded["seq"],
      type: decode_type(decoded["type"]),
      at: DateTime.from_iso8601(decoded["at"]) |> elem(1),
      data: decoded["data"] || %{}
    }
  end

  defp decode_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    # A type no code in the VM references (e.g. a marker written by a newer
    # version): keep it as a string. The projection skips it like any other
    # non-model-visible event.
    ArgumentError -> type
  end

  defp broadcast(scope, id, event) do
    ctx = Context.new(scope)
    Context.emit(ctx, :"session/event", %{session: id, event: event})
  end
end
