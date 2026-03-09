defmodule Maraithon.OAuth.LinearTest do
  use ExUnit.Case, async: false

  alias Maraithon.OAuth.Linear

  setup do
    Application.put_env(:maraithon, :linear,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/linear/callback",
      webhook_secret: "test_webhook_secret"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :linear, [])
    end)

    :ok
  end

  describe "default_scopes/0" do
    test "returns default scopes" do
      scopes = Linear.default_scopes()

      assert "read" in scopes
      assert "write" in scopes
      assert "issues:create" in scopes
      assert "comments:create" in scopes
    end
  end

  describe "authorize_url/2" do
    test "generates valid authorization URL with default scopes" do
      state = "test_state_123"

      url = Linear.authorize_url(state)

      assert url =~ "https://linear.app/oauth/authorize?"
      assert url =~ "client_id=test_client_id"
      assert url =~ "redirect_uri="
      assert url =~ "response_type=code"
      assert url =~ "state=test_state_123"
      assert url =~ "prompt=consent"
      assert url =~ "scope="
    end

    test "generates URL with custom scopes" do
      scopes = ["read", "issues:create"]
      state = "custom_state"

      url = Linear.authorize_url(scopes, state)

      assert url =~ "scope=read%2Cissues%3Acreate"
      assert url =~ "state=custom_state"
    end
  end

  describe "exchange_code/1" do
    test "returns error for invalid code" do
      result = Linear.exchange_code("invalid_code")

      assert match?({:error, _}, result)
    end

    test "successfully exchanges code for tokens" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/linear/callback",
        token_url: "http://localhost:#{bypass.port}/oauth/token"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["code"] == "valid_auth_code"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"
        assert params["grant_type"] == "authorization_code"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "lin_api_test_token",
            "token_type" => "Bearer",
            "expires_in" => 315_360_000,
            "scope" => "read,write"
          })
        )
      end)

      {:ok, tokens} = Linear.exchange_code("valid_auth_code")

      assert tokens.access_token == "lin_api_test_token"
      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == 315_360_000
    end
  end

  describe "revoke_token/1" do
    test "returns error for invalid token" do
      result = Linear.revoke_token("invalid_token")

      assert match?({:error, _}, result)
    end

    test "successfully revokes token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        revoke_url: "http://localhost:#{bypass.port}/oauth/revoke"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/revoke", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"success" => true}))
      end)

      assert :ok = Linear.revoke_token("test_token")
    end
  end

  describe "verify_signature/2" do
    test "verifies valid signature" do
      # Create a valid signature
      raw_body = ~s({"action":"create","type":"Issue"})

      signature =
        :crypto.mac(:hmac, :sha256, "test_webhook_secret", raw_body)
        |> Base.encode16(case: :lower)

      assert :ok = Linear.verify_signature(raw_body, signature)
    end

    test "rejects invalid signature" do
      raw_body = ~s({"action":"create"})
      invalid_signature = "invalid_signature"

      assert {:error, :invalid_signature} = Linear.verify_signature(raw_body, invalid_signature)
    end

    test "allows unsigned when configured" do
      Application.put_env(:maraithon, :linear,
        webhook_secret: "",
        allow_unsigned: true
      )

      raw_body = ~s({"action":"create"})

      assert :ok = Linear.verify_signature(raw_body, "any_signature")

      # Restore config
      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/linear/callback",
        webhook_secret: "test_webhook_secret"
      )
    end

    test "returns error when secret not configured and unsigned not allowed" do
      Application.put_env(:maraithon, :linear,
        webhook_secret: "",
        allow_unsigned: false
      )

      raw_body = ~s({"action":"create"})

      assert {:error, :webhook_secret_not_configured} = Linear.verify_signature(raw_body, "sig")

      # Restore config
      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/linear/callback",
        webhook_secret: "test_webhook_secret"
      )
    end
  end

  describe "graphql/3" do
    test "returns error for invalid token" do
      # Linear API uses hardcoded URL, so we test error handling
      result = Linear.graphql("invalid_token", "query { viewer { id } }")

      assert match?({:error, _}, result)
    end

    test "makes successful GraphQL request" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test_token"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["query"] == "query { viewer { id name } }"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "viewer" => %{
                "id" => "user_123",
                "name" => "Test User"
              }
            }
          })
        )
      end)

      {:ok, data} = Linear.graphql("test_token", "query { viewer { id name } }")

      assert data["viewer"]["id"] == "user_123"
      assert data["viewer"]["name"] == "Test User"
    end

    test "makes GraphQL request with variables" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["variables"]["issueId"] == "issue_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "issue" => %{"id" => "issue_123", "title" => "Test Issue"}
            }
          })
        )
      end)

      {:ok, data} =
        Linear.graphql(
          "test_token",
          "query($issueId: String!) { issue(id: $issueId) { id title } }",
          %{issueId: "issue_123"}
        )

      assert data["issue"]["title"] == "Test Issue"
    end

    test "returns error on GraphQL errors" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "errors" => [%{"message" => "Field 'unknown' not found"}]
          })
        )
      end)

      result = Linear.graphql("test_token", "query { unknown }")

      assert {:error, {:graphql_errors, errors}} = result
      assert [%{"message" => "Field 'unknown' not found"}] = errors
    end
  end
end
