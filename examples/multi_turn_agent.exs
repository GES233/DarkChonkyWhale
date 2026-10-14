# A multi-turn headless agent: many turns against one session log, so the
# model keeps its context (and its tool history) between prompts.
#
#   mix run examples/multi_turn_agent.exs -- [--cwd PATH] [model]
#
# `--cwd` changes the agent's workspace without changing the directory that
# hosts this Mix project. Relative paths are resolved from the launch cwd.
#
# Each line read from stdin is one turn. Blank lines are ignored. A line
# starting with "/" is a command:
#
#   /quit, /exit     end the session
#   /reset           start a fresh session log (the old one stays on disk)
#   /log             print the model-visible message count
#
# Anything else is a user message; the agent works the turn with the file
# tools and `execute`, then waits for the next line. The whole conversation
# lives in one session log, so turn 2 sees everything turn 1 did.
#
# The terminal rendering is driven entirely by the seam events: `llm/chunk`
# streams the answer, `tools/post-execute` reports each tool call.

alias DarkChonkyWhale.{AgentLoop, LLM, Session, Sessions, Tools}
alias Dexterous.Context
alias DexterousLoader.Entry

usage = """
usage: mix run examples/multi_turn_agent.exs -- [options] [model]

Options:
  --cwd PATH, -c PATH  use PATH as the agent's working directory
  --help, -h           show this help

The model defaults to deepseek:deepseek-flash. Relative working directories
are resolved from the directory where mix run was started.
"""

{opts, args, invalid} =
  OptionParser.parse(System.argv(),
    strict: [cwd: :string, help: :boolean],
    aliases: [c: :cwd, h: :help]
  )

fail = fn message ->
  IO.puts(:stderr, "#{message}\n\n#{usage}")
  System.halt(2)
end

if opts[:help] do
  IO.puts(usage)
  System.halt(0)
end

if invalid != [], do: fail.("unknown or invalid options: #{inspect(invalid)}")
if length(args) > 1, do: fail.("expected at most one model argument")

model = List.first(args) || "deepseek:deepseek-flash"
launch_cwd = File.cwd!()
cwd = opts |> Keyword.get(:cwd, launch_cwd) |> Path.expand(launch_cwd)

unless File.dir?(cwd), do: fail.("working directory does not exist or is not a directory: #{cwd}")

# `recompile` hot-swaps this running Mix project. It is useful when the agent
# works on dark_chonky_whale itself, but is misleading for an external repo.
self_edit? = cwd == launch_cwd

tool_modules = [
  Tools.Read,
  Tools.Write,
  Tools.Edit,
  Tools.Glob,
  Tools.Grep,
  Tools.Executor
]

{tool_modules, tool_env} =
  if self_edit? do
    {tool_modules ++ [Tools.Recompile], %{cwd: cwd, watch_dirs: [Path.join(cwd, "lib")]}}
  else
    {tool_modules, %{cwd: cwd}}
  end

dir = Path.join(System.tmp_dir!(), "dcw-multi-turn-sessions")

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

{:ok, loader} =
  DexterousLoader.start_link(ctx, [
    %Entry{id: :llm, component: LLM, config: [model: model]},
    %Entry{id: :sessions, component: Sessions, config: [dir: dir]},
    %Entry{
      id: :tools,
      component: Tools,
      config: [
        tools: tool_modules,
        env: tool_env
      ]
    }
  ])

if self_edit? do
  # The HMR loop, with this composition's loader registered, so the recompile
  # tool's cycles respawn stale entries transactionally.
  {:ok, _} = DexterousHMR.start_link()
  :ok = DexterousHMR.register(loader)
end

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

validation_instruction =
  if self_edit? do
    "After editing source files under lib/, call recompile to hot-swap them."
  else
    "Use the target project's own commands to validate changes."
  end

system = """
You are a coding agent working in #{cwd}. Use the read/write/edit/glob/grep
tools to inspect and modify files, and execute to run the tests, git or a
build. #{validation_instruction}
This is a multi-turn conversation: earlier turns are in your context, so build
on what you already learned instead of re-investigating from scratch.
When a turn's task is done, answer briefly without calling tools.
"""

# Open a fresh session log and seed it with the system message. Each turn
# appends to this same log; the agent's memory is nothing but the log.
open = fn ->
  {:ok, session} =
    Sessions.open(sessions, "multi-#{System.unique_integer([:positive])}")

  {:ok, _} = Session.append(session, :"system/message", %{"content" => system})
  session
end

session = open.()

IO.puts("model: #{model}\ncwd: #{cwd}\nturn 1 — enter a task ('/quit' to leave)\n---")

# The REPL. `IO.gets` returns :eof when stdin closes, which ends the loop.
loop = fn loop, session ->
  case IO.gets("\n> ") do
    :eof ->
      IO.puts("\n(input closed — bye)")
      :ok

    {:error, _} ->
      :ok

    line ->
      case String.trim(line) do
        "" ->
          loop.(loop, session)

        cmd when cmd in ["/quit", "/exit"] ->
          IO.puts("bye")
          :ok

        "/reset" ->
          # A new log: the model's context starts empty (system prompt aside).
          IO.puts("[reset — a fresh session log]")
          loop.(loop, open.())

        "/log" ->
          IO.puts("[#{length(Session.messages(session))} model-visible messages so far]")
          loop.(loop, session)

        message ->
          {:ok, _} = Session.append(session, :"user/message", %{"content" => message})

          case AgentLoop.run(llm, session, tools) do
            {:ok, _text} -> IO.puts("\n== turn complete ==")
            {:error, error} -> IO.puts("\n== turn failed: #{inspect(error)} ==")
          end

          loop.(loop, session)
      end
  end
end

loop.(loop, session)
