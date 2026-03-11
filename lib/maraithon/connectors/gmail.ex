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

  @default_api_base "https://gmail.googleapis.com/gmail/v1"

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
        url = "#{api_base_url()}/users/me/stop"

        case Google.api_request(:post, url, token, %{}) do
          {:ok, _} -> :ok
          # Gmail returns 404 if not watching - that's fine
          {:error, {:http_status, 404, _}} -> :ok
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
            event =
              Connector.build_event("email_sync", "gmail", %{
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
            event =
              Connector.build_event("email_changed", "gmail", %{
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
    fetch_messages(user_id, max_results: max_results, label_ids: ["INBOX"])
  end

  @doc """
  Fetches recent Gmail messages with optional labels or search query.
  """
  def fetch_messages(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    max_results = Keyword.get(opts, :max_results, 10)
    label_ids = Keyword.get(opts, :label_ids, [])
    query = Keyword.get(opts, :query)

    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        params =
          [{"maxResults", max_results}]
          |> maybe_append_query("q", query)
          |> append_repeated_query("labelIds", label_ids)
          |> Enum.map(&URI.encode_query([&1]))
          |> Enum.join("&")

        url = "#{api_base_url()}/users/me/messages?#{params}"

        case Google.api_request(:get, url, token) do
          {:ok, %{"messages" => messages}} ->
            detailed =
              messages
              |> Enum.take(max_results)
              |> Enum.map(fn %{"id" => id} -> fetch_message(token, id) end)
              |> Enum.filter(&match?({:ok, _}, &1))
              |> Enum.map(fn {:ok, msg} -> msg end)

            {:ok, detailed}

          {:ok, _} ->
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
        url = "#{api_base_url()}/users/me/messages/#{message_id}?format=metadata"

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

  @doc """
  Sends a Gmail message, optionally within an existing thread.
  """
  def send_message(user_id_or_token, attrs) when is_map(attrs) do
    with {:ok, access_token, provider} <- access_token_for_send(user_id_or_token, attrs),
         {:ok, to} <- required_attr(attrs, "to"),
         {:ok, subject} <- required_attr(attrs, "subject"),
         {:ok, body} <- required_attr(attrs, "body") do
      thread_id = optional_attr(attrs, "thread_id")
      reply_to_message_id = optional_attr(attrs, "reply_to_message_id")
      reply_headers = fetch_reply_headers(access_token, reply_to_message_id)

      raw =
        build_raw_message(
          to,
          subject,
          body,
          reply_headers["message_id"],
          reply_headers["references"]
        )

      request_body =
        %{raw: raw}
        |> maybe_put("threadId", thread_id)

      url = "#{api_base_url()}/users/me/messages/send"

      case Google.api_request(:post, url, access_token, request_body) do
        {:ok, response} ->
          {:ok,
           %{
             provider: provider,
             message_id: response["id"],
             thread_id: response["threadId"],
             label_ids: response["labelIds"] || []
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_access_token(_user_id, token) when is_binary(token) and token != "", do: {:ok, token}

  defp get_access_token(user_id, _) do
    OAuth.get_valid_access_token(user_id, "google")
  end

  defp access_token_for_send("ya29." <> _ = access_token, _attrs) do
    {:ok, access_token, "google"}
  end

  defp access_token_for_send(user_id, attrs) when is_binary(user_id) do
    account = optional_attr(attrs, "account")
    provider = if is_binary(account) and account != "", do: "google:#{account}", else: "google"

    case OAuth.get_valid_access_token(user_id, provider) do
      {:ok, access_token} ->
        {:ok, access_token, provider}

      {:error, :no_token} when provider != "google" ->
        get_access_token(user_id, nil) |> wrap_provider("google")

      other ->
        wrap_provider(other, provider)
    end
  end

  defp wrap_provider({:ok, access_token}, provider), do: {:ok, access_token, provider}
  defp wrap_provider(other, _provider), do: other

  defp create_watch(_user_id, access_token) do
    pubsub_topic = get_pubsub_topic()

    if is_nil(pubsub_topic) or pubsub_topic == "" do
      {:error, :pubsub_topic_not_configured}
    else
      url = "#{api_base_url()}/users/me/watch"

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

    url = "#{api_base_url()}/users/me/history?#{params}"

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
                   "#{api_base_url()}/users/me/messages/#{id}?format=metadata",
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

      {:error, {:http_status, 404, _}} ->
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
      internet_message_id: get_header(headers, "Message-ID"),
      references: get_header(headers, "References"),
      date: get_header(headers, "Date"),
      internal_date: parse_internal_date(message["internalDate"])
    }
  end

  defp fetch_reply_headers(_access_token, nil), do: %{}
  defp fetch_reply_headers(_access_token, ""), do: %{}

  defp fetch_reply_headers(access_token, message_id) do
    params =
      [
        {"format", "metadata"},
        {"metadataHeaders", "Message-ID"},
        {"metadataHeaders", "References"}
      ]
      |> Enum.map(&URI.encode_query([&1]))
      |> Enum.join("&")

    url = "#{api_base_url()}/users/me/messages/#{message_id}?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, response} ->
        parsed = parse_message(response)

        %{
          "message_id" => parsed.internet_message_id,
          "references" => parsed.references
        }

      _ ->
        %{}
    end
  end

  defp build_raw_message(to, subject, body, in_reply_to, references) do
    [
      "To: #{to}",
      "Subject: #{subject}",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      if(present?(in_reply_to), do: "In-Reply-To: #{in_reply_to}"),
      if(present?(references), do: "References: #{references}"),
      "",
      body
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
    |> Base.url_encode64(padding: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append_query(params, _key, nil), do: params
  defp maybe_append_query(params, _key, ""), do: params
  defp maybe_append_query(params, key, value), do: params ++ [{key, value}]

  defp append_repeated_query(params, _key, []), do: params

  defp append_repeated_query(params, key, values) when is_list(values) do
    params ++ Enum.map(values, &{key, &1})
  end

  defp required_attr(attrs, key) do
    case optional_attr(attrs, key) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp optional_attr(attrs, key) when is_map(attrs) do
    value =
      case Map.fetch(attrs, key) do
        {:ok, direct} ->
          direct

        :error ->
          Enum.find_value(attrs, fn
            {map_key, map_value} when is_atom(map_key) ->
              if Atom.to_string(map_key) == key, do: map_value

            _ ->
              nil
          end)
      end

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

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

  defp api_base_url do
    Application.get_env(:maraithon, :gmail, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end
end
