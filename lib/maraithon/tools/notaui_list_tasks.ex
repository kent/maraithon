defmodule Maraithon.Tools.NotauiListTasks do
  @moduledoc """
  Lists tasks from Notaui MCP (`task.list`).
  """

  alias Maraithon.Connectors.Notaui

  @allowed_filters ~w(project_id due_before limit offset verbose include_notes include_notes_preview)a

  def execute(args) when is_map(args) do
    args
    |> normalize_filter()
    |> then(&Notaui.list_tasks/1)
    |> case do
      {:ok, tasks} ->
        {:ok,
         %{
           source: "notaui",
           task_count: length(tasks),
           tasks: tasks
         }}

      {:error, :not_configured} ->
        {:error, "notaui_not_configured"}

      {:error, reason} ->
        {:error, "notaui_list_failed: #{inspect(reason)}"}
    end
  end

  defp normalize_filter(args) do
    base_filter =
      Enum.reduce(@allowed_filters, %{}, fn key, acc ->
        map_key = Atom.to_string(key)

        case Map.fetch(args, map_key) do
          {:ok, value} -> Map.put(acc, map_key, value)
          :error -> acc
        end
      end)

    case Map.get(args, "statuses") do
      nil ->
        base_filter

      statuses when is_list(statuses) ->
        Map.put(base_filter, "statuses", statuses)

      statuses when is_binary(statuses) ->
        parsed =
          statuses
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(base_filter, "statuses", parsed)

      _ ->
        base_filter
    end
  end
end
