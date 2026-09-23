defmodule DarkChonkyWhale.Tools do
  @moduledoc """
  The `:tools` seam provider: a registry of tool modules with a guarded
  execution pipeline.

      %DexterousLoader.Entry{
        id: :tools,
        component: DarkChonkyWhale.Tools,
        config: [tools: [MyTool, AnotherTool], env: %{cwd: File.cwd!()}]
      }

  Config:

    * `:tools` — the tool modules (each implementing `DarkChonkyWhale.Tool`)
    * `:env` — the execution environment handed to every `execute/2`
      (e.g. `%{cwd: ...}`), defaults to `%{}`

  The provision is a `%Tools{}` handle; consumers `inject: [:tools]`.

  ## The execution pipeline

  `execute/3` runs a call through the scope's events (consumers of the seam
  subscribe with `Context.on/3`):

    * `:"tools/pre-execute"` — a *waterfall* over
      `%{name:, arguments:, decision: :run}`. Listeners may rewrite the
      arguments, or deny the call by transforming `decision` to
      `{:deny, reason}` (typically also declining `next.()` to short-circuit
      the chain). This is where approval policy hooks in.
    * `:"tools/post-execute"` — an *emit* with
      `%{name:, arguments:, result:, duration_ms:}` for every settled call.

  Results are typed: `{:ok, output}` or `{:error, %{type:, message:}}` with
  `:type` one of `:unknown_tool | :denied | :crashed`.
  """

  use Dexterous.Component, provide: [:tools]

  alias Dexterous.Context

  @typedoc "The tool registry handle, the value bound to the `:tools` coeffect."
  @type t :: %__MODULE__{tools: %{String.t() => module()}, env: map(), scope: Context.scope()}

  defstruct [:tools, :env, :scope]

  @pre_event :"tools/pre-execute"
  @post_event :"tools/post-execute"

  ## Component

  @impl true
  def apply(ctx, config) do
    tools =
      Map.new(Keyword.get(config, :tools, []), fn module -> {module.schema().name, module} end)

    env = Keyword.get(config, :env, %{})

    Context.set(ctx, :tools, %__MODULE__{tools: tools, env: env, scope: ctx.scope})
  end

  ## Registry

  @doc "The registered tool schemas, in registration-independent name order."
  @spec schemas(t()) :: [DarkChonkyWhale.Tool.schema()]
  def schemas(%__MODULE__{} = registry) do
    registry.tools |> Map.values() |> Enum.map(& &1.schema())
  end

  @doc "The tool module registered under `name`, or `:error`."
  @spec lookup(t(), String.t()) :: {:ok, module()} | :error
  def lookup(%__MODULE__{} = registry, name), do: Map.fetch(registry.tools, name)

  @doc """
  Run the tool `name` with `arguments` through the pipeline. Never raises
  for tool-level failures: see the module doc for the result contract.
  """
  @spec execute(t(), String.t(), map()) :: {:ok, term()} | {:error, map()}
  def execute(%__MODULE__{} = registry, name, arguments) when is_map(arguments) do
    ctx = Context.new(registry.scope)

    call = %{name: name, arguments: arguments, decision: :run}
    call = Context.waterfall(ctx, @pre_event, call)

    case call.decision do
      :run -> run(registry, call, ctx)
      {:deny, reason} -> {:error, %{type: :denied, message: to_string(reason)}}
    end
  end

  defp run(registry, call, ctx) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, module} <- lookup(registry, call.name) do
        try do
          module.execute(call.arguments, registry.env)
        rescue
          exception -> {:error, %{type: :crashed, message: Exception.message(exception)}}
        catch
          kind, reason -> {:error, %{type: :crashed, message: "#{kind}: #{inspect(reason)}"}}
        end
      else
        :error -> {:error, %{type: :unknown_tool, message: "unknown tool: #{call.name}"}}
      end

    Context.emit(ctx, @post_event, %{
      name: call.name,
      arguments: call.arguments,
      result: result,
      duration_ms: System.monotonic_time(:millisecond) - started
    })

    result
  end
end
