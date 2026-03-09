defmodule Maraithon.OAuth.GoogleTest do
  use ExUnit.Case, async: false

  alias Maraithon.OAuth.Google

  setup do
    # Configure Google OAuth settings for testing
    Application.put_env(:maraithon, :google,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/google/callback"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
    end)

    :ok
  end

  describe "scopes_for/1" do
    test "returns calendar scope" do
      scopes = Google.scopes_for(["calendar"])

      assert scopes == ["https://www.googleapis.com/auth/calendar.readonly"]
    end

    test "returns gmail scope" do
      scopes = Google.scopes_for(["gmail"])

      assert scopes == ["https://www.googleapis.com/auth/gmail.readonly"]
    end

    test "returns multiple scopes" do
      scopes = Google.scopes_for(["calendar", "gmail"])

      assert "https://www.googleapis.com/auth/calendar.readonly" in scopes
      assert "https://www.googleapis.com/auth/gmail.readonly" in scopes
      assert length(scopes) == 2
    end

    test "ignores unknown services" do
      scopes = Google.scopes_for(["calendar", "unknown", "gmail"])

      assert length(scopes) == 2
    end

    test "returns empty list for unknown services" do
      scopes = Google.scopes_for(["unknown", "other"])

      assert scopes == []
    end

    test "returns empty list for empty input" do
      scopes = Google.scopes_for([])

      assert scopes == []
    end

    test "deduplicates scopes" do
      scopes = Google.scopes_for(["calendar", "calendar"])

      assert scopes == ["https://www.googleapis.com/auth/calendar.readonly"]
    end
  end

  describe "authorize_url/2" do
    test "generates valid authorization URL" do
      scopes = ["https://www.googleapis.com/auth/calendar.readonly"]
      state = "test_state_123"

      url = Google.authorize_url(scopes, state)

      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=test_client_id"
      assert url =~ "redirect_uri="
      assert url =~ "response_type=code"
      assert url =~ "state=test_state_123"
      assert url =~ "access_type=offline"
      assert url =~ "prompt=consent"
    end

    test "encodes multiple scopes" do
      scopes = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/gmail.readonly"
      ]

      url = Google.authorize_url(scopes, "state")

      # Scopes should be space-separated and URL encoded
      assert url =~ "scope="
    end
  end

  describe "exchange_code/1" do
    test "returns error for invalid code" do
      # This will fail to connect to Google's token endpoint
      result = Google.exchange_code("invalid_code")

      # Will fail because the code is invalid
      assert match?({:error, _}, result)
    end

    test "successfully exchanges code for tokens" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/google/callback",
        token_url: "http://localhost:#{bypass.port}/token"
      )

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["code"] == "valid_auth_code"
        assert params["grant_type"] == "authorization_code"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "ya29.test_access_token",
            "refresh_token" => "1//test_refresh_token",
            "expires_in" => 3600,
            "scope" => "https://www.googleapis.com/auth/calendar.readonly",
            "token_type" => "Bearer"
          })
        )
      end)

      {:ok, tokens} = Google.exchange_code("valid_auth_code")

      assert tokens.access_token == "ya29.test_access_token"
      assert tokens.refresh_token == "1//test_refresh_token"
      assert tokens.expires_in == 3600
      assert tokens.token_type == "Bearer"
    end
  end

  describe "refresh_token/1" do
    test "returns error for invalid refresh token" do
      result = Google.refresh_token("invalid_refresh_token")

      # Will fail to connect to Google
      assert match?({:error, _}, result)
    end

    test "successfully refreshes access token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/google/callback",
        token_url: "http://localhost:#{bypass.port}/token"
      )

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["refresh_token"] == "valid_refresh_token"
        assert params["grant_type"] == "refresh_token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "ya29.new_access_token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      {:ok, tokens} = Google.refresh_token("valid_refresh_token")

      assert tokens.access_token == "ya29.new_access_token"
      assert tokens.expires_in == 3600
    end

    test "returns error on token refresh failure" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        token_url: "http://localhost:#{bypass.port}/token"
      )

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Token has been revoked"
          })
        )
      end)

      result = Google.refresh_token("revoked_refresh_token")

      assert match?({:error, {:token_refresh_failed, _}}, result)
    end
  end

  describe "revoke_token/1" do
    test "returns error for invalid token" do
      result = Google.revoke_token("invalid_token")

      # Will fail to connect to Google
      assert match?({:error, _}, result)
    end

    test "successfully revokes token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        revoke_url: "http://localhost:#{bypass.port}/revoke"
      )

      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        # Query params should contain the token
        assert conn.query_string =~ "token=test_access_token"

        conn
        |> Plug.Conn.resp(200, "")
      end)

      result = Google.revoke_token("test_access_token")

      assert result == :ok
    end
  end

  describe "api_request/5" do
    test "makes GET request with authorization header" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/calendar/v3/users/me/calendarList", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test_access_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"items": []}))
      end)

      {:ok, response} =
        Google.api_request(
          :get,
          "http://localhost:#{bypass.port}/calendar/v3/users/me/calendarList",
          "test_access_token"
        )

      assert response["items"] == []
    end

    test "makes POST request with body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api/resource", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"name" => "test"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"created": true}))
      end)

      {:ok, response} =
        Google.api_request(
          :post,
          "http://localhost:#{bypass.port}/api/resource",
          "test_token",
          %{name: "test"}
        )

      assert response["created"] == true
    end

    test "makes PUT request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "PUT", "/api/resource/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"updated": true}))
      end)

      {:ok, response} =
        Google.api_request(
          :put,
          "http://localhost:#{bypass.port}/api/resource/1",
          "test_token",
          %{name: "updated"}
        )

      assert response["updated"] == true
    end

    test "makes PATCH request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "PATCH", "/api/resource/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"patched": true}))
      end)

      {:ok, response} =
        Google.api_request(
          :patch,
          "http://localhost:#{bypass.port}/api/resource/1",
          "test_token",
          %{status: "active"}
        )

      assert response["patched"] == true
    end

    test "makes DELETE request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "/api/resource/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"deleted": true}))
      end)

      {:ok, response} =
        Google.api_request(
          :delete,
          "http://localhost:#{bypass.port}/api/resource/1",
          "test_token"
        )

      assert response["deleted"] == true
    end

    test "includes extra headers" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        custom = Plug.Conn.get_req_header(conn, "x-custom-header")
        assert custom == ["custom_value"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({}))
      end)

      {:ok, _} =
        Google.api_request(
          :get,
          "http://localhost:#{bypass.port}/api",
          "test_token",
          nil,
          [{"X-Custom-Header", "custom_value"}]
        )
    end
  end
end
