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
    base_children = [
      # Registry for looking up agent processes by ID
      {Registry, keys: :unique, name: Maraithon.Runtime.AgentRegistry},

      # Dynamic supervisor for agent processes
      {DynamicSupervisor, strategy: :one_for_one, name: Maraithon.Runtime.AgentSupervisor},

      # Task supervisor for effect worker tasks
      {Task.Supervisor, name: Maraithon.Runtime.EffectSupervisor}
    ]

    # Background workers that poll the database - disabled in test mode
    background_workers =
      if Application.get_env(:maraithon, :start_background_workers, true) do
        [
          Maraithon.Runtime.Bootstrap,
          Maraithon.Runtime.EffectRunner,
          Maraithon.Runtime.Scheduler,
          Maraithon.Runtime.HealthReporter
        ]
      else
        []
      end

    Supervisor.init(base_children ++ background_workers, strategy: :one_for_one)
  end
end
