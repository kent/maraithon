defmodule Maraithon.Tools.ReadFile do
  @moduledoc """
  Tool for reading file contents.
  """

  alias Maraithon.Tools.PathPolicy

  # 100KB
  @max_file_size 100_000

  def execute(args) do
    path = args["path"]

    cond do
      is_nil(path) ->
        {:error, "path is required"}

      true ->
        with {:ok, resolved_path} <- PathPolicy.resolve_allowed_path(path) do
          read_file(resolved_path)
        end
    end
  end

  defp read_file(path) do
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
