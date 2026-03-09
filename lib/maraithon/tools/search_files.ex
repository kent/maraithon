defmodule Maraithon.Tools.SearchFiles do
  @moduledoc """
  Tool for searching file contents with regex patterns.
  """

  alias Maraithon.Tools.PathPolicy

  @max_results 50
  @max_context_lines 2
  @max_file_size 1_000_000

  def execute(args) do
    path = args["path"] || "."
    pattern = args["pattern"]
    file_pattern = args["file_pattern"] || "**/*"

    cond do
      is_nil(pattern) or pattern == "" ->
        {:error, "pattern is required"}

      true ->
        with :ok <- validate_file_pattern(file_pattern),
             {:ok, resolved_path} <- PathPolicy.resolve_allowed_path(path) do
          search_files(resolved_path, pattern, file_pattern, path)
        end
    end
  end

  defp search_files(base_path, pattern, file_pattern, original_path) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        full_pattern = Path.join(base_path, file_pattern)

        matches =
          Path.wildcard(full_pattern)
          |> Enum.filter(&File.regular?/1)
          |> Enum.filter(&PathPolicy.allowed_path?/1)
          |> Enum.filter(&searchable_file?/1)
          |> Enum.flat_map(&search_file(&1, regex))
          |> Enum.take(@max_results)

        {:ok,
         %{
           base_path: original_path,
           pattern: pattern,
           file_pattern: file_pattern,
           matches: matches,
           count: length(matches),
           truncated: length(matches) >= @max_results
         }}

      {:error, reason} ->
        {:error, "Invalid regex pattern: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp validate_file_pattern(file_pattern) do
    cond do
      Path.type(file_pattern) == :absolute ->
        {:error, "file_pattern must be relative"}

      String.contains?(file_pattern, "..") ->
        {:error, "file_pattern must not contain '..'"}

      true ->
        :ok
    end
  end

  defp searchable_file?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_file_size -> true
      _ -> false
    end
  end

  defp search_file(file_path, regex) do
    case File.read(file_path) do
      {:ok, content} ->
        if String.valid?(content) do
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _num} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {line, line_num} ->
            %{
              file: file_path,
              line_num: line_num,
              line: String.slice(line, 0, 200),
              context: get_context(content, line_num)
            }
          end)
        else
          []
        end

      {:error, _} ->
        []
    end
  end

  defp get_context(content, line_num) do
    lines = String.split(content, "\n")

    start_line = max(1, line_num - @max_context_lines)
    end_line = min(length(lines), line_num + @max_context_lines)

    lines
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.with_index(start_line)
    |> Enum.map(fn {line, num} ->
      prefix = if num == line_num, do: "> ", else: "  "
      "#{prefix}#{num}: #{String.slice(line, 0, 100)}"
    end)
    |> Enum.join("\n")
  end
end
