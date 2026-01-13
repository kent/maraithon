defmodule MaraithonWeb.WebhookController do
  use MaraithonWeb, :controller

  alias Maraithon.Connectors.{
    Connector,
    GitHub,
    GoogleCalendar,
    Gmail,
    Slack,
    WhatsApp,
    Linear,
    Telegram
  }

  require Logger

  @doc """
  Handle GitHub webhooks.

  POST /webhooks/github
  """
  def github(conn, params) do
    # Get raw body for signature verification (cached by CacheRawBody plug)
    raw_body = get_raw_body!(conn, params)

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

  @doc """
  Handle Google Calendar push notifications.

  POST /webhooks/google/calendar
  """
  def google_calendar(conn, params) do
    handle_connector(conn, params, GoogleCalendar)
  end

  @doc """
  Handle Gmail push notifications via Cloud Pub/Sub.

  POST /webhooks/google/gmail
  """
  def google_gmail(conn, params) do
    handle_connector(conn, params, Gmail)
  end

  @doc """
  Handle Slack Events API webhooks.

  POST /webhooks/slack
  """
  def slack(conn, params) do
    raw_body = get_raw_body!(conn, params)

    case Slack.verify_signature(conn, raw_body) do
      :ok ->
        case Slack.handle_webhook(conn, params) do
          {:challenge, challenge} ->
            # URL verification - return the challenge
            conn
            |> put_status(:ok)
            |> text(challenge)

          {:ok, topic, event} ->
            Connector.publish(topic, event)

            conn
            |> put_status(:ok)
            |> json(%{status: "published", topic: topic, event_type: event.type})

          {:ignore, reason} ->
            conn
            |> put_status(:ok)
            |> json(%{status: "ignored", reason: reason})

          {:error, reason} ->
            Logger.warning("Slack webhook failed", reason: inspect(reason))

            conn
            |> put_status(:bad_request)
            |> json(%{error: inspect(reason)})
        end

      {:error, reason} ->
        Logger.warning("Slack signature verification failed", reason: reason)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid signature"})
    end
  end

  @doc """
  Handle WhatsApp webhooks from Meta.

  GET /webhooks/whatsapp - Webhook verification
  POST /webhooks/whatsapp - Message events
  """
  def whatsapp(conn, params) do
    # Check if this is a GET verification request
    if conn.method == "GET" do
      handle_whatsapp_verify(conn)
    else
      handle_whatsapp_event(conn, params)
    end
  end

  defp handle_whatsapp_verify(conn) do
    case WhatsApp.handle_webhook(conn, %{}) do
      {:verify, challenge} ->
        conn
        |> put_status(:ok)
        |> text(challenge)

      {:error, _reason} ->
        conn
        |> put_status(:forbidden)
        |> text("Verification failed")
    end
  end

  defp handle_whatsapp_event(conn, params) do
    raw_body = get_raw_body!(conn, params)

    case WhatsApp.verify_signature(conn, raw_body) do
      :ok ->
        case WhatsApp.handle_webhook(conn, params) do
          {:ok, topic, event} ->
            Connector.publish(topic, event)

            conn
            |> put_status(:ok)
            |> json(%{status: "published", topic: topic, event_type: event.type})

          {:ignore, reason} ->
            conn
            |> put_status(:ok)
            |> json(%{status: "ignored", reason: reason})

          {:error, reason} ->
            Logger.warning("WhatsApp webhook failed", reason: inspect(reason))

            conn
            |> put_status(:bad_request)
            |> json(%{error: inspect(reason)})
        end

      {:error, reason} ->
        Logger.warning("WhatsApp signature verification failed", reason: reason)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid signature"})
    end
  end

  @doc """
  Handle Linear webhooks.

  POST /webhooks/linear
  """
  def linear(conn, params) do
    raw_body = get_raw_body!(conn, params)

    case Linear.verify_signature(conn, raw_body) do
      :ok ->
        handle_connector(conn, params, Linear)

      {:error, reason} ->
        Logger.warning("Linear signature verification failed", reason: reason)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid signature"})
    end
  end

  @doc """
  Handle Telegram webhooks.

  POST /webhooks/telegram/:secret_path
  """
  def telegram(conn, params) do
    raw_body = get_raw_body!(conn, params)

    case Telegram.verify_signature(conn, raw_body) do
      :ok ->
        case Telegram.handle_webhook(conn, params) do
          {:ok, topic, event} ->
            Connector.publish(topic, event)

            conn
            |> put_status(:ok)
            |> json(%{status: "published", topic: topic, event_type: event.type})

          {:ignore, reason} ->
            conn
            |> put_status(:ok)
            |> json(%{status: "ignored", reason: reason})

          {:error, reason} ->
            Logger.warning("Telegram webhook failed", reason: inspect(reason))

            conn
            |> put_status(:bad_request)
            |> json(%{error: inspect(reason)})
        end

      {:error, reason} ->
        Logger.warning("Telegram verification failed", reason: reason)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid request"})
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

  # Gets the cached raw body, falling back to re-encoding with a warning.
  # The CacheRawBody plug should always provide the raw body, but we handle
  # the edge case gracefully while logging a warning.
  defp get_raw_body!(conn, params) do
    case conn.assigns[:raw_body] do
      nil ->
        Logger.warning("Raw body not cached - signature verification may fail",
          path: conn.request_path
        )

        # Fallback to re-encoding (may not match original bytes)
        Jason.encode!(params)

      raw_body ->
        raw_body
    end
  end
end
