defmodule MaraithonWeb.NavigationControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth

  describe "tab pages" do
    test "GET /connectors renders the connectors page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Connectors"
      assert html =~ "Apps"
      assert html =~ "Google Workspace"
      assert html =~ "Slack"
      assert html =~ "View"
    end

    test "GET /connectors renders with connected Slack tokens", %{conn: conn} do
      user_id = "slack-connectors@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _bot} =
        OAuth.store_tokens(user_id, "slack:T12345", %{
          access_token: "xoxb-test-token",
          scopes: ["channels:read", "im:read"],
          metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
        })

      {:ok, _user_token} =
        OAuth.store_tokens(user_id, "slack:T12345:user:U99999", %{
          access_token: "xoxp-test-token",
          scopes: ["search:read", "im:read"],
          metadata: %{
            "team_id" => "T12345",
            "team_name" => "Agora",
            "slack_user_id" => "U99999"
          }
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Slack"
      assert html =~ "Agora"
      assert html =~ "Workspaces: Agora"
    end

    test "GET /connectors renders Google account rows for each connected email", %{conn: conn} do
      user_id = "google-multi@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _first} =
        OAuth.store_tokens(user_id, "google:founder@example.com", %{
          access_token: "google-token-1",
          scopes: [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/calendar.readonly"
          ],
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _second} =
        OAuth.store_tokens(user_id, "google:ops@example.com", %{
          access_token: "google-token-2",
          scopes: ["https://www.googleapis.com/auth/contacts.readonly"],
          metadata: %{"account_email" => "ops@example.com"}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "founder@example.com"
      assert html =~ "ops@example.com"
      assert html =~ "Disconnect"
    end

    test "GET /connectors shows refresh-required state for errored Google account", %{conn: conn} do
      user_id = "google-refresh-needed@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google:founder@example.com", %{
          access_token: "google-token-1",
          refresh_token: "refresh-token-1",
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _account} =
        ConnectedAccounts.mark_error(
          user_id,
          "google:founder@example.com",
          "oauth_reauth_required"
        )

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "refresh required"
      assert html =~ "Token refresh failed and the account must be re-authenticated."
      assert html =~ "Reconnect"
    end

    test "GET /connectors/:provider renders provider details", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/github")
      html = html_response(conn, 200)

      assert html =~ "Connector Detail"
      assert html =~ "GitHub"
      assert html =~ "OAuth Setup"
    end

    test "GET /connectors/slack renders slack setup details", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/slack")
      html = html_response(conn, 200)

      assert html =~ "Slack"
      assert html =~ "OAuth Setup"
      assert html =~ "SLACK_SIGNING_SECRET"
      assert html =~ "/webhooks/slack"
    end

    test "GET /connectors/telegram shows connected chat details without linked copy", %{
      conn: conn
    } do
      user_id = "telegram-user@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _account} =
        ConnectedAccounts.upsert_manual(user_id, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"username" => "kentfenwick"}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/telegram")
      html = html_response(conn, 200)

      assert html =~ "Chat ID 6114124042"
      assert html =~ "@kentfenwick"
      refute html =~ "Linked chat"
    end

    test "GET /how-it-works renders the guide page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/how-it-works")
      html = html_response(conn, 200)

      assert html =~ "How it works"
      assert html =~ "Execution Flow"
      assert html =~ "Engineering Principles"
    end

    test "GET /settings renders settings page", %{conn: conn} do
      conn = conn |> log_in_admin_user() |> get("/settings")
      html = html_response(conn, 200)

      assert html =~ "Settings"
      assert html =~ "Security Secrets"
      assert html =~ "OAuth Provider Readiness"
    end

    test "GET /conenctors redirects to /connectors", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/conenctors")
      assert redirected_to(conn) == "/connectors"
    end
  end

  describe "connector actions" do
    test "POST /connectors/:provider/disconnect handles unsupported providers", %{conn: conn} do
      conn = conn |> log_in_test_user() |> post("/connectors/invalid/disconnect", %{})

      assert redirected_to(conn) == "/connectors"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unsupported provider"
    end

    test "GET /connectors/:provider redirects unknown provider", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/unknown")

      assert redirected_to(conn) == "/connectors"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unknown connector: unknown"
    end

    test "POST /connectors/google/disconnect can remove a specific Google account", %{conn: conn} do
      user_id = "google-disconnect@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _first} =
        OAuth.store_tokens(user_id, "google:founder@example.com", %{
          access_token: "google-token-1",
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _second} =
        OAuth.store_tokens(user_id, "google:ops@example.com", %{
          access_token: "google-token-2",
          metadata: %{"account_email" => "ops@example.com"}
        })

      conn =
        conn
        |> log_in_test_user(user_id)
        |> post("/connectors/google/disconnect", %{
          "provider_key" => "google:ops@example.com",
          "account_label" => "ops@example.com"
        })

      assert redirected_to(conn) == "/connectors"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Google account ops@example.com disconnected"

      assert OAuth.get_token(user_id, "google:ops@example.com") == nil
      assert OAuth.get_token(user_id, "google:founder@example.com")
    end
  end
end
