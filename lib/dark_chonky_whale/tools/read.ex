defmodule DarkChonkyWhale.Tools.Read do
  @moduledoc """
  The `read` tool: read a file's contents with line numbers, one page at a
  time.

  The display is LF-normalized (CRLF files show without the `\\r`), so what
  the model sees is exactly the view the `edit` tool matches against.
  """

  @behaviour DarkChonkyWhale.Tool

  alias DarkChonkyWhale.Tool

  @impl true
  def schema do
    %{
      name: "read",
      description: "Read a file's contents with line numbers.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path to the file"},
          "offset" => %{
            "type" => "integer",
            "description" => "Start line (1-based). Default 1."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max lines to read. Default 2000."
          }
        },
        "required" => ["file_path"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    path = Tool.resolve_path(env, args["file_path"])
    offset = max(1, Map.get(args, "offset", 1))
    limit = max(1, Map.get(args, "limit", 2000))

    case File.read(path) do
      {:ok, text} -> {:ok, page(normalize_eol(text), offset, limit)}
      {:error, :enoent} -> {:error, "file not found: #{path}"}
      {:error, :eisdir} -> {:error, "not a file: #{path}"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp normalize_eol(text), do: String.replace(text, "\r\n", "\n")

  defp page("", _offset, _limit), do: "(empty file)"

  defp page(text, offset, limit) do
    lines = String.split(text, "\n")
    total = length(lines)
    chunk = lines |> Enum.drop(offset - 1) |> Enum.take(limit)

    case chunk do
      [] ->
        "(offset #{offset} is past the end; #{total} lines total)"

      _ ->
        numbered =
          chunk
          |> Enum.with_index(offset)
          |> Enum.map_join("\n", fn {line, n} -> "#{n}\t#{line}" end)

        if offset - 1 + length(chunk) < total do
          numbered <>
            "\n... (#{total} lines total, showing #{offset}-#{offset + length(chunk) - 1})"
        else
          numbered
        end
    end
  end
end
