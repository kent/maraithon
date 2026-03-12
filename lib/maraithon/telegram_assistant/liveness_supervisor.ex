defmodule Maraithon.TelegramAssistant.LivenessSupervisor do
  @moduledoc """
  Supervises per-run Telegram liveness sessions.
  """

  use Supervisor

  @registry Maraithon.TelegramAssistant.LivenessRegistry
  @dynamic_supervisor Maraithon.TelegramAssistant.LivenessDynamicSupervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def start_session(attrs) when is_map(attrs) do
    spec = {Maraithon.TelegramAssistant.LivenessSession, attrs}
    DynamicSupervisor.start_child(@dynamic_supervisor, spec)
  end
end
