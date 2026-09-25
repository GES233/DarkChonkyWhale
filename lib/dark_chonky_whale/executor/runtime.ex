defmodule DarkChonkyWhale.Executor.Runtime do
  @moduledoc """
  A runtime for the `execute` tool: one way to run a piece of code.

  A runtime receives the model-supplied `code` and a context carrying the
  resolved working directory, the tool environment, and the per-call knobs:

      %{cwd: String.t(), env: map(), timeout_ms: pos_integer(), max_output_bytes: pos_integer()}

  Port-based runtimes (shell, powershell, python, elixir_subprocess) each
  build a plan and hand it to `DarkChonkyWhale.Executor.Runner`; the
  in-process Elixir runtime implements `run/2` itself.
  """

  @typedoc "The execution context handed to `run/2` by the tool."
  @type ctx :: %{
          cwd: String.t(),
          env: map(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer()
        }

  @callback run(code :: String.t(), ctx :: ctx()) :: {:ok, String.t()} | {:error, String.t()}
end
