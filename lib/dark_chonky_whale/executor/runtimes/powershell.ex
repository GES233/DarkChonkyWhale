defmodule DarkChonkyWhale.Executor.Runtimes.PowerShell do
  # Defined ahead of the moduledoc, which reads them.
  @default_args ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"]

  @moduledoc """
  The PowerShell runtime: run `code` as a `.ps1` script through `pwsh`
  (PowerShell 7) or, where it is absent, `powershell` (Windows PowerShell
  5.1).

  The code is written to a temporary script and run with
  `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File` — not
  `-Command`, which would re-parse the code's quoting the way `cmd.exe` does
  (the shell runtime's batch-file trick is the same idea). The script starts
  by pinning the console output encoding to UTF-8, so even Windows
  PowerShell 5.1 emits what the runner's decoding pipeline expects, and it
  carries a BOM because 5.1 reads a BOM-less `.ps1` in the system ANSI
  codepage rather than UTF-8.

  The `:powershell` environment overrides the selection: the program (name
  or path), or `{program, args}` where `args` precede the script.
  """

  @behaviour DarkChonkyWhale.Executor.Runtime

  alias DarkChonkyWhale.Executor.Runner

  @impl true
  def run(code, ctx) do
    with {:ok, {program, base_args}} <- powershell(ctx.env),
         {:ok, exe} <- executable(program) do
      Runner.run(script_plan(exe, base_args, code), ctx)
    end
  end

  defp powershell(env) do
    case Map.get(env, :powershell) do
      nil ->
        case System.find_executable("pwsh") || System.find_executable("powershell") do
          nil -> {:error, "powershell not found: neither pwsh nor powershell is on PATH"}
          path -> {:ok, {path, @default_args}}
        end

      {program, args} when is_binary(program) and is_list(args) ->
        {:ok, {program, args}}

      program when is_binary(program) ->
        {:ok, {program, @default_args}}
    end
  end

  # The script goes to the runner as content, with the `:script` atom where
  # its path belongs in the argument vector. The BOM comes first: without it
  # Windows PowerShell 5.1 decodes the file in the system ANSI codepage and
  # any non-ASCII code arrives mangled.
  defp script_plan(exe, base_args, code) do
    body = "\uFEFF[Console]::OutputEncoding = [Text.Encoding]::UTF8\r\n" <> crlf(code) <> "\r\n"

    %{exe: exe, args: base_args ++ ["-File", :script], cwd: nil, script: %{name: "script.ps1", content: body}}
  end

  defp crlf(text), do: text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")

  defp executable(program) do
    case System.find_executable(program) do
      nil -> {:error, "powershell not found: #{program}"}
      path -> {:ok, path}
    end
  end
end
