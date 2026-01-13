defmodule Maraithon.Connectors.WhatsApp do
  @moduledoc """
  WhatsApp Business API connector.

  Receives WhatsApp messages via Meta's Webhooks and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `whatsapp:{phone_number_id}`

  Example: `whatsapp:1234567890`

  For user-specific subscriptions: `whatsapp:{phone_number_id}:{user_phone}`

  ## Event Types

  - `message_received` - Text message received
  - `image_received` - Image message received
  - `audio_received` - Audio/voice message received
  - `document_received` - Document received
  - `location_received` - Location shared
  - `message_status` - Delivery/read status update

  ## How it Works

  1. Create a Meta App with WhatsApp product
  2. Configure webhook URL to `/webhooks/whatsapp`
  3. Set verify token to match `WHATSAPP_VERIFY_TOKEN`
  4. Subscribe to `messages` webhook field
  5. WhatsApp sends message events to your webhook

  ## Configuration

      config :maraithon, :whatsapp,
        verify_token: "your_verify_token",
        access_token: "your_access_token",
        phone_number_id: "your_phone_number_id"
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.Connectors.Connector

  require Logger

  @whatsapp_api_base "https://graph.facebook.com/v18.0"

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(conn, raw_body) do
    # WhatsApp uses X-Hub-Signature-256 header with app secret
    app_secret = get_app_secret()

    if app_secret == "" do
      # No secret configured - allow in dev
      :ok
    else
      case Plug.Conn.get_req_header(conn, "x-hub-signature-256") do
        ["sha256=" <> signature] ->
          expected =
            :crypto.mac(:hmac, :sha256, app_secret, raw_body)
            |> Base.encode16(case: :lower)

          if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
            :ok
          else
            {:error, :invalid_signature}
          end

        [] ->
          {:error, :missing_signature}

        _ ->
          {:error, :invalid_signature_format}
      end
    end
  end

  @impl true
  def handle_webhook(conn, params) do
    # Check for webhook verification (GET request challenge)
    mode = conn.query_params["hub.mode"]
    token = conn.query_params["hub.verify_token"]
    challenge = conn.query_params["hub.challenge"]

    if mode == "subscribe" and token != nil do
      # This is a webhook verification request
      verify_token = get_verify_token()

      if token == verify_token do
        {:verify, challenge}
      else
        {:error, :invalid_verify_token}
      end
    else
      # This is an actual webhook event
      handle_notification(params)
    end
  end

  # ===========================================================================
  # Event Handling
  # ===========================================================================

  defp handle_notification(%{"object" => "whatsapp_business_account", "entry" => entries}) do
    # Process each entry (usually just one)
    results =
      Enum.flat_map(entries, fn entry ->
        changes = entry["changes"] || []

        Enum.map(changes, fn change ->
          handle_change(change)
        end)
      end)

    # Return the first successful result or first error
    case Enum.find(results, fn {status, _, _} -> status == :ok end) do
      nil ->
        case List.first(results) do
          {:ignore, reason} -> {:ignore, reason}
          {:error, reason} -> {:error, reason}
          nil -> {:ignore, "no changes"}
          result -> result
        end

      result ->
        result
    end
  end

  defp handle_notification(_params) do
    {:ignore, "not whatsapp_business_account"}
  end

  defp handle_change(%{"field" => "messages", "value" => value}) do
    phone_number_id = value["metadata"]["phone_number_id"]
    messages = value["messages"] || []
    statuses = value["statuses"] || []

    cond do
      length(messages) > 0 ->
        # Handle incoming message
        message = List.first(messages)
        handle_message(phone_number_id, message, value)

      length(statuses) > 0 ->
        # Handle status update
        status = List.first(statuses)
        handle_status(phone_number_id, status, value)

      true ->
        {:ignore, "no messages or statuses"}
    end
  end

  defp handle_change(%{"field" => field}) do
    {:ignore, "unhandled field: #{field}"}
  end

  defp handle_message(phone_number_id, message, raw_value) do
    from = message["from"]
    msg_type = message["type"]
    timestamp = message["timestamp"]

    topic = "whatsapp:#{phone_number_id}"

    {event_type, data} =
      case msg_type do
        "text" ->
          {"message_received",
           %{
             text: get_in(message, ["text", "body"]),
             message_type: "text"
           }}

        "image" ->
          {"image_received",
           %{
             media_id: get_in(message, ["image", "id"]),
             caption: get_in(message, ["image", "caption"]),
             mime_type: get_in(message, ["image", "mime_type"]),
             message_type: "image"
           }}

        "audio" ->
          {"audio_received",
           %{
             media_id: get_in(message, ["audio", "id"]),
             mime_type: get_in(message, ["audio", "mime_type"]),
             voice: get_in(message, ["audio", "voice"]) || false,
             message_type: "audio"
           }}

        "document" ->
          {"document_received",
           %{
             media_id: get_in(message, ["document", "id"]),
             filename: get_in(message, ["document", "filename"]),
             caption: get_in(message, ["document", "caption"]),
             mime_type: get_in(message, ["document", "mime_type"]),
             message_type: "document"
           }}

        "location" ->
          {"location_received",
           %{
             latitude: get_in(message, ["location", "latitude"]),
             longitude: get_in(message, ["location", "longitude"]),
             name: get_in(message, ["location", "name"]),
             address: get_in(message, ["location", "address"]),
             message_type: "location"
           }}

        "contacts" ->
          {"contacts_received",
           %{
             contacts: message["contacts"],
             message_type: "contacts"
           }}

        "button" ->
          {"button_reply",
           %{
             button_text: get_in(message, ["button", "text"]),
             button_payload: get_in(message, ["button", "payload"]),
             message_type: "button"
           }}

        "interactive" ->
          {"interactive_reply",
           %{
             interactive_type: get_in(message, ["interactive", "type"]),
             reply: message["interactive"],
             message_type: "interactive"
           }}

        _ ->
          {"message_received",
           %{
             message_type: msg_type,
             raw: message
           }}
      end

    full_data =
      Map.merge(data, %{
        phone_number_id: phone_number_id,
        from: from,
        message_id: message["id"],
        timestamp: parse_timestamp(timestamp),
        context: message["context"]
      })

    normalized = Connector.build_event(event_type, "whatsapp", full_data, raw_value)

    Logger.info("WhatsApp message received",
      phone_number_id: phone_number_id,
      from: from,
      type: msg_type
    )

    {:ok, topic, normalized}
  end

  defp handle_status(phone_number_id, status, raw_value) do
    topic = "whatsapp:#{phone_number_id}"

    data = %{
      phone_number_id: phone_number_id,
      message_id: status["id"],
      recipient: status["recipient_id"],
      status: status["status"],
      timestamp: parse_timestamp(status["timestamp"]),
      conversation: status["conversation"],
      pricing: status["pricing"]
    }

    normalized = Connector.build_event("message_status", "whatsapp", data, raw_value)
    {:ok, topic, normalized}
  end

  # ===========================================================================
  # WhatsApp API Helpers
  # ===========================================================================

  @doc """
  Sends a text message.
  """
  def send_text_message(to, text, opts \\ []) do
    phone_number_id = opts[:phone_number_id] || get_phone_number_id()
    access_token = opts[:access_token] || get_access_token()

    body = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: to,
      type: "text",
      text: %{
        preview_url: opts[:preview_url] || false,
        body: text
      }
    }

    # Add reply context if replying to a message
    body =
      if reply_to = opts[:reply_to] do
        Map.put(body, :context, %{message_id: reply_to})
      else
        body
      end

    api_request(:post, "#{phone_number_id}/messages", access_token, body)
  end

  @doc """
  Sends a template message.
  """
  def send_template_message(to, template_name, language_code, components \\ [], opts \\ []) do
    phone_number_id = opts[:phone_number_id] || get_phone_number_id()
    access_token = opts[:access_token] || get_access_token()

    body = %{
      messaging_product: "whatsapp",
      to: to,
      type: "template",
      template: %{
        name: template_name,
        language: %{code: language_code},
        components: components
      }
    }

    api_request(:post, "#{phone_number_id}/messages", access_token, body)
  end

  @doc """
  Downloads media by ID.
  """
  def get_media_url(media_id, opts \\ []) do
    access_token = opts[:access_token] || get_access_token()

    case api_request(:get, media_id, access_token) do
      {:ok, %{"url" => url}} -> {:ok, url}
      error -> error
    end
  end

  @doc """
  Marks a message as read.
  """
  def mark_as_read(message_id, opts \\ []) do
    phone_number_id = opts[:phone_number_id] || get_phone_number_id()
    access_token = opts[:access_token] || get_access_token()

    body = %{
      messaging_product: "whatsapp",
      status: "read",
      message_id: message_id
    }

    api_request(:post, "#{phone_number_id}/messages", access_token, body)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp api_request(method, endpoint, access_token, body \\ nil) do
    url = "#{@whatsapp_api_base}/#{endpoint}"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    request =
      case method do
        :get ->
          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)}

        :post ->
          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end),
           ~c"application/json", String.to_charlist(Jason.encode!(body))}
      end

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, status, _}, _, response_body}} when status in 200..299 ->
        {:ok, Jason.decode!(List.to_string(response_body))}

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("WhatsApp API error",
          status: status,
          endpoint: endpoint,
          body: List.to_string(response_body)
        )

        {:error, {:api_error, status, List.to_string(response_body)}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {unix, _} -> DateTime.from_unix!(unix)
      :error -> nil
    end
  end

  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts)
  end

  defp get_verify_token do
    Application.get_env(:maraithon, :whatsapp, [])
    |> Keyword.get(:verify_token, "")
  end

  defp get_app_secret do
    Application.get_env(:maraithon, :whatsapp, [])
    |> Keyword.get(:app_secret, "")
  end

  defp get_access_token do
    Application.get_env(:maraithon, :whatsapp, [])
    |> Keyword.get(:access_token, "")
  end

  defp get_phone_number_id do
    Application.get_env(:maraithon, :whatsapp, [])
    |> Keyword.get(:phone_number_id, "")
  end
end
