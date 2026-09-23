defmodule DarkChonkyWhale.Tools.Edit do
  @moduledoc """
  The `edit` tool: replace a unique string occurrence in a file.

  Line endings: matching runs on an LF-normalized view (models emit LF and
  cannot reliably reproduce `\\r`), and the file's original convention is
  restored on write — a CRLF file stays CRLF, byte for byte outside the
  replaced region. A BOM and the trailing-newline state are preserved. A
  file with *mixed* endings is normalized wholesale to its dominant
  convention, and the result message says so.

  When exact matching finds nothing, a fallback retry ignores trailing
  whitespace per line; the replacement splices only the matched lines,
  leaving the rest of the file byte-identical.
  """

  @behaviour DarkChonkyWhale.Tool

  alias DarkChonkyWhale.Tool

  @bom "\xEF\xBB\xBF"

  @impl true
  def schema do
    %{
      name: "edit",
      description:
        "Edit a file by replacing an exact string match. old_string must " <>
          "appear exactly once; include enough surrounding context for uniqueness. " <>
          "Line endings are matched flexibly (LF or CRLF both work).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path to the file to edit"},
          "old_string" => %{
            "type" => "string",
            "description" => "Exact text to find (must be unique)"
          },
          "new_string" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["file_path", "old_string", "new_string"]
      }
    }
  end

  @impl true
  def execute(%{"file_path" => _, "old_string" => old, "new_string" => new} = args, env)
      when is_binary(old) and is_binary(new) do
    path = Tool.resolve_path(env, args["file_path"])

    cond do
      old == "" ->
        {:error, "old_string must not be empty"}

      old == new ->
        {:error, "old_string and new_string are identical"}

      true ->
        with {:ok, raw} <- read(path),
             {:ok, edited, note} <- replace_preserving(raw, old, new),
             :ok <- File.write(path, edited) do
          {:ok, "edited #{path}" <> note}
        end
    end
  end

  def execute(_args, _env) do
    {:error, "file_path, old_string and new_string are required strings"}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "file not found: #{path}"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  ## The line-ending-aware replace

  defp replace_preserving(raw, old, new) do
    {bom, body} = split_bom(raw)
    eol = classify_eol(body)

    normalized = normalize_eol(body)
    old = normalize_eol(old)
    new = normalize_eol(new)

    case replace_exact(normalized, old, new) do
      {:ok, result, how} ->
        {:ok, bom <> restore_eol(result, eol), note(eol, how)}

      {:error, {:not_unique, n}} ->
        {:error, "old_string appears #{n} times; include more surrounding context"}

      {:error, :not_found} ->
        case replace_fuzzy(normalized, old, new) do
          {:ok, result} ->
            {:ok, bom <> restore_eol(result, eol), note(eol, :fuzzy)}

          {:error, :not_found} ->
            {:error, "old_string not found (also tried ignoring trailing whitespace)"}

          {:error, {:not_unique, n}} ->
            {:error, "old_string appears #{n} times; include more surrounding context"}
        end
    end
  end

  defp note(:lf, :exact), do: ""
  defp note(:crlf, :exact), do: " (CRLF preserved)"
  defp note(:lf, :fuzzy), do: " (matched ignoring trailing whitespace)"
  defp note(:crlf, :fuzzy), do: " (CRLF preserved; matched ignoring trailing whitespace)"

  defp note({:mixed, dominant}, _how),
    do: " (mixed line endings normalized to #{dominant_name(dominant)})"

  defp dominant_name(:lf), do: "LF"
  defp dominant_name(:crlf), do: "CRLF"

  defp split_bom(@bom <> rest), do: {@bom, rest}
  defp split_bom(text), do: {"", text}

  defp classify_eol(text) do
    crlf = text |> :binary.matches("\r\n") |> length()
    lf = (text |> :binary.matches("\n") |> length()) - crlf

    cond do
      crlf > 0 and lf > 0 -> {:mixed, if(crlf >= lf, do: :crlf, else: :lf)}
      crlf > 0 -> :crlf
      true -> :lf
    end
  end

  defp normalize_eol(text), do: String.replace(text, "\r\n", "\n")

  defp restore_eol(text, :crlf), do: String.replace(text, "\n", "\r\n")
  defp restore_eol(text, {:mixed, :crlf}), do: String.replace(text, "\n", "\r\n")
  defp restore_eol(text, _lf), do: text

  defp replace_exact(content, old, new) do
    case content |> :binary.matches(old) |> length() do
      0 -> {:error, :not_found}
      1 -> {:ok, :binary.replace(content, old, new), :exact}
      n -> {:error, {:not_unique, n}}
    end
  end

  # Line-window matching with trailing whitespace ignored; the replacement
  # splices only the matched lines, so the rest of the file is untouched.
  defp replace_fuzzy(content, old, new) do
    lines = String.split(content, "\n")
    width = length(String.split(old, "\n"))
    wanted = old |> String.split("\n") |> Enum.map(&String.trim_trailing/1)

    matches =
      lines
      |> Enum.chunk_every(width, 1, :discard)
      |> Enum.with_index()
      |> Enum.filter(fn {window, _i} -> Enum.map(window, &String.trim_trailing/1) == wanted end)
      |> Enum.map(&elem(&1, 1))

    case matches do
      [] ->
        {:error, :not_found}

      [index] ->
        result =
          Enum.take(lines, index) ++
            String.split(new, "\n") ++ Enum.drop(lines, index + width)

        {:ok, Enum.join(result, "\n")}

      many ->
        {:error, {:not_unique, length(many)}}
    end
  end
end
