defmodule DarkChonkyWhale.Tools.Write do
  @moduledoc """
  The `write` tool: create a file or completely overwrite an existing one,
  creating parent directories as needed.
  """

  @behaviour DarkChonkyWhale.Tool

  alias DarkChonkyWhale.Tool

  @impl true
  def schema do
    %{
      name: "write",
      description:
        "Create a new file or completely overwrite an existing one. " <>
          "Parent directories are created as needed.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path for the file"},
          "content" => %{"type" => "string", "description" => "Full file content to write"}
        },
        "required" => ["file_path", "content"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    path = Tool.resolve_path(env, args["file_path"])
    content = args["content"] || ""

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      lines = content |> String.split("\n") |> length()
      {:ok, "wrote #{lines} lines to #{path}"}
    else
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
