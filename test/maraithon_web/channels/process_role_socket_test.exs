defmodule MaraithonWeb.ProcessRoleSocketTest do
  use MaraithonWeb.ChannelCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias MaraithonWeb.{CompanionSocket, LiveSocket}

  setup do
    previous_role = Application.get_env(:maraithon, :process_role)

    on_exit(fn -> restore_env(:process_role, previous_role) end)
  end

  test "the Endpoint mounts the role-aware LiveView socket" do
    assert Enum.any?(MaraithonWeb.Endpoint.__sockets__(), fn
             {"/live", LiveSocket, _opts} -> true
             _socket -> false
           end)

    refute Enum.any?(MaraithonWeb.Endpoint.__sockets__(), fn
             {"/live", Phoenix.LiveView.Socket, _opts} -> true
             _socket -> false
           end)
  end

  test "runtime processes reject LiveView and companion transports before authentication" do
    Application.put_env(:maraithon, :process_role, :runtime)

    assert :error = LiveSocket.connect(%{}, %Phoenix.Socket{}, %{session: %{}})

    assert :error =
             CompanionSocket.connect(
               %{"token" => "not-verified-on-runtime"},
               %Phoenix.Socket{},
               %{}
             )
  end

  test "web and combined processes retain both socket transports" do
    {:ok, user} =
      Accounts.get_or_create_user_by_email(
        "role-socket-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, %{token: token}} = Devices.register(user.id, Ecto.UUID.generate())

    for role <- [:web, :combined] do
      Application.put_env(:maraithon, :process_role, role)

      assert {:ok, %Phoenix.Socket{private: %{connect_info: %{session: %{}}}}} =
               LiveSocket.connect(%{}, %Phoenix.Socket{}, %{session: %{}})

      assert {:ok, socket} = connect(CompanionSocket, %{"token" => token})
      assert socket.assigns.current_user_id == user.id
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)
end
