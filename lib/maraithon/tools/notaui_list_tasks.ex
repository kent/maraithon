defmodule Maraithon.Tools.NotauiListTasks do
  @moduledoc """
  Lists tasks from Notaui MCP (`task.list`).
  """

  alias Maraithon.Connectors.Notaui

  @allowed_filters ~w(
    account_id
    project_id
    due_before
    limit
    offset
    verbose
    include_notes
    include_notes_preview
  )a

  def execute(args) when is_map(args) do
    user_id = optional_user_id(args)

    args
    |> normalize_filter()
    |> then(fn filter -> list_tasks(user_id, filter) end)
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

      {:error, :no_token} ->
        {:error, "notaui_not_connected"}

      {:error, :no_refresh_token} ->
        {:error, "notaui_reauth_required"}

      {:error, :reauth_required} ->
        {:error, "notaui_reauth_required"}

      {:error, :unknown_account_id} ->
        {:error, "notaui_unknown_account_id"}

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

  defp list_tasks(nil, filter), do: Notaui.list_tasks(filter)
  defp list_tasks(user_id, filter), do: Notaui.list_tasks(user_id, filter)

  defp optional_user_id(%{"user_id" => user_id}) when is_binary(user_id) do
    case String.trim(user_id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_user_id(_args), do: nil
end
