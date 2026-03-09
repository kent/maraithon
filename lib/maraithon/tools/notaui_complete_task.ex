defmodule Maraithon.Tools.NotauiCompleteTask do
  @moduledoc """
  Completes a Notaui task (`task.complete`).
  """

  alias Maraithon.Connectors.Notaui

  def execute(args) when is_map(args) do
    with {:ok, task_id} <- required_task_id(args),
         {:ok, task} <- Notaui.complete_task(task_id, optional_params(args)) do
      {:ok, %{source: "notaui", task: task}}
    else
      {:error, :not_configured} -> {:error, "notaui_not_configured"}
      {:error, :missing_task_id} -> {:error, "task_id is required"}
      {:error, reason} -> {:error, "notaui_complete_failed: #{inspect(reason)}"}
    end
  end

  defp required_task_id(%{"task_id" => task_id}) when is_binary(task_id) do
    case String.trim(task_id) do
      "" -> {:error, :missing_task_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_task_id(_), do: {:error, :missing_task_id}

  defp optional_params(args) do
    Enum.reduce(["verbose", "include_notes"], %{}, fn key, acc ->
      case Map.fetch(args, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
