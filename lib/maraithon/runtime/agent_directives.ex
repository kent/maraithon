defmodule Maraithon.Runtime.AgentDirectives do
  @moduledoc """
  Durable, bounded Agent demand fenced by exact runtime lease generations.

  Enqueue is idempotent on `{agent_id, dedupe_key}` and never wakes a future
  schedule early. Claim is a workload-entry operation and therefore requires a
  live ready lease. Renew/terminal settlement use the exact live owner fence so
  a draining owner can durably finish already-started work. Enqueue follows the
  privacy-safe User -> Agent -> same-user Binding -> Guard -> Lease ->
  LifecycleOperation -> Directive order; lease-fenced paths inherit the
  canonical authority prefix from `AgentLeases`.
  """

  import Ecto.Query

  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.BoundedJSON
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminationIncident
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.Coordination.Scope

  @runnable_statuses ~w(running degraded)
  @default_claim_ttl_ms 60_000
  @min_claim_ttl_ms 1_000
  @max_claim_ttl_ms 300_000
  @max_delay_ms 604_800_000
  @max_payload_bytes 128_000
  @max_batch 500
  @redacted_payload %{"redacted" => true}
  @error_codes ~w(execution_failed runtime_crash lease_lost timeout cancelled invalid_directive effect_failed effect_outcome_ambiguous owner_lost_after_effect unknown)
  @settlement_statuses ~w(completed dead_letter cancelled)

  def enqueue(agent_id, user_id, kind, payload, dedupe_key, opts \\ [])

  def enqueue(agent_id, user_id, kind, payload, dedupe_key, opts) when is_list(opts) do
    with {:ok, prepared} <- prepare_enqueue(agent_id, user_id, kind, payload, dedupe_key, opts),
         {:ok, directive} <-
           Repo.transaction(fn ->
             ProtocolCutover.require_current_mutation!()
             enqueue_prepared!(prepared)
           end) do
      :ok = notify_committed(directive)
      {:ok, directive}
    end
  end

  def enqueue(_agent_id, _user_id, _kind, _payload, _dedupe_key, _opts),
    do: {:error, :invalid_directive}

  @doc """
  Enqueues one directive inside a caller-owned transaction.

  The caller must acquire no lower-order work locks before calling this
  function: it obtains the canonical User/Agent authority prefix and Directive
  lock.
  """
  def enqueue_in_transaction(agent_id, user_id, kind, payload, dedupe_key, opts \\ [])

  def enqueue_in_transaction(agent_id, user_id, kind, payload, dedupe_key, opts)
      when is_list(opts) do
    with true <- Repo.in_transaction?(),
         {:ok, prepared} <- prepare_enqueue(agent_id, user_id, kind, payload, dedupe_key, opts) do
      ProtocolCutover.require_current_mutation!()
      {:ok, enqueue_prepared!(prepared)}
    else
      false -> {:error, :transaction_required}
      {:error, _reason} = error -> error
    end
  end

  def enqueue_in_transaction(_agent_id, _user_id, _kind, _payload, _dedupe_key, _opts),
    do: {:error, :invalid_directive}

  @doc """
  Sends a best-effort ID-only nudge after a caller-owned enqueue transaction commits.

  Durable acceptance is the committed Directive row. Missing subscribers or a
  dropped mailbox notification do not change the result; resident Agents and
  wake reconciliation also poll PostgreSQL.
  """
  def notify_committed(%AgentDirective{agent_id: agent_id, id: directive_id})
      when is_binary(agent_id) and is_binary(directive_id) do
    Dispatch.dispatch(agent_id, {:directive_available, directive_id})
  end

  def notify_committed(_directive), do: :ok

  def claim_next(agent_id, user_id, owner_generation, opts \\ [])

  def claim_next(agent_id, user_id, owner_generation, opts) when is_list(opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, user_id} <- user_id(user_id),
         {:ok, owner_generation} <- cast_uuid(owner_generation),
         {:ok, ttl_ms} <- claim_opts(opts) do
      Repo.transaction(fn ->
        ProtocolCutover.require_current_mutation!()
        AgentLeases.fence_ready!(agent_id, owner_generation)
        ensure_agent_user!(agent_id, user_id)
        lease = Repo.get!(AgentRuntimeLease, agent_id)
        now = DatabaseClock.now!()

        case recover_expired_processing_for_owner(agent_id, owner_generation, now) do
          :busy ->
            nil

          :available ->
            case lock_next_due(agent_id) do
              nil ->
                nil

              directive ->
                deadline = claim_deadline!(now, ttl_ms, lease.lease_until)

                update!(directive, %{
                  status: "processing",
                  attempts: directive.attempts + 1,
                  claim_token: Ecto.UUID.generate(),
                  claimed_by_generation: owner_generation,
                  claimed_at: now,
                  claim_expires_at: deadline,
                  processing_started_at: now,
                  terminal_at: nil,
                  terminal_claim_token: nil,
                  terminal_by_generation: nil,
                  last_error_code: nil,
                  active_run_id: nil,
                  effect_admitted_at: nil,
                  effect_count: 0,
                  ambiguity_code: nil,
                  updated_at: now
                })
                |> AgentDirective.materialize_legacy_payload()
            end
        end
      end)
    end
  end

  def claim_next(_agent_id, _user_id, _owner_generation, _opts),
    do: {:error, :invalid_directive}

  @doc """
  Executes a durable write while holding the exact lease and Directive claim.

  `:ready` is required for new work or effect admission. `:owner` is reserved
  for closing already-admitted work while the lease is draining.
  """
  def with_live_claim(
        agent_id,
        directive_id,
        owner_generation,
        claim_token,
        mode,
        fun
      )
      when mode in [:ready, :owner] and is_function(fun, 2) do
    with {:ok, ids} <- exact_ids(agent_id, directive_id, owner_generation, claim_token) do
      Repo.transaction(fn ->
        ProtocolCutover.require_current_mutation!()
        fence_claim_mode!(ids.agent_id, ids.owner_generation, mode)
        directive = lock_directive!(ids)
        now = DatabaseClock.now!()
        ensure_live_claim!(directive, ids, now)
        run_claim_callback!(fun, directive, now)
      end)
    end
  end

  def with_live_claim(
        _agent_id,
        _directive_id,
        _owner_generation,
        _claim_token,
        _mode,
        _fun
      ),
      do: {:error, :invalid_directive}

  @doc false
  def renew_claim_in_transaction(
        agent_id,
        directive_id,
        owner_generation,
        claim_token,
        opts \\ []
      )

  def renew_claim_in_transaction(
        agent_id,
        directive_id,
        owner_generation,
        claim_token,
        opts
      )
      when is_list(opts) do
    with true <- Repo.in_transaction?(),
         {:ok, ids} <- exact_ids(agent_id, directive_id, owner_generation, claim_token),
         {:ok, ttl_ms} <- claim_opts(opts) do
      AgentLeases.fence_owner!(ids.agent_id, ids.owner_generation)
      lease = Repo.get!(AgentRuntimeLease, ids.agent_id)
      directive = lock_directive!(ids)
      now = DatabaseClock.now!()
      ensure_live_claim!(directive, ids, now)
      deadline = claim_deadline!(now, ttl_ms, lease.lease_until)

      {:ok,
       update!(directive, %{
         claim_expires_at: deadline,
         updated_at: now
       })}
    else
      false -> {:error, :transaction_required}
      {:error, _reason} = error -> error
    end
  end

  def renew_claim_in_transaction(
        _agent_id,
        _directive_id,
        _owner_generation,
        _claim_token,
        _opts
      ),
      do: {:error, :invalid_directive}

  @doc false
  def bind_run_locked(%AgentDirective{} = directive, run_id, now) do
    with true <- Repo.in_transaction?(),
         {:ok, run_id} <- cast_uuid(run_id),
         true <- directive.status == "processing",
         true <- is_nil(directive.active_run_id) or directive.active_run_id == run_id do
      {:ok,
       update!(directive, %{
         active_run_id: run_id,
         updated_at: now
       })}
    else
      false -> {:error, :directive_run_conflict}
      {:error, _reason} = error -> error
    end
  end

  def bind_run_locked(_directive, _run_id, _now), do: {:error, :invalid_directive}

  @doc false
  def admit_effect_locked(%AgentDirective{} = directive, run_id, now) do
    with true <- Repo.in_transaction?(),
         {:ok, run_id} <- cast_uuid(run_id),
         true <- directive.status == "processing",
         true <- directive.active_run_id == run_id do
      effect_count = directive.effect_count + 1

      {:ok,
       update!(directive, %{
         effect_admitted_at: directive.effect_admitted_at || now,
         effect_count: effect_count,
         updated_at: now
       }), effect_count}
    else
      false -> {:error, :directive_run_conflict}
      {:error, _reason} = error -> error
    end
  end

  def admit_effect_locked(_directive, _run_id, _now), do: {:error, :invalid_directive}

  @doc """
  Atomically settles a claim and caller-owned terminal-only writes.

  The callback runs at most once, only while the exact processing claim is
  locked. Immutable terminal proof makes retries return without rerunning it.
  Callbacks that require live-ready authority, especially those creating a new
  Snapshot recovery boundary, must use `settle_ready_with/7` so they preserve
  canonical lock ordering.
  """
  def settle_with(
        agent_id,
        directive_id,
        owner_generation,
        claim_token,
        terminal_status,
        error_code,
        fun
      )
      when terminal_status in @settlement_statuses and is_function(fun, 2) do
    settle_with_fence(
      agent_id,
      directive_id,
      owner_generation,
      claim_token,
      terminal_status,
      error_code,
      fun,
      :settlement
    )
  end

  def settle_with(
        _agent_id,
        _directive_id,
        _owner_generation,
        _claim_token,
        _terminal_status,
        _error_code,
        _fun
      ),
      do: {:error, :invalid_directive}

  @doc """
  Settles a live claim while retaining ready authority for callback writes.

  Use this when the terminal callback requires live-ready authority or creates
  a new Snapshot recovery boundary. Taking the partition fence before the User
  privacy fence preserves the runtime's canonical lock order.
  """
  def settle_ready_with(
        agent_id,
        directive_id,
        owner_generation,
        claim_token,
        terminal_status,
        error_code,
        fun
      )
      when terminal_status in @settlement_statuses and is_function(fun, 2) do
    settle_with_fence(
      agent_id,
      directive_id,
      owner_generation,
      claim_token,
      terminal_status,
      error_code,
      fun,
      :ready
    )
  end

  def settle_ready_with(
        _agent_id,
        _directive_id,
        _owner_generation,
        _claim_token,
        _terminal_status,
        _error_code,
        _fun
      ),
      do: {:error, :invalid_directive}

  defp settle_with_fence(
         agent_id,
         directive_id,
         owner_generation,
         claim_token,
         terminal_status,
         error_code,
         fun,
         fence_mode
       ) do
    with {:ok, ids} <- exact_ids(agent_id, directive_id, owner_generation, claim_token),
         {:ok, error_code} <- settlement_error_code(terminal_status, error_code) do
      case get_terminal_proof(ids, terminal_status) do
        %AgentDirective{} = terminal ->
          {:ok, %{directive: terminal, result: nil, newly_terminal?: false}}

        nil ->
          Repo.transaction(fn ->
            ProtocolCutover.require_current_mutation!()
            fence_settlement_mode!(ids.agent_id, ids.owner_generation, fence_mode)
            directive = lock_directive!(ids)
            now = DatabaseClock.now!()

            case settlement_state!(directive, ids, terminal_status, now) do
              :idempotent ->
                %{directive: directive, result: nil, newly_terminal?: false}

              :processing ->
                result = run_claim_callback!(fun, directive, now)

                terminal =
                  update!(directive, terminal_attrs(directive, terminal_status, now, error_code))

                %{directive: terminal, result: result, newly_terminal?: true}
            end
          end)
      end
    end
  end

  defp fence_settlement_mode!(agent_id, owner_generation, :ready),
    do: AgentLeases.fence_ready!(agent_id, owner_generation)

  defp fence_settlement_mode!(agent_id, owner_generation, :settlement),
    do: AgentLeases.fence_settlement!(agent_id, owner_generation)

  def cancel(agent_id, directive_id, owner_generation, claim_token) do
    case settle_with(
           agent_id,
           directive_id,
           owner_generation,
           claim_token,
           "cancelled",
           "cancelled",
           fn _directive, _now -> {:ok, :cancelled} end
         ) do
      {:ok, %{directive: directive}} -> {:ok, directive}
      {:error, _reason} = error -> error
    end
  end

  def renew_claim(agent_id, directive_id, owner_generation, claim_token, opts \\ [])

  def renew_claim(agent_id, directive_id, owner_generation, claim_token, opts)
      when is_list(opts) do
    with {:ok, ids} <- exact_ids(agent_id, directive_id, owner_generation, claim_token),
         {:ok, ttl_ms} <- claim_opts(opts) do
      Repo.transaction(fn ->
        ProtocolCutover.require_current_mutation!()
        AgentLeases.fence_owner!(ids.agent_id, ids.owner_generation)
        lease = Repo.get!(AgentRuntimeLease, ids.agent_id)
        directive = lock_directive!(ids)
        now = DatabaseClock.now!()
        ensure_live_claim!(directive, ids, now)
        deadline = claim_deadline!(now, ttl_ms, lease.lease_until)

        update!(directive, %{
          claim_expires_at: deadline,
          updated_at: now
        })
      end)
    end
  end

  def renew_claim(_agent_id, _directive_id, _owner_generation, _claim_token, _opts),
    do: {:error, :invalid_directive}

  def complete(agent_id, directive_id, owner_generation, claim_token) do
    case settle_with(
           agent_id,
           directive_id,
           owner_generation,
           claim_token,
           "completed",
           nil,
           fn _directive, _now -> {:ok, :completed} end
         ) do
      {:ok, %{directive: directive}} -> {:ok, directive}
      {:error, _reason} = error -> error
    end
  end

  def fail(agent_id, directive_id, owner_generation, claim_token, error_code, opts \\ [])

  def fail(agent_id, directive_id, owner_generation, claim_token, error_code, opts)
      when is_list(opts) do
    with {:ok, ids} <- exact_ids(agent_id, directive_id, owner_generation, claim_token),
         {:ok, error_code} <- error_code(error_code),
         {:ok, retry_delay_ms} <- retry_opts(opts) do
      case get_terminal_proof(ids, "dead_letter") do
        %AgentDirective{} = terminal ->
          {:ok, terminal}

        nil ->
          Repo.transaction(fn ->
            ProtocolCutover.require_current_mutation!()
            AgentLeases.fence_settlement!(ids.agent_id, ids.owner_generation)
            directive = lock_directive!(ids)
            now = DatabaseClock.now!()

            case settlement_state!(directive, ids, "dead_letter", now) do
              :idempotent ->
                directive

              :processing ->
                update!(directive, failure_attrs(directive, now, retry_delay_ms, error_code))
            end
          end)
      end
    end
  end

  def fail(_agent_id, _directive_id, _owner_generation, _claim_token, _error_code, _opts),
    do: {:error, :invalid_directive}

  @doc """
  Requeues or dead-letters the one directive owned by a generation whose loss
  was already durably recorded. This never removes an expired lease itself.
  """
  def recover_generation(agent_id, owner_generation, opts \\ [])

  def recover_generation(agent_id, owner_generation, opts) when is_list(opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_generation} <- cast_uuid(owner_generation),
         {:ok, retry_delay_ms} <- retry_opts(opts) do
      Repo.transaction(fn ->
        ProtocolCutover.require_current_mutation!()
        agent = lock_agent!(agent_id)
        _coordination = Scope.authorize_reconciliation!(agent)
        _binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        incident = lock_reconciled_termination(agent_id, owner_generation)
        proof = lock_termination_proof(incident)

        ensure_recorded_generation!(
          guard,
          lease,
          incident,
          proof,
          agent_id,
          owner_generation
        )

        if operation do
          :deferred_to_lifecycle
        else
          case lock_processing_generation(agent_id, owner_generation) do
            nil ->
              nil

            directive ->
              now = DatabaseClock.now!()

              update!(directive, failure_attrs(directive, now, retry_delay_ms, "runtime_crash"))
          end
        end
      end)
    end
  end

  def recover_generation(_agent_id, _owner_generation, _opts),
    do: {:error, :invalid_directive}

  @doc """
  Settles one expired claim only while its exact lease generation remains live.
  The claim token is rechecked after Agent -> Binding -> Guard -> Lease locks,
  so an unlocked sweeper hint can never revoke a rotated worker.
  """
  def recover_expired_claim(agent_id, directive_id, owner_generation, claim_token, opts \\ [])

  def recover_expired_claim(agent_id, directive_id, owner_generation, claim_token, opts)
      when is_list(opts) do
    with {:ok, ids} <- exact_ids(agent_id, directive_id, owner_generation, claim_token),
         {:ok, retry_delay_ms} <- retry_opts(opts) do
      Repo.transaction(fn ->
        ProtocolCutover.require_current_mutation!()
        AgentLeases.fence_settlement!(ids.agent_id, ids.owner_generation)
        operation = lock_operation(ids.agent_id)

        if operation, do: Repo.rollback(:deferred_to_lifecycle)

        directive = lock_directive!(ids)
        now = DatabaseClock.now!()

        cond do
          directive.status != "processing" or
            directive.claimed_by_generation != ids.owner_generation or
              directive.claim_token != ids.claim_token ->
            Repo.rollback(:directive_claim_lost)

          DateTime.compare(directive.claim_expires_at, now) == :gt ->
            :active

          true ->
            settle_expired_directive!(directive, now, retry_delay_ms)
        end
      end)
    end
  end

  def recover_expired_claim(_agent_id, _directive_id, _owner_generation, _claim_token, _opts),
    do: {:error, :invalid_directive}

  def reconcile_expired_claims(limit \\ 100, opts \\ [])

  def reconcile_expired_claims(limit, opts)
      when is_integer(limit) and limit in 1..@max_batch and is_list(opts) do
    with {:ok, retry_delay_ms} <- retry_opts(opts) do
      expired_claim_candidates(limit)
      |> Enum.map(fn {agent_id, directive_id, generation, claim_token} ->
        {agent_id, directive_id,
         recover_expired_claim(agent_id, directive_id, generation, claim_token,
           retry_delay_ms: retry_delay_ms
         )}
      end)
    end
  end

  def reconcile_expired_claims(_limit, _opts), do: {:error, :invalid_directive}

  @doc """
  Reconciles bounded expired lease hints through the guard-first exact-owner
  transaction, then settles that generation's directive in a second idempotent
  transaction. `reconcile_recorded_generations/2` closes the crash window
  between those commits.
  """
  def reconcile_expired_ownership(limit \\ 100, opts \\ [])

  def reconcile_expired_ownership(limit, opts)
      when is_integer(limit) and limit in 1..@max_batch and is_list(opts) do
    with {:ok, guard_opts, _retry_opts} <- reconciliation_opts(opts),
         requested when is_list(requested) <-
           AgentTerminations.request_expired_batch(limit, guard_opts) do
      Enum.map(requested, fn {status, incident} ->
        guard_result = {status, incident}

        {incident.agent_id, incident.lease_token, guard_result, :termination_proof_required}
      end)
    end
  end

  def reconcile_expired_ownership(_limit, _opts), do: {:error, :invalid_directive}

  def reconcile_recorded_generations(limit \\ 100, opts \\ [])

  def reconcile_recorded_generations(limit, opts)
      when is_integer(limit) and limit in 1..@max_batch and is_list(opts) do
    with {:ok, retry_delay_ms} <- retry_opts(opts) do
      recorded_generation_candidates(limit)
      |> Enum.map(fn {agent_id, owner_generation} ->
        {agent_id, recover_generation(agent_id, owner_generation, retry_delay_ms: retry_delay_ms)}
      end)
    end
  end

  def reconcile_recorded_generations(_limit, _opts), do: {:error, :invalid_directive}

  def list_due_agent_ids(limit \\ 100)

  def list_due_agent_ids(limit) when is_integer(limit) and limit in 1..@max_batch do
    from(directive in AgentDirective,
      join: agent in Agent,
      as: :agent,
      on: agent.id == directive.agent_id and agent.user_id == directive.user_id,
      join: binding in Binding,
      on: binding.agent_id == agent.id and binding.user_id == agent.user_id,
      left_join: lease in AgentRuntimeLease,
      on: lease.agent_id == agent.id,
      left_join: guard in AgentRestartGuard,
      on: guard.agent_id == agent.id,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == agent.id,
      left_join: termination in AgentTerminationIncident,
      on: termination.agent_id == agent.id and termination.status in ["requested", "proven"],
      where: directive.status == "pending",
      where: directive.available_at <= fragment("timezone('UTC', clock_timestamp())"),
      where: directive.attempts < directive.max_attempts,
      where: agent.install_status == "enabled",
      where: agent.status in ^@runnable_statuses,
      where: binding.status == "active",
      where: is_nil(lease.agent_id),
      where: is_nil(operation.agent_id),
      where: is_nil(termination.id),
      where:
        is_nil(guard.agent_id) or
          (guard.tripped == false and guard.needs_recovery == false and
             (is_nil(guard.blocked_until) or
                guard.blocked_until <= fragment("timezone('UTC', clock_timestamp())"))),
      group_by: agent.id,
      order_by: [asc: min(directive.available_at), asc: agent.id],
      limit: ^limit,
      select: agent.id
    )
    |> Scope.all_ready_agent()
  end

  def list_due_agent_ids(_limit), do: []

  def list_recovery_agent_ids(limit \\ 100)

  def list_recovery_agent_ids(limit) when is_integer(limit) and limit in 1..@max_batch do
    from(guard in AgentRestartGuard,
      join: agent in Agent,
      as: :agent,
      on: agent.id == guard.agent_id,
      join: binding in Binding,
      on: binding.agent_id == agent.id and binding.user_id == agent.user_id,
      left_join: lease in AgentRuntimeLease,
      on: lease.agent_id == agent.id,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == agent.id,
      left_join: termination in AgentTerminationIncident,
      on: termination.agent_id == agent.id and termination.status in ["requested", "proven"],
      where: guard.needs_recovery == true,
      where: guard.tripped == false,
      where:
        is_nil(guard.blocked_until) or
          guard.blocked_until <= fragment("timezone('UTC', clock_timestamp())"),
      where: agent.install_status == "enabled",
      where: agent.status in ^@runnable_statuses,
      where: binding.status == "active",
      where: is_nil(lease.agent_id),
      where: is_nil(operation.agent_id),
      where: is_nil(termination.id),
      order_by: [asc: guard.blocked_until, asc: guard.updated_at, asc: agent.id],
      limit: ^limit,
      select: agent.id
    )
    |> Scope.all_ready_agent()
  end

  def list_recovery_agent_ids(_limit), do: []

  defp expired_claim_candidates(limit) do
    from(directive in AgentDirective,
      join: agent in Agent,
      as: :agent,
      on: agent.id == directive.agent_id and agent.user_id == directive.user_id,
      join: lease in AgentRuntimeLease,
      as: :lease,
      on:
        lease.agent_id == directive.agent_id and
          lease.owner_token == directive.claimed_by_generation,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == directive.agent_id,
      where: directive.status == "processing",
      where: is_nil(operation.agent_id),
      where: lease.lease_until > fragment("timezone('UTC', clock_timestamp())"),
      where: directive.claim_expires_at <= fragment("timezone('UTC', clock_timestamp())"),
      order_by: [asc: directive.claim_expires_at, asc: directive.id],
      limit: ^limit,
      select: {
        directive.agent_id,
        directive.id,
        directive.claimed_by_generation,
        directive.claim_token
      }
    )
    |> Scope.all_ready_agent_lease()
  end

  defp recorded_generation_candidates(limit) do
    from(directive in AgentDirective,
      join: agent in Agent,
      as: :agent,
      on: agent.id == directive.agent_id and agent.user_id == directive.user_id,
      left_join: guard in AgentRestartGuard,
      on: guard.agent_id == directive.agent_id,
      left_join: lease in AgentRuntimeLease,
      on: lease.agent_id == directive.agent_id,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == directive.agent_id,
      left_join: incident in AgentTerminationIncident,
      on:
        incident.agent_id == directive.agent_id and
          incident.lease_token == directive.claimed_by_generation and
          incident.status == "reconciled",
      left_join: proof in AgentTerminationProof,
      on:
        proof.id == incident.proof_id and proof.incident_id == incident.id and
          proof.agent_id == directive.agent_id and
          proof.lease_token == directive.claimed_by_generation,
      where: directive.status == "processing",
      where: is_nil(lease.agent_id),
      where: is_nil(operation.agent_id),
      where:
        (guard.needs_recovery == true and
           guard.last_owner_token == directive.claimed_by_generation) or
          (not is_nil(incident.id) and not is_nil(proof.id)),
      order_by: [asc: directive.claim_expires_at, asc: directive.id],
      limit: ^limit,
      select: {directive.agent_id, directive.claimed_by_generation}
    )
    |> Scope.all_ready_agent()
  end

  @doc "Encrypts and redacts one resumable batch of legacy Directive payloads."
  def backfill_legacy_payload_encryption(limit \\ 100)

  def backfill_legacy_payload_encryption(limit) when is_integer(limit) and limit in 1..500 do
    case Repo.transaction(fn ->
           ProtocolCutover.require_legacy_mutation!()
           Maraithon.DurablePayloadContraction.require_authorized!()

           directives =
             AgentDirective
             |> where(
               [directive],
               directive.payload_encryption_version != 1 or
                 is_nil(directive.payload_encryption_version) or
                 is_nil(directive.payload) or
                 fragment(
                   "? IS DISTINCT FROM '{\"redacted\": true}'::jsonb",
                   directive.legacy_payload
                 )
             )
             |> order_by([directive], asc: directive.id)
             |> limit(^limit)
             |> lock("FOR UPDATE SKIP LOCKED")
             |> Repo.all()

           Enum.each(directives, fn directive ->
             # Backfill only establishes encrypted storage. Terminal payload
             # expiry remains exclusively owned by central retention after an
             # exact-protocol acknowledgement; it must never be inferred from
             # terminal status during a legacy conversion.
             attrs = %{
               payload:
                 if(directive.legacy_payload != @redacted_payload,
                   do: directive.legacy_payload || %{},
                   else: directive.payload || %{}
                 ),
               legacy_payload: @redacted_payload,
               payload_encryption_version: 1,
               payload_purged_at: directive.payload_purged_at
             }

             directive
             |> AgentDirective.changeset(attrs)
             |> Repo.update!()
           end)

           length(directives)
         end) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      {:error, {:directive_payload_backfill_failed, Maraithon.Redaction.error_class(error)}}
  catch
    :exit, reason ->
      {:error, {:directive_payload_backfill_failed, Maraithon.Redaction.error_class(reason)}}
  end

  def backfill_legacy_payload_encryption(_limit), do: {:error, :invalid_payload_batch_size}

  defp prepare_enqueue(agent_id, user_id, kind, payload, dedupe_key, opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, user_id} <- user_id(user_id),
         {:ok, kind} <- kind(kind),
         {:ok, dedupe_key} <- dedupe_key(dedupe_key),
         {:ok, payload} <- prepare_payload(payload),
         {:ok, enqueue_opts} <- enqueue_opts(opts) do
      {:ok,
       %{
         agent_id: agent_id,
         user_id: user_id,
         kind: kind,
         payload: payload,
         legacy_payload:
           if(ProtocolCutover.mode() == :legacy, do: payload, else: @redacted_payload),
         dedupe_key: dedupe_key,
         request_fingerprint: fingerprint(kind, payload),
         delay_ms: enqueue_opts.delay_ms,
         max_attempts: enqueue_opts.max_attempts
       }}
    end
  end

  defp enqueue_prepared!(prepared) do
    _user = prelock_enqueue_user!(prepared.agent_id, prepared.user_id)
    agent = lock_agent!(prepared.agent_id)
    :ok = WriteFence.ensure_agent_writable!(prepared.agent_id)
    binding = lock_binding(agent)
    _guard = lock_guard(prepared.agent_id)
    _lease = lock_lease(prepared.agent_id)
    operation = lock_operation(prepared.agent_id)
    if operation, do: Repo.rollback(:agent_drain_pending)
    ensure_runnable_owner!(agent, prepared.user_id, binding)
    now = DatabaseClock.now!()

    case lock_by_dedupe(prepared.agent_id, prepared.dedupe_key) do
      nil ->
        insert!(%{
          agent_id: prepared.agent_id,
          user_id: prepared.user_id,
          kind: prepared.kind,
          payload: prepared.payload,
          legacy_payload: prepared.legacy_payload,
          dedupe_key: prepared.dedupe_key,
          request_fingerprint: prepared.request_fingerprint,
          status: "pending",
          available_at: DateTime.add(now, prepared.delay_ms, :millisecond),
          attempts: 0,
          max_attempts: prepared.max_attempts,
          effect_count: 0,
          inserted_at: now,
          updated_at: now
        })

      %AgentDirective{request_fingerprint: fingerprint} = existing
      when fingerprint == prepared.request_fingerprint ->
        existing

      _changed_request ->
        Repo.rollback(:directive_idempotency_conflict)
    end
  end

  defp prelock_enqueue_user!(agent_id, requested_user_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, select: agent.user_id)) do
      ^requested_user_id -> WriteFence.lock_user_writable!(requested_user_id)
      nil -> Repo.rollback(:agent_not_found)
      _other_user_id -> Repo.rollback(:agent_owner_mismatch)
    end
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      nil -> Repo.rollback(:agent_not_found)
      agent -> agent
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

  defp lock_operation(agent_id) do
    Repo.one(
      from(operation in AgentLifecycleOperation,
        where: operation.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_reconciled_termination(agent_id, owner_generation) do
    Repo.one(
      from(incident in AgentTerminationIncident,
        where: incident.agent_id == ^agent_id,
        where: incident.lease_token == ^owner_generation,
        where: incident.status == "reconciled",
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_termination_proof(%AgentTerminationIncident{} = incident) do
    Repo.one(
      from(proof in AgentTerminationProof,
        where: proof.id == ^incident.proof_id,
        where: proof.incident_id == ^incident.id
      )
    )
  end

  defp lock_termination_proof(nil), do: nil

  defp lock_by_dedupe(agent_id, dedupe_key) do
    Repo.one(
      from(directive in AgentDirective,
        where: directive.agent_id == ^agent_id,
        where: directive.dedupe_key == ^dedupe_key,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_processing_agent(agent_id) do
    Repo.one(
      from(directive in AgentDirective,
        where: directive.agent_id == ^agent_id,
        where: directive.status == "processing",
        lock: "FOR UPDATE"
      )
    )
  end

  defp recover_expired_processing_for_owner(agent_id, owner_generation, now) do
    case lock_processing_agent(agent_id) do
      nil ->
        :available

      %AgentDirective{claim_expires_at: expires_at} = directive ->
        cond do
          DateTime.compare(expires_at, now) == :gt ->
            :busy

          directive.claimed_by_generation != owner_generation ->
            Repo.rollback(:stale_directive_claim_requires_reconciliation)

          true ->
            _recovered = settle_expired_directive!(directive, now, 0)
            :available
        end
    end
  end

  defp settle_expired_directive!(directive, now, retry_delay_ms) do
    update!(directive, failure_attrs(directive, now, retry_delay_ms, "timeout"))
  end

  defp lock_next_due(agent_id) do
    Repo.one(
      from(directive in AgentDirective,
        where: directive.agent_id == ^agent_id,
        where: directive.status == "pending",
        where: directive.attempts < directive.max_attempts,
        where: directive.available_at <= fragment("timezone('UTC', clock_timestamp())"),
        order_by: [asc: directive.available_at, asc: directive.inserted_at, asc: directive.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp get_terminal_proof(ids, terminal_status) do
    Repo.one(
      from(directive in AgentDirective,
        where: directive.id == ^ids.directive_id,
        where: directive.agent_id == ^ids.agent_id,
        where: directive.status == ^terminal_status,
        where: directive.terminal_by_generation == ^ids.owner_generation,
        where: directive.terminal_claim_token == ^ids.claim_token
      )
    )
  end

  defp lock_directive!(ids) do
    case Repo.one(
           from(directive in AgentDirective,
             where: directive.id == ^ids.directive_id,
             where: directive.agent_id == ^ids.agent_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> Repo.rollback(:directive_claim_lost)
      directive -> directive
    end
  end

  defp ensure_live_claim!(directive, ids, now) do
    if directive.status == "processing" and
         directive.claimed_by_generation == ids.owner_generation and
         directive.claim_token == ids.claim_token do
      if DateTime.compare(directive.claim_expires_at, now) == :gt,
        do: :ok,
        else: Repo.rollback(:directive_claim_expired)
    else
      Repo.rollback(:directive_claim_lost)
    end
  end

  defp settlement_state!(directive, ids, terminal_status, now) do
    cond do
      directive.status == terminal_status and
        directive.terminal_by_generation == ids.owner_generation and
          directive.terminal_claim_token == ids.claim_token ->
        :idempotent

      true ->
        ensure_live_claim!(directive, ids, now)
        :processing
    end
  end

  defp claim_deadline!(now, ttl_ms, lease_until) do
    requested = DateTime.add(now, ttl_ms, :millisecond)

    deadline =
      if DateTime.compare(requested, lease_until) == :gt, do: lease_until, else: requested

    if DateTime.compare(deadline, now) == :gt,
      do: deadline,
      else: Repo.rollback(:runtime_lease_expired)
  end

  defp lock_processing_generation(agent_id, owner_generation) do
    Repo.one(
      from(directive in AgentDirective,
        where: directive.agent_id == ^agent_id,
        where: directive.status == "processing",
        where: directive.claimed_by_generation == ^owner_generation,
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_runnable_owner!(%Agent{user_id: owner_user_id}, requested_user_id, _binding)
       when owner_user_id != requested_user_id,
       do: Repo.rollback(:agent_owner_mismatch)

  defp ensure_runnable_owner!(
         %Agent{user_id: user_id, install_status: "enabled", status: status},
         user_id,
         %Binding{user_id: user_id, status: "active"}
       )
       when status in @runnable_statuses,
       do: :ok

  defp ensure_runnable_owner!(
         %Agent{user_id: user_id, install_status: "enabled", status: status},
         user_id,
         _binding
       )
       when status in @runnable_statuses,
       do: Repo.rollback(:agent_binding_not_active)

  defp ensure_runnable_owner!(%Agent{}, _user_id, _binding),
    do: Repo.rollback(:agent_not_runnable)

  defp ensure_agent_user!(agent_id, user_id) do
    if Repo.exists?(
         from(agent in Agent, where: agent.id == ^agent_id and agent.user_id == ^user_id)
       ),
       do: :ok,
       else: Repo.rollback(:agent_owner_mismatch)
  end

  defp ensure_recorded_generation!(
         _guard,
         %AgentRuntimeLease{},
         _incident,
         _proof,
         _agent_id,
         _owner_generation
       ),
       do: Repo.rollback(:runtime_lease_owned)

  defp ensure_recorded_generation!(guard, nil, incident, proof, agent_id, owner_generation) do
    if guard_records_generation?(guard, owner_generation) or
         termination_records_generation?(incident, proof, agent_id, owner_generation) do
      :ok
    else
      Repo.rollback(:stale_recovery_generation)
    end
  end

  defp guard_records_generation?(
         %AgentRestartGuard{needs_recovery: true, last_owner_token: owner_generation},
         owner_generation
       ),
       do: true

  defp guard_records_generation?(_guard, _owner_generation), do: false

  defp termination_records_generation?(
         %AgentTerminationIncident{
           id: incident_id,
           activation_epoch: activation_epoch,
           node_incarnation_id: node_incarnation_id,
           partition_id: partition_id,
           partition_epoch: partition_epoch,
           agent_id: agent_id,
           lease_token: owner_generation,
           status: "reconciled",
           proof_id: proof_id
         },
         %AgentTerminationProof{
           id: proof_id,
           incident_id: incident_id,
           activation_epoch: activation_epoch,
           node_incarnation_id: node_incarnation_id,
           partition_id: partition_id,
           partition_epoch: partition_epoch,
           agent_id: agent_id,
           lease_token: owner_generation
         },
         agent_id,
         owner_generation
       ),
       do: true

  defp termination_records_generation?(_incident, _proof, _agent_id, _owner_generation),
    do: false

  defp insert!(attrs) do
    case %AgentDirective{} |> AgentDirective.changeset(attrs) |> Repo.insert() do
      {:ok, directive} -> directive
      {:error, changeset} -> Repo.rollback({:invalid_directive, changeset})
    end
  end

  defp update!(directive, attrs) do
    case directive |> AgentDirective.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:invalid_directive, changeset})
    end
  end

  defp failure_attrs(directive, now, retry_delay_ms, error_code) do
    cond do
      directive.effect_count > 0 ->
        ambiguous? = error_code in ~w(runtime_crash lease_lost timeout unknown)
        terminal_error = if ambiguous?, do: "owner_lost_after_effect", else: error_code

        directive
        |> terminal_attrs("dead_letter", now, terminal_error)
        |> Map.put(:ambiguity_code, if(ambiguous?, do: "effect_outcome_ambiguous", else: nil))

      directive.attempts >= directive.max_attempts ->
        terminal_attrs(directive, "dead_letter", now, error_code)

      true ->
        %{
          status: "pending",
          available_at: DateTime.add(now, retry_delay_ms, :millisecond),
          claim_token: nil,
          claimed_by_generation: nil,
          claimed_at: nil,
          claim_expires_at: nil,
          processing_started_at: nil,
          terminal_at: nil,
          terminal_claim_token: nil,
          terminal_by_generation: nil,
          last_error_code: error_code,
          active_run_id: nil,
          effect_admitted_at: nil,
          effect_count: 0,
          ambiguity_code: nil,
          updated_at: now
        }
    end
  end

  defp fence_claim_mode!(agent_id, owner_generation, :ready),
    do: AgentLeases.fence_ready!(agent_id, owner_generation)

  defp fence_claim_mode!(agent_id, owner_generation, :owner),
    do: AgentLeases.fence_owner!(agent_id, owner_generation)

  defp run_claim_callback!(fun, directive, now) do
    case fun.(directive, now) do
      {:ok, result} -> result
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
      _invalid -> Repo.rollback(:invalid_directive_callback)
    end
  end

  defp settlement_error_code("completed", nil), do: {:ok, nil}
  defp settlement_error_code("cancelled", nil), do: {:ok, "cancelled"}
  defp settlement_error_code("cancelled", "cancelled"), do: {:ok, "cancelled"}
  defp settlement_error_code("dead_letter", value), do: error_code(value)
  defp settlement_error_code(_status, _value), do: {:error, :invalid_directive}

  defp terminal_attrs(directive, status, now, error_code) do
    %{
      status: status,
      # Settlement is the Directive consumer acknowledgement. Keep content
      # encrypted until the bounded retention worker clears it; do not erase
      # before this terminal authority commit exists.
      terminal_acknowledged_at: now,
      claim_token: nil,
      claimed_by_generation: nil,
      claimed_at: nil,
      claim_expires_at: nil,
      processing_started_at: nil,
      terminal_at: now,
      terminal_claim_token: directive.claim_token,
      terminal_by_generation: directive.claimed_by_generation,
      last_error_code: error_code,
      ambiguity_code: nil,
      updated_at: now
    }
  end

  defp prepare_payload(payload) when is_map(payload) and not is_struct(payload) do
    if BoundedJSON.valid?(payload, @max_payload_bytes,
         max_binary_bytes: 100_000,
         max_depth: 12,
         max_nodes: 20_000,
         max_map_entries: 2_000,
         max_list_items: 5_000
       ) do
      with {:ok, encoded} <- Jason.encode(payload),
           true <- byte_size(encoded) <= @max_payload_bytes,
           {:ok, canonical} when is_map(canonical) <- Jason.decode(encoded) do
        {:ok, canonical}
      else
        _invalid -> {:error, :invalid_directive}
      end
    else
      {:error, :invalid_directive}
    end
  rescue
    _error -> {:error, :invalid_directive}
  end

  defp prepare_payload(_payload), do: {:error, :invalid_directive}

  defp fingerprint(kind, payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary({kind, payload}, [:deterministic]))
  end

  defp reconciliation_opts(opts) do
    allowed = [:window_ms, :max_crashes, :backoffs_ms, :retry_delay_ms]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      guard_opts = Keyword.take(opts, [:window_ms, :max_crashes, :backoffs_ms])
      retry_only = Keyword.take(opts, [:retry_delay_ms])

      case retry_opts(retry_only) do
        {:ok, retry_delay_ms} -> {:ok, guard_opts, [retry_delay_ms: retry_delay_ms]}
        {:error, :invalid_directive} = error -> error
      end
    else
      {:error, :invalid_directive}
    end
  end

  defp enqueue_opts(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:delay_ms, :max_attempts])) do
      delay_ms = Keyword.get(opts, :delay_ms, 0)
      max_attempts = Keyword.get(opts, :max_attempts, 3)

      if is_integer(delay_ms) and delay_ms in 0..@max_delay_ms and
           is_integer(max_attempts) and max_attempts in 1..100,
         do: {:ok, %{delay_ms: delay_ms, max_attempts: max_attempts}},
         else: {:error, :invalid_directive}
    else
      {:error, :invalid_directive}
    end
  end

  defp claim_opts(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :ttl_ms)) do
      ttl_ms = Keyword.get(opts, :ttl_ms, @default_claim_ttl_ms)

      if is_integer(ttl_ms) and ttl_ms in @min_claim_ttl_ms..@max_claim_ttl_ms,
        do: {:ok, ttl_ms},
        else: {:error, :invalid_directive}
    else
      {:error, :invalid_directive}
    end
  end

  defp retry_opts(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :retry_delay_ms)) do
      delay_ms = Keyword.get(opts, :retry_delay_ms, 0)

      if is_integer(delay_ms) and delay_ms in 0..@max_delay_ms,
        do: {:ok, delay_ms},
        else: {:error, :invalid_directive}
    else
      {:error, :invalid_directive}
    end
  end

  defp exact_ids(agent_id, directive_id, owner_generation, claim_token) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, directive_id} <- cast_uuid(directive_id),
         {:ok, owner_generation} <- cast_uuid(owner_generation),
         {:ok, claim_token} <- cast_uuid(claim_token) do
      {:ok,
       %{
         agent_id: agent_id,
         directive_id: directive_id,
         owner_generation: owner_generation,
         claim_token: claim_token
       }}
    end
  end

  defp user_id(value) when is_binary(value) and byte_size(value) in 1..320 do
    if String.valid?(value) and not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_directive}
  end

  defp user_id(_value), do: {:error, :invalid_directive}

  defp kind(value) when is_atom(value), do: kind(Atom.to_string(value))

  defp kind(value) when is_binary(value) do
    if value in AgentDirective.kinds(),
      do: {:ok, value},
      else: {:error, :invalid_directive}
  end

  defp kind(_value), do: {:error, :invalid_directive}

  defp dedupe_key(value) when is_binary(value) and byte_size(value) in 1..255 do
    if String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_directive}
  end

  defp dedupe_key(_value), do: {:error, :invalid_directive}

  defp error_code(value) when is_atom(value), do: error_code(Atom.to_string(value))

  defp error_code(value) when value in @error_codes, do: {:ok, value}
  defp error_code(_value), do: {:error, :invalid_directive}

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_directive}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_directive}
end
