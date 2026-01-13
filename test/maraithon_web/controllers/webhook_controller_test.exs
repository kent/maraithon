# ==============================================================================
# Webhook Controller Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# Webhooks are the primary way Maraithon connects to the outside world. They
# allow agents to react to real-world events in real-time:
#
# - **GitHub**: PR opened, issue created, code pushed, CI failed
# - **Slack**: New message in channel, user mentioned, emoji reaction
# - **WhatsApp**: Incoming message from customer
# - **Linear**: Issue created, status changed, assignee updated
# - **Telegram**: Bot receives message, callback query
# - **Google Calendar**: Event created, updated, or deleted
#
# From a user's perspective, webhooks are what make agents feel "alive" and
# responsive. Instead of polling APIs every few minutes, agents receive
# instant notifications when something happens.
#
# Example User Journey:
# 1. User connects their GitHub repo to Maraithon
# 2. User creates an agent subscribed to "github:owner/repo"
# 3. Developer opens a PR on that repo
# 4. GitHub sends a webhook to /webhooks/github
# 5. Maraithon validates the signature and publishes to PubSub
# 6. Agent receives the event and responds (e.g., posts a review)
#
# WHY THESE TESTS MATTER:
# -----------------------
# If webhook handling breaks, users experience:
# - Agents that never respond to external events
# - Security vulnerabilities if signature verification fails
# - Silent failures with no visibility into what went wrong
# - Missed business-critical notifications
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the WebhookController, which handles incoming
# webhook requests from external services. Each provider (GitHub, Slack, etc.)
# has its own signature verification scheme and payload format.
#
# Webhook Processing Flow:
# ------------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                        Webhook Processing                                │
#   │                                                                          │
#   │   External Service                                                       │
#   │   (GitHub, Slack, etc.)                                                 │
#   │          │                                                               │
#   │          ▼                                                               │
#   │   ┌─────────────────┐                                                   │
#   │   │ POST /webhooks/ │  ◄── Raw HTTP request with signature              │
#   │   │    {provider}   │                                                   │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │    Signature    │  ◄── Verify HMAC-SHA256 (or provider-specific)    │
#   │   │   Verification  │                                                   │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │     Connector   │  ◄── Parse payload, extract event type            │
#   │   │   (per-provider)│      Build normalized event structure             │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │  Phoenix.PubSub │  ◄── Publish to topic (e.g., "github:owner/repo") │
#   │   │     Broadcast   │                                                   │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │ Subscribed      │  ◄── Agents receive {:pubsub_event, topic, data}  │
#   │   │    Agents       │                                                   │
#   │   └─────────────────┘                                                   │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Signature Verification by Provider:
# -----------------------------------
# - GitHub: HMAC-SHA256 in X-Hub-Signature-256 header
# - Slack: HMAC-SHA256 with timestamp in X-Slack-Signature header
# - WhatsApp: HMAC-SHA256 in X-Hub-Signature-256 header (same as GitHub)
# - Linear: HMAC-SHA256 in Linear-Signature header
# - Telegram: Secret path in URL (e.g., /webhooks/telegram/{secret})
# - Google: No signature (relies on channel token validation)
#
# Test Categories:
# ----------------
# - Signature Verification: Ensure invalid signatures are rejected
# - Event Parsing: Verify different event types are handled correctly
# - PubSub Publishing: Confirm events are broadcast to correct topics
# - Error Handling: Graceful handling of malformed payloads
# - Challenge/Verification: Provider-specific URL verification flows
#
# Dependencies:
# -------------
# - MaraithonWeb.WebhookController (the controller being tested)
# - Maraithon.Connectors.* (provider-specific connectors)
# - Phoenix.PubSub (for event broadcasting)
# - Application config (webhook secrets, allow_unsigned flags)
#
# Setup Requirements:
# -------------------
# This test uses `async: false` because:
# 1. Application config is modified during tests (allow_unsigned flags)
# 2. Config changes must be isolated between tests
# 3. on_exit callbacks restore original config
#
# ==============================================================================

defmodule MaraithonWeb.WebhookControllerTest do
  # Non-async due to application config modification
  use MaraithonWeb.ConnCase, async: false

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # Configures all webhook providers to allow unsigned requests for testing.
  # In production, all webhooks require valid signatures for security.
  #
  # The allow_unsigned flag is a development/testing convenience that lets us
  # test webhook handling without computing real HMAC signatures.
  # ----------------------------------------------------------------------------
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

  # ============================================================================
  # GITHUB WEBHOOK TESTS
  # ============================================================================
  #
  # GitHub webhooks are triggered by repository events:
  # - push: Code pushed to branch
  # - pull_request: PR opened/closed/merged
  # - issues: Issue opened/closed/commented
  # - ping: Webhook configuration validation
  #
  # GitHub uses HMAC-SHA256 for signature verification.
  # ============================================================================

  describe "POST /webhooks/github" do
    @doc """
    Verifies that push events are processed and published.
    Push events contain commit information and branch references.
    These are published to topic "github:{owner}/{repo}".
    """
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

    @doc """
    Verifies that ping events are ignored (not published).
    Ping events are sent by GitHub when configuring a new webhook.
    They're used to verify the endpoint is reachable.
    """
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

    @doc """
    Verifies that invalid signatures are rejected when security is enabled.
    This is critical for preventing spoofed webhooks from malicious actors.
    """
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

  # ============================================================================
  # SLACK WEBHOOK TESTS
  # ============================================================================
  #
  # Slack webhooks are triggered by workspace events:
  # - url_verification: Challenge/response for endpoint setup
  # - event_callback: Actual events (messages, reactions, etc.)
  #
  # Slack uses a custom signature scheme with timestamp and HMAC-SHA256.
  # ============================================================================

  describe "POST /webhooks/slack" do
    @doc """
    Verifies URL verification challenge handling.
    When you configure a Slack app, Slack sends a challenge request.
    The server must respond with the challenge value to prove ownership.
    """
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

    @doc """
    Verifies that event_callback messages are processed and published.
    These contain actual user events like messages, reactions, etc.
    Published to topic "slack:{team_id}".
    """
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

  # ============================================================================
  # WHATSAPP WEBHOOK TESTS
  # ============================================================================
  #
  # WhatsApp webhooks are triggered by messaging events:
  # - GET: URL verification (hub.challenge)
  # - POST: Incoming messages, status updates
  #
  # WhatsApp uses the same signature scheme as Facebook (HMAC-SHA256).
  # ============================================================================

  describe "GET /webhooks/whatsapp" do
    @doc """
    Verifies URL verification challenge handling for WhatsApp.
    Meta requires you to verify your webhook endpoint before they send events.
    You must respond with the hub.challenge value.
    """
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

    @doc """
    Verifies that invalid verify tokens are rejected.
    This prevents unauthorized parties from receiving your webhooks.
    """
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
    @doc """
    Verifies that incoming WhatsApp messages are processed.
    Messages contain sender info, message content, and metadata.
    Published to topic "whatsapp:{phone_number_id}".
    """
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

  # ============================================================================
  # LINEAR WEBHOOK TESTS
  # ============================================================================
  #
  # Linear webhooks are triggered by project management events:
  # - Issue created/updated/deleted
  # - Comment added
  # - Status changed
  #
  # Linear uses HMAC-SHA256 with the Linear-Signature header.
  # ============================================================================

  describe "POST /webhooks/linear" do
    @doc """
    Verifies that issue creation events are processed.
    Issue events contain full issue data including title, state, team.
    Published to topic "linear:{team_key}".
    """
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

  # ============================================================================
  # TELEGRAM WEBHOOK TESTS
  # ============================================================================
  #
  # Telegram webhooks are triggered by bot interactions:
  # - Message received
  # - Callback query (inline button pressed)
  # - Inline query
  #
  # Telegram uses a secret path for verification (no signature header).
  # ============================================================================

  describe "POST /webhooks/telegram/:secret_path" do
    @doc """
    Verifies that incoming Telegram messages are processed.
    Messages contain chat info, sender info, and message content.
    Published to topic "telegram:{chat_id}".
    """
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

    @doc """
    Verifies that requests with wrong secret path are rejected.
    This is Telegram's authentication mechanism - the webhook URL includes
    a secret that only Telegram and your server know.
    """
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

  # ============================================================================
  # GOOGLE CALENDAR WEBHOOK TESTS
  # ============================================================================
  #
  # Google Calendar webhooks notify of calendar changes:
  # - sync: Initial synchronization (ignored)
  # - exists: Resource was created/updated
  #
  # Google uses channel tokens for verification (no HMAC signature).
  # ============================================================================

  describe "POST /webhooks/google/calendar" do
    @doc """
    Verifies that sync notifications are ignored.
    Sync notifications are sent when a watch is first created.
    They don't contain actual event data.
    """
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

    @doc """
    Verifies that exists notifications are processed.
    Exists means the resource was modified - we need to fetch changes.
    Published to topic "calendar:{user_id}".
    """
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

  # ============================================================================
  # ERROR HANDLING TESTS - GITHUB
  # ============================================================================
  #
  # These tests verify graceful error handling for malformed payloads.
  # ============================================================================

  describe "POST /webhooks/github - error handling" do
    @doc """
    Verifies error handling when repository info is missing.
    All GitHub events should include repository context.
    """
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

  # ============================================================================
  # ERROR HANDLING TESTS - SLACK
  # ============================================================================

  describe "POST /webhooks/slack - error handling" do
    @doc """
    Verifies that bot messages are ignored to prevent loops.
    When a bot posts a message, it shouldn't trigger another bot response.
    """
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

    @doc """
    Verifies signature rejection when security is enabled for Slack.
    """
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

  # ============================================================================
  # ERROR HANDLING TESTS - WHATSAPP
  # ============================================================================

  describe "POST /webhooks/whatsapp - error handling" do
    @doc """
    Verifies that non-WhatsApp Business Account objects are ignored.
    The object field tells us the type of webhook.
    """
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

    @doc """
    Verifies signature rejection when security is enabled for WhatsApp.
    """
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

  # ============================================================================
  # ERROR HANDLING TESTS - LINEAR
  # ============================================================================

  describe "POST /webhooks/linear - error handling" do
    @doc """
    Verifies that events without team info are ignored.
    We need team info to determine the topic for publishing.
    """
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

    @doc """
    Verifies signature rejection when secret is configured for Linear.
    """
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

  # ============================================================================
  # ERROR HANDLING TESTS - TELEGRAM
  # ============================================================================

  describe "POST /webhooks/telegram - error handling" do
    @doc """
    Verifies that updates without message/callback are ignored.
    Telegram sends many update types; we only care about some.
    """
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

  # ============================================================================
  # RAW BODY HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that the webhook handler works with or without
  # the raw body being cached in conn.assigns. The raw body is needed
  # for signature verification.
  # ============================================================================

  describe "raw body handling" do
    @doc """
    Verifies fallback when raw_body is not cached in assigns.
    The CacheRawBody plug should cache it, but we have a fallback
    that re-encodes the parsed params if needed.
    """
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
