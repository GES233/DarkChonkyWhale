defmodule DarkChonkyWhale.AgentLoop do
  @moduledoc """
  The default driver: runs a turn as a sequence of steps — stream a model
  response, append it to the session log, execute its tool calls through the
  tools pipeline, append their results, repeat — until the model answers
  without calling tools, or the step budget runs out.

  The loop reads the model's view from the session projection
  (`Session.messages/1`) and keeps no history of its own: model-visible
  means logged.
  """

  alias DarkChonkyWhale.{Session, Tools}
  alias DarkChonkyWhale.LLM.Client

  @default_max_steps 100

  @doc """
  Run one turn: `:"turn/start"`, the step loop, then `:"turn/end"` (appended
  even when the loop errors). Returns `{:ok, final_text}` or `{:error, _}`.

  Options:

    * `:max_steps` — step budget for the turn (default #{@default_max_steps})
  """
  @spec run(Client.t(), pid(), Tools.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%Client{} = client, session, %Tools{} = tools, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    {:ok, _} = Session.append(session, :"turn/start", %{})

    try do
      steps(client, session, tools, max_steps, 0)
    after
      # Best-effort bookkeeping: if the session died mid-turn, the original
      # error must not be masked by a failure to close the turn.
      try do
        Session.append(session, :"turn/end", %{})
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp steps(_client, _session, _tools, max, max), do: {:error, :max_steps_exceeded}

  defp steps(client, session, tools, max_steps, n) do
    {:ok, _} = Session.append(session, :"step/start", %{"n" => n})

    with {:ok, tool_specs} <- tool_specs(tools),
         {:ok, response} <- Client.stream(client, Session.messages(session), tools: tool_specs) do
      response
      |> ReqLLM.StreamResponse.classify()
      |> settle(client, session, tools, max_steps, n)
    end
  end

  defp settle(%{type: :final_answer} = result, _client, session, _tools, _max, _n) do
    append_assistant(session, result)
    {:ok, result.text}
  end

  defp settle(%{type: :tool_calls} = result, client, session, tools, max_steps, n) do
    append_assistant(session, result)
    execute_calls(session, tools, result.tool_calls)
    steps(client, session, tools, max_steps, n + 1)
  end

  defp append_assistant(session, result) do
    {:ok, _} =
      Session.append(session, :"assistant/message", %{
        "content" => result.text,
        "tool_calls" =>
          Enum.map(result.tool_calls, fn call ->
            %{"id" => call.id, "name" => call.name, "input" => call.arguments}
          end)
      })
  end

  defp execute_calls(session, tools, calls) do
    for call <- calls do
      output =
        case Tools.execute(tools, call.name, call.arguments) do
          {:ok, output} -> output
          {:error, error} -> %{ok: false, error: error}
        end

      {:ok, _} =
        Session.append(session, :"tool/result", %{
          "tool_call_id" => call.id,
          "name" => call.name,
          "output" => output
        })
    end

    :ok
  end

  # Our Tool schemas are already JSON Schema maps, which ReqLLM.tool/1
  # accepts directly as :parameter_schema. ReqLLM requires a :callback for
  # its own local-execution path; ours never runs (execution goes through
  # the Tools pipeline), so a placeholder satisfies the validation.
  # ReqLLM.tool/1 raises on an invalid schema — a programming error, which
  # the run's `after` still closes the turn around.
  defp tool_specs(tools) do
    {:ok,
     Enum.map(Tools.schemas(tools), fn schema ->
       ReqLLM.tool(
         name: schema.name,
         description: schema.description,
         parameter_schema: schema.parameters,
         callback: fn _args -> nil end
       )
     end)}
  end
end
