defmodule MaraithonWeb.NotauiController do
  use MaraithonWeb, :controller

  alias Maraithon.Connectors.Notaui

  @default_topic "notaui:tasks"

  @doc """
  Pulls a Notaui task snapshot and publishes it to a PubSub topic.

  POST /api/v1/integrations/notaui/sync
  {
    "topic": "notaui:tasks",
    "filter": {"statuses": ["inbox", "available"], "limit": 50}
  }
  """
  def sync(conn, params) do
    topic = normalize_topic(params["topic"])
    filter = normalize_filter(params["filter"])

    with :ok <- validate_topic(topic),
         {:ok, result} <- Notaui.publish_task_snapshot(topic, filter) do
      conn
      |> put_status(:accepted)
      |> json(%{
        status: "published",
        topic: result.topic,
        event_type: result.event_type,
        task_count: result.task_count
      })
    else
      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "notaui integration is not configured"})

      {:error, :invalid_topic} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "topic is required"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to sync Notaui tasks", reason: inspect(reason)})
    end
  end

  defp normalize_topic(topic) when is_binary(topic) do
    case String.trim(topic) do
      "" -> @default_topic
      value -> value
    end
  end

  defp normalize_topic(_), do: @default_topic

  defp normalize_filter(filter) when is_map(filter), do: filter
  defp normalize_filter(_), do: %{}

  defp validate_topic(topic) when is_binary(topic) and topic != "", do: :ok
  defp validate_topic(_), do: {:error, :invalid_topic}
end
