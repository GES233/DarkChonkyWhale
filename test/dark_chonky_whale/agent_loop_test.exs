defmodule DarkChonkyWhale.AgentLoopTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.{AgentLoop, Session, Sessions, Tools}
  alias DarkChonkyWhale.LLM.Client
  alias DarkChonkyWhale.Tools.{Read, Write}
  alias Dexterous.Context

  defmodule ScriptedBackend do
    @moduledoc false

    # opts[:script] is an Agent holding a list of canned responses; each
    # call pops the next one. opts[:kill_session] kills that session process
    # mid-call, simulating a session that dies while a step is in flight.
    def stream_text(_model, _context, opts) do
      script = Keyword.fetch!(opts, :script)

      response =
        Agent.get_and_update(script, fn
          [head | rest] -> {head, rest}
          [] -> {{:text, "(script exhausted)"}, []}
        end)

      if pid = opts[:kill_session], do: GenServer.stop(pid)

      {:ok, to_stream_response(response)}
    end

    defp to_stream_response({:text, text}) do
      stream([ReqLLM.StreamChunk.text(text), ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})])
    end

    defp to_stream_response({:tool_calls, calls}) do
      chunks =
        Enum.map(calls, fn call ->
          ReqLLM.StreamChunk.tool_call(call.name, call.arguments, %{"id" => call.id})
        end)

      stream(chunks ++ [ReqLLM.StreamChunk.meta(%{finish_reason: "tool_use"})])
    end

    defp stream(chunks) do
      %ReqLLM.StreamResponse{
        stream: chunks,
        metadata_handle: nil,
        cancel: fn -> :ok end,
        model: "scripted",
        context: ReqLLM.Context.new()
      }
    end
  end

  setup do
    scope = :"loop_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "dcw-loop-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    ctx = Context.new(scope)

    {:ok, _} = Context.use(ctx, Sessions, dir: Path.join(dir, "sessions"))
    {:ok, _} = Context.use(ctx, Tools, tools: [Read, Write], env: %{cwd: dir})

    {:ok, script} = Agent.start_link(fn -> [] end)

    client = %Client{
      scope: scope,
      model: "scripted",
      backend: ScriptedBackend,
      opts: [script: script]
    }

    {:ok, ctx: ctx, scope: scope, dir: dir, script: script, client: client}
  end

  defp open_session(%{dir: dir, scope: scope}, id) do
    {:ok, pid} = Session.start_link(id: id, dir: Path.join(dir, "sessions"), scope: scope)
    {:ok, _} = Session.append(pid, :"user/message", %{"content" => "do the thing"})
    pid
  end

  defp script(script, responses), do: Agent.update(script, fn _ -> responses end)

  test "a final answer ends the turn with no tool calls", %{
    dir: dir,
    client: client,
    script: script
  } do
    session = open_session(%{dir: dir, scope: client.scope}, :s1)
    script(script, [{:text, "done already"}])

    assert {:ok, "done already"} =
             AgentLoop.run(client, session, %Tools{tools: %{}, env: %{}, scope: client.scope})

    types = session |> Session.events() |> Enum.map(& &1.type)

    assert types == [
             :"user/message",
             :"turn/start",
             :"step/start",
             :"assistant/message",
             :"turn/end"
           ]

    messages = Session.messages(session)
    assert Enum.map(messages, & &1.role) == [:user, :assistant]
  end

  test "a tool call round: tool runs, result is logged, loop continues", %{
    dir: dir,
    ctx: ctx,
    script: script
  } do
    sessions = await(ctx, :sessions)
    tools = await(ctx, :tools)
    {:ok, session} = Sessions.open(sessions, :s2)
    {:ok, _} = Session.append(session, :"user/message", %{"content" => "write the file"})

    script(script, [
      {:tool_calls,
       [%{id: "c1", name: "write", arguments: %{"file_path" => "out.txt", "content" => "hello"}}]},
      {:text, "wrote it"}
    ])

    assert {:ok, "wrote it"} = AgentLoop.run(client_from(ctx, script), session, tools)
    assert File.read!(Path.join(dir, "out.txt")) == "hello"

    types = session |> Session.events() |> Enum.map(& &1.type)

    assert types == [
             :"user/message",
             :"turn/start",
             :"step/start",
             :"assistant/message",
             :"tool/result",
             :"step/start",
             :"assistant/message",
             :"turn/end"
           ]

    # The model-visible history of the next step contains the tool exchange.
    assert Enum.map(Session.messages(session), & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant
           ]
  end

  test "one step may carry several tool calls; each runs and is logged", %{
    ctx: ctx,
    script: script,
    dir: dir
  } do
    tools = await(ctx, :tools)
    session = open_session(%{dir: dir, scope: ctx.scope}, :s2b)

    script(script, [
      {:tool_calls,
       [
         %{id: "c1", name: "write", arguments: %{"file_path" => "a.txt", "content" => "A"}},
         %{id: "c2", name: "write", arguments: %{"file_path" => "b.txt", "content" => "B"}}
       ]},
      {:text, "both written"}
    ])

    assert {:ok, "both written"} = AgentLoop.run(client_from(ctx, script), session, tools)
    assert File.read!(Path.join(dir, "a.txt")) == "A"
    assert File.read!(Path.join(dir, "b.txt")) == "B"

    types = session |> Session.events() |> Enum.map(& &1.type)

    assert types == [
             :"user/message",
             :"turn/start",
             :"step/start",
             :"assistant/message",
             :"tool/result",
             :"tool/result",
             :"step/start",
             :"assistant/message",
             :"turn/end"
           ]

    # The assistant message carries both calls; each gets its own tool message.
    assert Enum.map(Session.messages(session), & &1.role) == [
             :user,
             :assistant,
             :tool,
             :tool,
             :assistant
           ]

    assert Enum.map(Session.events(session), & &1.type)
           |> Enum.filter(&(&1 == :"tool/result"))
           |> length() ==
             2
  end

  test "chunks flow through the event bus while the loop runs", %{
    ctx: ctx,
    script: script,
    dir: dir
  } do
    tools = await(ctx, :tools)
    session = open_session(%{dir: dir, scope: ctx.scope}, :s3)
    test_pid = self()
    {:ok, _} = Context.on(ctx, :"llm/chunk", fn chunk -> send(test_pid, {:chunk, chunk.type}) end)

    script(script, [
      {:tool_calls,
       [%{id: "c1", name: "write", arguments: %{"file_path" => "o.txt", "content" => "x"}}]},
      {:text, "ok"}
    ])

    assert {:ok, "ok"} = AgentLoop.run(client_from(ctx, script), session, tools)
    assert_received {:chunk, :tool_call}
    assert_received {:chunk, :content}
  end

  test "the step budget caps runaway loops and still closes the turn", %{
    ctx: ctx,
    script: script,
    dir: dir
  } do
    tools = await(ctx, :tools)
    session = open_session(%{dir: dir, scope: ctx.scope}, :s4)

    endless =
      {:tool_calls,
       [%{id: "c", name: "write", arguments: %{"file_path" => "x.txt", "content" => "x"}}]}

    script(script, List.duplicate(endless, 10))

    assert {:error, :max_steps_exceeded} =
             AgentLoop.run(client_from(ctx, script), session, tools, max_steps: 3)

    types = session |> Session.events() |> Enum.map(& &1.type)
    assert List.last(types) == :"turn/end"
    assert Enum.count(types, &(&1 == :"step/start")) == 3
  end

  test "a session dying mid-turn fails the step, not the runner", %{
    ctx: ctx,
    script: script,
    dir: dir
  } do
    tools = await(ctx, :tools)
    session = open_session(%{dir: dir, scope: ctx.scope}, :s5)
    script(script, [{:text, "never appended"}])

    client = %Client{
      scope: ctx.scope,
      model: "scripted",
      backend: ScriptedBackend,
      opts: [script: script, kill_session: session]
    }

    # The step's own Session.append fails with :noproc; the turn-closing
    # append in the `after` clause must not mask that with a second crash.
    assert catch_exit(AgentLoop.run(client, session, tools))
  end

  defp client_from(ctx, script) do
    %Client{scope: ctx.scope, model: "scripted", backend: ScriptedBackend, opts: [script: script]}
  end

  defp await(ctx, key) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case Context.get(ctx, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, Process.sleep(10)}
      end
    end) || raise "#{key} was not bound in time"
  end
end
