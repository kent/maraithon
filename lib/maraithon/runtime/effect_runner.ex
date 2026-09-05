defmodule Maraithon.Runtime.EffectRunner do
  @moduledoc """
  Polls and executes effects from the outbox.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.DurablePayload
  alias Maraithon.Effects
  alias Maraithon.LLM
  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.EffectTaskSupervisor
  alias Maraithon.Runtime.Effects.CommandFactory
  alias Maraithon.Runtime.Effects.LLMRateLimiter
  alias Maraithon.Runtime.Coordination.{Protocol, Scope, TaskAssignment, TaskClaims}

  require Logger

  @default_poll_interval_ms 1_000
  # Must exceed the longest-running effect (LLM calls may take up to 20 minutes
  # plus busy retries). Crashed tasks and stale claims are terminalized as
  # ambiguous rather than released for unsafe re-execution.
  @default_claim_timeout_ms 1_500_000
  @default_claim_liveness_ttl_ms 30_000
  @min_claim_liveness_ttl_ms 30_000
  @default_batch_size 10
  @default_rate_limit_retry_ms 60_000
  @max_rate_limit_retry_ms 300_000
  @completion_write_attempts 5
  @completion_write_backoff_ms 100
  @completion_write_backoff_cap_ms 1_000
  @max_stale_finalizations 200
  @max_cancellation_reconciliations 32
  @max_legacy_termination_proofs 2_048
  @ambiguous_outcome :effect_outcome_ambiguous
  @task_termination_timeout_ms 2_000
  @task_termination_rpc_timeout_ms 2_500
  @continuation_check_timeout_ms 1_000
  @max_runtime_nodes 32
  @llm_lanes [:chat, :reasoning, :default]
  @execution_lane_key "__maraithon_execution_lane"
  @legacy_llm_scan_limit 200
  @shutdown_timeout_ms 15_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: @shutdown_timeout_ms,
      type: :worker
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fence active Effects, then terminate and settle exact tasks after commit.

  The durable protocol is feature-dark during rolling migration. Once enabled,
  every claimed Effect is routed by its immutable claim token and coupled task
  supervisor identity. Unproved or partitioned work remains `cancelling`.
  """
  def cancel_active_for_agent(agent_id, reason, opts \\ [])

  def cancel_active_for_agent(agent_id, reason, opts)
      when is_binary(agent_id) and byte_size(agent_id) in 1..255 and is_binary(reason) and
             byte_size(reason) in 1..255 and is_list(opts) do
    if valid_effect_cancellation_text?(agent_id) and valid_effect_cancellation_text?(reason) do
      case ProtocolCutover.mode() do
        :exact ->
          case Cancellation.request(agent_id, reason, opts) do
            {:ok, summary} -> {:ok, summary.requested}
            {:pending, _summary} -> {:error, :effect_task_termination_incomplete}
            {:error, {:effect_protocol_mismatch, _reason}} = error -> error
            {:error, :effect_cancellation_owner_generation_required} = error -> error
            {:error, :effect_cancellation_owner_generation_lost} = error -> error
            {:error, _reason} -> {:error, :effect_cancellation_failed}
          end

        :legacy ->
          cancel_active_for_agent_legacy(agent_id, reason)

        {:blocked, mismatch} ->
          {:error, {:effect_protocol_mismatch, mismatch}}
      end
    else
      {:error, :invalid_effect_cancellation}
    end
  end

  def cancel_active_for_agent(_agent_id, _reason, _opts),
    do: {:error, :invalid_effect_cancellation}

  @doc """
  Continue a cancellation already staged by AgentIsolation after its transaction
  commits. This function refuses to perform process/RPC work inside a Repo
  transaction.
  """
  def finish_cancel_active_for_agent_post_commit(agent_id, limit \\ 32) do
    case Cancellation.reconcile_agent(agent_id, limit) do
      {:ok, summary} -> {:ok, summary}
      {:pending, summary} -> {:pending, summary}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def execute_cancellation_plan(plan), do: Cancellation.execute(plan)

  defp cancel_active_for_agent_legacy(agent_id, reason) do
    case Effects.begin_cancel_active_for_agent(agent_id, reason) do
      {:ok, %{overflow?: true}} ->
        {:error, :effect_task_termination_incomplete}

      {:ok, %{claims: []} = cancellation} ->
        {:ok, cancellation.count}

      {:ok, cancellation} ->
        case terminate_cancelled_agent_tasks(agent_id, cancellation.claims) do
          {:ok, _settled_claims} -> {:ok, cancellation.count}
          {:partial, _settled_claims} -> {:error, :effect_task_termination_incomplete}
        end

      {:error, {:effect_protocol_mismatch, _reason}} = error ->
        error

      {:error, _reason} ->
        {:error, :effect_cancellation_failed}
    end
  end

  @doc false
  def terminate_cancelled_agent_tasks_local(agent_id, claims)
      when is_binary(agent_id) and byte_size(agent_id) in 1..255 and is_list(claims) and
             length(claims) <= 512 do
    case ProtocolCutover.mode() do
      :legacy ->
        terminate_cancelled_agent_tasks_local_legacy(agent_id, claims)

      :exact ->
        {:error, :legacy_effect_cancellation_disabled}

      {:blocked, mismatch} ->
        {:error, {:effect_protocol_mismatch, mismatch}}
    end
  catch
    :exit, _reason -> {:error, :effect_runner_unavailable}
  end

  def terminate_cancelled_agent_tasks_local(_agent_id, _claims),
    do: {:error, :invalid_effect_cancellation}

  defp terminate_cancelled_agent_tasks_local_legacy(agent_id, claims) do
    if valid_effect_cancellation_text?(agent_id) and valid_cancellation_claims?(claims) do
      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          GenServer.call(
            pid,
            {:terminate_cancelled_agent_tasks, agent_id, claims},
            @task_termination_timeout_ms
          )

        _pid ->
          # Runner absence and an empty local Registry are not termination
          # evidence: a task may live on another node, behind a partition, or
          # under a predecessor Registry generation.
          {:error, :effect_runner_unavailable}
      end
    else
      {:error, :invalid_effect_cancellation}
    end
  catch
    :exit, _reason -> {:error, :effect_runner_unavailable}
  end

  @doc false
  def persist_completed_once(%Effect{} = effect, result), do: mark_completed(effect, result)

  @impl true
  def init(opts) do
    completion_writer = option_function(opts, :completion_writer, &mark_completed/2, 2)
    completion_sleeper = option_function(opts, :completion_sleeper, &Process.sleep/1, 1)

    pre_provider_outcome_observer =
      option_function(
        opts,
        :pre_provider_outcome_observer,
        fn _effect, _disposition -> :ok end,
        2
      )

    command_prepared_observer = test_command_prepared_observer(opts)

    default_task_starter = fn effect, writer, sleeper ->
      execute_effect_async(
        effect,
        writer,
        sleeper,
        pre_provider_outcome_observer,
        command_prepared_observer
      )
    end

    task_starter = option_function(opts, :task_starter, default_task_starter, 3)

    poll_interval_ms =
      RuntimeConfig.positive_integer(:effect_poll_interval_ms, @default_poll_interval_ms)

    claim_timeout_ms =
      RuntimeConfig.positive_integer(:effect_claim_timeout_ms, @default_claim_timeout_ms)

    claim_liveness_ttl_ms =
      RuntimeConfig.positive_integer(
        :effect_claim_liveness_ttl_ms,
        @default_claim_liveness_ttl_ms
      )
      |> max(@min_claim_liveness_ttl_ms)
      |> min(300_000)

    batch_size = RuntimeConfig.positive_integer(:effect_batch_size, @default_batch_size)

    schedule_poll(poll_interval_ms)

    {:ok,
     %{
       running: %{},
       tasks: %{},
       monitors: %{},
       completion_writer: completion_writer,
       completion_sleeper: completion_sleeper,
       task_starter: task_starter,
       poll_interval_ms: poll_interval_ms,
       claim_timeout_ms: claim_timeout_ms,
       claim_liveness_ttl_ms: claim_liveness_ttl_ms,
       batch_size: batch_size,
       llm_lane_cursor: 0,
       legacy_llm_cursor: nil,
       legacy_cancellation_reconciler_ref: nil,
       legacy_termination_proofs: MapSet.new(),
       poll_retry_attempts: 0
     }}
  end

  @impl true
  def terminate(_reason, state) do
    _state = finalize_and_terminate_running(state, dispatch?: false)
    :ok
  end

  @impl true
  def handle_info(:poll, state) do
    if BootGate.open?() do
      handle_open_poll(state)
    else
      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:effect_done, effect_id, claim_token, claimed_by, claimed_at, _result},
        state
      ) do
    case Map.get(state.running, effect_id) do
      %Effect{
        claim_token: ^claim_token,
        claimed_by: ^claimed_by,
        claimed_at: ^claimed_at
      } = effect ->
        case acknowledge_completed_effect_task(effect) do
          :ok -> {:noreply, drop_effect_task(state, effect_id)}
          _pending_or_refused -> {:noreply, state}
        end

      _stale_or_unknown ->
        {:noreply, state}
    end
  end

  # Rolling compatibility for a legacy task that started before exact claims
  # were activated.
  @impl true
  def handle_info(
        {:effect_done, effect_id, claimed_by, claimed_at, _result},
        state
      ) do
    case Map.get(state.running, effect_id) do
      %Effect{claim_token: nil, claimed_by: ^claimed_by, claimed_at: ^claimed_at} ->
        {:noreply, drop_effect_task(state, effect_id)}

      _stale_or_unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {ref, _result},
        %{legacy_cancellation_reconciler_ref: ref} = state
      )
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | legacy_cancellation_reconciler_ref: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{legacy_cancellation_reconciler_ref: ref} = state
      )
      when is_reference(ref) do
    {:noreply, %{state | legacy_cancellation_reconciler_ref: nil}}
  end

  # Task.Supervisor.async_nolink sends its reply immediately before task exit.
  # If durable completion already removed the task, only retire the stale ref.
  # Otherwise keep the monitor: the subsequent VM-authenticated DOWN is the
  # physical boundary that drives proof-first preactivation convergence.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    if Map.has_key?(state.monitors, ref) do
      {:noreply, state}
    else
      Process.demonitor(ref, [:flush])
      {:noreply, state}
    end
  end

  # A task that exits without durably reporting completion may already have
  # crossed an external side-effect boundary. Terminalize its exact claim as
  # ambiguous; never release an unknown outcome for re-execution.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case authenticate_effect_task_down(state, ref, pid) do
      {:task, effect_id, state} ->
        effect = Map.get(state.running, effect_id)
        state = drop_effect_task(state, effect_id, demonitor?: false)

        if effect do
          disposition = finalize_effect_task_down(effect)

          if reason != :normal and disposition != :terminal do
            Logger.error("Effect task crashed",
              effect_reference: Maraithon.Redaction.fingerprint(effect_id),
              failure_code: Maraithon.Redaction.error_class(reason)
            )
          end

          case disposition do
            :terminal ->
              dispatch_terminal_result(effect)

            :ok ->
              dispatch_terminal_result(effect, {:error, @ambiguous_outcome})

            :claim_lost ->
              if ProtocolCutover.exact_reconciliation_enabled?() and
                   is_binary(effect.claim_token) do
                _ = Cancellation.reconcile_agent(effect.agent_id, 1)
              end

            {:error, _reason} ->
              :ok
          end
        end

        {:noreply, state}

      {:spoofed, state} ->
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    Logger.debug("EffectRunner ignoring unexpected message",
      failure_code: "unexpected_message"
    )

    {:noreply, state}
  end

  defp handle_open_poll(state) do
    case DbResilience.with_database("effect runner poll", fn ->
           {cancellation_plans, legacy_cancellation_agents} =
             case ProtocolCutover.mode() do
               :exact ->
                 log_surprise_legacy_claims()
                 {Cancellation.fence_expired_claims(100), []}

               :legacy ->
                 finalize_stale_effects(state.claim_timeout_ms)

                 agents =
                   case Effects.list_legacy_cancellation_agents(@max_cancellation_reconciliations) do
                     {:ok, agent_ids} -> agent_ids
                     {:error, _reason} -> []
                   end

                 {[], agents}

               {:blocked, _reason} ->
                 {[], []}
             end

           {effects, next_llm_lane_cursor, next_legacy_llm_cursor} =
             fetch_pending_effects(
               state.batch_size,
               state.running,
               state.llm_lane_cursor,
               state.legacy_llm_cursor
             )

           terminal_results = Effects.list_terminal_results_for_dispatch()

           {
             effects,
             next_llm_lane_cursor,
             next_legacy_llm_cursor,
             terminal_results,
             cancellation_plans,
             legacy_cancellation_agents
           }
         end) do
      {:ok,
       {
         effects,
         next_llm_lane_cursor,
         next_legacy_llm_cursor,
         terminal_results,
         cancellation_plans,
         legacy_cancellation_agents
       }} ->
        Enum.each(cancellation_plans, &Cancellation.execute/1)

        if ProtocolCutover.exact_reconciliation_enabled?() do
          _ = Cancellation.reconcile(@max_cancellation_reconciliations)
        end

        state =
          maybe_start_legacy_cancellation_reconciler(state, legacy_cancellation_agents)

        Enum.each(terminal_results, &dispatch_terminal_result/1)
        running_before_poll = state.running

        state =
          Enum.reduce(effects, state, fn effect, acc ->
            case claim_effect(effect, acc.claim_liveness_ttl_ms) do
              {:ok, claimed} ->
                case start_effect_task(
                       acc.task_starter,
                       claimed,
                       acc.completion_writer,
                       acc.completion_sleeper
                     ) do
                  {:ok, task} ->
                    %{
                      acc
                      | running: Map.put(acc.running, effect.id, claimed),
                        tasks: Map.put(acc.tasks, effect.id, task),
                        monitors: Map.put(acc.monitors, task.ref, effect.id)
                    }

                  {:error, _reason} ->
                    Logger.error("Effect task could not be supervised",
                      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
                      failure_code: "effect_supervisor_unavailable"
                    )

                    finalize_failed_effect_task_start(claimed)

                    acc
                end

              :already_claimed ->
                acc

              {:error, _reason} ->
                acc
            end
          end)

        llm_admitted? =
          Enum.any?(effects, fn effect ->
            effect.effect_type == "llm_call" and
              not Map.has_key?(running_before_poll, effect.id) and
              Map.has_key?(state.running, effect.id)
          end)

        llm_lane_cursor =
          if llm_admitted?, do: next_llm_lane_cursor, else: state.llm_lane_cursor

        schedule_poll(state.poll_interval_ms)

        {:noreply,
         %{
           state
           | poll_retry_attempts: 0,
             llm_lane_cursor: llm_lane_cursor,
             legacy_llm_cursor: next_legacy_llm_cursor
         }}

      {:error, _reason} ->
        retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
        schedule_poll(retry_in_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_call(:clear_running, _from, state) do
    state = finalize_and_terminate_running(state, dispatch?: true)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:terminate_cancelled_agent_tasks, agent_id, claims}, _from, state) do
    case registered_effect_tasks_for_agent(agent_id) do
      {:ok, registered_tasks} ->
        state_tasks = state_effect_tasks_for_agent(state, agent_id)
        task_entries = Enum.uniq_by(state_tasks ++ registered_tasks, &{&1.effect_id, &1.pid})
        claim_ids = Enum.map(claims, & &1.id)

        verification =
          DbResilience.with_database("effect runner verify cancelling tasks", fn ->
            from(effect in Effect,
              where: effect.agent_id == ^agent_id,
              where: effect.id in ^claim_ids,
              where: effect.status == "cancelling",
              select: %{
                id: effect.id,
                claimed_by: effect.claimed_by,
                claimed_at: effect.claimed_at
              }
            )
            |> legacy_protocol_rows()
            |> Repo.all()
          end)

        case verification do
          {:ok, verified_claims} when length(verified_claims) == length(claims) ->
            {terminated_ids, termination_proofs, failure_count} =
              terminate_verified_effect_tasks(
                task_entries,
                verified_claims,
                state.legacy_termination_proofs
              )

            state =
              Enum.reduce(terminated_ids, state, fn effect_id, acc ->
                drop_effect_task(acc, effect_id)
              end)

            state = %{
              state
              | legacy_termination_proofs:
                  remember_legacy_termination_proofs(
                    state.legacy_termination_proofs,
                    termination_proofs
                  )
            }

            terminated_claims =
              Enum.filter(verified_claims, &(&1.id in terminated_ids))

            settlement =
              Effects.finish_cancel_active_for_agent(agent_id, terminated_claims)

            reply =
              case settlement do
                {:ok, %{ambiguous: count}} when count == length(terminated_claims) ->
                  if failure_count == 0,
                    do: {:ok, terminated_claims},
                    else: {:partial, terminated_claims}

                _database_or_protocol_failure ->
                  # Keep process-local proof for the next bounded reconciliation;
                  # do not advertise settlement that PostgreSQL did not confirm.
                  {:partial, []}
              end

            {:reply, reply, state}

          {:ok, _protocol_mismatch} ->
            {:reply, {:error, {:effect_protocol_mismatch, :legacy_cancellation_verification}},
             state}

          {:error, _reason} ->
            {:reply, {:error, :effect_cancellation_verification_failed}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :effect_task_registry_unavailable}, state}
    end
  end

  # Private functions

  defp authenticate_effect_task_down(state, ref, pid)
       when is_reference(ref) and is_pid(pid) do
    case Map.get(state.monitors, ref) do
      nil ->
        :unknown

      effect_id ->
        case Map.get(state.tasks, effect_id) do
          %Task{ref: ^ref, pid: ^pid} = task ->
            if Process.demonitor(ref, [:info]) do
              new_ref = Process.monitor(pid)
              task = %{task | ref: new_ref}

              state = %{
                state
                | tasks: Map.put(state.tasks, effect_id, task),
                  monitors:
                    state.monitors
                    |> Map.delete(ref)
                    |> Map.put(new_ref, effect_id)
              }

              {:spoofed, state}
            else
              {:task, effect_id, state}
            end

          _mismatched_task ->
            :unknown
        end
    end
  end

  defp authenticate_effect_task_down(_state, _ref, _pid), do: :unknown

  defp maybe_start_legacy_cancellation_reconciler(
         %{legacy_cancellation_reconciler_ref: nil} = state,
         [_agent_id | _rest] = agent_ids
       ) do
    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.EffectSupervisor, fn ->
        Enum.each(agent_ids, fn agent_id ->
          _ = cancel_active_for_agent_legacy(agent_id, "legacy_cancellation_reconcile")
        end)
      end)

    %{state | legacy_cancellation_reconciler_ref: task.ref}
  catch
    :exit, _reason -> state
  end

  defp maybe_start_legacy_cancellation_reconciler(state, _agent_ids), do: state

  defp fetch_pending_effects(limit, running, llm_lane_cursor, legacy_llm_cursor) do
    case ProtocolCutover.mode() do
      mode when mode in [:exact, :legacy] ->
        do_fetch_pending_effects(limit, running, llm_lane_cursor, legacy_llm_cursor)

      _draining_or_blocked ->
        {[], llm_lane_cursor, legacy_llm_cursor}
    end
  end

  defp do_fetch_pending_effects(limit, running, llm_lane_cursor, legacy_llm_cursor) do
    available_slots = max(limit - map_size(running), 0)
    lane_order = rotate_llm_lanes(llm_lane_cursor)
    next_llm_lane_cursor = rem(llm_lane_cursor + 1, length(@llm_lanes))

    non_llm_candidates =
      if available_slots > 0 do
        pending_effects_query()
        |> where([e], e.effect_type != "llm_call")
        |> limit(^available_slots)
        |> Repo.all()
      else
        []
      end

    llm_fetch_limit =
      cond do
        non_llm_candidates == [] -> available_slots
        available_slots <= 1 -> available_slots
        true -> available_slots - 1
      end

    {lane_slots, llm_capacity} = llm_lane_slots(running)

    {llm_effects, next_legacy_llm_cursor} =
      if llm_fetch_limit > 0 and llm_capacity > 0 do
        {fetched, cursor} = fetch_llm_effects(lane_slots, lane_order, legacy_llm_cursor)
        {Enum.take(fetched, min(llm_fetch_limit, llm_capacity)), cursor}
      else
        {[], legacy_llm_cursor}
      end

    effects =
      if available_slots == 1 and non_llm_candidates != [] and llm_effects != [] do
        (non_llm_candidates ++ llm_effects)
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
        |> Enum.take(1)
      else
        non_llm_effects =
          Enum.take(non_llm_candidates, max(available_slots - length(llm_effects), 0))

        (non_llm_effects ++ llm_effects)
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
      end
      |> Enum.reject(&Map.has_key?(running, &1.id))

    {effects, next_llm_lane_cursor, next_legacy_llm_cursor}
  end

  defp pending_effects_query do
    query =
      from(e in Effect,
        where: e.status == "pending",
        where: is_nil(e.retry_after) or e.retry_after <= fragment("timezone('UTC', NOW())"),
        order_by: [asc: e.inserted_at, asc: e.id]
      )

    case ProtocolCutover.mode() do
      :exact ->
        from(e in query,
          where: not is_nil(e.runtime_owner_generation),
          where: is_nil(e.claim_token),
          where: is_nil(e.claim_owner_node),
          where: is_nil(e.claim_heartbeat_at),
          where: is_nil(e.claim_expires_at),
          where: is_nil(e.claim_supervisor_id),
          where: is_nil(e.claim_task_id),
          where: is_nil(e.cancellation_state),
          where:
            fragment(
              "EXISTS (SELECT 1 FROM agent_runtime_leases AS pending_effect_owner_lease WHERE pending_effect_owner_lease.agent_id = ? AND pending_effect_owner_lease.owner_token = ? AND pending_effect_owner_lease.ready_at IS NOT NULL AND pending_effect_owner_lease.draining_at IS NULL AND pending_effect_owner_lease.lease_until > timezone('UTC', clock_timestamp()))",
              e.agent_id,
              e.runtime_owner_generation
            )
        )
        |> coordinated_effect_query()

      :legacy ->
        legacy_protocol_rows(query)

      _draining_or_blocked ->
        where(query, [e], false)
    end
  end

  defp coordinated_effect_query(query) do
    case Protocol.mode() do
      :dark ->
        query

      :active ->
        case Scope.current() do
          {:ok, session} ->
            from(e in query,
              where:
                fragment(
                  """
                  EXISTS (
                    SELECT 1 FROM public.agent_runtime_leases AS scoped_lease
                    JOIN public.runtime_partitions AS scoped_partition
                      ON scoped_partition.partition_id = scoped_lease.coordination_partition_id
                     AND scoped_partition.activation_epoch = scoped_lease.coordination_activation_epoch
                     AND scoped_partition.ownership_epoch = scoped_lease.coordination_partition_epoch
                     AND scoped_partition.owner_node_incarnation_id = scoped_lease.coordination_node_incarnation_id
                     AND scoped_partition.state = 'ready' AND scoped_partition.ready_at IS NOT NULL
                     AND scoped_partition.lease_expires_at > timezone('UTC', clock_timestamp())
                    WHERE scoped_lease.agent_id = ? AND scoped_lease.owner_token = ?
                      AND scoped_lease.coordination_activation_epoch = ?::uuid
                      AND scoped_lease.coordination_node_incarnation_id = ?::uuid
                      AND scoped_lease.ready_at IS NOT NULL AND scoped_lease.draining_at IS NULL
                      AND scoped_lease.lease_until > timezone('UTC', clock_timestamp())
                  )
                  """,
                  e.agent_id,
                  e.runtime_owner_generation,
                  type(^session.activation_epoch, :binary_id),
                  type(^session.id, :binary_id)
                )
            )

          _not_ready ->
            where(query, [e], false)
        end

      _blocked ->
        where(query, [e], false)
    end
  end

  defp fetch_llm_effects(lane_slots, lane_order, legacy_llm_cursor) do
    tagged_by_lane =
      Map.new(lane_order, fn lane ->
        lane_limit = Map.get(lane_slots, lane, 0)

        effects =
          if lane_limit > 0 do
            pending_effects_query()
            |> where([e], e.effect_type == "llm_call")
            |> where(
              [e],
              e.execution_lane == ^to_string(lane) or
                (is_nil(e.execution_lane) and
                   fragment(
                     "? ->> '__maraithon_execution_lane' = ?",
                     e.legacy_params,
                     ^to_string(lane)
                   ))
            )
            |> limit(^lane_limit)
            |> Repo.all()
          else
            []
          end

        {lane, effects}
      end)

    {legacy_effects, next_legacy_llm_cursor} =
      if Enum.any?(lane_slots, fn {_lane, count} -> count > 0 end) do
        fetch_legacy_llm_window(legacy_llm_cursor)
      else
        {[], legacy_llm_cursor}
      end

    legacy_by_lane = Enum.group_by(legacy_effects, &effect_execution_lane/1)

    effects_by_lane =
      Map.new(lane_order, fn lane ->
        effects =
          (Map.get(tagged_by_lane, lane, []) ++ Map.get(legacy_by_lane, lane, []))
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
          |> Enum.take(Map.get(lane_slots, lane, 0))

        {lane, effects}
      end)

    {round_robin_lane_effects(effects_by_lane, lane_order), next_legacy_llm_cursor}
  end

  defp fetch_legacy_llm_window(cursor) do
    query = legacy_llm_query_after(cursor)
    effects = Repo.all(query)

    effects =
      if effects == [] and not is_nil(cursor) do
        Repo.all(legacy_llm_query_after(nil))
      else
        effects
      end

    next_cursor =
      case List.last(effects) do
        %Effect{inserted_at: inserted_at, id: id} -> {inserted_at, id}
        nil -> nil
      end

    {effects, next_cursor}
  end

  defp legacy_llm_query_after(cursor) do
    query =
      pending_effects_query()
      |> where([e], e.effect_type == "llm_call")
      |> where(
        [e],
        (is_nil(e.execution_lane) and
           fragment(
             "(? ->> '__maraithon_execution_lane') IS NULL OR (? ->> '__maraithon_execution_lane') NOT IN ('chat', 'reasoning', 'default')",
             e.legacy_params,
             e.legacy_params
           )) or
          e.execution_lane not in ["chat", "reasoning", "default"]
      )

    query =
      case cursor do
        {%DateTime{} = inserted_at, id} when is_binary(id) ->
          where(
            query,
            [e],
            e.inserted_at > ^inserted_at or (e.inserted_at == ^inserted_at and e.id > ^id)
          )

        _no_cursor ->
          query
      end

    limit(query, ^@legacy_llm_scan_limit)
  end

  defp llm_lane_slots(running) do
    status = LLMRateLimiter.status()

    if Map.get(status, :blocked_for_ms, 0) > 0 do
      {Map.new(@llm_lanes, &{&1, 0}), 0}
    else
      running_counts =
        running
        |> Map.values()
        |> Enum.filter(&match?(%Effect{effect_type: "llm_call"}, &1))
        |> Enum.frequencies_by(&effect_execution_lane/1)

      case Map.get(status, :buckets) do
        buckets when is_map(buckets) and map_size(buckets) > 0 ->
          slots =
            Map.new(@llm_lanes, fn lane ->
              bucket = Map.get(buckets, lane, %{})
              limit = positive_count(Map.get(bucket, :max_concurrency, 0))
              limiter_in_flight = non_negative_count(Map.get(bucket, :in_flight, 0))
              runner_in_flight = Map.get(running_counts, lane, 0)
              {lane, max(limit - max(limiter_in_flight, runner_in_flight), 0)}
            end)

          {slots, slots |> Map.values() |> Enum.sum()}

        _missing_bucket_status ->
          limit = positive_count(Map.get(status, :max_concurrency, 1))
          limiter_in_flight = non_negative_count(Map.get(status, :in_flight, 0))
          runner_in_flight = running_counts |> Map.values() |> Enum.sum()
          available = max(limit - max(limiter_in_flight, runner_in_flight), 0)
          {Map.new(@llm_lanes, &{&1, available}), available}
      end
    end
  end

  defp effect_execution_lane(%Effect{execution_lane: lane})
       when lane in ["chat", "reasoning", "default"],
       do: String.to_existing_atom(lane)

  defp effect_execution_lane(%Effect{} = effect) do
    params = effect.params || effect.legacy_params || %{}

    case Map.get(params, @execution_lane_key) do
      "chat" -> :chat
      "reasoning" -> :reasoning
      "default" -> :default
      _legacy_or_invalid -> LLM.execution_bucket(params)
    end
  end

  defp effect_execution_lane(_effect), do: :default

  defp rotate_llm_lanes(cursor) do
    offset = rem(max(cursor, 0), length(@llm_lanes))
    Enum.drop(@llm_lanes, offset) ++ Enum.take(@llm_lanes, offset)
  end

  defp round_robin_lane_effects(effects_by_lane, lane_order) do
    do_round_robin_lane_effects(effects_by_lane, lane_order, [])
  end

  defp do_round_robin_lane_effects(effects_by_lane, lane_order, acc) do
    {round, next_by_lane} =
      Enum.map_reduce(lane_order, effects_by_lane, fn lane, by_lane ->
        case Map.get(by_lane, lane, []) do
          [effect | rest] -> {effect, Map.put(by_lane, lane, rest)}
          [] -> {nil, by_lane}
        end
      end)

    round = Enum.reject(round, &is_nil/1)

    if round == [] do
      Enum.reverse(acc)
    else
      next_acc = Enum.reduce(round, acc, fn effect, current -> [effect | current] end)
      do_round_robin_lane_effects(next_by_lane, lane_order, next_acc)
    end
  end

  defp positive_count(value) when is_integer(value) and value > 0, do: value
  defp positive_count(_value), do: 0

  defp non_negative_count(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_count(_value), do: 0

  defp claim_effect(effect, claim_liveness_ttl_ms) do
    case ProtocolCutover.mode() do
      :exact -> claim_effect_exact(effect, claim_liveness_ttl_ms)
      :legacy -> claim_effect_legacy(effect)
      mode -> {:error, ProtocolCutover.protocol_error(mode)}
    end
  end

  defp claim_effect_exact(effect, claim_liveness_ttl_ms) do
    case Protocol.mode() do
      :dark -> claim_effect_exact_uncoordinated(effect, claim_liveness_ttl_ms)
      :active -> claim_effect_coordinated(effect, claim_liveness_ttl_ms)
      blocked -> {:error, {:runtime_coordination_blocked, blocked}}
    end
  end

  defp claim_effect_exact_uncoordinated(effect, claim_liveness_ttl_ms) do
    claim_token = Ecto.UUID.generate()

    case EffectTaskSupervisor.reserve_legacy(effect.id, effect.agent_id, claim_token) do
      {:ok, identity} ->
        node_id = Atom.to_string(node())
        ttl_ms = min(max(claim_liveness_ttl_ms, 1), 300_000)

        outcome =
          DbResilience.with_database("effect runner claim effect", fn ->
            Repo.transaction(fn ->
              Cancellation.fence_effect_admission!(
                effect.agent_id,
                effect.runtime_owner_generation
              )

              {now, expires_at} = Maraithon.Runtime.DatabaseClock.window!(ttl_ms)

              query =
                from(e in Effect,
                  where: e.id == ^effect.id,
                  where: e.status == "pending",
                  where: is_nil(e.claim_token),
                  where: is_nil(e.cancellation_state),
                  where:
                    is_nil(e.retry_after) or
                      e.retry_after <= fragment("timezone('UTC', clock_timestamp())"),
                  update: [
                    set: [
                      status: "claimed",
                      claimed_by: ^node_id,
                      claimed_at: ^now,
                      claim_token: ^claim_token,
                      claim_owner_node: ^node_id,
                      claim_heartbeat_at: ^now,
                      claim_expires_at: ^expires_at,
                      claim_supervisor_id: ^identity.supervisor_id,
                      claim_task_id: ^identity.task_id,
                      updated_at: ^now
                    ]
                  ],
                  select: e
                )
                |> fence_runtime_owner_lineage(effect)

              Repo.update_all(query, [])
            end)
          end)

        case outcome do
          {:ok, {:ok, {1, [%Effect{} = claimed]}}} ->
            {:ok, claimed}

          {:ok, {:ok, {0, _rows}}} ->
            release_task_identity(identity)
            :already_claimed

          {:ok, {:ok, {_count, _rows}}} ->
            release_task_identity(identity)
            {:error, :unexpected_claim_result}

          {:ok, {:error, reason}} ->
            release_task_identity(identity)
            {:error, reason}

          {:error, reason} ->
            release_task_identity(identity)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_effect_coordinated(effect, claim_liveness_ttl_ms) do
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()

    with {:ok, session, partition} <-
           Scope.partition_for_agent_owner(effect.agent_id, effect.runtime_owner_generation),
         {:ok, physical} <-
           EffectTaskSupervisor.reserve_coordinated(
             effect.id,
             effect.agent_id,
             claim_token,
             assignment_id
           ) do
      identity = %{
        work_kind: "effect",
        work_id: effect.id,
        claim_token: claim_token,
        assignment_id: assignment_id,
        supervisor_id: physical.supervisor_id,
        local_task_id: physical.task_id,
        termination_capability_digest: physical.termination_capability_digest
      }

      node_id = Atom.to_string(node())
      ttl_ms = min(max(claim_liveness_ttl_ms, 1_000), 300_000)

      outcome =
        DbResilience.with_database("effect runner coordinated claim", fn ->
          Repo.transaction(fn ->
            unless Protocol.lock_effect_pair!() == {:active, session.activation_epoch},
              do: Repo.rollback(:coordination_task_authority_lost)

            locked = lock_pending_effect_for_claim!(effect)
            ensure_pending_coordination_scope!(locked, session, partition)

            authority_lease_cap =
              Cancellation.fence_effect_admission_lease_until!(
                locked.agent_id,
                locked.runtime_owner_generation
              )

            assignment =
              case TaskClaims.reserve(session, partition, identity,
                     ttl_ms: ttl_ms,
                     authority_lease_cap: authority_lease_cap
                   ) do
                {:ok,
                 %TaskAssignment{state: "reserved", provider_boundary: "not_entered"} = value} ->
                  value

                {:ok, _mismatched} ->
                  Repo.rollback(:coordination_task_authority_lost)

                {:error, reason} ->
                  Repo.rollback(reason)
              end

            now = Maraithon.Runtime.DatabaseClock.now!()
            expires_at = assignment.lease_expires_at

            query =
              from(e in Effect,
                where: e.id == ^locked.id,
                where: e.status == "pending",
                where: is_nil(e.claim_token),
                where: is_nil(e.cancellation_state),
                update: [
                  set: [
                    status: "claimed",
                    claimed_by: ^node_id,
                    claimed_at: ^now,
                    claim_token: ^claim_token,
                    claim_owner_node: ^node_id,
                    claim_heartbeat_at: ^now,
                    claim_expires_at: ^expires_at,
                    claim_supervisor_id: ^physical.supervisor_id,
                    claim_task_id: ^physical.task_id,
                    coordination_task_assignment_id: ^assignment.id,
                    updated_at: ^now
                  ]
                ],
                select: e
              )
              |> fence_runtime_owner_lineage(locked)

            case Repo.update_all(query, []) do
              {1, [%Effect{} = claimed]} -> claimed
              {0, _rows} -> Repo.rollback(:already_claimed)
              _unexpected -> Repo.rollback(:unexpected_claim_result)
            end
          end)
        end)

      case outcome do
        {:ok, {:ok, %Effect{} = claimed}} ->
          {:ok, claimed}

        {:ok, {:error, :already_claimed}} ->
          release_task_identity(physical)
          :already_claimed

        {:ok, {:error, reason}} ->
          release_task_identity(physical)
          {:error, reason}

        {:error, reason} ->
          # Connection/COMMIT ambiguity is not a definite rollback. Keep the
          # capability under Guardian ownership and converge it as either the
          # committed exact claim (never_activated) or a locked, confirmed
          # uncommitted reservation. Never release the preimage on ambiguity.
          case terminate_ambiguous_task_identity(physical) do
            :ok -> {:error, reason}
            {:error, _handoff_failed} -> exit(:effect_claim_commit_unknown_handoff_failed)
          end
      end
    end
  end

  defp lock_pending_effect_for_claim!(%Effect{} = expected) do
    query =
      from(effect in Effect,
        where: effect.id == ^expected.id,
        where: effect.agent_id == ^expected.agent_id,
        where: effect.status == "pending",
        where: is_nil(effect.claim_token),
        where: is_nil(effect.cancellation_state),
        where:
          is_nil(effect.retry_after) or
            effect.retry_after <= fragment("timezone('UTC', clock_timestamp())"),
        lock: "FOR UPDATE"
      )
      |> fence_runtime_owner_lineage(expected)

    case Repo.one(query) do
      %Effect{} = locked -> locked
      nil -> Repo.rollback(:already_claimed)
    end
  end

  defp ensure_pending_coordination_scope!(effect, session, partition) do
    unless effect.coordination_activation_epoch == session.activation_epoch and
             effect.coordination_partition_id == partition.partition_id and
             effect.coordination_partition_epoch == partition.ownership_epoch and
             effect.coordination_node_incarnation_id == session.id and
             is_nil(effect.coordination_task_assignment_id),
           do: Repo.rollback(:coordination_task_authority_lost)

    :ok
  end

  defp claim_effect_legacy(effect) do
    node_id = Atom.to_string(node())

    case DbResilience.with_database("effect runner claim effect", fn ->
           Repo.transaction(fn ->
             require_legacy_protocol_pair!()

             query =
               from(e in Effect,
                 where: e.id == ^effect.id,
                 where: e.status == "pending",
                 where:
                   is_nil(e.retry_after) or
                     e.retry_after <= fragment("timezone('UTC', NOW())"),
                 update: [
                   set: [
                     status: "claimed",
                     claimed_by: ^node_id,
                     claimed_at: fragment("timezone('UTC', NOW())"),
                     updated_at: fragment("timezone('UTC', NOW())")
                   ]
                 ],
                 select: e
               )
               |> legacy_protocol_rows()

             Repo.update_all(query, [])
           end)
         end) do
      {:ok, {:ok, {1, [%Effect{} = claimed]}}} ->
        {:ok, claimed}

      {:ok, {:ok, {0, _rows}}} ->
        case exact_artifact_for_effect?(effect.id) do
          true -> {:error, {:effect_protocol_mismatch, :exact_artifact}}
          false -> :already_claimed
        end

      {:ok, {:ok, {_count, _rows}}} ->
        {:error, :unexpected_claim_result}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fence_runtime_owner_lineage(query, %Effect{runtime_owner_generation: nil}),
    do: where(query, [candidate], false)

  defp fence_runtime_owner_lineage(query, %Effect{} = effect) do
    from(candidate in query,
      where: candidate.runtime_owner_generation == ^effect.runtime_owner_generation,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM agent_runtime_leases AS effect_owner_lease WHERE effect_owner_lease.agent_id = ? AND effect_owner_lease.owner_token = ? AND effect_owner_lease.ready_at IS NOT NULL AND effect_owner_lease.draining_at IS NULL AND effect_owner_lease.lease_until > timezone('UTC', clock_timestamp()))",
          candidate.agent_id,
          candidate.runtime_owner_generation
        )
    )
  end

  defp task_identity(%Effect{} = effect) do
    identity = %{
      effect_id: effect.id,
      agent_id: effect.agent_id,
      claim_token: effect.claim_token,
      supervisor_id: effect.claim_supervisor_id,
      task_id: effect.claim_task_id
    }

    if is_binary(effect.coordination_task_assignment_id),
      do: Map.put(identity, :assignment_id, effect.coordination_task_assignment_id),
      else: identity
  end

  defp finalize_failed_effect_task_start(%Effect{} = effect) do
    request_failed_start_termination(effect)
  end

  defp request_failed_start_termination(%Effect{} = effect) do
    case Cancellation.prepare_runtime_abort(
           effect.agent_id,
           [effect],
           "effect_task_start_ambiguous"
         ) do
      {:ok, plan} ->
        case Cancellation.execute(plan) do
          {:ok, _summary} -> dispatch_terminal_result(effect, {:error, @ambiguous_outcome})
          _pending_or_failed -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp release_task_identity(identity) do
    case EffectTaskSupervisor.release(identity) do
      :ok ->
        :ok

      _not_definitively_released ->
        case terminate_ambiguous_task_identity(identity) do
          :ok -> :ok
          {:error, _handoff_failed} -> exit(:effect_task_release_handoff_failed)
        end
    end
  rescue
    _error -> exit(:effect_task_release_handoff_failed)
  catch
    :exit, reason -> exit({:effect_task_release_handoff_failed, reason})
  end

  defp terminate_ambiguous_task_identity(identity) do
    case EffectTaskSupervisor.terminate_exact(identity) do
      {:ok, _disposition} -> :ok
      {:unknown, :effect_task_supervisor_unavailable} -> {:error, :authority_unavailable}
      {:error, :effect_task_supervisor_unavailable} -> {:error, :authority_unavailable}
      {:unknown, _retry_owned} -> :ok
      {:error, :effect_task_reservation_lost} -> :ok
      _unexpected -> {:error, :commit_unknown_handoff_refused}
    end
  rescue
    _error -> {:error, :authority_unavailable}
  catch
    :exit, _reason -> {:error, :authority_unavailable}
  end

  defp acknowledge_completed_effect_task(%Effect{claim_token: claim_token} = effect)
       when is_binary(claim_token) do
    identity = task_identity(effect)

    if Map.has_key?(identity, :assignment_id) do
      # The exact immutable assignment is the durable acknowledgement boundary.
      # Retry settlement may intentionally clear every old claim field from the
      # Effect row, so the physical authority must not depend on that mutable row.
      EffectTaskSupervisor.acknowledge_completed(identity)
    else
      case Repo.get(Effect, effect.id) do
        %Effect{status: status} = terminal when status in ["completed", "failed", "cancelled"] ->
          if task_identity(terminal) == identity,
            do: EffectTaskSupervisor.acknowledge_completed(identity),
            else: {:error, :effect_task_identity_mismatch}

        _not_durably_terminal ->
          {:error, :effect_outcome_not_persisted}
      end
    end
  end

  defp acknowledge_completed_effect_task(%Effect{}), do: :ok

  defp register_effect_task!(%Effect{claim_token: claim_token} = effect)
       when is_binary(claim_token) do
    effect
    |> task_identity()
    |> EffectTaskSupervisor.register_current!()
  end

  defp register_effect_task!(%Effect{} = effect) do
    key = {effect.id, effect.claimed_by, effect.claimed_at}

    {:ok, _owner} =
      Registry.register(Maraithon.Runtime.EffectTaskRegistry, key, %{
        agent_id: effect.agent_id,
        effect_id: effect.id
      })

    :ok
  end

  defp start_effect_task(starter, effect, completion_writer, completion_sleeper) do
    case starter.(effect, completion_writer, completion_sleeper) do
      {:bound_task, %Task{} = task} -> {:ok, task}
      %Task{} = task -> bind_started_effect_task(effect, task)
      {:error, _reason} = error -> error
      _unexpected -> {:error, :invalid_effect_task_start}
    end
  rescue
    _error -> {:error, :effect_supervisor_unavailable}
  catch
    _kind, _reason -> {:error, :effect_supervisor_unavailable}
  end

  defp bind_started_effect_task(%Effect{claim_token: claim_token} = effect, %Task{} = task)
       when is_binary(claim_token) do
    case EffectTaskSupervisor.bind_task(task_identity(effect), task.pid) do
      :ok ->
        send(task.pid, {:effect_task_bound, effect.id})
        {:ok, task}

      {:error, reason} ->
        _ = Task.Supervisor.terminate_child(effect_task_supervisor(effect), task.pid)
        {:error, reason}
    end
  end

  defp bind_started_effect_task(%Effect{}, %Task{} = task), do: {:ok, task}

  defp execute_effect_async(
         effect,
         completion_writer,
         completion_sleeper,
         pre_provider_outcome_observer,
         command_prepared_observer
       ) do
    parent = self()
    gate = make_ref()

    task =
      Task.Supervisor.async_nolink(
        effect_task_supervisor(effect),
        fn ->
          receive do
            {:activate_effect_task, ^gate} -> :ok
          after
            5_000 -> exit(:effect_task_bind_timeout)
          end

          register_effect_task!(effect)

          result =
            execute_effect(
              effect,
              completion_writer,
              completion_sleeper,
              pre_provider_outcome_observer,
              command_prepared_observer
            )

          send(
            parent,
            {
              :effect_done,
              effect.id,
              effect.claim_token,
              effect.claimed_by,
              effect.claimed_at,
              result
            }
          )

          :ok
        end,
        shutdown: :brutal_kill
      )

    case effect do
      %Effect{claim_token: claim_token} when is_binary(claim_token) ->
        identity = task_identity(effect)

        case EffectTaskSupervisor.bind_task(identity, task.pid) do
          :ok ->
            send(task.pid, {:activate_effect_task, gate})
            {:bound_task, task}

          {:error, reason} ->
            _ = Task.Supervisor.terminate_child(effect_task_supervisor(effect), task.pid)
            {:error, reason}
        end

      _legacy ->
        send(task.pid, {:activate_effect_task, gate})
        {:bound_task, task}
    end
  end

  defp activate_coordinated_effect_task(%Effect{} = effect) do
    with :ok <- EffectTaskSupervisor.authorize_activation(task_identity(effect)) do
      do_activate_coordinated_effect_task(effect)
    else
      _foreign_or_unbound -> {:error, :coordination_task_authority_lost}
    end
  end

  defp do_activate_coordinated_effect_task(%Effect{} = effect) do
    case {Protocol.mode(), coordination_assignment(effect)} do
      {:dark, :uncoordinated} ->
        :ok

      {:active, {:ok, assignment}} ->
        case Repo.transaction(fn ->
               unless Protocol.lock_effect_pair!() ==
                        {:active, effect.coordination_activation_epoch},
                      do: Repo.rollback(:coordination_task_authority_lost)

               _locked_effect = lock_exact_effect_claim_in_transaction!(effect, ["claimed"])

               TaskClaims.activate_effect_in_transaction!(
                 assignment,
                 effect.agent_id,
                 effect.runtime_owner_generation
               )
             end) do
          {:ok,
           %TaskAssignment{
             state: "running",
             provider_boundary: "not_entered"
           } = active} ->
            if exact_coordination_assignment?(active, assignment),
              do: :ok,
              else: {:error, :coordination_task_authority_lost}

          _lost_or_mismatched ->
            {:error, :coordination_task_authority_lost}
        end

      _mode_or_identity_mismatch ->
        {:error, :coordination_task_authority_lost}
    end
  end

  defp coordination_assignment(%Effect{
         id: work_id,
         claim_token: claim_token,
         claim_supervisor_id: supervisor_id,
         claim_task_id: local_task_id,
         coordination_activation_epoch: activation_epoch,
         coordination_partition_id: partition_id,
         coordination_partition_epoch: partition_epoch,
         coordination_node_incarnation_id: node_incarnation_id,
         coordination_task_assignment_id: assignment_id
       })
       when is_binary(work_id) and is_binary(claim_token) and is_binary(supervisor_id) and
              is_binary(local_task_id) and is_binary(activation_epoch) and
              is_integer(partition_id) and is_integer(partition_epoch) and
              is_binary(node_incarnation_id) and is_binary(assignment_id) do
    {:ok,
     %TaskAssignment{
       id: assignment_id,
       activation_epoch: activation_epoch,
       work_kind: "effect",
       work_id: work_id,
       claim_token: claim_token,
       partition_id: partition_id,
       partition_epoch: partition_epoch,
       node_incarnation_id: node_incarnation_id,
       supervisor_id: supervisor_id,
       local_task_id: local_task_id
     }}
  end

  defp coordination_assignment(%Effect{
         coordination_activation_epoch: nil,
         coordination_partition_id: nil,
         coordination_partition_epoch: nil,
         coordination_node_incarnation_id: nil,
         coordination_task_assignment_id: nil
       }),
       do: :uncoordinated

  defp coordination_assignment(%Effect{}), do: :mismatched

  defp lock_exact_effect_claim_in_transaction!(%Effect{} = expected, statuses)
       when is_list(statuses) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "exact Effect lock requires transaction")

    query =
      from(stored in Effect,
        where: stored.id == ^expected.id,
        where: stored.agent_id == ^expected.agent_id,
        where: stored.status in ^statuses,
        where: stored.claimed_by == ^expected.claimed_by,
        where: stored.claimed_at == ^expected.claimed_at,
        where: stored.claim_token == ^expected.claim_token,
        where: stored.claim_owner_node == ^expected.claim_owner_node,
        where: stored.claim_supervisor_id == ^expected.claim_supervisor_id,
        where: stored.claim_task_id == ^expected.claim_task_id,
        where: stored.runtime_owner_generation == ^expected.runtime_owner_generation,
        where:
          fragment(
            "? IS NOT DISTINCT FROM ?",
            stored.coordination_activation_epoch,
            type(^expected.coordination_activation_epoch, :binary_id)
          ),
        where:
          fragment(
            "? IS NOT DISTINCT FROM ?",
            stored.coordination_partition_id,
            type(^expected.coordination_partition_id, :integer)
          ),
        where:
          fragment(
            "? IS NOT DISTINCT FROM ?",
            stored.coordination_partition_epoch,
            type(^expected.coordination_partition_epoch, :integer)
          ),
        where:
          fragment(
            "? IS NOT DISTINCT FROM ?",
            stored.coordination_node_incarnation_id,
            type(^expected.coordination_node_incarnation_id, :binary_id)
          ),
        where:
          fragment(
            "? IS NOT DISTINCT FROM ?",
            stored.coordination_task_assignment_id,
            type(^expected.coordination_task_assignment_id, :binary_id)
          ),
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      %Effect{} = locked -> locked
      nil -> Repo.rollback(:effect_claim_lost)
    end
  end

  defp exact_coordination_assignment?(actual, expected) do
    fields = [
      :id,
      :activation_epoch,
      :work_kind,
      :work_id,
      :claim_token,
      :partition_id,
      :partition_epoch,
      :node_incarnation_id,
      :supervisor_id,
      :local_task_id
    ]

    Map.take(actual, fields) == Map.take(expected, fields)
  end

  defp execute_effect(
         effect,
         completion_writer,
         completion_sleeper,
         pre_provider_outcome_observer,
         command_prepared_observer
       ) do
    Logger.info("Executing effect",
      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
      effect_type: effect.effect_type
    )

    result =
      try do
        execute_with_command(effect, command_prepared_observer)
      rescue
        exception ->
          {:error, {:effect_exception, Maraithon.Redaction.error_class(exception)}}
      catch
        kind, _value ->
          {:error, {:effect_exception, to_string(kind)}}
      end

    case result do
      {:ok, data} ->
        case Maraithon.Effects.prepare_result(data) do
          {:ok, bounded_data} ->
            case persist_completed(
                   effect,
                   bounded_data,
                   completion_writer,
                   completion_sleeper
                 ) do
              :ok ->
                dispatch_terminal_result(effect, {:ok, bounded_data})
                {:ok, bounded_data}

              :claim_lost ->
                {:error, @ambiguous_outcome}

              {:ambiguous, :persisted} ->
                dispatch_terminal_result(effect, {:error, @ambiguous_outcome})
                {:error, @ambiguous_outcome}

              {:ambiguous, :unpersisted} ->
                {:error, @ambiguous_outcome}
            end

          {:error, :invalid_effect_result} ->
            # The command already returned success, so the external operation
            # may have completed even though its result cannot be durably
            # encoded. Never advertise this as a safe-to-repeat failure.
            reason = @ambiguous_outcome
            attempts = effect.attempts + 1

            Logger.warning("Effect result rejected before persistence",
              effect_reference: Maraithon.Redaction.fingerprint(effect.id),
              effect_type: effect.effect_type,
              failure_code: "invalid_effect_result"
            )

            case coordinated_ambiguity_exit!(effect, :invalid_effect_result) do
              :uncoordinated ->
                case mark_failed(effect, reason, attempts) do
                  :ok -> dispatch_terminal_result(effect, {:error, reason})
                  :claim_lost -> :ok
                  {:error, _reason} -> :ok
                end

                {:error, reason}
            end
        end

      {:error, reason} ->
        reason = classify_claimed_error(effect, reason)
        attempts = next_attempt_count(effect, reason)

        if reason == @ambiguous_outcome do
          coordinated_ambiguity_exit!(effect, :provider_outcome_ambiguous)
        end

        persistence_disposition =
          if should_retry?(effect, reason, attempts) do
            mark_pending_retry(effect, reason, attempts)
          else
            disposition = mark_failed(effect, reason, attempts)

            case disposition do
              :ok -> dispatch_terminal_result(effect, {:error, reason})
              :termination_pending -> :ok
              :claim_lost -> :ok
              {:error, _reason} -> :ok
            end

            disposition
          end

        observe_pre_provider_outcome(
          effect,
          persistence_disposition,
          pre_provider_outcome_observer
        )

        {:error, reason}
    end
  end

  defp observe_pre_provider_outcome(effect, :termination_pending, observer)
       when is_function(observer, 2) do
    observer.(effect, :termination_pending)
  end

  defp observe_pre_provider_outcome(_effect, _disposition, _observer), do: :ok

  defp observe_prepared_command(effect, command_module, prepared, observer)
       when is_function(observer, 3),
       do: observer.(effect, command_module, prepared)

  defp execute_with_command(effect, command_prepared_observer) do
    effect = Effect.materialize_legacy_payload(effect)

    with {:ok, command_module} <- CommandFactory.fetch(effect.effect_type),
         {:ok, prepared} <- command_module.prepare(effect),
         :ok <-
           observe_prepared_command(
             effect,
             command_module,
             prepared,
             command_prepared_observer
           ),
         :ok <- activate_coordinated_effect_task(effect),
         :ok <- authorize_effect_claim(effect, command_module, prepared) do
      command_module.execute_prepared(effect, prepared)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_effect_claim(
         %Effect{
           id: effect_id,
           agent_id: agent_id,
           agent_run_id: nil,
           claimed_by: claimed_by,
           claimed_at: claimed_at
         } = effect,
         command_module,
         prepared
       )
       when is_atom(command_module) and is_binary(claimed_by) and not is_nil(claimed_at) do
    authorized? =
      from(stored in Effect,
        join: agent in Agent,
        on: agent.id == stored.agent_id,
        where: stored.id == ^effect_id,
        where: stored.agent_id == ^agent_id,
        where: stored.status == "claimed",
        where: stored.claimed_by == ^claimed_by,
        where: stored.claimed_at == ^claimed_at,
        where: agent.status in ["running", "degraded"],
        where: agent.install_status == "enabled"
      )
      |> authorize_effect_owner(effect, :without_run)
      |> authorize_effect_protocol(effect)
      |> fence_claim_identity(effect)
      |> claim_authorized_at_entry?(effect, command_module, prepared)

    if authorized?, do: :ok, else: {:error, :stale_effect_context}
  end

  defp authorize_effect_claim(
         %Effect{
           id: effect_id,
           agent_id: agent_id,
           agent_run_id: run_id,
           agent_run_step_id: step_id,
           claimed_by: claimed_by,
           claimed_at: claimed_at
         } = effect,
         command_module,
         prepared
       )
       when is_atom(command_module) and is_binary(run_id) and is_binary(step_id) and
              is_binary(claimed_by) and not is_nil(claimed_at) do
    continuation_authorized? =
      not is_nil(effect.runtime_owner_generation) or
        current_continuation?(agent_id, run_id, effect_id)

    if continuation_authorized? do
      authorized? =
        from(stored in Effect,
          join: run in AgentRun,
          on: run.id == stored.agent_run_id,
          join: step in AgentRunStep,
          on: step.id == stored.agent_run_step_id and step.agent_run_id == run.id,
          join: agent in Agent,
          on: agent.id == stored.agent_id and agent.id == run.agent_id,
          where: stored.id == ^effect_id,
          where: stored.agent_id == ^agent_id,
          where: stored.status == "claimed",
          where: stored.claimed_by == ^claimed_by,
          where: stored.claimed_at == ^claimed_at,
          where: run.id == ^run_id and run.status == "running",
          where: agent.active_run_id == run.id,
          where: step.id == ^step_id and step.agent_id == ^agent_id,
          where: step.status == "requested",
          where: agent.status in ["running", "degraded"],
          where: agent.install_status == "enabled"
        )
        |> authorize_effect_owner(effect, :with_run)
        |> authorize_effect_protocol(effect)
        |> fence_claim_identity(effect)
        |> claim_authorized_at_entry?(effect, command_module, prepared)

      if authorized?, do: :ok, else: {:error, :stale_effect_context}
    else
      {:error, :stale_effect_context}
    end
  end

  defp authorize_effect_claim(_effect, _command_module, _prepared),
    do: {:error, :stale_effect_context}

  defp authorize_effect_owner(
         query,
         %Effect{runtime_owner_generation: nil, owner_user_id: nil},
         :without_run
       ) do
    where(query, [stored, _agent], is_nil(stored.owner_user_id))
  end

  defp authorize_effect_owner(query, %Effect{owner_user_id: owner_user_id}, :without_run) do
    where(
      query,
      [stored, agent],
      fragment("? IS NOT DISTINCT FROM ?", stored.owner_user_id, ^owner_user_id) and
        fragment("? IS NOT DISTINCT FROM ?", agent.user_id, ^owner_user_id)
    )
  end

  defp authorize_effect_owner(
         query,
         %Effect{runtime_owner_generation: nil, owner_user_id: nil},
         :with_run
       ) do
    where(
      query,
      [stored, run, _step, agent],
      is_nil(stored.owner_user_id) and
        fragment("? IS NOT DISTINCT FROM ?", run.user_id, agent.user_id)
    )
  end

  defp authorize_effect_owner(query, %Effect{owner_user_id: owner_user_id}, :with_run) do
    where(
      query,
      [stored, run, _step, agent],
      fragment("? IS NOT DISTINCT FROM ?", stored.owner_user_id, ^owner_user_id) and
        fragment("? IS NOT DISTINCT FROM ?", run.user_id, ^owner_user_id) and
        fragment("? IS NOT DISTINCT FROM ?", agent.user_id, ^owner_user_id)
    )
  end

  defp authorize_effect_protocol(query, %Effect{runtime_owner_generation: nil} = effect) do
    protocol_version =
      effect.effect_protocol_version ||
        if(is_map(effect.params), do: Map.get(effect.params, "__maraithon_effect_protocol"))

    if protocol_version == 2 do
      where(
        query,
        [stored],
        is_nil(stored.effect_protocol_version) or stored.effect_protocol_version == 2
      )
    else
      where(query, [stored], false)
    end
  end

  defp authorize_effect_protocol(query, %Effect{}) do
    where(query, [stored], stored.effect_protocol_version == 2)
  end

  # This exact CAS is the final authoritative pre-command boundary. It prevents
  # a cancellation committed before activation from reaching provider code; a
  # cancellation racing after the CAS is still conservatively ambiguous.
  defp claim_authorized_at_entry?(query, effect, command_module, prepared) do
    # Caller/PID authorization happens before any database lock. The claim
    # transaction's transaction-local writer marker is gone before this
    # supervised task starts, so the DB boundary then re-enters the canonical
    # protocol and lifecycle lock prefix.
    with :ok <- authorize_effect_task_entry(effect) do
      case Repo.transaction(fn ->
             protocol_pair = Protocol.lock_effect_pair!()

             {now, entry_updates} =
               case {legacy_effect_struct?(effect), protocol_pair} do
                 {true, :legacy} ->
                   {Maraithon.Runtime.DatabaseClock.now!(), []}

                 {false, {:active, epoch}}
                 when epoch == effect.coordination_activation_epoch ->
                   locked = lock_exact_effect_claim_in_transaction!(effect, ["claimed"])

                   now =
                     lock_exact_command_authority!(
                       locked,
                       command_module,
                       prepared
                     )

                   {now, enter_coordination_provider_boundary!(locked)}

                 _mismatched_pair ->
                   Repo.rollback(:coordination_task_authority_lost)
               end

             Repo.update_all(query, set: Keyword.put(entry_updates, :updated_at, now))
           end) do
        {:ok, {1, _rows}} -> true
        _lost_or_unavailable -> false
      end
    else
      _foreign_or_unbound -> false
    end
  rescue
    _database_or_protocol_failure -> false
  catch
    :exit, _reason -> false
  end

  defp authorize_effect_task_entry(%Effect{claim_token: claim_token} = effect)
       when is_binary(claim_token),
       do: EffectTaskSupervisor.authorize_activation(task_identity(effect))

  defp authorize_effect_task_entry(%Effect{}), do: :ok

  defp enter_coordination_provider_boundary!(%Effect{} = effect) do
    case coordination_assignment(effect) do
      {:ok, assignment} ->
        case TaskClaims.enter_effect_provider_in_transaction!(
               assignment,
               effect.agent_id,
               effect.runtime_owner_generation
             ) do
          %TaskAssignment{
            state: "running",
            provider_boundary: "entered"
          } = entered ->
            unless exact_coordination_assignment?(entered, assignment),
              do: Repo.rollback(:coordination_task_authority_lost)

            [status: "executing"]

          _mismatched ->
            Repo.rollback(:coordination_task_authority_lost)
        end

      _uncoordinated_or_mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp lock_exact_command_authority!(effect, command_module, prepared) do
    agent =
      Repo.one(
        from(agent in Agent,
          where: agent.id == ^effect.agent_id,
          lock: "FOR UPDATE"
        )
      )

    unless match?(%Agent{}, agent) and agent.status in ["running", "degraded"] and
             agent.install_status == "enabled" and
             agent.user_id == effect.owner_user_id do
      Repo.rollback(:stale_effect_context)
    end

    binding =
      Repo.one(
        from(binding in Binding,
          where: binding.agent_id == ^effect.agent_id,
          where: binding.user_id == ^effect.owner_user_id,
          where: binding.status == "active",
          lock: "FOR UPDATE"
        )
      )

    unless match?(%Binding{}, binding), do: Repo.rollback(:stale_effect_context)

    guard =
      Repo.one(
        from(guard in AgentRestartGuard,
          where: guard.agent_id == ^effect.agent_id,
          lock: "FOR UPDATE"
        )
      )

    lease =
      Repo.one(
        from(lease in AgentRuntimeLease,
          where: lease.agent_id == ^effect.agent_id,
          lock: "FOR UPDATE"
        )
      )

    operation =
      Repo.one(
        from(operation in AgentLifecycleOperation,
          where: operation.agent_id == ^effect.agent_id,
          lock: "FOR UPDATE"
        )
      )

    if operation, do: Repo.rollback(:stale_effect_context)
    directive = lock_exact_command_lineage!(effect, agent)
    now = Maraithon.Runtime.DatabaseClock.now!()

    if guard &&
         (guard.tripped or guard.needs_recovery or
            (guard.blocked_until && DateTime.compare(guard.blocked_until, now) == :gt)) do
      Repo.rollback(:stale_effect_context)
    end

    unless match?(%AgentRuntimeLease{}, lease) and
             lease.owner_token == effect.runtime_owner_generation and
             not is_nil(lease.ready_at) and is_nil(lease.draining_at) and
             DateTime.compare(lease.lease_until, now) == :gt do
      Repo.rollback(:stale_effect_context)
    end

    if directive &&
         (is_nil(directive.claim_expires_at) or
            DateTime.compare(directive.claim_expires_at, now) != :gt) do
      Repo.rollback(:stale_effect_context)
    end

    revalidate_prepared_command_authority!(
      command_module,
      effect,
      prepared,
      agent,
      binding
    )

    now
  end

  defp revalidate_prepared_command_authority!(
         command_module,
         effect,
         prepared,
         agent,
         binding
       ) do
    if function_exported?(command_module, :revalidate_prepared_authority, 3) do
      case apply(command_module, :revalidate_prepared_authority, [
             effect,
             prepared,
             %{agent: agent, binding: binding}
           ]) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
        _invalid -> Repo.rollback(:stale_effect_context)
      end
    else
      :ok
    end
  end

  defp lock_exact_command_lineage!(%Effect{agent_run_id: nil}, _agent), do: nil

  defp lock_exact_command_lineage!(
         %Effect{agent_run_id: run_id, agent_run_step_id: step_id} = effect,
         agent
       )
       when is_binary(run_id) and is_binary(step_id) do
    directive =
      Repo.one(
        from(directive in AgentDirective,
          where: directive.agent_id == ^effect.agent_id,
          where: directive.status == "processing",
          where: directive.active_run_id == ^run_id,
          where: directive.claimed_by_generation == ^effect.runtime_owner_generation,
          where: not is_nil(directive.claim_token),
          lock: "FOR UPDATE"
        )
      )

    unless match?(%AgentDirective{}, directive), do: Repo.rollback(:stale_effect_context)

    run =
      Repo.one(
        from(run in AgentRun,
          where: run.id == ^run_id,
          where: run.agent_id == ^effect.agent_id,
          where: run.user_id == ^effect.owner_user_id,
          where: run.status == "running",
          lock: "FOR UPDATE"
        )
      )

    unless match?(%AgentRun{}, run) and agent.active_run_id == run_id,
      do: Repo.rollback(:stale_effect_context)

    step =
      Repo.one(
        from(step in AgentRunStep,
          where: step.id == ^step_id,
          where: step.agent_run_id == ^run_id,
          where: step.agent_id == ^effect.agent_id,
          where: step.status == "requested",
          lock: "FOR UPDATE"
        )
      )

    unless match?(%AgentRunStep{}, step), do: Repo.rollback(:stale_effect_context)
    directive
  end

  defp lock_exact_command_lineage!(_effect, _agent),
    do: Repo.rollback(:stale_effect_context)

  defp current_continuation?(agent_id, run_id, effect_id) do
    case :global.whereis_name({:maraithon_agent, agent_id}) do
      pid when is_pid(pid) ->
        case :sys.get_state(pid, @continuation_check_timeout_ms) do
          {:waiting_effect, %{current_run_id: ^run_id, pending_effects: pending_effects}}
          when is_map(pending_effects) ->
            Map.has_key?(pending_effects, effect_id)

          _other_state ->
            false
        end

      :undefined ->
        false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp persist_completed(
         effect,
         result,
         completion_writer,
         completion_sleeper,
         attempt \\ 0
       ) do
    case safe_completion_write(completion_writer, effect, result) do
      :ok ->
        :ok

      :claim_lost ->
        :claim_lost

      {:error, _reason} when attempt + 1 < @completion_write_attempts ->
        delay_ms =
          DbResilience.backoff_ms(
            @completion_write_backoff_ms,
            attempt,
            @completion_write_backoff_cap_ms
          )

        safe_completion_sleep(completion_sleeper, delay_ms)

        persist_completed(
          effect,
          result,
          completion_writer,
          completion_sleeper,
          attempt + 1
        )

      {:error, _reason} ->
        Logger.warning("Effect completion persistence exhausted",
          effect_reference: Maraithon.Redaction.fingerprint(effect.id),
          failure_code: "effect_outcome_ambiguous"
        )

        case coordinated_ambiguity_exit!(effect, :effect_completion_persistence_uncertain) do
          :uncoordinated ->
            case finalize_ambiguous_claim(effect) do
              :ok -> {:ambiguous, :persisted}
              :claim_lost -> :claim_lost
              {:error, _reason} -> {:ambiguous, :unpersisted}
            end
        end
    end
  end

  defp safe_completion_write(writer, effect, result) do
    case writer.(effect, result) do
      outcome when outcome in [:ok, :claim_lost] -> outcome
      {:error, _reason} = error -> error
      _outcome -> {:error, :invalid_completion_write_result}
    end
  rescue
    _error -> {:error, :completion_write_failed}
  catch
    _kind, _reason -> {:error, :completion_write_failed}
  end

  defp safe_completion_sleep(sleeper, delay_ms) do
    sleeper.(delay_ms)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp mark_completed(effect, result) do
    case update_claimed_effect(effect, "mark completed",
           status: "completed",
           result: result,
           legacy_result: if(legacy_effect_struct?(effect), do: result, else: nil),
           result_envelope: TerminalEnvelope.success(),
           error: nil,
           last_failure_code: nil,
           last_failure_attempt: nil,
           retry_after: nil,
           completion_claimed_by: effect.claimed_by,
           completion_claimed_at: effect.claimed_at,
           result_dispatched_at: nil,
           result_dispatch_after: nil,
           result_dispatch_attempts: 0,
           result_acknowledged_at: nil,
           claimed_by: nil,
           claimed_at: nil
         ) do
      :claim_lost -> completion_persisted_for_claim(effect)
      outcome -> outcome
    end
  end

  defp completion_persisted_for_claim(%Effect{} = effect) do
    case DbResilience.with_database("effect runner verify completed claim", fn ->
           from(completed in Effect,
             where: completed.id == ^effect.id,
             where: completed.status == "completed",
             where: completed.completion_claimed_by == ^effect.claimed_by,
             where: completed.completion_claimed_at == ^effect.claimed_at
           )
           |> fence_terminal_claim_identity(effect)
           |> Repo.exists?()
         end) do
      {:ok, true} -> :ok
      {:ok, false} -> :claim_lost
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_pending_retry(effect, reason, attempts) do
    case ProtocolCutover.mode() do
      mode when mode in [:exact, :legacy] ->
        backoff_ms = calculate_backoff(attempts, reason)
        retry_after = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

        fields =
          [
            status: "pending",
            claimed_by: nil,
            claimed_at: nil,
            claim_token: nil,
            claim_owner_node: nil,
            claim_heartbeat_at: nil,
            claim_expires_at: nil,
            claim_supervisor_id: nil,
            claim_task_id: nil,
            coordination_task_assignment_id: nil,
            cancellation_state: nil,
            cancellation_reason: nil,
            cancellation_requested_at: nil,
            cancellation_target_claim_token: nil,
            cancellation_last_attempt_at: nil,
            cancellation_last_error: nil,
            cancellation_settled_at: nil,
            attempts: attempts,
            retry_after: retry_after,
            error: Maraithon.Redaction.error_summary(reason)
          ] ++ counted_failure_provenance(effect, reason, attempts)

        update_claimed_effect_for_retry(effect, "mark retry", fields)

      {:blocked, mismatch} ->
        {:error, {:effect_protocol_mismatch, mismatch}}
    end
  end

  defp mark_failed(effect, reason, attempts) do
    fields =
      [
        status: "failed",
        error: Maraithon.Redaction.error_summary(reason),
        result_envelope: TerminalEnvelope.error(reason),
        attempts: attempts,
        retry_after: nil,
        result_dispatched_at: nil,
        result_dispatch_after: nil,
        result_dispatch_attempts: 0,
        result_acknowledged_at: nil,
        claimed_by: nil,
        claimed_at: nil
      ] ++ failure_provenance(reason, attempts)

    update_claimed_effect(effect, "mark failed", fields)
  end

  defp counted_failure_provenance(%Effect{attempts: previous}, reason, attempts)
       when is_integer(previous) and is_integer(attempts) and attempts > previous,
       do: failure_provenance(reason, attempts)

  defp counted_failure_provenance(_effect, _reason, _attempts), do: []

  defp failure_provenance(:timeout, attempts) when is_integer(attempts) and attempts >= 0,
    do: [last_failure_code: "timeout", last_failure_attempt: attempts]

  defp failure_provenance(_reason, _attempts),
    do: [last_failure_code: nil, last_failure_attempt: nil]

  defp finalize_effect_task_down(%Effect{} = effect) do
    case coordination_assignment(effect) do
      {:ok, _assignment} ->
        case reconcile_effect_after_task_down(effect) do
          :terminal ->
            :terminal

          :active ->
            with {:ok, plan} <-
                   Cancellation.prepare_runtime_abort(
                     effect.agent_id,
                     [effect],
                     "effect_task_exited_without_outcome"
                   ),
                 {:ok, _summary} <- Cancellation.execute(plan) do
              :ok
            else
              {:pending, _summary} -> {:error, :effect_task_termination_unproven}
              {:error, reason} -> {:error, reason}
            end

          :claim_lost ->
            :claim_lost

          {:error, reason} ->
            {:error, reason}
        end

      :uncoordinated ->
        finalize_ambiguous_claim(effect)

      :mismatched ->
        {:error, :coordination_task_authority_lost}
    end
  end

  defp reconcile_effect_after_task_down(%Effect{} = expected) do
    case Repo.transaction(fn ->
           unless Protocol.lock_effect_pair!() ==
                    {:active, expected.coordination_activation_epoch},
                  do: Repo.rollback(:coordination_task_authority_lost)

           stored = lock_effect_after_task_down(expected)

           case stored.status do
             status when status in ["completed", "failed", "cancelled"] ->
               converge_terminal_coordination!(stored)
               :terminal

             status when status in ["claimed", "executing", "cancelling"] ->
               :active

             _pending_or_replaced ->
               :claim_lost
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp lock_effect_after_task_down(%Effect{} = expected) do
    query =
      from(stored in Effect,
        where: stored.id == ^expected.id,
        where: stored.agent_id == ^expected.agent_id,
        where: stored.claim_token == ^expected.claim_token,
        where: stored.claim_owner_node == ^expected.claim_owner_node,
        where: stored.claim_supervisor_id == ^expected.claim_supervisor_id,
        where: stored.claim_task_id == ^expected.claim_task_id,
        where: stored.runtime_owner_generation == ^expected.runtime_owner_generation,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      %Effect{} = stored -> stored
      nil -> Repo.rollback(:effect_claim_lost)
    end
  end

  defp converge_terminal_coordination!(%Effect{} = effect) do
    case {Protocol.mode(), coordination_assignment(effect), canonical_assignment_outcome(effect)} do
      {:dark, :uncoordinated, _outcome} ->
        :ok

      {:active, {:ok, assignment}, {:settled, outcome}} ->
        case TaskClaims.settle_effect_in_transaction(
               assignment,
               effect.agent_id,
               effect.runtime_owner_generation,
               outcome
             ) do
          %TaskAssignment{state: "settled", outcome: ^outcome} = settled ->
            unless exact_coordination_assignment?(settled, assignment),
              do: Repo.rollback(:coordination_task_settlement_lost)

            :ok

          %TaskAssignment{state: "outcome_ambiguous"} ->
            # The Effect is already canonical and immutable. Preserve it rather
            # than downgrading known content to an ambiguity marker.
            :ok

          _mismatched ->
            Repo.rollback(:coordination_task_settlement_lost)
        end

      {:active, {:ok, assignment}, :outcome_ambiguous} ->
        case TaskClaims.lock_effect_assignment_in_transaction!(assignment) do
          %TaskAssignment{
            state: "outcome_ambiguous",
            outcome: "provider_outcome_ambiguous"
          } = ambiguous ->
            unless exact_coordination_assignment?(ambiguous, assignment),
              do: Repo.rollback(:coordination_task_settlement_lost)

            :ok

          %TaskAssignment{state: "settled", outcome: "failed"} ->
            # A durable known result is stronger than a later crash signal.
            :ok

          _not_yet_converged ->
            Repo.rollback(:coordination_task_settlement_lost)
        end

      _mode_or_identity_mismatch ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp canonical_assignment_outcome(%Effect{status: "completed"}), do: {:settled, "completed"}

  defp canonical_assignment_outcome(%Effect{
         status: "failed",
         error: "effect_outcome_ambiguous"
       }),
       do: :outcome_ambiguous

  defp canonical_assignment_outcome(%Effect{status: "failed"}), do: {:settled, "failed"}

  defp canonical_assignment_outcome(%Effect{status: "cancelled"}),
    do: {:settled, "cancelled_before_provider"}

  defp finalize_ambiguous_claim(effect) do
    update_claimed_effect(effect, "mark ambiguous outcome",
      status: "failed",
      result: nil,
      error: "effect_outcome_ambiguous",
      last_failure_code: nil,
      last_failure_attempt: nil,
      result_envelope: TerminalEnvelope.error(@ambiguous_outcome),
      retry_after: nil,
      result_dispatched_at: nil,
      result_dispatch_after: nil,
      result_dispatch_attempts: 0,
      result_acknowledged_at: nil,
      claimed_by: nil,
      claimed_at: nil
    )
  end

  # A worker may finish after its claim was cancelled or reclaimed. Fence every
  # terminal/retry write by the exact claim generation so stale work cannot
  # overwrite the newer status or notify an unrelated Agent incarnation.
  defp update_claimed_effect_for_retry(
         %Effect{claimed_by: claimed_by, claimed_at: claimed_at} = effect,
         operation,
         updates
       )
       when is_binary(claimed_by) and not is_nil(claimed_at) do
    case DbResilience.with_database("effect runner #{operation}", fn ->
           Repo.transaction(fn ->
             require_effect_protocol_pair!(effect)
             locked = lock_effect_before_outcome!(effect)

             disposition =
               settle_coordinated_effect_in_transaction!(locked, "retry_scheduled")

             now = Maraithon.Runtime.DatabaseClock.now!()

             {result_kind, updates} =
               case disposition do
                 :settled ->
                   {:settled, Keyword.put(updates, :updated_at, now)}

                 :termination_proof_required ->
                   {:termination_pending,
                    preactivation_outcome_intent_updates(locked, updates, :retry, now)}
               end

             result = Repo.update_all(claimed_effect_query(effect, locked.status), set: updates)

             if not match?({1, _rows}, result), do: Repo.rollback(:effect_claim_lost)
             {result_kind, result}
           end)
         end) do
      {:ok, {:ok, {:settled, {1, _rows}}}} ->
        :ok

      {:ok, {:ok, {:termination_pending, {1, _rows}}}} ->
        :termination_pending

      {:ok, {:ok, {_kind, {0, _rows}}}} ->
        Logger.info("Discarded late effect retry after claim ownership changed",
          effect_reference: Maraithon.Redaction.fingerprint(effect.id),
          failure_code: "claim_lost"
        )

        :claim_lost

      {:ok, {:error, :effect_claim_lost}} ->
        :claim_lost

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, :effect_claim_lost} ->
        :claim_lost

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_claimed_effect_for_retry(%Effect{} = effect, _operation, _updates) do
    Logger.warning("Discarded effect retry without claim ownership",
      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
      failure_code: "claim_lost"
    )

    :claim_lost
  end

  defp update_claimed_effect(
         %Effect{claimed_by: claimed_by, claimed_at: claimed_at} = effect,
         operation,
         updates
       )
       when is_binary(claimed_by) and not is_nil(claimed_at) do
    case DbResilience.with_database("effect runner #{operation}", fn ->
           Repo.transaction(fn ->
             require_effect_protocol_pair!(effect)
             locked = lock_effect_before_outcome!(effect)
             outcome = terminal_coordination_outcome!(updates)
             disposition = settle_coordinated_effect_in_transaction!(locked, outcome)
             now = Maraithon.Runtime.DatabaseClock.now!()

             {result_kind, updates} =
               case disposition do
                 :settled ->
                   updates =
                     locked
                     |> put_terminal_payload_binding!(updates)
                     |> Keyword.put(:updated_at, now)

                   {:settled, updates}

                 :termination_proof_required ->
                   {:termination_pending,
                    preactivation_outcome_intent_updates(locked, updates, :failure, now)}
               end

             result = Repo.update_all(claimed_effect_query(effect, locked.status), set: updates)

             if not match?({1, _rows}, result), do: Repo.rollback(:effect_claim_lost)
             {result_kind, result}
           end)
         end) do
      {:ok, {:ok, {:settled, {1, _rows}}}} ->
        :ok

      {:ok, {:ok, {:termination_pending, {1, _rows}}}} ->
        :termination_pending

      {:ok, {:ok, {_kind, {0, _rows}}}} ->
        Logger.info("Discarded late effect result after claim ownership changed",
          effect_reference: Maraithon.Redaction.fingerprint(effect.id),
          failure_code: "claim_lost"
        )

        :claim_lost

      {:ok, {:error, :effect_claim_lost}} ->
        :claim_lost

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, :effect_claim_lost} ->
        :claim_lost

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_claimed_effect(%Effect{} = effect, _operation, _updates) do
    Logger.warning("Discarded effect result without claim ownership",
      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
      failure_code: "claim_lost"
    )

    :claim_lost
  end

  defp preactivation_outcome_intent_updates(
         %Effect{} = locked,
         terminal_updates,
         intent,
         now
       )
       when intent in [:failure, :retry] and is_list(terminal_updates) do
    error_code =
      terminal_updates
      |> Keyword.get(:error, "unknown_error")
      |> Cancellation.pre_provider_error_code()

    attempts =
      case Keyword.get(terminal_updates, :attempts, locked.attempts) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> locked.attempts
      end

    reason =
      case intent do
        :failure -> Cancellation.pre_provider_failure_reason(error_code)
        :retry -> Cancellation.pre_provider_retry_reason(error_code)
      end

    intended_failure_code =
      Keyword.get(terminal_updates, :last_failure_code, locked.last_failure_code)

    intended_failure_attempt =
      Keyword.get(terminal_updates, :last_failure_attempt, locked.last_failure_attempt)

    result_envelope =
      case intent do
        :failure ->
          Cancellation.pre_provider_failure_envelope(
            Keyword.fetch!(terminal_updates, :result_envelope),
            attempts,
            intended_failure_code,
            intended_failure_attempt
          )

        :retry ->
          Cancellation.pre_provider_retry_envelope(
            error_code,
            attempts,
            intended_failure_code,
            intended_failure_attempt
          )
      end

    base = [
      status: "cancelling",
      cancellation_state: "requested",
      cancellation_reason: reason,
      cancellation_requested_at: now,
      cancellation_target_claim_token: locked.claim_token,
      cancellation_last_attempt_at: nil,
      cancellation_last_error: nil,
      cancellation_settled_at: nil,
      attempts: attempts,
      last_failure_code: Cancellation.pre_provider_intent_marker(),
      last_failure_attempt: attempts,
      error: error_code,
      result_envelope: result_envelope,
      updated_at: now
    ]

    case Keyword.fetch(terminal_updates, :retry_after) do
      {:ok, value} -> Keyword.put(base, :retry_after, value)
      :error -> base
    end
  end

  defp put_terminal_payload_binding!(%Effect{} = locked, updates) when is_list(updates) do
    spec = Effect.payload_binding_spec()

    binding_row =
      Enum.reduce(Map.fetch!(spec, :fields), locked, fn field, row ->
        case Keyword.fetch(updates, field) do
          {:ok, value} -> Map.put(row, field, value)
          :error -> row
        end
      end)

    binding_attrs = DurablePayload.binding_attrs!(binding_row, spec)
    Keyword.merge(updates, Map.to_list(binding_attrs))
  end

  defp require_effect_protocol_pair!(%Effect{} = effect) do
    case {legacy_effect_struct?(effect), Protocol.lock_effect_pair!()} do
      {true, :legacy} -> :ok
      {false, {:active, epoch}} when epoch == effect.coordination_activation_epoch -> :ok
      _mismatch -> Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp require_legacy_protocol_pair! do
    unless Protocol.lock_effect_pair!() == :legacy,
      do: Repo.rollback(:effect_protocol_pair_mismatch)

    :ok
  end

  defp lock_effect_before_outcome!(%Effect{} = effect) do
    if legacy_effect_struct?(effect) do
      effect
    else
      lock_exact_effect_claim_in_transaction!(effect, ["claimed", "executing"])
    end
  end

  defp terminal_coordination_outcome!(updates) do
    case Keyword.fetch(updates, :status) do
      {:ok, "completed"} -> "completed"
      {:ok, "failed"} -> "failed"
      _invalid_terminal_transition -> Repo.rollback(:invalid_effect_terminal_outcome)
    end
  end

  defp settle_coordinated_effect_in_transaction!(%Effect{} = effect, outcome) do
    case coordination_assignment(effect) do
      :uncoordinated ->
        :settled

      {:ok, assignment} ->
        settle_exact_coordination_assignment!(effect, assignment, outcome)

      :mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp settle_exact_coordination_assignment!(
         %Effect{status: "claimed"} = effect,
         assignment,
         _outcome
       ) do
    locked = TaskClaims.lock_effect_assignment_in_transaction!(assignment)

    unless exact_coordination_assignment?(locked, assignment),
      do: Repo.rollback(:coordination_task_settlement_lost)

    case locked do
      %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} ->
        # A side-effect-free preflight can fail before durable Task activation.
        # Raw reserved settlement is forbidden: persist the Effect intent, let
        # Guardian authenticate physical DOWN, then reconcile from proof.
        :termination_proof_required

      %TaskAssignment{state: "running"} ->
        case TaskClaims.settle_effect_before_provider_in_transaction!(
               locked,
               effect.agent_id,
               effect.runtime_owner_generation
             ) do
          %TaskAssignment{
            state: "settled",
            provider_boundary: "not_entered",
            outcome: "cancelled_before_provider"
          } = settled ->
            if exact_coordination_assignment?(settled, assignment),
              do: :settled,
              else: Repo.rollback(:coordination_task_settlement_lost)

          _mismatched ->
            Repo.rollback(:coordination_task_settlement_lost)
        end

      _mismatched ->
        Repo.rollback(:coordination_task_settlement_lost)
    end
  end

  defp settle_exact_coordination_assignment!(
         %Effect{status: "executing"} = effect,
         assignment,
         outcome
       ) do
    case TaskClaims.settle_effect_in_transaction(
           assignment,
           effect.agent_id,
           effect.runtime_owner_generation,
           outcome
         ) do
      %TaskAssignment{state: "settled", outcome: ^outcome} = settled ->
        if exact_coordination_assignment?(settled, assignment),
          do: :settled,
          else: Repo.rollback(:coordination_task_settlement_lost)

      %TaskAssignment{state: "outcome_ambiguous"} ->
        Repo.rollback(:coordination_task_outcome_already_ambiguous)

      _mismatched ->
        Repo.rollback(:coordination_task_settlement_lost)
    end
  end

  defp claimed_effect_query(%Effect{} = effect, expected_status)
       when expected_status in ["claimed", "executing"] do
    from(e in Effect,
      where: e.id == ^effect.id,
      where: e.status == ^expected_status,
      where: e.claimed_by == ^effect.claimed_by,
      where: e.claimed_at == ^effect.claimed_at
    )
    |> fence_claim_identity(effect)
  end

  defp fence_claim_identity(query, %Effect{claim_token: nil}),
    do: legacy_protocol_rows(query)

  defp fence_claim_identity(query, %Effect{claim_token: claim_token} = effect)
       when is_binary(claim_token) do
    from(stored in query,
      where: stored.claim_token == ^claim_token,
      where: stored.claim_owner_node == ^effect.claim_owner_node,
      where: stored.claim_supervisor_id == ^effect.claim_supervisor_id,
      where: stored.claim_task_id == ^effect.claim_task_id,
      where: is_nil(stored.cancellation_state),
      where: stored.claim_expires_at > fragment("timezone('UTC', clock_timestamp())")
    )
    |> fence_runtime_owner_lineage(effect)
  end

  defp fence_claim_identity(query, %Effect{}), do: where(query, [stored], false)

  defp fence_terminal_claim_identity(query, %Effect{claim_token: nil}),
    do: legacy_protocol_rows(query)

  defp fence_terminal_claim_identity(query, %Effect{claim_token: claim_token} = effect)
       when is_binary(claim_token) do
    from(stored in query,
      where: stored.claim_token == ^claim_token,
      where: stored.claim_owner_node == ^effect.claim_owner_node,
      where: stored.claim_supervisor_id == ^effect.claim_supervisor_id,
      where: stored.claim_task_id == ^effect.claim_task_id
    )
  end

  defp fence_terminal_claim_identity(query, %Effect{}), do: where(query, [stored], false)

  defp coordinated_ambiguity_exit!(%Effect{} = effect, reason) do
    case coordination_assignment(effect) do
      {:ok, _assignment} -> exit(reason)
      :uncoordinated -> :uncoordinated
      :mismatched -> exit(:coordination_task_authority_lost)
    end
  end

  defp classify_claimed_error(_effect, {:effect_exception, _class}),
    do: @ambiguous_outcome

  defp classify_claimed_error(%Effect{effect_type: "tool_call"}, reason) do
    if tool_pre_entry_error?(reason), do: reason, else: @ambiguous_outcome
  end

  defp classify_claimed_error(_effect, reason), do: reason

  # Only failures proven to occur before Tool execution may be represented as
  # ordinary terminal failures. Transport, provider, response, parse, and
  # post-success encoding failures are outcome-ambiguous for external tools.
  defp tool_pre_entry_error?(:stale_effect_context), do: true
  defp tool_pre_entry_error?(:unknown_effect_type), do: true
  defp tool_pre_entry_error?(:unknown_tool), do: true
  defp tool_pre_entry_error?(:tool_not_allowed), do: true
  defp tool_pre_entry_error?({:tool_policy_denied, _decision}), do: true
  defp tool_pre_entry_error?({:tool_policy_needs_confirmation, _decision}), do: true
  defp tool_pre_entry_error?("unknown_tool:" <> _tool_name), do: true
  defp tool_pre_entry_error?(_reason), do: false

  defp next_attempt_count(%Effect{} = effect, reason) do
    if no_attempt_deferrable_effect_error?(effect, reason) do
      effect.attempts
    else
      effect.attempts + 1
    end
  end

  # Tool commands can cross an external side-effect boundary before returning an
  # error. Re-running the durable effect without a provider idempotency proof is
  # unsafe, so a claimed tool call is attempted at most once.
  defp should_retry?(%Effect{effect_type: "tool_call"}, _reason, _attempts), do: false

  defp should_retry?(%Effect{} = effect, reason, attempts) do
    not terminal_effect_error?(reason) and
      (no_attempt_deferrable_effect_error?(effect, reason) or attempts < effect.max_attempts)
  end

  defp terminal_effect_error?(@ambiguous_outcome), do: true
  defp terminal_effect_error?({:insufficient_quota, _message}), do: true
  defp terminal_effect_error?(:insufficient_quota), do: true
  defp terminal_effect_error?({:invalid_request, _summary}), do: true
  defp terminal_effect_error?(:invalid_request), do: true
  defp terminal_effect_error?("invalid_request"), do: true
  defp terminal_effect_error?({:provider_refusal, _summary}), do: true
  defp terminal_effect_error?({:content_filtered, _summary}), do: true
  defp terminal_effect_error?({:incomplete_response, _summary}), do: true
  defp terminal_effect_error?({:invalid_response, _summary}), do: true
  defp terminal_effect_error?(:invalid_json_response), do: true
  defp terminal_effect_error?({:invalid_json_response, _summary}), do: true
  defp terminal_effect_error?({:llm_provider_not_configured, _summary}), do: true

  defp terminal_effect_error?(message)
       when message in [
              "OPENAI_API_KEY not configured",
              "OPENROUTER_API_KEY not configured",
              "ANTHROPIC_API_KEY not configured"
            ],
       do: true

  defp terminal_effect_error?({:api_error, status, _summary})
       when is_integer(status) and status not in [408, 425, 429] and
              status not in 500..599,
       do: true

  defp terminal_effect_error?(:invalid_effect_result), do: true
  defp terminal_effect_error?(:unknown_effect_type), do: true
  defp terminal_effect_error?("unknown_effect_type"), do: true
  defp terminal_effect_error?(:stale_effect_context), do: true
  defp terminal_effect_error?(:unknown_tool), do: true
  defp terminal_effect_error?(:tool_not_allowed), do: true
  defp terminal_effect_error?({:tool_policy_denied, _decision}), do: true
  defp terminal_effect_error?({:tool_policy_needs_confirmation, _decision}), do: true
  defp terminal_effect_error?("unknown_tool:" <> _tool_name), do: true
  defp terminal_effect_error?(_reason), do: false

  defp no_attempt_deferrable_effect_error?(
         %Effect{effect_type: "llm_call"},
         {:llm_busy, _retry_after}
       ),
       do: true

  defp no_attempt_deferrable_effect_error?(_effect, _reason), do: false

  defp dispatch_terminal_result(effect, result \\ nil)

  defp dispatch_terminal_result(%Effect{} = effect, _result) do
    case DbResilience.with_database("effect runner reserve terminal result dispatch", fn ->
           case Repo.get(Effect, effect.id) do
             %Effect{agent_id: agent_id, status: status} = stored
             when agent_id == effect.agent_id and status in ["completed", "failed"] ->
               {stored, Effects.reserve_terminal_result_dispatch(stored)}

             _missing_or_nonterminal ->
               nil
           end
         end) do
      {:ok, {%Effect{} = stored, {:ok, true}}} ->
        notify_agent(stored.agent_id, stored.id, Effects.terminal_result(stored))

      {:ok, _not_reserved} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp notify_agent(agent_id, effect_id, result) do
    :ok = Dispatch.dispatch(agent_id, {:effect_result, effect_id, result})
  end

  defp log_surprise_legacy_claims do
    count =
      Repo.aggregate(
        from(effect in Effect,
          where: effect.status in ["pending", "claimed", "executing", "cancelling"],
          where: is_nil(effect.runtime_owner_generation)
        ),
        :count,
        :id
      )

    if count > 0 do
      Logger.error("Exact Effect protocol encountered unresolved legacy work",
        unresolved: count,
        failure_code: "effect_protocol_mismatch"
      )
    end

    count
  end

  defp finalize_stale_effects(claim_timeout_ms) do
    Repo.transaction(fn ->
      require_legacy_protocol_pair!()

      stale_before =
        dynamic(
          [effect],
          is_nil(effect.claimed_at) or
            effect.claimed_at <
              fragment(
                "timezone('UTC', NOW()) - (? * INTERVAL '1 millisecond')",
                ^claim_timeout_ms
              )
        )

      stale_base =
        from(effect in Effect,
          where: effect.status == "claimed",
          where: ^stale_before
        )

      stale_total = Repo.aggregate(stale_base, :count, :id)
      stale_legacy = stale_base |> legacy_protocol_rows() |> Repo.aggregate(:count, :id)

      if stale_total != stale_legacy do
        Repo.rollback({:effect_protocol_mismatch, stale_total - stale_legacy})
      end

      stale_ids =
        stale_base
        |> legacy_protocol_rows()
        |> order_by([effect], asc_nulls_first: effect.claimed_at, asc: effect.id)
        |> limit(@max_stale_finalizations)
        |> select([effect], effect.id)

      query =
        from(effect in Effect,
          where: effect.id in subquery(stale_ids),
          where: effect.status == "claimed",
          where: ^stale_before
        )
        |> legacy_protocol_rows()

      {count, _rows} =
        Repo.update_all(query,
          set: [
            status: "cancelling",
            updated_at: Maraithon.Runtime.DatabaseClock.now!()
          ]
        )

      if count > 0 do
        Logger.warning("Fenced stale legacy Effects pending worker termination",
          failed: count,
          failure_code: "stale_effect_termination_pending"
        )
      end

      count
    end)
  end

  defp calculate_backoff(attempt, reason) do
    case retry_after_ms(reason) do
      nil -> calculate_exponential_backoff(attempt)
      retry_after_ms -> add_jitter(retry_after_ms)
    end
  end

  defp calculate_exponential_backoff(attempt) do
    base = 1_000
    max = 60_000
    delay = base * :math.pow(2, attempt)
    jitter = :rand.uniform() * delay * 0.3
    round(min(delay + jitter, max))
  end

  defp retry_after_ms({:rate_limited, value}), do: normalize_retry_after_ms(value)
  defp retry_after_ms({:llm_busy, value}), do: normalize_retry_after_ms(value)

  defp retry_after_ms({:llm_fallbacks_failed, original_reason, fallback_errors}) do
    retry_after_values =
      ([retry_after_ms(original_reason)] ++ Enum.map(fallback_errors, &fallback_retry_after_ms/1))
      |> Enum.reject(&is_nil/1)

    case retry_after_values do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp retry_after_ms(_reason), do: nil

  defp fallback_retry_after_ms(%{reason: reason}), do: retry_after_text_ms(reason)
  defp fallback_retry_after_ms(%{"reason" => reason}), do: retry_after_text_ms(reason)
  defp fallback_retry_after_ms(_reason), do: nil

  defp retry_after_text_ms(reason) when is_binary(reason) do
    case Regex.run(~r/rate_limited[:,]\s*(\d{1,9})/, reason) do
      [_, retry_after] -> normalize_retry_after_ms(retry_after)
      _other -> nil
    end
  end

  defp retry_after_text_ms(_reason), do: nil

  defp normalize_retry_after_ms(value) when is_integer(value) and value > 0 do
    min(value, @max_rate_limit_retry_ms)
  end

  defp normalize_retry_after_ms(value) when is_binary(value) and byte_size(value) <= 9 do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> normalize_retry_after_ms(parsed)
      _other -> @default_rate_limit_retry_ms
    end
  end

  defp normalize_retry_after_ms(_value), do: @default_rate_limit_retry_ms

  defp add_jitter(retry_after_ms) do
    jitter = :rand.uniform(max(1, div(retry_after_ms, 5)))
    retry_after_ms + jitter
  end

  defp registered_effect_tasks_for_agent(agent_id) do
    case registered_effect_tasks() do
      {:ok, tasks} -> {:ok, Enum.filter(tasks, &(&1.agent_id == agent_id))}
      {:error, _reason} = error -> error
    end
  end

  defp registered_effect_tasks do
    tasks =
      Registry.select(Maraithon.Runtime.EffectTaskRegistry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.flat_map(fn
        {{effect_id, claimed_by, claimed_at}, pid, %{agent_id: agent_id}}
        when is_binary(effect_id) and is_binary(agent_id) and is_pid(pid) ->
          [
            %{
              effect_id: effect_id,
              agent_id: agent_id,
              claimed_by: claimed_by,
              claimed_at: claimed_at,
              claim_token: nil,
              pid: pid
            }
          ]

        {{effect_id, claim_token, supervisor_id, task_id}, pid,
         %{
           agent_id: agent_id,
           claim_token: claim_token,
           supervisor_id: supervisor_id,
           task_id: task_id
         }}
        when is_binary(effect_id) and is_binary(agent_id) and is_binary(claim_token) and
               is_pid(pid) ->
          [
            %{
              effect_id: effect_id,
              agent_id: agent_id,
              claim_token: claim_token,
              supervisor_id: supervisor_id,
              task_id: task_id,
              pid: pid
            }
          ]

        _other ->
          []
      end)

    {:ok, tasks}
  rescue
    _error -> {:error, :effect_task_registry_unavailable}
  catch
    :exit, _reason -> {:error, :effect_task_registry_unavailable}
  end

  defp state_effect_tasks_for_agent(state, agent_id) do
    Enum.flat_map(state.running, fn
      {effect_id, %Effect{agent_id: ^agent_id} = effect} ->
        case Map.get(state.tasks, effect_id) do
          %Task{pid: pid} when is_pid(pid) ->
            [
              %{
                effect_id: effect_id,
                agent_id: effect.agent_id,
                claimed_by: effect.claimed_by,
                claimed_at: effect.claimed_at,
                claim_token: effect.claim_token,
                assignment_id: effect.coordination_task_assignment_id,
                supervisor_id: effect.claim_supervisor_id,
                task_id: effect.claim_task_id,
                pid: pid
              }
            ]

          _no_task ->
            []
        end

      {_effect_id, _effect} ->
        []
    end)
  end

  defp terminate_verified_effect_tasks(task_entries, verified_claims, known_proofs) do
    entries_by_claim =
      Enum.group_by(task_entries, &{&1.effect_id, &1.claimed_by, &1.claimed_at})

    verified_claims
    |> Enum.reduce({MapSet.new(), MapSet.new(), 0}, fn claim, {terminated, proofs, failures} ->
      key = {claim.id, claim.claimed_by, claim.claimed_at}

      case Map.get(entries_by_claim, key, []) do
        [] ->
          if MapSet.member?(known_proofs, key) do
            {MapSet.put(terminated, claim.id), MapSet.put(proofs, key), failures}
          else
            # Missing Registry/state entries are ambiguity unless this Runner
            # directly proved the same physical generation terminated earlier.
            {terminated, proofs, failures + 1}
          end

        entries ->
          outcomes =
            Enum.map(entries, fn task ->
              try do
                Task.Supervisor.terminate_child(Maraithon.Runtime.EffectSupervisor, task.pid)
              catch
                :exit, _reason -> {:error, :supervisor_unavailable}
              end
            end)

          if Enum.all?(outcomes, &(&1 == :ok)) do
            {
              MapSet.put(terminated, claim.id),
              MapSet.put(proofs, key),
              failures
            }
          else
            # In particular, :not_found is not worker-death proof.
            {terminated, proofs, failures + 1}
          end
      end
    end)
    |> then(fn {terminated, proofs, failures} ->
      {MapSet.to_list(terminated), MapSet.to_list(proofs), failures}
    end)
  end

  defp remember_legacy_termination_proofs(existing, new_proofs) do
    new_proofs
    |> Enum.concat(MapSet.to_list(existing))
    |> Enum.uniq()
    |> Enum.take(@max_legacy_termination_proofs)
    |> MapSet.new()
  end

  defp terminate_cancelled_agent_tasks(agent_id, claims) do
    runtime_nodes = [node() | Node.list(:connected)] |> Enum.uniq()

    result =
      if length(runtime_nodes) > @max_runtime_nodes do
        {:partial, []}
      else
        nodes_by_name = Map.new(runtime_nodes, &{Atom.to_string(&1), &1})

        {terminated, incomplete?} =
          claims
          |> Enum.group_by(& &1.claimed_by)
          |> Enum.reduce({[], false}, fn {owner_name, owner_claims}, {terminated, incomplete?} ->
            owner_result =
              case Map.get(nodes_by_name, owner_name) do
                nil ->
                  {:partial, []}

                owner_node when owner_node == node() ->
                  terminate_cancelled_agent_tasks_local(agent_id, owner_claims)

                owner_node ->
                  :rpc.call(
                    owner_node,
                    __MODULE__,
                    :terminate_cancelled_agent_tasks_local,
                    [agent_id, owner_claims],
                    @task_termination_rpc_timeout_ms
                  )
              end

            case owner_result do
              {:ok, owner_terminated} when is_list(owner_terminated) ->
                {owner_terminated ++ terminated, incomplete?}

              {:partial, owner_terminated} when is_list(owner_terminated) ->
                {owner_terminated ++ terminated, true}

              _unknown_or_unreachable ->
                {terminated, true}
            end
          end)

        terminated =
          Enum.uniq_by(terminated, &{&1.id, &1.claimed_by, &1.claimed_at})

        if incomplete?, do: {:partial, terminated}, else: {:ok, terminated}
      end

    if match?({:partial, _terminated}, result) do
      Logger.warning("Effect task termination was incomplete on claim-owner nodes",
        failure_code: "effect_task_termination_incomplete"
      )
    end

    result
  catch
    _kind, _reason ->
      Logger.warning("Effect task termination orchestration failed",
        failure_code: "effect_task_termination_failed"
      )

      {:partial, []}
  end

  defp valid_cancellation_claims?(claims) do
    Enum.all?(claims, fn
      %{id: id, claimed_by: claimed_by, claimed_at: %DateTime{}}
      when is_binary(id) and is_binary(claimed_by) ->
        valid_effect_cancellation_text?(id) and valid_effect_cancellation_text?(claimed_by)

      _other ->
        false
    end)
  end

  defp finalize_and_terminate_running(state, opts) do
    case ProtocolCutover.mode() do
      :exact ->
        finalize_and_terminate_running_exact(state, opts)

      :legacy ->
        finalize_and_terminate_running_legacy(state, opts)

      {:blocked, reason} ->
        Logger.error("Effect shutdown blocked by protocol mismatch",
          failure_code: "effect_protocol_mismatch",
          mismatch: inspect(reason)
        )

        state = terminate_effect_tasks(state, Map.keys(state.tasks))
        %{state | running: %{}, tasks: %{}, monitors: %{}}
    end
  end

  defp finalize_and_terminate_running_exact(state, opts) do
    dispatch? = Keyword.get(opts, :dispatch?, false)

    {registered_tasks, registry_failed?} =
      case registered_effect_tasks() do
        {:ok, tasks} -> {tasks, false}
        {:error, _reason} -> {[], true}
      end

    {registered_effects, registered_load_failed?} = load_registered_claims(registered_tasks)

    effects =
      (Map.values(state.running) ++ registered_effects)
      |> Enum.uniq_by(&{&1.id, &1.claim_token})

    {exact_effects, legacy_effects} = Enum.split_with(effects, &is_binary(&1.claim_token))

    exact_failures =
      exact_effects
      |> Enum.group_by(& &1.agent_id)
      |> Enum.reduce(0, fn {agent_id, agent_effects}, failures ->
        chunk_failures =
          agent_effects
          |> Enum.chunk_every(100)
          |> Enum.count(fn chunk ->
            case Cancellation.prepare_runtime_abort(
                   agent_id,
                   chunk,
                   "effect_runner_shutdown"
                 ) do
              {:ok, plan} ->
                outcome = Cancellation.execute(plan)

                if dispatch? do
                  Enum.each(chunk, &dispatch_terminal_result(&1, {:error, @ambiguous_outcome}))
                end

                not match?({:ok, _summary}, outcome)

              {:error, _reason} ->
                true
            end
          end)

        failures + chunk_failures
      end)

    legacy_failures =
      Enum.count(legacy_effects, fn effect ->
        # A legacy claim has no exact task generation. Fence and kill it, but do
        # not falsely settle it from registry absence after exact activation.
        claims = fence_claim_for_termination(effect)
        claims == []
      end)

    _ = terminate_registered_tasks(Enum.filter(registered_tasks, &is_nil(&1.claim_token)))

    failure_count =
      exact_failures + legacy_failures +
        if(registry_failed? or registered_load_failed?, do: 1, else: 0)

    if failure_count > 0 do
      Logger.warning("Exact Effect shutdown finalization was incomplete",
        failed: failure_count,
        failure_code: "effect_shutdown_finalization_incomplete"
      )
    end

    state = terminate_effect_tasks(state, Map.keys(state.tasks))
    %{state | running: %{}, tasks: %{}, monitors: %{}}
  end

  defp finalize_and_terminate_running_legacy(state, opts) do
    dispatch? = Keyword.get(opts, :dispatch?, false)

    {registered_tasks, registry_failed?} =
      case registered_effect_tasks() do
        {:ok, tasks} -> {tasks, false}
        {:error, _reason} -> {[], true}
      end

    {registered_effects, registered_load_failed?} =
      load_registered_claims(registered_tasks)

    effects =
      (Map.values(state.running) ++ registered_effects)
      |> Enum.uniq_by(&{&1.id, &1.claimed_by, &1.claimed_at})

    {legacy_effects, exact_effects} = Enum.split_with(effects, &legacy_effect_struct?/1)

    failure_count =
      legacy_effects
      |> Enum.group_by(& &1.agent_id)
      |> Enum.reduce(0, fn {agent_id, agent_effects}, failures ->
        fenced_claims = Enum.flat_map(agent_effects, &fence_claim_for_termination/1)
        state_tasks = state_effect_tasks_for_agent(state, agent_id)
        registered = Enum.filter(registered_tasks, &(&1.agent_id == agent_id))

        task_entries =
          Enum.uniq_by(state_tasks ++ registered, fn task ->
            {task.effect_id, task.pid}
          end)

        {_terminated_ids, _termination_proofs, kill_failures} =
          terminate_verified_effect_tasks(
            task_entries,
            fenced_claims,
            state.legacy_termination_proofs
          )

        finalization_failed? =
          cond do
            length(fenced_claims) != length(agent_effects) ->
              true

            registry_failed? or registered_load_failed? ->
              true

            kill_failures > 0 ->
              true

            true ->
              case Effects.finish_cancel_active_for_agent(agent_id, fenced_claims) do
                {:ok, _summary} ->
                  if dispatch? do
                    Enum.each(agent_effects, fn effect ->
                      dispatch_terminal_result(effect, {:error, @ambiguous_outcome})
                    end)
                  end

                  false

                {:error, _reason} ->
                  true
              end
          end

        failures + if(finalization_failed?, do: 1, else: 0)
      end)

    legacy_registered_tasks = Enum.filter(registered_tasks, &is_nil(&1.claim_token))
    orphan_kill_failures = terminate_registered_tasks(legacy_registered_tasks)
    failure_count = failure_count + orphan_kill_failures + length(exact_effects)

    if failure_count > 0 do
      Logger.warning("Effect shutdown finalization was incomplete",
        failed: failure_count,
        failure_code: "effect_shutdown_finalization_incomplete"
      )
    end

    state = terminate_effect_tasks(state, Map.keys(state.tasks))
    %{state | running: %{}, tasks: %{}, monitors: %{}}
  end

  defp load_registered_claims([]), do: {[], false}

  defp load_registered_claims(tasks) do
    tasks
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({[], false}, fn task_chunk, {effects, false} ->
      ids = Enum.map(task_chunk, & &1.effect_id)

      loaded =
        Repo.all(
          from(effect in Effect,
            where: effect.id in ^ids,
            where: effect.status in ["claimed", "executing", "cancelling"]
          )
        )
        |> Enum.filter(fn effect ->
          Enum.any?(task_chunk, &registered_task_matches_effect?(&1, effect))
        end)

      {:cont, {loaded ++ effects, false}}
    end)
  rescue
    _error -> {[], true}
  catch
    :exit, _reason -> {[], true}
  end

  defp registered_task_matches_effect?(%{claim_token: nil} = task, effect) do
    effect.id == task.effect_id and effect.claim_token == nil and
      effect.claimed_by == task.claimed_by and effect.claimed_at == task.claimed_at
  end

  defp registered_task_matches_effect?(task, effect) do
    effect.id == task.effect_id and effect.claim_token == task.claim_token and
      effect.claim_supervisor_id == task.supervisor_id and effect.claim_task_id == task.task_id
  end

  defp terminate_registered_tasks(tasks) do
    Enum.count(tasks, fn task ->
      try do
        case Task.Supervisor.terminate_child(Maraithon.Runtime.EffectSupervisor, task.pid) do
          :ok -> false
          {:error, :not_found} -> false
          _failure -> true
        end
      catch
        :exit, _reason -> true
      end
    end)
  end

  defp fence_claim_for_termination(%Effect{} = effect) do
    query =
      from(stored in Effect,
        where: stored.id == ^effect.id,
        where: stored.agent_id == ^effect.agent_id,
        where: stored.status == "claimed",
        where: stored.claimed_by == ^effect.claimed_by,
        where: stored.claimed_at == ^effect.claimed_at,
        select: %{
          id: stored.id,
          claimed_by: stored.claimed_by,
          claimed_at: stored.claimed_at
        }
      )
      |> legacy_protocol_rows()

    case Repo.transaction(fn ->
           require_legacy_protocol_pair!()

           case Repo.update_all(query,
                  set: [status: "cancelling", updated_at: DateTime.utc_now()]
                ) do
             {1, [claim]} ->
               [claim]

             _already_fenced_or_lost ->
               stored_claim =
                 from(stored in Effect,
                   where: stored.id == ^effect.id,
                   where: stored.agent_id == ^effect.agent_id,
                   where: stored.status == "cancelling",
                   where: stored.claimed_by == ^effect.claimed_by,
                   where: stored.claimed_at == ^effect.claimed_at,
                   select: %{
                     id: stored.id,
                     claimed_by: stored.claimed_by,
                     claimed_at: stored.claimed_at
                   }
                 )
                 |> legacy_protocol_rows()
                 |> Repo.one()

               case stored_claim do
                 nil -> []
                 claim -> [claim]
               end
           end
         end) do
      {:ok, claims} -> claims
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp legacy_protocol_rows(query) do
    from(effect in query,
      where: is_nil(effect.runtime_owner_generation),
      where: is_nil(effect.claim_token),
      where: is_nil(effect.claim_owner_node),
      where: is_nil(effect.claim_heartbeat_at),
      where: is_nil(effect.claim_expires_at),
      where: is_nil(effect.claim_supervisor_id),
      where: is_nil(effect.claim_task_id),
      where: is_nil(effect.cancellation_state),
      where: is_nil(effect.cancellation_reason),
      where: is_nil(effect.cancellation_requested_at),
      where: is_nil(effect.cancellation_target_claim_token),
      where: is_nil(effect.cancellation_last_attempt_at),
      where: is_nil(effect.cancellation_last_error),
      where: is_nil(effect.cancellation_settled_at)
    )
  end

  defp exact_artifact_for_effect?(effect_id) do
    base = from(effect in Effect, where: effect.id == ^effect_id)
    Repo.exists?(base) and not (base |> legacy_protocol_rows() |> Repo.exists?())
  end

  defp legacy_effect_struct?(%Effect{} = effect) do
    is_nil(effect.runtime_owner_generation) and is_nil(effect.claim_token) and
      is_nil(effect.claim_owner_node) and is_nil(effect.claim_heartbeat_at) and
      is_nil(effect.claim_expires_at) and is_nil(effect.claim_supervisor_id) and
      is_nil(effect.claim_task_id) and is_nil(effect.cancellation_state) and
      is_nil(effect.cancellation_reason) and is_nil(effect.cancellation_requested_at) and
      is_nil(effect.cancellation_target_claim_token) and
      is_nil(effect.cancellation_last_attempt_at) and
      is_nil(effect.cancellation_last_error) and is_nil(effect.cancellation_settled_at)
  end

  defp terminate_effect_tasks(state, effect_ids) do
    Enum.reduce(effect_ids, state, fn effect_id, acc ->
      task = Map.get(acc.tasks, effect_id)
      effect = Map.get(acc.running, effect_id)
      acc = drop_effect_task(acc, effect_id)

      if match?(%Task{}, task) do
        try do
          Task.Supervisor.terminate_child(effect_task_supervisor(effect), task.pid)
        catch
          :exit, _reason -> :ok
        end
      end

      acc
    end)
  end

  defp effect_task_supervisor(%Effect{claim_token: claim_token}) when is_binary(claim_token),
    do: Maraithon.Runtime.ExactEffectTaskSupervisor

  defp effect_task_supervisor(_legacy_or_missing_effect),
    do: Maraithon.Runtime.EffectSupervisor

  defp drop_effect_task(state, effect_id, opts \\ []) do
    task = Map.get(state.tasks, effect_id)

    ref =
      case task do
        %Task{ref: ref} -> ref
        _task -> find_monitor_ref(state.monitors, effect_id)
      end

    if is_reference(ref) and Keyword.get(opts, :demonitor?, true) do
      Process.demonitor(ref, [:flush])
    end

    %{
      state
      | running: Map.delete(state.running, effect_id),
        tasks: Map.delete(state.tasks, effect_id),
        monitors: if(is_reference(ref), do: Map.delete(state.monitors, ref), else: state.monitors)
    }
  end

  defp find_monitor_ref(monitors, effect_id) do
    Enum.find_value(monitors, fn
      {ref, ^effect_id} -> ref
      {_ref, _other_id} -> nil
    end)
  end

  defp valid_effect_cancellation_text?(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  if Mix.env() == :test do
    defp test_command_prepared_observer(opts) do
      option_function(
        opts,
        :command_prepared_observer,
        fn _effect, _command_module, _prepared -> :ok end,
        3
      )
    end
  else
    # The deterministic prepare/entry barrier is a per-runner test seam only;
    # production builds neither read nor honor a configurable observer.
    defp test_command_prepared_observer(_opts),
      do: fn _effect, _command_module, _prepared -> :ok end
  end

  defp option_function(opts, key, default, arity) do
    value = if is_list(opts), do: Keyword.get(opts, key), else: nil
    if is_function(value, arity), do: value, else: default
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
