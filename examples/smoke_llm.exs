# Smoke-test the :llm seam against a live provider.
#
#   # PowerShell:  $env:ZENMUX_API_KEY = "sk-..."
#   # or put ZENMUX_API_KEY=sk-... into .env (ReqLLM auto-loads it)
#   mix run examples/smoke_llm.exs [model]
#
# Defaults to a small zenmux model. Thinking chunks render dimmed.

alias DarkChonkyWhale.LLM
alias DarkChonkyWhale.LLM.Client
alias Dexterous.Context

model = List.first(System.argv()) || "zenmux:sapiens-ai/agnes-1.5-lite"

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
  Context.on(ctx, :"llm/usage", fn %{usage: usage} -> IO.puts("\nusage: #{inspect(usage)}") end)

{:ok, _fiber} = Context.use(ctx, LLM, model: model)

client =
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case Context.get(ctx, :llm) do
      {:ok, client} -> {:halt, client}
      :error -> {:cont, Process.sleep(10)}
    end
  end) || raise "the :llm client was not bound in time"

IO.puts("model: #{model}\n---")
{:ok, response} = Client.stream(client, "简单介绍无人机遥控器的美国手以及日本手。")
_ = ReqLLM.StreamResponse.text(response)
IO.puts("\n--- done")
