defmodule MaraithonWeb.Plugs.ProcessRoleGate do
  @moduledoc """
  Keeps the internal runtime service from becoming a second web surface.

  Cloud Run still needs an HTTP listener for startup probes and exact-runtime
  deployment handoff. Runtime-role processes therefore expose only the simple
  health probe and the bearer-authenticated runtime control endpoints.
  """

  import Plug.Conn

  alias Maraithon.Runtime.Config, as: RuntimeConfig

  def init(opts), do: opts

  def call(conn, _opts) do
    case RuntimeConfig.process_role() do
      :combined ->
        conn

      :web ->
        if runtime_control_path?(conn.request_path), do: reject(conn), else: conn

      :runtime ->
        if runtime_request?(conn.method, conn.request_path), do: conn, else: reject(conn)

      :maintenance ->
        reject(conn)
    end
  end

  defp runtime_request?(method, path)
       when method in ["GET", "HEAD"] and path in ["/health", "/health/"],
       do: true

  defp runtime_request?("GET", "/api/v1/runtime/status"), do: true
  defp runtime_request?("POST", "/api/v1/runtime/drain"), do: true
  defp runtime_request?("POST", "/api/v1/runtime/rejoin"), do: true
  defp runtime_request?(_method, _path), do: false

  defp runtime_control_path?("/api/v1/runtime"), do: true
  defp runtime_control_path?("/api/v1/runtime/" <> _rest), do: true
  defp runtime_control_path?(_path), do: false

  defp reject(conn) do
    conn
    |> send_resp(:not_found, "")
    |> halt()
  end
end
