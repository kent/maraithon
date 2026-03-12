defmodule Maraithon.Tools.NotauiCompleteTask do
  @moduledoc """
  Completes a Notaui task (`task.complete`).
  """

  alias Maraithon.Connectors.Notaui

  def execute(args) when is_map(args) do
    user_id = optional_user_id(args)

    with {:ok, task_id} <- required_task_id(args),
         {:ok, task} <- complete_task(user_id, task_id, optional_params(args)) do
      {:ok, %{source: "notaui", task: task}}
    else
      {:error, :not_configured} -> {:error, "notaui_not_configured"}
      {:error, :no_token} -> {:error, "notaui_not_connected"}
      {:error, :no_refresh_token} -> {:error, "notaui_reauth_required"}
      {:error, :reauth_required} -> {:error, "notaui_reauth_required"}
      {:error, :unknown_account_id} -> {:error, "notaui_unknown_account_id"}
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
    Enum.reduce(["account_id", "verbose", "include_notes"], %{}, fn key, acc ->
      case Map.fetch(args, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp complete_task(nil, task_id, opts), do: Notaui.complete_task(task_id, opts)
  defp complete_task(user_id, task_id, opts), do: Notaui.complete_task(user_id, task_id, opts)

  defp optional_user_id(%{"user_id" => user_id}) when is_binary(user_id) do
    case String.trim(user_id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_user_id(_args), do: nil
end
