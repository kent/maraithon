defmodule MaraithonWeb.NavigationControllerTest do
  use MaraithonWeb.ConnCase, async: true

  describe "tab pages" do
    test "GET /connectors renders the connectors page", %{conn: conn} do
      conn = get(conn, "/connectors")
      html = html_response(conn, 200)

      assert html =~ "Connectors"
      assert html =~ "Connected Accounts"
      assert html =~ "Connector"
      assert html =~ "Actions"
      assert html =~ "OAuth Configuration"
    end

    test "GET /how-it-works renders the guide page", %{conn: conn} do
      conn = get(conn, "/how-it-works")
      html = html_response(conn, 200)

      assert html =~ "How it works"
      assert html =~ "Execution Flow"
      assert html =~ "Engineering Principles"
    end

    test "GET /settings renders settings page", %{conn: conn} do
      conn = get(conn, "/settings")
      html = html_response(conn, 200)

      assert html =~ "Settings"
      assert html =~ "Security Secrets"
      assert html =~ "OAuth Provider Readiness"
    end

    test "GET /conenctors redirects to /connectors", %{conn: conn} do
      conn = get(conn, "/conenctors")
      assert redirected_to(conn) == "/connectors"
    end
  end

  describe "connector actions" do
    test "POST /connectors/:provider/disconnect handles unsupported providers", %{conn: conn} do
      conn = post(conn, "/connectors/invalid/disconnect", %{"user_id" => "kent"})

      assert redirected_to(conn) == "/connectors?user_id=kent"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unsupported provider"
    end
  end
end
