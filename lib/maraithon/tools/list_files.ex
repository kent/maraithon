defmodule Maraithon.Tools.ListFiles do
  @moduledoc """
  Tool for listing files in a directory with glob patterns.
  """

  @max_results 100

  def execute(args) do
    path = args["path"] || "."
    pattern = args["pattern"] || "**/*"

    list_files(path, pattern)
  end

  defp list_files(base_path, pattern) do
    full_pattern = Path.join(base_path, pattern)

    files =
      Path.wildcard(full_pattern)
      |> Enum.filter(&File.regular?/1)
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
       base_path: base_path,
       pattern: pattern,
       files: files,
       count: length(files),
       truncated: length(files) >= @max_results
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
