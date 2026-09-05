defmodule MaraithonWeb.CompanionSocket do
  @moduledoc """
  Phoenix Socket for companion desktop devices.

  Authenticates a join via the same bearer-token mechanism as
  `MaraithonWeb.Plugs.CompanionDeviceAuth`: the client passes the
  plaintext token as the `"token"` connect param, we look up the
  device via `Maraithon.Companion.Devices.verify_token/1`, and on
  success store the device + user_id on the socket assigns.

  The socket is mounted at `"/companion/socket"` in
  `MaraithonWeb.Endpoint` and is the transport behind the
  `companion:device:<device_id>` channel topic implemented in
  `MaraithonWeb.CompanionChannel`.
  """

  use Phoenix.Socket

  alias Maraithon.Companion.Devices
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  channel "companion:device:*", MaraithonWeb.CompanionChannel

  @impl true
  def connect(params, socket, _connect_info) do
    if RuntimeConfig.web_process?(), do: connect_web(params, socket), else: :error
  end

  defp connect_web(params, socket) do
    with {:ok, token} <- extract_token(params),
         %{} = device <- Devices.verify_token(token) do
      device = Devices.touch_last_seen(device)

      {:ok,
       socket
       |> assign(:current_device, device)
       |> assign(:current_user_id, device.user_id)}
    else
      _ ->
        :telemetry.execute(
          [:maraithon, :companion, :auth_failure],
          %{count: 1},
          %{reason: :channel_invalid_token}
        )

        :error
    end
  end

  @impl true
  def id(socket) do
    case socket.assigns[:current_device] do
      nil -> nil
      device -> "companion_device:#{device.id}"
    end
  end

  defp extract_token(%{"token" => token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp extract_token(%{token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp extract_token(_), do: :error
end
