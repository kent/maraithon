defmodule MaraithonWeb.OAuthControllerTest do
  use MaraithonWeb.ConnCase, async: false

  setup do
    # Configure OAuth settings for testing
    Application.put_env(:maraithon, :google,
      client_id: "test_google_client_id",
      client_secret: "test_google_client_secret",
      redirect_uri: "http://localhost:4000/auth/google/callback"
    )

    Application.put_env(:maraithon, :slack,
      client_id: "test_slack_client_id",
      client_secret: "test_slack_client_secret",
      redirect_uri: "http://localhost:4000/auth/slack/callback"
    )

    Application.put_env(:maraithon, :linear,
      client_id: "test_linear_client_id",
      client_secret: "test_linear_client_secret",
      redirect_uri: "http://localhost:4000/auth/linear/callback"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
      Application.put_env(:maraithon, :slack, [])
      Application.put_env(:maraithon, :linear, [])
    end)

    :ok
  end

  # ===========================================================================
  # Google OAuth Tests
  # ===========================================================================

  describe "GET /auth/google" do
    test "returns error when user_id is missing", %{conn: conn} do
      conn = get(conn, "/auth/google", %{scopes: "calendar"})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    test "returns error when user_id is empty", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "", scopes: "calendar"})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    test "returns error when scopes is missing", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123"})

      response = json_response(conn, 400)
      assert response["error"] =~ "scopes is required"
    end

    test "returns error when scopes is empty", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: ""})

      response = json_response(conn, 400)
      assert response["error"] =~ "scopes is required"
    end

    test "redirects to Google with valid params", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "calendar"})

      assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth"
      assert redirected_to(conn) =~ "client_id=test_google_client_id"
      assert redirected_to(conn) =~ "state="
    end

    test "redirects with multiple scopes", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "calendar,gmail"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com/o/oauth2/v2/auth"
    end
  end

  describe "GET /auth/google/callback" do
    test "returns error for invalid state", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{code: "auth_code", state: "invalid"})

      assert json_response(conn, 400) == %{"error" => "Invalid state parameter"}
    end

    test "returns error when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{state: "some_state"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    test "returns error when state is missing", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{code: "auth_code"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    test "handles OAuth error from Google", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{
        error: "access_denied",
        error_description: "User denied access"
      })

      response = json_response(conn, 400)
      assert response["error"] == "OAuth authorization failed"
      assert response["details"]["error"] == "access_denied"
    end

    test "returns error for token exchange failure with valid state", %{conn: conn} do
      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_123", services: ["calendar"]}))

      conn = get(conn, "/auth/google/callback", %{code: "invalid_code", state: state})

      # Token exchange will fail, but state is valid
      assert json_response(conn, 400) == %{"error" => "Failed to exchange authorization code"}
    end
  end

  # ===========================================================================
  # Slack OAuth Tests
  # ===========================================================================

  describe "GET /auth/slack" do
    test "returns error when user_id is missing", %{conn: conn} do
      conn = get(conn, "/auth/slack")

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    test "returns error when user_id is empty", %{conn: conn} do
      conn = get(conn, "/auth/slack", %{user_id: ""})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    test "redirects to Slack with valid params", %{conn: conn} do
      conn = get(conn, "/auth/slack", %{user_id: "user_123"})

      assert redirected_to(conn) =~ "https://slack.com/oauth/v2/authorize"
      assert redirected_to(conn) =~ "client_id=test_slack_client_id"
      assert redirected_to(conn) =~ "state="
    end
  end

  describe "GET /auth/slack/callback" do
    test "returns error for invalid state", %{conn: conn} do
      conn = get(conn, "/auth/slack/callback", %{code: "auth_code", state: "invalid"})

      assert json_response(conn, 400) == %{"error" => "Invalid state parameter"}
    end

    test "returns error when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/slack/callback", %{state: "some_state"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    test "handles OAuth error from Slack", %{conn: conn} do
      conn = get(conn, "/auth/slack/callback", %{error: "access_denied"})

      response = json_response(conn, 400)
      assert response["error"] == "OAuth authorization failed"
      assert response["details"] == "access_denied"
    end

    test "returns error for token exchange failure with valid state", %{conn: conn} do
      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_123", provider: "slack"}))

      conn = get(conn, "/auth/slack/callback", %{code: "invalid_code", state: state})

      # Token exchange will fail, but state is valid
      assert json_response(conn, 400) == %{"error" => "Failed to exchange authorization code"}
    end
  end

  # ===========================================================================
  # Linear OAuth Tests
  # ===========================================================================

  describe "GET /auth/linear" do
    test "returns error when user_id is missing", %{conn: conn} do
      conn = get(conn, "/auth/linear")

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    test "returns error when user_id is empty", %{conn: conn} do
      conn = get(conn, "/auth/linear", %{user_id: ""})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    test "redirects to Linear with valid params", %{conn: conn} do
      conn = get(conn, "/auth/linear", %{user_id: "user_123"})

      assert redirected_to(conn) =~ "https://linear.app/oauth/authorize"
      assert redirected_to(conn) =~ "client_id=test_linear_client_id"
      assert redirected_to(conn) =~ "state="
    end
  end

  describe "GET /auth/linear/callback" do
    test "returns error for invalid state", %{conn: conn} do
      conn = get(conn, "/auth/linear/callback", %{code: "auth_code", state: "invalid"})

      assert json_response(conn, 400) == %{"error" => "Invalid state parameter"}
    end

    test "returns error when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/linear/callback", %{state: "some_state"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    test "handles OAuth error from Linear", %{conn: conn} do
      conn = get(conn, "/auth/linear/callback", %{error: "access_denied"})

      response = json_response(conn, 400)
      assert response["error"] == "OAuth authorization failed"
      assert response["details"] == "access_denied"
    end

    test "returns error for token exchange failure with valid state", %{conn: conn} do
      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_123", provider: "linear"}))

      conn = get(conn, "/auth/linear/callback", %{code: "invalid_code", state: state})

      # Token exchange will fail, but state is valid
      assert json_response(conn, 400) == %{"error" => "Failed to exchange authorization code"}
    end
  end

  # ===========================================================================
  # Additional OAuth Flow Tests
  # ===========================================================================

  describe "GET /auth/google with different scopes" do
    test "handles gmail scope", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "gmail"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com"
      assert redirect_url =~ "scope="
    end

    test "handles both calendar and gmail scopes", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "calendar,gmail"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com"
    end

    test "handles scopes with extra whitespace", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: " calendar , gmail "})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com"
    end
  end

  # ===========================================================================
  # Successful Token Exchange Tests with Bypass
  # ===========================================================================

  describe "GET /auth/google/callback with successful token exchange" do
    test "stores tokens and returns success", %{conn: conn} do
      bypass = Bypass.open()

      # Configure Google OAuth to use Bypass
      Application.put_env(:maraithon, :google,
        client_id: "test_google_client_id",
        client_secret: "test_google_client_secret",
        redirect_uri: "http://localhost:4000/auth/google/callback",
        token_url: "http://localhost:#{bypass.port}/token",
        calendar_webhook_url: "",
        gmail_webhook_url: ""
      )

      # Configure watch URLs to fail gracefully
      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar"
      )
      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail"
      )

      # Mock token exchange
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => "google_access_token",
          "refresh_token" => "google_refresh_token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        }))
      end)

      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_456", services: ["calendar"]}))

      conn = get(conn, "/auth/google/callback", %{code: "valid_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "user_456"
      assert response["services"] == ["calendar"]
    end
  end

  describe "GET /auth/slack/callback with successful token exchange" do
    test "stores tokens and returns success", %{conn: conn} do
      bypass = Bypass.open()

      # Configure Slack OAuth to use Bypass
      Application.put_env(:maraithon, :slack,
        client_id: "test_slack_client_id",
        client_secret: "test_slack_client_secret",
        redirect_uri: "http://localhost:4000/auth/slack/callback",
        token_url: "http://localhost:#{bypass.port}/api/oauth.v2.access"
      )

      # Mock token exchange
      Bypass.expect_once(bypass, "POST", "/api/oauth.v2.access", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "ok" => true,
          "access_token" => "xoxb-slack-access-token",
          "token_type" => "bot",
          "scope" => "chat:write,users:read",
          "team" => %{"id" => "T12345", "name" => "Test Team"},
          "bot_user_id" => "U12345",
          "app_id" => "A12345"
        }))
      end)

      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_789", provider: "slack"}))

      conn = get(conn, "/auth/slack/callback", %{code: "valid_slack_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "user_789"
      assert response["team_id"] == "T12345"
      assert response["team_name"] == "Test Team"
    end
  end

  describe "GET /auth/linear/callback with successful token exchange" do
    test "stores tokens and returns success", %{conn: conn} do
      bypass = Bypass.open()

      # Configure Linear OAuth to use Bypass
      Application.put_env(:maraithon, :linear,
        client_id: "test_linear_client_id",
        client_secret: "test_linear_client_secret",
        redirect_uri: "http://localhost:4000/auth/linear/callback",
        token_url: "http://localhost:#{bypass.port}/oauth/token",
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      # Mock token exchange
      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => "linear_access_token",
          "token_type" => "Bearer",
          "expires_in" => 315360000,
          "scope" => "read,write"
        }))
      end)

      # Mock get teams GraphQL call
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "teams" => %{
              "nodes" => [
                %{"id" => "team1", "key" => "ENG", "name" => "Engineering"}
              ]
            }
          }
        }))
      end)

      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_abc", provider: "linear"}))

      conn = get(conn, "/auth/linear/callback", %{code: "valid_linear_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "user_abc"
      assert response["teams"] == ["ENG"]
    end

    test "handles token storage failure", %{conn: conn} do
      bypass = Bypass.open()

      # Configure Linear OAuth to use Bypass
      Application.put_env(:maraithon, :linear,
        client_id: "test_linear_client_id",
        client_secret: "test_linear_client_secret",
        redirect_uri: "http://localhost:4000/auth/linear/callback",
        token_url: "http://localhost:#{bypass.port}/oauth/token",
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      # Mock token exchange with missing required fields to trigger storage failure
      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => nil,
          "token_type" => "Bearer"
        }))
      end)

      # Mock get teams GraphQL call
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{"teams" => %{"nodes" => []}}
        }))
      end)

      # Create a valid state
      state = Base.url_encode64(Jason.encode!(%{user_id: "user_fail", provider: "linear"}))

      conn = get(conn, "/auth/linear/callback", %{code: "code", state: state})

      # Token storage will fail because access_token is nil
      response = json_response(conn, 500)
      assert response["error"] == "Failed to store tokens"
    end
  end
end
