defmodule MaraithonWeb.Plugs.RequireAdmin do
  @moduledoc """
  Protects browser admin surfaces with HTTP Basic authentication when enabled.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:maraithon, :admin_auth, [])
    username = Keyword.get(config, :username, "")
    password = Keyword.get(config, :password, "")

    if username == "" or password == "" do
      conn
    else
      Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    end
  end
end
