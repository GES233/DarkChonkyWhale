defmodule DarkChonkyWhale.Tools.Walk do
  # Defined ahead of the moduledoc, which reads it.
  @default_ignore [
    ".git",
    ".elixir_ls",
    "_build",
    "cover",
    "deps",
    "doc",
    "node_modules",
    "tmp",
    ".venv"
  ]

  @moduledoc """
  The file-tree plumbing the search tools (`glob`, `grep`) share: a
  deterministic, symlink-safe walk, and the glob matcher they filter with.

  A walk prunes directory *names* that only ever hold build output or
  vendored code:

      #{inspect(@default_ignore)}

  `env[:search_ignore_dirs]` replaces that list for a call; an empty list
  walks everything reachable. Symlinked directories are never followed
  (`File.lstat/1` sees the link, not the target), so a self-referential link
  cannot send a walk into a loop.

  Paths reported by the search tools go through `relative/2`, which makes
  them relative to the working directory and uses `/` separators on every
  platform — so they can be handed straight back to `read`, `edit` or
  `write`, which resolve against the same `:cwd`.
  """

  @doc "The directory names pruned for a call, from `env[:search_ignore_dirs]`."
  @spec ignore_dirs(DarkChonkyWhale.Tool.env()) :: [String.t()]
  # Access, not Map.get: a direct caller (the in-process Elixir runtime) may
  # hand over a keyword list, and both shapes read the same through it.
  def ignore_dirs(env), do: env[:search_ignore_dirs] || @default_ignore

  @doc """
  Every regular file under `base`, pruned, in path order so that repeated
  calls report identically. `base` is trusted to exist and be a directory.
  """
  @spec files(Path.t(), DarkChonkyWhale.Tool.env()) :: [Path.t()]
  def files(base, env) do
    ignore = MapSet.new(ignore_dirs(env))
    base |> walk(ignore, []) |> Enum.sort()
  end

  @doc """
  Compile a glob into an anchored regex. Supported wildcards: `*` (any
  characters within a path segment), `?` (exactly one character) and `**`
  (any number of directory prefixes, including none) — so `"**/*.ex"`
  matches both `"lib/a.ex"` and `"lib/nested/b.ex"`. Matching runs on
  `/`-joined paths.
  """
  @spec compile_glob(String.t()) :: Regex.t()
  def compile_glob(glob), do: Regex.compile!("^" <> source(glob) <> "$")

  @doc """
  Does the file `path` (somewhere under `base`) match `glob`? A glob with no
  `/` is matched against the file's name at any depth; one with a `/` is
  matched against the path relative to `base`.
  """
  @spec glob_match?(Regex.t(), String.t(), Path.t(), Path.t()) :: boolean()
  def glob_match?(regex, glob, path, base) do
    if String.contains?(glob, "/") do
      Regex.match?(regex, relative(path, base))
    else
      Regex.match?(regex, Path.basename(path))
    end
  end

  @doc "`path` relative to `base`, with `/` separators on every platform."
  @spec relative(Path.t(), Path.t()) :: String.t()
  def relative(path, base), do: path |> Path.relative_to(base) |> slash()

  @doc "The path with `/` separators on every platform."
  @spec slash(Path.t()) :: String.t()
  def slash(path), do: path |> Path.split() |> Enum.join("/")

  ## Internal

  defp walk(dir, ignore, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, acc ->
          path = Path.join(dir, entry)

          cond do
            MapSet.member?(ignore, entry) -> acc
            directory?(path) -> walk(path, ignore, acc)
            File.regular?(path) -> [path | acc]
            true -> acc
          end
        end)

      # An unreadable subdirectory loses its files, not the whole search.
      {:error, _reason} ->
        acc
    end
  end

  defp directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp source(<<>>), do: ""
  defp source(<<"**/", rest::binary>>), do: "(?:[^/]+/)*" <> source(rest)
  defp source(<<"**", rest::binary>>), do: ".*" <> source(rest)
  defp source(<<"*", rest::binary>>), do: "[^/]*" <> source(rest)
  defp source(<<"?", rest::binary>>), do: "[^/]" <> source(rest)

  defp source(<<char::utf8, rest::binary>>) do
    Regex.escape(<<char::utf8>>) <> source(rest)
  end
end
