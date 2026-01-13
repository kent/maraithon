defmodule Maraithon.Connectors.Slack do
  @moduledoc """
  Slack Events API connector.

  Receives Slack events via the Events API and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `slack:{team_id}:{channel_id}`

  Example: `slack:T01234567:C01234567`

  For DMs: `slack:{team_id}:dm:{user_id}`

  ## Event Types

  - `message` - Message posted to channel
  - `message_changed` - Message edited
  - `message_deleted` - Message deleted
  - `reaction_added` - Reaction added to message
  - `reaction_removed` - Reaction removed
  - `member_joined_channel` - User joined channel
  - `app_mention` - Bot was mentioned

  ## How it Works

  1. Install Slack app to workspace via OAuth
  2. Configure Event Subscriptions in Slack app settings
  3. Point Request URL to `/webhooks/slack`
  4. Subscribe to events you want (message.channels, app_mention, etc.)
  5. Slack sends events to your webhook

  ## Configuration

      config :maraithon, :slack,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        signing_secret: "your_signing_secret"
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.OAuth.Slack, as: SlackOAuth
  alias Maraithon.Connectors.Connector

  require Logger

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(conn, raw_body) do
    timestamp = get_header(conn, "x-slack-request-timestamp")
    signature = get_header(conn, "x-slack-signature")

    if is_nil(timestamp) or is_nil(signature) do
      {:error, :missing_headers}
    else
      SlackOAuth.verify_signature(raw_body, timestamp, signature)
    end
  end

  @impl true
  def handle_webhook(_conn, params) do
    case params["type"] do
      "url_verification" ->
        # Slack challenge for webhook verification
        {:challenge, params["challenge"]}

      "event_callback" ->
        handle_event(params)

      type ->
        {:ignore, "unknown type: #{type}"}
    end
  end

  # ===========================================================================
  # Event Handling
  # ===========================================================================

  defp handle_event(params) do
    event = params["event"]
    team_id = params["team_id"]
    event_type = event["type"]

    case event_type do
      "message" ->
        handle_message_event(team_id, event, params)

      "app_mention" ->
        handle_app_mention(team_id, event, params)

      "reaction_added" ->
        handle_reaction(team_id, event, params, "reaction_added")

      "reaction_removed" ->
        handle_reaction(team_id, event, params, "reaction_removed")

      "member_joined_channel" ->
        handle_member_event(team_id, event, params, "member_joined")

      "member_left_channel" ->
        handle_member_event(team_id, event, params, "member_left")

      _ ->
        # Generic handler for other events
        topic = build_topic(team_id, event["channel"])

        normalized = Connector.build_event(event_type, "slack", %{
          team_id: team_id,
          event: event
        }, params)

        {:ok, topic, normalized}
    end
  end

  defp handle_message_event(team_id, event, params) do
    # Skip bot messages to avoid loops
    if event["bot_id"] || event["subtype"] == "bot_message" do
      {:ignore, "bot message"}
    else
      channel = event["channel"]
      topic = build_topic(team_id, channel)

      # Determine event type based on subtype
      event_type =
        case event["subtype"] do
          "message_changed" -> "message_changed"
          "message_deleted" -> "message_deleted"
          nil -> "message"
          subtype -> "message_#{subtype}"
        end

      data = %{
        team_id: team_id,
        channel_id: channel,
        user_id: event["user"],
        text: event["text"],
        ts: event["ts"],
        thread_ts: event["thread_ts"],
        blocks: event["blocks"],
        files: parse_files(event["files"]),
        edited: event["edited"]
      }

      normalized = Connector.build_event(event_type, "slack", data, params)

      Logger.info("Slack message received",
        team_id: team_id,
        channel: channel,
        user: event["user"]
      )

      {:ok, topic, normalized}
    end
  end

  defp handle_app_mention(team_id, event, params) do
    channel = event["channel"]
    topic = build_topic(team_id, channel)

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: event["user"],
      text: event["text"],
      ts: event["ts"],
      thread_ts: event["thread_ts"]
    }

    normalized = Connector.build_event("app_mention", "slack", data, params)

    Logger.info("Slack app mention",
      team_id: team_id,
      channel: channel,
      user: event["user"]
    )

    {:ok, topic, normalized}
  end

  defp handle_reaction(team_id, event, params, event_type) do
    # Reactions have item.channel
    channel = get_in(event, ["item", "channel"])
    topic = build_topic(team_id, channel)

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: event["user"],
      reaction: event["reaction"],
      item_type: get_in(event, ["item", "type"]),
      item_ts: get_in(event, ["item", "ts"])
    }

    normalized = Connector.build_event(event_type, "slack", data, params)
    {:ok, topic, normalized}
  end

  defp handle_member_event(team_id, event, params, event_type) do
    channel = event["channel"]
    topic = build_topic(team_id, channel)

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: event["user"],
      inviter: event["inviter"]
    }

    normalized = Connector.build_event(event_type, "slack", data, params)
    {:ok, topic, normalized}
  end

  # ===========================================================================
  # Slack API Helpers
  # ===========================================================================

  @doc """
  Posts a message to a Slack channel.
  """
  def post_message(access_token, channel, text, opts \\ []) do
    body = %{
      channel: channel,
      text: text
    }

    body =
      if thread_ts = opts[:thread_ts] do
        Map.put(body, :thread_ts, thread_ts)
      else
        body
      end

    SlackOAuth.api_request(:post, "chat.postMessage", access_token, body)
  end

  @doc """
  Gets channel info.
  """
  def get_channel_info(access_token, channel_id) do
    SlackOAuth.api_request(:get, "conversations.info?channel=#{channel_id}", access_token)
  end

  @doc """
  Gets user info.
  """
  def get_user_info(access_token, user_id) do
    SlackOAuth.api_request(:get, "users.info?user=#{user_id}", access_token)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_topic(team_id, nil), do: "slack:#{team_id}"
  defp build_topic(team_id, channel), do: "slack:#{team_id}:#{channel}"

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value] -> value
      _ -> nil
    end
  end

  defp parse_files(nil), do: []

  defp parse_files(files) do
    Enum.map(files, fn f ->
      %{
        id: f["id"],
        name: f["name"],
        mimetype: f["mimetype"],
        url: f["url_private"],
        size: f["size"]
      }
    end)
  end
end
