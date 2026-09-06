defmodule Maraithon.Runtime.Coordination.Session do
  @moduledoc """
  Local participant in the PostgreSQL-owned coordination protocol.

  Worker processes start fail-closed. This process is supervised last, verifies
  them, registers a joining incarnation, and publishes node readiness last. It
  is therefore stopped first: graceful shutdown revokes DB readiness and fences
  partitions before local workers are terminated.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias Maraithon.Repo
  alias Maraithon.Runtime.Config

  alias Maraithon.Runtime.Coordination.{
    Authority,
    NodeIncarnation,
    Planner,
    Protocol,
    TaskAssignment,
    TaskClaims,
    TaskSupervisor
  }

  @default_tick 2_000
  @default_node_ttl 30_000
  @default_partition_ttl 30_000
  # A planner tick also publishes partitions and reconciles task proofs.
  # Give leadership the same lease window as its node, rather than expiring
  # it halfway through an otherwise valid node/partition lease.
  @default_leader_ttl 30_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 30_000,
      type: :worker
    }
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @published_table :maraithon_runtime_coordination_session

  @doc """
  Returns the ready node incarnation from the Session's published scope.

  The Session publishes `{phase, session}` to a protected ETS table after every
  tick, so readers never wait on the GenServer while it is inside a database
  transaction (its lease renewals can queue behind row locks held by the very
  callers asking for the session). The GenServer call remains only as the
  bootstrap fallback before the first publication.
  """
  def current do
    case :ets.lookup(@published_table, :current) do
      [{:current, :ready, %NodeIncarnation{} = session}] -> {:ok, session}
      [{:current, phase, _session}] -> {:error, {:coordination_not_ready, phase}}
      [] -> GenServer.call(__MODULE__, :current, 5_000)
    end
  rescue
    ArgumentError -> {:error, :coordination_session_unavailable}
  catch
    :exit, _ -> {:error, :coordination_session_unavailable}
  end

  def prepare_shutdown, do: GenServer.call(__MODULE__, :prepare_shutdown, 30_000)

  @doc """
  Starts a drain without waiting for it. Used by the deploy pipeline before a
  revision replacement: the node revokes its partitions, stops local Agents
  with local proofs, and settles its tasks while it still has all the time it
  needs, instead of racing the platform's SIGTERM grace period.
  """
  def request_drain, do: GenServer.cast(__MODULE__, :drain)

  @doc "Leaves a drained state so the next tick registers a fresh incarnation."
  def rejoin, do: GenServer.call(__MODULE__, :rejoin, 5_000)

  @doc "Published phase and incarnation id, without touching the GenServer."
  def status do
    case :ets.lookup(@published_table, :current) do
      [{:current, phase, %NodeIncarnation{id: id}}] -> %{phase: phase, node_incarnation_id: id}
      [{:current, phase, _}] -> %{phase: phase, node_incarnation_id: nil}
      [] -> %{phase: :unknown, node_incarnation_id: nil}
    end
  rescue
    ArgumentError -> %{phase: :unavailable, node_incarnation_id: nil}
  end

  @doc false
  def terminate_background_job_assignment(assignment_id) when is_binary(assignment_id) do
    case TaskClaims.get(assignment_id) do
      %TaskAssignment{work_kind: "background_job", state: state} = assignment
      when state in ["reserved", "running", "termination_requested", "termination_proven"] ->
        case TaskSupervisor.terminate_exact(task_identity(assignment)) do
          {:ok, _proof} -> :ok
          {:unknown, _reason} = unknown -> unknown
          _other -> {:unknown, :task_termination_unproven}
        end

      _missing_or_mismatched ->
        {:unknown, :task_identity_mismatch}
    end
  rescue
    _error -> {:unknown, :task_termination_unproven}
  catch
    :exit, _reason -> {:unknown, :task_termination_unproven}
  end

  def terminate_background_job_assignment(_assignment_id),
    do: {:unknown, :invalid_task_identity}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session: nil,
      leader: nil,
      phase: :dormant,
      joining_attempts: 0,
      tick_ms:
        Keyword.get(opts, :tick_ms, Config.positive_integer(:coordination_tick_ms, @default_tick)),
      node_ttl_ms:
        Keyword.get(
          opts,
          :node_ttl_ms,
          Config.positive_integer(:coordination_node_ttl_ms, @default_node_ttl)
        ),
      partition_ttl_ms:
        Keyword.get(
          opts,
          :partition_ttl_ms,
          Config.positive_integer(:coordination_partition_ttl_ms, @default_partition_ttl)
        ),
      leader_ttl_ms:
        Keyword.get(
          opts,
          :leader_ttl_ms,
          Config.positive_integer(:coordination_leader_ttl_ms, @default_leader_ttl)
        ),
      transition_limit:
        Keyword.get(
          opts,
          :transition_limit,
          Config.positive_integer(:coordination_transition_limit, 4)
        ),
      required_workers: Keyword.get(opts, :required_workers, required_workers())
    }

    _ = :ets.new(@published_table, [:named_table, :protected, :set, read_concurrency: true])
    publish(state)

    send(self(), :coordinate)
    {:ok, state}
  end

  @impl true
  def handle_call(
        :current,
        _from,
        %{phase: :ready, session: %NodeIncarnation{} = session} = state
      ),
      do: {:reply, {:ok, session}, state}

  def handle_call(:current, _from, state),
    do: {:reply, {:error, {:coordination_not_ready, state.phase}}, state}

  def handle_call(:prepare_shutdown, _from, state) do
    {reply, state} = drain_safely(state)
    publish(state)
    {:reply, reply, state}
  end

  def handle_call(:rejoin, _from, %{phase: phase} = state)
      when phase in [:draining, :uncertain] do
    state = %{state | session: nil, leader: nil, phase: :dormant, joining_attempts: 0}
    publish(state)
    {:reply, :ok, state}
  end

  def handle_call(:rejoin, _from, state),
    do: {:reply, {:error, {:not_drained, state.phase}}, state}

  @impl true
  def handle_cast(:drain, %{phase: :draining} = state), do: {:noreply, state}

  def handle_cast(:drain, state) do
    {_reply, state} = drain_safely(state)

    publish(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:coordinate, state) do
    state = coordinate_safely(state)
    publish(state)
    Process.send_after(self(), :coordinate, state.tick_ms)
    {:noreply, state}
  end

  # Lease expiry and connection loss are expected authority failures. Keep the
  # old incarnation long enough to terminate its local work and persist proof;
  # crashing this process would discard that cleanup identity on restart.
  defp coordinate_safely(state) do
    coordinate(state)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("RUNTIME_COORDINATION_ERROR=database",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      phase = if state.phase == :drain_pending, do: :drain_pending, else: :uncertain
      %{state | phase: phase, leader: nil}
  end

  @impl true
  def terminate(_reason, %{phase: :draining}), do: :ok

  def terminate(_reason, state) do
    _ = drain(state)
    # The protected table dies with this process; readers then fall back to
    # `{:error, :coordination_session_unavailable}` instead of a stale scope.
    :ok
  end

  # Publication is the only cross-process read path for the current scope.
  # `phase` other than `:ready` publishes as not-ready so callers fail closed.
  defp publish(%{phase: phase, session: session}) do
    :ets.insert(@published_table, {:current, phase, session})
    :ok
  end

  defp coordinate(%{phase: :dormant} = state) do
    if Config.multinode_coordination_enabled?() and Protocol.mode() == :active do
      case Authority.register_node(
             ttl_ms: state.node_ttl_ms,
             metadata: node_metadata()
           ) do
        {:ok, %NodeIncarnation{} = session} ->
          Logger.info("Runtime node registered", node_incarnation_id: session.id)
          %{state | session: session, phase: :joining}

        _ ->
          state
      end
    else
      state
    end
  end

  defp coordinate(%{phase: :joining, session: session} = state) do
    missing_workers = Enum.reject(state.required_workers, &is_pid(Process.whereis(&1)))

    if missing_workers == [] do
      case Authority.mark_node_ready(session) do
        {:ok, %NodeIncarnation{} = ready} ->
          %{state | session: ready, phase: :ready, joining_attempts: 0} |> ready_cycle()

        _ ->
          fail_closed(state, :mark_node_ready)
      end
    else
      if rem(state.joining_attempts, 15) == 0 do
        codes = missing_workers |> Enum.map(&worker_code/1) |> Enum.sort() |> Enum.join(",")
        Logger.warning("RUNTIME_COORDINATION_ERROR=joining_workers_missing:#{codes}")
      end

      %{state | joining_attempts: state.joining_attempts + 1}
    end
  end

  defp coordinate(%{phase: :ready} = state), do: ready_cycle(state)

  defp coordinate(%{phase: :drain_pending} = state) do
    {_reply, state} = drain_safely(state)
    state
  end

  defp coordinate(%{phase: :uncertain} = state) do
    # Uncertain work remains fenced to its expired incarnation. After local
    # termination and proof reconciliation, rejoin with a fresh identity so
    # unrelated partitions can recover. The planner still cannot release an
    # old partition until its exact task proof is durable.
    state = cleanup_uncertain(state)
    %{state | session: nil, leader: nil, phase: :dormant}
  end

  defp coordinate(state), do: state

  # The protocol revision and reusable deployment generation are not physical
  # process identities. Keep the actual hosting revision for incident recovery.
  defp node_metadata do
    %{
      "deployment_generation" => Authority.deployment_generation(),
      "cloud_run_revision" => System.get_env("K_REVISION"),
      "cloud_run_service" => System.get_env("K_SERVICE")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp ready_cycle(state) do
    started_at = System.monotonic_time(:millisecond)
    state = renew_ownership(state)

    if state.phase == :ready do
      prepare_and_plan(state, started_at)
    else
      state
    end
  end

  defp renew_ownership(%{phase: phase} = state) when phase != :ready, do: state

  defp renew_ownership(state) do
    with {:renew_node, {:ok, %NodeIncarnation{state: "ready"} = session}} <-
           {:renew_node, Authority.renew_node(state.session, state.node_ttl_ms)},
         {:renew_partitions, {:ok, _partitions}} <-
           {:renew_partitions, Authority.renew_partitions(session, state.partition_ttl_ms)} do
      %{state | session: session} |> refresh_leader()
    else
      {:renew_node, {:ok, %NodeIncarnation{state: "draining"} = session}} ->
        # A database-side drain is an explicit retirement request, not a lost
        # lease to recover by registering a new incarnation. Finish local proof
        # cleanup without renewing leadership or readmitting this process.
        %{state | session: session} |> mark_drain_pending() |> coordinate()

      {:renew_node, _error} ->
        fail_closed(state, :renew_node)

      {:renew_partitions, _error} ->
        fail_closed(state, :renew_partitions)
    end
  end

  defp prepare_and_plan(state, started_at) do
    case publish_preparing_partitions(state.session) do
      :ok ->
        _ = drain_revoked_partitions(state.session)

        case TaskClaims.reconcile_proven(10) do
          {:ok, _results} ->
            # Recovery can spend a whole renewal interval publishing partitions
            # or settling proofs. Refresh every ownership lease before another
            # planner batch; renewing only leadership leaves the node to expire.
            state =
              if System.monotonic_time(:millisecond) - started_at >= state.tick_ms,
                do: renew_ownership(state),
                else: state

            plan_partitions(state)

          _error ->
            fail_closed(state, :reconcile_proven)
        end

      {:error, :partition_publish_failed} ->
        fail_closed(state, :publish_partition)
    end
  end

  defp plan_partitions(%{leader: nil} = state), do: state

  defp plan_partitions(state) do
    case Planner.plan_once(state.leader, limit: state.transition_limit) do
      {:ok, _result} -> state
      {:error, reason} -> fail_closed(state, planner_error_code(reason))
    end
  rescue
    _error in Postgrex.Error -> fail_closed(state, :planner_database)
    _error -> fail_closed(state, :planner_exception)
  catch
    :exit, _reason -> fail_closed(state, :planner_exception)
  end

  defp planner_error_code({stage, reason}),
    do: "planner_#{planner_stage_code(stage)}:#{planner_reason_code(reason)}"

  defp planner_error_code(_reason), do: "planner_unknown:error"

  defp planner_stage_code(:finalize), do: "finalize"
  defp planner_stage_code(:fence), do: "fence"
  defp planner_stage_code(:assign), do: "assign"
  defp planner_stage_code(:rebalance), do: "rebalance"
  defp planner_stage_code(_stage), do: "unknown"

  defp planner_reason_code({:database, code}), do: "database_#{database_error_code(code)}"
  defp planner_reason_code(:exception), do: "exception"
  defp planner_reason_code(:exit), do: "exit"
  defp planner_reason_code(_reason), do: "error"

  defp database_error_code(:check_violation), do: "check_violation"
  defp database_error_code(:foreign_key_violation), do: "foreign_key_violation"
  defp database_error_code(:insufficient_privilege), do: "insufficient_privilege"
  defp database_error_code(:lock_not_available), do: "lock_not_available"
  defp database_error_code(:query_canceled), do: "query_canceled"
  defp database_error_code(:unique_violation), do: "unique_violation"
  defp database_error_code(:undefined_column), do: "undefined_column"
  defp database_error_code(:undefined_table), do: "undefined_table"
  defp database_error_code(_code), do: "other"

  defp refresh_leader(%{phase: phase} = state) when phase != :ready, do: state

  defp refresh_leader(%{leader: nil} = state) do
    case Authority.acquire_leader(state.session, state.leader_ttl_ms) do
      {:ok, preparing} ->
        case Authority.mark_leader_ready(preparing) do
          {:ok, ready} -> %{state | leader: ready}
          _ -> state
        end

      {:error, :leader_held} ->
        state

      {:error, :leader_incarnation_expired} ->
        # The exact protocol requires a fresh node identity after this node's
        # ready leadership expires. Preserve the identity for local cleanup.
        fail_closed(state, :leader_incarnation_expired)

      _ ->
        state
    end
  end

  defp refresh_leader(%{leader: leader} = state) do
    case Authority.renew_leader(leader, state.leader_ttl_ms) do
      {:ok, renewed} -> %{state | leader: renewed}
      _ -> %{state | leader: nil}
    end
  end

  defp publish_preparing_partitions(session) do
    Authority.owned_partitions(session, ["preparing"])
    |> Enum.reduce_while(:ok, fn partition, :ok ->
      # All scoped pollers were verified before node readiness; partition ready
      # is the final authority publication, never an acquisition side effect.
      case Authority.mark_partition_ready(session, partition.partition_id) do
        {:ok, _ready} -> {:cont, :ok}
        _error -> {:halt, {:error, :partition_publish_failed}}
      end
    end)
  end

  defp drain_revoked_partitions(session) do
    Authority.locally_owned_revoked_partitions(session)
    |> Enum.each(fn partition ->
      _ = Authority.revoke_partition_workload(session, partition.partition_id)
      terminate_partition_tasks(session, partition.partition_id, partition.ownership_epoch)
    end)
  end

  defp terminate_partition_tasks(session, partition_id, epoch) do
    Repo.all(
      from a in TaskAssignment,
        where:
          a.node_incarnation_id == ^session.id and a.partition_id == ^partition_id and
            a.partition_epoch == ^epoch and a.state in ["reserved", "termination_requested"],
        order_by: a.id
    )
    |> Enum.each(&terminate_exact_task/1)
  end

  defp terminate_exact_task(%TaskAssignment{work_kind: "background_job"} = assignment) do
    identity = task_identity(assignment)

    case TaskSupervisor.terminate_exact(identity) do
      {:ok, :never_activated} -> :ok
      {:ok, _proof} -> :ok
      {:unknown, _reason} -> :blocked
      _ -> :blocked
    end
  end

  defp terminate_exact_task(%TaskAssignment{work_kind: "effect"} = assignment) do
    claim = %{
      effect_id: assignment.work_id,
      agent_id: effect_agent_id(assignment.work_id),
      claim_token: assignment.claim_token,
      supervisor_id: assignment.supervisor_id,
      task_id: assignment.local_task_id
    }

    case Maraithon.Effects.Cancellation.terminate_local_coordination_assignment(
           assignment,
           claim
         ) do
      {:ok, :termination_proven} ->
        :ok

      {:unknown, _reason} ->
        :blocked

      _ ->
        :blocked
    end
  end

  defp task_identity(assignment),
    do: %{
      work_kind: assignment.work_kind,
      work_id: assignment.work_id,
      claim_token: assignment.claim_token,
      assignment_id: assignment.id,
      supervisor_id: assignment.supervisor_id,
      local_task_id: assignment.local_task_id
    }

  defp effect_agent_id(effect_id) do
    case Repo.query("SELECT agent_id FROM public.effects WHERE id = $1::uuid", [
           Ecto.UUID.dump!(effect_id)
         ]) do
      {:ok, %{rows: [[id]]}} -> Ecto.UUID.load!(id)
      _ -> nil
    end
  end

  defp drain_safely(state) do
    state = mark_drain_pending(state)

    try do
      drain(state)
    rescue
      error ->
        Logger.warning(
          "RUNTIME_COORDINATION_ERROR=drain:#{Maraithon.Redaction.error_class(error)}"
        )

        {{:error, :drain_cleanup_failed}, state}
    catch
      :exit, _reason ->
        Logger.warning("RUNTIME_COORDINATION_ERROR=drain:exit")
        {{:error, :drain_cleanup_failed}, state}
    end
  end

  defp drain(%{session: %NodeIncarnation{} = session} = state) do
    # PostgreSQL revocation happens before any local termination attempt.
    case Authority.begin_node_drain(session) do
      {:ok, :draining} ->
        terminate_local_agents()
        # begin_node_drain already revoked each partition's workload. Terminate
        # its exact local tasks without repeating those database drain phases.
        terminate_local_tasks(session)
        _ = TaskClaims.reconcile_proven(100)

        # PostgreSQL refuses revocation while any local task lacks its proof;
        # the node then stays draining (nothing new is admitted) and a successor
        # leader releases the partitions once the proofs land.
        _ = revoke_drained_node(session)

        {:ok, %{state | phase: :draining, leader: nil}}

      {:error, reason} ->
        # The topology fence may already have committed before workload cleanup
        # failed. Retain drain intent across retries; an automatic rejoin would
        # undo the operator's retirement request with a fresh node identity.
        state = cleanup_uncertain(state)
        {{:error, reason}, mark_drain_pending(state)}
    end
  end

  defp drain(state), do: {:ok, %{state | phase: :draining, leader: nil}}

  defp mark_drain_pending(state) do
    state = %{state | phase: :drain_pending, leader: nil}
    publish(state)
    state
  end

  defp revoke_drained_node(session) do
    result =
      Authority.revoke_node(%{
        session
        | state: "draining",
          ready_at: nil,
          draining_at: session.draining_at || session.updated_at
      })

    case result do
      {:error, :node_not_drained} ->
        Logger.warning("Node revocation deferred until local task proofs and partitions clear")
        {:error, :node_revocation_deferred}

      other ->
        other
    end
  rescue
    error in Postgrex.Error ->
      Logger.warning("Node revocation deferred until local task proofs land",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      {:error, :node_revocation_deferred}
  end

  defp terminate_local_agents do
    DynamicSupervisor.which_children(Maraithon.Runtime.AgentSupervisor)
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(Maraithon.Runtime.AgentSupervisor, pid)

      _ ->
        :ok
    end)
  catch
    :exit, _ -> :ok
  end

  defp cleanup_uncertain(%{session: %NodeIncarnation{} = session} = state) do
    terminate_local_agents()
    terminate_local_tasks(session)
    _ = drain_revoked_partitions(session)
    _ = TaskClaims.reconcile_proven(100)
    %{state | phase: :uncertain, leader: nil}
  end

  defp cleanup_uncertain(state), do: %{state | phase: :uncertain, leader: nil}

  defp terminate_local_tasks(session) do
    Repo.all(
      from a in TaskAssignment,
        where: a.node_incarnation_id == ^session.id,
        where: a.state in ["reserved", "running", "termination_requested"],
        order_by: a.id
    )
    |> Enum.each(&terminate_local_assignment/1)
  rescue
    _ -> :blocked
  catch
    :exit, _ -> :blocked
  end

  defp terminate_local_assignment(assignment) do
    # A reserved task cannot use the running-only termination-request transition.
    # The guardian records never-activated proof for reservations, or atomically
    # requests termination and records monitored proof for an activated task.
    # Keep attempting the other exact identities if one proof must retry.
    terminate_exact_task(assignment)
  rescue
    _ -> :blocked
  catch
    :exit, _ -> :blocked
  end

  defp fail_closed(state, stage) do
    Logger.error("RUNTIME_COORDINATION_ERROR=#{stage}")

    state = %{state | phase: :uncertain, leader: nil}
    publish(state)

    # Uncertainty revokes all local execution immediately. Durable settlement
    # still requires exact monitored termination proof and PostgreSQL fences.
    cleanup_uncertain(state)
  end

  defp worker_code(Maraithon.Runtime.BackgroundJobRunner), do: "background_job_runner"
  defp worker_code(Maraithon.Runtime.EffectRunner), do: "effect_runner"
  defp worker_code(Maraithon.Runtime.Scheduler), do: "scheduler"
  defp worker_code(Maraithon.Runtime.WakeCoordinator), do: "wake_coordinator"
  defp worker_code(Maraithon.Runtime.AgentWatcher), do: "agent_watcher"
  defp worker_code(_worker), do: "unknown"

  defp required_workers do
    [
      Maraithon.Runtime.BackgroundJobRunner,
      Maraithon.Runtime.EffectRunner,
      Maraithon.Runtime.Scheduler,
      Maraithon.Runtime.WakeCoordinator,
      Maraithon.Runtime.AgentWatcher
    ]
  end
end
