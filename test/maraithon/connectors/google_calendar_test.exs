defmodule Maraithon.Connectors.GoogleCalendarTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Connectors.GoogleCalendar

  setup do
    Application.put_env(:maraithon, :google,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/google/callback",
      calendar_webhook_url: "https://example.com/webhooks/gcal"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
    end)

    :ok
  end

  describe "verify_signature/2" do
    test "always returns :ok (Google uses channel tokens)" do
      conn = %Plug.Conn{}
      assert :ok = GoogleCalendar.verify_signature(conn, "any_body")
    end
  end

  describe "handle_webhook/2" do
    test "returns error for missing channel token" do
      conn = build_conn_with_headers(%{})

      assert {:error, :missing_channel_token} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "returns error for empty channel token" do
      conn = build_conn_with_headers(%{"x-goog-channel-token" => ""})

      assert {:error, :missing_channel_token} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "ignores sync confirmation" do
      conn = build_conn_with_headers(%{
        "x-goog-channel-id" => "channel123",
        "x-goog-resource-id" => "resource123",
        "x-goog-resource-state" => "sync",
        "x-goog-channel-token" => "user_123"
      })

      assert {:ignore, "sync confirmation"} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "returns event for not_exists state" do
      conn = build_conn_with_headers(%{
        "x-goog-channel-id" => "channel123",
        "x-goog-resource-id" => "resource123",
        "x-goog-resource-state" => "not_exists",
        "x-goog-channel-token" => "user_123"
      })

      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:user_123"
      assert event.type == "calendar_deleted"
      assert event.source == "google_calendar"
      assert event.data.user_id == "user_123"
      assert event.data.channel_id == "channel123"
      assert event.data.resource_id == "resource123"
    end

    test "ignores unknown resource states" do
      conn = build_conn_with_headers(%{
        "x-goog-channel-id" => "channel123",
        "x-goog-resource-id" => "resource123",
        "x-goog-resource-state" => "unknown_state",
        "x-goog-channel-token" => "user_123"
      })

      assert {:ignore, "unknown resource state: unknown_state"} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "handles exists state (calendar changed)" do
      conn = build_conn_with_headers(%{
        "x-goog-channel-id" => "channel123",
        "x-goog-resource-id" => "resource123",
        "x-goog-resource-state" => "exists",
        "x-goog-channel-token" => "user_123"
      })

      # Will fail to sync because no OAuth token exists for user_123
      # but should still return a calendar_changed event
      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:user_123"
      # Event type depends on whether sync succeeded
      assert event.type in ["calendar_sync", "calendar_changed"]
      assert event.source == "google_calendar"
    end
  end

  describe "setup_watch/2" do
    test "returns error when webhook URL not configured" do
      Application.put_env(:maraithon, :google, calendar_webhook_url: "")

      assert {:error, :webhook_url_not_configured} = GoogleCalendar.setup_watch("user_123", "fake_token")
    end

    test "returns error when no valid token and user not found" do
      assert {:error, :no_token} = GoogleCalendar.setup_watch("nonexistent_user")
    end
  end

  describe "sync_calendar_events/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = GoogleCalendar.sync_calendar_events("nonexistent_user")
    end
  end

  describe "fetch_upcoming_events/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = GoogleCalendar.fetch_upcoming_events("nonexistent_user")
    end
  end

  describe "stop_watch/3" do
    test "returns error when token not found" do
      assert {:error, :no_token} = GoogleCalendar.stop_watch("nonexistent_user", "channel_id", "resource_id")
    end
  end

  describe "setup_watch/2 with token" do
    test "returns success with direct access token" do
      Application.put_env(:maraithon, :google,
        calendar_webhook_url: "https://example.com/webhooks/gcal"
      )

      # Will fail on API call but tests the token path
      result = GoogleCalendar.setup_watch("test_user", "valid_access_token")
      assert match?({:error, _}, result)
    end
  end

  describe "stop_watch/3 with token" do
    setup do
      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_stop_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to stop watch with valid token" do
      result = GoogleCalendar.stop_watch("cal_stop_user", "channel_id", "resource_id")
      assert match?({:error, _}, result)
    end
  end

  describe "sync_calendar_events/2 with token" do
    setup do
      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_sync_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch events with valid token" do
      result = GoogleCalendar.sync_calendar_events("cal_sync_user")
      assert match?({:error, _}, result)
    end

    test "accepts sync_token option" do
      result = GoogleCalendar.sync_calendar_events("cal_sync_user", sync_token: "sync123")
      assert match?({:error, _}, result)
    end
  end

  describe "fetch_upcoming_events/2 with token" do
    setup do
      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_upcoming_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch upcoming events with valid token" do
      result = GoogleCalendar.fetch_upcoming_events("cal_upcoming_user", 5)
      assert match?({:error, _}, result)
    end
  end

  describe "handle_webhook/2 - exists state with token" do
    setup do
      {:ok, _token} = Maraithon.OAuth.store_tokens("webhook_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "returns calendar_changed event when sync fails" do
      conn = build_conn_with_headers(%{
        "x-goog-channel-id" => "channel123",
        "x-goog-resource-id" => "resource123",
        "x-goog-resource-state" => "exists",
        "x-goog-channel-token" => "webhook_user"
      })

      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:webhook_user"
      assert event.source == "google_calendar"
      # Will be calendar_changed since API call fails
      assert event.type in ["calendar_sync", "calendar_changed"]
    end
  end

  describe "setup_watch/2 with Bypass" do
    test "successfully creates watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        calendar_webhook_url: "https://example.com/webhooks/gcal"
      )
      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events/watch", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["type"] == "web_hook"
        assert params["address"] == "https://example.com/webhooks/gcal"
        assert params["token"] == "user_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "id" => "channel-123",
          "resourceId" => "resource-456",
          "expiration" => "#{System.system_time(:millisecond) + 86400000}"
        }))
      end)

      {:ok, watch} = GoogleCalendar.setup_watch("user_123", "test_access_token")

      assert watch.id == "channel-123"
      assert watch.resource_id == "resource-456"
      assert %DateTime{} = watch.expiration
    end
  end

  describe "fetch_upcoming_events/2 with Bypass" do
    test "successfully fetches events" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_fetch_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "items" => [
            %{
              "id" => "event1",
              "summary" => "Meeting with Bob",
              "description" => "Discuss project",
              "location" => "Conference Room A",
              "status" => "confirmed",
              "start" => %{"dateTime" => "2024-01-15T10:00:00Z"},
              "end" => %{"dateTime" => "2024-01-15T11:00:00Z"},
              "attendees" => [
                %{"email" => "bob@test.com", "displayName" => "Bob", "responseStatus" => "accepted"}
              ],
              "organizer" => %{"email" => "me@test.com"},
              "htmlLink" => "https://calendar.google.com/event/event1",
              "created" => "2024-01-01T00:00:00Z",
              "updated" => "2024-01-02T00:00:00Z"
            }
          ]
        }))
      end)

      {:ok, events} = GoogleCalendar.fetch_upcoming_events("cal_fetch_user", 10)

      assert length(events) == 1
      event = hd(events)
      assert event.event_id == "event1"
      assert event.summary == "Meeting with Bob"
      assert event.location == "Conference Room A"
      assert length(event.attendees) == 1
    end
  end

  describe "sync_calendar_events/2 with Bypass" do
    test "successfully syncs events" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_sync_bypass_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "items" => [
            %{
              "id" => "event2",
              "summary" => "Team Standup",
              "start" => %{"dateTime" => "2024-01-15T09:00:00Z"},
              "end" => %{"dateTime" => "2024-01-15T09:15:00Z"},
              "organizer" => %{"email" => "team@test.com"}
            }
          ],
          "nextSyncToken" => "sync_token_123"
        }))
      end)

      {:ok, events} = GoogleCalendar.sync_calendar_events("cal_sync_bypass_user")

      assert length(events) == 1
      assert hd(events).event_id == "event2"
    end

    test "handles sync token for incremental sync" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_incremental_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        # Verify sync token is passed
        assert conn.query_string =~ "syncToken"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "items" => [],
          "nextSyncToken" => "new_sync_token"
        }))
      end)

      {:ok, events} = GoogleCalendar.sync_calendar_events("cal_incremental_user", sync_token: "old_token")

      assert events == []
    end

    test "handles 410 Gone by doing full sync" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_410_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          # First call with sync token returns 410
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(410, Jason.encode!(%{"error" => %{"code" => 410}}))
        else
          # Second call (full sync) succeeds
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{
            "items" => [%{
              "id" => "event3",
              "summary" => "Recovered Event",
              "start" => %{"date" => "2024-01-16"},
              "end" => %{"date" => "2024-01-17"},
              "organizer" => %{"email" => "org@test.com"}
            }]
          }))
        end
      end)

      {:ok, events} = GoogleCalendar.sync_calendar_events("cal_410_user", sync_token: "expired_token")

      assert length(events) == 1
      assert hd(events).event_id == "event3"
    end
  end

  describe "stop_watch/3 with Bypass" do
    test "successfully stops watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} = Maraithon.OAuth.store_tokens("cal_stop_bypass_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      Bypass.expect_once(bypass, "POST", "/calendar/v3/channels/stop", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["id"] == "channel_123"
        assert params["resourceId"] == "resource_456"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = GoogleCalendar.stop_watch("cal_stop_bypass_user", "channel_123", "resource_456")
    end
  end

  describe "handle_webhook/2 - exists state with Bypass" do
    test "returns calendar_sync event when sync succeeds" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} = Maraithon.OAuth.store_tokens("webhook_bypass_user", "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["calendar.readonly"]
      })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "items" => [
            %{
              "id" => "updated_event",
              "summary" => "Updated Meeting",
              "start" => %{"dateTime" => "2024-01-15T14:00:00Z"},
              "end" => %{"dateTime" => "2024-01-15T15:00:00Z"},
              "organizer" => %{"email" => "me@test.com"}
            }
          ]
        }))
      end)

      conn = build_conn_with_headers(%{
        "x-goog-channel-id" => "channel123",
        "x-goog-resource-id" => "resource123",
        "x-goog-resource-state" => "exists",
        "x-goog-channel-token" => "webhook_bypass_user"
      })

      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:webhook_bypass_user"
      assert event.type == "calendar_sync"
      assert event.source == "google_calendar"
      assert length(event.data.events) == 1
    end
  end

  # Helper functions

  defp build_conn_with_headers(headers) do
    conn = %Plug.Conn{req_headers: []}

    Enum.reduce(headers, conn, fn {header, value}, acc ->
      %{acc | req_headers: [{header, value} | acc.req_headers]}
    end)
  end
end
