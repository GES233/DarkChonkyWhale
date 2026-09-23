defmodule DarkChonkyWhale.SessionTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.{Session, Sessions}
  alias Dexterous.Context

  setup do
    scope = :"session_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "dcw-session-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ctx: Context.new(scope), scope: scope, dir: dir}
  end

  defp open_session(dir, scope, id) do
    {:ok, pid} = Session.start_link(id: id, dir: dir, scope: scope)
    pid
  end

  describe "the log" do
    test "append assigns seq and timestamp, in order", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)

      {:ok, e1} = Session.append(pid, :"turn/start", %{})
      {:ok, e2} = Session.append(pid, :"user/message", %{"content" => "hi"})

      assert e1.seq == 0
      assert e2.seq == 1
      assert %DateTime{} = e1.at
      assert [^e1, ^e2] = Session.events(pid)
    end

    test "every append is broadcast as a session/event", %{dir: dir, scope: scope, ctx: ctx} do
      test_pid = self()

      {:ok, _} =
        Context.on(ctx, :"session/event", fn %{session: id, event: event} ->
          send(test_pid, {:session_event, id, event})
        end)

      pid = open_session(dir, scope, :s1)
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hi"})

      assert_received {:session_event, :s1, %{type: :"user/message", seq: 0}}
    end

    test "invalid UTF-8 in a payload is scrubbed, never fatal", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :gbk)

      # GBK-encoded console output, as captured by a tool on a Chinese
      # Windows machine: not valid UTF-8.
      {:ok, event} =
        Session.append(pid, :"tool/result", %{"name" => "bash", "output" => <<199, 253, 10>>})

      assert Process.alive?(pid)
      assert String.valid?(event.data["output"])

      GenServer.stop(pid)
      pid = open_session(dir, scope, :gbk)
      assert [%{data: %{"output" => output}}] = Session.events(pid)
      assert String.valid?(output)
    end

    test "reopening the same id replays the on-disk log", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hello"})
      {:ok, _} = Session.append(pid, :"assistant/message", %{"content" => "hi there"})
      GenServer.stop(pid)

      pid = open_session(dir, scope, :s1)

      assert [first, second] = Session.events(pid)
      assert first.type == :"user/message"
      assert first.data == %{"content" => "hello"}
      assert second.seq == 1
    end

    test "an event type no code references round-trips as a string", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hi"})

      # Simulate a future format: a line whose type is unknown to this VM.
      File.write!(
        Path.join(dir, "session-s1.jsonl"),
        Jason.encode!(%{
          "seq" => 1,
          "type" => "future/thing",
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{}
        }) <> "\n",
        [:append]
      )

      GenServer.stop(pid)
      pid = open_session(dir, scope, :s1)

      assert [%{type: :"user/message"}, %{type: "future/thing"}] = Session.events(pid)
      # Unknown types are not model-visible.
      assert [%{role: :user}] = Session.messages(pid)
    end
  end

  describe "the projection" do
    test "folds message events into ReqLLM messages, skipping markers", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)

      {:ok, _} = Session.append(pid, :"system/message", %{"content" => "be brief"})
      {:ok, _} = Session.append(pid, :"turn/start", %{})
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "2+2?"})

      {:ok, _} =
        Session.append(pid, :"assistant/message", %{
          "content" => "",
          "tool_calls" => [%{"id" => "call_1", "name" => "calc", "input" => %{"expr" => "2+2"}}]
        })

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "tool_call_id" => "call_1",
          "name" => "calc",
          "output" => "4"
        })

      {:ok, _} = Session.append(pid, :"assistant/message", %{"content" => "4"})
      {:ok, _} = Session.append(pid, :"turn/end", %{})

      assert [system, user, assistant_call, tool_result, assistant] = Session.messages(pid)
      assert system.role == :system
      assert user.role == :user
      assert assistant_call.role == :assistant
      assert tool_result.role == :tool
      assert assistant.role == :assistant

      assert [%{type: :text, text: "4"}] = assistant.content
    end
  end

  describe "the :sessions service" do
    test "provides a store that opens, lists and reopens sessions", %{ctx: ctx, dir: dir} do
      {:ok, _fiber} = Context.use(ctx, Sessions, dir: dir)

      sessions =
        eventually(fn ->
          case Context.get(ctx, :sessions) do
            {:ok, sessions} -> sessions
            :error -> nil
          end
        end)

      {:ok, pid} = Sessions.open(sessions, "chat-1")
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hi"})

      # Opening twice returns the same process.
      assert {:ok, ^pid} = Sessions.open(sessions, "chat-1")
      assert ["chat-1"] = Sessions.list(sessions)

      assert :ok = Sessions.close(sessions, pid)
      assert ["chat-1"] = Sessions.list(sessions)

      # The log survives the process: reopening replays it.
      {:ok, pid2} = Sessions.open(sessions, "chat-1")
      assert [%{type: :"user/message"}] = Session.events(pid2)
    end
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
