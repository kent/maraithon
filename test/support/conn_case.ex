defmodule MaraithonWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MaraithonWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MaraithonWeb.Endpoint

      use MaraithonWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import MaraithonWeb.ConnCase
    end
  end

  setup tags do
    Maraithon.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def log_in_test_user(conn, email \\ "user@example.com") do
    {:ok, user} = Maraithon.Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: token}} = Maraithon.Accounts.create_session_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("user_session_token", token)
  end

  def log_in_admin_user(conn, email \\ "admin@example.com") do
    {:ok, user} = Maraithon.Accounts.get_or_create_user_by_email(email)
    {:ok, user} = Maraithon.Repo.update(Ecto.Changeset.change(user, is_admin: true))
    {:ok, %{token: token}} = Maraithon.Accounts.create_session_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("user_session_token", token)
  end
end
