defmodule MaraithonWeb.EventController do
  use MaraithonWeb, :controller

  require Logger

  @doc """
  Publish an event to PubSub for agents to receive.

  POST /api/v1/events
  {
    "topic": "calendar",
    "payload": { ... }
  }

  This is the ingress point for external systems to send events
  to agents subscribed to topics.
  """
  def publish(conn, params) do
    topic = params["topic"]
    payload = params["payload"] || %{}

    if is_nil(topic) or topic == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "topic is required"})
    else
      # Broadcast to all subscribers of this topic
      Phoenix.PubSub.broadcast(
        Maraithon.PubSub,
        topic,
        {:pubsub_event, topic, payload}
      )

      Logger.info("Event published", topic: topic)

      conn
      |> put_status(:accepted)
      |> json(%{
        status: "published",
        topic: topic
      })
    end
  end

  @doc """
  List all topics that have active subscribers.
  Useful for debugging and observability.
  """
  def topics(conn, _params) do
    # Note: Phoenix.PubSub doesn't provide a way to list topics
    # This would need custom tracking if needed
    conn
    |> json(%{
      message: "Topic listing not yet implemented",
      hint: "Subscribe agents to topics via config['subscribe']"
    })
  end
end
