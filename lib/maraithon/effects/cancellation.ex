defmodule Maraithon.Effects.Cancellation do
  @moduledoc """
  Partition-safe two-phase cancellation for exact durable Effect claims.

  Phase one is database-only and may compose into an AgentIsolation transaction.
  It persists cancellation intent while retaining the immutable Effect claim
  token and physical task identity. Phase two runs only after commit: it routes
  to the persisted owner, obtains coupled Task.Supervisor proof, and settles the
  exact claim as `failed/effect_outcome_ambiguous`. Unreachable, partitioned,
  legacy, or otherwise unproved work remains durably `cancelling` until exact
  supervisor proof or a task-bound operator attestation exists.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Effects.CancellationPlan
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Effects.TerminationAttestations
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.EffectTaskSupervisor
  alias Maraithon.Runtime.Coordination.{Protocol, TaskAssignment, TaskClaims}

  @default_plan_limit 32
  @max_plan_limit 100
  @max_runtime_nodes 32
  @rpc_timeout_ms 5_000
  @guardian_persistence_timeout_ms 5_000
  @ambiguous_outcome :effect_outcome_ambiguous
  @pre_provider_failure_prefix "effect_preflight_failed:"
  @pre_provider_retry_prefix "effect_preflight_retry:"
  @pre_provider_intent_marker "__maraithon_pre_provider_intent_v1"
  @pre_provider_intent_envelope_version 1
  @internal_pre_provider_abort_reasons [
    "claim_liveness_expired",
    "effect_runner_shutdown",
    "effect_task_exited_without_outcome",
    "effect_task_start_ambiguous"
  ]

  @doc "True while the persisted epoch permits exact cancellation/reconciliation."
  def enabled?, do: ProtocolCutover.exact_reconciliation_enabled?()

  @doc false
  def exact_writes_enabled?, do: ProtocolCutover.exact_writes_enabled?()

  @doc false
  def pre_provider_error_code(reason), do: bounded_pre_provider_error_code(reason)

  @doc false
  def pre_provider_failure_reason(error_code),
    do: @pre_provider_failure_prefix <> bounded_pre_provider_error_code(error_code)

  @doc false
  def pre_provider_retry_reason(error_code),
    do: @pre_provider_retry_prefix <> bounded_pre_provider_error_code(error_code)

  @doc false
  def pre_provider_intent_marker, do: @pre_provider_intent_marker

  @doc false
  def pre_provider_failure_envelope(
        result_envelope,
        attempts,
        failure_code,
        failure_attempt
      )
      when is_map(result_envelope) and is_integer(attempts) and attempts >= 0 do
    %{
      "attempt" => attempts,
      "intent" => "pre_provider_failure",
      "provenance" => encode_pre_provider_provenance(failure_code, failure_attempt),
      "terminal_envelope" => result_envelope,
      "version" => @pre_provider_intent_envelope_version
    }
  end

  @doc false
  def pre_provider_retry_envelope(error_code, attempts, failure_code, failure_attempt)
      when is_binary(error_code) and is_integer(attempts) and attempts >= 0 do
    %{
      "attempt" => attempts,
      "error_code" => error_code,
      "intent" => "pre_provider_retry",
      "provenance" => encode_pre_provider_provenance(failure_code, failure_attempt),
      "version" => @pre_provider_intent_envelope_version
    }
  end

  @doc false
  def protocol_mode, do: ProtocolCutover.mode()

  @doc "Verify the reviewed fleet epoch, exact schema, and every active Effect shape."
  def activation_preconditions, do: ProtocolCutover.activation_preconditions()

  @doc false
  def fence_effect_admission!(agent_id, runtime_owner_generation) do
    _lease_until =
      fence_effect_admission_lease_until!(agent_id, runtime_owner_generation)

    :ok
  end

  @doc false
  def fence_effect_admission_lease_until!(agent_id, runtime_owner_generation) do
    require_transaction!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, runtime_owner_generation} <- cast_uuid(runtime_owner_generation) do
      require_active_effect_pair!()
      AgentLeases.fence_ready_lease_until!(agent_id, runtime_owner_generation)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def request_coordination_drain_in_transaction!(
        node_incarnation_id,
        partition_id,
        partition_epoch,
        reason,
        lock_topology
      )
      when is_binary(node_incarnation_id) and is_integer(partition_id) and
             is_integer(partition_epoch) and is_binary(reason) and is_function(lock_topology, 0) do
    require_transaction!()
    require_active_effect_pair!()

    request_coordination_drain_after_validation!(
      node_incarnation_id,
      partition_id,
      partition_epoch,
      reason,
      lock_topology
    )
  end

  @doc false
  def request_coordination_drain_after_pair_lock_in_transaction!(
        pair_lock,
        node_incarnation_id,
        partition_id,
        partition_epoch,
        reason,
        lock_topology,
        trace \\ fn _stage -> :ok end
      )
      when is_binary(node_incarnation_id) and is_integer(partition_id) and
             is_integer(partition_epoch) and is_binary(reason) and is_function(lock_topology, 0) and
             is_function(trace, 1) do
    require_transaction!()
    :ok = Protocol.reuse_effect_pair_lock!(pair_lock, trace)

    request_coordination_drain_after_validation!(
      node_incarnation_id,
      partition_id,
      partition_epoch,
      reason,
      lock_topology
    )
  end

  defp request_coordination_drain_after_validation!(
         node_incarnation_id,
         partition_id,
         partition_epoch,
         reason,
         lock_topology
       ) do
    # A durable topology fence must already prevent new work from entering this
    # incarnation. Lock the stable Effect set first, then let Authority lock and
    # revalidate node/partition authority before assignment mutations. Guardian
    # persistence uses this same Effect -> topology -> assignment order.
    effects =
      Repo.all(
        from effect in Effect,
          where: effect.coordination_node_incarnation_id == ^node_incarnation_id,
          where: effect.coordination_partition_id == ^partition_id,
          where: effect.coordination_partition_epoch == ^partition_epoch,
          where: effect.status in ["pending", "claimed", "executing", "cancelling"],
          order_by: [asc: effect.id],
          lock: "FOR UPDATE"
      )

    _ = lock_topology.()
    now = DatabaseClock.now!()

    Enum.each(effects, fn effect ->
      if effect.status == "pending" do
        effect
        |> Ecto.Changeset.change(%{
          status: "cancelled",
          cancellation_state: "settled",
          cancellation_reason: reason,
          cancellation_requested_at: now,
          cancellation_target_claim_token: nil,
          cancellation_last_attempt_at: nil,
          cancellation_last_error: nil,
          cancellation_settled_at: now,
          claimed_by: nil,
          claimed_at: nil,
          retry_after: nil,
          result: nil,
          result_envelope: nil,
          error: reason,
          updated_at: now
        })
        |> Repo.update!()
      else
        request_coordination_termination!(effect)

        if effect.status != "cancelling" do
          effect
          |> Ecto.Changeset.change(%{
            status: "cancelling",
            cancellation_state: "requested",
            cancellation_reason: reason,
            cancellation_requested_at: now,
            cancellation_target_claim_token: effect.claim_token,
            cancellation_last_attempt_at: nil,
            cancellation_last_error: nil,
            cancellation_settled_at: nil,
            retry_after: nil,
            error: reason,
            updated_at: now
          })
          |> Repo.update!()
        end
      end
    end)

    length(effects)
  end

  @doc false
  def record_local_coordination_termination(_assignment, _evidence_id),
    do: {:error, :local_task_termination_capability_required}

  @doc false
  def record_local_coordination_termination(
        %TaskAssignment{work_kind: "effect"} = assignment,
        proof_kind,
        evidence_id,
        capability_secret
      )
      when proof_kind in ["supervisor_down", "never_activated"] and is_binary(evidence_id) and
             byte_size(evidence_id) in 1..256 and is_binary(capability_secret) and
             byte_size(capability_secret) == 32 do
    Repo.transaction(fn ->
      require_active_effect_pair!()

      record_local_coordination_termination_in_transaction!(
        assignment,
        proof_kind,
        evidence_id,
        capability_secret
      )
    end)
  end

  def record_local_coordination_termination(_assignment, _kind, _evidence, _capability),
    do: {:error, :local_task_termination_capability_required}

  defp record_local_coordination_termination_in_transaction!(
         %TaskAssignment{work_kind: "effect"} = assignment,
         proof_kind,
         evidence_id,
         capability_secret
       ) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "local Effect proof requires a transaction")

    effect =
      case Repo.one(
             from effect in Effect,
               where: effect.id == ^assignment.work_id,
               where: effect.status == "cancelling",
               where: effect.cancellation_state == "requested",
               lock: "FOR UPDATE"
           ) do
        %Effect{} = value -> value
        nil -> Repo.rollback(:effect_claim_lost)
      end

    case coordination_assignment(effect) do
      {:ok, expected} ->
        unless exact_coordination_assignment?(assignment, expected),
          do: Repo.rollback(:coordination_task_authority_lost)

        actual = exact_coordination_assignment!(expected)

        {proof_kind, evidence_id} =
          case actual do
            %TaskAssignment{state: "reserved", provider_boundary: "not_entered", ready_at: nil} ->
              {"never_activated", "task-supervisor:never_activated:#{actual.local_task_id}"}

            _activated ->
              {proof_kind, evidence_id}
          end

        actual = prepare_local_proof_assignment!(actual, proof_kind)

        case actual.state do
          "termination_proven" ->
            actual

          state when state in ["reserved", "termination_requested"] ->
            case TaskClaims.record_local_termination(
                   actual,
                   proof_kind,
                   evidence_id,
                   capability_secret
                 ) do
              {:ok, %TaskAssignment{state: "termination_proven"} = proven} -> proven
              _lost -> Repo.rollback(:coordination_task_termination_proof_lost)
            end

          _terminal_or_mismatched ->
            Repo.rollback(:coordination_task_authority_lost)
        end

      _uncoordinated_or_mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp prepare_local_proof_assignment!(
         %TaskAssignment{state: "running"} = assignment,
         "supervisor_down"
       ),
       do: TaskClaims.request_effect_termination_in_transaction!(assignment)

  defp prepare_local_proof_assignment!(assignment, _proof_kind), do: assignment

  @doc false
  def terminate_local_coordination_assignment(
        %TaskAssignment{work_kind: "effect"},
        claim
      )
      when is_map(claim) do
    case EffectTaskSupervisor.terminate_exact(claim) do
      {:ok, proof_kind} when proof_kind in [:supervisor_down, :never_activated] ->
        {:ok, :termination_proven}

      other ->
        other
    end
  end

  def terminate_local_coordination_assignment(_assignment, _claim),
    do: {:unknown, :invalid_effect_claim}

  @doc "Persist cancellation intent and execute the first exact post-commit page."
  def request(agent_id, reason, opts \\ []) do
    with {:ok, plan} <- prepare(agent_id, reason, opts) do
      execute(plan)
    end
  end

  @doc "Persist cancellation intent without process, RPC, or network calls."
  def prepare(agent_id, reason, opts \\ []) do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, reason} <- cancellation_reason(reason),
         {:ok, parsed_opts} <- prepare_agent_opts(opts) do
      Repo.transaction(fn ->
        prepare_in_transaction!(agent_id, reason, parsed_opts)
      end)
    end
  end

  @doc false
  def prepare_lifecycle(agent_id, operation_token, reason, opts \\ [])

  def prepare_lifecycle(agent_id, operation_token, reason, opts) when is_list(opts) do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, operation_token} <- cast_uuid(operation_token),
         {:ok, reason} <- cancellation_reason(reason),
         true <- Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :limit)),
         {:ok, limit} <- plan_limit(Keyword.get(opts, :limit, @default_plan_limit)) do
      Repo.transaction(fn ->
        require_active_effect_pair!()
        _effects = lock_effects_for_cancellation!(agent_id)
        agent = lock_agent!(agent_id)
        _binding = lock_optional_same_user_binding!(agent)
        lease = lock_runtime_rows!(agent_id)
        ensure_lifecycle_authority!(agent, operation_token, lease)
        now = DatabaseClock.now!()

        pending_cancelled = cancel_pending!(agent_id, reason, now)
        requested = request_active_cancellation!(agent_id, reason, now)
        {claims, more?} = requested_claim_page(agent_id, limit)

        %CancellationPlan{
          agent_id: agent.id,
          user_id: agent.user_id,
          reason: reason,
          claims: claims,
          pending_cancelled: pending_cancelled,
          requested: pending_cancelled + requested,
          more?: more?,
          lifecycle_operation_token: operation_token
        }
      end)
    else
      _invalid -> {:error, :invalid_effect_cancellation}
    end
  end

  def prepare_lifecycle(_agent_id, _operation_token, _reason, _opts),
    do: {:error, :invalid_effect_cancellation}

  @doc """
  Compose phase one into a caller-owned transaction.

  AgentIsolation must retain the returned plan and call `execute/1` only after
  the outer transaction commits. This function deliberately does not redesign
  or mutate Binding authority itself.
  """
  def prepare_in_transaction!(agent_id, reason, opts \\ []) do
    require_transaction!()

    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, reason} <- cancellation_reason(reason),
         {:ok, parsed_opts} <- normalize_agent_prepared_opts(opts) do
      require_active_effect_pair!()
      _effects = lock_effects_for_cancellation!(agent_id)
      agent = lock_agent!(agent_id)
      binding = lock_same_user_binding!(agent)
      ensure_expected_user!(binding, parsed_opts.user_id)
      lease = lock_runtime_rows!(agent_id)
      ensure_expected_runtime_owner!(lease, parsed_opts.expected_runtime_owner_generation)
      now = DatabaseClock.now!()

      pending_cancelled = cancel_pending!(agent_id, reason, now)
      requested = request_active_cancellation!(agent_id, reason, now)
      {claims, more?} = requested_claim_page(agent_id, parsed_opts.limit)

      %CancellationPlan{
        agent_id: agent.id,
        user_id: binding.user_id,
        reason: reason,
        claims: claims,
        pending_cancelled: pending_cancelled,
        requested: pending_cancelled + requested,
        more?: more?
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def prepare_exact_claims(agent_id, effects, reason, opts \\ [])

  def prepare_exact_claims(agent_id, effects, reason, opts) when is_list(effects) do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, reason} <- cancellation_reason(reason),
         {:ok, references} <- exact_references(effects),
         true <- length(references) <= @max_plan_limit,
         {:ok, parsed_opts} <- prepare_opts(opts) do
      prepare_exact_claims_with_reason(
        agent_id,
        references,
        reason,
        parsed_opts,
        :ordinary
      )
    else
      false -> {:error, :invalid_effect_cancellation}
      {:error, _reason} = error -> error
    end
  end

  def prepare_exact_claims(_agent_id, _effects, _reason, _opts),
    do: {:error, :invalid_effect_cancellation}

  @doc false
  def prepare_runtime_abort(agent_id, effects, reason, opts \\ [])

  def prepare_runtime_abort(agent_id, effects, reason, opts)
      when is_list(effects) and reason in @internal_pre_provider_abort_reasons do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, references} <- exact_references(effects),
         true <- length(references) <= @max_plan_limit,
         {:ok, parsed_opts} <- prepare_opts(opts) do
      prepare_exact_claims_with_reason(
        agent_id,
        references,
        reason,
        parsed_opts,
        :internal_pre_provider_abort
      )
    else
      false -> {:error, :invalid_effect_cancellation}
      {:error, _reason} = error -> error
    end
  end

  def prepare_runtime_abort(_agent_id, _effects, _reason, _opts),
    do: {:error, :invalid_effect_cancellation}

  defp prepare_exact_claims_with_reason(agent_id, references, reason, parsed_opts, intent) do
    Repo.transaction(fn ->
      require_active_effect_pair!()
      _effects = lock_referenced_effects!(agent_id, references)
      agent = lock_agent!(agent_id)
      binding = lock_same_user_binding!(agent)
      ensure_expected_user!(binding, parsed_opts.user_id)
      lock_runtime_rows!(agent_id)
      now = DatabaseClock.now!()

      claims =
        references
        |> Enum.map(&request_exact_claim!(agent_id, &1, reason, now, intent))
        |> Enum.reject(&is_nil/1)

      %CancellationPlan{
        agent_id: agent.id,
        user_id: binding.user_id,
        reason: reason,
        claims: claims,
        pending_cancelled: 0,
        requested: length(claims),
        more?: false
      }
    end)
  end

  @doc "Execute only exact claims from an already-committed plan."
  def execute(%CancellationPlan{} = plan) do
    if Repo.in_transaction?() do
      {:error, :effect_cancellation_requires_post_commit}
    else
      {settled, duplicates, unresolved} =
        case authorize_plan_execution(plan) do
          :ok -> execute_claims(plan)
          {:error, reason} -> {0, 0, [{nil, reason}]}
        end

      unresolved =
        case unresolved_protocol_count(plan.agent_id) do
          0 -> unresolved
          count -> [{nil, {:effect_protocol_mismatch, count}} | unresolved]
        end

      summary = %{
        agent_id: plan.agent_id,
        requested: plan.requested,
        pending_cancelled: plan.pending_cancelled,
        claims_settled: settled,
        duplicate_settlements: duplicates,
        unresolved: Enum.reverse(unresolved),
        more?: plan.more?
      }

      if unresolved == [] and not plan.more?, do: {:ok, summary}, else: {:pending, summary}
    end
  end

  def execute(_plan), do: {:error, :invalid_effect_cancellation_plan}

  @doc "Retry a bounded durable page for one Agent after the staging commit."
  def reconcile_agent(agent_id, limit \\ @default_plan_limit) do
    with :ok <- require_enabled(),
         false <- Repo.in_transaction?(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, limit} <- plan_limit(limit),
         {:ok, plan} <- load_agent_plan(agent_id, limit) do
      execute(plan)
    else
      true -> {:error, :effect_cancellation_requires_post_commit}
      {:error, _reason} = error -> error
    end
  end

  @doc "Retry a bounded global page of committed exact cancellations."
  def reconcile(limit \\ @default_plan_limit) do
    with :ok <- require_enabled(),
         false <- Repo.in_transaction?(),
         {:ok, limit} <- plan_limit(limit) do
      # Surprise rows and exact cancellations use independent bounded pages so
      # a permanent malformed/legacy row cannot starve physical exact claims.
      surprises = protocol_mismatch_candidates(limit)

      exact_results =
        cancellation_candidates(limit)
        |> Enum.map(fn {agent_id, effect_id, claim_token} ->
          case load_committed_plan(agent_id, effect_id, claim_token) do
            {:ok, plan} -> {effect_id, execute(plan)}
            {:error, reason} -> {effect_id, {:error, reason}}
          end
        end)

      Enum.map(surprises, fn effect_id ->
        {effect_id, {:error, {:effect_protocol_mismatch, :surprise_active_shape}}}
      end) ++ exact_results
    else
      _disabled_or_invalid -> []
    end
  end

  @doc "Fence a bounded page of expired exact claims without taking them over."
  def fence_expired_claims(limit \\ @max_plan_limit)

  def fence_expired_claims(limit) when is_integer(limit) and limit in 1..@max_plan_limit do
    if enabled?() do
      expired_claim_candidates(limit)
      |> Enum.flat_map(fn {agent_id, effect_id, claim_token} ->
        case prepare_expired_claim(agent_id, effect_id, claim_token) do
          {:ok, %CancellationPlan{} = plan} -> [plan]
          _lost_or_failed -> []
        end
      end)
    else
      []
    end
  end

  def fence_expired_claims(_limit), do: []

  @doc false
  def terminate_exact_on_owner(claim) when is_map(claim) do
    with {:ok, claim} <- validate_claim(claim),
         true <- claim.owner_node == Atom.to_string(node()),
         {:ok, persisted} <- load_persisted_claim(claim) do
      if coordination_termination_already_proven?(persisted) do
        {:ok, :termination_proven}
      else
        case EffectTaskSupervisor.terminate_exact(persisted) do
          {:ok, proof_kind} when proof_kind in [:supervisor_down, :never_activated] ->
            {:ok, :termination_proven}

          {:unknown, reason} ->
            {:unknown, reason}

          _unexpected ->
            {:unknown, :effect_task_termination_unproven}
        end
      end
    else
      false -> {:unknown, :effect_claim_wrong_physical_owner}
      {:duplicate, _persisted} -> {:unknown, :effect_cancellation_already_settled}
      {:error, reason} -> {:unknown, reason}
    end
  end

  def terminate_exact_on_owner(_claim), do: {:unknown, :invalid_effect_claim}

  defp coordination_termination_already_proven?(%{
         assignment_id: assignment_id,
         effect_id: effect_id,
         claim_token: claim_token,
         supervisor_id: supervisor_id,
         task_id: task_id
       })
       when is_binary(assignment_id) and is_binary(effect_id) and is_binary(claim_token) and
              is_binary(supervisor_id) and is_binary(task_id) do
    case TaskClaims.get(assignment_id) do
      %TaskAssignment{
        state: state,
        work_kind: "effect",
        work_id: ^effect_id,
        claim_token: ^claim_token,
        supervisor_id: ^supervisor_id,
        local_task_id: ^task_id
      }
      when state in ["termination_proven", "settled", "outcome_ambiguous"] ->
        true

      _not_exactly_proven ->
        false
    end
  end

  defp coordination_termination_already_proven?(effect) do
    case coordination_assignment(effect) do
      {:ok, expected} ->
        case TaskClaims.get(expected.id) do
          %TaskAssignment{state: state} = actual
          when state in ["termination_proven", "settled", "outcome_ambiguous"] ->
            exact_coordination_assignment?(actual, expected)

          _not_proven ->
            false
        end

      _uncoordinated_or_mismatched ->
        false
    end
  end

  @doc false
  def terminate_physical_identity_on_owner(identity) when is_map(identity) do
    query =
      from effect in Effect,
        where: effect.id == ^Map.get(identity, :effect_id),
        where: effect.agent_id == ^Map.get(identity, :agent_id),
        where: effect.claim_token == ^Map.get(identity, :claim_token),
        where: effect.claim_supervisor_id == ^Map.get(identity, :supervisor_id),
        where: effect.claim_task_id == ^Map.get(identity, :task_id)

    query =
      case Map.get(identity, :assignment_id) do
        assignment_id when is_binary(assignment_id) ->
          from effect in query,
            where: effect.coordination_task_assignment_id == ^assignment_id

        nil ->
          from effect in query,
            where: is_nil(effect.coordination_task_assignment_id)

        _invalid ->
          from effect in query, where: false
      end

    case Repo.one(query) do
      %Effect{status: "cancelling", cancellation_state: "requested"} = effect ->
        terminate_exact_on_owner(claim_from_effect!(effect))

      %Effect{status: status} when status in ["completed", "failed", "cancelled"] ->
        EffectTaskSupervisor.terminate_exact(identity)

      _active_or_missing ->
        {:unknown, :effect_claim_not_ready_for_termination_proof}
    end
  end

  def terminate_physical_identity_on_owner(_identity),
    do: {:unknown, :invalid_effect_claim}

  @doc false
  def acknowledge_guardian_completion(identity, capability_secret)
      when is_map(identity) and is_binary(capability_secret) and
             byte_size(capability_secret) == 32 do
    Repo.transaction(
      fn ->
        TaskClaims.set_guardian_persistence_timeouts!()

        result =
          with assignment_id when is_binary(assignment_id) <- Map.get(identity, :assignment_id),
               %TaskAssignment{} = assignment <- TaskClaims.get(assignment_id),
               :ok <- exact_guardian_assignment(assignment, identity, capability_secret) do
            case TaskClaims.guardian_termination_disposition(assignment) do
              {:ok, disposition}
              when disposition in [
                     :completion,
                     :never_activated,
                     :supervisor_down,
                     :external_destroyed
                   ] ->
                {:ok, disposition}

              {:error, :task_termination_proof_missing} ->
                {:error, :coordination_task_completion_not_durable}

              {:error, _reason} = error ->
                error
            end
          else
            nil -> {:error, :coordination_task_assignment_missing}
            {:error, _reason} = error -> error
            _unbound -> {:error, :effect_task_assignment_binding_required}
          end

        case result do
          {:ok, disposition} -> disposition
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @guardian_persistence_timeout_ms
    )
  rescue
    _error -> {:error, :task_termination_persistence_failed}
  catch
    :exit, _reason -> {:error, :task_termination_persistence_failed}
  end

  def acknowledge_guardian_completion(_identity, _secret),
    do: {:error, :local_task_termination_capability_required}

  @doc false
  def persist_guardian_termination(identity, proof_kind, evidence_id, capability_secret)
      when is_map(identity) and proof_kind in ["supervisor_down", "never_activated"] and
             is_binary(evidence_id) and byte_size(evidence_id) in 1..256 and
             is_binary(capability_secret) and byte_size(capability_secret) == 32 do
    Repo.transaction(
      fn ->
        TaskClaims.set_guardian_persistence_timeouts!()
        require_active_effect_pair!()

        case persist_guardian_termination_in_transaction(
               identity,
               proof_kind,
               evidence_id,
               capability_secret
             ) do
          {:ok, disposition} -> disposition
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @guardian_persistence_timeout_ms
    )
  rescue
    _error -> {:error, :task_termination_persistence_failed}
  catch
    :exit, _reason -> {:error, :task_termination_persistence_failed}
  end

  def persist_guardian_termination(_identity, _proof_kind, _evidence_id, _secret),
    do: {:error, :local_task_termination_capability_required}

  defp persist_guardian_termination_in_transaction(
         identity,
         proof_kind,
         evidence_id,
         capability_secret
       ) do
    with assignment_id when is_binary(assignment_id) <- Map.get(identity, :assignment_id) do
      case TaskClaims.get(assignment_id) do
        %TaskAssignment{} = assignment ->
          persist_loaded_guardian_assignment(
            assignment,
            identity,
            proof_kind,
            evidence_id,
            capability_secret
          )

        nil ->
          classify_commit_unknown_reservation(
            identity,
            proof_kind,
            evidence_id,
            capability_secret
          )
      end
    else
      _unbound -> {:error, :effect_task_assignment_binding_required}
    end
  end

  defp classify_commit_unknown_reservation(
         identity,
         proof_kind,
         evidence_id,
         capability_secret
       ) do
    # The outer Guardian transaction has already validated and locked the exact
    # protocol pair. Locking the Effect row now serializes with the possibly
    # still-finishing claim
    # transaction. Only after that lock may assignment absence prove rollback.
    effect =
      Repo.one(
        from effect in Effect,
          where: effect.id == ^Map.get(identity, :effect_id),
          where: effect.agent_id == ^Map.get(identity, :agent_id),
          lock: "FOR UPDATE"
      )

    assignment = TaskClaims.get(Map.fetch!(identity, :assignment_id))

    case {effect, assignment} do
      {%Effect{} = locked_effect, nil} ->
        if definitively_uncommitted_effect?(locked_effect, identity),
          do: {:ok, :uncommitted},
          else: {:error, :effect_claim_commit_outcome_mismatched}

      {%Effect{}, %TaskAssignment{} = assignment} ->
        persist_loaded_guardian_assignment(
          assignment,
          identity,
          proof_kind,
          evidence_id,
          capability_secret
        )

      _partial_or_mismatched ->
        {:error, :effect_claim_commit_outcome_mismatched}
    end
  end

  defp definitively_uncommitted_effect?(effect, identity) do
    unclaimed? =
      effect.status == "pending" and is_nil(effect.claim_token) and
        is_nil(effect.claim_supervisor_id) and is_nil(effect.claim_task_id) and
        is_nil(effect.coordination_task_assignment_id)

    clearly_different? =
      is_binary(effect.claim_token) and effect.claim_token != identity.claim_token and
        is_binary(effect.claim_supervisor_id) and
        is_binary(effect.claim_task_id) and effect.claim_task_id != identity.task_id and
        (is_nil(effect.coordination_task_assignment_id) or
           effect.coordination_task_assignment_id != identity.assignment_id)

    unclaimed? or clearly_different?
  end

  defp persist_loaded_guardian_assignment(
         assignment,
         identity,
         proof_kind,
         evidence_id,
         capability_secret
       ) do
    with :ok <- exact_guardian_assignment(assignment, identity, capability_secret) do
      if assignment.state in ["termination_proven", "settled", "outcome_ambiguous"] do
        TaskClaims.guardian_termination_disposition(assignment)
      else
        with :ok <- stage_spontaneous_task_down(identity),
             %Effect{} = effect <- load_guardian_effect(identity) do
          case effect do
            %Effect{status: "cancelling", cancellation_state: "requested"} ->
              persist_owner_local_termination(
                effect,
                proof_kind,
                evidence_id,
                capability_secret
              )

            _not_persistable ->
              {:error, :effect_claim_not_ready_for_termination_proof}
          end
        else
          nil -> {:error, :effect_claim_lost}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  defp exact_guardian_assignment(assignment, identity, capability_secret) do
    exact? =
      assignment.work_kind == "effect" and
        assignment.id == identity.assignment_id and
        assignment.work_id == identity.effect_id and
        assignment.claim_token == identity.claim_token and
        assignment.supervisor_id == identity.supervisor_id and
        assignment.local_task_id == identity.task_id and
        assignment.termination_capability_digest == :crypto.hash(:sha256, capability_secret)

    if exact?, do: :ok, else: {:error, :coordination_task_authority_lost}
  end

  defp stage_spontaneous_task_down(identity) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Guardian Effect staging requires a transaction")

    effect =
      case Repo.one(
             from effect in Effect,
               where: effect.id == ^Map.get(identity, :effect_id),
               where: effect.agent_id == ^Map.get(identity, :agent_id),
               where: effect.claim_token == ^Map.get(identity, :claim_token),
               where: effect.claim_supervisor_id == ^Map.get(identity, :supervisor_id),
               where: effect.claim_task_id == ^Map.get(identity, :task_id),
               where:
                 effect.coordination_task_assignment_id ==
                   ^Map.get(identity, :assignment_id),
               lock: "FOR UPDATE"
           ) do
        %Effect{} = value -> value
        nil -> Repo.rollback(:effect_claim_lost)
      end

    case effect do
      %Effect{status: status} when status in ["claimed", "executing"] ->
        requested_assignment = request_coordination_termination!(effect)
        now = DatabaseClock.now!()

        intent_updates =
          case requested_assignment do
            %TaskAssignment{provider_boundary: "not_entered"} ->
              %{
                last_failure_code: @pre_provider_intent_marker,
                last_failure_attempt: effect.attempts,
                result_envelope:
                  internal_pre_provider_abort_envelope(
                    effect,
                    "effect_task_exited_without_outcome"
                  )
              }

            _entered_or_uncoordinated ->
              %{}
          end

        effect
        |> Ecto.Changeset.change(
          Map.merge(
            %{
              status: "cancelling",
              cancellation_state: "requested",
              cancellation_reason: "effect_task_exited_without_outcome",
              cancellation_requested_at: now,
              cancellation_target_claim_token: effect.claim_token,
              cancellation_last_attempt_at: nil,
              cancellation_last_error: nil,
              cancellation_settled_at: nil,
              retry_after: nil,
              error: "effect_task_exited_without_outcome",
              updated_at: now
            },
            intent_updates
          )
        )
        |> Repo.update!()

        :ok

      %Effect{status: "cancelling", cancellation_state: "requested"} ->
        request_coordination_termination!(effect)
        :ok

      %Effect{status: status} when status in ["completed", "failed", "cancelled"] ->
        :ok

      _invalid ->
        Repo.rollback(:effect_claim_not_ready_for_termination_proof)
    end
  end

  defp load_guardian_effect(identity) do
    Repo.one(
      from effect in Effect,
        where: effect.id == ^Map.get(identity, :effect_id),
        where: effect.agent_id == ^Map.get(identity, :agent_id),
        where: effect.claim_token == ^Map.get(identity, :claim_token),
        where: effect.claim_supervisor_id == ^Map.get(identity, :supervisor_id),
        where: effect.claim_task_id == ^Map.get(identity, :task_id),
        where: effect.coordination_task_assignment_id == ^Map.get(identity, :assignment_id)
    )
  end

  defp persist_owner_local_termination(effect, proof_kind, evidence_id, capability_secret) do
    case coordination_assignment(effect) do
      :uncoordinated ->
        {:ok, :uncoordinated}

      {:ok, assignment} ->
        case record_local_coordination_termination_in_transaction!(
               assignment,
               proof_kind,
               evidence_id,
               capability_secret
             ) do
          %TaskAssignment{state: "termination_proven"} = proven ->
            TaskClaims.guardian_termination_disposition(proven)

          _unexpected ->
            {:error, :coordination_task_termination_proof_lost}
        end

      :mismatched ->
        {:error, :coordination_task_authority_lost}
    end
  end

  defp execute_claims(%CancellationPlan{} = plan) do
    Enum.reduce(plan.claims, {0, 0, []}, fn claim, {settled, duplicates, unresolved} ->
      case route_and_terminate(claim) do
        {:ok, proof} ->
          case settle(plan, claim, proof) do
            {:ok, :settled} -> {settled + 1, duplicates, unresolved}
            {:ok, :duplicate} -> {settled, duplicates + 1, unresolved}
            {:error, reason} -> {settled, duplicates, [{claim.effect_id, reason} | unresolved]}
          end

        :duplicate ->
          {settled, duplicates + 1, unresolved}

        {:unknown, reason} ->
          persist_unknown(plan, claim, reason)
          {settled, duplicates, [{claim.effect_id, reason} | unresolved]}
      end
    end)
  end

  defp cancel_pending!(agent_id, reason, now) do
    query =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.status == "pending",
        where: not is_nil(effect.runtime_owner_generation),
        where: is_nil(effect.claimed_by),
        where: is_nil(effect.claimed_at),
        where: is_nil(effect.claim_token),
        where: is_nil(effect.claim_owner_node),
        where: is_nil(effect.claim_heartbeat_at),
        where: is_nil(effect.claim_expires_at),
        where: is_nil(effect.claim_supervisor_id),
        where: is_nil(effect.claim_task_id)
      )

    {count, _rows} =
      Repo.update_all(query,
        set: [
          status: "cancelled",
          cancellation_state: "settled",
          cancellation_reason: reason,
          cancellation_requested_at: now,
          cancellation_target_claim_token: nil,
          cancellation_last_attempt_at: nil,
          cancellation_last_error: nil,
          cancellation_settled_at: now,
          claimed_by: nil,
          claimed_at: nil,
          retry_after: nil,
          result: nil,
          result_envelope: nil,
          error: reason,
          updated_at: now
        ]
      )

    count
  end

  defp request_active_cancellation!(agent_id, reason, now) do
    effects =
      Repo.all(
        from effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status in ["claimed", "executing"],
          where: not is_nil(effect.runtime_owner_generation),
          where: not is_nil(effect.claim_token),
          where: not is_nil(effect.claim_owner_node),
          where: not is_nil(effect.claim_heartbeat_at),
          where: not is_nil(effect.claim_expires_at),
          where: not is_nil(effect.claim_supervisor_id),
          where: not is_nil(effect.claim_task_id),
          where: is_nil(effect.cancellation_state),
          order_by: [asc: effect.id],
          lock: "FOR UPDATE"
      )

    # Lock the complete canonical Effect set before touching any assignment.
    # This gives every multi-row cancellation the same Effect -> assignment
    # order as entry, renewal, terminal settlement, and proof convergence.
    Enum.each(effects, fn effect ->
      request_coordination_termination!(effect)

      effect
      |> Ecto.Changeset.change(%{
        status: "cancelling",
        cancellation_state: "requested",
        cancellation_reason: reason,
        cancellation_requested_at: now,
        cancellation_target_claim_token: effect.claim_token,
        cancellation_last_attempt_at: nil,
        cancellation_last_error: nil,
        cancellation_settled_at: nil,
        retry_after: nil,
        error: reason,
        updated_at: now
      })
      |> Repo.update!()
    end)

    length(effects)
  end

  defp requested_claim_page(agent_id, limit) do
    rows =
      Repo.all(
        from(effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status == "cancelling",
          where: effect.cancellation_state == "requested",
          where: not is_nil(effect.runtime_owner_generation),
          where: not is_nil(effect.claim_token),
          where: not is_nil(effect.claim_owner_node),
          where: not is_nil(effect.claim_supervisor_id),
          where: not is_nil(effect.claim_task_id),
          order_by: [
            asc_nulls_first: effect.cancellation_last_attempt_at,
            asc: effect.cancellation_requested_at,
            asc: effect.id
          ],
          limit: ^(limit + 1)
        )
      )

    {Enum.take(rows, limit) |> Enum.map(&claim_from_effect!/1), length(rows) > limit}
  end

  defp request_exact_claim!(agent_id, reference, reason, now, intent) do
    effect = lock_effect!(agent_id, reference.effect_id)

    cond do
      exact_claim?(effect, reference) and effect.status in ["claimed", "executing"] ->
        requested_assignment = request_coordination_termination!(effect)

        intent_updates =
          case {intent, requested_assignment} do
            {:internal_pre_provider_abort, %TaskAssignment{provider_boundary: "not_entered"}} ->
              %{
                last_failure_code: @pre_provider_intent_marker,
                last_failure_attempt: effect.attempts,
                result_envelope: internal_pre_provider_abort_envelope(effect, reason)
              }

            _ordinary_or_entered ->
              %{}
          end

        effect
        |> Ecto.Changeset.change(
          Map.merge(
            %{
              status: "cancelling",
              cancellation_state: "requested",
              cancellation_reason: reason,
              cancellation_requested_at: now,
              cancellation_target_claim_token: effect.claim_token,
              cancellation_last_attempt_at: nil,
              cancellation_last_error: nil,
              cancellation_settled_at: nil,
              retry_after: nil,
              error: reason,
              updated_at: now
            },
            intent_updates
          )
        )
        |> Repo.update!()
        |> claim_from_effect!()

      exact_claim?(effect, reference) and effect.status == "cancelling" and
          effect.cancellation_state == "requested" ->
        request_coordination_termination!(effect)
        claim_from_effect!(effect)

      true ->
        nil
    end
  end

  defp prepare_expired_claim(agent_id, effect_id, claim_token) do
    Repo.transaction(fn ->
      require_active_effect_pair!()
      effect = lock_effect!(agent_id, effect_id)
      agent = lock_agent!(agent_id)
      _binding = lock_optional_same_user_binding!(agent)
      lock_runtime_rows!(agent_id)
      now = DatabaseClock.now!()

      cond do
        effect.status in ["claimed", "executing"] and effect.claim_token == claim_token and
          not is_nil(effect.claim_expires_at) and
            DateTime.compare(effect.claim_expires_at, now) != :gt ->
          claim =
            request_exact_claim!(
              agent_id,
              %{effect_id: effect_id, claim_token: claim_token},
              "claim_liveness_expired",
              now,
              :internal_pre_provider_abort
            )

          %CancellationPlan{
            agent_id: agent.id,
            user_id: agent.user_id,
            reason: "claim_liveness_expired",
            claims: if(claim, do: [claim], else: []),
            pending_cancelled: 0,
            requested: if(claim, do: 1, else: 0),
            more?: false
          }

        effect.status == "cancelling" and effect.cancellation_state == "requested" and
            effect.cancellation_target_claim_token == claim_token ->
          %CancellationPlan{
            agent_id: agent.id,
            user_id: agent.user_id,
            reason: effect.cancellation_reason,
            claims: [claim_from_effect!(effect)],
            pending_cancelled: 0,
            requested: 0,
            more?: false
          }

        true ->
          Repo.rollback(:effect_claim_not_expired)
      end
    end)
  end

  defp load_agent_plan(agent_id, limit) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id)) do
      %Agent{user_id: user_id} when is_binary(user_id) ->
        {claims, more?} = requested_claim_page(agent_id, limit)

        {:ok,
         %CancellationPlan{
           agent_id: agent_id,
           user_id: user_id,
           reason: "reconcile",
           claims: claims,
           pending_cancelled: 0,
           requested: 0,
           more?: more?
         }}

      _missing ->
        {:error, :agent_not_found}
    end
  end

  defp load_committed_plan(agent_id, effect_id, claim_token) do
    case Repo.one(
           from(effect in Effect,
             join: agent in Agent,
             on: agent.id == effect.agent_id,
             where: effect.agent_id == ^agent_id,
             where: effect.id == ^effect_id,
             where: effect.status == "cancelling",
             where: effect.cancellation_state == "requested",
             where: not is_nil(effect.runtime_owner_generation),
             where: not is_nil(effect.claim_owner_node),
             where: not is_nil(effect.claim_supervisor_id),
             where: not is_nil(effect.claim_task_id),
             where: effect.claim_token == ^claim_token,
             where: effect.cancellation_target_claim_token == ^claim_token,
             select: {effect, agent.user_id}
           )
         ) do
      {%Effect{} = effect, user_id} when is_binary(user_id) ->
        {:ok,
         %CancellationPlan{
           agent_id: agent_id,
           user_id: user_id,
           reason: effect.cancellation_reason,
           claims: [claim_from_effect!(effect)],
           pending_cancelled: 0,
           requested: 0,
           more?: false
         }}

      nil ->
        {:error, :effect_cancellation_claim_lost}
    end
  end

  defp route_and_terminate(claim) do
    case load_persisted_claim(claim) do
      {:ok, persisted} ->
        if TerminationAttestations.proof?(persisted) do
          {:ok, :operator_attestation}
        else
          with {:ok, owner_node} <- runtime_node(persisted.owner_node) do
            if owner_node == node() do
              terminate_exact_on_owner(persisted)
            else
              case :rpc.call(
                     owner_node,
                     __MODULE__,
                     :terminate_exact_on_owner,
                     [persisted],
                     @rpc_timeout_ms
                   ) do
                {:ok, proof} -> {:ok, proof}
                {:unknown, reason} -> {:unknown, reason}
                _failure -> {:unknown, :effect_claim_owner_unreachable}
              end
            end
          else
            {:error, reason} -> {:unknown, reason}
          end
        end

      {:duplicate, _persisted} ->
        :duplicate

      {:error, reason} ->
        {:unknown, reason}
    end
  catch
    _kind, _reason -> {:unknown, :effect_claim_owner_unreachable}
  end

  defp load_persisted_claim(claim) do
    query =
      from(effect in Effect,
        where: effect.id == ^claim.effect_id,
        where: effect.agent_id == ^claim.agent_id,
        where: effect.runtime_owner_generation == ^claim.runtime_owner_generation,
        where: effect.claim_token == ^claim.claim_token,
        where: effect.cancellation_target_claim_token == ^claim.claim_token,
        where: effect.claim_owner_node == ^claim.owner_node,
        where: effect.claim_supervisor_id == ^claim.supervisor_id,
        where: effect.claim_task_id == ^claim.task_id,
        where:
          (effect.status == "cancelling" and effect.cancellation_state == "requested") or
            (effect.status in ["failed", "cancelled"] and
               effect.cancellation_state == "settled")
      )

    case Repo.one(query) do
      %Effect{status: "cancelling", cancellation_state: "requested"} = effect ->
        {:ok, claim_from_effect!(effect)}

      %Effect{status: status, cancellation_state: "settled"} = effect
      when status in ["failed", "cancelled"] ->
        {:duplicate, claim_from_effect!(effect)}

      nil ->
        {:error, :effect_cancellation_claim_lost}
    end
  end

  defp settle(%CancellationPlan{} = plan, claim, proof)
       when proof in [:termination_proven, :operator_attestation] do
    Repo.transaction(fn ->
      require_active_effect_pair!()
      effect = lock_effect!(claim.agent_id, claim.effect_id)
      agent = lock_agent!(claim.agent_id)
      lock_plan_authority!(plan, agent)

      cond do
        effect.status in ["failed", "cancelled"] and
          effect.cancellation_state == "settled" and
          effect.cancellation_target_claim_token == claim.claim_token and
            effect.claim_token == claim.claim_token ->
          :duplicate

        exact_cancelling_claim?(effect, claim) ->
          now = DatabaseClock.now!()

          case settle_coordination_termination!(effect, proof) do
            %TaskAssignment{
              state: "settled",
              provider_boundary: "not_entered",
              outcome: "cancelled_before_provider"
            } ->
              settle_pre_provider_cancellation!(effect, now)

            %TaskAssignment{
              state: "outcome_ambiguous",
              provider_boundary: boundary,
              outcome: "provider_outcome_ambiguous"
            }
            when boundary in ["entered", "outcome_unknown"] ->
              settle_ambiguous_cancellation!(effect, now)

            :uncoordinated ->
              settle_ambiguous_cancellation!(effect, now)

            _mismatched ->
              Repo.rollback(:coordination_task_settlement_lost)
          end

          :settled

        true ->
          Repo.rollback(:effect_cancellation_claim_lost)
      end
    end)
  end

  defp settle(_plan, _claim, _proof), do: {:error, :effect_task_termination_unproven}

  defp settle_pre_provider_cancellation!(%Effect{} = effect, now) do
    case pre_provider_outcome_intent(effect) do
      {:failure, error_code, result_envelope, provenance} ->
        settle_pre_provider_failure!(effect, error_code, result_envelope, provenance, now)

      {:retry, error_code, provenance} ->
        settle_pre_provider_retry!(effect, error_code, provenance, now)

      :ordinary ->
        settle_ordinary_pre_provider_cancellation!(effect, now)
    end
  end

  defp settle_ordinary_pre_provider_cancellation!(%Effect{} = effect, now) do
    case internal_pre_provider_abort_provenance(effect) do
      {:ok, {failure_code, failure_attempt}} ->
        effect
        |> Ecto.Changeset.change(%{
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
          retry_after: now,
          result: nil,
          result_envelope: nil,
          error: nil,
          last_failure_code: failure_code,
          last_failure_attempt: failure_attempt,
          updated_at: now
        })
        |> Repo.update!()

      :error ->
        effect
        |> Ecto.Changeset.change(%{
          status: "cancelled",
          cancellation_state: "settled",
          cancellation_last_attempt_at: now,
          cancellation_last_error: nil,
          cancellation_settled_at: now,
          result: nil,
          result_envelope: nil,
          error: effect.cancellation_reason,
          completion_claimed_by: effect.claim_owner_node,
          completion_claimed_at: effect.claimed_at,
          claimed_by: nil,
          claimed_at: nil,
          retry_after: nil,
          last_failure_code:
            if(effect.last_failure_code == @pre_provider_intent_marker,
              do: nil,
              else: effect.last_failure_code
            ),
          last_failure_attempt:
            if(effect.last_failure_code == @pre_provider_intent_marker,
              do: nil,
              else: effect.last_failure_attempt
            ),
          updated_at: now
        })
        |> Repo.update!()
    end
  end

  defp settle_pre_provider_failure!(
         %Effect{} = effect,
         error_code,
         result_envelope,
         {failure_code, failure_attempt},
         now
       ) do
    effect
    |> Ecto.Changeset.change(%{
      status: "failed",
      cancellation_state: "settled",
      cancellation_last_attempt_at: now,
      cancellation_last_error: nil,
      cancellation_settled_at: now,
      result: nil,
      error: error_code,
      result_envelope: result_envelope,
      last_failure_code: failure_code,
      last_failure_attempt: failure_attempt,
      result_dispatched_at: nil,
      result_dispatch_after: nil,
      result_dispatch_attempts: 0,
      result_acknowledged_at: nil,
      completion_claimed_by: effect.claim_owner_node,
      completion_claimed_at: effect.claimed_at,
      claimed_by: nil,
      claimed_at: nil,
      retry_after: nil,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp settle_pre_provider_retry!(
         %Effect{} = effect,
         error_code,
         {failure_code, failure_attempt},
         now
       ) do
    retry_after =
      case effect.retry_after do
        %DateTime{} = value -> value
        _missing -> now
      end

    effect
    |> Ecto.Changeset.change(%{
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
      retry_after: retry_after,
      result: nil,
      result_envelope: nil,
      error: error_code,
      last_failure_code: failure_code,
      last_failure_attempt: failure_attempt,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp pre_provider_outcome_intent(
         %Effect{
           cancellation_reason: reason,
           error: error_code,
           last_failure_code: @pre_provider_intent_marker,
           last_failure_attempt: attempt,
           attempts: attempt
         } = effect
       )
       when is_binary(reason) and is_binary(error_code) and is_integer(attempt) and attempt >= 0 do
    with true <- bounded_pre_provider_error_code?(error_code) do
      cond do
        String.starts_with?(reason, @pre_provider_failure_prefix) ->
          with true <-
                 valid_pre_provider_reason?(reason, @pre_provider_failure_prefix, error_code),
               {:ok, result_envelope, provenance} <-
                 exact_pre_provider_error_envelope(effect, attempt) do
            {:failure, error_code, result_envelope, provenance}
          else
            _invalid -> :ordinary
          end

        String.starts_with?(reason, @pre_provider_retry_prefix) ->
          with true <- valid_pre_provider_reason?(reason, @pre_provider_retry_prefix, error_code),
               {:ok, provenance} <- exact_pre_provider_retry_envelope(effect, error_code, attempt) do
            {:retry, error_code, provenance}
          else
            _invalid -> :ordinary
          end

        true ->
          :ordinary
      end
    else
      false -> :ordinary
    end
  end

  defp pre_provider_outcome_intent(%Effect{}), do: :ordinary

  defp valid_pre_provider_reason?(reason, prefix, error_code) do
    reason == prefix <> error_code and bounded_pre_provider_error_code?(error_code)
  end

  defp bounded_pre_provider_error_code?(code)
       when is_binary(code) and byte_size(code) in 1..128,
       do: Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, code)

  defp bounded_pre_provider_error_code?(_code), do: false

  defp exact_pre_provider_error_envelope(
         %Effect{
           result_envelope:
             %{
               "attempt" => intent_attempt,
               "intent" => "pre_provider_failure",
               "provenance" => encoded_provenance,
               "terminal_envelope" => terminal_envelope,
               "version" => @pre_provider_intent_envelope_version
             } = intent_envelope
         } = effect,
         expected_attempt
       )
       when map_size(intent_envelope) == 5 and is_map(terminal_envelope) and
              intent_attempt == expected_attempt do
    terminal_effect = %{effect | result_envelope: terminal_envelope}

    with {:error, reason} <- TerminalEnvelope.decode(terminal_effect),
         true <- TerminalEnvelope.error(reason) == terminal_envelope,
         {:ok, provenance} <-
           decode_pre_provider_provenance(encoded_provenance, expected_attempt) do
      {:ok, terminal_envelope, provenance}
    else
      _invalid -> {:error, :invalid_pre_provider_error_envelope}
    end
  end

  defp exact_pre_provider_error_envelope(%Effect{}, _expected_attempt),
    do: {:error, :invalid_pre_provider_error_envelope}

  defp exact_pre_provider_retry_envelope(
         %Effect{
           result_envelope:
             %{
               "attempt" => intent_attempt,
               "error_code" => intent_error_code,
               "intent" => "pre_provider_retry",
               "provenance" => encoded_provenance,
               "version" => @pre_provider_intent_envelope_version
             } = intent_envelope
         },
         expected_error_code,
         expected_attempt
       )
       when map_size(intent_envelope) == 5 and intent_attempt == expected_attempt and
              intent_error_code == expected_error_code do
    decode_pre_provider_provenance(encoded_provenance, expected_attempt)
  end

  defp exact_pre_provider_retry_envelope(%Effect{}, _error_code, _attempt),
    do: {:error, :invalid_pre_provider_retry_envelope}

  defp decode_pre_provider_provenance(%{"attempt" => nil, "code" => nil} = encoded, _attempt)
       when map_size(encoded) == 2,
       do: {:ok, {nil, nil}}

  defp decode_pre_provider_provenance(
         %{"attempt" => failure_attempt, "code" => failure_code} = encoded,
         intent_attempt
       )
       when map_size(encoded) == 2 and is_integer(failure_attempt) and failure_attempt >= 0 and
              failure_attempt <= intent_attempt and is_binary(failure_code) do
    if bounded_pre_provider_error_code?(failure_code),
      do: {:ok, {failure_code, failure_attempt}},
      else: {:error, :invalid_pre_provider_failure_provenance}
  end

  defp decode_pre_provider_provenance(_encoded, _attempt),
    do: {:error, :invalid_pre_provider_failure_provenance}

  defp settle_ambiguous_cancellation!(%Effect{} = effect, now) do
    effect
    |> Ecto.Changeset.change(%{
      status: "failed",
      cancellation_state: "settled",
      cancellation_last_attempt_at: now,
      cancellation_last_error: nil,
      cancellation_settled_at: now,
      result: nil,
      error: "effect_outcome_ambiguous",
      result_envelope: TerminalEnvelope.error(@ambiguous_outcome),
      last_failure_code: nil,
      last_failure_attempt: nil,
      result_dispatched_at: nil,
      result_dispatch_after: nil,
      result_dispatch_attempts: 0,
      result_acknowledged_at: nil,
      completion_claimed_by: effect.claim_owner_node,
      completion_claimed_at: effect.claimed_at,
      claimed_by: nil,
      claimed_at: nil,
      retry_after: nil,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp internal_pre_provider_abort_provenance(%Effect{
         cancellation_reason: reason,
         last_failure_code: @pre_provider_intent_marker,
         last_failure_attempt: attempt,
         attempts: attempt,
         result_envelope:
           %{
             "attempt" => intent_attempt,
             "intent" => "internal_pre_provider_abort",
             "provenance" => encoded_provenance,
             "reason" => intent_reason,
             "version" => @pre_provider_intent_envelope_version
           } = intent_envelope
       })
       when reason in @internal_pre_provider_abort_reasons and is_integer(attempt) and
              attempt >= 0 and map_size(intent_envelope) == 5 and intent_attempt == attempt and
              intent_reason == reason do
    decode_pre_provider_provenance(encoded_provenance, attempt)
  end

  defp internal_pre_provider_abort_provenance(%Effect{}), do: :error

  defp request_coordination_termination!(%Effect{} = effect) do
    case coordination_assignment(effect) do
      :uncoordinated ->
        :ok

      {:ok, expected} ->
        case TaskClaims.request_effect_termination_in_transaction!(expected) do
          %TaskAssignment{state: state} = requested
          when state in [
                 "reserved",
                 "termination_requested",
                 "termination_proven",
                 "settled",
                 "outcome_ambiguous"
               ] ->
            unless exact_coordination_assignment?(requested, expected),
              do: Repo.rollback(:coordination_task_authority_lost)

            requested

          _mismatched ->
            Repo.rollback(:coordination_task_authority_lost)
        end

      :mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp settle_coordination_termination!(%Effect{} = effect, _proof) do
    case coordination_assignment(effect) do
      :uncoordinated ->
        :uncoordinated

      {:ok, expected} ->
        assignment = exact_coordination_assignment!(expected)

        proven_or_terminal =
          case assignment.state do
            state when state in ["reserved", "running", "termination_requested"] ->
              Repo.rollback(:coordination_task_termination_proof_lost)

            "termination_proven" ->
              assignment

            state when state in ["settled", "outcome_ambiguous"] ->
              assignment

            _invalid_state ->
              Repo.rollback(:coordination_task_authority_lost)
          end

        final =
          case proven_or_terminal.state do
            "termination_proven" ->
              TaskClaims.reconcile_effect_proven_in_transaction(
                proven_or_terminal,
                effect.agent_id,
                effect.runtime_owner_generation
              )

            _already_terminal ->
              proven_or_terminal
          end

        case final do
          %TaskAssignment{
            id: id,
            state: "settled",
            provider_boundary: "not_entered",
            outcome: "cancelled_before_provider"
          }
          when id == expected.id ->
            final

          %TaskAssignment{
            id: id,
            state: "outcome_ambiguous",
            provider_boundary: boundary,
            outcome: "provider_outcome_ambiguous"
          }
          when id == expected.id and boundary in ["entered", "outcome_unknown"] ->
            final

          _mismatched_terminal_proof ->
            Repo.rollback(:coordination_task_settlement_lost)
        end

      :mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
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

  defp exact_coordination_assignment!(expected) do
    actual = TaskClaims.lock_effect_assignment_in_transaction!(expected)

    if exact_coordination_assignment?(actual, expected),
      do: actual,
      else: Repo.rollback(:coordination_task_authority_lost)
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

  defp persist_unknown(%CancellationPlan{} = plan, claim, reason) do
    Repo.transaction(fn ->
      require_active_effect_pair!()
      _effect = lock_effect!(claim.agent_id, claim.effect_id)
      agent = lock_agent!(claim.agent_id)
      lock_plan_authority!(plan, agent)
      now = DatabaseClock.now!()
      error = cancellation_error(reason)

      query =
        from(effect in Effect,
          where: effect.id == ^claim.effect_id,
          where: effect.agent_id == ^claim.agent_id,
          where: effect.status == "cancelling",
          where: effect.runtime_owner_generation == ^claim.runtime_owner_generation,
          where: effect.cancellation_state == "requested",
          where: effect.claim_token == ^claim.claim_token,
          where: effect.cancellation_target_claim_token == ^claim.claim_token,
          where: effect.claim_owner_node == ^claim.owner_node,
          where: effect.claim_supervisor_id == ^claim.supervisor_id,
          where: effect.claim_task_id == ^claim.task_id
        )

      Repo.update_all(query,
        set: [
          cancellation_last_attempt_at: now,
          cancellation_last_error: error,
          updated_at: now
        ]
      )
    end)

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp exact_cancelling_claim?(effect, claim) do
    effect.status == "cancelling" and
      effect.cancellation_state == "requested" and
      effect.claim_token == claim.claim_token and
      effect.cancellation_target_claim_token == claim.claim_token and
      effect.claim_owner_node == claim.owner_node and
      effect.claim_supervisor_id == claim.supervisor_id and
      effect.claim_task_id == claim.task_id and
      effect.runtime_owner_generation == claim.runtime_owner_generation
  end

  defp exact_claim?(effect, reference) do
    effect.claim_token == reference.claim_token and not is_nil(effect.claim_token)
  end

  defp expired_claim_candidates(limit) do
    Repo.all(
      from(effect in Effect,
        where: effect.status in ["claimed", "executing"],
        where: not is_nil(effect.runtime_owner_generation),
        where: not is_nil(effect.claim_token),
        where: not is_nil(effect.claim_owner_node),
        where: not is_nil(effect.claim_supervisor_id),
        where: not is_nil(effect.claim_task_id),
        where: effect.claim_expires_at <= fragment("timezone('UTC', clock_timestamp())"),
        order_by: [asc: effect.claim_expires_at, asc: effect.id],
        limit: ^limit,
        select: {effect.agent_id, effect.id, effect.claim_token}
      )
    )
  end

  defp protocol_mismatch_candidates(0), do: []

  defp protocol_mismatch_candidates(limit) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text
        FROM public.effects
        WHERE status IN ('pending', 'claimed', 'executing', 'cancelling')
          AND NOT (
            runtime_owner_generation IS NOT NULL AND
            effect_protocol_version = 2 AND
            payload_encryption_version = 1 AND
            payload_purged_at IS NULL AND params_ciphertext IS NOT NULL AND
            params = '{"redacted": true}'::jsonb AND result IS NULL AND
            (
              (status = 'pending' AND claimed_by IS NULL AND claimed_at IS NULL AND
               claim_token IS NULL AND claim_owner_node IS NULL AND
               claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
               claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status IN ('claimed', 'executing') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status = 'cancelling' AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state = 'requested' AND cancellation_reason IS NOT NULL AND
               cancellation_requested_at IS NOT NULL AND
               cancellation_target_claim_token = claim_token AND
               cancellation_settled_at IS NULL)
            )
          )
        ORDER BY inserted_at, id
        LIMIT $1
        """,
        [limit]
      )

    Enum.map(rows, fn [effect_id] -> effect_id end)
  end

  defp cancellation_candidates(limit) do
    Repo.all(
      from(effect in Effect,
        where: effect.status == "cancelling",
        where: effect.cancellation_state == "requested",
        where: not is_nil(effect.runtime_owner_generation),
        where: not is_nil(effect.claim_token),
        where: not is_nil(effect.claim_owner_node),
        where: not is_nil(effect.claim_supervisor_id),
        where: not is_nil(effect.claim_task_id),
        where: not is_nil(effect.cancellation_target_claim_token),
        order_by: [
          asc_nulls_first: effect.cancellation_last_attempt_at,
          asc: effect.cancellation_requested_at,
          asc: effect.id
        ],
        limit: ^limit,
        select: {effect.agent_id, effect.id, effect.cancellation_target_claim_token}
      )
    )
  end

  # Counts legacy, bare/unknown cancelling, partial exact identity, and any
  # other operational surprise. It is deliberately a COUNT rather than an
  # unbounded load so reconciliation remains paged.
  defp unresolved_protocol_count(agent_id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT COUNT(*)
        FROM public.effects
        WHERE agent_id = $1::uuid
          AND status IN ('pending', 'claimed', 'executing', 'cancelling')
          AND NOT (
            runtime_owner_generation IS NOT NULL AND
            effect_protocol_version = 2 AND
            payload_encryption_version = 1 AND
            payload_purged_at IS NULL AND params_ciphertext IS NOT NULL AND
            params = '{"redacted": true}'::jsonb AND result IS NULL AND
            (
              (status = 'pending' AND claimed_by IS NULL AND claimed_at IS NULL AND
               claim_token IS NULL AND claim_owner_node IS NULL AND
               claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
               claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status IN ('claimed', 'executing') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status = 'cancelling' AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state = 'requested' AND cancellation_reason IS NOT NULL AND
               cancellation_requested_at IS NOT NULL AND
               cancellation_target_claim_token = claim_token AND
               cancellation_settled_at IS NULL)
            )
          )
        """,
        [Ecto.UUID.dump!(agent_id)]
      )

    count
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_same_user_binding!(%Agent{id: agent_id, user_id: user_id}) when is_binary(user_id) do
    case Repo.one(
           from(binding in Binding,
             where: binding.agent_id == ^agent_id,
             where: binding.user_id == ^user_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Binding{} = binding -> binding
      nil -> Repo.rollback(:agent_binding_not_found)
    end
  end

  defp lock_same_user_binding!(%Agent{}), do: Repo.rollback(:agent_owner_missing)

  defp lock_optional_same_user_binding!(%Agent{id: agent_id, user_id: user_id})
       when is_binary(user_id) do
    Repo.one(
      from(binding in Binding,
        where: binding.agent_id == ^agent_id,
        where: binding.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_optional_same_user_binding!(%Agent{}), do: nil

  # Canonical order after Agent -> Binding: Guard -> Lease -> processing
  # Directive -> active Run -> Effect. Process/RPC calls happen only after the
  # transaction using this order has committed.
  defp lock_runtime_rows!(agent_id) do
    _guard =
      Repo.one(
        from(guard in AgentRestartGuard,
          where: guard.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    lease =
      Repo.one(
        from(lease in AgentRuntimeLease,
          where: lease.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    _operation =
      Repo.one(
        from(operation in AgentLifecycleOperation,
          where: operation.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    _directives =
      Repo.all(
        from(directive in AgentDirective,
          where: directive.agent_id == ^agent_id,
          where: directive.status == "processing",
          order_by: [asc: directive.id],
          lock: "FOR UPDATE"
        )
      )

    _runs =
      Repo.all(
        from(run in AgentRun,
          where: run.agent_id == ^agent_id,
          where: run.status == "running",
          order_by: [asc: run.id],
          lock: "FOR UPDATE"
        )
      )

    _steps =
      Repo.all(
        from(step in AgentRunStep,
          where: step.agent_id == ^agent_id,
          where: step.status == "requested",
          order_by: [asc: step.id],
          lock: "FOR UPDATE"
        )
      )

    lease
  end

  defp lock_lifecycle_operation!(agent_id, operation_token) do
    case Repo.one(
           from(operation in AgentLifecycleOperation,
             where: operation.agent_id == ^agent_id,
             where: operation.operation_token == ^operation_token,
             where: operation.state == "draining",
             lock: "FOR UPDATE"
           )
         ) do
      %AgentLifecycleOperation{} = operation -> operation
      nil -> Repo.rollback(:lifecycle_operation_not_found)
    end
  end

  defp ensure_lifecycle_authority!(%Agent{} = agent, operation_token, lease) do
    operation = lock_lifecycle_operation!(agent.id, operation_token)

    guard =
      Repo.one(
        from(guard in AgentRestartGuard,
          where: guard.agent_id == ^agent.id,
          lock: "FOR UPDATE"
        )
      )

    cond do
      agent.status != "stopped" ->
        Repo.rollback(:lifecycle_operation_fence_lost)

      not is_nil(lease) ->
        Repo.rollback(:runtime_lease_requires_reconciliation)

      not is_map(operation.payload) or
          operation.request_digest !=
            AgentLifecycleOperations.digest(Map.get(operation.payload, "request", %{})) ->
        Repo.rollback(:lifecycle_operation_payload_mismatch)

      operation.payload_digest != AgentLifecycleOperations.digest(operation.payload) ->
        Repo.rollback(:lifecycle_operation_payload_mismatch)

      operation.requires_external_drain and is_nil(operation.external_drain_confirmed_at) ->
        Repo.rollback(:external_fleet_drain_required)

      lifecycle_guard_valid?(guard, operation) ->
        operation

      true ->
        Repo.rollback(:restart_guard_requires_reconciliation)
    end
  end

  defp lifecycle_guard_valid?(nil, _operation), do: true

  defp lifecycle_guard_valid?(%AgentRestartGuard{} = guard, operation) do
    not (guard.needs_recovery or guard.tripped) or
      (is_binary(operation.expected_owner_token) and
         guard.last_owner_token == operation.expected_owner_token)
  end

  defp lock_plan_authority!(%CancellationPlan{} = plan, %Agent{} = agent) do
    if plan.agent_id != agent.id, do: Repo.rollback(:effect_cancellation_agent_mismatch)

    case plan.lifecycle_operation_token do
      nil ->
        # Caller ownership was fenced when cancellation intent committed. Once
        # a row is durably `cancelling`, crash reconciliation must not depend on
        # a still-present Binding merely to prove and settle physical death.
        _binding = lock_optional_same_user_binding!(agent)
        lock_runtime_rows!(agent.id)

      operation_token ->
        _binding = lock_optional_same_user_binding!(agent)
        lease = lock_runtime_rows!(agent.id)
        ensure_lifecycle_authority!(agent, operation_token, lease)
    end
  end

  defp authorize_plan_execution(%CancellationPlan{lifecycle_operation_token: nil}), do: :ok

  defp authorize_plan_execution(%CancellationPlan{} = plan) do
    case Repo.transaction(fn ->
           require_active_effect_pair!()
           agent = lock_agent!(plan.agent_id)
           lock_plan_authority!(plan, agent)
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp lock_effects_for_cancellation!(agent_id) do
    Repo.all(
      from effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.status in ["pending", "claimed", "executing", "cancelling"],
        where: not is_nil(effect.runtime_owner_generation),
        order_by: [asc: effect.id],
        lock: "FOR UPDATE"
    )
  end

  defp lock_referenced_effects!(agent_id, references) do
    ids = references |> Enum.map(& &1.effect_id) |> Enum.uniq() |> Enum.sort()

    Repo.all(
      from effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.id in ^ids,
        order_by: [asc: effect.id],
        lock: "FOR UPDATE"
    )
  end

  defp lock_effect!(agent_id, effect_id) do
    case Repo.one(
           from(effect in Effect,
             where: effect.id == ^effect_id,
             where: effect.agent_id == ^agent_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Effect{} = effect -> effect
      nil -> Repo.rollback(:effect_cancellation_claim_lost)
    end
  end

  defp claim_from_effect!(%Effect{} = effect) do
    claim = %{
      effect_id: effect.id,
      agent_id: effect.agent_id,
      claim_token: effect.claim_token,
      runtime_owner_generation: effect.runtime_owner_generation,
      owner_node: effect.claim_owner_node,
      assignment_id: effect.coordination_task_assignment_id,
      supervisor_id: effect.claim_supervisor_id,
      task_id: effect.claim_task_id
    }

    case validate_claim(claim) do
      {:ok, valid} -> valid
      {:error, _reason} -> Repo.rollback(:legacy_effect_claim_requires_drain)
    end
  end

  defp validate_claim(claim) when is_map(claim) do
    with {:ok, effect_id} <- claim |> Map.get(:effect_id) |> cast_uuid(),
         {:ok, agent_id} <- claim |> Map.get(:agent_id) |> cast_uuid(),
         {:ok, claim_token} <- claim |> Map.get(:claim_token) |> cast_uuid(),
         {:ok, runtime_owner_generation} <-
           claim |> Map.get(:runtime_owner_generation) |> cast_uuid(),
         {:ok, supervisor_id} <- claim |> Map.get(:supervisor_id) |> cast_uuid(),
         {:ok, task_id} <- claim |> Map.get(:task_id) |> cast_uuid(),
         {:ok, owner_node} <- owner_node(Map.get(claim, :owner_node)),
         {:ok, assignment_id} <- optional_claim_assignment_id(claim) do
      valid = %{
        effect_id: effect_id,
        agent_id: agent_id,
        claim_token: claim_token,
        runtime_owner_generation: runtime_owner_generation,
        owner_node: owner_node,
        supervisor_id: supervisor_id,
        task_id: task_id
      }

      {:ok,
       if(is_binary(assignment_id),
         do: Map.put(valid, :assignment_id, assignment_id),
         else: valid
       )}
    else
      _invalid -> {:error, :invalid_effect_claim}
    end
  end

  defp validate_claim(_claim), do: {:error, :invalid_effect_claim}

  defp optional_claim_assignment_id(claim) do
    case Map.get(claim, :assignment_id) do
      nil -> {:ok, nil}
      assignment_id -> cast_uuid(assignment_id)
    end
  end

  defp runtime_node(owner_name) do
    runtime_nodes = [node() | Node.list(:connected)] |> Enum.uniq()

    if length(runtime_nodes) > @max_runtime_nodes do
      {:error, :effect_claim_owner_unknown}
    else
      case Enum.find(runtime_nodes, &(Atom.to_string(&1) == owner_name)) do
        nil -> {:error, :effect_claim_owner_unknown}
        owner -> {:ok, owner}
      end
    end
  end

  defp exact_references(effects) do
    effects
    |> Enum.reduce_while({:ok, []}, fn
      %Effect{id: id, claim_token: claim_token}, {:ok, acc} ->
        case exact_reference(id, claim_token) do
          {:ok, reference} -> {:cont, {:ok, [reference | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      %{effect_id: id, claim_token: claim_token}, {:ok, acc} ->
        case exact_reference(id, claim_token) do
          {:ok, reference} -> {:cont, {:ok, [reference | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_effect_cancellation}}
    end)
    |> case do
      {:ok, references} -> {:ok, Enum.reverse(references) |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp exact_reference(effect_id, claim_token) do
    with {:ok, effect_id} <- cast_uuid(effect_id),
         {:ok, claim_token} <- cast_uuid(claim_token) do
      {:ok, %{effect_id: effect_id, claim_token: claim_token}}
    end
  end

  defp prepare_agent_opts(opts) do
    allowed = [:user_id, :limit, :expected_runtime_owner_generation]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      normalize_agent_prepared_opts(opts)
    else
      {:error, :invalid_effect_cancellation}
    end
  end

  defp normalize_agent_prepared_opts(%{
         limit: limit,
         user_id: user_id,
         expected_runtime_owner_generation: expected_runtime_owner_generation
       }) do
    validate_agent_prepared_opts(limit, user_id, expected_runtime_owner_generation)
  end

  defp normalize_agent_prepared_opts(opts) when is_list(opts) do
    validate_agent_prepared_opts(
      Keyword.get(opts, :limit, @default_plan_limit),
      Keyword.get(opts, :user_id),
      Keyword.get(opts, :expected_runtime_owner_generation)
    )
  end

  defp normalize_agent_prepared_opts(_opts), do: {:error, :invalid_effect_cancellation}

  defp validate_agent_prepared_opts(limit, user_id, expected_runtime_owner_generation) do
    with {:ok, limit} <- plan_limit(limit),
         {:ok, user_id} <- optional_user_id(user_id),
         {:ok, expected_runtime_owner_generation} <-
           cast_uuid(expected_runtime_owner_generation) do
      {:ok,
       %{
         limit: limit,
         user_id: user_id,
         expected_runtime_owner_generation: expected_runtime_owner_generation
       }}
    else
      _invalid -> {:error, :effect_cancellation_owner_generation_required}
    end
  end

  defp prepare_opts(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in [:user_id, :limit])) do
      normalize_prepared_opts(opts)
    else
      {:error, :invalid_effect_cancellation}
    end
  end

  defp normalize_prepared_opts(%{limit: limit, user_id: user_id}) do
    validate_prepared_opts(limit, user_id)
  end

  defp normalize_prepared_opts(opts) when is_list(opts) do
    validate_prepared_opts(
      Keyword.get(opts, :limit, @default_plan_limit),
      Keyword.get(opts, :user_id)
    )
  end

  defp normalize_prepared_opts(_opts), do: {:error, :invalid_effect_cancellation}

  defp validate_prepared_opts(limit, user_id) do
    with {:ok, limit} <- plan_limit(limit),
         {:ok, user_id} <- optional_user_id(user_id) do
      {:ok, %{limit: limit, user_id: user_id}}
    else
      _invalid -> {:error, :invalid_effect_cancellation}
    end
  end

  defp plan_limit(value) when is_integer(value) and value in 1..@max_plan_limit,
    do: {:ok, value}

  defp plan_limit(_value), do: {:error, :invalid_effect_cancellation}

  defp ensure_expected_user!(_binding, nil), do: :ok
  defp ensure_expected_user!(%Binding{user_id: user_id}, user_id), do: :ok
  defp ensure_expected_user!(_binding, _expected), do: Repo.rollback(:agent_owner_mismatch)

  defp ensure_expected_runtime_owner!(
         %AgentRuntimeLease{owner_token: owner_token, lease_until: lease_until},
         owner_token
       )
       when is_binary(owner_token) and not is_nil(lease_until) do
    if DateTime.compare(lease_until, DatabaseClock.now!()) == :gt do
      :ok
    else
      Repo.rollback(:effect_cancellation_owner_generation_lost)
    end
  end

  defp ensure_expected_runtime_owner!(_lease, _owner_token),
    do: Repo.rollback(:effect_cancellation_owner_generation_lost)

  defp cancellation_reason(value) when is_binary(value) and byte_size(value) in 1..255 do
    internal_intent? =
      value in @internal_pre_provider_abort_reasons or
        String.starts_with?(value, @pre_provider_failure_prefix) or
        String.starts_with?(value, @pre_provider_retry_prefix)

    if String.valid?(value) and not internal_intent? and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
       do: {:ok, value},
       else: {:error, :invalid_effect_cancellation}
  end

  defp cancellation_reason(_value), do: {:error, :invalid_effect_cancellation}

  defp internal_pre_provider_abort_envelope(%Effect{} = effect, reason)
       when reason in @internal_pre_provider_abort_reasons do
    %{
      "attempt" => effect.attempts,
      "intent" => "internal_pre_provider_abort",
      "provenance" =>
        encode_pre_provider_provenance(
          effect.last_failure_code,
          effect.last_failure_attempt
        ),
      "reason" => reason,
      "version" => @pre_provider_intent_envelope_version
    }
  end

  defp encode_pre_provider_provenance(nil, nil),
    do: %{"attempt" => nil, "code" => nil}

  defp encode_pre_provider_provenance(code, attempt)
       when is_binary(code) and byte_size(code) in 1..128 and is_integer(attempt) and
              attempt >= 0 do
    if bounded_pre_provider_error_code?(code) do
      %{"attempt" => attempt, "code" => code}
    else
      raise ArgumentError, "invalid pre-provider failure provenance"
    end
  end

  defp encode_pre_provider_provenance(_code, _attempt),
    do: raise(ArgumentError, "invalid pre-provider failure provenance")

  defp bounded_pre_provider_error_code(reason) do
    summarized =
      if is_binary(reason),
        do: reason,
        else: Maraithon.Redaction.error_summary(reason)

    code =
      summarized
      |> String.replace(~r/[^A-Za-z0-9_.:-]+/u, "_")
      |> String.trim("_")

    code = if code == "", do: "unknown_error", else: code
    binary_part(code, 0, min(byte_size(code), 128))
  end

  defp cancellation_error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> bound_error_code()

  defp cancellation_error(reason) when is_binary(reason) do
    reason |> Maraithon.Redaction.error_summary() |> bound_error_code()
  end

  defp cancellation_error(_reason), do: "effect_task_termination_unproven"

  defp bound_error_code(value) when is_binary(value) and byte_size(value) <= 255 do
    if String.valid?(value), do: value, else: "effect_task_termination_unproven"
  end

  defp bound_error_code(value) when is_binary(value) do
    value
    |> binary_part(0, 255)
    |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(value) do
    if String.valid?(value) do
      value
    else
      trim_incomplete_utf8(binary_part(value, 0, byte_size(value) - 1))
    end
  end

  defp owner_node(value) when is_binary(value) and byte_size(value) in 1..255 do
    if String.valid?(value) and not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_effect_claim}
  end

  defp owner_node(_value), do: {:error, :invalid_effect_claim}

  defp optional_user_id(nil), do: {:ok, nil}

  defp optional_user_id(value) when is_binary(value) and byte_size(value) in 1..320 do
    if String.valid?(value) and not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_user_id}
  end

  defp optional_user_id(_value), do: {:error, :invalid_user_id}

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_cancellation}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_effect_cancellation}

  defp require_enabled do
    case ProtocolCutover.mode() do
      :exact -> :ok
      {:blocked, reason} -> {:error, {:effect_protocol_mismatch, reason}}
      _legacy -> {:error, :durable_effect_cancellation_disabled}
    end
  end

  defp require_active_effect_pair! do
    case Protocol.lock_effect_pair!() do
      {:active, _epoch} -> :ok
      other -> Repo.rollback({:runtime_effect_protocol_pair_mismatch, other})
    end
  end

  defp require_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "effect cancellation preparation requires a Repo transaction"
    end

    :ok
  end
end
