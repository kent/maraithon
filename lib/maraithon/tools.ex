defmodule Maraithon.Tools do
  @moduledoc """
  Tool registry and execution.
  """

  @tools %{
    "time" => Maraithon.Tools.Time,
    "http_get" => Maraithon.Tools.HttpGet,
    "read_file" => Maraithon.Tools.ReadFile,
    "list_files" => Maraithon.Tools.ListFiles,
    "file_tree" => Maraithon.Tools.FileTree,
    "search_files" => Maraithon.Tools.SearchFiles
  }

  @doc """
  Execute a tool by name.
  """
  def execute(name, args) do
    case Map.get(@tools, name) do
      nil -> {:error, "unknown_tool: #{name}"}
      module -> module.execute(args)
    end
  end

  @doc """
  List available tools.
  """
  def list do
    Map.keys(@tools)
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    Map.has_key?(@tools, name)
  end
end
