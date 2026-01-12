defmodule Maraithon.Tools.ReadFile do
  @moduledoc """
  Tool for reading file contents.
  """

  @max_file_size 100_000  # 100KB

  def execute(args) do
    path = args["path"]

    unless path do
      {:error, "path is required"}
    else
      read_file(path)
    end
  end

  defp read_file(path) do
    # Security: Don't allow reading outside configured directories
    # For now, just read the file
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_size ->
        {:error, "file too large (max #{@max_file_size} bytes)"}

      {:ok, _stat} ->
        case File.read(path) do
          {:ok, content} ->
            {:ok,
             %{
               path: path,
               content: content,
               size: byte_size(content)
             }}

          {:error, reason} ->
            {:error, "failed to read file: #{reason}"}
        end

      {:error, reason} ->
        {:error, "file not found or not accessible: #{reason}"}
    end
  end
end
