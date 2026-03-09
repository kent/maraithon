defmodule Maraithon.Runtime.Config do
  @moduledoc """
  Runtime configuration helpers with lightweight validation.
  """

  require Logger

  @runtime_key Maraithon.Runtime

  @doc """
  Fetch a raw runtime config value with a default.
  """
  def get(key, default) do
    Application.get_env(:maraithon, @runtime_key, [])
    |> Keyword.get(key, default)
  end

  @doc """
  Fetch a positive integer runtime setting.
  Falls back to default when the value is invalid.
  """
  def positive_integer(key, default) when is_integer(default) and default > 0 do
    value = get(key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Logger.warning("Invalid runtime config; using default", key: key, value: inspect(value))
      default
    end
  end

  @doc """
  Returns absolute allowed tool root directories.
  """
  def tool_allowed_paths do
    get(:tool_allowed_paths, default_tool_roots())
    |> normalize_paths()
  end

  defp normalize_paths(paths) when is_binary(paths) do
    [paths] |> normalize_paths()
  end

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_paths(_), do: default_tool_roots() |> Enum.map(&Path.expand/1)

  defp default_tool_roots do
    [File.cwd!(), System.tmp_dir!()]
  end
end
