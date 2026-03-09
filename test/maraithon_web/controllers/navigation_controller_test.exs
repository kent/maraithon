defmodule MaraithonWeb.NavigationControllerTest do
  use MaraithonWeb.ConnCase, async: true

  describe "tab pages" do
    test "GET /connectors renders the connectors page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Connectors"
      assert html =~ "Apps"
      assert html =~ "Google Workspace"
      assert html =~ "View"
    end

    test "GET /connectors/:provider renders provider details", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/github")
      html = html_response(conn, 200)

      assert html =~ "Connector Detail"
      assert html =~ "GitHub"
      assert html =~ "OAuth Setup"
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
  end
end
