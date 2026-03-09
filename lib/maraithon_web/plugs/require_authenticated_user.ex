defmodule MaraithonWeb.Plugs.RequireAuthenticatedUser do
  @moduledoc """
  Redirects unauthenticated browser requests to the sign-in page.
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Sign in to continue.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
