defmodule Maraithon.Accounts.AdminBootstrap do
  @moduledoc """
  Ensures the primary admin user exists when the app boots.
  """

  use GenServer

  require Logger

  alias Maraithon.Accounts

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    send(self(), :ensure_admin)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:ensure_admin, state) do
    case Accounts.ensure_primary_admin_user!() do
      {:ok, :not_configured} ->
        Logger.info("Primary admin bootstrap skipped (PRIMARY_ADMIN_EMAIL not set)")

      {:ok, user} ->
        Logger.info("Primary admin ensured", user_id: user.id)

      {:error, reason} ->
        Logger.warning("Primary admin bootstrap skipped", reason: inspect(reason))
    end

    {:noreply, state}
  end
end
