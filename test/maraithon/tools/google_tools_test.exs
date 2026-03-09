defmodule Maraithon.Tools.GoogleToolsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.OAuth

  alias Maraithon.Tools.{
    GmailGetMessage,
    GmailListRecent,
    GmailSearch,
    GoogleCalendarListEvents
  }

  setup do
    original_gmail = Application.get_env(:maraithon, :gmail, [])
    original_google_calendar = Application.get_env(:maraithon, :google_calendar, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :gmail, original_gmail)
      Application.put_env(:maraithon, :google_calendar, original_google_calendar)
    end)

    :ok
  end

  test "GmailListRecent returns recent messages for a connected user" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    assert {:ok, _token} =
             OAuth.store_tokens("google-tool-user-1", "google", %{access_token: "google-token-1"})

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
      assert conn.query_string =~ "maxResults=2"
      assert conn.query_string =~ "labelIds=INBOX"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"messages" => [%{"id" => "m-1"}, %{"id" => "m-2"}]})
      )
    end)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/m-1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "m-1",
          "threadId" => "t-1",
          "snippet" => "Need a response",
          "labelIds" => ["INBOX"],
          "internalDate" => "1710000000000",
          "payload" => %{
            "headers" => [
              %{"name" => "From", "value" => "boss@example.com"},
              %{"name" => "Subject", "value" => "Status?"}
            ]
          }
        })
      )
    end)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/m-2", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "m-2",
          "threadId" => "t-2",
          "snippet" => "Calendar invite",
          "labelIds" => ["INBOX"],
          "payload" => %{"headers" => []}
        })
      )
    end)

    assert {:ok, result} =
             GmailListRecent.execute(%{
               "user_id" => "google-tool-user-1",
               "max_results" => 2
             })

    assert result.source == "gmail"
    assert result.count == 2
    assert Enum.map(result.messages, & &1.message_id) == ["m-1", "m-2"]
  end

  test "GmailSearch uses query and returns matched messages" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    assert {:ok, _token} =
             OAuth.store_tokens("google-tool-user-2", "google", %{access_token: "google-token-2"})

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
      assert conn.query_string =~ "q=from%3Aboss%40example.com"
      assert conn.query_string =~ "maxResults=5"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => [%{"id" => "m-9"}]}))
    end)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/m-9", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "m-9",
          "threadId" => "t-9",
          "snippet" => "Please reply",
          "labelIds" => ["INBOX"],
          "payload" => %{"headers" => [%{"name" => "Subject", "value" => "Urgent"}]}
        })
      )
    end)

    assert {:ok, result} =
             GmailSearch.execute(%{
               "user_id" => "google-tool-user-2",
               "query" => "from:boss@example.com",
               "max_results" => 5
             })

    assert result.source == "gmail"
    assert result.query == "from:boss@example.com"
    assert result.count == 1
    assert hd(result.messages).message_id == "m-9"
  end

  test "GmailGetMessage fetches one message by id" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    assert {:ok, _token} =
             OAuth.store_tokens("google-tool-user-3", "google", %{access_token: "google-token-3"})

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/m-42", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "m-42",
          "threadId" => "t-42",
          "snippet" => "One message",
          "labelIds" => ["INBOX"],
          "payload" => %{"headers" => [%{"name" => "Subject", "value" => "One"}]}
        })
      )
    end)

    assert {:ok, result} =
             GmailGetMessage.execute(%{
               "user_id" => "google-tool-user-3",
               "message_id" => "m-42"
             })

    assert result.source == "gmail"
    assert result.message_id == "m-42"
    assert result.message.message_id == "m-42"
    assert result.message.subject == "One"
  end

  test "GoogleCalendarListEvents returns parsed events for connected user" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :google_calendar,
      api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
    )

    assert {:ok, _token} =
             OAuth.store_tokens("google-tool-user-4", "google", %{access_token: "google-token-4"})

    Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
      assert conn.query_string =~ "maxResults=10"
      assert conn.query_string =~ "q=strategy"
      assert conn.query_string =~ "timeMin=2026-03-01T00%3A00%3A00Z"
      assert conn.query_string =~ "timeMax=2026-03-31T23%3A59%3A59Z"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "items" => [
            %{
              "id" => "evt-1",
              "summary" => "Strategy Review",
              "status" => "confirmed",
              "start" => %{"dateTime" => "2026-03-15T14:00:00Z"},
              "end" => %{"dateTime" => "2026-03-15T15:00:00Z"},
              "organizer" => %{"email" => "kent@example.com"}
            },
            %{
              "id" => "evt-2",
              "summary" => "Offsite",
              "status" => "confirmed",
              "start" => %{"date" => "2026-03-20"},
              "end" => %{"date" => "2026-03-21"},
              "organizer" => %{"email" => "team@example.com"}
            }
          ]
        })
      )
    end)

    assert {:ok, result} =
             GoogleCalendarListEvents.execute(%{
               "user_id" => "google-tool-user-4",
               "query" => "strategy",
               "time_min" => "2026-03-01T00:00:00Z",
               "time_max" => "2026-03-31T23:59:59Z",
               "max_results" => 10
             })

    assert result.source == "google_calendar"
    assert result.calendar_id == "primary"
    assert result.count == 2
    assert hd(result.events).event_id == "evt-1"
    assert is_struct(hd(result.events).start, DateTime)
    assert Enum.at(result.events, 1).start == %{date: "2026-03-20", all_day: true}
  end
end
