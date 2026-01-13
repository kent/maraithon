defmodule Maraithon.Connectors.Telegram do
  @moduledoc """
  Telegram Bot API connector.

  Receives Telegram updates via webhook and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `telegram:{bot_id}` or `telegram:{bot_id}:{chat_id}`

  Example: `telegram:123456789` or `telegram:123456789:-100123456`

  ## Event Types

  - `message` - Text message received
  - `photo` - Photo received
  - `document` - Document/file received
  - `voice` - Voice message received
  - `video` - Video received
  - `location` - Location shared
  - `contact` - Contact shared
  - `callback_query` - Inline button pressed
  - `edited_message` - Message was edited
  - `channel_post` - Post in channel
  - `member_joined` - User joined group
  - `member_left` - User left group

  ## How it Works

  1. Create a bot via @BotFather on Telegram
  2. Get your bot token
  3. Set webhook URL to `/webhooks/telegram/{secret_path}`
  4. Telegram sends updates to your webhook

  ## Configuration

      config :maraithon, :telegram,
        bot_token: "123456789:ABC...",
        webhook_secret_path: "random_secret_string"

  ## Webhook Setup

  Call `Maraithon.Connectors.Telegram.set_webhook/1` to configure the webhook:

      Telegram.set_webhook("https://your-domain.com/webhooks/telegram/your_secret")
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.Connectors.Connector
  alias Maraithon.HTTP

  require Logger

  @telegram_api_base "https://api.telegram.org/bot"

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(conn, _raw_body) do
    # Telegram uses a secret path in the URL instead of signature verification
    # The secret is verified by the router matching the path
    secret_path = get_webhook_secret_path()

    if secret_path == "" do
      # No secret configured - only allow if explicitly enabled
      if allow_unsigned?() do
        :ok
      else
        {:error, :webhook_secret_path_not_configured}
      end
    else
      # Check if the request path contains the secret
      # This should be handled by the router, but double-check here
      path = conn.request_path

      if String.contains?(path, secret_path) do
        :ok
      else
        {:error, :invalid_path}
      end
    end
  end

  @impl true
  def handle_webhook(_conn, params) do
    # Telegram sends an "update" object
    update_id = params["update_id"]

    cond do
      params["message"] ->
        handle_message(params["message"], params)

      params["edited_message"] ->
        handle_edited_message(params["edited_message"], params)

      params["channel_post"] ->
        handle_channel_post(params["channel_post"], params)

      params["callback_query"] ->
        handle_callback_query(params["callback_query"], params)

      params["inline_query"] ->
        handle_inline_query(params["inline_query"], params)

      params["my_chat_member"] ->
        handle_chat_member_update(params["my_chat_member"], params)

      params["chat_member"] ->
        handle_chat_member_update(params["chat_member"], params)

      true ->
        {:ignore, "unhandled update type, id: #{update_id}"}
    end
  end

  # ===========================================================================
  # Message Handlers
  # ===========================================================================

  defp handle_message(message, params) do
    chat = message["chat"]
    from = message["from"]
    bot_id = get_bot_id()

    topic = "telegram:#{bot_id}:#{chat["id"]}"

    # Determine message type
    {event_type, type_data} = classify_message(message)

    # Check for new/left members (group events)
    cond do
      message["new_chat_members"] ->
        members = message["new_chat_members"]

        data = %{
          chat_id: chat["id"],
          chat_type: chat["type"],
          chat_title: chat["title"],
          members: Enum.map(members, &parse_user/1)
        }

        normalized = Connector.build_event("member_joined", "telegram", data, params)
        {:ok, topic, normalized}

      message["left_chat_member"] ->
        member = message["left_chat_member"]

        data = %{
          chat_id: chat["id"],
          chat_type: chat["type"],
          chat_title: chat["title"],
          member: parse_user(member)
        }

        normalized = Connector.build_event("member_left", "telegram", data, params)
        {:ok, topic, normalized}

      true ->
        data =
          Map.merge(type_data, %{
            message_id: message["message_id"],
            chat_id: chat["id"],
            chat_type: chat["type"],
            chat_title: chat["title"],
            from: parse_user(from),
            date: parse_timestamp(message["date"]),
            reply_to: parse_reply(message["reply_to_message"]),
            forward_from: parse_forward(message)
          })

        normalized = Connector.build_event(event_type, "telegram", data, params)

        Logger.info("Telegram message received",
          type: event_type,
          chat_id: chat["id"],
          from: from["username"] || from["id"]
        )

        {:ok, topic, normalized}
    end
  end

  defp handle_edited_message(message, params) do
    chat = message["chat"]
    from = message["from"]
    bot_id = get_bot_id()

    topic = "telegram:#{bot_id}:#{chat["id"]}"

    data = %{
      message_id: message["message_id"],
      chat_id: chat["id"],
      chat_type: chat["type"],
      from: parse_user(from),
      text: message["text"],
      edit_date: parse_timestamp(message["edit_date"]),
      date: parse_timestamp(message["date"])
    }

    normalized = Connector.build_event("edited_message", "telegram", data, params)
    {:ok, topic, normalized}
  end

  defp handle_channel_post(post, params) do
    chat = post["chat"]
    bot_id = get_bot_id()

    topic = "telegram:#{bot_id}:#{chat["id"]}"

    {event_type, type_data} = classify_message(post)

    data =
      Map.merge(type_data, %{
        message_id: post["message_id"],
        chat_id: chat["id"],
        chat_title: chat["title"],
        chat_username: chat["username"],
        date: parse_timestamp(post["date"])
      })

    normalized = Connector.build_event("channel_#{event_type}", "telegram", data, params)
    {:ok, topic, normalized}
  end

  defp handle_callback_query(query, params) do
    from = query["from"]
    message = query["message"]
    chat = message && message["chat"]
    bot_id = get_bot_id()

    topic =
      if chat do
        "telegram:#{bot_id}:#{chat["id"]}"
      else
        "telegram:#{bot_id}"
      end

    data = %{
      callback_id: query["id"],
      from: parse_user(from),
      data: query["data"],
      chat_id: chat && chat["id"],
      message_id: message && message["message_id"],
      inline_message_id: query["inline_message_id"]
    }

    normalized = Connector.build_event("callback_query", "telegram", data, params)
    {:ok, topic, normalized}
  end

  defp handle_inline_query(query, params) do
    from = query["from"]
    bot_id = get_bot_id()

    topic = "telegram:#{bot_id}"

    data = %{
      query_id: query["id"],
      from: parse_user(from),
      query: query["query"],
      offset: query["offset"],
      chat_type: query["chat_type"],
      location: query["location"]
    }

    normalized = Connector.build_event("inline_query", "telegram", data, params)
    {:ok, topic, normalized}
  end

  defp handle_chat_member_update(update, params) do
    chat = update["chat"]
    from = update["from"]
    bot_id = get_bot_id()

    topic = "telegram:#{bot_id}:#{chat["id"]}"

    old_member = update["old_chat_member"]
    new_member = update["new_chat_member"]

    data = %{
      chat_id: chat["id"],
      chat_type: chat["type"],
      chat_title: chat["title"],
      from: parse_user(from),
      old_status: old_member && old_member["status"],
      new_status: new_member && new_member["status"],
      user: new_member && parse_user(new_member["user"])
    }

    normalized = Connector.build_event("chat_member_updated", "telegram", data, params)
    {:ok, topic, normalized}
  end

  # ===========================================================================
  # Bot API Methods
  # ===========================================================================

  @doc """
  Sets the webhook URL for receiving updates.
  """
  def set_webhook(url, opts \\ []) do
    params = %{url: url}

    params =
      params
      |> maybe_put(:secret_token, opts[:secret_token])
      |> maybe_put(:max_connections, opts[:max_connections])
      |> maybe_put(:allowed_updates, opts[:allowed_updates])

    api_request("setWebhook", params)
  end

  @doc """
  Deletes the webhook (switches to getUpdates polling mode).
  """
  def delete_webhook do
    api_request("deleteWebhook", %{})
  end

  @doc """
  Gets current webhook info.
  """
  def get_webhook_info do
    api_request("getWebhookInfo", %{})
  end

  @doc """
  Sends a text message.
  """
  def send_message(chat_id, text, opts \\ []) do
    params =
      %{chat_id: chat_id, text: text}
      |> maybe_put(:parse_mode, opts[:parse_mode])
      |> maybe_put(:reply_to_message_id, opts[:reply_to])
      |> maybe_put(:reply_markup, opts[:reply_markup])
      |> maybe_put(:disable_notification, opts[:silent])

    api_request("sendMessage", params)
  end

  @doc """
  Sends a photo.
  """
  def send_photo(chat_id, photo, opts \\ []) do
    params =
      %{chat_id: chat_id, photo: photo}
      |> maybe_put(:caption, opts[:caption])
      |> maybe_put(:parse_mode, opts[:parse_mode])
      |> maybe_put(:reply_to_message_id, opts[:reply_to])

    api_request("sendPhoto", params)
  end

  @doc """
  Sends a document.
  """
  def send_document(chat_id, document, opts \\ []) do
    params =
      %{chat_id: chat_id, document: document}
      |> maybe_put(:caption, opts[:caption])
      |> maybe_put(:parse_mode, opts[:parse_mode])
      |> maybe_put(:reply_to_message_id, opts[:reply_to])

    api_request("sendDocument", params)
  end

  @doc """
  Answers a callback query (acknowledges button press).
  """
  def answer_callback_query(callback_query_id, opts \\ []) do
    params =
      %{callback_query_id: callback_query_id}
      |> maybe_put(:text, opts[:text])
      |> maybe_put(:show_alert, opts[:show_alert])
      |> maybe_put(:url, opts[:url])

    api_request("answerCallbackQuery", params)
  end

  @doc """
  Edits a message's text.
  """
  def edit_message_text(chat_id, message_id, text, opts \\ []) do
    params =
      %{chat_id: chat_id, message_id: message_id, text: text}
      |> maybe_put(:parse_mode, opts[:parse_mode])
      |> maybe_put(:reply_markup, opts[:reply_markup])

    api_request("editMessageText", params)
  end

  @doc """
  Gets info about the bot.
  """
  def get_me do
    api_request("getMe", %{})
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp api_request(method, params) do
    bot_token = get_bot_token()
    url = "#{@telegram_api_base}#{bot_token}/#{method}"

    case HTTP.post_json(url, params) do
      {:ok, %{"ok" => true, "result" => result}} ->
        {:ok, result}

      {:ok, %{"ok" => false, "error_code" => code, "description" => desc}} ->
        {:error, {:telegram_error, code, desc}}

      {:ok, _} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_message(message) do
    cond do
      message["text"] ->
        {"message", %{text: message["text"], entities: message["entities"]}}

      message["photo"] ->
        photo = List.last(message["photo"])

        {"photo",
         %{
           photo_id: photo["file_id"],
           file_unique_id: photo["file_unique_id"],
           width: photo["width"],
           height: photo["height"],
           caption: message["caption"]
         }}

      message["document"] ->
        doc = message["document"]

        {"document",
         %{
           document_id: doc["file_id"],
           file_name: doc["file_name"],
           mime_type: doc["mime_type"],
           file_size: doc["file_size"],
           caption: message["caption"]
         }}

      message["voice"] ->
        voice = message["voice"]

        {"voice",
         %{
           voice_id: voice["file_id"],
           duration: voice["duration"],
           mime_type: voice["mime_type"]
         }}

      message["audio"] ->
        audio = message["audio"]

        {"audio",
         %{
           audio_id: audio["file_id"],
           duration: audio["duration"],
           performer: audio["performer"],
           title: audio["title"],
           caption: message["caption"]
         }}

      message["video"] ->
        video = message["video"]

        {"video",
         %{
           video_id: video["file_id"],
           duration: video["duration"],
           width: video["width"],
           height: video["height"],
           caption: message["caption"]
         }}

      message["location"] ->
        loc = message["location"]

        {"location",
         %{
           latitude: loc["latitude"],
           longitude: loc["longitude"],
           horizontal_accuracy: loc["horizontal_accuracy"]
         }}

      message["contact"] ->
        contact = message["contact"]

        {"contact",
         %{
           phone_number: contact["phone_number"],
           first_name: contact["first_name"],
           last_name: contact["last_name"],
           user_id: contact["user_id"],
           vcard: contact["vcard"]
         }}

      message["sticker"] ->
        sticker = message["sticker"]

        {"sticker",
         %{
           sticker_id: sticker["file_id"],
           emoji: sticker["emoji"],
           set_name: sticker["set_name"],
           is_animated: sticker["is_animated"]
         }}

      message["poll"] ->
        poll = message["poll"]

        {"poll",
         %{
           poll_id: poll["id"],
           question: poll["question"],
           options: poll["options"],
           is_anonymous: poll["is_anonymous"],
           type: poll["type"]
         }}

      true ->
        {"unknown", %{raw: message}}
    end
  end

  defp parse_user(nil), do: nil

  defp parse_user(user) do
    %{
      id: user["id"],
      username: user["username"],
      first_name: user["first_name"],
      last_name: user["last_name"],
      is_bot: user["is_bot"]
    }
  end

  defp parse_reply(nil), do: nil

  defp parse_reply(reply) do
    %{
      message_id: reply["message_id"],
      from: parse_user(reply["from"]),
      text: reply["text"]
    }
  end

  defp parse_forward(message) do
    cond do
      message["forward_from"] ->
        %{type: "user", user: parse_user(message["forward_from"])}

      message["forward_from_chat"] ->
        %{
          type: "chat",
          chat_id: message["forward_from_chat"]["id"],
          chat_title: message["forward_from_chat"]["title"]
        }

      message["forward_sender_name"] ->
        %{type: "hidden", name: message["forward_sender_name"]}

      true ->
        nil
    end
  end

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)

  defp get_bot_token do
    Application.get_env(:maraithon, :telegram, [])
    |> Keyword.get(:bot_token, "")
  end

  defp get_bot_id do
    bot_token = get_bot_token()

    case String.split(bot_token, ":") do
      [id | _] -> id
      _ -> "unknown"
    end
  end

  defp get_webhook_secret_path do
    Application.get_env(:maraithon, :telegram, [])
    |> Keyword.get(:webhook_secret_path, "")
  end

  defp allow_unsigned? do
    Application.get_env(:maraithon, :telegram, [])
    |> Keyword.get(:allow_unsigned, false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
