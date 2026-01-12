defmodule MaraithonWeb.HealthController do
  use MaraithonWeb, :controller

  alias Maraithon.Health

  @doc """
  Simple health check for load balancers.
  """
  def index(conn, _params) do
    json(conn, %{status: "ok", service: "maraithon"})
  end

  @doc """
  Detailed health check with system info.
  """
  def detailed(conn, _params) do
    health = Health.check()

    status_code = if health.status == :healthy, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(health)
  end
end
