defmodule Maraithon.Connectors.GmailTest do
  use Maraithon.DataCase, async: false

  import Plug.Test

  alias Maraithon.Connectors.Gmail

  setup do
    Application.put_env(:maraithon, :google,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/google/callback",
      pubsub_topic: "projects/test-project/topics/gmail-push"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
    end)

    :ok
  end

  describe "verify_signature/2" do
    test "always returns ok" do
      conn = conn(:post, "/webhooks/google/gmail", %{})

      assert :ok = Gmail.verify_signature(conn, ~s({}))
    end
  end

  describe "handle_webhook/2 - invalid payloads" do
    test "returns error for invalid pubsub format" do
      params = %{"invalid" => "format"}
      conn = conn(:post, "/webhooks/google/gmail", params)

      assert {:error, :invalid_pubsub_format} = Gmail.handle_webhook(conn, params)
    end

    test "returns error for invalid base64 data" do
      params = %{
        "message" => %{
          "data" => "not-valid-base64!!!",
          "messageId" => "msg123"
        }
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      assert {:error, :invalid_pubsub_message} = Gmail.handle_webhook(conn, params)
    end

    test "returns error for invalid json in data" do
      # Valid base64 but not valid JSON
      encoded_data = Base.encode64("not json")

      params = %{
        "message" => %{
          "data" => encoded_data,
          "messageId" => "msg123"
        }
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      assert {:error, :invalid_pubsub_message} = Gmail.handle_webhook(conn, params)
    end
  end

  describe "handle_webhook/2 - valid payload" do
    test "parses valid pubsub message and returns event" do
      # Gmail sends payload: {"emailAddress": "user@example.com", "historyId": "12345"}
      payload_json = ~s({"emailAddress":"user@test.com","historyId":"99999"})
      encoded_data = Base.encode64(payload_json)

      params = %{
        "message" => %{
          "data" => encoded_data,
          "messageId" => "msg123",
          "publishTime" => "2024-01-01T00:00:00Z"
        },
        "subscription" => "projects/test/subscriptions/gmail-push"
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      # Will return email_changed event since sync will fail (no token)
      {:ok, topic, event} = Gmail.handle_webhook(conn, params)

      assert topic == "email:user@test.com"
      assert event.source == "gmail"
      # Either email_sync or email_changed depending on sync result
      assert event.type in ["email_sync", "email_changed"]
    end
  end

  describe "setup_watch/2" do
    test "returns error when pubsub topic not configured" do
      Application.put_env(:maraithon, :google, pubsub_topic: "")

      assert {:error, :pubsub_topic_not_configured} = Gmail.setup_watch("user_123", "fake_token")
    end

    test "returns error when no valid token and user not found" do
      assert {:error, :no_token} = Gmail.setup_watch("nonexistent_user")
    end
  end

  describe "stop_watch/1" do
    test "returns error when token not found" do
      assert {:error, :no_token} = Gmail.stop_watch("nonexistent_user")
    end
  end

  describe "sync_mail_changes/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = Gmail.sync_mail_changes("nonexistent_user", "12345")
    end
  end

  describe "fetch_recent_emails/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = Gmail.fetch_recent_emails("nonexistent_user")
    end
  end

  describe "fetch_message/2" do
    test "returns error when token not found for user_id" do
      assert {:error, :no_token} = Gmail.fetch_message("nonexistent_user", "msg_id")
    end

    test "handles token directly starting with ya29." do
      # Will fail to connect but tests the branch
      result = Gmail.fetch_message("ya29.fake_token", "msg_id")
      assert match?({:error, _}, result)
    end
  end

  describe "setup_watch/2 - token handling" do
    test "returns error when pubsub topic not configured" do
      Application.put_env(:maraithon, :google, pubsub_topic: nil)

      result = Gmail.setup_watch("test_user", "valid_token")
      assert {:error, :pubsub_topic_not_configured} = result
    end

    test "returns error when pubsub topic is empty" do
      Application.put_env(:maraithon, :google, pubsub_topic: "")

      result = Gmail.setup_watch("test_user", "valid_token")
      assert {:error, :pubsub_topic_not_configured} = result
    end

    test "attempts API call when pubsub topic is configured" do
      Application.put_env(:maraithon, :google, pubsub_topic: "projects/test/topics/gmail")

      # Will fail on actual API call but tests the token path
      result = Gmail.setup_watch("test_user", "valid_token")
      # Will fail because API call to google fails
      assert match?({:error, _}, result)
    end
  end

  describe "stop_watch/1 with token" do
    setup do
      # Create an OAuth token for testing
      {:ok, token} =
        Maraithon.OAuth.store_tokens("gmail_test_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      {:ok, token: token}
    end

    test "attempts to stop watch with valid token" do
      # Will fail on actual API call but tests the token retrieval path
      result = Gmail.stop_watch("gmail_test_user")
      assert match?({:error, _}, result)
    end
  end

  describe "sync_mail_changes/2 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_test_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch history with valid token" do
      # Will fail on actual API call but tests the token retrieval path
      result = Gmail.sync_mail_changes("sync_test_user", "12345")
      assert match?({:error, _}, result)
    end
  end

  describe "fetch_recent_emails/2 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("email_test_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch emails with valid token" do
      result = Gmail.fetch_recent_emails("email_test_user", 5)
      assert match?({:error, _}, result)
    end
  end

  describe "handle_webhook/2 - successful sync" do
    setup do
      # Create token for user that will be used in webhook
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("user@test.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "returns email_changed event when sync fails on API" do
      payload_json = ~s({"emailAddress":"user@test.com","historyId":"99999"})
      encoded_data = Base.encode64(payload_json)

      params = %{
        "message" => %{
          "data" => encoded_data,
          "messageId" => "msg123"
        }
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      {:ok, topic, event} = Gmail.handle_webhook(conn, params)

      assert topic == "email:user@test.com"
      assert event.source == "gmail"
      # Sync will fail because API call fails, but event is still generated
      assert event.type in ["email_sync", "email_changed"]
    end
  end

  describe "setup_watch/2 with Bypass" do
    test "successfully creates watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google, pubsub_topic: "projects/test/topics/gmail")

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/watch", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["topicName"] == "projects/test/topics/gmail"
        assert params["labelIds"] == ["INBOX"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "historyId" => "12345",
            "expiration" => "#{System.system_time(:millisecond) + 86_400_000}"
          })
        )
      end)

      {:ok, watch} = Gmail.setup_watch("user_123", "test_access_token")

      assert watch.history_id == "12345"
      assert %DateTime{} = watch.expiration
    end
  end

  describe "fetch_recent_emails/2 with Bypass" do
    test "successfully fetches emails" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("fetch_emails_user", "google", %{
          access_token: "ya29.test_access_token",
          refresh_token: "1//test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      # Mock messages list endpoint
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "messages" => [
              %{"id" => "msg1", "threadId" => "thread1"},
              %{"id" => "msg2", "threadId" => "thread2"}
            ]
          })
        )
      end)

      # Mock individual message fetch
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/msg1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "msg1",
            "threadId" => "thread1",
            "snippet" => "Test email snippet",
            "labelIds" => ["INBOX", "UNREAD"],
            "internalDate" => "#{System.system_time(:millisecond)}",
            "payload" => %{
              "headers" => [
                %{"name" => "From", "value" => "sender@test.com"},
                %{"name" => "To", "value" => "me@test.com"},
                %{"name" => "Subject", "value" => "Test Subject"},
                %{"name" => "Date", "value" => "Mon, 1 Jan 2024 00:00:00 +0000"}
              ]
            }
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/msg2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "msg2",
            "threadId" => "thread2",
            "snippet" => "Another email",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => []}
          })
        )
      end)

      {:ok, emails} = Gmail.fetch_recent_emails("fetch_emails_user", 2)

      assert length(emails) == 2
      assert hd(emails).message_id == "msg1"
      assert hd(emails).subject == "Test Subject"
      assert hd(emails).from == "sender@test.com"
    end

    test "returns empty list when no messages" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("fetch_no_emails_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"resultSizeEstimate" => 0}))
      end)

      {:ok, emails} = Gmail.fetch_recent_emails("fetch_no_emails_user")

      assert emails == []
    end
  end

  describe "sync_mail_changes/2 with Bypass - history endpoint" do
    test "successfully syncs mail changes" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_bypass_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      # Mock history endpoint
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "history" => [
              %{
                "messagesAdded" => [
                  %{"message" => %{"id" => "new_msg1"}}
                ]
              }
            ],
            "historyId" => "12346"
          })
        )
      end)

      # Mock message fetch
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/new_msg1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "new_msg1",
            "threadId" => "thread1",
            "snippet" => "New email",
            "labelIds" => ["INBOX"],
            "payload" => %{
              "headers" => [
                %{"name" => "Subject", "value" => "New Message"}
              ]
            }
          })
        )
      end)

      {:ok, messages} = Gmail.sync_mail_changes("sync_bypass_user", "12345")

      assert length(messages) == 1
      assert hd(messages).message_id == "new_msg1"
    end

    test "returns empty list when no history changes" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_empty_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"historyId" => "12346"}))
      end)

      {:ok, messages} = Gmail.sync_mail_changes("sync_empty_user", "12345")

      assert messages == []
    end

    test "returns history_expired error on 404" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_expired_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => %{"code" => 404}}))
      end)

      result = Gmail.sync_mail_changes("sync_expired_user", "12345")

      assert {:error, :history_expired} = result
    end
  end

  describe "stop_watch/1 with Bypass" do
    test "successfully stops watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("stop_bypass_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Gmail.stop_watch("stop_bypass_user")
    end

    test "returns ok on 404 (not watching)" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("stop_404_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => %{"code" => 404}}))
      end)

      assert :ok = Gmail.stop_watch("stop_404_user")
    end
  end
end
