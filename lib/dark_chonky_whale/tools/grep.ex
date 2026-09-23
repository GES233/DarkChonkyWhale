defmodule DarkChonkyWhale.Tools.Grep do
  @moduledoc """
  The `grep` tool: search file contents by regular expression.

  The walk is `DarkChonkyWhale.Tools.Walk`'s, so build output and vendored
  code are pruned and results are deterministic. `path` may be a directory
  (searched recursively) or a single file.

  Hits are rendered as `path:line_number:text`, with paths relative to the
  working directory (`env[:cwd]`), `/`-separated — the form `read`, `edit`
  and `write` accept back.

  Only text files are searched: a file is skipped if it looks binary (a NUL
  byte in its first block) or is larger than `:max_file_bytes` (default 2 MB).
  Long lines are truncated to `:max_line_chars` (default 500) so one minified
  file cannot blow up the output, and the output is capped at `:limit`
  (default 100) matching lines.

  `:options` are passed to `Regex.compile/2`, e.g. `"i"` for a
  case-insensitive search.
  """

  @behaviour DarkChonkyWhale.Tool

  alias DarkChonkyWhale.Tool
  alias DarkChonkyWhale.Tools.Walk

  @default_limit 100
  @default_max_file_bytes 2_000_000
  @default_max_line_chars 500
  @sniff_bytes 8192

  @impl true
  def schema do
    %{
      name: "grep",
      description:
        "Search file contents with a regular expression, recursively (build " <>
          "output and vendored code are pruned). Returns matching lines as " <>
          "`path:line_number:text`, in path order. `options` are regex options, " <>
          "e.g. \"i\" for a case-insensitive search.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Regular expression"},
          "path" => %{
            "type" => "string",
            "description" => "File or directory to search. Default: the working directory."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max matching lines to return. Default #{@default_limit}."
          },
          "options" => %{"type" => "string", "description" => "Regex options, e.g. \"i\"."}
        },
        "required" => ["pattern"]
      }
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, env) when is_binary(pattern) do
    base =
      case Map.get(args, "path") do
        nil -> cwd(env)
        path -> Tool.resolve_path(env, path)
      end

    with {:ok, regex} <- compile(pattern, Map.get(args, "options")),
         {:ok, files} <- target_files(base, env) do
      limit = positive(args["limit"], @default_limit)
      max_bytes = non_negative(args["max_file_bytes"], @default_max_file_bytes)
      max_chars = non_negative(args["max_line_chars"], @default_max_line_chars)

      # One hit past the limit distinguishes "exactly at the cap" from
      # "more matches than were shown".
      hits = collect(files, cwd(env), regex, max_bytes, max_chars, limit)

      {:ok, render(base, hits, limit)}
    end
  end

  def execute(_args, _env), do: {:error, "pattern is a required string"}

  defp cwd(env), do: env[:cwd] || File.cwd!()

  # Model-supplied numbers: accept integers, fall back on anything else
  # (a string from a sloppy tool call must not crash the pipeline).
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default

  defp collect(files, cwd, regex, max_bytes, max_chars, limit) do
    Enum.reduce_while(files, [], fn path, acc ->
      acc = acc ++ file_hits(path, cwd, regex, max_bytes, max_chars)

      if length(acc) > limit, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp compile(pattern, options) when is_binary(options) or is_nil(options) do
    case Regex.compile(pattern, options || "") do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {message, at}} ->
        {:error, "invalid pattern: #{message} (at byte #{at})"}
    end
  end

  defp compile(_pattern, options) do
    {:error, "options must be a string, got: #{inspect(options)}"}
  end

  defp target_files(base, env) do
    case File.stat(base) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, Walk.files(base, env)}
      {:ok, %File.Stat{type: :regular}} -> {:ok, [base]}
      {:ok, _} -> {:error, "not a file or directory: #{base}"}
      {:error, :enoent} -> {:error, "path not found: #{base}"}
      {:error, reason} -> {:error, "cannot search #{base}: #{:file.format_error(reason)}"}
    end
  end

  defp file_hits(path, cwd, regex, max_bytes, max_chars) do
    case read_text(path, max_bytes) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, n} ->
          "#{Walk.relative(path, cwd)}:#{n}:#{truncate(line, max_chars)}"
        end)

      :skip ->
        []
    end
  end

  # The size check and the binary sniff run before the full read: the search
  # must not pull a huge blob into memory.
  defp read_text(path, max_bytes) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max_bytes -> sniff_and_read(path)
      _ -> :skip
    end
  end

  defp sniff_and_read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        head =
          case IO.binread(io, @sniff_bytes) do
            data when is_binary(data) -> data
            _ -> ""
          end

        File.close(io)

        with false <- String.contains?(head, <<0>>),
             {:ok, text} <- File.read(path) do
          {:ok, text}
        else
          _ -> :skip
        end

      {:error, _reason} ->
        :skip
    end
  end

  defp truncate(line, max) when max <= 0, do: line

  defp truncate(line, max) do
    if String.length(line) > max do
      String.slice(line, 0, max) <> "..."
    else
      line
    end
  end

  defp render(base, [], _limit), do: "(no matches in #{base})"

  defp render(_base, hits, limit) do
    text = hits |> Enum.take(limit) |> Enum.join("\n")

    if length(hits) > limit do
      text <> "\n... (capped at #{limit} matching lines)"
    else
      text
    end
  end
end
