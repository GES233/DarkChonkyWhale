# Demo: the session log — append, broadcast, project, survive a restart.
# Run from the project root:  mix run examples/session_demo.exs
#
# No network needed; this exercises only the local log and projection.

alias DarkChonkyWhale.{Session, Sessions}
alias Dexterous.Context

dir = Path.join(System.tmp_dir!(), "dcw-session-demo")
File.rm_rf!(dir)

ctx = Dexterous.root()

# A live consumer: print every durable fact as it lands.
{:ok, _} =
  Context.on(ctx, :"session/event", fn %{session: id, event: event} ->
    IO.puts("  [event] #{id}##{event.seq} #{event.type}")
  end)

IO.puts("== 1. mount the :sessions service and open a session ==")
{:ok, _fiber} = Context.use(ctx, Sessions, dir: dir)

sessions =
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case Context.get(ctx, :sessions) do
      {:ok, sessions} -> {:halt, sessions}
      :error -> {:cont, Process.sleep(10)}
    end
  end) || raise "the :sessions service was not bound in time"

{:ok, session} = Sessions.open(sessions, "demo")

IO.puts("\n== 2. a turn with a tool call, event by event ==")
{:ok, _} = Session.append(session, :"system/message", %{"content" => "Be brief."})
{:ok, _} = Session.append(session, :"turn/start", %{})
{:ok, _} = Session.append(session, :"user/message", %{"content" => "What is 2+2?"})

{:ok, _} =
  Session.append(session, :"assistant/message", %{
    "content" => "",
    "tool_calls" => [%{"id" => "call_1", "name" => "calc", "input" => %{"expr" => "2+2"}}]
  })

{:ok, _} =
  Session.append(session, :"tool/result", %{
    "tool_call_id" => "call_1",
    "name" => "calc",
    "output" => "4"
  })

{:ok, _} = Session.append(session, :"assistant/message", %{"content" => "2+2 = 4."})
{:ok, _} = Session.append(session, :"turn/end", %{})

IO.puts("\n== 3. the model-visible projection (markers skipped) ==")

for message <- Session.messages(session) do
  calls =
    case message.tool_calls do
      nil -> ""
      calls -> " calls=" <> inspect(Enum.map(calls, & &1.function.name))
    end

  IO.puts("  #{String.pad_trailing(to_string(message.role), 9)} #{inspect(message.content)}#{calls}")
end

IO.puts("\n== 4. kill the process; the on-disk log survives ==")
Sessions.close(sessions, session)
{:ok, session} = Sessions.open(sessions, "demo")
IO.puts("  #{length(Session.events(session))} events replayed from disk")

IO.puts("\n== 5. sessions on disk: #{inspect(Sessions.list(sessions))} ==")
IO.puts("log file: #{Path.join(dir, "session-demo.jsonl")}")

IO.puts("\ndone.\nYou need delete it mannually.")
