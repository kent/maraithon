defmodule Maraithon.Tools.NotauiUpdateTask do
  @moduledoc """
  Updates a Notaui task (`task.update`).
  """

  alias Maraithon.Connectors.Notaui

  @updatable_fields ~w(
    title
    notes
    status
    project_id
    parent_task_id
    defer_at
    due_at
    estimated_minutes
    flagged
    verbose
    include_notes
  )a

  def execute(args) when is_map(args) do
    with {:ok, task_id} <- required_task_id(args),
         {:ok, updates} <- extract_updates(args),
         {:ok, task} <- Notaui.update_task(task_id, updates) do
      {:ok, %{source: "notaui", task: task}}
    else
      {:error, :not_configured} -> {:error, "notaui_not_configured"}
      {:error, :missing_task_id} -> {:error, "task_id is required"}
      {:error, :no_updates} -> {:error, "at least one update field is required"}
      {:error, reason} -> {:error, "notaui_update_failed: #{inspect(reason)}"}
    end
  end

  defp required_task_id(%{"task_id" => task_id}) when is_binary(task_id) do
    case String.trim(task_id) do
      "" -> {:error, :missing_task_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_task_id(_), do: {:error, :missing_task_id}

  defp extract_updates(args) do
    updates =
      Enum.reduce(@updatable_fields, %{}, fn field, acc ->
        key = Atom.to_string(field)

        case Map.fetch(args, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    if map_size(updates) == 0 do
      {:error, :no_updates}
    else
      {:ok, updates}
    end
  end
end
