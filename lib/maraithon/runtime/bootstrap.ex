defmodule Maraithon.Runtime.Bootstrap do
  @moduledoc """
  One-shot runtime bootstrap worker.

  Resumes persisted running agents after supervision tree startup.
  """

  use GenServer

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :bootstrap)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    Logger.info("Bootstrapping runtime")
    Maraithon.Runtime.resume_all_agents()
    {:stop, :normal, state}
  end
end
