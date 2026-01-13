defmodule MaraithonWeb.WebhookControllerTest do
  # Non-async due to application config modification
  use MaraithonWeb.ConnCase, async: false

  setup do
    # Enable unsigned webhooks for testing
    Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
    Application.put_env(:maraithon, :slack, signing_secret: "", allow_unsigned: true)
    Application.put_env(:maraithon, :whatsapp, app_secret: "", verify_token: "test_verify_token", allow_unsigned: true)
    Application.put_env(:maraithon, :linear, webhook_secret: "", allow_unsigned: true)
    Application.put_env(:maraithon, :telegram, bot_token: "123456:ABC-DEF", webhook_secret_path: "secret123", allow_unsigned: true)

    on_exit(fn ->
      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :slack, signing_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :whatsapp, app_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :linear, webhook_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :telegram, allow_unsigned: false)
    end)

    :ok
  end

  describe "POST /webhooks/github" do
    test "handles push event", %{conn: conn} do
      payload = %{
        "ref" => "refs/heads/main",
        "repository" => %{"full_name" => "owner/repo"},
        "sender" => %{"login" => "user"},
        "commits" => [%{"id" => "abc123", "message" => "Test commit"}]
      }

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 200)["status"] == "published"
      assert json_response(conn, 200)["event_type"] == "push"
    end

    test "handles ping event", %{conn: conn} do
      payload = %{
        "zen" => "Keep it simple.",
        "hook_id" => 12345
      }

      conn =
        conn
        |> put_req_header("x-github-event", "ping")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "rejects invalid signature when not allowing unsigned", %{conn: conn} do
      # Temporarily disable allow_unsigned
      Application.put_env(:maraithon, :github, webhook_secret: "real_secret", allow_unsigned: false)

      payload = %{"action" => "test"}

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
    end
  end

  describe "POST /webhooks/slack" do
    test "handles url_verification challenge", %{conn: conn} do
      payload = %{
        "type" => "url_verification",
        "challenge" => "test_challenge_string"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=test")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert response(conn, 200) == "test_challenge_string"
    end

    test "handles event_callback", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "team_id" => "T123",
        "event" => %{
          "type" => "message",
          "channel" => "C123",
          "user" => "U123",
          "text" => "Hello world"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=test")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  describe "GET /webhooks/whatsapp" do
    test "handles verification challenge", %{conn: conn} do
      conn =
        conn
        |> get("/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "test_verify_token",
          "hub.challenge" => "challenge_response"
        })

      assert response(conn, 200) == "challenge_response"
    end

    test "rejects invalid verify token", %{conn: conn} do
      conn =
        conn
        |> get("/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong_token",
          "hub.challenge" => "challenge_response"
        })

      assert response(conn, 403) =~ "Verification failed"
    end
  end

  describe "POST /webhooks/whatsapp" do
    test "handles text message", %{conn: conn} do
      payload = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "changes" => [
              %{
                "field" => "messages",
                "value" => %{
                  "metadata" => %{"phone_number_id" => "12345"},
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "type" => "text",
                      "text" => %{"body" => "Hello"},
                      "id" => "msg123",
                      "timestamp" => "1234567890"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/whatsapp", payload)

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  describe "POST /webhooks/linear" do
    test "handles issue created event", %{conn: conn} do
      payload = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue123",
          "title" => "Test Issue",
          "state" => %{"name" => "Todo"},
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org123"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("linear-signature", "test-signature")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/linear", payload)

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  describe "POST /webhooks/telegram/:secret_path" do
    test "handles text message", %{conn: conn} do
      payload = %{
        "message" => %{
          "message_id" => 123,
          "from" => %{"id" => 456, "first_name" => "John"},
          "chat" => %{"id" => 789, "type" => "private"},
          "text" => "Hello bot"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/telegram/secret123", payload)

      assert json_response(conn, 200)["status"] == "published"
    end

    test "rejects invalid secret path", %{conn: conn} do
      # Temporarily disable allow_unsigned
      Application.put_env(:maraithon, :telegram, bot_token: "123456:ABC-DEF", webhook_secret_path: "secret123", allow_unsigned: false)

      payload = %{
        "message" => %{
          "message_id" => 123,
          "from" => %{"id" => 456},
          "chat" => %{"id" => 789, "type" => "private"},
          "text" => "Hello"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/telegram/wrong_secret", payload)

      assert json_response(conn, 401)["error"] == "Invalid request"

      Application.put_env(:maraithon, :telegram, bot_token: "123456:ABC-DEF", webhook_secret_path: "secret123", allow_unsigned: true)
    end
  end

  describe "POST /webhooks/google/calendar" do
    test "handles calendar sync notification", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-goog-channel-id", "channel123")
        |> put_req_header("x-goog-resource-id", "resource123")
        |> put_req_header("x-goog-resource-state", "sync")
        |> put_req_header("x-goog-channel-token", "user_123")
        |> post("/webhooks/google/calendar", %{})

      # Calendar returns ignore for sync notifications
      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "handles calendar exists notification", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-goog-channel-id", "channel123")
        |> put_req_header("x-goog-resource-id", "resource123")
        |> put_req_header("x-goog-resource-state", "exists")
        |> put_req_header("x-goog-channel-token", "user_123")
        |> post("/webhooks/google/calendar", %{})

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  describe "POST /webhooks/github - error handling" do
    test "handles missing repository error", %{conn: conn} do
      payload = %{
        "action" => "opened"
        # No repository key
      }

      conn =
        conn
        |> put_req_header("x-github-event", "issues")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 400)["error"] =~ "Failed to process webhook"
    end
  end

  describe "POST /webhooks/slack - error handling" do
    test "handles ignored events", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "team_id" => "T123",
        "event" => %{
          "type" => "message",
          "channel" => "C123",
          "bot_id" => "B123",
          "text" => "Bot message"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=test")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "rejects invalid signature when not allowing unsigned", %{conn: conn} do
      Application.put_env(:maraithon, :slack, signing_secret: "real_secret", allow_unsigned: false)

      payload = %{"type" => "event_callback"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=invalid")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :slack, signing_secret: "", allow_unsigned: true)
    end
  end

  describe "POST /webhooks/whatsapp - error handling" do
    test "handles ignored events", %{conn: conn} do
      payload = %{
        "object" => "other_object"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/whatsapp", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "rejects invalid signature when not allowing unsigned", %{conn: conn} do
      Application.put_env(:maraithon, :whatsapp, app_secret: "real_secret", allow_unsigned: false)

      payload = %{"object" => "whatsapp_business_account"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/whatsapp", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :whatsapp, app_secret: "", allow_unsigned: true)
    end
  end

  describe "POST /webhooks/linear - error handling" do
    test "handles events without team info", %{conn: conn} do
      payload = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue123",
          "title" => "Test Issue"
          # No team key
        },
        "organizationId" => "org123"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("linear-signature", "test-signature")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/linear", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    test "rejects invalid signature when secret configured", %{conn: conn} do
      Application.put_env(:maraithon, :linear, webhook_secret: "real_secret")

      payload = %{"action" => "create", "type" => "Issue"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        # No linear-signature header
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/linear", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :linear, webhook_secret: "", allow_unsigned: true)
    end
  end

  describe "POST /webhooks/telegram - error handling" do
    test "handles ignored events", %{conn: conn} do
      payload = %{
        "update_id" => 123
        # No message, callback_query, etc.
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/telegram/secret123", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end
  end

  describe "raw body handling" do
    test "falls back to re-encoding when raw_body is not cached", %{conn: conn} do
      payload = %{
        "ref" => "refs/heads/main",
        "repository" => %{"full_name" => "owner/repo"},
        "commits" => []
      }

      # Do not assign :raw_body - it will fall back to re-encoding
      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/github", payload)

      # Should still succeed (with allow_unsigned)
      assert json_response(conn, 200)["status"] == "published"
    end
  end
end
