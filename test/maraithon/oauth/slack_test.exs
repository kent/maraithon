defmodule Maraithon.OAuth.SlackTest do
  use ExUnit.Case, async: false

  alias Maraithon.OAuth.Slack

  setup do
    Application.put_env(:maraithon, :slack,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/slack/callback",
      signing_secret: "test_signing_secret"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :slack, [])
    end)

    :ok
  end

  describe "default_scopes/0" do
    test "returns default scopes" do
      scopes = Slack.default_scopes()

      assert "channels:history" in scopes
      assert "channels:read" in scopes
      assert "chat:write" in scopes
      assert "users:read" in scopes
      assert "reactions:read" in scopes
    end
  end

  describe "authorize_url/2" do
    test "generates valid authorization URL with default scopes" do
      state = "test_state_123"

      url = Slack.authorize_url(state)

      assert url =~ "https://slack.com/oauth/v2/authorize?"
      assert url =~ "client_id=test_client_id"
      assert url =~ "redirect_uri="
      assert url =~ "state=test_state_123"
      assert url =~ "scope="
    end

    test "generates URL with custom scopes" do
      scopes = ["channels:history", "chat:write"]
      state = "custom_state"

      url = Slack.authorize_url(scopes, state)

      assert url =~ "scope=channels%3Ahistory%2Cchat%3Awrite"
      assert url =~ "state=custom_state"
    end
  end

  describe "exchange_code/1" do
    test "returns error for invalid code" do
      result = Slack.exchange_code("invalid_code")

      assert match?({:error, _}, result)
    end

    test "successfully exchanges code for tokens" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/slack/callback",
        token_url: "http://localhost:#{bypass.port}/api/oauth.v2.access"
      )

      Bypass.expect_once(bypass, "POST", "/api/oauth.v2.access", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["code"] == "valid_auth_code"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "access_token" => "xoxb-test-token",
            "token_type" => "bot",
            "scope" => "channels:history,chat:write",
            "team" => %{"id" => "T123", "name" => "Test Team"},
            "bot_user_id" => "U123",
            "app_id" => "A123",
            "authed_user" => %{"id" => "U456"}
          })
        )
      end)

      {:ok, tokens} = Slack.exchange_code("valid_auth_code")

      assert tokens.access_token == "xoxb-test-token"
      assert tokens.team_id == "T123"
      assert tokens.team_name == "Test Team"
      assert tokens.bot_user_id == "U123"
    end

    test "returns error on Slack API error" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        token_url: "http://localhost:#{bypass.port}/api/oauth.v2.access"
      )

      Bypass.expect_once(bypass, "POST", "/api/oauth.v2.access", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => false,
            "error" => "invalid_code"
          })
        )
      end)

      result = Slack.exchange_code("bad_code")

      assert {:error, {:slack_error, "invalid_code"}} = result
    end
  end

  describe "revoke_token/1" do
    test "returns error for invalid token" do
      result = Slack.revoke_token("invalid_token")

      assert match?({:error, _}, result)
    end

    test "successfully revokes token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        revoke_url: "http://localhost:#{bypass.port}/api/auth.revoke"
      )

      Bypass.expect_once(bypass, "POST", "/api/auth.revoke", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert :ok = Slack.revoke_token("test_token")
    end

    test "returns error on revoke failure" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        revoke_url: "http://localhost:#{bypass.port}/api/auth.revoke"
      )

      Bypass.expect_once(bypass, "POST", "/api/auth.revoke", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => false, "error" => "token_revoked"}))
      end)

      result = Slack.revoke_token("already_revoked_token")

      assert {:error, {:slack_error, "token_revoked"}} = result
    end
  end

  describe "verify_signature/3" do
    test "verifies valid signature" do
      raw_body = ~s({"type":"event_callback","event":{"type":"message"}})
      # Use current timestamp (must be within 5 minutes)
      timestamp = "#{System.system_time(:second)}"
      signing_secret = "test_signing_secret"

      # Create the basestring and signature
      basestring = "v0:#{timestamp}:#{raw_body}"

      signature =
        :crypto.mac(:hmac, :sha256, signing_secret, basestring)
        |> Base.encode16(case: :lower)

      signature_header = "v0=#{signature}"

      assert :ok = Slack.verify_signature(raw_body, timestamp, signature_header)
    end

    test "rejects invalid signature" do
      raw_body = ~s({"type":"event_callback"})
      # Use current timestamp (must be within 5 minutes)
      timestamp = "#{System.system_time(:second)}"
      invalid_signature = "v0=invalid_signature"

      assert {:error, :invalid_signature} =
               Slack.verify_signature(raw_body, timestamp, invalid_signature)
    end

    test "allows unsigned when configured" do
      Application.put_env(:maraithon, :slack,
        signing_secret: "",
        allow_unsigned: true
      )

      raw_body = ~s({"type":"event_callback"})
      timestamp = "1234567890"

      assert :ok = Slack.verify_signature(raw_body, timestamp, "any_signature")

      # Restore config
      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/slack/callback",
        signing_secret: "test_signing_secret"
      )
    end

    test "returns error when secret not configured and unsigned not allowed" do
      Application.put_env(:maraithon, :slack,
        signing_secret: "",
        allow_unsigned: false
      )

      raw_body = ~s({"type":"event_callback"})
      timestamp = "1234567890"

      assert {:error, :signing_secret_not_configured} =
               Slack.verify_signature(raw_body, timestamp, "sig")

      # Restore config
      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/slack/callback",
        signing_secret: "test_signing_secret"
      )
    end
  end

  describe "api_request/4" do
    test "returns error for invalid endpoint" do
      # Slack API uses hardcoded base URL, so we test error handling
      result = Slack.api_request(:get, "conversations.list", "invalid_token")

      # Will fail to authenticate with invalid token
      assert match?({:error, _}, result)
    end

    test "handles POST request method" do
      result = Slack.api_request(:post, "chat.postMessage", "invalid_token", %{channel: "C123"})

      assert match?({:error, _}, result)
    end

    test "makes successful GET request" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        api_base_url: "http://localhost:#{bypass.port}/api"
      )

      Bypass.expect_once(bypass, "GET", "/api/conversations.list", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "channels" => [%{"id" => "C123", "name" => "general"}]
          })
        )
      end)

      {:ok, response} = Slack.api_request(:get, "conversations.list", "test_token")

      assert response["channels"] == [%{"id" => "C123", "name" => "general"}]
    end

    test "makes successful POST request" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        api_base_url: "http://localhost:#{bypass.port}/api"
      )

      Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["channel"] == "C123"
        assert params["text"] == "Hello"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "ts" => "1234567890.123456"
          })
        )
      end)

      {:ok, response} =
        Slack.api_request(:post, "chat.postMessage", "test_token", %{
          channel: "C123",
          text: "Hello"
        })

      assert response["ts"] == "1234567890.123456"
    end

    test "returns error on Slack API error response" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :slack,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        api_base_url: "http://localhost:#{bypass.port}/api"
      )

      Bypass.expect_once(bypass, "GET", "/api/conversations.list", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => false,
            "error" => "invalid_auth"
          })
        )
      end)

      result = Slack.api_request(:get, "conversations.list", "bad_token")

      assert {:error, {:slack_error, "invalid_auth"}} = result
    end
  end
end
