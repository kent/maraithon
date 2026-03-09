defmodule Maraithon.Tools.ListFiles do
  @moduledoc """
  Tool for listing files in a directory with glob patterns.
  """

  alias Maraithon.Tools.PathPolicy

  @max_results 100

  def execute(args) do
    path = args["path"] || "."
    pattern = args["pattern"] || "**/*"

    with :ok <- validate_pattern(pattern),
         {:ok, resolved_path} <- PathPolicy.resolve_allowed_path(path) do
      list_files(resolved_path, pattern, path)
    end
  end

  defp list_files(base_path, pattern, original_path) do
    full_pattern = Path.join(base_path, pattern)

    files =
      Path.wildcard(full_pattern)
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&PathPolicy.allowed_path?/1)
      |> Enum.take(@max_results)
      |> Enum.map(fn file ->
        stat = File.stat!(file)

        %{
          path: file,
          size: stat.size,
          modified: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
        }
      end)

    {:ok,
     %{
       base_path: original_path,
       pattern: pattern,
       files: files,
       count: length(files),
       truncated: length(files) >= @max_results
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp validate_pattern(pattern) do
    cond do
      Path.type(pattern) == :absolute ->
        {:error, "pattern must be relative"}

      String.contains?(pattern, "..") ->
        {:error, "pattern must not contain '..'"}

      true ->
        :ok
    end
  end
end
