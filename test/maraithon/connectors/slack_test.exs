defmodule Maraithon.Connectors.SlackTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Maraithon.Connectors.Slack

  describe "handle_webhook/2" do
    test "handles url_verification challenge" do
      params = %{
        "type" => "url_verification",
        "challenge" => "test_challenge_string"
      }

      conn = conn(:post, "/webhooks/slack", params)

      assert {:challenge, "test_challenge_string"} = Slack.handle_webhook(conn, params)
    end

    test "parses message event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "Hello world",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "message"
      assert event.source == "slack"
      assert event.data.team_id == "T12345"
      assert event.data.text == "Hello world"
    end

    test "parses app_mention event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "app_mention",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "<@U_BOT> help me",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "app_mention"
    end

    test "parses reaction_added event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "reaction_added",
          "channel" => "C12345",
          "user" => "U12345",
          "reaction" => "thumbsup",
          "item" => %{
            "type" => "message",
            "channel" => "C12345",
            "ts" => "1234567890.123456"
          }
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "reaction_added"
    end

    test "ignores bot messages" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "channel" => "C12345",
          "bot_id" => "B12345",
          "text" => "Bot message"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      assert {:ignore, "bot message"} = Slack.handle_webhook(conn, params)
    end

    test "handles generic event type with string channel" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "file_shared",
          "channel" => "C99999",
          "file_id" => "F12345"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C99999"
      assert event.type == "file_shared"
    end

    test "handles event without channel" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "team_join",
          "user" => %{"id" => "U99999", "name" => "newuser"}
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345"
      assert event.type == "team_join"
    end

    test "returns ignore for unknown payload type" do
      params = %{"type" => nil}
      conn = conn(:post, "/webhooks/slack", params)

      assert {:ignore, "unknown type: "} = Slack.handle_webhook(conn, params)
    end

    test "returns ignore for missing type" do
      params = %{"invalid" => "payload"}
      conn = conn(:post, "/webhooks/slack", params)

      assert {:ignore, "unknown type: "} = Slack.handle_webhook(conn, params)
    end

    test "parses member_joined event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "member_joined_channel",
          "channel" => "C12345",
          "user" => "U99999"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "member_joined"
    end

    test "handles channel in item object" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "reaction_added",
          "item" => %{
            "channel" => "C77777"
          },
          "reaction" => "thumbsup"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, _event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C77777"
    end

    test "handles message subtype" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "subtype" => "channel_join",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "<@U12345> has joined the channel"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      # Message with subtype becomes message_subtype
      assert event.type == "message_channel_join"
    end

    test "parses message_changed event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "subtype" => "message_changed",
          "channel" => "C12345",
          "edited" => %{"user" => "U12345", "ts" => "1234567890.123456"}
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      assert event.type == "message_changed"
    end

    test "parses message_deleted event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "subtype" => "message_deleted",
          "channel" => "C12345"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      assert event.type == "message_deleted"
    end

    test "parses message with files" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "Here's a file",
          "ts" => "1234567890.123456",
          "files" => [
            %{
              "id" => "F12345",
              "name" => "test.txt",
              "mimetype" => "text/plain",
              "url_private" => "https://files.slack.com/...",
              "size" => 1234
            }
          ]
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      assert event.type == "message"
      assert length(event.data.files) == 1
    end

    test "parses member_left_channel event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "member_left_channel",
          "channel" => "C12345",
          "user" => "U99999"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "member_left"
    end

    test "parses reaction_removed event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "reaction_removed",
          "channel" => "C12345",
          "user" => "U12345",
          "reaction" => "thumbsup",
          "item" => %{
            "type" => "message",
            "channel" => "C12345",
            "ts" => "1234567890.123456"
          }
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "reaction_removed"
    end

    test "parses bot_message subtype as bot message" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "subtype" => "bot_message",
          "channel" => "C12345",
          "text" => "Bot message"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      assert {:ignore, "bot message"} = Slack.handle_webhook(conn, params)
    end

    test "handles generic event type" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "channel_archive",
          "channel" => "C12345"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "channel_archive"
    end
  end

  describe "verify_signature/2" do
    test "returns error for missing headers when secret configured" do
      Application.put_env(:maraithon, :slack, signing_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :slack) end)

      conn = conn(:post, "/webhooks/slack", %{})

      assert {:error, :missing_headers} = Slack.verify_signature(conn, "{}")
    end

    test "verifies valid signature" do
      signing_secret = "test_signing_secret"
      Application.put_env(:maraithon, :slack, signing_secret: signing_secret)
      on_exit(fn -> Application.delete_env(:maraithon, :slack) end)

      raw_body = ~s({"type":"event_callback"})
      timestamp = "#{System.system_time(:second)}"
      basestring = "v0:#{timestamp}:#{raw_body}"

      signature =
        :crypto.mac(:hmac, :sha256, signing_secret, basestring) |> Base.encode16(case: :lower)

      signature_header = "v0=#{signature}"

      conn =
        conn(:post, "/webhooks/slack", %{})
        |> Plug.Conn.put_req_header("x-slack-signature", signature_header)
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)

      assert :ok = Slack.verify_signature(conn, raw_body)
    end

    test "returns error for invalid signature" do
      Application.put_env(:maraithon, :slack, signing_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :slack) end)

      timestamp = "#{System.system_time(:second)}"

      conn =
        conn(:post, "/webhooks/slack", %{})
        |> Plug.Conn.put_req_header("x-slack-signature", "v0=invalid")
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)

      assert {:error, :invalid_signature} = Slack.verify_signature(conn, "{}")
    end
  end
end
