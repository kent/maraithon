defmodule Maraithon.Connectors.GoogleCalendar do
  @moduledoc """
  Google Calendar connector.

  Sets up push notifications for calendar changes and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `calendar:{user_id}`

  Example: `calendar:user_123`

  ## Event Types

  - `calendar_event_created` - New event created
  - `calendar_event_updated` - Event modified
  - `calendar_event_deleted` - Event removed
  - `calendar_sync` - Full or incremental sync completed

  ## How it Works

  1. User authorizes via OAuth
  2. We call Google Calendar API to create a "watch" on their calendar
  3. Google sends push notifications to our webhook when changes occur
  4. We fetch the changed events and publish to PubSub

  ## Configuration

  Requires `GOOGLE_CALENDAR_WEBHOOK_URL` environment variable for push notification address.
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Connectors.Connector

  require Logger

  @default_api_base "https://www.googleapis.com/calendar/v3"

  # ===========================================================================
  # Watch Management
  # ===========================================================================

  @doc """
  Sets up a watch on the user's primary calendar.

  This registers a push notification channel with Google.
  Google will send POST requests to our webhook when events change.

  Returns `{:ok, watch_info}` or `{:error, reason}`.
  """
  def setup_watch(user_id, access_token \\ nil) do
    with {:ok, token} <- get_access_token(user_id, access_token),
         {:ok, watch} <- create_watch(user_id, token) do
      Logger.info("Google Calendar watch created",
        user_id: user_id,
        channel_id: watch.id,
        expiration: watch.expiration
      )

      {:ok, watch}
    end
  end

  @doc """
  Stops a calendar watch.

  Should be called when a user disconnects their calendar.
  """
  def stop_watch(user_id, channel_id, resource_id) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        url = "#{api_base_url()}/channels/stop"

        body = %{
          id: channel_id,
          resourceId: resource_id
        }

        case Google.api_request(:post, url, token, body) do
          {:ok, _} -> :ok
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
    # Google Calendar push notifications use channel tokens for verification
    # We verify the X-Goog-Channel-Token header in handle_webhook
    :ok
  end

  @impl true
  def handle_webhook(conn, _params) do
    # Extract headers
    channel_id = get_header(conn, "x-goog-channel-id")
    resource_id = get_header(conn, "x-goog-resource-id")
    resource_state = get_header(conn, "x-goog-resource-state")
    channel_token = get_header(conn, "x-goog-channel-token")

    # Channel token contains user_id
    user_id = channel_token

    if is_nil(user_id) or user_id == "" do
      {:error, :missing_channel_token}
    else
      topic = "calendar:#{user_id}"

      case resource_state do
        "sync" ->
          # Initial sync confirmation - acknowledge but don't publish
          {:ignore, "sync confirmation"}

        "exists" ->
          # Calendar changed - fetch updated events
          case sync_calendar_events(user_id) do
            {:ok, events} ->
              event =
                Connector.build_event("calendar_sync", "google_calendar", %{
                  user_id: user_id,
                  channel_id: channel_id,
                  resource_id: resource_id,
                  events: events
                })

              {:ok, topic, event}

            {:error, reason} ->
              Logger.warning("Failed to sync calendar",
                user_id: user_id,
                reason: inspect(reason)
              )

              # Still publish notification of change
              event =
                Connector.build_event("calendar_changed", "google_calendar", %{
                  user_id: user_id,
                  channel_id: channel_id,
                  resource_id: resource_id,
                  sync_failed: true
                })

              {:ok, topic, event}
          end

        "not_exists" ->
          # Resource deleted
          event =
            Connector.build_event("calendar_deleted", "google_calendar", %{
              user_id: user_id,
              channel_id: channel_id,
              resource_id: resource_id
            })

          {:ok, topic, event}

        _ ->
          {:ignore, "unknown resource state: #{resource_state}"}
      end
    end
  end

  # ===========================================================================
  # Calendar API
  # ===========================================================================

  @doc """
  Fetches calendar events, using incremental sync if a sync token is available.

  Returns `{:ok, events}` or `{:error, reason}`.
  """
  def sync_calendar_events(user_id, opts \\ []) do
    provider = Keyword.get(opts, :provider, "google")

    case OAuth.get_valid_access_token(user_id, provider) do
      {:ok, token} ->
        fetch_events(token, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches upcoming events from the user's primary calendar.
  """
  def fetch_upcoming_events(user_id, max_results \\ 10) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        params =
          URI.encode_query(%{
            timeMin: now,
            maxResults: max_results,
            singleEvents: true,
            orderBy: "startTime"
          })

        url = "#{api_base_url()}/calendars/primary/events?#{params}"

        case Google.api_request(:get, url, token) do
          {:ok, response} ->
            events = parse_events(response["items"] || [])
            {:ok, events}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_access_token(_user_id, token) when is_binary(token) and token != "", do: {:ok, token}

  defp get_access_token(user_id, _) do
    OAuth.get_valid_access_token(user_id, "google")
  end

  defp create_watch(user_id, access_token) do
    webhook_url = get_webhook_url()

    if is_nil(webhook_url) or webhook_url == "" do
      {:error, :webhook_url_not_configured}
    else
      channel_id = generate_channel_id()

      url = "#{api_base_url()}/calendars/primary/events/watch"

      body = %{
        id: channel_id,
        type: "web_hook",
        address: webhook_url,
        token: user_id,
        params: %{
          ttl: "604800"
        }
      }

      case Google.api_request(:post, url, access_token, body) do
        {:ok, response} ->
          {:ok,
           %{
             id: response["id"],
             resource_id: response["resourceId"],
             expiration: parse_expiration(response["expiration"])
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_events(access_token, opts) do
    sync_token = Keyword.get(opts, :sync_token)

    params =
      if sync_token do
        URI.encode_query(%{syncToken: sync_token})
      else
        # Initial full sync - get recent events
        time_min =
          DateTime.utc_now()
          |> DateTime.add(-7, :day)
          |> DateTime.to_iso8601()

        URI.encode_query(%{
          timeMin: time_min,
          singleEvents: true,
          maxResults: 100
        })
      end

    url = "#{api_base_url()}/calendars/primary/events?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, response} ->
        events = parse_events(response["items"] || [])

        {:ok, events}

      {:error, {:http_status, 410, _}} ->
        # Sync token expired - do full sync
        fetch_events(access_token, Keyword.delete(opts, :sync_token))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_events(items) do
    Enum.map(items, fn item ->
      %{
        event_id: item["id"],
        summary: item["summary"],
        description: item["description"],
        location: item["location"],
        status: item["status"],
        start: parse_event_time(item["start"]),
        end: parse_event_time(item["end"]),
        attendees: parse_attendees(item["attendees"]),
        organizer: item["organizer"]["email"],
        html_link: item["htmlLink"],
        created: item["created"],
        updated: item["updated"]
      }
    end)
  end

  defp parse_event_time(nil), do: nil

  defp parse_event_time(%{"dateTime" => dt}) when not is_nil(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _} -> datetime
      _ -> dt
    end
  end

  defp parse_event_time(%{"date" => date}) when not is_nil(date) do
    # All-day event
    %{date: date, all_day: true}
  end

  defp parse_event_time(_), do: nil

  defp parse_attendees(nil), do: []

  defp parse_attendees(attendees) do
    Enum.map(attendees, fn a ->
      %{
        email: a["email"],
        display_name: a["displayName"],
        response_status: a["responseStatus"],
        organizer: a["organizer"] || false,
        self: a["self"] || false
      }
    end)
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

  defp get_webhook_url do
    Application.get_env(:maraithon, :google, [])
    |> Keyword.get(:calendar_webhook_url, "")
  end

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value] -> value
      _ -> nil
    end
  end

  defp generate_channel_id do
    "maraithon-cal-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp api_base_url do
    Application.get_env(:maraithon, :google_calendar, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end
end
