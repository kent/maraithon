defmodule Maraithon.Connectors.Gmail do
  @moduledoc """
  Gmail connector.

  Sets up push notifications for email changes and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `email:{user_id}`

  Example: `email:user_123`

  ## Event Types

  - `email_received` - New email received
  - `email_sync` - Batch of email changes

  ## How it Works

  Gmail push notifications use Google Cloud Pub/Sub:

  1. Create a Cloud Pub/Sub topic in Google Cloud Console
  2. Grant Gmail API service account publish access
  3. Create a push subscription pointing to your webhook
  4. Call Gmail API to "watch" the user's mailbox
  5. Google publishes messages to Pub/Sub when mail changes
  6. Pub/Sub pushes to your webhook

  ## Configuration

  Requires:
  - `GOOGLE_PUBSUB_TOPIC` - Full topic name (e.g., projects/my-project/topics/gmail-push)
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Connectors.Connector

  require Logger

  @gmail_api_base "https://gmail.googleapis.com/gmail/v1"

  # ===========================================================================
  # Watch Management
  # ===========================================================================

  @doc """
  Sets up a watch on the user's mailbox.

  This registers the user's mailbox with Google Cloud Pub/Sub for push notifications.

  Returns `{:ok, watch_info}` or `{:error, reason}`.
  """
  def setup_watch(user_id, access_token \\ nil) do
    with {:ok, token} <- get_access_token(user_id, access_token),
         {:ok, watch} <- create_watch(user_id, token) do
      Logger.info("Gmail watch created",
        user_id: user_id,
        history_id: watch.history_id,
        expiration: watch.expiration
      )

      {:ok, watch}
    end
  end

  @doc """
  Stops watching the user's mailbox.

  Should be called when a user disconnects their email.
  """
  def stop_watch(user_id) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        url = "#{@gmail_api_base}/users/me/stop"

        case Google.api_request(:post, url, token, %{}) do
          {:ok, _} -> :ok
          # Gmail returns 404 if not watching - that's fine
          {:error, {:api_error, 404, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(_conn, _raw_body) do
    # Cloud Pub/Sub push subscriptions can be configured to require authentication
    # For now, we rely on the subscription being properly configured
    # In production, you should verify the JWT token from Pub/Sub
    :ok
  end

  @impl true
  def handle_webhook(_conn, params) do
    # Cloud Pub/Sub sends messages in this format:
    # {
    #   "message": {
    #     "data": "<base64 encoded>",
    #     "messageId": "...",
    #     "publishTime": "..."
    #   },
    #   "subscription": "projects/.../subscriptions/..."
    # }

    case decode_pubsub_message(params) do
      {:ok, user_id, history_id} ->
        topic = "email:#{user_id}"

        # Fetch the actual email changes
        case sync_mail_changes(user_id, history_id) do
          {:ok, messages} ->
            event = Connector.build_event("email_sync", "gmail", %{
              user_id: user_id,
              history_id: history_id,
              messages: messages
            })

            {:ok, topic, event}

          {:error, reason} ->
            Logger.warning("Failed to sync mail changes",
              user_id: user_id,
              history_id: history_id,
              reason: inspect(reason)
            )

            # Still notify that mail changed
            event = Connector.build_event("email_changed", "gmail", %{
              user_id: user_id,
              history_id: history_id,
              sync_failed: true
            })

            {:ok, topic, event}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Gmail API
  # ===========================================================================

  @doc """
  Fetches mail history since a given history ID.

  Returns `{:ok, messages}` or `{:error, reason}`.
  """
  def sync_mail_changes(user_id, history_id) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        fetch_history(token, history_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches recent emails from the user's inbox.
  """
  def fetch_recent_emails(user_id, max_results \\ 10) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        params =
          URI.encode_query(%{
            maxResults: max_results,
            labelIds: "INBOX"
          })

        url = "#{@gmail_api_base}/users/me/messages?#{params}"

        case Google.api_request(:get, url, token) do
          {:ok, %{"messages" => messages}} ->
            # Fetch full message details
            detailed =
              messages
              |> Enum.take(max_results)
              |> Enum.map(fn %{"id" => id} -> fetch_message(token, id) end)
              |> Enum.filter(&match?({:ok, _}, &1))
              |> Enum.map(fn {:ok, msg} -> msg end)

            {:ok, detailed}

          {:ok, _} ->
            # No messages
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches a single email message.
  """
  def fetch_message(user_id_or_token, message_id) do
    token =
      case user_id_or_token do
        "ya29." <> _ = t -> {:ok, t}
        user_id -> OAuth.get_valid_access_token(user_id, "google")
      end

    case token do
      {:ok, access_token} ->
        url = "#{@gmail_api_base}/users/me/messages/#{message_id}?format=metadata"

        case Google.api_request(:get, url, access_token) do
          {:ok, response} ->
            {:ok, parse_message(response)}

          {:error, reason} ->
            {:error, reason}
        end

      error ->
        error
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_access_token(_user_id, token) when is_binary(token) and token != "", do: {:ok, token}

  defp get_access_token(user_id, _) do
    OAuth.get_valid_access_token(user_id, "google")
  end

  defp create_watch(_user_id, access_token) do
    pubsub_topic = get_pubsub_topic()

    if is_nil(pubsub_topic) or pubsub_topic == "" do
      {:error, :pubsub_topic_not_configured}
    else
      url = "#{@gmail_api_base}/users/me/watch"

      body = %{
        topicName: pubsub_topic,
        labelIds: ["INBOX"]
      }

      case Google.api_request(:post, url, access_token, body) do
        {:ok, response} ->
          {:ok,
           %{
             history_id: response["historyId"],
             expiration: parse_expiration(response["expiration"])
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_history(access_token, history_id) do
    params =
      URI.encode_query(%{
        startHistoryId: history_id,
        historyTypes: "messageAdded"
      })

    url = "#{@gmail_api_base}/users/me/history?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, %{"history" => history}} ->
        # Extract added message IDs
        message_ids =
          history
          |> Enum.flat_map(fn h -> h["messagesAdded"] || [] end)
          |> Enum.map(fn ma -> ma["message"]["id"] end)
          |> Enum.uniq()

        # Fetch message details
        messages =
          message_ids
          |> Enum.take(20)
          |> Enum.map(fn id ->
            case Google.api_request(
                   :get,
                   "#{@gmail_api_base}/users/me/messages/#{id}?format=metadata",
                   access_token
                 ) do
              {:ok, msg} -> parse_message(msg)
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, messages}

      {:ok, _} ->
        # No history changes
        {:ok, []}

      {:error, {:api_error, 404, _}} ->
        # History ID too old - need full sync
        {:error, :history_expired}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_message(message) do
    headers = message["payload"]["headers"] || []

    %{
      message_id: message["id"],
      thread_id: message["threadId"],
      snippet: message["snippet"],
      labels: message["labelIds"] || [],
      from: get_header(headers, "From"),
      to: get_header(headers, "To"),
      subject: get_header(headers, "Subject"),
      date: get_header(headers, "Date"),
      internal_date: parse_internal_date(message["internalDate"])
    }
  end

  defp get_header(headers, name) do
    case Enum.find(headers, fn h -> h["name"] == name end) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp parse_internal_date(nil), do: nil

  defp parse_internal_date(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {millis, _} -> DateTime.from_unix!(millis, :millisecond)
      :error -> nil
    end
  end

  defp parse_expiration(nil), do: nil

  defp parse_expiration(expiration) when is_binary(expiration) do
    case Integer.parse(expiration) do
      {ms, _} -> DateTime.from_unix!(ms, :millisecond)
      :error -> nil
    end
  end

  defp parse_expiration(expiration) when is_integer(expiration) do
    DateTime.from_unix!(expiration, :millisecond)
  end

  defp decode_pubsub_message(%{"message" => %{"data" => data}}) do
    with {:ok, json} <- Base.decode64(data),
         {:ok, payload} <- Jason.decode(json) do
      # Gmail sends: {"emailAddress": "user@example.com", "historyId": "12345"}
      user_email = payload["emailAddress"]
      history_id = payload["historyId"]

      # We use email address as user_id for Gmail
      # In production, you'd map this to your internal user_id
      {:ok, user_email, history_id}
    else
      _ -> {:error, :invalid_pubsub_message}
    end
  end

  defp decode_pubsub_message(_) do
    {:error, :invalid_pubsub_format}
  end

  defp get_pubsub_topic do
    Application.get_env(:maraithon, :google, [])
    |> Keyword.get(:pubsub_topic, "")
  end
end
