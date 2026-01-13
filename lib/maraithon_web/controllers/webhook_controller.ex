defmodule MaraithonWeb.WebhookController do
  use MaraithonWeb, :controller

  alias Maraithon.Connectors.{Connector, GitHub}

  require Logger

  @doc """
  Handle GitHub webhooks.

  POST /webhooks/github
  """
  def github(conn, params) do
    # Get raw body for signature verification
    # Note: This requires a custom plug to cache the raw body
    raw_body = conn.assigns[:raw_body] || Jason.encode!(params)

    case GitHub.verify_signature(conn, raw_body) do
      :ok ->
        handle_connector(conn, params, GitHub)

      {:error, reason} ->
        Logger.warning("GitHub webhook signature verification failed", reason: reason)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid signature"})
    end
  end

  # Generic handler for any connector
  defp handle_connector(conn, params, connector_module) do
    case connector_module.handle_webhook(conn, params) do
      {:ok, topic, event} ->
        # Publish to PubSub
        Connector.publish(topic, event)

        conn
        |> put_status(:ok)
        |> json(%{
          status: "published",
          topic: topic,
          event_type: event.type
        })

      {:ignore, reason} ->
        Logger.debug("Webhook ignored", reason: reason)

        conn
        |> put_status(:ok)
        |> json(%{status: "ignored", reason: reason})

      {:error, reason} ->
        Logger.warning("Webhook processing failed", reason: inspect(reason))

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to process webhook", reason: inspect(reason)})
    end
  end
end
