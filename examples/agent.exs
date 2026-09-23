# One-shot headless agent: give it a task, watch it work, done.
#
#   # set DEEPSEEK_API_KEY (env or .env), then:
#   mix run examples/agent.exs "create hello.txt containing 你好, then read it back"
#
# The agent's view of the world is the session log; the terminal rendering
# below is driven entirely by the seam events (llm/chunk, tools/*).

alias DarkChonkyWhale.{AgentLoop, LLM, Session, Sessions, Tools}
alias Dexterous.Context

prompt = List.first(System.argv()) || raise "usage: mix run examples/agent.exs PROMPT [model]"
model = Enum.at(System.argv(), 1) || "deepseek:deepseek-flash"
cwd = File.cwd!()

ctx = Dexterous.root()

{:ok, _} =
  Context.on(ctx, :"llm/chunk", fn chunk ->
    case chunk.type do
      :content -> IO.write(chunk.text)
      :thinking -> IO.write(IO.ANSI.faint() <> chunk.text <> IO.ANSI.reset())
      _ -> :ok
    end
  end)

{:ok, _} =
  Context.on(ctx, :"tools/post-execute", fn %{name: name, result: result, duration_ms: ms} ->
    status =
      case result do
        {:ok, _} -> "ok"
        {:error, error} -> "error: #{inspect(error)}"
      end

    IO.puts("\n[tool #{name}] #{status} (#{ms}ms)")
  end)

{:ok, _} = Context.use(ctx, LLM, model: model)
{:ok, _} = Context.use(ctx, Sessions, dir: Path.join(System.tmp_dir!(), "dcw-headless-sessions"))
{:ok, _} = Context.use(ctx, Tools, tools: [Tools.Read, Tools.Write, Tools.Edit], env: %{cwd: cwd})

await = fn key ->
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case Context.get(ctx, key) do
      {:ok, value} -> {:halt, value}
      :error -> {:cont, Process.sleep(10)}
    end
  end) || raise "#{key} was not bound in time"
end

llm = await.(:llm)
sessions = await.(:sessions)
tools = await.(:tools)

{:ok, session} = Sessions.open(sessions, "headless-#{System.unique_integer([:positive])}")

{:ok, _} =
  Session.append(session, :"system/message", %{
    "content" => """
    You are a one-shot coding agent. The working directory is #{cwd}.
    Use the read/write/edit tools to inspect and modify files.
    When the task is done, answer briefly without calling tools.
    """
  })

{:ok, _} = Session.append(session, :"user/message", %{"content" => prompt})

IO.puts("model: #{model}\ncwd: #{cwd}\n---")

case AgentLoop.run(llm, session, tools) do
  {:ok, _text} -> IO.puts("\n\n== task complete ==")
  {:error, error} -> IO.puts("\n\n== task failed: #{inspect(error)} ==")
end
