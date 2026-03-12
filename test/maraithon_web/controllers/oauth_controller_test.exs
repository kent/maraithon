# ==============================================================================
# OAuth Controller Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# OAuth is how users connect their external accounts (Google, Slack, Linear)
# to Maraithon. This enables agents to:
#
# - **Access User Data**: Read calendars, emails, Slack messages on behalf of users
# - **Take Actions**: Post messages, create issues, update calendars
# - **Maintain Access**: Automatically refresh tokens when they expire
#
# From a user's perspective, OAuth is the "Connect your Google Account" button
# that securely grants Maraithon access without sharing passwords.
#
# Example User Journey:
# 1. User wants an agent to manage their calendar
# 2. User clicks "Connect Google" in the Maraithon UI
# 3. Browser redirects to Google's OAuth consent screen
# 4. User approves access to their calendar
# 5. Google redirects back to Maraithon with an authorization code
# 6. Maraithon exchanges the code for access/refresh tokens
# 7. Tokens are stored securely for future API calls
# 8. Agent can now read/write the user's calendar
#
# WHY THESE TESTS MATTER:
# -----------------------
# If OAuth flows break, users experience:
# - Inability to connect their accounts
# - "Invalid state" errors after approving access
# - Token exchange failures that lose the user's approval
# - Agents that suddenly can't access user data
# - Security issues if state validation is bypassed
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the OAuthController, which implements the OAuth 2.0
# Authorization Code flow for multiple providers.
#
# OAuth 2.0 Authorization Code Flow:
# -----------------------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                      OAuth Authorization Code Flow                       │
#   │                                                                          │
#   │   User        Maraithon           OAuth Provider        Token Store     │
#   │    │              │                    │                    │            │
#   │    │  1. Connect  │                    │                    │            │
#   │    │─────────────►│                    │                    │            │
#   │    │              │                    │                    │            │
#   │    │  2. Redirect │  3. Auth URL       │                    │            │
#   │    │◄─────────────│───────────────────►│                    │            │
#   │    │              │                    │                    │            │
#   │    │         4. User approves          │                    │            │
#   │    │              │◄───────────────────│                    │            │
#   │    │              │   5. Code + State  │                    │            │
#   │    │              │                    │                    │            │
#   │    │              │  6. Exchange code  │                    │            │
#   │    │              │───────────────────►│                    │            │
#   │    │              │  7. Access token   │                    │            │
#   │    │              │◄───────────────────│                    │            │
#   │    │              │                    │                    │            │
#   │    │              │         8. Store tokens                 │            │
#   │    │              │─────────────────────────────────────────►            │
#   │    │  9. Success  │                    │                    │            │
#   │    │◄─────────────│                    │                    │            │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Supported OAuth Providers:
# --------------------------
# - **Google**: Calendar and Gmail access (calendar, gmail scopes)
# - **Slack**: Workspace access (bot tokens)
# - **Linear**: Issue tracking access (read, write scopes)
#
# Security Measures:
# ------------------
# - **State Parameter**: CSRF protection - random value in auth URL, validated on callback
# - **HTTPS Only**: OAuth requires secure connections (handled by deployment)
# - **Encrypted Storage**: Tokens stored encrypted at rest
# - **Scope Validation**: Users explicitly approve requested permissions
#
# Test Categories:
# ----------------
# - Input Validation: Required parameters (user_id, scopes, code, state)
# - OAuth Initiation: Redirect URL construction with proper scopes
# - Callback Handling: Code exchange, state validation, error handling
# - Token Storage: Successful token storage after exchange
# - Error Handling: OAuth errors from provider, exchange failures
#
# Dependencies:
# -------------
# - MaraithonWeb.OAuthController (the controller being tested)
# - Maraithon.OAuth.Google/Slack/Linear (provider-specific helpers)
# - Maraithon.OAuth (token storage context)
# - Bypass (for mocking external OAuth APIs)
#
# Setup Requirements:
# -------------------
# This test uses `async: false` because:
# 1. Application config is modified during tests (OAuth credentials)
# 2. Bypass servers need isolated ports
# 3. Config changes must be restored after each test
#
# ==============================================================================

defmodule MaraithonWeb.OAuthControllerTest do
  use MaraithonWeb.ConnCase, async: false

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # Configures OAuth credentials for all providers. In production, these come
  # from environment variables. For testing, we use test values.
  #
  # The on_exit callback ensures config is reset after each test to prevent
  # pollution between tests.
  # ----------------------------------------------------------------------------
  setup %{conn: conn} do
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

    Application.put_env(:maraithon, :github,
      client_id: "test_github_client_id",
      client_secret: "test_github_client_secret",
      redirect_uri: "http://localhost:4000/auth/github/callback",
      api_base_url: "https://api.github.com"
    )

    Application.put_env(:maraithon, :notion,
      client_id: "test_notion_client_id",
      client_secret: "test_notion_client_secret",
      redirect_uri: "http://localhost:4000/auth/notion/callback",
      api_base_url: "https://api.notion.com/v1",
      api_version: "2025-09-03"
    )

    Application.put_env(:maraithon, :notaui,
      client_id: "test_notaui_client_id",
      client_secret: "test_notaui_client_secret",
      redirect_uri: "http://localhost:4000/auth/notaui/callback",
      issuer: "https://api.notaui.com",
      mcp_url: "https://api.notaui.com/mcp"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
      Application.put_env(:maraithon, :slack, [])
      Application.put_env(:maraithon, :linear, [])
      Application.put_env(:maraithon, :github, [])
      Application.put_env(:maraithon, :notion, [])
      Application.put_env(:maraithon, :notaui, [])
    end)

    {:ok, conn: log_in_test_user(conn, "oauth@example.com")}
  end

  # ============================================================================
  # GOOGLE OAUTH TESTS - INITIATION
  # ============================================================================
  #
  # These tests verify the OAuth flow initiation for Google.
  # GET /auth/google starts the flow by redirecting to Google's OAuth consent.
  #
  # Required parameters:
  # - user_id: Identifies which user is connecting (stored in state)
  # - scopes: Which Google services to request access for (calendar, gmail)
  # ============================================================================

  describe "GET /auth/google" do
    @doc """
    Verifies that user_id is required for OAuth initiation.
    Without user_id, we don't know who to associate the tokens with.
    """
    test "returns error when user_id is missing", %{conn: conn} do
      conn = get(conn, "/auth/google", %{scopes: "calendar"})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    @doc """
    Verifies that empty user_id is rejected.
    An empty string is not a valid user identifier.
    """
    test "returns error when user_id is empty", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "", scopes: "calendar"})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    @doc """
    Verifies that scopes parameter is required.
    Without scopes, we don't know what permissions to request.
    """
    test "returns error when scopes is missing", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123"})

      response = json_response(conn, 400)
      assert response["error"] =~ "scopes is required"
    end

    @doc """
    Verifies that empty scopes is rejected.
    At least one scope must be specified.
    """
    test "returns error when scopes is empty", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: ""})

      response = json_response(conn, 400)
      assert response["error"] =~ "scopes is required"
    end

    @doc """
    Verifies successful redirect to Google OAuth consent.
    The redirect URL should include:
    - client_id: Our application ID
    - state: Encoded user_id for callback validation
    """
    test "redirects to Google with valid params", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "calendar"})

      assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth"
      assert redirected_to(conn) =~ "client_id=test_google_client_id"
      assert redirected_to(conn) =~ "state="
    end

    @doc """
    Verifies that multiple scopes are handled correctly.
    Users can request access to both calendar and gmail at once.
    """
    test "redirects with multiple scopes", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "calendar,gmail"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com/o/oauth2/v2/auth"
    end
  end

  # ============================================================================
  # GOOGLE OAUTH TESTS - CALLBACK
  # ============================================================================
  #
  # These tests verify the OAuth callback handling for Google.
  # GET /auth/google/callback receives the authorization code from Google
  # and exchanges it for access/refresh tokens.
  #
  # Required parameters:
  # - code: Authorization code from Google
  # - state: Encoded user_id (must match what we sent)
  # ============================================================================

  describe "GET /auth/google/callback" do
    @doc """
    Verifies that invalid state parameter is rejected.
    State validation prevents CSRF attacks where an attacker tricks a user
    into connecting their own OAuth tokens to the attacker's account.
    """
    test "returns error for invalid state", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{code: "auth_code", state: "invalid"})

      assert json_response(conn, 400) == %{"error" => "Invalid state parameter"}
    end

    @doc """
    Verifies that missing code parameter is rejected.
    The code is required to exchange for tokens.
    """
    test "returns error when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{state: "some_state"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    @doc """
    Verifies that missing state parameter is rejected.
    State is required for security validation.
    """
    test "returns error when state is missing", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{code: "auth_code"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    @doc """
    Verifies that OAuth errors from Google are handled gracefully.
    When a user denies access or there's an error, Google redirects back
    with error parameters instead of a code.
    """
    test "handles OAuth error from Google", %{conn: conn} do
      conn =
        get(conn, "/auth/google/callback", %{
          error: "access_denied",
          error_description: "User denied access"
        })

      response = json_response(conn, 400)
      assert response["error"] == "OAuth authorization failed"
      assert response["details"]["error"] == "access_denied"
    end

    @doc """
    Verifies that token exchange failure is handled.
    Even with valid state, the code exchange can fail if the code is
    invalid, expired, or already used.
    """
    test "returns error for token exchange failure with valid state", %{conn: conn} do
      # Create a valid state
      state = signed_google_state("user_123", ["calendar"])

      conn = get(conn, "/auth/google/callback", %{code: "invalid_code", state: state})

      # Token exchange will fail, but state is valid
      assert json_response(conn, 400) == %{"error" => "Failed to exchange authorization code"}
    end
  end

  # ============================================================================
  # SLACK OAUTH TESTS - INITIATION
  # ============================================================================
  #
  # Slack OAuth follows the same pattern as Google but with different scopes.
  # Slack tokens grant access to workspace messages, users, and channels.
  # ============================================================================

  describe "GET /auth/slack" do
    @doc """
    Verifies that user_id is required for Slack OAuth initiation.
    """
    test "returns error when user_id is missing", %{conn: conn} do
      conn = get(conn, "/auth/slack")

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    @doc """
    Verifies that empty user_id is rejected for Slack OAuth.
    """
    test "returns error when user_id is empty", %{conn: conn} do
      conn = get(conn, "/auth/slack", %{user_id: ""})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    @doc """
    Verifies successful redirect to Slack OAuth consent.
    """
    test "redirects to Slack with valid params", %{conn: conn} do
      conn = get(conn, "/auth/slack", %{user_id: "user_123"})

      assert redirected_to(conn) =~ "https://slack.com/oauth/v2/authorize"
      assert redirected_to(conn) =~ "client_id=test_slack_client_id"
      assert redirected_to(conn) =~ "state="
    end
  end

  # ============================================================================
  # SLACK OAUTH TESTS - CALLBACK
  # ============================================================================

  describe "GET /auth/slack/callback" do
    @doc """
    Verifies that invalid state parameter is rejected for Slack.
    """
    test "returns error for invalid state", %{conn: conn} do
      conn = get(conn, "/auth/slack/callback", %{code: "auth_code", state: "invalid"})

      assert json_response(conn, 400) == %{"error" => "Invalid state parameter"}
    end

    @doc """
    Verifies that missing code parameter is rejected for Slack.
    """
    test "returns error when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/slack/callback", %{state: "some_state"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    @doc """
    Verifies that OAuth errors from Slack are handled gracefully.
    """
    test "handles OAuth error from Slack", %{conn: conn} do
      conn = get(conn, "/auth/slack/callback", %{error: "access_denied"})

      response = json_response(conn, 400)
      assert response["error"] == "OAuth authorization failed"
      assert response["details"] == "access_denied"
    end

    @doc """
    Verifies that token exchange failure is handled for Slack.
    """
    test "returns error for token exchange failure with valid state", %{conn: conn} do
      # Create a valid state
      state = signed_provider_state("slack", "user_123")

      conn = get(conn, "/auth/slack/callback", %{code: "invalid_code", state: state})

      # Token exchange will fail, but state is valid
      assert json_response(conn, 400) == %{"error" => "Failed to exchange authorization code"}
    end
  end

  # ============================================================================
  # LINEAR OAUTH TESTS - INITIATION
  # ============================================================================
  #
  # Linear OAuth grants access to issue tracking data.
  # Tokens allow reading and writing issues, projects, and teams.
  # ============================================================================

  describe "GET /auth/linear" do
    @doc """
    Verifies that user_id is required for Linear OAuth initiation.
    """
    test "returns error when user_id is missing", %{conn: conn} do
      conn = get(conn, "/auth/linear")

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    @doc """
    Verifies that empty user_id is rejected for Linear OAuth.
    """
    test "returns error when user_id is empty", %{conn: conn} do
      conn = get(conn, "/auth/linear", %{user_id: ""})

      assert json_response(conn, 400) == %{"error" => "user_id is required"}
    end

    @doc """
    Verifies successful redirect to Linear OAuth consent.
    """
    test "redirects to Linear with valid params", %{conn: conn} do
      conn = get(conn, "/auth/linear", %{user_id: "user_123"})

      assert redirected_to(conn) =~ "https://linear.app/oauth/authorize"
      assert redirected_to(conn) =~ "client_id=test_linear_client_id"
      assert redirected_to(conn) =~ "state="
    end
  end

  # ============================================================================
  # LINEAR OAUTH TESTS - CALLBACK
  # ============================================================================

  describe "GET /auth/linear/callback" do
    @doc """
    Verifies that invalid state parameter is rejected for Linear.
    """
    test "returns error for invalid state", %{conn: conn} do
      conn = get(conn, "/auth/linear/callback", %{code: "auth_code", state: "invalid"})

      assert json_response(conn, 400) == %{"error" => "Invalid state parameter"}
    end

    @doc """
    Verifies that missing code parameter is rejected for Linear.
    """
    test "returns error when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/linear/callback", %{state: "some_state"})

      assert json_response(conn, 400) == %{"error" => "Missing code or state parameter"}
    end

    @doc """
    Verifies that OAuth errors from Linear are handled gracefully.
    """
    test "handles OAuth error from Linear", %{conn: conn} do
      conn = get(conn, "/auth/linear/callback", %{error: "access_denied"})

      response = json_response(conn, 400)
      assert response["error"] == "OAuth authorization failed"
      assert response["details"] == "access_denied"
    end

    @doc """
    Verifies that token exchange failure is handled for Linear.
    """
    test "returns error for token exchange failure with valid state", %{conn: conn} do
      # Create a valid state
      state = signed_provider_state("linear", "user_123")

      conn = get(conn, "/auth/linear/callback", %{code: "invalid_code", state: state})

      # Token exchange will fail, but state is valid
      assert json_response(conn, 400) == %{"error" => "Failed to exchange authorization code"}
    end
  end

  # ============================================================================
  # GITHUB OAUTH TESTS
  # ============================================================================

  describe "GET /auth/github" do
    test "redirects to GitHub with PKCE challenge", %{conn: conn} do
      conn = get(conn, "/auth/github", %{user_id: "user_123"})

      redirect_url = redirected_to(conn)

      assert redirect_url =~ "https://github.com/login/oauth/authorize"
      assert redirect_url =~ "client_id=test_github_client_id"
      assert redirect_url =~ "code_challenge="
      assert redirect_url =~ "code_challenge_method=S256"
      assert redirect_url =~ "state="
    end
  end

  describe "GET /auth/github/callback" do
    test "redirects back to the admin UI when return_to is provided", %{conn: conn} do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :github,
        client_id: "test_github_client_id",
        client_secret: "test_github_client_secret",
        redirect_uri: "http://localhost:4000/auth/github/callback",
        token_url: "http://localhost:#{bypass.port}/login/oauth/access_token",
        api_base_url: "http://localhost:#{bypass.port}"
      )

      Bypass.expect_once(bypass, "POST", "/login/oauth/access_token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "github_access_token",
            "scope" => "repo read:org notifications user:email",
            "token_type" => "bearer"
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => 42,
            "login" => "kent",
            "name" => "Kent",
            "email" => "kent@example.com",
            "avatar_url" => "https://avatars.example.com/kent",
            "html_url" => "https://github.com/kent"
          })
        )
      end)

      state =
        signed_provider_state("github", "user_123", %{
          "return_to" => "/?user_id=user_123",
          "code_verifier" => "test-code-verifier"
        })

      conn = get(conn, "/auth/github/callback", %{code: "valid_code", state: state})

      redirect_url = redirected_to(conn)

      assert redirect_url =~ "/?oauth_message="
      assert redirect_url =~ "oauth_provider=github"
      assert redirect_url =~ "oauth_status=connected"
      assert redirect_url =~ "user_id=user_123"
    end
  end

  # ============================================================================
  # NOTION OAUTH TESTS
  # ============================================================================

  describe "GET /auth/notion" do
    test "redirects to Notion with the expected owner and client id", %{conn: conn} do
      conn = get(conn, "/auth/notion", %{user_id: "user_123"})

      redirect_url = redirected_to(conn)

      assert redirect_url =~ "https://api.notion.com/v1/oauth/authorize"
      assert redirect_url =~ "client_id=test_notion_client_id"
      assert redirect_url =~ "owner=user"
      assert redirect_url =~ "response_type=code"
      assert redirect_url =~ "state="
    end
  end

  describe "GET /auth/notaui" do
    test "redirects to Notaui with PKCE challenge", %{conn: conn} do
      conn = get(conn, "/auth/notaui", %{user_id: "user_123"})

      redirect_url = redirected_to(conn)

      assert redirect_url =~ "https://api.notaui.com/oauth/authorize"
      assert redirect_url =~ "client_id=test_notaui_client_id"
      assert redirect_url =~ "code_challenge="
      assert redirect_url =~ "code_challenge_method=S256"
      assert redirect_url =~ "state="
    end
  end

  # ============================================================================
  # GOOGLE SCOPE HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that different Google scopes are handled correctly.
  # Users can request access to calendar, gmail, or both.
  # ============================================================================

  describe "GET /auth/google with different scopes" do
    @doc """
    Verifies that gmail scope is handled correctly.
    """
    test "handles gmail scope", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "gmail"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com"
      assert redirect_url =~ "scope="
    end

    @doc """
    Verifies that multiple scopes (calendar + gmail) are handled.
    """
    test "handles both calendar and gmail scopes", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: "calendar,gmail"})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com"
    end

    @doc """
    Verifies that whitespace in scopes is handled gracefully.
    Users might accidentally include spaces in the scopes parameter.
    """
    test "handles scopes with extra whitespace", %{conn: conn} do
      conn = get(conn, "/auth/google", %{user_id: "user_123", scopes: " calendar , gmail "})

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "https://accounts.google.com"
    end
  end

  # ============================================================================
  # SUCCESSFUL TOKEN EXCHANGE TESTS WITH BYPASS
  # ============================================================================
  #
  # These tests use Bypass to mock external OAuth APIs and verify the full
  # token exchange flow works correctly, including token storage.
  # ============================================================================

  describe "GET /auth/google/callback with successful token exchange" do
    @doc """
    Verifies the complete Google OAuth flow with mocked token exchange.
    This tests:
    1. Valid state is decoded correctly
    2. Token exchange HTTP request is made
    3. Tokens are stored in database
    4. Success response is returned to user
    """
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
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "google_access_token",
            "refresh_token" => "google_refresh_token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      # Create a valid state
      state = signed_google_state("user_456", ["calendar"])

      conn = get(conn, "/auth/google/callback", %{code: "valid_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "user_456"
      assert response["services"] == ["calendar"]
    end

    test "stores Google tokens under account-specific provider when identity is available", %{
      conn: conn
    } do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        client_id: "test_google_client_id",
        client_secret: "test_google_client_secret",
        redirect_uri: "http://localhost:4000/auth/google/callback",
        token_url: "http://localhost:#{bypass.port}/token",
        userinfo_url: "http://localhost:#{bypass.port}/userinfo"
      )

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "google_access_token",
            "refresh_token" => "google_refresh_token",
            "expires_in" => 3600,
            "scope" =>
              "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email",
            "token_type" => "Bearer"
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/userinfo", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "email" => "Founder@Example.com",
            "name" => "Founder",
            "sub" => "google-sub-123"
          })
        )
      end)

      state = signed_google_state("user_999", ["calendar"])
      conn = get(conn, "/auth/google/callback", %{code: "valid_code", state: state})
      response = json_response(conn, 200)

      assert response["status"] == "connected"
      assert response["user_id"] == "user_999"

      token = Maraithon.OAuth.get_token("user_999", "google:founder@example.com")
      assert token
      assert token.access_token == "google_access_token"
      assert get_in(token.metadata, ["account_email"]) == "founder@example.com"
      assert get_in(token.metadata, ["account_name"]) == "Founder"
      assert get_in(token.metadata, ["account_sub"]) == "google-sub-123"
    end
  end

  describe "GET /auth/slack/callback with successful token exchange" do
    @doc """
    Verifies the complete Slack OAuth flow with mocked token exchange.
    Slack returns additional metadata like team_id and team_name.
    """
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
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "access_token" => "xoxb-slack-access-token",
            "refresh_token" => "xoxe-refresh-bot",
            "expires_in" => 43_200,
            "token_type" => "bot",
            "scope" => "chat:write,users:read",
            "team" => %{"id" => "T12345", "name" => "Test Team"},
            "bot_user_id" => "U12345",
            "app_id" => "A12345",
            "authed_user" => %{
              "id" => "U99999",
              "access_token" => "xoxp-user-access-token",
              "refresh_token" => "xoxe-refresh-user",
              "expires_in" => 43_200,
              "scope" => "search:read,im:history",
              "token_type" => "user"
            }
          })
        )
      end)

      # Create a valid state
      state = signed_provider_state("slack", "user_789")

      conn = get(conn, "/auth/slack/callback", %{code: "valid_slack_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "user_789"
      assert response["team_id"] == "T12345"
      assert response["team_name"] == "Test Team"
      assert response["user_scopes_connected"] == true

      bot_token = Maraithon.OAuth.get_token("user_789", "slack:T12345")
      user_token = Maraithon.OAuth.get_token("user_789", "slack:T12345:user:U99999")

      assert bot_token.access_token == "xoxb-slack-access-token"
      assert bot_token.refresh_token == "xoxe-refresh-bot"
      assert "chat:write" in (bot_token.scopes || [])
      assert user_token.access_token == "xoxp-user-access-token"
      assert user_token.refresh_token == "xoxe-refresh-user"
      assert "search:read" in (user_token.scopes || [])
    end
  end

  describe "GET /auth/linear/callback with successful token exchange" do
    @doc """
    Verifies the complete Linear OAuth flow with mocked token exchange.
    After token exchange, we also fetch the user's teams via GraphQL.
    """
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
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "linear_access_token",
            "token_type" => "Bearer",
            "expires_in" => 315_360_000,
            "scope" => "read,write"
          })
        )
      end)

      # Mock get teams GraphQL call
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "teams" => %{
                "nodes" => [
                  %{"id" => "team1", "key" => "ENG", "name" => "Engineering"}
                ]
              }
            }
          })
        )
      end)

      # Create a valid state
      state = signed_provider_state("linear", "user_abc")

      conn = get(conn, "/auth/linear/callback", %{code: "valid_linear_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "user_abc"
      assert response["teams"] == ["ENG"]
    end

    @doc """
    Verifies that token storage failures are handled gracefully.
    If we get tokens but can't store them (e.g., database error),
    we should return an appropriate error.
    """
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
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => nil,
            "token_type" => "Bearer"
          })
        )
      end)

      # Mock get teams GraphQL call
      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{"teams" => %{"nodes" => []}}
          })
        )
      end)

      # Create a valid state
      state = signed_provider_state("linear", "user_fail")

      conn = get(conn, "/auth/linear/callback", %{code: "code", state: state})

      # Token storage will fail because access_token is nil
      response = json_response(conn, 500)
      assert response["error"] == "Failed to store tokens"
    end
  end

  describe "GET /auth/notaui/callback with successful token exchange" do
    test "stores tokens, discovers accounts, and returns success", %{conn: conn} do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :notaui,
        client_id: "test_notaui_client_id",
        client_secret: "test_notaui_client_secret",
        redirect_uri: "http://localhost:4000/auth/notaui/callback",
        issuer: "https://api.notaui.com",
        token_url: "http://localhost:#{bypass.port}/oauth/token",
        mcp_url: "http://localhost:#{bypass.port}/mcp"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")

        assert auth == [
                 "Basic dGVzdF9ub3RhdWlfY2xpZW50X2lkOnRlc3Rfbm90YXVpX2NsaWVudF9zZWNyZXQ="
               ]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "authorization_code"
        assert params["code"] == "valid_notaui_code"
        assert params["code_verifier"] == "test-code-verifier"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "notaui_access_token",
            "refresh_token" => "notaui_refresh_token",
            "expires_in" => 3600,
            "scope" => "tasks:read tasks:write projects:read",
            "token_type" => "Bearer"
          })
        )
      end)

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer notaui_access_token"]
        assert Plug.Conn.get_req_header(conn, "x-notaui-account-id") == []

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        assert req["params"]["name"] == "account.list"

        payload = [
          %{"id" => "acct-default", "label" => "Personal", "is_default" => true},
          %{"id" => "acct-team", "label" => "Team Workspace"}
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => req["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]
            }
          })
        )
      end)

      state =
        signed_provider_state("notaui", "oauth@example.com", %{
          "code_verifier" => "test-code-verifier"
        })

      conn = get(conn, "/auth/notaui/callback", %{code: "valid_notaui_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["user_id"] == "oauth@example.com"
      assert "tasks:read" in response["scopes"]
      assert response["account_count"] == 2
      assert response["default_account_id"] == "acct-default"
      assert response["default_account_label"] == "Personal"
      assert response["account_discovery"] == "ok"

      token = Maraithon.OAuth.get_token("oauth@example.com", "notaui")
      assert token.access_token == "notaui_access_token"
      assert token.refresh_token == "notaui_refresh_token"
      assert "tasks:read" in (token.scopes || [])
      assert get_in(token.metadata, ["mcp_url"]) == "http://localhost:#{bypass.port}/mcp"
      assert get_in(token.metadata, ["issuer"]) == "https://api.notaui.com"
      assert get_in(token.metadata, ["default_account_id"]) == "acct-default"
      assert get_in(token.metadata, ["default_account_label"]) == "Personal"
      assert get_in(token.metadata, ["account_count"]) == 2

      connected_account = Maraithon.ConnectedAccounts.get("oauth@example.com", "notaui")
      assert connected_account.external_account_id == "acct-default"
      assert get_in(connected_account.metadata, ["accounts"]) |> length() == 2
    end

    test "returns degraded success when account discovery fails", %{conn: conn} do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :notaui,
        client_id: "test_notaui_client_id",
        client_secret: "test_notaui_client_secret",
        redirect_uri: "http://localhost:4000/auth/notaui/callback",
        issuer: "https://api.notaui.com",
        token_url: "http://localhost:#{bypass.port}/oauth/token",
        mcp_url: "http://localhost:#{bypass.port}/mcp"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "notaui_access_token",
            "refresh_token" => "notaui_refresh_token",
            "expires_in" => 3600,
            "scope" => "tasks:read tasks:write",
            "token_type" => "Bearer"
          })
        )
      end)

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)
        assert req["params"]["name"] == "account.list"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          500,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => req["id"],
            "error" => %{"message" => "boom"}
          })
        )
      end)

      state =
        signed_provider_state("notaui", "oauth@example.com", %{
          "code_verifier" => "test-code-verifier"
        })

      conn =
        get(conn, "/auth/notaui/callback", %{code: "valid_notaui_code", state: state})

      response = json_response(conn, 200)
      assert response["status"] == "connected"
      assert response["account_count"] == 0
      assert response["default_account_id"] == nil
      assert response["account_discovery"] == "error"

      token = Maraithon.OAuth.get_token("oauth@example.com", "notaui")
      assert token.access_token == "notaui_access_token"
      assert get_in(token.metadata, ["discovery_error", "reason"]) == "mcp_request_failed_500"
    end
  end

  defp signed_google_state(user_id, services) do
    signed_state(%{"provider" => "google", "user_id" => user_id, "services" => services})
  end

  defp signed_provider_state(provider, user_id, extra \\ %{}) do
    %{"provider" => provider, "user_id" => user_id}
    |> Map.merge(extra)
    |> signed_state()
  end

  defp signed_state(payload) do
    payload = Map.put(payload, "nonce", Ecto.UUID.generate())
    Phoenix.Token.sign(MaraithonWeb.Endpoint, "oauth_state", payload)
  end
end
