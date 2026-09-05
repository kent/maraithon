defmodule Maraithon.Runtime.Supervisor do
  @moduledoc """
  Top-level supervisor for the Maraithon runtime.
  """

  use Supervisor

  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.PeriodicJobs

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    if Config.runtime_process?() do
      init_runtime_children()
    else
      {:stop, :runtime_process_required}
    end
  end

  defp init_runtime_children do
    background_workers? = Application.get_env(:maraithon, :start_background_workers, true)
    if background_workers?, do: BootGate.close(), else: BootGate.open()

    agent_supervisor =
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Maraithon.Runtime.AgentSupervisor,
       max_restarts: 20,
       max_seconds: 60}

    dependency_children = [
      {Registry, keys: :unique, name: Maraithon.Runtime.AgentRegistry},
      {Task.Supervisor, name: Maraithon.Runtime.EffectSupervisor},
      Maraithon.Runtime.TaskSystemSupervisor,
      {Task.Supervisor, name: Maraithon.Runtime.ToolCallSupervisor},
      Maraithon.Runtime.Effects.LLMRateLimiter,
      {Task.Supervisor, name: Maraithon.Runtime.AgentRecoveryTaskSupervisor}
    ]

    children =
      if background_workers? do
        dependency_children ++
          [
            # EffectRunner starts closed behind BootGate. Keeping it before the
            # Agent supervisor means Agents terminate and fence their outbox
            # work while the runner is still alive during reverse-order stop.
            Maraithon.Runtime.EffectRunner,
            # AgentWatcher is supervised above Runtime.Supervisor so this whole
            # subtree (including AgentSupervisor) can restart or stop while the
            # exact PID monitors remain alive.
            agent_supervisor,
            Maraithon.Runtime.WakeCoordinator,
            Maraithon.Runtime.Bootstrap,
            # Deliberately non-fair: this heterogeneous runner owns ordered
            # Telegram ingress. Migration 140004 will supply its global tenant
            # policy; only the two homogeneous lanes below use local rotation.
            Supervisor.child_spec(
              {Maraithon.Runtime.BackgroundJobRunner,
               exclude_queues: [PeriodicJobs.provider_queue(), PeriodicJobs.model_queue()]},
              id: Maraithon.Runtime.BackgroundJobRunner
            ),
            Supervisor.child_spec(
              {Maraithon.Runtime.BackgroundJobRunner,
               name: Maraithon.Runtime.ProviderBackgroundJobRunner,
               queues: [PeriodicJobs.provider_queue()],
               fair?: true,
               max_concurrency: Config.positive_integer(:provider_job_max_concurrency, 4),
               max_partition_concurrency: 1,
               max_rate_limit_concurrency: 1,
               reconcile_recurring_jobs?: false},
              id: Maraithon.Runtime.ProviderBackgroundJobRunner
            ),
            Supervisor.child_spec(
              {Maraithon.Runtime.BackgroundJobRunner,
               name: Maraithon.Runtime.ModelBackgroundJobRunner,
               queues: [PeriodicJobs.model_queue()],
               fair?: true,
               max_concurrency: Config.positive_integer(:model_job_max_concurrency, 3),
               max_partition_concurrency: 1,
               max_rate_limit_concurrency: Config.positive_integer(:model_job_max_concurrency, 3),
               reconcile_recurring_jobs?: false},
              id: Maraithon.Runtime.ModelBackgroundJobRunner
            ),
            Maraithon.Runtime.Scheduler,
            Maraithon.Runtime.ShutdownReporter,
            # These two remain independent observers by design. If the durable
            # queue or every lane runner wedges, putting its reporter/alarm in
            # that same queue would silence the only signal about the failure.
            Maraithon.Runtime.HealthReporter,
            Maraithon.Runtime.StuckStateWatchdog,
            # Supervised last so graceful shutdown revokes PostgreSQL readiness
            # before any scoped worker or exact task supervisor stops locally.
            Maraithon.Runtime.Coordination.Session
          ]
      else
        # The mandatory watcher is a parent-level application child. Exact
        # starts remain available while periodic/background producers are off.
        dependency_children ++ [agent_supervisor]
      end

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 20,
      max_seconds: 60
    )
  end
end
