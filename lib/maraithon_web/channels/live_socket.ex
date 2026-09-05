defmodule MaraithonWeb.LiveSocket do
  @moduledoc """
  LiveView transport boundary for the public web process.

  Phoenix dispatches socket transports before the Endpoint's ordinary plug
  pipeline, so the HTTP process-role gate cannot protect this boundary.
  """

  use Phoenix.LiveView.Socket

  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    if RuntimeConfig.web_process?(),
      do: Phoenix.LiveView.Socket.connect(params, socket, connect_info),
      else: :error
  end

  @impl Phoenix.Socket
  def id(socket), do: Phoenix.LiveView.Socket.id(socket)
end
