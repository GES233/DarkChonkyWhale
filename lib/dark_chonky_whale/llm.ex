defmodule DarkChonkyWhale.LLM do
  @moduledoc """
  The `:llm` seam provider: a component whose config selects the model and
  the transport options, and whose provision is a
  `DarkChonkyWhale.LLM.Client` bound to the composition's scope.

      %DexterousLoader.Entry{
        id: :llm,
        component: DarkChonkyWhale.LLM,
        config: [model: "openrouter:anthropic/claude-sonnet-4.5", temperature: 0.7]
      }

  Config:

    * `:model` (required) — a ReqLLM model specification
      (`"provider:model"`, or anything `ReqLLM.model/1` accepts)
    * any other key — passed through to `ReqLLM.stream_text/3` /
      `generate_text/3` as default options (e.g. `:temperature`,
      `:max_tokens`, `:api_key`, `:provider_options`)
    * `:backend` — internal; the module performing the calls, defaults to
      `ReqLLM`. Not part of the public configuration surface.

  Consumers `inject: [:llm]` and call `Client.stream/3` or
  `Client.generate/3`; every call publishes the seam's events (see
  `DarkChonkyWhale.LLM.Client`).
  """

  use Dexterous.Component, provide: [:llm]

  alias DarkChonkyWhale.LLM.Client
  alias Dexterous.Context

  @impl true
  def apply(ctx, config) do
    client = %Client{
      scope: ctx.scope,
      model: Keyword.fetch!(config, :model),
      opts: config |> Keyword.drop([:model, :backend]),
      backend: Keyword.get(config, :backend, ReqLLM)
    }

    Context.set(ctx, :llm, client)
  end
end
