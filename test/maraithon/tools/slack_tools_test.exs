defmodule Maraithon.Tools.SlackToolsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.OAuth

  alias Maraithon.Tools.{
    SlackGetThreadReplies,
    SlackListConversations,
    SlackListMessages,
    SlackSearchMessages
  }

  setup do
    original_slack = Application.get_env(:maraithon, :slack, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :slack, original_slack)
    end)

    :ok
  end

  test "SlackListConversations lists channels for a connected workspace" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("slack-tool-user-1", "slack:T123", %{
               access_token: "xoxb-bot-token",
               scopes: ["channels:read", "channels:history"]
             })

    Bypass.expect_once(bypass, "GET", "/api/conversations.list", fn conn ->
      assert ["Bearer xoxb-bot-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "types=public_channel%2Cprivate_channel"
      assert conn.query_string =~ "exclude_archived=false"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "C111", "name" => "general", "is_private" => false},
            %{"id" => "C222", "name" => "exec", "is_private" => true}
          ]
        })
      )
    end)

    assert {:ok, result} =
             SlackListConversations.execute(%{
               "user_id" => "slack-tool-user-1",
               "team_id" => "T123",
               "types" => "public_channel,private_channel"
             })

    assert result.source == "slack"
    assert result.count == 2
    assert Enum.map(result.conversations, & &1.id) == ["C111", "C222"]
  end

  test "SlackListMessages reads conversation history" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("slack-tool-user-2", "slack:T123", %{
               access_token: "xoxb-bot-token",
               scopes: ["channels:history"]
             })

    Bypass.expect_once(bypass, "GET", "/api/conversations.history", fn conn ->
      assert ["Bearer xoxb-bot-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "channel=C111"
      assert conn.query_string =~ "limit=2"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "has_more" => false,
          "messages" => [
            %{"ts" => "1762502400.000001", "user" => "U1", "text" => "Need this today?"},
            %{
              "ts" => "1762502600.000001",
              "user" => "U2",
              "text" => "Working on it",
              "thread_ts" => "1762502400.000001"
            }
          ]
        })
      )
    end)

    assert {:ok, result} =
             SlackListMessages.execute(%{
               "user_id" => "slack-tool-user-2",
               "team_id" => "T123",
               "channel" => "C111",
               "limit" => 2
             })

    assert result.source == "slack"
    assert result.count == 2
    assert hd(result.messages).text == "Need this today?"
  end

  test "SlackGetThreadReplies reads thread messages" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("slack-tool-user-3", "slack:T123", %{
               access_token: "xoxb-bot-token",
               scopes: ["channels:history"]
             })

    Bypass.expect_once(bypass, "GET", "/api/conversations.replies", fn conn ->
      assert ["Bearer xoxb-bot-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "channel=C111"
      assert conn.query_string =~ "ts=1762502400.000001"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{"ts" => "1762502400.000001", "user" => "U1", "text" => "Original"},
            %{"ts" => "1762502500.000001", "user" => "U2", "text" => "Reply"}
          ]
        })
      )
    end)

    assert {:ok, result} =
             SlackGetThreadReplies.execute(%{
               "user_id" => "slack-tool-user-3",
               "team_id" => "T123",
               "channel" => "C111",
               "thread_ts" => "1762502400.000001"
             })

    assert result.source == "slack"
    assert result.thread_ts == "1762502400.000001"
    assert result.count == 2
  end

  test "SlackSearchMessages uses user token for personal scope searches" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("slack-tool-user-4", "slack:T123:user:U999", %{
               access_token: "xoxp-user-token",
               scopes: ["search:read"]
             })

    Bypass.expect_once(bypass, "GET", "/api/search.messages", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "query=send+the+deck"
      assert conn.query_string =~ "count=5"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => %{
            "total" => 1,
            "matches" => [
              %{
                "ts" => "1762502400.000001",
                "text" => "I will send the deck today",
                "user" => "U999",
                "channel" => %{"id" => "D111", "name" => "directmessage"},
                "permalink" => "https://example.slack.com/archives/D111/p1762502400000001"
              }
            ]
          }
        })
      )
    end)

    assert {:ok, result} =
             SlackSearchMessages.execute(%{
               "user_id" => "slack-tool-user-4",
               "team_id" => "T123",
               "query" => "send the deck",
               "count" => 5
             })

    assert result.source == "slack"
    assert result.count == 1
    assert hd(result.matches).channel_id == "D111"
  end
end
