defmodule Maraithon.Runtime.AgentRestartGuards do
  @moduledoc """
  Durable, exact-owner restart backoff and crash-loop fencing.

  The guard is written before the matching lease is removed in one transaction.
  Its lock prefix includes LifecycleOperation after Lease and before Directive.
  A replacement token or a duplicate delayed `:DOWN` can therefore never be
  counted against the current incarnation.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminationIncident
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.WakeCoordinator
  alias Maraithon.Runtime.Coordination.{Protocol, Scope}

  @default_window_ms 600_000
  @default_max_crashes 3
  @default_backoffs_ms [5_000, 15_000, 30_000]
  @max_window_ms 86_400_000
  @max_backoff_ms 3_600_000
  @max_crashes 100

  @doc "Unproven crash reports are never physical termination evidence."
  def record_crash(agent_id, owner_token, _reason, opts \\ [])

  def record_crash(agent_id, owner_token, _reason, opts) when is_list(opts) do
    with {:ok, _agent_id} <- cast_uuid(agent_id),
         {:ok, _owner_token} <- cast_uuid(owner_token),
         {:ok, _policy} <- policy(opts) do
      {:ignored, :termination_proof_required}
    end
  end

  def record_crash(_agent_id, _owner_token, _reason, _opts),
    do: {:error, :invalid_restart_guard}

  @doc """
  Requests reconciliation for an expired generation.

  Expiry is only an authority fence.  This function deliberately does not
  create a restart guard, recover work, delete the lease, or admit a successor.
  """
  def record_expired(agent_id, owner_token, opts \\ [])

  def record_expired(agent_id, owner_token, opts) when is_list(opts) do
    Maraithon.Runtime.AgentTerminations.request_expired(agent_id, owner_token, opts)
  end

  def record_expired(_agent_id, _owner_token, _opts),
    do: {:error, :invalid_restart_guard}

  @doc false
  def record_termination(incident_id, opts \\ [])

  def record_termination(incident_id, opts) when is_binary(incident_id) and is_list(opts) do
    with {:ok, incident_id} <- cast_uuid(incident_id),
         %AgentTerminationIncident{} = candidate <-
           Repo.get(AgentTerminationIncident, incident_id),
         {:ok, policy} <- termination_policy(candidate, opts) do
      Repo.transaction(fn ->
        protocol_pair = Protocol.locked_pair!()

        agent = lock_agent!(candidate.agent_id)
        _binding = lock_binding(agent)
        guard = lock_guard(candidate.agent_id)
        lease = lock_lease(candidate.agent_id)
        operation = lock_operation(candidate.agent_id)
        incident = lock_termination_incident!(incident_id)
        proof = lock_termination_proof!(incident)
        now = DatabaseClock.now!()

        validate_termination_identity!(candidate, incident, proof)

        owner = matching_proven_owner(lease, guard, incident)

        expected_termination? =
          AgentLifecycleOperations.expected_termination?(
            operation,
            incident.agent_id,
            incident.lease_token
          ) or draining_owner?(owner)

        if expected_termination? do
          reconcile_expected_lifecycle_termination!(owner, incident, proof, now)
        else
          reconcile_unexpected_termination!(
            owner,
            agent,
            guard,
            incident,
            proof,
            now,
            policy,
            protocol_pair
          )
        end
      end)
      |> unwrap_transaction()
      |> maybe_converge_expected_lifecycle()
    else
      nil -> {:error, :termination_incident_not_found}
      {:error, _reason} = error -> error
    end
  end

  def record_termination(_incident_id, _opts), do: {:error, :invalid_restart_guard}

  @doc "Settles pending exact work left behind by tripped crash-loop guards."
  def reconcile_tripped_pending(limit \\ 100)

  def reconcile_tripped_pending(limit) when is_integer(limit) and limit in 1..500 do
    case ProtocolCutover.mode() do
      :legacy ->
        {:ok, 0}

      :exact ->
        from(guard in AgentRestartGuard,
          join: agent in Agent,
          as: :agent,
          on: agent.id == guard.agent_id,
          join: effect in Effect,
          on:
            effect.agent_id == guard.agent_id and effect.status == "pending" and
              not is_nil(effect.runtime_owner_generation) and is_nil(effect.claimed_by) and
              is_nil(effect.claimed_at) and is_nil(effect.claim_token) and
              is_nil(effect.claim_owner_node) and is_nil(effect.claim_heartbeat_at) and
              is_nil(effect.claim_expires_at) and is_nil(effect.claim_supervisor_id) and
              is_nil(effect.claim_task_id),
          where: guard.tripped and guard.needs_recovery,
          where: not is_nil(guard.last_owner_token),
          group_by: [guard.agent_id, guard.generation],
          order_by: [asc: min(effect.inserted_at), asc: guard.agent_id],
          limit: ^limit,
          select: {guard.agent_id, guard.generation}
        )
        |> Scope.all_ready_agent()
        |> Enum.reduce_while({:ok, 0}, fn {agent_id, generation}, {:ok, total} ->
          case reconcile_tripped_generation(agent_id, generation) do
            {:ok, count} -> {:cont, {:ok, total + count}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:blocked, reason} ->
        {:error, {:effect_protocol_mismatch, reason}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  def reconcile_tripped_pending(_limit), do: {:error, :invalid_restart_guard_limit}

  def reset_for_operator(agent_id) do
    with {:ok, agent_id} <- cast_uuid(agent_id) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        termination_incident = lock_open_termination_incident(agent_id)
        now = DatabaseClock.now!()

        if operation, do: Repo.rollback(:agent_drain_pending)
        if lease, do: Repo.rollback(:runtime_lease_owned)
        if termination_incident, do: Repo.rollback(:agent_termination_unproven)
        ensure_no_processing_directive!(agent_id)

        put_guard!(
          guard,
          %{
            agent_id: agent_id,
            generation: Ecto.UUID.generate(),
            last_owner_token: nil,
            blocked_until: nil,
            window_started_at: nil,
            crash_count: 0,
            tripped: false,
            needs_recovery: false,
            last_reason: nil
          },
          now
        )
      end)
    end
  end

  def get(agent_id) do
    case cast_uuid(agent_id) do
      {:ok, agent_id} -> Repo.get(AgentRestartGuard, agent_id)
      {:error, :invalid_restart_guard} -> nil
    end
  end

  defp matching_proven_owner(
         nil,
         %AgentRestartGuard{last_owner_token: token} = guard,
         %AgentTerminationIncident{lease_token: token}
       ) do
    if guard.needs_recovery or guard.tripped, do: {:duplicate, guard}, else: :already_released
  end

  defp matching_proven_owner(nil, _guard, _incident), do: :already_released

  defp matching_proven_owner(
         %AgentRuntimeLease{owner_token: token} = lease,
         _guard,
         %AgentTerminationIncident{lease_token: token}
       ),
       do: {:exact, lease}

  defp matching_proven_owner(_lease, _guard, _incident), do: :stale

  # A draining lease is a durable revocation marker. In particular, node and
  # partition drains publish it before terminating the local Agent process, so
  # its authenticated DOWN is expected and must not increment the crash guard.
  defp draining_owner?({:exact, %AgentRuntimeLease{draining_at: draining_at}}),
    do: not is_nil(draining_at)

  defp draining_owner?(_owner), do: false

  defp reconcile_expected_lifecycle_termination!(owner, incident, proof, now) do
    case owner do
      {:exact, %AgentRuntimeLease{} = exact_lease} ->
        delete_proven_lease!(exact_lease, incident)
        {:expected_lifecycle, mark_incident_reconciled!(incident, proof, now)}

      {:duplicate, %AgentRestartGuard{}} ->
        {:expected_lifecycle, mark_incident_reconciled!(incident, proof, now)}

      :already_released ->
        {:expected_lifecycle, mark_incident_reconciled!(incident, proof, now)}

      :stale ->
        {:ignored, :stale_owner}
    end
  end

  defp reconcile_unexpected_termination!(
         owner,
         agent,
         guard,
         incident,
         proof,
         now,
         policy,
         protocol_pair
       ) do
    case owner do
      {:duplicate, %AgentRestartGuard{} = duplicate} ->
        mark_incident_reconciled!(incident, proof, now)
        {:duplicate, duplicate}

      :already_released ->
        reconciled = mark_incident_reconciled!(incident, proof, now)
        {:reconciled_without_loss, reconciled}

      :stale ->
        {:ignored, :stale_owner}

      {:exact, %AgentRuntimeLease{} = exact_lease} ->
        {window_started_at, crash_count} = next_window(guard, now, policy.window_ms)
        tripped = crash_count >= policy.max_crashes

        blocked_until =
          if tripped, do: nil, else: deadline(now, backoff(policy, crash_count))

        attrs = %{
          agent_id: incident.agent_id,
          generation: Ecto.UUID.generate(),
          last_owner_token: incident.lease_token,
          blocked_until: blocked_until,
          window_started_at: window_started_at,
          crash_count: crash_count,
          tripped: tripped,
          needs_recovery: true,
          last_reason: safe_reason(proof_reason(proof))
        }

        stored_guard = put_guard!(guard, attrs, now)

        if tripped and agent.status not in ["stopped", "terminated"] do
          agent
          |> Ecto.Changeset.change(%{
            status: "stopped",
            stopped_at: now,
            updated_at: now
          })
          |> Repo.update!()
        end

        if tripped and protocol_pair == :exact do
          coordination = maybe_coordination_scope(agent, exact_lease, protocol_pair)

          if coordination != :deferred do
            cancel_pending_for_tripped_agent!(incident.agent_id, now, coordination)
          end
        end

        # The immutable proof and durable restart guard exist before the exact
        # lease row can disappear. Expiry alone never reaches this delete.
        delete_proven_lease!(exact_lease, incident)
        mark_incident_reconciled!(incident, proof, now)
        {:recorded, stored_guard}
    end
  end

  defp delete_proven_lease!(exact_lease, incident) do
    # The transaction-local incident ID binds the database trigger to the same
    # immutable proof identity checked above.
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.agent_termination_reconciliation', $1, true)",
      [incident.id]
    )

    Repo.delete!(exact_lease)
  end

  defp maybe_converge_expected_lifecycle({:expected_lifecycle, incident}) do
    # This pass can settle the just-proven lifecycle marker, but explicit closed
    # admission prevents this DOWN handler from scheduling any replacement.
    # A stale or draining coordination session returns the closed no-work shape;
    # the durable marker remains available to a later ready authority.
    _ = safe_lifecycle_convergence_pass()
    {:reconciled_without_loss, incident}
  end

  defp maybe_converge_expected_lifecycle(result), do: result

  defp safe_lifecycle_convergence_pass do
    WakeCoordinator.reconcile_once(admit_recoveries: false)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp termination_policy(incident, []) do
    stored = incident.reconciliation_policy || %{}

    policy(
      window_ms: stored["window_ms"] || @default_window_ms,
      max_crashes: stored["max_crashes"] || @default_max_crashes,
      backoffs_ms: stored["backoffs_ms"] || @default_backoffs_ms
    )
  end

  defp termination_policy(_incident, opts), do: policy(opts)

  defp validate_termination_identity!(candidate, incident, proof) do
    candidate_identity =
      {candidate.id, candidate.activation_epoch, candidate.node_incarnation_id,
       candidate.partition_id, candidate.partition_epoch, candidate.agent_id,
       candidate.lease_token}

    incident_identity =
      {incident.id, incident.activation_epoch, incident.node_incarnation_id,
       incident.partition_id, incident.partition_epoch, incident.agent_id, incident.lease_token}

    proof_identity =
      {proof.incident_id, proof.activation_epoch, proof.node_incarnation_id, proof.partition_id,
       proof.partition_epoch, proof.agent_id, proof.lease_token}

    if candidate_identity == incident_identity and
         incident_identity == proof_identity and
         incident.status in ["proven", "reconciled"] and
         incident.proof_id == proof.id do
      :ok
    else
      Repo.rollback(:termination_proof_mismatch)
    end
  end

  defp lock_termination_incident!(incident_id) do
    case Repo.one(
           from(incident in AgentTerminationIncident,
             where: incident.id == ^incident_id,
             lock: "FOR UPDATE"
           )
         ) do
      %AgentTerminationIncident{} = incident -> incident
      nil -> Repo.rollback(:termination_incident_not_found)
    end
  end

  defp lock_termination_proof!(incident) do
    case Repo.one(
           from(proof in AgentTerminationProof,
             where: proof.id == ^incident.proof_id,
             where: proof.incident_id == ^incident.id
           )
         ) do
      %AgentTerminationProof{} = proof -> proof
      nil -> Repo.rollback(:termination_proof_required)
    end
  end

  defp mark_incident_reconciled!(
         %AgentTerminationIncident{status: "proven"} = incident,
         proof,
         now
       ) do
    incident
    |> Ecto.Changeset.change(%{
      status: "reconciled",
      proof_id: proof.id,
      proof_kind: proof.proof_kind,
      proved_at: proof.proved_at,
      reconciled_at: now,
      retry_at: now,
      last_error: nil,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp mark_incident_reconciled!(
         %AgentTerminationIncident{status: "reconciled"} = incident,
         _proof,
         _now
       ),
       do: incident

  defp mark_incident_reconciled!(_incident, _proof, _now),
    do: Repo.rollback(:termination_proof_required)

  defp proof_reason(%AgentTerminationProof{proof_kind: "local_down", down_reason: reason}),
    do: reason || "agent_down"

  defp proof_reason(%AgentTerminationProof{proof_kind: "external_node_destroyed"}),
    do: "external_node_destroyed"

  defp maybe_coordination_scope(_agent, _lease, :legacy), do: :legacy

  defp maybe_coordination_scope(agent, lease, :exact) do
    case Scope.partition_for_user(agent.user_id) do
      {:ok, session, partition}
      when session.id == lease.coordination_node_incarnation_id and
             session.activation_epoch == lease.coordination_activation_epoch and
             partition.partition_id == lease.coordination_partition_id and
             partition.ownership_epoch == lease.coordination_partition_epoch ->
        Scope.authorize_reconciliation!(agent)

      _stale_partition ->
        :deferred
    end
  end

  defp maybe_coordination_scope(_agent, _lease, _blocked), do: :deferred

  defp next_window(nil, now, _window_ms), do: {now, 1}

  defp next_window(%AgentRestartGuard{} = guard, now, window_ms) do
    if is_nil(guard.window_started_at) or
         DateTime.diff(now, guard.window_started_at, :millisecond) > window_ms do
      {now, 1}
    else
      {guard.window_started_at, guard.crash_count + 1}
    end
  end

  defp backoff(%{backoffs_ms: backoffs}, crash_count) do
    backoffs
    |> Enum.at(max(crash_count - 1, 0), List.last(backoffs))
    |> min(@max_backoff_ms)
  end

  defp deadline(now, milliseconds), do: DateTime.add(now, milliseconds, :millisecond)

  defp put_guard!(nil, attrs, now) do
    %AgentRestartGuard{inserted_at: now, updated_at: now}
    |> AgentRestartGuard.changeset(attrs)
    |> Repo.insert!()
  end

  defp put_guard!(%AgentRestartGuard{} = guard, attrs, now) do
    guard
    |> AgentRestartGuard.changeset(attrs)
    |> Ecto.Changeset.change(updated_at: now)
    |> Repo.update!()
  end

  defp reconcile_tripped_generation(agent_id, generation) do
    Repo.transaction(fn ->
      :exact = Protocol.locked_pair!()
      agent = lock_agent!(agent_id)
      coordination = Scope.authorize_reconciliation!(agent)
      _binding = lock_binding(agent)
      guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      _operation = lock_operation(agent_id)

      cond do
        not match?(%AgentRestartGuard{}, guard) ->
          0

        guard.generation != generation or not guard.tripped or not guard.needs_recovery ->
          0

        not is_nil(lease) ->
          0

        is_nil(guard.last_owner_token) ->
          0

        true ->
          {count, _rows} =
            cancel_pending_for_tripped_agent!(
              agent_id,
              DatabaseClock.now!(),
              coordination
            )

          count
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_pending_for_tripped_agent!(agent_id, now, coordination) do
    query =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: not is_nil(effect.runtime_owner_generation),
        where: effect.status == "pending",
        where: is_nil(effect.claimed_by),
        where: is_nil(effect.claimed_at),
        where: is_nil(effect.claim_token),
        where: is_nil(effect.claim_owner_node),
        where: is_nil(effect.claim_heartbeat_at),
        where: is_nil(effect.claim_expires_at),
        where: is_nil(effect.claim_supervisor_id),
        where: is_nil(effect.claim_task_id)
      )
      |> Scope.scope_reconciliation_mutation(coordination)

    Repo.update_all(
      query,
      set: [
        status: "cancelled",
        cancellation_state: "settled",
        cancellation_reason: "agent_crash_loop_tripped",
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
        error: "agent_crash_loop_tripped",
        updated_at: now
      ]
    )
  end

  defp ensure_no_processing_directive!(agent_id) do
    case Repo.one(
           from(directive in AgentDirective,
             where: directive.agent_id == ^agent_id,
             where: directive.status == "processing",
             lock: "FOR UPDATE"
           )
         ) do
      nil -> :ok
      _processing -> Repo.rollback(:runtime_work_requires_reconciliation)
    end
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
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

  defp policy(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:window_ms, :max_crashes, :backoffs_ms])) do
      window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
      max_crashes = Keyword.get(opts, :max_crashes, @default_max_crashes)
      backoffs_ms = Keyword.get(opts, :backoffs_ms, @default_backoffs_ms)

      if is_integer(window_ms) and window_ms in 1_000..@max_window_ms and
           is_integer(max_crashes) and max_crashes in 1..@max_crashes and
           is_list(backoffs_ms) and backoffs_ms != [] and
           Enum.all?(backoffs_ms, &(is_integer(&1) and &1 in 0..@max_backoff_ms)) do
        {:ok, %{window_ms: window_ms, max_crashes: max_crashes, backoffs_ms: backoffs_ms}}
      else
        {:error, :invalid_restart_guard}
      end
    else
      {:error, :invalid_restart_guard}
    end
  end

  defp safe_reason(reason) do
    reason
    |> Maraithon.Redaction.error_class()
    |> case do
      value when is_binary(value) and byte_size(value) in 1..255 ->
        if String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
          do: value,
          else: "runtime_crash"

      _other ->
        "runtime_crash"
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_restart_guard}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_restart_guard}

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
