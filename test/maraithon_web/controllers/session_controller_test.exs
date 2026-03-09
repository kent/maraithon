defmodule MaraithonWeb.SessionControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Accounts.{MagicLink, UserSession}
  alias Maraithon.Repo

  test "GET / renders magic-link sign-in page", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "Send magic link"
  end

  test "POST /auth/magic-link issues a magic link", %{conn: conn} do
    conn = post(conn, "/auth/magic-link", %{"magic_link" => %{"email" => "user@example.com"}})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Check your email"

    assert Repo.aggregate(MagicLink, :count) == 1
  end

  test "GET /auth/magic/:token signs in and creates session", %{conn: conn} do
    {:ok, %{token: token}} = Accounts.request_magic_link("user@example.com")

    conn = get(conn, "/auth/magic/#{token}")

    assert redirected_to(conn) == "/connectors"
    assert get_session(conn, "user_session_token")
    assert Repo.aggregate(UserSession, :count) == 1
  end

  test "DELETE /logout revokes active session", %{conn: conn} do
    conn = log_in_test_user(conn, "user@example.com")
    token = get_session(conn, "user_session_token")

    conn = delete(conn, "/logout")

    assert redirected_to(conn) == "/"

    session = Accounts.get_active_session(token)
    assert is_nil(session)
  end

  test "protected pages redirect when unauthenticated", %{conn: conn} do
    conn = get(conn, "/connectors")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in"
  end
end
