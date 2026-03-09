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

  alias Maraithon.InsightNotifications

  require Logger

  @doc """
  Handle GitHub webhooks.

  POST /webhooks/github
  """
  def github(conn, params) do
    handle_signed_connector(conn, params,
      connector_module: GitHub,
      signature_log: "GitHub webhook signature verification failed",
      signature_error: "Invalid signature"
    )
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
    handle_signed_connector(conn, params,
      connector_module: Slack,
      signature_log: "Slack signature verification failed",
      signature_error: "Invalid signature",
      on_verified: &handle_slack/2
    )
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
    handle_signed_connector(conn, params,
      connector_module: WhatsApp,
      signature_log: "WhatsApp signature verification failed",
      signature_error: "Invalid signature",
      failure_log: "WhatsApp webhook failed"
    )
  end

  @doc """
  Handle Linear webhooks.

  POST /webhooks/linear
  """
  def linear(conn, params) do
    handle_signed_connector(conn, params,
      connector_module: Linear,
      signature_log: "Linear signature verification failed",
      signature_error: "Invalid signature"
    )
  end

  @doc """
  Handle Telegram webhooks.

  POST /webhooks/telegram/:secret_path
  """
  def telegram(conn, params) do
    handle_signed_connector(conn, params,
      connector_module: Telegram,
      signature_log: "Telegram verification failed",
      signature_error: "Invalid request",
      failure_log: "Telegram webhook failed",
      on_event: &handle_telegram_event/1
    )
  end

  defp handle_slack(conn, params) do
    case Slack.handle_webhook(conn, params) do
      {:challenge, challenge} ->
        conn
        |> put_status(:ok)
        |> text(challenge)

      result ->
        handle_connector_result(conn, result, failure_log: "Slack webhook failed")
    end
  end

  # Generic handler for any connector
  defp handle_connector(conn, params, connector_module, opts \\ []) do
    result = connector_module.handle_webhook(conn, params)
    handle_connector_result(conn, result, opts)
  end

  defp handle_connector_result(conn, result, opts) do
    case result do
      {:ok, topic, event} ->
        maybe_handle_event(event, opts)
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
        failure_log = Keyword.get(opts, :failure_log, "Webhook processing failed")
        error_message = Keyword.get(opts, :error_message, "Failed to process webhook")
        Logger.warning(failure_log, reason: inspect(reason))
        bad_request(conn, error_message)
    end
  end

  defp maybe_handle_event(event, opts) do
    case Keyword.get(opts, :on_event) do
      callback when is_function(callback, 1) ->
        callback.(event)

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Connector side-effect handler failed", reason: Exception.message(error))
      :ok
  end

  defp handle_telegram_event(event) do
    InsightNotifications.handle_telegram_event(event)
  end

  defp handle_signed_connector(conn, params, opts) do
    connector_module = Keyword.fetch!(opts, :connector_module)
    signature_log = Keyword.fetch!(opts, :signature_log)
    signature_error = Keyword.fetch!(opts, :signature_error)

    on_verified =
      Keyword.get(opts, :on_verified, fn conn, params ->
        handle_connector(conn, params, connector_module, opts)
      end)

    raw_body = get_raw_body(conn, params)

    case connector_module.verify_signature(conn, raw_body) do
      :ok ->
        on_verified.(conn, params)

      {:error, reason} ->
        Logger.warning(signature_log, reason: reason)
        unauthorized(conn, signature_error)
    end
  end

  # Gets the cached raw body, falling back to re-encoding with a warning.
  # The CacheRawBody plug should always provide the raw body, but we handle
  # the edge case gracefully while logging a warning.
  defp get_raw_body(conn, params) do
    case conn.assigns[:raw_body] do
      nil ->
        Logger.warning("Raw body not cached - signature verification may fail",
          path: conn.request_path
        )

        case Jason.encode(params) do
          {:ok, raw_body} ->
            raw_body

          {:error, reason} ->
            Logger.warning("Failed to encode raw body fallback",
              path: conn.request_path,
              reason: inspect(reason)
            )

            ""
        end

      raw_body ->
        raw_body
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: message})
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end
end
