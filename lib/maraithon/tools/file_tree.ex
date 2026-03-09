defmodule Maraithon.Tools.FileTree do
  @moduledoc """
  Tool for getting a directory tree visualization.
  """

  alias Maraithon.Tools.PathPolicy

  @max_depth 4
  @max_entries 200

  def execute(args) do
    path = args["path"] || "."
    depth = min(args["depth"] || @max_depth, @max_depth)

    with {:ok, resolved_path} <- PathPolicy.resolve_allowed_path(path) do
      build_tree(resolved_path, depth)
    end
  end

  defp build_tree(path, max_depth) do
    path = Path.expand(path)

    unless File.dir?(path) do
      {:error, "Not a directory: #{path}"}
    else
      {tree_lines, count} = build_tree_lines(path, "", 0, max_depth, 0)

      tree_str =
        [Path.basename(path) <> "/" | tree_lines]
        |> Enum.join("\n")

      {:ok,
       %{
         path: path,
         tree: tree_str,
         entries: count,
         truncated: count >= @max_entries
       }}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_tree_lines(_path, _prefix, depth, max_depth, count) when depth >= max_depth do
    {[], count}
  end

  defp build_tree_lines(_path, _prefix, _depth, _max_depth, count) when count >= @max_entries do
    {["... (truncated)"], count}
  end

  defp build_tree_lines(path, prefix, depth, max_depth, count) do
    entries =
      path
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reject(&String.starts_with?(&1, "."))

    {lines, final_count} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], count}, fn {entry, idx}, {acc_lines, acc_count} ->
        if acc_count >= @max_entries do
          {acc_lines, acc_count}
        else
          is_last = idx == length(entries) - 1
          connector = if is_last, do: "└── ", else: "├── "
          child_prefix = if is_last, do: "    ", else: "│   "

          full_path = Path.join(path, entry)
          is_dir = File.dir?(full_path)

          entry_str = if is_dir, do: entry <> "/", else: entry
          line = prefix <> connector <> entry_str

          if is_dir do
            {child_lines, new_count} =
              build_tree_lines(
                full_path,
                prefix <> child_prefix,
                depth + 1,
                max_depth,
                acc_count + 1
              )

            {acc_lines ++ [line | child_lines], new_count}
          else
            {acc_lines ++ [line], acc_count + 1}
          end
        end
      end)

    {lines, final_count}
  end
end
