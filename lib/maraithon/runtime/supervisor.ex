defmodule Maraithon.Runtime.Supervisor do
  @moduledoc """
  Top-level supervisor for the Maraithon runtime.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Registry for looking up agent processes by ID
      {Registry, keys: :unique, name: Maraithon.Runtime.AgentRegistry},

      # Dynamic supervisor for agent processes
      {DynamicSupervisor, strategy: :one_for_one, name: Maraithon.Runtime.AgentSupervisor},

      # Dynamic supervisor for effect worker tasks
      {DynamicSupervisor, strategy: :one_for_one, name: Maraithon.Runtime.EffectSupervisor},

      # Effect runner (polls and executes effects)
      Maraithon.Runtime.EffectRunner,

      # Scheduler (polls and delivers wakeups)
      Maraithon.Runtime.Scheduler,

      # Health reporter
      Maraithon.Runtime.HealthReporter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
