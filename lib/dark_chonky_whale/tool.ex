defmodule DarkChonkyWhale.Tool do
  @moduledoc """
  The tool contract: a declarative schema plus an execution function.

  A tool is a plain module (not a component — tools are cheap, and the ones
  that need coeffects get them through the execution environment the
  registry hands over):

      defmodule MyTool do
        @behaviour DarkChonkyWhale.Tool

        @impl true
        def schema do
          %{
            name: "my_tool",
            description: "Does a thing",
            parameters: %{
              "type" => "object",
              "properties" => %{"arg" => %{"type" => "string"}},
              "required" => ["arg"]
            }
          }
        end

        @impl true
        def execute(%{"arg" => arg}, env) do
          {:ok, "got #\{arg} from #\{inspect(env)}"}
        end
      end

  `execute/2` receives the model-supplied arguments (string keys, as decoded
  from the tool call's JSON) and the registry's execution environment (see
  `DarkChonkyWhale.Tools`). It returns `{:ok, output}` — any JSON-encodable
  term — or `{:error, reason}`; an uncaught exception is caught by the
  pipeline and reported as `{:error, %{type: :crashed}}`.
  """

  @typedoc "A tool's declarative schema; `parameters` is a JSON Schema map."
  @type schema :: %{name: String.t(), description: String.t(), parameters: map()}

  @typedoc "The execution environment handed to `execute/2` by the registry."
  @type env :: map()

  @callback schema() :: schema()
  @callback execute(args :: map(), env()) :: {:ok, term()} | {:error, term()}
end
