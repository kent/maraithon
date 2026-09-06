defmodule Maraithon.Runtime.Agent do
  @moduledoc """
  Agent process using gen_statem.
  Manages the lifecycle of a single long-running agent.
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  alias Maraithon.Events
  alias Maraithon.Effects
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.AgentSubscriptions
  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent, as: AgentRecord
  alias Maraithon.Behaviors
  alias Maraithon.Behaviors.SnapshotBudget
  alias Maraithon.Insights.Refresh, as: InsightRefresh
  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Memory
  alias Maraithon.OpenLoops
  alias Maraithon.OperatorEvents
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.Coordination.NodeIncarnation
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.UserMemory

  require Logger

  @default_effect_timeout_ms 120_000
  @default_llm_effect_timeout_ms 900_000
  @effect_timeout_buffer_ms 10_000
  @orphaned_effect_reason "agent_recovered_without_effect_continuation"
  @orphaned_run_reason "agent_recovered_without_run_continuation"
  @stopped_effect_reason "agent_stopped_without_effect_continuation"
  @stopped_run_reason "agent_stopped_without_run_continuation"
  @terminated_effect_reason "agent_process_terminated_without_effect_continuation"
  @terminated_run_reason "agent_process_terminated_without_run_continuation"
  @abandoned_result_reason "effect_result_continuation_lost"
  @global_register_retry_ms 25
  @global_register_retries 80
  @recovery_retry_ms 5_000
  @max_exact_activation_timeout_ms 5_000
  @min_exact_activation_timeout_ms 1_000
  @directive_poll_interval_ms 5_000
  @max_deferred_messages 200
  @max_ordinary_directive_burst 8
  @periodic_wakeup_scope {"_schedule_key", "agent_periodic_wakeup"}
  @periodic_wakeup_opts [include_legacy_empty_payload: true, preserve_earlier: true]

  defstruct [
    :agent_id,
    :user_id,
    :project_id,
    :behavior,
    :agent_package_id,
    :agent_package_version_id,
    :behavior_module,
    :behavior_state,
    :behavior_cycle_context,
    :config,
    :budget,
    :sequence_num,
    :pending_effects,
    :handled_jobs,
    :last_heartbeat_at,
    :last_checkpoint_at,
    :started_at,
    :subscriptions,
    :current_trigger,
    :current_event,
    :current_message,
    :current_message_metadata,
    :current_message_id,
    :current_run_id,
    :current_directive_id,
    :current_directive_claim_token,
    :current_directive_kind,
    :deferred_messages,
    :startup_agent,
    :owner_token,
    :guard_generation,
    :lease_ttl_ms,
    :lease_renew_interval_ms,
    ordinary_directive_burst: 0,
    exact_owner?: false,
    exact_activated?: false,
    clean_shutdown?: false
  ]

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(%{agent: %AgentRecord{} = agent, owner_token: owner_token} = launch)
      when is_binary(owner_token) do
    GenStateMachine.start_link(__MODULE__, launch,
      name: {:via, Registry, {Maraithon.Runtime.AgentRegistry, agent.id, owner_token}}
    )
  end

  # Compatibility for direct process tests and non-production callers. Runtime
  # and AgentSupervisor never use this legacy authority path.
  def start_link(%AgentRecord{} = agent) do
    GenStateMachine.start_link(__MODULE__, agent,
      name: {:via, Registry, {Maraithon.Runtime.AgentRegistry, agent.id}}
    )
  end

  def child_spec(%{agent: %AgentRecord{} = agent, owner_token: owner_token} = launch)
      when is_binary(owner_token) do
    %{
      id: {__MODULE__, agent.id, owner_token},
      start: {__MODULE__, :start_link, [launch]},
      # A restart must take a new database lease token through AgentSupervisor.
      # Reusing these launch arguments would resurrect a fenced incarnation.
      restart: :temporary,
      shutdown: 15_000,
      type: :worker
    }
  end

  def child_spec(%AgentRecord{} = agent) do
    %{
      id: agent.id,
      start: {__MODULE__, :start_link, [agent]},
      # Retained only for direct legacy tests. Production uses the exact clause.
      restart: :transient,
      type: :worker
    }
  end

  @doc false
  def activate_exact(pid, owner_token) when is_pid(pid) and is_binary(owner_token) do
    send(pid, {:activate_exact, owner_token})
    :ok
  end

  # ==========================================================================
  # Callbacks
  # ==========================================================================

  @impl true
  def init(%{
        agent: %AgentRecord{} = agent,
        owner_token: owner_token,
        guard_generation: guard_generation,
        lease_ttl_ms: ttl_ms,
        lease_renew_interval_ms: renew_interval_ms
      }) do
    if valid_exact_launch?(agent, owner_token, guard_generation, ttl_ms, renew_interval_ms) do
      data =
        agent
        |> initial_data()
        |> Map.merge(%{
          startup_agent: agent,
          owner_token: owner_token,
          guard_generation: guard_generation,
          lease_ttl_ms: ttl_ms,
          lease_renew_interval_ms: renew_interval_ms,
          exact_owner?: true
        })
        |> then(&struct!(__MODULE__, &1))

      # Stay dormant until AgentSupervisor synchronously installs the exact
      # Watcher monitor. No recovery work or readiness write may precede it.
      # A bounded watchdog closes the spawn -> monitor crash window: an orphan
      # incarnation cannot remain registered forever if its starter dies.
      activation_timeout_ms =
        renew_interval_ms
        |> max(@min_exact_activation_timeout_ms)
        |> min(@max_exact_activation_timeout_ms)

      {:ok, :recovering, data, [{{:timeout, :exact_activation}, activation_timeout_ms, :expire}]}
    else
      {:stop, :invalid_exact_agent_launch}
    end
  end

  def init(%AgentRecord{} = agent) do
    Process.flag(:trap_exit, true)

    case register_global_name(agent.id) do
      :ok ->
        case Agents.begin_runtime_agent_recovery(agent.id) do
          {:ok, recovery_agent} ->
            Logger.metadata(agent_reference: Maraithon.Redaction.fingerprint(agent.id))
            Logger.info("Agent initializing", behavior: recovery_agent.behavior)

            data = struct!(__MODULE__, initial_data(recovery_agent))
            {:ok, :recovering, data, [{:next_event, :internal, {:init, recovery_agent}}]}

          {:error, _reason} ->
            :global.unregister_name({:maraithon_agent, agent.id})
            :ignore
        end

      {:error, _reason} ->
        :ignore
    end
  end

  @impl true
  def terminate(_reason, _state, %{exact_owner?: true}), do: :ok

  def terminate(_reason, _state, data) do
    case close_terminated_effects(data) do
      {:ok, _cancelled_count} -> close_terminated_run(data)
      {:error, _reason} -> :ok
    end

    :ok
  end

  defp initial_data(agent) do
    %{
      agent_id: agent.id,
      config: agent.config,
      sequence_num: 0,
      pending_effects: %{},
      handled_jobs: MapSet.new(),
      started_at: DateTime.utc_now(),
      deferred_messages: []
    }
  end

  defp valid_exact_launch?(agent, owner_token, guard_generation, ttl_ms, renew_interval_ms) do
    agent.id != nil and match?({:ok, _}, Ecto.UUID.cast(agent.id)) and
      match?({:ok, _}, Ecto.UUID.cast(owner_token)) and
      (is_nil(guard_generation) or match?({:ok, _}, Ecto.UUID.cast(guard_generation))) and
      is_integer(ttl_ms) and ttl_ms >= 1_000 and ttl_ms <= 300_000 and
      is_integer(renew_interval_ms) and renew_interval_ms > 0 and renew_interval_ms < ttl_ms
  end

  # ==========================================================================
  # RECOVERING state
  # ==========================================================================

  def recovering(:enter, _old_state, data) do
    Logger.info("Entering recovering state")
    {:keep_state, data}
  end

  def recovering(
        :info,
        {:activate_exact, owner_token},
        %{exact_owner?: true, owner_token: owner_token, exact_activated?: false} = data
      ) do
    Logger.metadata(agent_reference: Maraithon.Redaction.fingerprint(data.agent_id))
    Logger.info("Exact Agent initializing", behavior: data.startup_agent.behavior)

    data = %{data | exact_activated?: true}

    {:keep_state, data,
     [
       {{:timeout, :exact_activation}, :cancel},
       lease_renewal_action(data),
       {:next_event, :internal, {:init, data.startup_agent}}
     ]}
  end

  def recovering(:info, {:activate_exact, _owner_token}, %{exact_owner?: true} = data) do
    {:keep_state, data}
  end

  def recovering(
        {:timeout, :exact_activation},
        :expire,
        %{exact_owner?: true, exact_activated?: false} = data
      ) do
    {:stop, :exact_activation_timeout, data}
  end

  def recovering({:timeout, :lease_renewal}, :renew_lease, data) do
    renew_exact_lease(data)
  end

  def recovering(:internal, {:init, startup_agent}, data) do
    case recovery_agent(startup_agent.id, data) do
      {:ok, agent} ->
        if exact_recovery_owner?(data) do
          # Checkpoints intentionally capture only idle behavior state. Any active
          # outbox rows therefore belong to a process incarnation whose
          # continuation cannot be restored safely. Cancel them before this
          # incarnation can start another cycle.
          with {:ok, _cancelled_count} <-
                 cancel_active_effects(agent.id, @orphaned_effect_reason, data.owner_token),
               :ok <- reconcile_persisted_active_run(agent) do
            finish_recovery(agent, data)
          else
            {:error, reason} ->
              Logger.warning("Agent recovery deferred while durable cleanup is incomplete",
                agent_reference: Maraithon.Redaction.fingerprint(agent.id),
                failure_code: Maraithon.Redaction.error_class(reason)
              )

              {:keep_state, data,
               [{{:timeout, :recovery_retry}, @recovery_retry_ms, :retry_recovery}]}
          end
        else
          # A direct/stale launch must not use recovery cleanup as an authority
          # bypass. The Watcher guards a production token on DOWN.
          {:stop, :exact_runtime_not_owned, data}
        end

      :inactive ->
        stop_inactive_agent(data)
    end
  end

  def recovering({:timeout, :recovery_retry}, :retry_recovery, data) do
    case Agents.get_agent(data.agent_id, include_removed: true) do
      nil -> stop_inactive_agent(data)
      agent -> recovering(:internal, {:init, agent}, data)
    end
  end

  def recovering(
        :info,
        {:agent_dispatch, {:control, :stop, reason, owner_token}},
        data
      ) do
    stop_agent(reason, data, owner_token)
  end

  def recovering(:info, {:control, :stop, reason, owner_token}, data) do
    stop_agent(reason, data, owner_token)
  end

  def recovering(
        :info,
        {:agent_dispatch, {:control, :stop, _reason}},
        %{exact_owner?: true} = data
      ) do
    {:keep_state, data}
  end

  def recovering(
        :info,
        {:agent_dispatch, {:control, :stop, reason}},
        %{exact_owner?: false} = data
      ) do
    stop_agent(reason, data)
  end

  def recovering(:info, {:control, :stop, _reason}, %{exact_owner?: true} = data) do
    {:keep_state, data}
  end

  def recovering(:info, {:control, :stop, reason}, %{exact_owner?: false} = data) do
    stop_agent(reason, data)
  end

  def recovering(
        :info,
        {:agent_dispatch, {:directive_available, _directive_id}},
        data
      ),
      do: {:keep_state, data}

  def recovering(:info, {:directive_available, _directive_id}, data),
    do: {:keep_state, data}

  def recovering(:info, :directive_poll, data) do
    schedule_directive_poll()
    {:keep_state, data}
  end

  def recovering(:info, {:agent_dispatch, msg}, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def recovering(:info, msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  defp finish_recovery(agent, data) do
    agent_config = enrich_config_with_package_manifest(agent)

    # Load behavior module
    behavior_module = Behaviors.get!(agent.behavior)

    # Restore behavior state and budget from the latest checkpoint snapshot so a
    # restarted agent resumes with context instead of a blank behavior state.
    # The snapshot is the recovery boundary — events between the last checkpoint
    # and a crash are not replayed (replaying behavior handlers would re-run
    # their side effects).
    #
    # SPEC 08 R3: restore MERGES the snapshot onto fresh init/1 defaults (with
    # optional versioned migration and config reconciliation hooks) instead of
    # installing it wholesale — a snapshot predating a newly-read state key
    # must never be able to crash every subsequent wakeup (prod 2026-07-03,
    # :pending_watermarks), and config-derived state must not stay frozen at
    # snapshot time (the LocalPatternReview never-enabled bug).
    {behavior_state, budget} =
      case safe_load_snapshot(agent.id) do
        %{sequence_num: seq} = snapshot ->
          Logger.info("Agent restoring behavior state from snapshot", sequence_num: seq)
          restore_from_snapshot(behavior_module, agent_config, snapshot, agent.id)

        nil ->
          {behavior_module.init(agent_config), init_budget(agent_config["budget"])}
      end

    subscriptions =
      (agent.config["subscribe"] || [])
      |> Kernel.++(AgentSubscriptions.list_topics_for_agent(agent.id))
      |> Enum.uniq()

    data = %{
      data
      | behavior_module: behavior_module,
        user_id: agent.user_id,
        project_id: agent.project_id,
        behavior: agent.behavior,
        agent_package_id: agent.agent_package_id,
        agent_package_version_id: agent.agent_package_version_id,
        behavior_state: behavior_state,
        behavior_cycle_context: nil,
        config: agent_config,
        budget: budget,
        sequence_num: Events.latest_sequence_num(agent.id),
        subscriptions: subscriptions,
        current_trigger: nil,
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil,
        current_run_id: nil
    }

    expose_recovered_agent(agent, agent_config, subscriptions, data)
  end

  defp expose_recovered_agent(agent, agent_config, subscriptions, data) do
    # Replace recurring timers and install every routing subscription before
    # readiness. A ready lease is the last durable recovery fact.
    schedule_heartbeat(data)
    schedule_checkpoint(data)
    schedule_next_wakeup(data)
    schedule_directive_poll()

    :ok = Dispatch.subscribe(agent.id)

    Enum.each(subscriptions, fn topic ->
      Phoenix.PubSub.subscribe(Maraithon.PubSub, topic)
      Logger.info("Subscribed to topic", topic: topic)
    end)

    if data.exact_owner? do
      case activate_exact_owner(data) do
        {:ok, _lease} ->
          # Readiness is the last recovery authority write. Only a ready exact
          # owner may append the startup event or enter the workload state.
          data = %{data | guard_generation: nil}
          data = emit_started_event(data, agent, agent_config)
          Logger.info("Exact Agent recovered, transitioning to idle")
          {:next_state, :idle, data}

        {:error, reason} ->
          Logger.warning("Exact Agent readiness was fenced",
            agent_reference: Maraithon.Redaction.fingerprint(agent.id),
            failure_code: Maraithon.Redaction.error_class(reason)
          )

          {:stop, {:exact_agent_not_ready, reason}, data}
      end
    else
      case Agents.finish_runtime_agent_recovery(agent.id) do
        {:ok, _running_agent} ->
          data = emit_started_event(data, agent, agent_config)
          Logger.info("Agent recovered, transitioning to idle")
          {:next_state, :idle, data}

        {:error, reason} ->
          Logger.warning("Agent recovery activation was fenced",
            agent_reference: Maraithon.Redaction.fingerprint(agent.id),
            failure_code: Maraithon.Redaction.error_class(reason)
          )

          {:keep_state, data,
           [{{:timeout, :recovery_retry}, @recovery_retry_ms, :retry_recovery}]}
      end
    end
  end

  defp emit_started_event(data, agent, agent_config) do
    emit_event(data, "agent_started", %{
      behavior: agent.behavior,
      config: redact_runtime_config(agent_config)
    })
  end

  defp activate_exact_owner(%{guard_generation: nil} = data) do
    AgentLeases.mark_ready(data.agent_id, data.owner_token)
  end

  defp activate_exact_owner(data) do
    AgentLeases.finish_recovery(
      data.agent_id,
      data.owner_token,
      data.guard_generation
    )
  end

  # ==========================================================================
  # IDLE state
  # ==========================================================================

  def idle(:enter, _old_state, data) do
    Logger.debug("Entering idle state")

    data = drain_deferred_messages(data)

    if data.exact_owner? do
      # A busy Agent can have a continuous backlog of Directive notifications.
      # Those mailbox events may remain ahead of the named renewal timeout while
      # each completed Directive immediately admits the next one. Renew at this
      # cooperative boundary as well, so throughput cannot starve the lease that
      # fences that work. The timer remains the idle/waiting safety net.
      send(self(), :claim_directive)
      renew_exact_lease(data)
    else
      {:keep_state, data}
    end
  end

  def idle(:internal, :claim_directive, %{exact_owner?: true} = data) do
    claim_and_activate_directive(data)
  end

  def idle(:internal, :claim_directive, data), do: {:keep_state, data}

  def idle({:timeout, :lease_renewal}, :renew_lease, data) do
    renew_exact_lease(data)
  end

  def idle(:info, :claim_directive, %{exact_owner?: true} = data) do
    claim_and_activate_directive(data)
  end

  def idle(:info, :claim_directive, data), do: {:keep_state, data}

  def idle(:info, {:agent_dispatch, msg}, data) do
    idle(:info, msg, data)
  end

  def idle(:info, {:directive_available, _directive_id}, %{exact_owner?: true} = data) do
    {:keep_state, data, [{:next_event, :internal, :claim_directive}]}
  end

  def idle(:info, {:directive_available, _directive_id}, data), do: {:keep_state, data}

  def idle(:info, :directive_poll, data) do
    schedule_directive_poll()

    if data.exact_owner? do
      {:keep_state, data, [{:next_event, :internal, :claim_directive}]}
    else
      {:keep_state, data}
    end
  end

  def idle(:info, {:wakeup, _job_type, _job_id, _payload}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :wakeup, claim?: true)
  end

  def idle(:info, {:wakeup, job_type, job_id, payload}, data) do
    acknowledge_wakeup(job_id)

    if MapSet.member?(data.handled_jobs, job_id) do
      # Duplicate, ignore
      {:keep_state, data}
    else
      data = %{data | handled_jobs: add_bounded(data.handled_jobs, job_id, 100)}

      case job_type do
        "heartbeat" ->
          data = emit_heartbeat(data)
          schedule_heartbeat(data)
          {:keep_state, data}

        "checkpoint" ->
          data = emit_checkpoint(data)
          schedule_checkpoint(data)
          {:keep_state, data}

        "wakeup" ->
          data = emit_event(data, "wakeup_received", %{job_id: job_id})
          data = maybe_refill_budget(data)

          if has_budget?(data) do
            data = put_wakeup_trigger(data, job_type, job_id, payload)
            {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
          else
            Logger.warning("No budget, staying idle")
            schedule_next_wakeup(data)
            {:keep_state, data}
          end
      end
    end
  end

  def idle(:info, {:control, :stop, reason, owner_token}, data) do
    stop_agent(reason, data, owner_token)
  end

  def idle(:info, {:control, :stop, _reason}, %{exact_owner?: true} = data) do
    {:keep_state, data}
  end

  def idle(
        :info,
        {:control, :stop, reason},
        %{exact_owner?: false} = data
      ) do
    stop_agent(reason, data)
  end

  def idle(:info, {:message, _message, _metadata, _message_id}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :message, claim?: true)
  end

  def idle(:info, {:message, message, metadata, message_id}, data) do
    metadata = normalize_message_metadata(metadata)
    data = maybe_reset_open_insights_for_refresh(data, message, metadata)

    data =
      emit_event(data, "message_received", %{
        message: message,
        metadata: metadata,
        message_id: message_id
      })

    data = maybe_refill_budget(data)

    if has_budget?(data) do
      data = put_message_trigger(data, message, metadata, message_id)
      {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
    else
      Logger.warning("No budget, cannot process message")
      {:keep_state, data}
    end
  end

  # Handle PubSub events
  def idle(:info, {:pubsub_event, _topic, _payload}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :pubsub_event, claim?: true)
  end

  def idle(:info, {:pubsub_event, topic, payload}, data) do
    if topic in (data.subscriptions || []) do
      Logger.info("Received PubSub event", topic: topic)

      data =
        emit_event(data, "pubsub_event_received", %{
          topic: topic,
          payload: payload
        })

      data = maybe_refill_budget(data)

      if has_budget?(data) do
        data = put_pubsub_trigger(data, topic, payload)
        {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
      else
        Logger.warning("No budget, cannot process PubSub event")
        {:keep_state, data}
      end
    else
      {:keep_state, data}
    end
  end

  def idle(:info, {:effect_result, effect_id, _result}, data) do
    data = reconcile_abandoned_terminal_result(effect_id, data, false)
    {:keep_state, data}
  end

  def idle(:info, _msg, data) do
    Logger.debug("Idle received an unhandled message")
    {:keep_state, data}
  end

  # ==========================================================================
  # WORKING state
  # ==========================================================================

  def working(:enter, _old_state, data) do
    Logger.debug("Entering working state")
    {:keep_state, data}
  end

  def working({:timeout, :lease_renewal}, :renew_lease, data) do
    renew_exact_lease(data)
  end

  def working(:info, {:agent_dispatch, msg}, data) do
    working(:info, msg, data)
  end

  def working(:info, {:directive_available, _directive_id}, data), do: {:keep_state, data}

  def working(:info, :directive_poll, data) do
    schedule_directive_poll()
    {:keep_state, data}
  end

  def working(:internal, :execute_behavior, %{exact_owner?: true} = data) do
    if renew_effect_admission_authority(data) == :ok and
         AgentLeases.ready?(data.agent_id, data.owner_token) do
      execute_behavior(data)
    else
      {:stop, :exact_runtime_not_ready, data}
    end
  end

  def working(:internal, :execute_behavior, data), do: execute_behavior(data)

  def working(:info, {:wakeup, _, _, _}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :wakeup)
  end

  def working(:info, {:wakeup, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def working(:info, {:pubsub_event, _, _}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :pubsub_event)
  end

  def working(:info, {:pubsub_event, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def working(:info, {:message, _, _, _}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :message)
  end

  def working(:info, {:message, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def working(:info, {:control, :stop, reason, owner_token}, data) do
    stop_agent(reason, data, owner_token)
  end

  def working(:info, {:control, :stop, _reason}, %{exact_owner?: true} = data) do
    {:keep_state, data}
  end

  def working(
        :info,
        {:control, :stop, reason},
        %{exact_owner?: false} = data
      ) do
    stop_agent(reason, data)
  end

  def working(:info, {:effect_result, effect_id, _result}, data) do
    reconcile_abandoned_terminal_result(effect_id, data, true)
    {:keep_state, data}
  end

  def working(:info, _msg, data) do
    Logger.debug("Working received an unhandled message")
    {:keep_state, data}
  end

  defp execute_behavior(data) do
    data = ensure_current_run(data)
    context = build_context(data)

    case data.behavior_module.handle_wakeup(behavior_state_for_call(data), context) do
      {:effect, effect, new_behavior_state} ->
        data = put_behavior_state(data, new_behavior_state)
        request_effect(data, effect)

      {:emit, {event_type, payload}, new_behavior_state} ->
        data = put_behavior_state(data, new_behavior_state)
        data = complete_current_run(data, event_type, payload)
        data = clear_transient_context(data)
        schedule_next_wakeup(data)
        {:next_state, :idle, data}

      {:continue, new_behavior_state} ->
        data = put_behavior_state(data, new_behavior_state)
        {:keep_state, data, [{:next_event, :internal, :execute_behavior}]}

      {:idle, new_behavior_state} ->
        data = put_behavior_state(data, new_behavior_state)
        data = complete_current_run(data, :idle, %{})
        data = clear_transient_context(data)
        schedule_next_wakeup(data)
        {:next_state, :idle, data}
    end
  end

  # ==========================================================================
  # WAITING_EFFECT state
  # ==========================================================================

  def waiting_effect(:enter, _old_state, data) do
    timeout_ms = pending_effect_timeout_ms(data.pending_effects)

    Logger.debug("Entering waiting_effect state", timeout_ms: timeout_ms)
    {:keep_state, data, [{:state_timeout, timeout_ms, :effect_timeout}]}
  end

  def waiting_effect({:timeout, :lease_renewal}, :renew_lease, data) do
    renew_exact_lease(data)
  end

  def waiting_effect(:info, {:agent_dispatch, msg}, data) do
    waiting_effect(:info, msg, data)
  end

  def waiting_effect(:info, {:directive_available, _directive_id}, data),
    do: {:keep_state, data}

  def waiting_effect(:info, :directive_poll, data) do
    schedule_directive_poll()
    {:keep_state, data}
  end

  def waiting_effect(:info, {:effect_result, effect_id, _reported_result}, data) do
    case authoritative_terminal_result(effect_id, data.agent_id) do
      {:terminal, result} ->
        process_received_effect_result(effect_id, result, data)

      :not_terminal ->
        Logger.warning("Ignored non-terminal effect result notification",
          effect_reference: Maraithon.Redaction.fingerprint(effect_id),
          failure_code: "effect_not_terminal"
        )

        {:keep_state, data}

      {:error, reason} ->
        Logger.warning("Ignored invalid effect result notification",
          effect_reference: Maraithon.Redaction.fingerprint(effect_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:keep_state, data}
    end
  end

  # Locally generated request-validation/write failures have no durable Effect
  # row. Keep them on gen_statem's internal event channel so they cannot be
  # forged through a process mailbox or PubSub dispatch.
  def waiting_effect(:internal, {:synthetic_effect_result, effect_id, result}, data) do
    process_received_effect_result(effect_id, result, data)
  end

  def waiting_effect(:state_timeout, :effect_timeout, data) do
    Logger.warning("Effect timeout")

    # The behavior is about to abandon this continuation. Cancel the durable
    # row before it can be retried, and fence any worker already finishing it.
    {:ok, _cancelled_count} =
      cancel_active_effects(data.agent_id, "effect_timeout", data.owner_token)

    # R4 (SPEC 07): waiting_effect only ever holds the single in-flight
    # effect request_effect/2 just registered, and no effect_id is bound in
    # this clause — clear the whole map so the stale entry stops inflating
    # pending_effect_timeout_ms/1's Enum.max for every later effect and
    # leaking across the agent's lifetime.
    effect_info =
      case Map.values(data.pending_effects) do
        [effect_info | _rest] -> effect_info
        [] -> nil
      end

    data = %{data | pending_effects: %{}}

    # R3 (SPEC 07): route the timeout through the behavior exactly like the
    # {:error, reason} effect_result branch above, so the waiting skill gets
    # its handle_effect_error/4 turn and a mid-cycle timeout can resume the
    # rest of the cycle instead of silently dropping the continuation.
    # Timeouts never decrement budget — unchanged by this spec. If
    # pending_effects was unexpectedly empty, fall back to today's behavior.
    if effect_info != nil and function_exported?(data.behavior_module, :handle_effect_error, 4) do
      update_current_run_error(data.current_run_id, effect_info, :effect_timeout)

      data =
        emit_event(data, "effect_failed", %{
          effect_type: to_string(effect_info.type),
          error: "effect_timeout"
        })

      context = build_context(data)

      case data.behavior_module.handle_effect_error(
             effect_info.type,
             :effect_timeout,
             behavior_state_for_call(data),
             context
           ) do
        {:emit, {event_type, payload}, new_behavior_state} ->
          data = put_behavior_state(data, new_behavior_state)
          data = complete_current_run(data, event_type, payload)
          data = clear_transient_context(data)
          schedule_next_wakeup(data)
          {:next_state, :idle, data}

        {:idle, new_behavior_state} ->
          data = put_behavior_state(data, new_behavior_state)
          data = complete_current_run(data, :idle, %{})
          data = clear_transient_context(data)
          schedule_next_wakeup(data)
          {:next_state, :idle, data}

        {:effect, effect, new_behavior_state} ->
          data = put_behavior_state(data, new_behavior_state)
          request_effect(data, effect)

        {:continue, new_behavior_state} ->
          data = put_behavior_state(data, new_behavior_state)
          {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
      end
    else
      data = fail_current_run(data, "effect_timeout")
      data = clear_transient_context(data)
      schedule_next_wakeup(data)
      {:next_state, :idle, data}
    end
  end

  def waiting_effect(:info, {:wakeup, _, _, _}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :wakeup)
  end

  def waiting_effect(:info, {:wakeup, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def waiting_effect(:info, {:pubsub_event, _, _}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :pubsub_event)
  end

  def waiting_effect(:info, {:pubsub_event, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def waiting_effect(:info, {:message, _, _, _}, %{exact_owner?: true} = data) do
    reject_raw_exact_workload(data, :message)
  end

  def waiting_effect(:info, {:message, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def waiting_effect(:info, {:control, :stop, reason, owner_token}, data) do
    stop_agent(reason, data, owner_token)
  end

  def waiting_effect(:info, {:control, :stop, _reason}, %{exact_owner?: true} = data) do
    {:keep_state, data}
  end

  def waiting_effect(
        :info,
        {:control, :stop, reason},
        %{exact_owner?: false} = data
      ) do
    stop_agent(reason, data)
  end

  def waiting_effect(:info, _msg, data) do
    Logger.debug("Waiting effect received an unhandled message")
    {:keep_state, data}
  end

  defp process_received_effect_result(effect_id, result, data) do
    if Map.has_key?(data.pending_effects, effect_id) do
      process_effect_result(effect_id, result, data)
    else
      outcome = process_effect_result(effect_id, result, data)
      reconcile_abandoned_terminal_result(effect_id, data, true)
      outcome
    end
  end

  defp authoritative_terminal_result(effect_id, agent_id) do
    Effects.terminal_result(effect_id, agent_id)
  rescue
    _error -> {:error, :effect_repository_unavailable}
  catch
    :exit, _reason -> {:error, :effect_repository_unavailable}
  end

  defp process_effect_result(effect_id, result, data) do
    case Map.pop(data.pending_effects, effect_id) do
      {nil, _} ->
        if active_terminal_result_replay?(effect_id, data) do
          Logger.debug("Received replay for active effect result",
            effect_reference: Maraithon.Redaction.fingerprint(effect_id)
          )
        else
          Logger.warning("Received result for unknown effect",
            effect_reference: Maraithon.Redaction.fingerprint(effect_id),
            failure_code: "unknown_effect"
          )
        end

        {:keep_state, data}

      {effect_info, pending_effects} ->
        data = %{data | pending_effects: pending_effects}
        data = decrement_budget(data, effect_info.type)

        case result do
          {:ok, result_data} ->
            data = persist_effect_outcome(data, effect_id, effect_info, {:ok, result_data})

            # Pass result to behavior
            context = build_context(data)

            case data.behavior_module.handle_effect_result(
                   {effect_info.type, result_data},
                   behavior_state_for_call(data),
                   context
                 ) do
              {:emit, {event_type, payload}, new_behavior_state} ->
                data = put_behavior_state(data, new_behavior_state)
                data = complete_current_run(data, event_type, payload)
                data = clear_transient_context(data)
                schedule_next_wakeup(data)
                {:next_state, :idle, data}

              {:idle, new_behavior_state} ->
                data = put_behavior_state(data, new_behavior_state)
                data = complete_current_run(data, :idle, %{})
                data = clear_transient_context(data)
                schedule_next_wakeup(data)
                {:next_state, :idle, data}

              {:effect, effect, new_behavior_state} ->
                data = put_behavior_state(data, new_behavior_state)
                request_effect(data, effect)

              {:continue, new_behavior_state} ->
                data = put_behavior_state(data, new_behavior_state)
                {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
            end

          {:error, reason} ->
            data = persist_effect_outcome(data, effect_id, effect_info, {:error, reason})

            context = build_context(data)

            if function_exported?(data.behavior_module, :handle_effect_error, 4) do
              case data.behavior_module.handle_effect_error(
                     effect_info.type,
                     reason,
                     behavior_state_for_call(data),
                     context
                   ) do
                {:emit, {event_type, payload}, new_behavior_state} ->
                  data = put_behavior_state(data, new_behavior_state)
                  data = complete_current_run(data, event_type, payload)
                  data = clear_transient_context(data)
                  schedule_next_wakeup(data)
                  {:next_state, :idle, data}

                {:idle, new_behavior_state} ->
                  data = put_behavior_state(data, new_behavior_state)
                  data = complete_current_run(data, :idle, %{})
                  data = clear_transient_context(data)
                  schedule_next_wakeup(data)
                  {:next_state, :idle, data}

                {:effect, effect, new_behavior_state} ->
                  data = put_behavior_state(data, new_behavior_state)
                  request_effect(data, effect)

                {:continue, new_behavior_state} ->
                  data = put_behavior_state(data, new_behavior_state)
                  {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
              end
            else
              data = fail_current_run(data, reason)
              data = clear_transient_context(data)
              schedule_next_wakeup(data)
              {:next_state, :idle, data}
            end
        end
    end
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp claim_and_activate_directive(%{current_directive_id: directive_id} = data)
       when is_binary(directive_id) do
    {:stop, :directive_settlement_incomplete, data}
  end

  defp claim_and_activate_directive(data) do
    opts = [prefer_scheduled: data.ordinary_directive_burst >= @max_ordinary_directive_burst]

    case AgentDirectives.claim_next(data.agent_id, data.user_id, data.owner_token, opts) do
      {:ok, nil} ->
        {:keep_state, data}

      {:ok, directive} ->
        burst =
          if directive.kind == "scheduled_wakeup",
            do: 0,
            else: min(data.ordinary_directive_burst + 1, @max_ordinary_directive_burst)

        activate_claimed_directive(%{data | ordinary_directive_burst: burst}, directive)

      {:error, reason} when reason in [:node_authority_lost, :partition_authority_lost] ->
        if durable_authority_draining?(data) do
          {:stop, :normal, data}
        else
          stop_after_directive_failure(:claim, reason, data)
        end

      {:error, reason} ->
        stop_after_directive_failure(:claim, reason, data)
    end
  end

  defp activate_claimed_directive(data, directive) do
    claimed_data = %{
      data
      | current_directive_id: directive.id,
        current_directive_claim_token: directive.claim_token,
        current_directive_kind: directive.kind
    }

    activation =
      AgentDirectives.with_live_claim(
        data.agent_id,
        directive.id,
        data.owner_token,
        directive.claim_token,
        :ready,
        fn _locked_directive, _now ->
          activate_directive_payload_locked(claimed_data, directive.kind, directive.payload)
        end
      )

    case activation do
      {:ok, %{current_trigger: %{type: :wakeup, job_type: "heartbeat"}} = activated_data} ->
        settle_maintenance_directive(activated_data, :heartbeat)

      {:ok, %{current_trigger: %{type: :wakeup, job_type: "checkpoint"}} = activated_data} ->
        settle_maintenance_directive(activated_data, :checkpoint)

      {:ok, activated_data} ->
        activated_data = maybe_refill_budget(activated_data)

        if has_budget?(activated_data) do
          {:next_state, :working, activated_data, [{:next_event, :internal, :execute_behavior}]}
        else
          Logger.warning("No budget, rejecting durable Directive",
            agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
            directive_reference: Maraithon.Redaction.fingerprint(directive.id)
          )

          fail_unstarted_directive(activated_data, "execution_failed")
        end

      {:error, :invalid_directive_payload} ->
        dead_letter_invalid_directive(claimed_data)

      {:error, reason} when reason in [:node_authority_lost, :partition_authority_lost] ->
        if durable_authority_draining?(claimed_data) do
          {:stop, :normal, claimed_data}
        else
          stop_after_directive_failure(:activation, reason, claimed_data)
        end

      {:error, reason} ->
        stop_after_directive_failure(:activation, reason, claimed_data)
    end
  end

  defp stop_after_directive_failure(:claim, reason, data) do
    Logger.warning("Exact Agent could not claim durable Directive",
      agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
      failure_code: Maraithon.Redaction.error_class(reason)
    )

    {:stop, {:directive_claim_failed, reason}, data}
  end

  defp stop_after_directive_failure(:activation, reason, data) do
    Logger.warning("Durable Directive activation was fenced",
      agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
      directive_reference: Maraithon.Redaction.fingerprint(data.current_directive_id),
      failure_code: Maraithon.Redaction.error_class(reason)
    )

    {:stop, {:directive_activation_failed, reason}, data}
  end

  defp activate_directive_payload_locked(data, "message", payload) when is_map(payload) do
    with message_id when is_binary(message_id) <- payload["message_id"],
         metadata when is_map(metadata) <- payload["metadata"] || %{},
         true <- Map.has_key?(payload, "message") do
      message = payload["message"]
      data = maybe_reset_open_insights_for_refresh(data, message, metadata)
      data = put_message_trigger(data, message, metadata, message_id)

      {:ok,
       append_event!(data, "message_received", %{
         message: message,
         metadata: metadata,
         message_id: message_id
       })}
    else
      _invalid -> {:error, :invalid_directive_payload}
    end
  end

  defp activate_directive_payload_locked(data, "channel_ingress", payload)
       when is_map(payload) do
    with topic when is_binary(topic) <- payload["topic"],
         true <- Map.has_key?(payload, "payload") do
      event_payload = payload["payload"]
      data = put_pubsub_trigger(data, topic, event_payload)

      {:ok,
       append_event!(data, "pubsub_event_received", %{
         topic: topic,
         payload: event_payload
       })}
    else
      _invalid -> {:error, :invalid_directive_payload}
    end
  end

  defp activate_directive_payload_locked(data, kind, payload)
       when kind in ["scheduled_wakeup", "manual_wake", "background_job"] and is_map(payload) do
    with job_type when is_binary(job_type) <- payload["job_type"],
         job_id when is_binary(job_id) <- payload["job_id"],
         job_payload when is_map(job_payload) <- payload["payload"] || %{} do
      data = put_wakeup_trigger(data, job_type, job_id, job_payload)

      if job_type in ["heartbeat", "checkpoint"] do
        {:ok, data}
      else
        {:ok, append_event!(data, "wakeup_received", %{job_id: job_id, job_type: job_type})}
      end
    else
      _invalid -> {:error, :invalid_directive_payload}
    end
  end

  defp activate_directive_payload_locked(_data, _kind, _payload),
    do: {:error, :invalid_directive_payload}

  defp settle_maintenance_directive(data, kind) when kind in [:heartbeat, :checkpoint] do
    now = DateTime.utc_now()

    settlement =
      AgentDirectives.settle_ready_with(
        data.agent_id,
        data.current_directive_id,
        data.owner_token,
        data.current_directive_claim_token,
        "completed",
        nil,
        fn _directive, _claim_now ->
          case kind do
            :heartbeat ->
              updated_data =
                append_event!(data, "heartbeat_emitted", %{
                  timestamp: DateTime.to_iso8601(now)
                })

              with {:ok, _job_id} <- schedule_heartbeat(updated_data) do
                {:ok,
                 updated_data
                 |> Map.put(:last_heartbeat_at, now)
                 |> clear_transient_context()}
              end

            :checkpoint ->
              updated_data =
                append_event!(data, "checkpoint_created", %{
                  timestamp: DateTime.to_iso8601(now)
                })

              with :ok <- persist_exact_snapshot!(updated_data),
                   {:ok, _job_id} <- schedule_checkpoint(updated_data) do
                {:ok,
                 updated_data
                 |> Map.put(:last_checkpoint_at, now)
                 |> clear_transient_context()}
              end
          end
        end
      )

    case settlement do
      {:ok, %{newly_terminal?: true, result: finalized_data}} ->
        event_type = if kind == :heartbeat, do: "heartbeat_emitted", else: "checkpoint_created"
        Logger.info("Agent event", event_log_metadata(event_type, %{}))
        {:next_state, :idle, finalized_data}

      {:ok, %{newly_terminal?: false}} ->
        finalized_data = %{
          clear_transient_context(data)
          | sequence_num: Events.latest_sequence_num(data.agent_id)
        }

        {:next_state, :idle, finalized_data}

      {:error, reason} ->
        {:stop, {:maintenance_directive_settlement_failed, reason}, data}
    end
  end

  defp fail_unstarted_directive(data, error_code) do
    case AgentDirectives.fail(
           data.agent_id,
           data.current_directive_id,
           data.owner_token,
           data.current_directive_claim_token,
           error_code,
           retry_delay_ms: @directive_poll_interval_ms
         ) do
      {:ok, _directive} ->
        {:next_state, :idle, clear_transient_context(data)}

      {:error, reason} ->
        {:stop, {:directive_failure_settlement_failed, reason}, data}
    end
  end

  defp dead_letter_invalid_directive(data) do
    case AgentDirectives.settle_with(
           data.agent_id,
           data.current_directive_id,
           data.owner_token,
           data.current_directive_claim_token,
           "dead_letter",
           "invalid_directive",
           fn _directive, _now -> {:ok, :invalid_directive} end
         ) do
      {:ok, _settlement} ->
        {:next_state, :idle, clear_transient_context(data),
         [{:next_event, :internal, :claim_directive}]}

      {:error, reason} ->
        {:stop, {:directive_dead_letter_failed, reason}, data}
    end
  end

  defp emit_event(%{exact_owner?: true} = data, event_type, payload) do
    emit_exact_event(data, event_type, payload, :ready)
  end

  defp emit_event(data, event_type, payload) do
    sequence_num = data.sequence_num + 1
    Events.append(data.agent_id, event_type, payload, sequence_num: sequence_num)
    Logger.info("Agent event", event_log_metadata(event_type, payload))
    %{data | sequence_num: sequence_num}
  end

  defp emit_exact_event(
         %{current_directive_id: directive_id, current_directive_claim_token: claim_token} = data,
         event_type,
         payload,
         fence_mode
       )
       when is_binary(directive_id) and is_binary(claim_token) do
    case AgentDirectives.with_live_claim(
           data.agent_id,
           directive_id,
           data.owner_token,
           claim_token,
           fence_mode,
           fn _directive, _now -> {:ok, append_event!(data, event_type, payload)} end
         ) do
      {:ok, updated_data} ->
        Logger.info("Agent event", event_log_metadata(event_type, payload))
        updated_data

      {:error, reason} ->
        exit({:exact_directive_event_write_rejected, Maraithon.Redaction.error_class(reason)})
    end
  end

  defp emit_exact_event(data, event_type, payload, fence_mode) do
    case Repo.transaction(fn ->
           case fence_mode do
             :ready -> AgentLeases.fence_ready!(data.agent_id, data.owner_token)
             :owner -> AgentLeases.fence_owner!(data.agent_id, data.owner_token)
           end

           append_event!(data, event_type, payload)
         end) do
      {:ok, updated_data} ->
        Logger.info("Agent event", event_log_metadata(event_type, payload))
        updated_data

      {:error, reason} ->
        exit({:exact_event_write_rejected, Maraithon.Redaction.error_class(reason)})
    end
  end

  defp append_event!(data, event_type, payload) do
    sequence_num = data.sequence_num + 1

    case Events.append(data.agent_id, event_type, payload, sequence_num: sequence_num) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback({:event_append_failed, reason})
    end

    %{data | sequence_num: sequence_num}
  end

  defp event_log_metadata("effect_failed" = event_type, payload) when is_map(payload) do
    [
      event_type: event_type,
      effect_reference: Maraithon.Redaction.fingerprint(payload[:effect_id]),
      effect_type: event_label(payload[:effect_type]),
      failure_code: event_label(payload[:failure_code])
    ]
  end

  defp event_log_metadata("effect_requested" = event_type, payload) when is_map(payload) do
    [
      event_type: event_type,
      effect_reference: Maraithon.Redaction.fingerprint(payload[:effect_id]),
      effect_type: event_label(payload[:effect_type])
    ]
  end

  defp event_log_metadata(event_type, _payload), do: [event_type: event_label(event_type)]

  defp event_label(value) when is_atom(value), do: event_label(Atom.to_string(value))

  defp event_label(value) when is_binary(value) and byte_size(value) <= 128 do
    if String.valid?(value) and Regex.match?(~r/^[A-Za-z0-9._:\/-]+$/, value),
      do: value,
      else: "unknown"
  end

  defp event_label(_value), do: "unknown"

  defp emit_heartbeat(data) do
    now = DateTime.utc_now()
    data = emit_event(data, "heartbeat_emitted", %{timestamp: DateTime.to_iso8601(now)})
    %{data | last_heartbeat_at: now}
  end

  defp emit_checkpoint(%{exact_owner?: true} = data) do
    now = DateTime.utc_now()
    payload = %{timestamp: DateTime.to_iso8601(now)}

    case Repo.transaction(fn ->
           AgentLeases.fence_ready!(data.agent_id, data.owner_token)
           updated_data = append_event!(data, "checkpoint_created", payload)
           persist_exact_snapshot!(updated_data)
           updated_data
         end) do
      {:ok, updated_data} ->
        Logger.info("Agent event", event_log_metadata("checkpoint_created", payload))
        %{updated_data | last_checkpoint_at: now}

      {:error, reason} ->
        exit({:exact_checkpoint_write_rejected, Maraithon.Redaction.error_class(reason)})
    end
  end

  defp emit_checkpoint(data) do
    now = DateTime.utc_now()
    data = emit_event(data, "checkpoint_created", %{timestamp: DateTime.to_iso8601(now)})
    _ = persist_snapshot(data)
    %{data | last_checkpoint_at: now}
  end

  defp persist_exact_snapshot!(data) do
    # The Snapshot trigger admits inserts only from a generation-fenced writer
    # that names its live lease token. Directive settlement and the exact
    # checkpoint both run inside a ready-fenced transaction, so mark it here.
    Maraithon.Effects.ProtocolCutover.require_exact_write!()

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('maraithon.agent_lease_owner_token', $1, true)",
      [data.owner_token]
    )

    behavior_state = measured_snapshot_behavior_state(data)

    case Snapshot.persist(
           data.agent_id,
           data.sequence_num,
           :idle,
           behavior_state,
           data.budget,
           behavior_schema_version(data.behavior_module)
         ) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.error("Exact Agent snapshot persist failed",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        Repo.rollback({:snapshot_persist_failed, reason})
    end
  end

  defp behavior_state_for_call(%{
         behavior_module: module,
         behavior_state: state,
         behavior_cycle_context: cycle_context
       }) do
    if is_atom(module) and function_exported?(module, :put_cycle_context, 2),
      do: module.put_cycle_context(state, cycle_context || %{}),
      else: state
  end

  defp put_behavior_state(%{behavior_module: module} = data, state) do
    if is_atom(module) and function_exported?(module, :pop_cycle_context, 1) do
      case module.pop_cycle_context(state) do
        {durable_state, cycle_context} ->
          %{data | behavior_state: durable_state, behavior_cycle_context: cycle_context}

        durable_state ->
          %{data | behavior_state: durable_state}
      end
    else
      %{data | behavior_state: state}
    end
  end

  # Behaviors may trim transient working data (fetched source bundles) before a
  # checkpoint; the live state is untouched.
  defp snapshot_behavior_state(%{behavior_module: module, behavior_state: state}) do
    if is_atom(module) and function_exported?(module, :snapshot_state, 1),
      do: module.snapshot_state(state),
      else: state
  end

  defp measured_snapshot_behavior_state(data) do
    state = snapshot_behavior_state(data)
    agent_reference = Maraithon.Redaction.fingerprint(data.agent_id)

    case SnapshotBudget.check(state) do
      {:ok, bytes} ->
        Logger.info("Agent checkpoint snapshot measured",
          agent_reference: agent_reference,
          snapshot_bytes: bytes
        )

      {:error, {reason, paths}} ->
        Logger.error("Agent checkpoint snapshot measurement failed",
          agent_reference: agent_reference,
          failure_code: Maraithon.Redaction.error_class(reason),
          paths: Enum.map_join(paths, ",", &Enum.join(&1, "."))
        )
    end

    state
  end

  # Best-effort only for the retained legacy compatibility path. Exact
  # checkpoint Event + Snapshot writes share one ready-fenced transaction.
  # Legacy checkpoints are handled only while idle.
  defp persist_snapshot(data) do
    behavior_state = measured_snapshot_behavior_state(data)

    case Snapshot.persist(
           data.agent_id,
           data.sequence_num,
           :idle,
           behavior_state,
           data.budget,
           behavior_schema_version(data.behavior_module)
         ) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning("Agent checkpoint snapshot failed",
          agent_id: data.agent_id,
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("Agent checkpoint snapshot crashed",
        agent_id: data.agent_id,
        failure_code: Maraithon.Redaction.error_class(error)
      )

      :ok
  end

  # A corrupt or schema-incompatible snapshot must not wedge agent startup —
  # fall back to a fresh behavior state if loading or decoding fails.
  defp safe_load_snapshot(agent_id) do
    Snapshot.latest(agent_id)
  rescue
    error ->
      Logger.warning("Agent snapshot load failed, starting fresh",
        agent_id: agent_id,
        failure_code: Maraithon.Redaction.error_class(error)
      )

      nil
  end

  # SPEC 08 R3 — layered snapshot restore. Returns `{behavior_state, budget}`.
  #
  # Three independent rescue boundaries, deliberately NOT collapsed into one:
  # a bug in a behavior's own migrate_state/3 (step 4) or
  # reconcile_restored_state/2 (step 6) degrades to "skip that step, keep
  # restoring" rather than "abandon the entire snapshot and start with zero
  # accumulated context". The outer boundary here mirrors
  # safe_load_snapshot/1's philosophy: anything else unexpected falls all the
  # way back to a fresh init, exactly like the no-snapshot branch.
  #
  # Public (@doc false) so restore semantics are directly testable; production
  # calls it only from recovering/2.
  @doc false
  def restore_from_snapshot(behavior_module, agent_config, snapshot, agent_id) do
    {restore_behavior_state(behavior_module, agent_config, snapshot),
     restore_budget(agent_config, snapshot)}
  rescue
    error ->
      Logger.error("Agent snapshot restore failed, starting with fresh behavior state",
        agent_id: agent_id,
        behavior: inspect(behavior_module),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      {behavior_module.init(agent_config), init_budget(agent_config["budget"])}
  end

  defp restore_behavior_state(behavior_module, agent_config, snapshot) do
    # Step 1: fresh defaults. Used ONLY as the fallback source for keys absent
    # from the snapshot — every key present in the snapshot overwrites its
    # default in the merge below, so any id/timestamp init/1 happens to mint
    # for a snapshotted key is discarded, never persisted, never observed.
    defaults = behavior_module.init(agent_config)

    current_version = behavior_schema_version(behavior_module)
    # Defensive nil-guard even though the DB default guarantees 0 for legacy
    # rows — a hand-edited row or a map built elsewhere must still restore.
    stored_version = Map.get(snapshot, :schema_version) || 0

    snapshot.behavior_state
    |> maybe_migrate_state(behavior_module, stored_version, current_version, agent_config)
    |> merge_onto_defaults(defaults)
    |> maybe_reconcile_restored_state(behavior_module, agent_config)
  end

  # Step 4: optional versioned migration, own rescue boundary — a broken
  # migration skips migration, not the restore.
  defp maybe_migrate_state(state, behavior_module, stored_version, current_version, agent_config)
       when stored_version < current_version do
    if function_exported?(behavior_module, :migrate_state, 3) do
      try do
        behavior_module.migrate_state(stored_version, state, agent_config)
      rescue
        error ->
          Logger.warning("Behavior migrate_state failed, restoring unmigrated snapshot state",
            behavior: inspect(behavior_module),
            stored_version: stored_version,
            current_version: current_version,
            failure_code: Maraithon.Redaction.error_class(error)
          )

          state
      end
    else
      state
    end
  end

  defp maybe_migrate_state(state, _behavior_module, _stored, _current, _agent_config), do: state

  # Step 5: shallow, top-level merge — snapshot/migrated value wins for every
  # key present in it; a key absent from it (new in this release) falls back
  # to the fresh init/1 default. Deliberately NOT a deep merge: nested maps
  # are replaced wholesale by the behaviors that own them, and a recursive
  # merge would resurrect stale sub-keys from init/1 placeholders over real
  # accumulated data. Non-map states (Behavior.state() is any()) restore
  # verbatim — there are no defaults to merge onto.
  defp merge_onto_defaults(restored, defaults)
       when is_map(restored) and not is_struct(restored) and
              is_map(defaults) and not is_struct(defaults) do
    Map.merge(defaults, restored)
  end

  defp merge_onto_defaults(restored, _defaults), do: restored

  # Step 6: optional config reconciliation, own rescue boundary — a broken
  # reconciliation skips reconciliation, not the restore.
  defp maybe_reconcile_restored_state(state, behavior_module, agent_config) do
    if function_exported?(behavior_module, :reconcile_restored_state, 2) do
      try do
        behavior_module.reconcile_restored_state(state, agent_config)
      rescue
        error ->
          Logger.warning("Behavior reconcile_restored_state failed, keeping merged state",
            behavior: inspect(behavior_module),
            failure_code: Maraithon.Redaction.error_class(error)
          )

          state
      end
    else
      state
    end
  end

  # Step 7: budget merges over fresh defaults the same shallow, snapshot-wins
  # way — generalizing the `refilled_at` defensive-read prior art
  # (maybe_refill_budget/1) so any future budget key is tolerant by
  # construction instead of needing another defensive Map.get at its read
  # site.
  defp restore_budget(agent_config, snapshot) do
    snapshot_budget =
      case snapshot.budget do
        budget when is_map(budget) and not is_struct(budget) -> budget
        _other -> %{}
      end

    Map.merge(init_budget(agent_config["budget"]), snapshot_budget)
  end

  defp behavior_schema_version(behavior_module) do
    if function_exported?(behavior_module, :schema_version, 0) do
      behavior_module.schema_version()
    else
      0
    end
  end

  defp schedule_directive_poll do
    Process.send_after(self(), :directive_poll, @directive_poll_interval_ms)
    :ok
  end

  defp schedule_heartbeat(data) do
    interval = get_config(:heartbeat_interval_ms, 900_000)
    Scheduler.schedule_unique_in(data.agent_id, "heartbeat", interval)
  end

  defp schedule_checkpoint(data) do
    interval = get_config(:checkpoint_interval_ms, 600_000)
    Scheduler.schedule_unique_in(data.agent_id, "checkpoint", interval)
  end

  defp schedule_next_wakeup(data) do
    case data.behavior_module.next_wakeup(data.behavior_state) do
      {:relative, ms} ->
        Scheduler.schedule_scoped_unique_in(
          data.agent_id,
          "wakeup",
          ms,
          @periodic_wakeup_scope,
          %{},
          @periodic_wakeup_opts
        )

      {:absolute, datetime} ->
        Scheduler.schedule_scoped_unique_at(
          data.agent_id,
          "wakeup",
          datetime,
          @periodic_wakeup_scope,
          %{},
          @periodic_wakeup_opts
        )

      :none ->
        Scheduler.cancel_scoped(
          data.agent_id,
          "wakeup",
          @periodic_wakeup_scope,
          @periodic_wakeup_opts
        )
    end
  end

  defp close_terminated_effects(%{agent_id: agent_id, owner_token: owner_token})
       when is_binary(agent_id) do
    case cancel_active_effects(agent_id, @terminated_effect_reason, owner_token) do
      {:ok, _cancelled_count} = success ->
        success

      {:error, reason} = error ->
        Logger.warning("Agent termination left effect cleanup for recovery",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        error
    end
  end

  defp close_terminated_effects(_data), do: {:ok, 0}

  defp close_terminated_run(%{current_run_id: run_id, agent_id: agent_id})
       when is_binary(run_id) and is_binary(agent_id) do
    result =
      try do
        with :ok <- reconcile_run_terminal_results(run_id, agent_id),
             {:ok, summary} <-
               Agents.cancel_agent_run(run_id, agent_id, @terminated_run_reason),
             {:ok, _count} <- Effects.acknowledge_terminal_results_for_run(run_id, agent_id) do
          {:ok, summary}
        end
      rescue
        _error -> {:error, :agent_run_repository_unavailable}
      catch
        :exit, _reason -> {:error, :agent_run_repository_unavailable}
      end

    case result do
      {:ok, %{cancelled: true, steps: step_count}} ->
        Logger.info("Cancelled current agent run during process termination",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          status: "cancelled",
          item_count: step_count
        )

      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cancel current agent run during process termination",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )
    end
  end

  defp close_terminated_run(_data), do: :ok

  defp active_terminal_result_replay?(
         effect_id,
         %{agent_id: agent_id, current_run_id: run_id}
       )
       when is_binary(effect_id) and is_binary(agent_id) and is_binary(run_id) do
    case Effects.get_terminal_result(effect_id, agent_id) do
      %{agent_run_id: ^run_id} -> true
      _other -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp active_terminal_result_replay?(_effect_id, _data), do: false

  defp acknowledge_terminal_effect_result(effect_id, agent_id) do
    case Effects.acknowledge_terminal_result(effect_id, agent_id) do
      {:ok, _count} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp reconcile_abandoned_terminal_result(effect_id, data, active_continuation?) do
    agent_id = data.agent_id

    case Effects.get_terminal_result(effect_id, agent_id) do
      nil ->
        data

      %{agent_run_id: run_id} = effect when is_binary(run_id) ->
        if active_continuation? and run_id == data.current_run_id do
          # Keep the result replayable until the whole run reaches a durable
          # terminal state. A crash can then cancel/reconcile the exact run.
          data
        else
          outcome =
            with :ok <- reconcile_abandoned_run_step(effect) do
              case Agents.cancel_agent_run(run_id, agent_id, @abandoned_result_reason) do
                {:ok, _summary} ->
                  acknowledge_terminal_effect_result(effect_id, agent_id)

                {:error, :run_not_found} ->
                  acknowledge_terminal_effect_result(effect_id, agent_id)

                {:error, _reason} ->
                  :error
              end
            end

          if outcome == :ok and run_id == data.current_run_id,
            do: %{data | current_run_id: nil},
            else: data
        end

      _effect_without_run ->
        _ack_result = acknowledge_terminal_effect_result(effect_id, agent_id)
        data
    end
  rescue
    _error -> data
  catch
    :exit, _reason -> data
  end

  defp reconcile_abandoned_run_step(effect) do
    Agents.reconcile_terminal_effect_step(effect)
  end

  defp cancel_active_effects(agent_id, reason, owner_token) do
    result =
      try do
        EffectRunner.cancel_active_for_agent(agent_id, reason,
          expected_runtime_owner_generation: owner_token
        )
      rescue
        _error -> {:error, :effect_repository_unavailable}
      catch
        :exit, _reason -> {:error, :effect_repository_unavailable}
      end

    case result do
      {:ok, cancelled_count} ->
        if cancelled_count > 0 do
          Logger.info("Cancelled active effects after Agent continuation ended",
            agent_reference: Maraithon.Redaction.fingerprint(agent_id),
            status: "cancelled",
            recovered: cancelled_count
          )
        end

        {:ok, cancelled_count}

      {:error, reason} = error ->
        Logger.warning("Failed to cancel active effects after Agent continuation ended",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        error
    end
  end

  defp request_effect(data, {effect_type, params}) do
    request_effect(data, {effect_type, nil, params})
  end

  defp request_effect(data, {effect_type, tool_name, raw_params}) do
    raw_params = durable_effect_params(raw_params, effect_type, tool_name)

    {params, validation_error} =
      with {:ok, base} <- validate_effect_params(effect_type, raw_params),
           enriched <- maybe_inject_memory_into_effect(data, effect_type, base),
           {:ok, bounded} <- validate_effect_params(effect_type, enriched),
           {:ok, persistable} <- Effects.prepare_params(tool_name, bounded) do
        {persistable, nil}
      else
        {:error, reason} -> {%{}, reason}
      end

    effect_id = Ecto.UUID.generate()
    idempotency_key = Ecto.UUID.generate()

    effect_info = %{
      type: effect_type,
      tool_name: tool_name,
      params: params,
      requested_at: DateTime.utc_now(),
      run_id: data.current_run_id,
      run_step_id: record_effect_step(data, effect_type, tool_name, params)
    }

    {write_result, data} =
      if validation_error do
        data =
          emit_event(data, "effect_requested", %{
            effect_id: effect_id,
            effect_type: to_string(effect_type),
            idempotency_key: idempotency_key
          })

        {{:error, {:invalid_effect_request, validation_error}}, data}
      else
        persist_effect_request(
          data,
          effect_info,
          effect_id,
          idempotency_key,
          effect_type,
          tool_name,
          params
        )
      end

    data = %{data | pending_effects: Map.put(data.pending_effects, effect_id, effect_info)}

    # Re-arm the effect timeout explicitly: a same-state transition
    # (waiting_effect -> waiting_effect on a chained effect) does not run the
    # :enter callback, so without this the whole chain runs on the first
    # effect's deadline.
    actions = [{:state_timeout, pending_effect_timeout_ms(data.pending_effects), :effect_timeout}]

    case write_result do
      {:ok, _effect_id} ->
        {:next_state, :waiting_effect, data, actions}

      {:error, {:invalid_effect_request, reason}} ->
        Logger.warning("Effect request rejected before persistence",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          effect_type: event_label(effect_type),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:next_state, :waiting_effect, data,
         actions ++
           [{:next_event, :internal, {:synthetic_effect_result, effect_id, {:error, reason}}}]}

      {:error, reason} ->
        Logger.error("Effect outbox write failed",
          agent_id: data.agent_id,
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        failure = {:error, {:effect_write_failed, reason}}

        {:next_state, :waiting_effect, data,
         actions ++ [{:next_event, :internal, {:synthetic_effect_result, effect_id, failure}}]}
    end
  end

  defp persist_effect_request(
         %{
           current_directive_id: directive_id,
           current_directive_claim_token: claim_token,
           current_run_id: run_id
         } = data,
         effect_info,
         effect_id,
         idempotency_key,
         effect_type,
         tool_name,
         params
       )
       when is_binary(directive_id) and is_binary(claim_token) and is_binary(run_id) do
    result =
      with :ok <- renew_effect_admission_authority(data) do
        AgentDirectives.with_live_claim(
          data.agent_id,
          directive_id,
          data.owner_token,
          claim_token,
          :ready,
          fn directive, now ->
            with {:ok, persisted_effect_id} <-
                   Effects.request_prepared(data.agent_id, effect_type, tool_name, params, %{
                     effect_id: effect_id,
                     idempotency_key: idempotency_key,
                     agent_run_id: run_id,
                     agent_run_step_id: effect_info.run_step_id,
                     runtime_owner_generation: data.owner_token
                   }),
                 {:ok, _directive, _ordinal} <-
                   AgentDirectives.admit_effect_locked(directive, run_id, now) do
              updated_data =
                append_event!(data, "effect_requested", %{
                  effect_id: effect_id,
                  effect_type: to_string(effect_type),
                  idempotency_key: idempotency_key
                })

              {:ok, {persisted_effect_id, updated_data}}
            end
          end
        )
      end

    case result do
      {:ok, {persisted_effect_id, updated_data}} ->
        Logger.info(
          "Agent event",
          event_log_metadata("effect_requested", %{
            effect_id: effect_id,
            effect_type: effect_type
          })
        )

        {{:ok, persisted_effect_id}, updated_data}

      {:error, reason} ->
        {{:error, reason}, data}
    end
  rescue
    exception ->
      {{:error, {:effect_write_failed, Maraithon.Redaction.error_class(exception)}}, data}
  end

  defp persist_effect_request(
         data,
         effect_info,
         effect_id,
         idempotency_key,
         effect_type,
         tool_name,
         params
       ) do
    result =
      try do
        Effects.request_prepared(data.agent_id, effect_type, tool_name, params, %{
          effect_id: effect_id,
          idempotency_key: idempotency_key,
          agent_run_id: data.current_run_id,
          agent_run_step_id: effect_info.run_step_id,
          runtime_owner_generation: data.owner_token
        })
      rescue
        exception ->
          {:error, {:effect_write_failed, Maraithon.Redaction.error_class(exception)}}
      end

    data =
      if match?({:ok, _effect_id}, result) do
        emit_event(data, "effect_requested", %{
          effect_id: effect_id,
          effect_type: to_string(effect_type),
          idempotency_key: idempotency_key
        })
      else
        data
      end

    {result, data}
  end

  defp durable_effect_params(args, effect_type, tool_name)
       when effect_type in [:tool_call, "tool_call"] and is_binary(tool_name),
       do: %{"args" => args}

  defp durable_effect_params(params, _effect_type, _tool_name), do: params

  defp validate_effect_params(effect_type, params)
       when effect_type in [:llm_call, "llm_call"] do
    case Maraithon.LLM.RequestBudget.validate(params) do
      {:ok, %{"_on_reasoning" => _callback}} ->
        {:error, {:invalid_request, %{reason: "durable_callback_unsupported"}}}

      result ->
        result
    end
  end

  defp validate_effect_params(_effect_type, params), do: {:ok, params}

  defp pending_effect_timeout_ms(pending_effects) when is_map(pending_effects) do
    pending_effects
    |> Map.values()
    |> Enum.map(&effect_timeout_ms/1)
    |> Enum.max(fn -> @default_effect_timeout_ms end)
  end

  # `timeout_ms` on an LLM request is the per-claim provider budget. The
  # durable runner may need all counted claims, so the Agent continuation uses
  # its separately bounded whole-effect window even when the request is explicit.
  defp effect_timeout_ms(%{type: type}) when type in [:llm_call, "llm_call"],
    do: @default_llm_effect_timeout_ms

  defp effect_timeout_ms(%{params: params}) when is_map(params) do
    case read_timeout_ms(params) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms + @effect_timeout_buffer_ms

      _other ->
        @default_effect_timeout_ms
    end
  end

  defp effect_timeout_ms(_effect_info), do: @default_effect_timeout_ms

  defp read_timeout_ms(params) do
    Map.get(params, "timeout_ms") || Map.get(params, :timeout_ms)
  end

  defp ensure_current_run(%{current_run_id: run_id} = data) when is_binary(run_id), do: data

  defp ensure_current_run(data) do
    agent = %Maraithon.Agents.Agent{
      id: data.agent_id,
      user_id: data.user_id,
      project_id: data.project_id,
      behavior: data.behavior,
      agent_package_id: data.agent_package_id,
      agent_package_version_id: data.agent_package_version_id
    }

    manifest = data.config["_harness_manifest"] || %{}
    now = DateTime.utc_now()

    attrs = %{
      trigger_type: trigger_type(data.current_trigger),
      trigger: to_jsonable(data.current_trigger || %{}),
      resolved_model: Manifest.get(manifest, :model),
      intelligence: Manifest.get(manifest, :intelligence),
      active_skills: Manifest.active_skill_ids(manifest),
      tool_allowlist: Manifest.get(manifest, :tool_allowlist, []),
      budget_snapshot: %{
        "llm_calls" => data.budget.llm_calls,
        "tool_calls" => data.budget.tool_calls
      },
      metadata: %{
        "package_manifest" => data.agent_package_version_id != nil,
        "started_by_runtime_at" => DateTime.to_iso8601(now)
      }
    }

    run_result =
      cond do
        is_binary(data.current_directive_id) and
            is_binary(data.current_directive_claim_token) ->
          AgentDirectives.with_live_claim(
            data.agent_id,
            data.current_directive_id,
            data.owner_token,
            data.current_directive_claim_token,
            :ready,
            fn directive, claim_now ->
              with {:ok, run} <- Agents.start_runtime_agent_run(agent, attrs),
                   {:ok, _directive} <-
                     AgentDirectives.bind_run_locked(directive, run.id, claim_now) do
                {:ok, run}
              end
            end
          )

        is_binary(data.owner_token) ->
          Agents.start_exact_runtime_agent_run(agent, data.owner_token, attrs)

        true ->
          # Compatibility-only unfenced launches are never used by AgentSupervisor.
          Agents.start_runtime_agent_run(agent, attrs)
      end

    case run_result do
      {:ok, run} ->
        %{data | current_run_id: run.id}

      {:error, reason} ->
        Logger.error("Failed to record agent run",
          agent_id: data.agent_id,
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        exit(:agent_run_start_failed)
    end
  end

  defp record_effect_step(%{current_run_id: nil}, _effect_type, _tool_name, _params), do: nil

  defp record_effect_step(
         %{
           current_directive_id: directive_id,
           current_directive_claim_token: claim_token
         } = data,
         effect_type,
         tool_name,
         params
       )
       when is_binary(directive_id) and is_binary(claim_token) do
    case AgentDirectives.with_live_claim(
           data.agent_id,
           directive_id,
           data.owner_token,
           claim_token,
           :ready,
           fn _directive, _now ->
             case persist_run_step(data, effect_type, tool_name, params) do
               {:ok, step_id} -> {:ok, step_id}
               {:error, reason} -> {:error, reason}
             end
           end
         ) do
      {:ok, step_id} ->
        step_id

      {:error, reason} ->
        log_run_step_error(data, reason)
        nil
    end
  end

  defp record_effect_step(data, effect_type, tool_name, params) do
    case persist_run_step(data, effect_type, tool_name, params) do
      {:ok, step_id} ->
        step_id

      {:error, reason} ->
        log_run_step_error(data, reason)
        nil
    end
  end

  defp persist_run_step(data, effect_type, tool_name, params) do
    attrs = %{
      step_type: step_type(effect_type),
      effect_type: to_string(effect_type),
      tool_name: tool_name,
      status: "requested",
      resolved_model: model_from_params(params),
      intelligence: intelligence_from_params(params),
      request_payload: to_jsonable(params),
      generation_mode: generation_mode_for_effect(effect_type)
    }

    case Agents.record_agent_run_step(data.current_run_id, data.agent_id, attrs) do
      {:ok, step} -> {:ok, step.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_run_step_error(data, reason) do
    Logger.error("Failed to record agent run step",
      agent_id: data.agent_id,
      run_id: data.current_run_id,
      failure_code: Maraithon.Redaction.error_class(reason)
    )
  end

  defp persist_effect_outcome(
         %{
           current_directive_id: directive_id,
           current_directive_claim_token: claim_token
         } = data,
         effect_id,
         effect_info,
         result
       )
       when is_binary(directive_id) and is_binary(claim_token) do
    event = effect_outcome_event(effect_id, effect_info, result)

    case AgentDirectives.with_live_claim(
           data.agent_id,
           directive_id,
           data.owner_token,
           claim_token,
           :ready,
           fn _directive, _now ->
             with :ok <- record_effect_step_result(effect_info, result),
                  :ok <-
                    update_current_run_from_effect_result(
                      data.current_run_id,
                      effect_info,
                      result
                    ) do
               {:ok, append_event!(data, event.type, event.payload)}
             end
           end
         ) do
      {:ok, updated_data} ->
        Logger.info("Agent event", event_log_metadata(event.type, event.payload))
        updated_data

      {:error, reason} ->
        Logger.error("Exact Agent lost authority while recording an Effect result",
          agent_id: data.agent_id,
          run_id: data.current_run_id,
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        exit({:shutdown, :exact_effect_result_fence_lost})
    end
  end

  defp persist_effect_outcome(data, effect_id, effect_info, result) do
    :ok = record_effect_step_result(effect_info, result)
    :ok = update_current_run_from_effect_result(data.current_run_id, effect_info, result)
    event = effect_outcome_event(effect_id, effect_info, result)
    emit_event(data, event.type, event.payload)
  end

  defp effect_outcome_event(effect_id, effect_info, {:ok, result_data}) do
    %{
      type: "effect_completed",
      payload: %{
        effect_id: effect_id,
        effect_type: to_string(effect_info.type),
        result: result_data
      }
    }
  end

  defp effect_outcome_event(effect_id, effect_info, {:error, reason}) do
    %{
      type: "effect_failed",
      payload: %{
        effect_id: effect_id,
        effect_type: to_string(effect_info.type),
        failure_code: Maraithon.Redaction.error_class(reason),
        error: Maraithon.Redaction.error_summary(reason)
      }
    }
  end

  defp record_effect_step_result(%{run_step_id: nil}, _result), do: :ok

  defp record_effect_step_result(effect_info, {:ok, result_data}) do
    attrs = %{
      status: "completed",
      response_payload: to_jsonable(result_data),
      resolved_model: model_from_response(result_data) || model_from_params(effect_info.params),
      intelligence: intelligence_from_params(effect_info.params),
      finish_reason: finish_reason_from_response(result_data),
      generation_mode: generation_mode_for_effect(effect_info.type)
    }

    update_run_step(effect_info.run_step_id, attrs)
  end

  defp record_effect_step_result(effect_info, {:error, reason}) do
    update_run_step(effect_info.run_step_id, %{
      status: "failed",
      error: Maraithon.Redaction.error_summary(reason),
      response_payload: %{"error" => Maraithon.Redaction.error_summary(reason)}
    })
  end

  defp update_current_run_from_effect_result(run_id, effect_info, {:ok, result_data}),
    do: update_current_run_from_effect(run_id, effect_info, result_data)

  defp update_current_run_from_effect_result(run_id, effect_info, {:error, reason}),
    do: update_current_run_error(run_id, effect_info, reason)

  defp update_current_run_from_effect(nil, _effect_info, _result_data), do: :ok

  defp update_current_run_from_effect(run_id, %{type: :llm_call} = effect_info, result_data) do
    case Agents.update_agent_run(run_id, %{
           resolved_model:
             model_from_response(result_data) || model_from_params(effect_info.params),
           intelligence: intelligence_from_params(effect_info.params),
           finish_reason: finish_reason_from_response(result_data),
           generation_mode: "llm"
         }) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_current_run_from_effect(_run_id, _effect_info, _result_data), do: :ok

  defp update_current_run_error(nil, _effect_info, _reason), do: :ok

  defp update_current_run_error(run_id, %{type: :llm_call} = effect_info, reason) do
    case Agents.update_agent_run(run_id, %{
           resolved_model: model_from_params(effect_info.params),
           intelligence: intelligence_from_params(effect_info.params),
           finish_reason: "error",
           generation_mode: "error",
           error: Maraithon.Redaction.error_summary(reason)
         }) do
      {:ok, _run} -> :ok
      {:error, update_reason} -> {:error, update_reason}
    end
  end

  defp update_current_run_error(_run_id, _effect_info, _reason), do: :ok

  defp complete_current_run(
         %{
           current_run_id: run_id,
           current_directive_id: directive_id,
           current_directive_claim_token: claim_token
         } = data,
         event_type,
         payload
       )
       when is_binary(run_id) and is_binary(directive_id) and is_binary(claim_token) do
    run_status = if to_string(event_type) == "agent_error", do: "failed", else: "completed"

    attrs =
      %{
        status: run_status,
        metadata: %{"terminal_event" => to_string(event_type)}
      }
      |> maybe_put_error(payload)

    settlement =
      AgentDirectives.settle_ready_with(
        data.agent_id,
        directive_id,
        data.owner_token,
        claim_token,
        "completed",
        nil,
        fn _directive, _now ->
          updated_data = append_terminal_run_event!(data, event_type, payload)

          with :ok <- reconcile_run_terminal_results(run_id, data.agent_id),
               {:ok, _run} <- Agents.complete_agent_run(run_id, attrs),
               {:ok, _count} <-
                 Effects.acknowledge_terminal_results_for_run(run_id, data.agent_id),
               :ok <- persist_exact_snapshot!(updated_data) do
            {:ok, clear_completed_work_context(updated_data)}
          end
        end
      )

    case settlement do
      {:ok, %{newly_terminal?: true, result: finalized_data}} ->
        log_terminal_run_event(event_type, payload)
        finalized_data

      {:ok, %{newly_terminal?: false}} ->
        # The commit may have succeeded while the caller lost its acknowledgement.
        # Immutable terminal claim proof makes this a read-only convergence path.
        %{
          clear_completed_work_context(data)
          | sequence_num: Events.latest_sequence_num(data.agent_id)
        }

      {:error, reason} when reason in [:node_authority_lost, :partition_authority_lost] ->
        if durable_authority_draining?(data) do
          exit(:normal)
        else
          log_current_run_settlement_failure(data, run_id, directive_id, reason)

          data
        end

      {:error, reason} ->
        log_current_run_settlement_failure(data, run_id, directive_id, reason)
        data
    end
  end

  defp complete_current_run(%{current_run_id: nil} = data, _event_type, _payload), do: data

  defp complete_current_run(data, event_type, payload) do
    data =
      if event_type == :idle do
        data
      else
        emit_event(data, to_string(event_type), payload)
      end

    status = if to_string(event_type) == "agent_error", do: "failed", else: "completed"

    attrs =
      %{
        status: status,
        metadata: %{"terminal_event" => to_string(event_type)}
      }
      |> maybe_put_error(payload)

    run_id = data.current_run_id

    result =
      with :ok <- reconcile_run_terminal_results(run_id, data.agent_id),
           {:ok, run} <- Agents.complete_agent_run(run_id, attrs) do
        {:ok, run}
      end

    case result do
      {:ok, _run} ->
        acknowledge_terminal_effect_results_for_run(run_id, data.agent_id)
        %{data | current_run_id: nil}

      {:error, reason} ->
        Logger.error("Failed to complete agent run",
          agent_id: data.agent_id,
          run_id: data.current_run_id,
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        data
    end
  end

  defp log_current_run_settlement_failure(data, run_id, directive_id, reason) do
    Logger.error("Failed to atomically settle Agent Directive",
      agent_id: data.agent_id,
      run_id: run_id,
      directive_reference: Maraithon.Redaction.fingerprint(directive_id),
      failure_code: Maraithon.Redaction.error_class(reason)
    )
  end

  defp append_terminal_run_event!(data, :idle, _payload) do
    append_event!(data, "agent_run_completed", %{
      run_id: data.current_run_id,
      outcome: "idle"
    })
  end

  defp append_terminal_run_event!(data, event_type, payload) do
    append_event!(data, to_string(event_type), payload)
  end

  defp log_terminal_run_event(:idle, _payload) do
    Logger.info("Agent event", event_log_metadata("agent_run_completed", %{}))
  end

  defp log_terminal_run_event(event_type, payload) do
    Logger.info("Agent event", event_log_metadata(to_string(event_type), payload))
  end

  defp clear_completed_work_context(data) do
    data
    |> Map.put(:current_run_id, nil)
    |> clear_transient_context()
  end

  defp reconcile_run_terminal_results(run_id, agent_id) do
    with {:ok, terminal_results} <- Effects.list_terminal_results_for_run(run_id, agent_id),
         :ok <- reconcile_terminal_effect_steps(terminal_results) do
      :ok
    end
  end

  defp reconcile_terminal_effect_steps(terminal_results) do
    if Repo.in_transaction?() do
      Agents.reconcile_terminal_effect_steps_in_transaction(terminal_results)
    else
      Agents.reconcile_terminal_effect_steps(terminal_results)
    end
  end

  defp reconcile_persisted_active_run(%{active_run_id: nil}), do: :ok

  defp reconcile_persisted_active_run(%{id: agent_id, active_run_id: run_id})
       when is_binary(agent_id) and is_binary(run_id) do
    with :ok <- reconcile_run_terminal_results(run_id, agent_id),
         {:ok, _summary} <- Agents.cancel_agent_run(run_id, agent_id, @orphaned_run_reason),
         {:ok, _count} <- Effects.acknowledge_terminal_results_for_run(run_id, agent_id) do
      :ok
    end
  end

  defp cancel_current_run(
         %{
           current_run_id: run_id,
           current_directive_id: directive_id,
           current_directive_claim_token: claim_token
         } = data,
         reason
       )
       when is_binary(run_id) and is_binary(directive_id) and is_binary(claim_token) do
    settlement =
      AgentDirectives.settle_with(
        data.agent_id,
        directive_id,
        data.owner_token,
        claim_token,
        "cancelled",
        "cancelled",
        fn _directive, _now ->
          updated_data =
            append_event!(data, "agent_run_cancelled", %{
              run_id: run_id,
              failure_code: Maraithon.Redaction.error_class(reason)
            })

          with :ok <- reconcile_run_terminal_results(run_id, data.agent_id),
               {:ok, _summary} <- Agents.cancel_agent_run(run_id, data.agent_id, reason),
               {:ok, _count} <-
                 Effects.acknowledge_terminal_results_for_run(run_id, data.agent_id) do
            {:ok, clear_completed_work_context(updated_data)}
          end
        end
      )

    case settlement do
      {:ok, %{newly_terminal?: true, result: finalized_data}} ->
        Logger.info("Agent event", event_log_metadata("agent_run_cancelled", %{}))
        finalized_data

      {:ok, %{newly_terminal?: false}} ->
        %{
          clear_completed_work_context(data)
          | sequence_num: Events.latest_sequence_num(data.agent_id)
        }

      {:error, cancellation_error} ->
        Logger.warning("Failed to atomically cancel current Directive run",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          directive_reference: Maraithon.Redaction.fingerprint(directive_id),
          failure_code: Maraithon.Redaction.error_class(cancellation_error)
        )

        data
    end
  rescue
    _error -> data
  catch
    :exit, _reason -> data
  end

  defp cancel_current_run(%{current_run_id: nil} = data, _reason), do: data

  defp cancel_current_run(data, reason) do
    run_id = data.current_run_id

    result =
      with :ok <- reconcile_run_terminal_results(run_id, data.agent_id),
           {:ok, summary} <- Agents.cancel_agent_run(run_id, data.agent_id, reason) do
        {:ok, summary}
      end

    case result do
      {:ok, _summary} ->
        acknowledge_terminal_effect_results_for_run(run_id, data.agent_id)
        %{data | current_run_id: nil}

      {:error, cancellation_error} ->
        Logger.warning("Failed to cancel current run during intentional stop",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          failure_code: Maraithon.Redaction.error_class(cancellation_error)
        )

        data
    end
  rescue
    _error -> data
  catch
    :exit, _reason -> data
  end

  defp fail_current_run(
         %{
           current_run_id: run_id,
           current_directive_id: directive_id,
           current_directive_claim_token: claim_token
         } = data,
         reason
       )
       when is_binary(run_id) and is_binary(directive_id) and is_binary(claim_token) do
    error_summary = Maraithon.Redaction.error_summary(reason)

    settlement =
      AgentDirectives.settle_ready_with(
        data.agent_id,
        directive_id,
        data.owner_token,
        claim_token,
        "completed",
        nil,
        fn _directive, _now ->
          updated_data =
            append_event!(data, "agent_run_failed", %{
              run_id: run_id,
              failure_code: Maraithon.Redaction.error_class(reason)
            })

          with :ok <- reconcile_run_terminal_results(run_id, data.agent_id),
               {:ok, _run} <- Agents.fail_agent_run(run_id, %{error: error_summary}),
               {:ok, _count} <-
                 Effects.acknowledge_terminal_results_for_run(run_id, data.agent_id),
               :ok <- persist_exact_snapshot!(updated_data) do
            {:ok, clear_completed_work_context(updated_data)}
          end
        end
      )

    case settlement do
      {:ok, %{newly_terminal?: true, result: finalized_data}} ->
        Logger.info("Agent event", event_log_metadata("agent_run_failed", %{}))
        finalized_data

      {:ok, %{newly_terminal?: false}} ->
        %{
          clear_completed_work_context(data)
          | sequence_num: Events.latest_sequence_num(data.agent_id)
        }

      {:error, failure_reason} ->
        Logger.warning("Failed to atomically close Directive after Agent failure",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          directive_reference: Maraithon.Redaction.fingerprint(directive_id),
          failure_code: Maraithon.Redaction.error_class(failure_reason)
        )

        data
    end
  end

  defp fail_current_run(%{current_run_id: nil} = data, _reason), do: data

  defp fail_current_run(data, reason) do
    run_id = data.current_run_id

    result =
      with :ok <- reconcile_run_terminal_results(run_id, data.agent_id),
           {:ok, run} <-
             Agents.fail_agent_run(run_id, %{
               error: Maraithon.Redaction.error_summary(reason)
             }) do
        {:ok, run}
      end

    case result do
      {:ok, _run} ->
        acknowledge_terminal_effect_results_for_run(run_id, data.agent_id)
        %{data | current_run_id: nil}

      {:error, failure_reason} ->
        Logger.warning("Failed to close current run after Agent failure",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          failure_code: Maraithon.Redaction.error_class(failure_reason)
        )

        data
    end
  end

  defp update_run_step(nil, _attrs), do: :ok

  defp update_run_step(step_id, attrs) do
    case Agents.update_agent_run_step(step_id, attrs) do
      {:ok, _step} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to update run step",
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:error, reason}
    end
  end

  defp build_context(data) do
    context = %{
      agent_id: data.agent_id,
      user_id: data.user_id,
      project_id: data.project_id,
      agent_package_id: data.agent_package_id,
      agent_package_version_id: data.agent_package_version_id,
      run_id: data.current_run_id,
      harness_manifest: data.config["_harness_manifest"],
      timestamp: DateTime.utc_now(),
      budget: data.budget,
      recent_events: recent_operator_events(data.user_id),
      user_memory: UserMemory.prompt_context(data.user_id),
      deep_memory:
        Memory.prompt_context(data.user_id,
          query: effect_query(data),
          limit: 8
        ),
      memory_tools:
        ~w(write_memory recall_memory list_memories forget_memory record_memory_feedback update_memory_confidence),
      open_loops:
        OpenLoops.snapshot(data.user_id,
          query: data.current_message,
          limit: 8,
          include_memory?: false
        ),
      open_loop_tools:
        ~w(get_open_loops list_todos upsert_todos resolve_todo list_people get_relationship_context learn_relationship_context recall_memory write_memory record_memory_feedback update_memory_confidence),
      last_message: data.current_message,
      last_message_metadata: data.current_message_metadata || %{},
      last_message_id: data.current_message_id,
      trigger: data.current_trigger,
      event: data.current_event
    }

    Map.merge(context, data.behavior_cycle_context || %{})
  end

  defp recent_operator_events(user_id) when is_binary(user_id) do
    user_id
    |> OperatorEvents.list_recent_for_user(20)
    |> Enum.map(&serialize_operator_event_for_prompt/1)
  end

  defp recent_operator_events(_user_id), do: []

  defp serialize_operator_event_for_prompt(%OperatorEvent{} = event) do
    %{
      id: event.id,
      source: event.source,
      event_type: event.event_type,
      scope: event.scope,
      source_item_id: event.source_item_id,
      occurred_at: to_jsonable(event.occurred_at),
      payload: compact_prompt_map(event.payload || %{}),
      metadata: compact_prompt_map(event.metadata || %{})
    }
    |> maybe_put(:project_id, event.project_id)
  end

  defp compact_prompt_map(value) when is_map(value) do
    value
    |> Enum.take(12)
    |> Map.new(fn {key, val} -> {to_string(key), compact_prompt_value(val)} end)
  end

  defp compact_prompt_map(_value), do: %{}

  defp compact_prompt_value(value) when is_binary(value), do: String.slice(value, 0, 500)

  defp compact_prompt_value(value) when is_list(value) do
    value
    |> Enum.take(6)
    |> Enum.map(&compact_prompt_value/1)
  end

  defp compact_prompt_value(value) when is_map(value), do: compact_prompt_map(value)
  defp compact_prompt_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp compact_prompt_value(%Date{} = value), do: Date.to_iso8601(value)
  defp compact_prompt_value(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_inject_memory_into_effect(data, effect_type, params)
       when effect_type in [:llm_call, "llm_call"] and is_map(params) do
    query = effect_query(data)

    params
    |> RequestBudget.put_optional_context(fn candidate ->
      Memory.inject_llm_params(candidate, data.user_id, query: query, limit: 8)
    end)
    |> RequestBudget.put_optional_context(fn candidate ->
      OpenLoops.inject_llm_params(candidate, data.user_id,
        query: query,
        limit: 8,
        include_memory?: false
      )
    end)
  end

  defp maybe_inject_memory_into_effect(_data, _effect_type, params), do: params

  # SPEC 07 R1: `current_message` is nil for effect/skill-triggered runs
  # (wakeup jobs, pubsub events) that never went through
  # `put_message_trigger/4`. Fall back to the trigger's own intent (job type
  # + reason, or the pubsub topic) so those runs still thread a real query
  # into memory recall instead of silently degrading to "no query".
  defp effect_query(%{current_message: message}) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp effect_query(%{current_trigger: %{type: :wakeup, job_type: job_type}} = data)
       when is_binary(job_type) do
    reason =
      get_in(data.current_trigger, [:payload, "reason"]) ||
        get_in(data.current_trigger, [:payload, :reason])

    [job_type, reason]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp effect_query(%{current_trigger: %{type: :pubsub_event, topic: topic}})
       when is_binary(topic),
       do: topic

  defp effect_query(_data), do: nil

  defp put_wakeup_trigger(data, job_type, job_id, payload) do
    %{
      data
      | current_trigger: %{
          type: :wakeup,
          job_type: job_type,
          job_id: job_id,
          payload: payload
        },
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil
    }
  end

  defp put_message_trigger(data, message, metadata, message_id) do
    %{
      data
      | current_trigger: %{
          type: :message,
          message_id: message_id,
          metadata: metadata
        },
        current_event: nil,
        current_message: message,
        current_message_metadata: metadata,
        current_message_id: message_id
    }
  end

  defp put_pubsub_trigger(data, topic, payload) do
    %{
      data
      | current_trigger: %{
          type: :pubsub_event,
          topic: topic
        },
        current_event: %{topic: topic, payload: payload},
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil
    }
  end

  defp clear_transient_context(
         %{current_run_id: run_id, current_directive_id: directive_id} = data
       )
       when is_binary(run_id) and is_binary(directive_id) do
    # A failed atomic settlement keeps the immutable claim proof in process
    # state. Dropping it would allow the Agent to look idle while PostgreSQL
    # still owns one processing attempt.
    %{
      data
      | current_trigger: nil,
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil,
        behavior_cycle_context: nil
    }
  end

  defp clear_transient_context(data) do
    %{
      data
      | current_trigger: nil,
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil,
        behavior_cycle_context: nil,
        current_directive_id: nil,
        current_directive_claim_token: nil,
        current_directive_kind: nil
    }
  end

  defp maybe_reset_open_insights_for_refresh(data, message, metadata) do
    if InsightRefresh.refresh_request?(message, metadata) do
      reset_count =
        InsightRefresh.reset_open_insights_for_agent(
          data.user_id,
          data.agent_id,
          %{
            behavior: data.behavior,
            behavior_module: data.behavior_module,
            config: data.config
          }
        )

      if reset_count > 0 do
        Logger.info("Reset open insights before queued refresh",
          agent_id: data.agent_id,
          reset_count: reset_count
        )
      end
    end

    data
  end

  defp trigger_type(%{type: type}), do: to_string(type)
  defp trigger_type(%{"type" => type}), do: to_string(type)
  defp trigger_type(_trigger), do: nil

  defp step_type(:llm_call), do: "llm_call"
  defp step_type(:tool_call), do: "tool_call"
  defp step_type(effect_type), do: to_string(effect_type)

  defp generation_mode_for_effect(:llm_call), do: "llm"
  defp generation_mode_for_effect(:tool_call), do: "tool"
  defp generation_mode_for_effect(effect_type), do: to_string(effect_type)

  defp model_from_params(params) when is_map(params),
    do: params["model"] || params[:model]

  defp model_from_params(_params), do: nil

  defp intelligence_from_params(params) when is_map(params),
    do:
      params["reasoning_effort"] || params[:reasoning_effort] || params["intelligence"] ||
        params[:intelligence]

  defp intelligence_from_params(_params), do: nil

  defp model_from_response(response) when is_map(response),
    do: response[:model] || response["model"]

  defp model_from_response(_response), do: nil

  defp finish_reason_from_response(response) when is_map(response),
    do: response[:finish_reason] || response["finish_reason"]

  defp finish_reason_from_response(_response), do: nil

  defp maybe_put_error(attrs, payload) when is_map(payload) do
    case payload["error"] || payload[:error] do
      nil -> attrs
      error -> Map.put(attrs, :error, Maraithon.Redaction.error_summary(error))
    end
  end

  defp maybe_put_error(attrs, _payload), do: attrs

  defp to_jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_jsonable(%Date{} = value), do: Date.to_iso8601(value)
  defp to_jsonable(%Time{} = value), do: Time.to_iso8601(value)
  defp to_jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp to_jsonable(value) when is_map(value) do
    value
    |> maybe_struct_to_map()
    |> Map.new(fn {key, val} -> {to_string(key), to_jsonable(val)} end)
  end

  defp to_jsonable(value) when is_list(value), do: Enum.map(value, &to_jsonable/1)
  defp to_jsonable(value) when is_atom(value), do: to_string(value)
  defp to_jsonable(value), do: value

  defp normalize_message_metadata(nil), do: %{}
  defp normalize_message_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_message_metadata(_metadata), do: %{}

  defp init_budget(nil), do: %{llm_calls: 500, tool_calls: 1000}

  defp init_budget(budget) do
    %{
      llm_calls: budget["llm_calls"] || 500,
      tool_calls: budget["tool_calls"] || 1000
    }
  end

  # The budget is a runaway-work guardrail, but it is snapshotted and
  # restored across restarts/deploys and was never refilled — so it was
  # a LIFETIME allowance: at the 10-minute always-on cadence an agent
  # burned through it in days and then every wakeup/message/pubsub gate
  # became a silent "No budget, staying idle" no-op forever. Refill to
  # the configured allowance once per UTC day, so it acts as the daily
  # spend cap it was meant to be. `refilled_at` rides inside the budget
  # map (snapshot-compatible: old snapshots lack the key and refill on
  # their first post-deploy trigger; has_budget?/decrement_budget only
  # read llm_calls/tool_calls).
  @budget_refill_interval_hours 24

  defp maybe_refill_budget(data) do
    refilled_at = parse_refilled_at(Map.get(data.budget || %{}, :refilled_at))
    now = DateTime.utc_now()

    stale? =
      is_nil(refilled_at) or
        DateTime.diff(now, refilled_at, :hour) >= @budget_refill_interval_hours

    if stale? do
      fresh = init_budget(data.config["budget"])

      Logger.info("Agent budget refilled",
        agent_id: data.agent_id,
        previous_llm_calls: Map.get(data.budget || %{}, :llm_calls),
        previous_tool_calls: Map.get(data.budget || %{}, :tool_calls)
      )

      %{data | budget: Map.put(fresh, :refilled_at, DateTime.to_iso8601(now))}
    else
      data
    end
  end

  defp parse_refilled_at(%DateTime{} = at), do: at

  defp parse_refilled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_refilled_at(_other), do: nil

  defp has_budget?(data) do
    data.budget.llm_calls > 0 || data.budget.tool_calls > 0
  end

  defp decrement_budget(data, :llm_call) do
    %{data | budget: %{data.budget | llm_calls: max(0, data.budget.llm_calls - 1)}}
  end

  defp decrement_budget(data, :tool_call) do
    %{data | budget: %{data.budget | tool_calls: max(0, data.budget.tool_calls - 1)}}
  end

  defp decrement_budget(data, _), do: data

  defp add_bounded(set, item, max_size) do
    set = MapSet.put(set, item)

    if MapSet.size(set) > max_size do
      # Evict an arbitrary element, but never the one just added — evicting
      # the new id would immediately re-open the dedupe window for it.
      victim = set |> MapSet.delete(item) |> Enum.at(0)
      MapSet.delete(set, victim)
    else
      set
    end
  end

  defp maybe_struct_to_map(%_{} = value), do: Map.from_struct(value)
  defp maybe_struct_to_map(value), do: value

  defp get_config(key, default) do
    Maraithon.Runtime.Config.get(key, default)
  end

  defp enrich_config_with_package_manifest(agent) do
    config = agent.config || %{}

    case package_version_id(agent, config) do
      nil ->
        config

      version_id ->
        case Agents.get_agent_package_version(version_id) do
          nil ->
            Map.put(config, "_harness_manifest_error", {:package_version_not_found, version_id})

          version ->
            case Manifest.build(version) do
              {:ok, manifest} ->
                config
                |> Map.put("_harness_manifest", manifest)
                |> Map.put("agent_package_version_id", version.id)

              {:error, reason} ->
                Map.put(config, "_harness_manifest_error", reason)
            end
        end
    end
  end

  defp package_version_id(%{agent_package_version_id: id}, _config) when is_binary(id), do: id
  defp package_version_id(_agent, %{"agent_package_version_id" => id}) when is_binary(id), do: id
  defp package_version_id(_agent, _config), do: nil

  defp redact_runtime_config(config) when is_map(config) do
    Map.drop(config, ["_harness_manifest"])
  end

  defp acknowledge_wakeup(job_id) do
    case Scheduler.ack_delivered(job_id) do
      {:ok, _status} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, :invalid_state} ->
        :ok

      {:error, reason} ->
        Logger.warning("Scheduled wakeup acknowledgement deferred",
          job_id: job_id,
          error: Maraithon.Redaction.error_summary(reason)
        )

        :ok
    end
  end

  defp reject_raw_exact_workload(data, workload_type, opts \\ []) do
    Logger.warning("Exact Agent rejected non-durable workload delivery",
      agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
      workload_type: workload_type,
      failure_code: "raw_workload_rejected"
    )

    if Keyword.get(opts, :claim?, false) do
      {:keep_state, data, [{:next_event, :internal, :claim_directive}]}
    else
      {:keep_state, data}
    end
  end

  # Buffer a message that arrived while the agent was busy (recovering, working,
  # or waiting on an effect) and replay it once the agent is idle again. Without
  # this, connector pubsub events and direct messages were silently dropped in
  # the busy states' catch-all clauses.
  defp defer_message(data, msg) do
    maybe_ack_wakeup(msg)
    buffer = [msg | data.deferred_messages]

    # Bound the buffer: a busy pubsub feed during a long cycle must not grow
    # process state without limit. Oldest messages are dropped first; scans
    # are cycle-based, so the next wakeup re-covers anything dropped here.
    buffer =
      if length(buffer) > @max_deferred_messages do
        Logger.warning("Deferred agent message buffer full; dropping oldest",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          failure_code: "deferred_buffer_full"
        )

        List.delete_at(buffer, -1)
      else
        buffer
      end

    %{data | deferred_messages: buffer}
  end

  # A wakeup is "delivered" the moment it lands in the agent's mailbox, in any
  # state. Acking on receipt — not only in :idle — stops the Scheduler from
  # reclaiming and re-dispatching the same job every poll while the agent is
  # busy, which was the scheduler-churn leak.
  defp maybe_ack_wakeup({:wakeup, _type, job_id, _payload}) when is_binary(job_id) do
    acknowledge_wakeup(job_id)
  end

  defp maybe_ack_wakeup({:agent_dispatch, inner}), do: maybe_ack_wakeup(inner)
  defp maybe_ack_wakeup(_msg), do: :ok

  defp drain_deferred_messages(%{deferred_messages: []} = data), do: data

  defp drain_deferred_messages(%{deferred_messages: messages} = data) do
    # Replay in arrival order (the buffer is prepended, so reverse first).
    Enum.each(Enum.reverse(messages), &send(self(), &1))
    %{data | deferred_messages: []}
  end

  defp exact_recovery_owner?(%{exact_owner?: true} = data) do
    AgentLeases.owner?(data.agent_id, data.owner_token)
  end

  defp exact_recovery_owner?(_legacy_data), do: true

  defp recovery_agent(agent_id, %{exact_owner?: true}) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %{status: status, install_status: "enabled"} = agent
      when status in ["running", "degraded"] ->
        {:ok, agent}

      _missing_or_inactive ->
        :inactive
    end
  end

  defp recovery_agent(agent_id, _legacy_data) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %{status: status, install_status: "enabled"} = agent
      when status in ["recovering", "running", "degraded"] ->
        {:ok, agent}

      _missing_or_inactive ->
        :inactive
    end
  end

  defp stop_inactive_agent(%{exact_owner?: true} = data) do
    stop_agent("desired_state_inactive", data)
  end

  defp stop_inactive_agent(data), do: {:stop, :normal, data}

  defp lease_renewal_action(data) do
    {{:timeout, :lease_renewal}, data.lease_renew_interval_ms, :renew_lease}
  end

  defp renew_exact_lease(%{exact_owner?: true, exact_activated?: true} = data) do
    renewal = renew_exact_authority(data)

    case renewal do
      {:ok, %{draining_at: nil}} ->
        {:keep_state, data, [lease_renewal_action(data)]}

      {:ok, _draining_lease} ->
        stop_agent("runtime_authority_revoked", data)

      {:error, reason} when reason in [:node_authority_lost, :partition_authority_lost] ->
        if durable_authority_draining?(data) do
          {:stop, :normal, data}
        else
          stop_after_exact_lease_renewal_failure(reason, data)
        end

      {:error, reason} ->
        stop_after_exact_lease_renewal_failure(reason, data)
    end
  end

  defp renew_exact_lease(data), do: {:keep_state, data}

  defp renew_effect_admission_authority(%{exact_owner?: true, exact_activated?: true} = data) do
    case renew_exact_authority(data) do
      {:ok, %{draining_at: nil}} -> :ok
      {:ok, _draining_lease} -> {:error, :runtime_authority_revoked}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_effect_admission_authority(_data), do: :ok

  defp durable_authority_draining?(data) do
    case AgentLeases.get(data.agent_id) do
      %{owner_token: owner_token, draining_at: draining_at}
      when owner_token == data.owner_token and not is_nil(draining_at) ->
        true

      %{
        owner_token: owner_token,
        coordination_activation_epoch: activation_epoch,
        coordination_node_incarnation_id: node_id
      }
      when owner_token == data.owner_token and is_binary(activation_epoch) and is_binary(node_id) ->
        match?(
          %NodeIncarnation{activation_epoch: ^activation_epoch, state: "draining"},
          Repo.get(NodeIncarnation, node_id)
        )

      _missing_or_active_lease ->
        false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp stop_after_exact_lease_renewal_failure(reason, data) do
    Logger.warning("Exact Agent lease/Directive renewal failed",
      agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
      failure_code: Maraithon.Redaction.error_class(reason)
    )

    # Do not release or perform termination cleanup. The Watcher must first
    # durably guard this exact generation, even for a normal-looking exit.
    {:stop, {:exact_lease_renewal_failed, reason}, data}
  end

  defp renew_exact_authority(data) do
    Repo.transaction(fn ->
      ProtocolCutover.require_current_mutation!()

      lease_result =
        case data.guard_generation do
          nil ->
            AgentLeases.renew(data.agent_id, data.owner_token, ttl_ms: data.lease_ttl_ms)

          guard_generation ->
            AgentLeases.renew_recovery(
              data.agent_id,
              data.owner_token,
              guard_generation,
              ttl_ms: data.lease_ttl_ms
            )
        end

      lease =
        case lease_result do
          {:ok, lease} -> lease
          {:error, reason} -> Repo.rollback(reason)
        end

      case {data.current_directive_id, data.current_directive_claim_token} do
        {directive_id, claim_token}
        when is_binary(directive_id) and is_binary(claim_token) ->
          case AgentDirectives.renew_claim_in_transaction(
                 data.agent_id,
                 directive_id,
                 data.owner_token,
                 claim_token,
                 ttl_ms: data.lease_ttl_ms
               ) do
            {:ok, _directive} -> lease
            {:error, reason} -> Repo.rollback(reason)
          end

        _no_active_directive ->
          lease
      end
    end)
  end

  defp stop_agent(reason, %{exact_owner?: true} = data) do
    if begin_exact_draining(data) do
      {data, cleanup_complete?} = clean_stopped_work(data)
      data = safely_emit_stop_event(data, reason)

      # Durable schedules/subscriptions are cancelled only by the caller-owned
      # lifecycle finalization transaction after the lease and work rows quiesce.
      # Even a clean callback is not physical-termination proof. The stable
      # watcher owns the exact monitor and removes this lease only after DOWN.
      _cleanup_complete? = cleanup_complete?
      {:stop, :normal, data}
    else
      # Without an exact draining fence this process may already be stale. It
      # must not cancel work, append events, or release another incarnation.
      {:stop, :normal, data}
    end
  end

  defp stop_agent(reason, data) do
    {data, _cleanup_complete?} = clean_stopped_work(data)
    data = safely_emit_stop_event(data, reason)
    safely_cancel_schedules(data.agent_id)
    {:stop, :normal, data}
  end

  defp stop_agent(reason, %{exact_owner?: true, owner_token: owner_token} = data, owner_token),
    do: stop_agent(reason, data)

  defp stop_agent(_reason, %{exact_owner?: true} = data, _stale_owner_token),
    do: {:keep_state, data}

  defp stop_agent(reason, data, _legacy_owner_token), do: stop_agent(reason, data)

  defp clean_stopped_work(data) do
    case cancel_active_effects(data.agent_id, @stopped_effect_reason, data.owner_token) do
      {:ok, _cancelled_count} ->
        closed = cancel_current_run(data, @stopped_run_reason)
        {closed, is_nil(closed.current_run_id)}

      {:error, cancellation_error} ->
        Logger.warning("Agent stop left run closure for durable recovery",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          failure_code: Maraithon.Redaction.error_class(cancellation_error)
        )

        {data, false}
    end
  end

  defp begin_exact_draining(data) do
    case AgentLeases.begin_draining(data.agent_id, data.owner_token) do
      {:ok, _lease} ->
        true

      {:error, reason} ->
        Logger.warning("Exact Agent could not begin draining",
          agent_reference: Maraithon.Redaction.fingerprint(data.agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        false
    end
  end

  defp acknowledge_terminal_effect_results_for_run(run_id, agent_id) do
    Effects.acknowledge_terminal_results_for_run(run_id, agent_id)
  rescue
    _error -> {:error, :effect_acknowledgement_failed}
  catch
    :exit, _reason -> {:error, :effect_acknowledgement_failed}
  end

  defp safely_emit_stop_event(%{exact_owner?: true} = data, reason) do
    emit_exact_event(data, "agent_stopped", %{reason: event_label(reason)}, :owner)
  rescue
    _error -> data
  catch
    _kind, _reason -> data
  end

  defp safely_emit_stop_event(data, reason) do
    emit_event(data, "agent_stopped", %{reason: event_label(reason)})
  rescue
    _error -> data
  catch
    _kind, _reason -> data
  end

  defp safely_cancel_schedules(agent_id) do
    Scheduler.cancel_all(agent_id)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp register_global_name(agent_id) do
    name = {:maraithon_agent, agent_id}
    register_global_name(name, @global_register_retries)
  end

  defp register_global_name(name, retries_left) do
    case :global.register_name(name, self()) do
      :yes ->
        :ok

      :no ->
        owner = :global.whereis_name(name)

        if retries_left > 0 and retry_global_register?(owner) do
          Process.sleep(@global_register_retry_ms)
          register_global_name(name, retries_left - 1)
        else
          {:error, {:already_started, owner}}
        end
    end
  end

  defp retry_global_register?(:undefined), do: true

  defp retry_global_register?(pid) when is_pid(pid) do
    node(pid) == node() and not Process.alive?(pid)
  end

  defp retry_global_register?(_owner), do: false
end
