defmodule Maraithon.Runtime.AgentLifecycleOperations do
  @moduledoc """
  Durable composite Agent lifecycle transitions.

  Every transition first takes the global Agent lock order
  `Agent -> same-user Binding -> Guard -> Lease -> LifecycleOperation`, stores
  an immutable operation token/canonical plan, revokes readiness, and commits a
  stopped desired-state fence. Process routing and waits happen only after that
  transaction. Finalization is a second short caller-owned transaction which
  repeats the prefix, then locks `Directive -> Run -> RunStep -> Effect` before
  changing delivery/config/install state. An unresolved row leaves the marker
  and every requested mutation untouched.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.AgentSubscriptions
  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.BoundedJSON
  alias Maraithon.Effects
  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminationIncident
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Coordination.{Protocol, Scope}
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Runtime.Snapshot

  @max_payload_bytes 128_000
  @default_drain_ttl_ms 60_000
  @max_batch 500
  @active_effect_statuses ~w(pending claimed executing cancelling)
  @terminal_effect_statuses ~w(completed failed cancelled)

  # Lifecycle authority must remain operable even when an encrypted payload is
  # corrupt. These projections intentionally omit every encrypted and legacy
  # content column; only the exceptional requested-step projection reloads the
  # exact terminal Effect payload and fails closed when it cannot decode.
  @directive_authority_fields [
    :id,
    :agent_id,
    :user_id,
    :kind,
    :dedupe_key,
    :request_fingerprint,
    :status,
    :available_at,
    :attempts,
    :max_attempts,
    :claim_token,
    :claimed_by_generation,
    :claimed_at,
    :claim_expires_at,
    :processing_started_at,
    :terminal_at,
    :terminal_acknowledged_at,
    :terminal_claim_token,
    :terminal_by_generation,
    :last_error_code,
    :active_run_id,
    :effect_admitted_at,
    :effect_count,
    :ambiguity_code,
    :payload_encryption_version,
    :payload_purged_at,
    :inserted_at,
    :updated_at
  ]
  @run_authority_fields [
    :id,
    :agent_id,
    :user_id,
    :behavior,
    :status,
    :started_at,
    :completed_at,
    :error,
    :inserted_at,
    :updated_at
  ]
  @step_authority_fields [
    :id,
    :agent_run_id,
    :agent_id,
    :sequence,
    :step_type,
    :status,
    :error,
    :started_at,
    :completed_at,
    :payload_purged_at,
    :inserted_at,
    :updated_at
  ]
  @effect_authority_fields [
    :id,
    :agent_id,
    :owner_user_id,
    :status,
    :runtime_owner_generation,
    :claim_token,
    :claim_owner_node,
    :claim_heartbeat_at,
    :claim_expires_at,
    :claim_supervisor_id,
    :claim_task_id,
    :cancellation_state,
    :cancellation_requested_at,
    :cancellation_target_claim_token,
    :cancellation_settled_at,
    :agent_run_id,
    :agent_run_step_id,
    :result_envelope,
    :result_acknowledged_at,
    :payload_purged_at,
    :error,
    :inserted_at,
    :updated_at
  ]

  @reconcilable_work_reasons [
    :active_run_pointer,
    :processing_directive,
    :running_agent_run,
    :requested_agent_run_step,
    :active_effect
  ]

  @doc """
  Establishes or idempotently adopts one exact lifecycle operation.

  `planner` runs only for a fresh marker while the Agent row is locked. It must
  return the complete JSON-safe mutation plan (or `{:error, reason}`). A retry
  with the same kind and canonical request adopts the stored plan; a different
  request cannot replace an in-flight operation.
  """
  def begin(agent_id, kind, request, planner, opts \\ [])

  def begin(agent_id, kind, request, planner, opts)
      when is_binary(agent_id) and is_atom(kind) and is_map(request) and
             is_function(planner, 1) and is_list(opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, kind} <- kind(kind),
         {:ok, request} <- canonical_payload(request),
         {:ok, drain_ttl_ms, requires_external_drain, privacy_request_id} <-
           begin_options(opts),
         true <- is_nil(privacy_request_id) or kind == "delete" do
      request_digest = digest(request)

      Repo.transaction(fn ->
        set_privacy_erasure_context!(privacy_request_id)
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        termination_incident = lock_open_termination_incident(agent_id)
        now = DatabaseClock.now!()

        if termination_incident, do: Repo.rollback(:agent_termination_unproven)

        case operation do
          %AgentLifecycleOperation{} = existing ->
            adopt!(
              existing,
              kind,
              request_digest,
              requires_external_drain,
              now,
              agent,
              lease
            )

          nil ->
            mutation = plan!(planner, agent)
            resume_after = resume_after?(kind, agent)
            final_status = final_status(kind, agent, resume_after)

            fenced_lease = fence_lease!(lease, now, drain_ttl_ms)
            operation_token = Ecto.UUID.generate()
            expected_owner_token = owner_token(fenced_lease) || expected_guard_owner(guard)

            stopped_agent =
              agent
              |> Ecto.Changeset.change(%{
                status: "stopped",
                stopped_at: stopped_at(agent, now),
                updated_at: now
              })
              |> Repo.update!()

            payload =
              %{
                "version" => 1,
                "kind" => kind,
                "request" => request,
                "mutation" => mutation,
                "resume_after" => resume_after,
                "final_status" => final_status,
                "guard" => guard_snapshot(guard),
                "operation_token" => operation_token,
                "expected_owner_token" => expected_owner_token,
                "requires_external_drain" => requires_external_drain
              }
              |> canonical_payload!()

            operation =
              %AgentLifecycleOperation{inserted_at: now, updated_at: now}
              |> AgentLifecycleOperation.changeset(%{
                agent_id: agent_id,
                operation_token: operation_token,
                kind: kind,
                state: "draining",
                request_digest: request_digest,
                payload_digest: digest(payload),
                payload: payload,
                expected_owner_token: expected_owner_token,
                requires_external_drain: requires_external_drain,
                initiated_at: now,
                last_attempted_at: now
              })
              |> Repo.insert!()

            lifecycle_fence(operation, stopped_agent, fenced_lease, :created)
        end
      end)
    else
      false -> {:error, :invalid_lifecycle_operation}
      {:error, _reason} = error -> error
    end
  end

  def begin(_agent_id, _kind, _request, _planner, _opts),
    do: {:error, :invalid_lifecycle_operation}

  @doc """
  Records explicit external proof for a marker that observed an unfenced local
  legacy process. This never infers fleet absence from Registry or node lists.
  """
  def confirm_external_drain(agent_id, operation_token, evidence)
      when is_binary(agent_id) and is_binary(operation_token) and is_map(evidence) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, operation_token} <- cast_uuid(operation_token),
         {:ok, evidence} <- external_drain_evidence(evidence) do
      evidence_digest = digest(evidence)

      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        _guard = lock_guard(agent_id)
        _lease = lock_lease(agent_id)
        operation = lock_operation(agent_id) || Repo.rollback(:lifecycle_operation_not_found)
        validate_operation!(operation, operation_token)
        validate_payload!(operation)

        cond do
          not operation.requires_external_drain ->
            Repo.rollback(:external_drain_confirmation_not_required)

          is_nil(operation.external_drain_confirmed_at) ->
            now = DatabaseClock.now!()

            operation
            |> Ecto.Changeset.change(%{
              external_drain_confirmed_at: now,
              external_drain_evidence_digest: evidence_digest,
              last_attempted_at: now,
              updated_at: now
            })
            |> Repo.update!()

          operation.external_drain_evidence_digest == evidence_digest ->
            operation

          true ->
            Repo.rollback(:external_drain_confirmation_conflict)
        end
      end)
    end
  end

  def confirm_external_drain(_agent_id, _operation_token, _evidence),
    do: {:error, :invalid_external_drain_evidence}

  @doc """
  Finishes one operation only after exact ownership and durable work quiesce.

  A pending result is a successful, read-only finalization attempt: the marker
  remains durable and no directive/delivery/config/install mutation is applied.
  """
  def finalize(agent_id, operation_token)

  def finalize(agent_id, operation_token) when is_binary(agent_id),
    do: do_finalize(agent_id, operation_token, false)

  def finalize(_agent_id, _operation_token), do: {:error, :invalid_lifecycle_operation}

  @doc false
  def finalize_for_reconciliation(agent_id, operation_token) when is_binary(agent_id),
    do: do_finalize(agent_id, operation_token, true)

  def finalize_for_reconciliation(_agent_id, _operation_token),
    do: {:error, :invalid_lifecycle_operation}

  @doc false
  def confirm_finalized_postcondition(
        agent_id,
        operation_token,
        %AgentLifecycleOperation{} = original_operation
      ) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, operation_token} <- cast_uuid(operation_token),
         true <- original_operation.agent_id == agent_id,
         true <- original_operation.operation_token == operation_token,
         true <- original_operation.state == "draining",
         true <- valid_payload?(original_operation),
         true <- recoverable_operation?(original_operation) do
      case Repo.transaction(fn ->
             confirm_finalized_postcondition_locked!(original_operation)
           end) do
        {:ok, result} -> {:ok, result}
        {:error, _reason} -> {:error, :lifecycle_completion_unproven}
      end
    else
      _invalid -> {:error, :lifecycle_completion_unproven}
    end
  rescue
    _error -> {:error, :lifecycle_completion_unproven}
  catch
    :exit, _reason -> {:error, :lifecycle_completion_unproven}
  end

  def confirm_finalized_postcondition(_agent_id, _operation_token, _operation),
    do: {:error, :lifecycle_completion_unproven}

  defp do_finalize(agent_id, operation_token, scoped?) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, operation_token} <- optional_uuid(operation_token) do
      transaction_result =
        Repo.transaction(
          fn ->
            protocol_pair = Protocol.locked_pair!()
            user_id = prelock_agent_user!(agent_id)
            finalize_locked(agent_id, operation_token, scoped?, user_id, protocol_pair)
          end,
          timeout: :infinity
        )

      case transaction_result do
        {:ok, {:pending, reason, operation}} ->
          if reason in @reconcilable_work_reasons do
            # This is deliberately after commit: exact cancellation may route
            # to another node/Task.Supervisor and can never run under the
            # lifecycle row locks.
            _ = reconcile_work_after_commit(agent_id, operation, reason)
          end

          {:ok,
           %{
             status: :reconciliation_pending,
             reason: reason,
             operation: operation,
             operation_token: operation.operation_token
           }}

        {:ok, {:finalized, result}} ->
          {:ok, Map.put(result, :status, :finalized)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp confirm_finalized_postcondition_locked!(
         %AgentLifecycleOperation{kind: "delete"} = operation
       ) do
    agent = Repo.get(Agent, operation.agent_id)
    pending_operation = Repo.get(AgentLifecycleOperation, operation.agent_id)

    if is_nil(agent) and is_nil(pending_operation) do
      %{
        action: :deleted,
        agent: nil,
        agent_id: operation.agent_id,
        operation_token: operation.operation_token,
        resume_after: false,
        status: :finalized
      }
    else
      Repo.rollback(:lifecycle_completion_unproven)
    end
  end

  defp confirm_finalized_postcondition_locked!(%AgentLifecycleOperation{} = operation) do
    agent =
      Repo.one(
        from(agent in Agent,
          where: agent.id == ^operation.agent_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:lifecycle_completion_unproven)

    binding = lock_binding(agent)

    if lock_operation(operation.agent_id),
      do: Repo.rollback(:lifecycle_completion_unproven)

    if finalization_happened_after_begin?(agent, operation) and
         finalized_agent_postcondition?(agent, binding, operation) do
      %{
        action: :updated,
        agent: agent,
        agent_id: agent.id,
        operation_token: operation.operation_token,
        resume_after: operation.payload["resume_after"] == true,
        status: :finalized
      }
    else
      Repo.rollback(:lifecycle_completion_unproven)
    end
  end

  defp recoverable_operation?(operation) do
    payload = operation.payload
    mutation = payload["mutation"]

    is_map(mutation) and mutation["action"] == operation.kind and
      is_boolean(payload["resume_after"]) and
      payload["final_status"] in ["running", "stopped", "terminated"]
  end

  defp finalized_agent_postcondition?(agent, binding, operation) do
    payload = operation.payload
    mutation = payload["mutation"]

    case mutation["action"] do
      "stop" ->
        payload["final_status"] == "stopped" and agent.status == "stopped" and
          match?(%DateTime{}, agent.stopped_at)

      "pause" ->
        payload["final_status"] == "stopped" and agent.status == "stopped" and
          agent.install_status == "paused" and binding_status?(binding, "paused")

      "remove" ->
        payload["final_status"] == "stopped" and agent.status == "stopped" and
          agent.install_status == "removed" and match?(%DateTime{}, agent.removed_at) and
          binding_status?(binding, "revoked")

      action when action in ["update", "upgrade"] ->
        mutation_attrs_applied?(agent, mutation["attrs"]) and
          final_status_applied?(agent, payload["final_status"])

      _invalid ->
        false
    end
  end

  defp binding_status?(nil, _expected), do: true
  defp binding_status?(%Binding{status: status}, expected), do: status == expected

  defp finalization_happened_after_begin?(
         %Agent{updated_at: %DateTime{} = updated_at},
         %AgentLifecycleOperation{initiated_at: %DateTime{} = initiated_at}
       ),
       do: DateTime.compare(updated_at, initiated_at) == :gt

  defp finalization_happened_after_begin?(_agent, _operation), do: false

  defp mutation_attrs_applied?(%Agent{} = agent, attrs) when is_map(attrs) do
    allowed_fields = ~w(behavior config project_id agent_package_version_id)

    if Enum.all?(Map.keys(attrs), &(&1 in allowed_fields)) do
      changeset = Agent.changeset(agent, attrs)
      changeset.valid? and changeset.changes == %{}
    else
      false
    end
  end

  defp mutation_attrs_applied?(_agent, _attrs), do: false

  defp final_status_applied?(agent, "running") do
    agent.status == "running" and match?(%DateTime{}, agent.started_at) and
      is_nil(agent.stopped_at)
  end

  defp final_status_applied?(agent, "stopped") do
    agent.status == "stopped" and match?(%DateTime{}, agent.stopped_at)
  end

  defp final_status_applied?(agent, "terminated") do
    agent.status == "terminated" and match?(%DateTime{}, agent.stopped_at)
  end

  defp final_status_applied?(_agent, _status), do: false

  @doc "Returns a bounded oldest-first set of stranded operation IDs."
  def list_pending_ids(limit \\ 50)

  def list_pending_ids(limit) when is_integer(limit) and limit in 1..@max_batch do
    from(operation in AgentLifecycleOperation,
      join: agent in Agent,
      as: :agent,
      on: agent.id == operation.agent_id,
      order_by: [
        asc: operation.last_attempted_at,
        asc: operation.initiated_at,
        asc: operation.agent_id
      ],
      limit: ^limit,
      select: operation.agent_id
    )
    |> Scope.all_ready_agent()
  end

  def list_pending_ids(_limit), do: []

  def get(agent_id) when is_binary(agent_id) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, id} -> Repo.get(AgentLifecycleOperation, id)
      :error -> nil
    end
  end

  def get(_agent_id), do: nil

  @doc false
  def canonical_payload(payload) when is_map(payload) and not is_struct(payload) do
    if BoundedJSON.valid?(payload, @max_payload_bytes,
         max_binary_bytes: @max_payload_bytes,
         max_depth: 12,
         max_nodes: 20_000,
         max_map_entries: 2_000,
         max_list_items: 2_000
       ) do
      with {:ok, encoded} <- Jason.encode(payload),
           true <- byte_size(encoded) <= @max_payload_bytes,
           {:ok, decoded} when is_map(decoded) <- Jason.decode(encoded) do
        {:ok, decoded}
      else
        _invalid -> {:error, :invalid_lifecycle_payload}
      end
    else
      {:error, :invalid_lifecycle_payload}
    end
  rescue
    _error -> {:error, :invalid_lifecycle_payload}
  end

  def canonical_payload(_payload), do: {:error, :invalid_lifecycle_payload}

  @doc false
  def digest(payload) when is_map(payload) do
    payload
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp finalize_locked(agent_id, operation_token, scoped?, prelocked_user_id, protocol_pair) do
    agent = lock_agent!(agent_id)

    if agent.user_id != prelocked_user_id,
      do: Repo.rollback(:agent_user_authority_changed)

    _coordination = if scoped?, do: Scope.authorize_reconciliation!(agent), else: :legacy
    binding = lock_binding(agent)
    guard = lock_guard(agent_id)
    lease = lock_lease(agent_id)
    operation = lock_operation(agent_id) || Repo.rollback(:lifecycle_operation_not_found)
    termination_incident = lock_open_termination_incident(agent_id)
    now = DatabaseClock.now!()

    validate_operation!(operation, operation_token)
    validate_payload!(operation)

    cond do
      agent.status != "stopped" ->
        Repo.rollback(:lifecycle_operation_fence_lost)

      operation.requires_external_drain and is_nil(operation.external_drain_confirmed_at) ->
        {:pending, :external_fleet_drain_required, touch!(operation, now)}

      not is_nil(termination_incident) ->
        {:pending, :agent_termination_unproven, touch!(operation, now)}

      live_lease?(lease, now) ->
        {:pending, :runtime_lease_owned, touch!(operation, now)}

      not is_nil(lease) ->
        {:pending, :expired_lease_requires_reconciliation, touch!(operation, now)}

      not guard_finalizable?(guard, operation) ->
        {:pending, :restart_guard_requires_reconciliation, touch!(operation, now)}

      true ->
        # This order is part of the runtime locking contract. Do not reorder it.
        directives = lock_directives(agent_id)
        runs = lock_runs(agent_id)
        steps = lock_steps(agent_id)
        effects = lock_effects(agent_id)

        active_effect? = Enum.any?(effects, &(&1.status in @active_effect_statuses))

        case unresolved_work(agent, operation, directives, runs, steps, effects, protocol_pair) do
          nil ->
            finalize_quiesced!(
              agent,
              binding,
              guard,
              operation,
              directives,
              runs,
              steps,
              effects,
              now
            )

          reason when reason in @reconcilable_work_reasons and not active_effect? ->
            settle_orphaned_work!(agent, operation, directives, runs, steps, effects, now)

            settled_agent = lock_agent!(agent_id)
            settled_directives = lock_directives(agent_id)
            settled_runs = lock_runs(agent_id)
            settled_steps = lock_steps(agent_id)
            settled_effects = lock_effects(agent_id)

            case unresolved_work(
                   settled_agent,
                   operation,
                   settled_directives,
                   settled_runs,
                   settled_steps,
                   settled_effects,
                   protocol_pair
                 ) do
              nil ->
                finalize_quiesced!(
                  settled_agent,
                  binding,
                  guard,
                  operation,
                  settled_directives,
                  settled_runs,
                  settled_steps,
                  settled_effects,
                  now
                )

              remaining ->
                Repo.rollback({:lifecycle_settlement_incomplete, remaining})
            end

          reason ->
            {:pending, reason, touch!(operation, now)}
        end
    end
  end

  defp finalize_quiesced!(
         agent,
         binding,
         guard,
         operation,
         directives,
         runs,
         steps,
         effects,
         now
       ) do
    scheduled_jobs = lock_scheduled_jobs(agent.id)
    subscriptions = lock_subscriptions(agent.id)

    cancel_pending_directives!(directives, now)
    cancel_scheduled_jobs!(scheduled_jobs)
    deactivate_subscriptions!(subscriptions, now)
    clear_expected_guard!(guard, operation)
    erase_terminal_effects_for_delete!(operation, effects, runs, steps)

    case apply_mutation!(agent, binding, operation, now) do
      {:deleted, deleted_id} ->
        # The Agent delete cascade removes the operation marker in this commit.
        {:finalized,
         %{
           action: :deleted,
           agent: nil,
           agent_id: deleted_id,
           operation_token: operation.operation_token,
           resume_after: false
         }}

      {:updated, updated_agent} ->
        # Delete the marker before deriving delivery authority. The row locks
        # remain held until commit, and any sync failure rolls this delete back.
        Repo.delete!(operation)
        maybe_sync_subscriptions!(updated_agent)

        {:finalized,
         %{
           action: :updated,
           agent: updated_agent,
           agent_id: updated_agent.id,
           operation_token: operation.operation_token,
           resume_after: operation.payload["resume_after"] == true
         }}
    end
  end

  defp apply_mutation!(agent, binding, operation, now) do
    mutation = operation.payload["mutation"] || %{}
    action = mutation["action"]
    final_status = operation.payload["final_status"] || "stopped"

    case action do
      "delete" ->
        Repo.delete!(agent, timeout: :infinity)
        {:deleted, agent.id}

      "pause" ->
        pause_binding!(binding, now)

        {:updated,
         update_agent!(
           agent,
           %{install_status: "paused", status: "stopped", stopped_at: now},
           now
         )}

      "remove" ->
        revoke_binding!(binding, now)

        {:updated,
         update_agent!(
           agent,
           %{
             install_status: "removed",
             status: "stopped",
             stopped_at: now,
             removed_at: now
           },
           now
         )}

      action when action in ["update", "upgrade"] ->
        attrs = mutation["attrs"] || %{}
        attrs = with_final_status(attrs, final_status, now)
        {:updated, update_agent!(agent, attrs, now)}

      "stop" ->
        {:updated,
         update_agent!(agent, %{status: "stopped", stopped_at: agent.stopped_at || now}, now)}

      _other ->
        Repo.rollback(:invalid_lifecycle_payload)
    end
  end

  defp pause_binding!(nil, _now), do: :ok

  defp pause_binding!(binding, now) do
    binding
    |> Ecto.Changeset.change(status: "paused", updated_at: now)
    |> Repo.update!()
  end

  defp revoke_binding!(nil, _now), do: :ok

  defp revoke_binding!(binding, now) do
    binding
    |> Ecto.Changeset.change(status: "revoked", updated_at: now)
    |> Repo.update!()
  end

  defp with_final_status(attrs, "running", now) do
    attrs
    |> Map.put("status", "running")
    |> Map.put("started_at", now)
    |> Map.put("stopped_at", nil)
  end

  defp with_final_status(attrs, "terminated", now) do
    attrs
    |> Map.put("status", "terminated")
    |> Map.put("stopped_at", now)
  end

  defp with_final_status(attrs, _status, now) do
    attrs
    |> Map.put("status", "stopped")
    |> Map.put("stopped_at", now)
  end

  defp update_agent!(agent, attrs, now) do
    agent
    |> Agent.changeset(attrs)
    |> Ecto.Changeset.change(updated_at: now)
    |> Repo.update!()
  end

  defp maybe_sync_subscriptions!(%Agent{status: status, install_status: "enabled"} = agent)
       when status in ["running", "degraded"] do
    case AgentSubscriptions.sync_for_agent_locked(agent) do
      {:ok, _subscriptions} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_sync_subscriptions!(_agent), do: :ok

  defp reconcile_work_after_commit(agent_id, operation, _reason) do
    cancellation_reason = "agent_lifecycle_reconciliation"

    case ProtocolCutover.mode() do
      :exact ->
        with {:ok, plan} <-
               Cancellation.prepare_lifecycle(
                 agent_id,
                 operation.operation_token,
                 cancellation_reason,
                 limit: 100
               ) do
          Cancellation.execute(plan)
        end

      :legacy ->
        EffectRunner.cancel_active_for_agent(agent_id, cancellation_reason)

      {:blocked, reason} ->
        {:error, {:effect_protocol_mismatch, reason}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp settle_orphaned_work!(agent, operation, directives, runs, steps, effects, now) do
    requested_step_ids =
      steps
      |> Enum.filter(&(&1.status == "requested"))
      |> MapSet.new(& &1.id)

    projected_effect_ids =
      effects
      |> Enum.filter(fn effect ->
        effect.status in ["completed", "failed"] and
          is_map(effect.result_envelope) and
          is_binary(effect.agent_run_id) and
          is_binary(effect.agent_run_step_id) and
          MapSet.member?(requested_step_ids, effect.agent_run_step_id)
      end)
      |> Enum.map(& &1.id)

    # Only an actually requested step needs result projection. Loading those
    # few exact payloads preserves normal recovery semantics; corrupt content
    # raises and rolls back, leaving requested authority durably blocked for
    # operator proof instead of inventing an outcome. Already-terminal rows
    # remain metadata-only and can be erased without any decrypt.
    projected_effects = load_projectable_effects!(projected_effect_ids)

    case Agents.reconcile_terminal_effect_steps_in_transaction(projected_effects) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # Projection may have terminalized requested steps with update_all/3. Read
    # them again before abandoning only those still genuinely requested.
    agent.id
    |> lock_steps()
    |> Enum.each(fn
      %AgentRunStep{status: "requested"} = step ->
        step
        |> AgentRunStep.changeset(%{
          status: "failed",
          error: step.error || "agent_lifecycle_cancelled",
          completed_at: now
        })
        |> Repo.update!()

      %AgentRunStep{} ->
        :ok
    end)

    Enum.each(runs, fn
      %AgentRun{status: "running"} = run ->
        run
        |> AgentRun.changeset(%{
          status: "cancelled",
          error: run.error || "agent_lifecycle_cancelled",
          completed_at: now
        })
        |> Repo.update!()

      %AgentRun{} ->
        :ok
    end)

    if is_binary(agent.active_run_id) do
      agent
      |> Ecto.Changeset.change(active_run_id: nil, updated_at: now)
      |> Repo.update!()
    end

    Enum.each(directives, &cancel_directive_for_lifecycle!(&1, now))

    unless delete_action?(operation) do
      projected_effects
      |> Enum.map(& &1.agent_run_id)
      |> Enum.uniq()
      |> Enum.each(fn run_id ->
        case Effects.acknowledge_terminal_results_for_run(run_id, agent.id) do
          {:ok, _count} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    :ok
  end

  defp cancel_directive_for_lifecycle!(
         %AgentDirective{status: status} = directive,
         now
       )
       when status in ["pending", "processing"] do
    {terminal_claim_token, terminal_by_generation} =
      if status == "processing" do
        {directive.claim_token, directive.claimed_by_generation}
      else
        {nil, nil}
      end

    directive
    |> AgentDirective.changeset(%{
      status: "cancelled",
      payload: %{"redacted" => true},
      claim_token: nil,
      claimed_by_generation: nil,
      claimed_at: nil,
      claim_expires_at: nil,
      processing_started_at: nil,
      terminal_at: now,
      terminal_claim_token: terminal_claim_token,
      terminal_by_generation: terminal_by_generation,
      last_error_code: "lifecycle_cancelled",
      ambiguity_code: if(directive.effect_count > 0, do: "effect_outcome_ambiguous", else: nil)
    })
    |> Ecto.Changeset.change(updated_at: now)
    |> Repo.update!()
  end

  defp cancel_directive_for_lifecycle!(%AgentDirective{}, _now), do: :ok

  defp erase_terminal_effects_for_delete!(operation, effects, runs, steps) do
    if delete_action?(operation) do
      SQL.query!(
        Repo,
        "SELECT set_config('maraithon.lifecycle_operation_token', $1, true)",
        [operation.operation_token]
      )

      ids = Enum.map(effects, & &1.id)

      deleted =
        ids
        |> Enum.chunk_every(@max_batch)
        |> Enum.reduce(0, fn batch, count ->
          {batch_deleted, _rows} =
            Repo.delete_all(
              from(effect in Effect,
                where: effect.id in ^batch,
                where: effect.agent_id == ^operation.agent_id,
                where: effect.status in ^@terminal_effect_statuses
              ),
              timeout: :infinity
            )

          count + batch_deleted
        end)

      if deleted != length(effects), do: Repo.rollback(:effect_erasure_fence_lost)

      # Delete Snapshots while the durable lifecycle marker still exists.
      # PostgreSQL may otherwise cascade-delete the operation row first.
      Repo.delete_all(
        from(snapshot in Snapshot, where: snapshot.agent_id == ^operation.agent_id),
        timeout: :infinity
      )

      # Delete runtime history directly under the executor role. PostgreSQL FK
      # cascades execute referential actions under table-owner authority, which
      # must not be mistaken for an ordinary runtime mutation by role guards.
      delete_locked_history!(AgentRunStep, steps, operation.agent_id)
      delete_locked_history!(AgentRun, runs, operation.agent_id)
    end

    :ok
  end

  defp delete_locked_history!(schema, rows, agent_id) do
    deleted =
      rows
      |> Enum.map(& &1.id)
      |> Enum.chunk_every(@max_batch)
      |> Enum.reduce(0, fn batch, count ->
        {batch_deleted, _rows} =
          Repo.delete_all(
            from(row in schema, where: row.id in ^batch, where: row.agent_id == ^agent_id),
            timeout: :infinity
          )

        count + batch_deleted
      end)

    if deleted != length(rows), do: Repo.rollback(:runtime_history_erasure_fence_lost)
  end

  defp unresolved_work(agent, operation, directives, runs, steps, effects, protocol_pair) do
    cond do
      is_binary(agent.active_run_id) ->
        :active_run_pointer

      Enum.any?(directives, &(&1.status == "processing")) ->
        :processing_directive

      Enum.any?(runs, &(&1.status == "running")) ->
        :running_agent_run

      Enum.any?(steps, &(&1.status == "requested")) ->
        :requested_agent_run_step

      Enum.any?(effects, &(&1.status in @active_effect_statuses)) ->
        :active_effect

      delete_action?(operation) and
          not effects_deletable_for_delete?(effects, protocol_pair) ->
        :effect_retention_requires_archival

      true ->
        nil
    end
  end

  defp delete_action?(operation),
    do: get_in(operation.payload, ["mutation", "action"]) == "delete"

  # Legacy Effect rows predate terminal envelopes, and the database's legacy
  # protocol permits their lifecycle erasure once active work is absent. Exact
  # mode remains fail-closed on the versioned archival envelope.
  defp effects_deletable_for_delete?(effects, :legacy) do
    Enum.all?(effects, fn
      %Effect{runtime_owner_generation: nil, status: status}
      when status in @terminal_effect_statuses ->
        true

      %Effect{} ->
        false
    end)
  end

  defp effects_deletable_for_delete?(effects, :exact) do
    # The persisted lifecycle delete marker is an explicit erasure intent, not
    # a fabricated delivery acknowledgement. The DB trigger independently
    # rechecks the marker and refuses every active Effect row.
    Enum.all?(effects, fn
      %Effect{status: "cancelled", result_envelope: nil} ->
        true

      %Effect{status: status, result_envelope: envelope}
      when status in @terminal_effect_statuses and is_map(envelope) ->
        envelope["version"] == 1 and envelope["status"] in ["ok", "error"]

      %Effect{} ->
        false
    end)
  end

  defp cancel_pending_directives!(directives, now) do
    directives
    |> Enum.filter(&(&1.status == "pending"))
    |> Enum.each(fn directive ->
      directive
      |> Ecto.Changeset.change(%{
        status: "cancelled",
        terminal_at: now,
        claim_token: nil,
        claimed_by_generation: nil,
        claimed_at: nil,
        claim_expires_at: nil,
        processing_started_at: nil,
        terminal_claim_token: nil,
        terminal_by_generation: nil,
        last_error_code: "cancelled",
        updated_at: now
      })
      |> Repo.update!()
    end)
  end

  defp cancel_scheduled_jobs!(jobs) do
    Enum.each(jobs, fn job ->
      job
      |> Ecto.Changeset.change(%{
        status: "cancelled",
        claimed_by: nil,
        claimed_at: nil,
        dispatched_at: nil
      })
      |> Repo.update!()
    end)
  end

  defp deactivate_subscriptions!(subscriptions, now) do
    Enum.each(subscriptions, fn subscription ->
      subscription
      |> Ecto.Changeset.change(status: "inactive", updated_at: now)
      |> Repo.update!()
    end)
  end

  defp clear_expected_guard!(nil, _operation), do: :ok

  defp clear_expected_guard!(%AgentRestartGuard{} = guard, operation) do
    if guard.needs_recovery or guard.tripped do
      if guard_matches_operation?(guard, operation) do
        Repo.delete!(guard)
      else
        Repo.rollback(:restart_guard_requires_reconciliation)
      end
    end

    :ok
  end

  defp guard_finalizable?(nil, _operation), do: true

  defp guard_finalizable?(%AgentRestartGuard{} = guard, operation) do
    not (guard.needs_recovery or guard.tripped) or guard_matches_operation?(guard, operation)
  end

  defp guard_matches_operation?(guard, operation) do
    expected_owner = operation.expected_owner_token

    is_binary(expected_owner) and guard.last_owner_token == expected_owner
  end

  defp adopt!(operation, kind, request_digest, requires_external_drain, now, agent, lease) do
    validate_payload!(operation)

    if operation.kind == kind and operation.request_digest == request_digest do
      operation =
        if requires_external_drain and not operation.requires_external_drain do
          payload =
            operation.payload
            |> Map.put("requires_external_drain", true)
            |> canonical_payload!()

          operation
          |> Ecto.Changeset.change(%{
            payload: payload,
            payload_digest: digest(payload),
            requires_external_drain: true,
            external_drain_confirmed_at: nil,
            external_drain_evidence_digest: nil,
            last_attempted_at: now,
            updated_at: now
          })
          |> Repo.update!()
        else
          touch!(operation, now)
        end

      lifecycle_fence(operation, agent, lease, :adopted)
    else
      Repo.rollback(:agent_drain_pending)
    end
  end

  defp lifecycle_fence(operation, agent, lease, disposition) do
    %{
      operation: operation,
      operation_token: operation.operation_token,
      agent: agent,
      lease: lease,
      lease_state: if(lease, do: :live, else: :none),
      disposition: disposition
    }
  end

  defp validate_operation!(operation, operation_token) do
    if operation.operation_token == operation_token,
      do: operation,
      else: Repo.rollback(:lifecycle_operation_token_mismatch)
  end

  @doc false
  def expected_termination?(
        %AgentLifecycleOperation{} = operation,
        agent_id,
        owner_token
      )
      when is_binary(agent_id) and is_binary(owner_token) do
    valid_payload?(operation) and
      operation.state == "draining" and
      operation.agent_id == agent_id and
      operation.expected_owner_token == owner_token and
      get_in(operation.payload, ["mutation", "action"]) == operation.kind
  end

  def expected_termination?(_operation, _agent_id, _owner_token), do: false

  defp validate_payload!(operation) do
    if valid_payload?(operation),
      do: operation,
      else: Repo.rollback(:invalid_lifecycle_payload)
  end

  defp valid_payload?(operation) do
    with {:ok, payload} <- canonical_payload(operation.payload),
         true <- payload == operation.payload,
         true <- digest(payload) == operation.payload_digest,
         request when is_map(request) <- payload["request"],
         true <- digest(request) == operation.request_digest,
         true <- payload["kind"] == operation.kind,
         true <- payload["operation_token"] == operation.operation_token,
         true <- payload["expected_owner_token"] == operation.expected_owner_token,
         true <- payload["requires_external_drain"] == operation.requires_external_drain,
         1 <- payload["version"] do
      true
    else
      _invalid -> false
    end
  end

  defp touch!(operation, now) do
    operation
    |> Ecto.Changeset.change(last_attempted_at: now, updated_at: now)
    |> Repo.update!()
  end

  defp fence_lease!(nil, _now, _ttl_ms), do: nil

  defp fence_lease!(%AgentRuntimeLease{} = lease, now, ttl_ms) do
    if DateTime.compare(lease.lease_until, now) == :gt do
      drain_until = DateTime.add(now, ttl_ms, :millisecond)

      lease
      |> Ecto.Changeset.change(%{
        ready_at: nil,
        draining_at: lease.draining_at || now,
        lease_until: later_datetime(lease.lease_until, drain_until),
        updated_at: now
      })
      |> Repo.update!()
    else
      Repo.rollback(
        {:expired_lease_requires_reconciliation,
         %{owner_token: lease.owner_token, owner_node: lease.owner_node}}
      )
    end
  end

  defp live_lease?(nil, _now), do: false

  defp live_lease?(lease, now),
    do: DateTime.compare(lease.lease_until, now) == :gt

  defp stopped_at(%Agent{status: "stopped", stopped_at: %DateTime{} = stopped_at}, _now),
    do: stopped_at

  defp stopped_at(_agent, now), do: now

  defp resume_after?(kind, agent),
    do: kind in ["update", "upgrade"] and agent.status in ["recovering", "running", "degraded"]

  defp final_status(kind, _agent, true) when kind in ["update", "upgrade"], do: "running"

  defp final_status(kind, %{status: "terminated"}, false) when kind in ["update", "upgrade"],
    do: "terminated"

  defp final_status(_kind, _agent, _resume_after), do: "stopped"

  defp plan!(planner, agent) do
    case planner.(agent) do
      {:ok, mutation} when is_map(mutation) -> canonical_payload!(mutation)
      mutation when is_map(mutation) -> canonical_payload!(mutation)
      {:error, reason} -> Repo.rollback(reason)
      _invalid -> Repo.rollback(:invalid_lifecycle_payload)
    end
  end

  defp canonical_payload!(payload) do
    case canonical_payload(payload) do
      {:ok, canonical} -> canonical
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp guard_snapshot(nil), do: nil

  defp guard_snapshot(guard) do
    %{
      "generation" => guard.generation,
      "last_owner_token" => guard.last_owner_token,
      "needs_recovery" => guard.needs_recovery,
      "tripped" => guard.tripped
    }
  end

  defp owner_token(nil), do: nil
  defp owner_token(lease), do: lease.owner_token

  defp expected_guard_owner(%AgentRestartGuard{last_owner_token: token} = guard)
       when is_binary(token) do
    if guard.needs_recovery or guard.tripped, do: token, else: nil
  end

  defp expected_guard_owner(_guard), do: nil

  # Durable child-table writes take the privacy User fence in their database
  # triggers. Acquire that fence before the Agent prefix so a successor lease
  # claimant (User -> Agent) cannot deadlock with finalization (Agent -> User).
  defp prelock_agent_user!(agent_id) do
    case SQL.query!(
           Repo,
           """
           SELECT user_row.id
           FROM public.users AS user_row
           JOIN public.agents AS agent_row ON agent_row.user_id = user_row.id
           WHERE agent_row.id = $1::uuid
           FOR UPDATE OF user_row
           """,
           [Ecto.UUID.dump!(agent_id)]
         ).rows do
      [[user_id]] when is_binary(user_id) -> user_id
      [] -> Repo.rollback(:not_found)
    end
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:not_found)
    end
  end

  defp lock_binding(%Agent{id: agent_id, user_id: user_id}) when is_binary(user_id) do
    Repo.one(
      from(binding in Binding,
        where: binding.agent_id == ^agent_id,
        where: binding.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_binding(_agent), do: nil

  defp lock_guard(agent_id) do
    Repo.one(
      from(guard in AgentRestartGuard,
        where: guard.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_lease(agent_id) do
    Repo.one(
      from(lease in AgentRuntimeLease,
        where: lease.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_open_termination_incident(agent_id) do
    Repo.one(
      from(incident in AgentTerminationIncident,
        where: incident.agent_id == ^agent_id,
        where: incident.status in ["requested", "proven"],
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_operation(agent_id) do
    Repo.one(
      from(operation in AgentLifecycleOperation,
        where: operation.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_directives(agent_id) do
    Repo.all(
      from(directive in AgentDirective,
        where: directive.agent_id == ^agent_id,
        order_by: [asc: directive.inserted_at, asc: directive.id],
        select: struct(directive, ^@directive_authority_fields),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_runs(agent_id) do
    Repo.all(
      from(run in AgentRun,
        where: run.agent_id == ^agent_id,
        order_by: [asc: run.inserted_at, asc: run.id],
        select: struct(run, ^@run_authority_fields),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_steps(agent_id) do
    Repo.all(
      from(step in AgentRunStep,
        where: step.agent_id == ^agent_id,
        order_by: [asc: step.inserted_at, asc: step.id],
        select: struct(step, ^@step_authority_fields),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_effects(agent_id) do
    Repo.all(
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        order_by: [asc: effect.inserted_at, asc: effect.id],
        select: struct(effect, ^@effect_authority_fields),
        lock: "FOR UPDATE"
      )
    )
  end

  defp load_projectable_effects!([]), do: []

  defp load_projectable_effects!(ids) do
    Repo.all(
      from(effect in Effect,
        where: effect.id in ^ids,
        order_by: [asc: effect.inserted_at, asc: effect.id]
      )
    )
  rescue
    _error -> Repo.rollback(:terminal_effect_payload_unreadable)
  end

  defp lock_scheduled_jobs(agent_id) do
    Repo.all(
      from(job in ScheduledJob,
        where: job.agent_id == ^agent_id,
        where: job.status in ["pending", "dispatched"],
        order_by: [asc: job.inserted_at, asc: job.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_subscriptions(agent_id) do
    Repo.all(
      from(subscription in AgentSubscription,
        where: subscription.agent_id == ^agent_id,
        where: subscription.status == "active",
        order_by: [asc: subscription.inserted_at, asc: subscription.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp later_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp kind(value) do
    kind = to_string(value)

    if kind in AgentLifecycleOperation.kinds(),
      do: {:ok, kind},
      else: {:error, :invalid_lifecycle_operation}
  end

  defp begin_options(opts) do
    allowed = [:drain_ttl_ms, :requires_external_drain, :privacy_erasure_request_id]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      ttl_ms = Keyword.get(opts, :drain_ttl_ms, @default_drain_ttl_ms)
      requires_external_drain = Keyword.get(opts, :requires_external_drain, false)

      with true <- is_integer(ttl_ms) and ttl_ms in 1_000..300_000,
           true <- is_boolean(requires_external_drain),
           {:ok, privacy_request_id} <-
             optional_uuid(Keyword.get(opts, :privacy_erasure_request_id)) do
        {:ok, ttl_ms, requires_external_drain, privacy_request_id}
      else
        _invalid -> {:error, :invalid_lifecycle_operation}
      end
    else
      {:error, :invalid_lifecycle_operation}
    end
  end

  defp set_privacy_erasure_context!(nil), do: :ok

  defp set_privacy_erasure_context!(request_id) do
    Repo.query!(
      "SELECT set_config('maraithon.privacy_erasure_request_id', $1, true)",
      [request_id],
      log: false
    )

    :ok
  end

  defp external_drain_evidence(evidence) do
    with {:ok, evidence} <- canonical_payload(evidence),
         true <- evidence["non_rolling"] == true,
         proof_id when is_binary(proof_id) and byte_size(proof_id) in 1..256 <-
           evidence["proof_id"],
         confirmer when is_binary(confirmer) and byte_size(confirmer) in 1..320 <-
           evidence["confirmed_by"],
         revision when is_binary(revision) and byte_size(revision) in 1..128 <-
           evidence["legacy_revision"] do
      {:ok, evidence}
    else
      _invalid -> {:error, :invalid_external_drain_evidence}
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: cast_uuid(value)

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_lifecycle_operation}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_lifecycle_operation}

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> then(&{:map, &1})
  end

  defp canonical_term(list) when is_list(list), do: {:list, Enum.map(list, &canonical_term/1)}
  defp canonical_term(value), do: value
end
