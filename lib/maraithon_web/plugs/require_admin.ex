defmodule MaraithonWeb.Plugs.RequireAdmin do
  @moduledoc """
  Protects browser admin surfaces.

  Allows DB-backed admin users and preserves HTTP Basic auth fallback when
  configured for legacy access.
  """

  import Plug.Conn

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if db_admin?(conn.assigns[:current_user]) do
      conn
    else
      basic_auth_fallback(conn)
    end
  end

  defp db_admin?(%{is_admin: true}), do: true
  defp db_admin?(_), do: false

  defp basic_auth_fallback(conn) do
    {username, password} = admin_credentials()

    cond do
      username != "" and password != "" ->
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      conn.assigns[:current_user] ->
        conn
        |> put_flash(:error, "Admin access required.")
        |> redirect(to: "/dashboard")
        |> halt()

      true ->
        conn
        |> put_flash(:error, "Admin access required.")
        |> redirect(to: "/")
        |> halt()
    end
  end

  defp admin_credentials do
    config = Application.get_env(:maraithon, :admin_auth, [])
    {Keyword.get(config, :username, ""), Keyword.get(config, :password, "")}
  end
end
