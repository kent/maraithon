defmodule Maraithon.Tools.PathPolicy do
  @moduledoc """
  Shared path sandbox policy for filesystem tools.
  """

  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @doc """
  Resolve a path and enforce that it stays within allowed roots.
  """
  def resolve_allowed_path(path) when is_binary(path) do
    resolved = resolve_path(path)

    with {:ok, root} <- matching_root(resolved),
         true <- no_symlink_under_root?(resolved, root) do
      {:ok, resolved}
    else
      _ -> {:error, "path is outside allowed roots"}
    end
  end

  @doc """
  Check whether a path is within configured tool roots.
  """
  def allowed_path?(path) when is_binary(path) do
    resolved = resolve_path(path)

    match?({:ok, _root}, matching_root(resolved))
  end

  defp resolve_path(path) do
    Path.expand(path)
  end

  defp no_symlink_under_root?(path, root) do
    path
    |> paths_under_root(root)
    |> Enum.reduce_while(true, fn prefix, _acc ->
      case File.lstat(prefix) do
        {:ok, %{type: :symlink}} -> {:halt, false}
        {:ok, _} -> {:cont, true}
        {:error, :enoent} -> {:cont, true}
        {:error, _} -> {:halt, false}
      end
    end)
  end

  defp paths_under_root(path, root) do
    relative = Path.relative_to(path, root)

    case relative do
      "." ->
        []

      _ ->
        relative
        |> Path.split()
        |> Enum.scan(root, &Path.join(&2, &1))
    end
  end

  defp matching_root(path) do
    RuntimeConfig.tool_allowed_paths()
    |> Enum.map(&resolve_path/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find_value(:error, fn root ->
      if within_root?(path, root), do: {:ok, root}, else: false
    end)
  end

  defp within_root?(path, root) do
    path_parts = Path.split(path)
    root_parts = Path.split(root)

    Enum.take(path_parts, length(root_parts)) == root_parts
  end
end
