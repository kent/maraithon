defmodule Maraithon.Runtime.AgentLeases do
  @moduledoc """
  Exact PostgreSQL-clock ownership and readiness fences for runtime Agents.

  Registry, PID, node name, and `agents.status` are never ownership proof. The
  immutable UUID token plus a live database lease is lifecycle authority;
  workload authority additionally requires readiness, current desired-state,
  Binding consent, an open exact-runtime gate, and no lifecycle marker. When a
  watcher is supplied, local termination authority is prepared inside that
  AgentWatcher and only its digest is inserted or returned by this module. A
  watcherless claim is explicitly external-proof-only and persists a NULL
  termination capability digest; it never creates an orphaned local preimage.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminationIncident
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.Coordination.{Authority, NodeIncarnation, Protocol, Scope}

  require Logger

  @default_ttl_ms 60_000
  @min_ttl_ms 1_000
  @max_ttl_ms 300_000
  @runnable_statuses ~w(running degraded)

  @doc """
  Claims an unready exact owner generation.

  Passing `:watcher` prepares local physical-DOWN authority in that watcher.
  Omitting it deliberately creates an external-proof-only lease whose
  `termination_capability_digest` is NULL.
  """
  def claim(agent_id, opts \\ [])

  def claim(agent_id, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_node} <- owner_node(opts),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms, :owner_node, :watcher]) do
      owner_token = Ecto.UUID.generate()

      with_termination_capability(agent_id, owner_token, opts, fn termination_capability_digest ->
        Repo.transaction(fn ->
          coordination = prelock_new_agent!(agent_id, :admission)
          agent = lock_agent!(agent_id)
          ensure_scope_agent!(agent, coordination)
          binding = lock_active_binding!(agent)
          guard = lock_guard(agent_id)
          lease = lock_lease(agent_id)
          operation = lock_operation(agent_id)
          termination_incident = lock_open_termination_incident(agent_id)
          {now, lease_until} = DatabaseClock.window!(ttl_ms)

          ensure_no_lifecycle_operation!(operation)
          ensure_no_open_termination_incident!(termination_incident)
          ensure_runnable!(agent)
          ensure_binding_matches!(agent, binding)
          ensure_initial_guard_allows_claim!(guard, now)
          ensure_no_existing_lease!(lease, now)
          ensure_no_processing_directive!(agent_id, :runtime_work_requires_reconciliation)

          insert_lease!(
            agent_id,
            owner_token,
            owner_node,
            termination_capability_digest,
            now,
            lease_until,
            coordination
          )
        end)
      end)
    end
  end

  def claim(_agent_id, _opts), do: {:error, :invalid_runtime_lease}

  def claim_recovery(agent_id, guard_generation, opts \\ [])

  def claim_recovery(agent_id, guard_generation, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, guard_generation} <- cast_uuid(guard_generation),
         {:ok, owner_node} <- owner_node(opts),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms, :owner_node, :watcher]) do
      owner_token = Ecto.UUID.generate()

      with_termination_capability(agent_id, owner_token, opts, fn termination_capability_digest ->
        Repo.transaction(fn ->
          coordination = prelock_new_agent!(agent_id, :admission)
          agent = lock_agent!(agent_id)
          ensure_scope_agent!(agent, coordination)
          binding = lock_active_binding!(agent)
          guard = lock_guard(agent_id)
          lease = lock_lease(agent_id)
          operation = lock_operation(agent_id)
          termination_incident = lock_open_termination_incident(agent_id)
          {now, lease_until} = DatabaseClock.window!(ttl_ms)

          ensure_no_lifecycle_operation!(operation)
          ensure_no_open_termination_incident!(termination_incident)
          ensure_runnable!(agent)
          ensure_binding_matches!(agent, binding)
          ensure_due_recovery_guard!(guard, guard_generation, now)
          ensure_no_existing_lease!(lease, now)
          ensure_no_processing_directive!(agent_id, :runtime_work_requires_reconciliation)

          insert_lease!(
            agent_id,
            owner_token,
            owner_node,
            termination_capability_digest,
            now,
            lease_until,
            coordination
          )
        end)
      end)
    end
  end

  def claim_recovery(_agent_id, _guard_generation, _opts),
    do: {:error, :invalid_runtime_lease}

  def renew(agent_id, owner_token, opts \\ [])

  def renew(agent_id, owner_token, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms]) do
      Repo.transaction(fn ->
        scope = prelock_existing_lease!(agent_id, :ready, :admission)
        agent = lock_agent!(agent_id)
        ensure_scope_agent!(agent, scope)
        binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, lease_until} = DatabaseClock.window!(ttl_ms)

        ensure_exact_live_lease!(lease, owner_token, now)
        ensure_coordination_lease!(lease, :owner, scope)

        runnable? =
          is_nil(operation) and runnable?(agent) and binding_matches?(agent, binding) and
            guard_allows_ready?(guard, now)

        updates =
          if runnable? do
            %{renewed_at: now, lease_until: lease_until, updated_at: now}
          else
            %{
              renewed_at: now,
              lease_until: lease_until,
              ready_at: nil,
              draining_at: lease.draining_at || now,
              updated_at: now
            }
          end

        update_lease!(lease, updates)
      end)
    end
  end

  def renew(_agent_id, _owner_token, _opts), do: {:error, :invalid_runtime_lease}

  @doc """
  Renews an unready recovery incarnation without publishing readiness or
  converting the lease to draining while its exact guard generation remains
  due. Recovery readiness is still published only by `finish_recovery/3`.
  """
  def renew_recovery(agent_id, owner_token, guard_generation, opts \\ [])

  def renew_recovery(agent_id, owner_token, guard_generation, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, guard_generation} <- cast_uuid(guard_generation),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms]) do
      Repo.transaction(fn ->
        scope = prelock_existing_lease!(agent_id, :ready, :admission)
        agent = lock_agent!(agent_id)
        ensure_scope_agent!(agent, scope)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, lease_until} = DatabaseClock.window!(ttl_ms)

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_due_recovery_guard!(guard, guard_generation, now)
        ensure_exact_live_lease!(lease, owner_token, now)
        ensure_coordination_lease!(lease, :owner, scope)

        update_lease!(lease, %{
          renewed_at: now,
          lease_until: lease_until,
          updated_at: now
        })
      end)
    end
  end

  def renew_recovery(_agent_id, _owner_token, _guard_generation, _opts),
    do: {:error, :invalid_runtime_lease}

  def mark_ready(agent_id, owner_token) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.transaction(fn ->
        scope = prelock_existing_lease!(agent_id, :ready, :admission)
        agent = lock_agent!(agent_id)
        ensure_scope_agent!(agent, scope)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_initial_guard_allows_claim!(guard, now)
        ensure_exact_live_lease!(lease, owner_token, now)
        ensure_coordination_lease!(lease, :ready, scope)

        # Readiness is deliberately the last authority write in this transaction.
        update_lease!(lease, %{ready_at: now, draining_at: nil, updated_at: now})
      end)
    end
  end

  def finish_recovery(agent_id, owner_token, guard_generation) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, guard_generation} <- cast_uuid(guard_generation) do
      Repo.transaction(fn ->
        scope = prelock_existing_lease!(agent_id, :ready, :admission)
        agent = lock_agent!(agent_id)
        ensure_scope_agent!(agent, scope)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_due_recovery_guard!(guard, guard_generation, now)
        ensure_exact_live_lease!(lease, owner_token, now)
        ensure_coordination_lease!(lease, :ready, scope)

        guard
        |> Ecto.Changeset.change(%{
          needs_recovery: false,
          blocked_until: nil,
          updated_at: now
        })
        |> Repo.update!()

        # The lease becomes ready only after every recovery fact is committed.
        update_lease!(lease, %{ready_at: now, draining_at: nil, updated_at: now})
      end)
    end
  end

  @doc """
  Atomically revoke workload readiness and persist stopped desired state.

  The returned lease token is routing metadata for the exact incarnation that
  was fenced. Callers must finish this transaction before signalling a local or
  remote process; no process/RPC wait belongs inside the database lock scope.
  """
  def fence_for_stop(agent_id, opts \\ [])

  def fence_for_stop(agent_id, opts) when is_list(opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms]) do
      Repo.transaction(fn ->
        scope = prelock_existing_or_new!(agent_id, :owner, :settlement)
        agent = lock_agent!(agent_id)
        ensure_scope_agent!(agent, scope)
        _binding = lock_binding(agent)
        _guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, drain_until} = DatabaseClock.window!(ttl_ms)
        ensure_no_lifecycle_operation!(operation)

        {lease_state, fenced_lease} =
          cond do
            is_nil(lease) ->
              {:none, nil}

            DateTime.compare(lease.lease_until, now) == :gt ->
              fenced =
                update_lease!(lease, %{
                  ready_at: nil,
                  draining_at: lease.draining_at || now,
                  lease_until: later_datetime(lease.lease_until, drain_until),
                  updated_at: now
                })

              {:live, fenced}

            true ->
              # Expiry is generation loss, never permission to resurrect that
              # incarnation for cleanup. Abort before changing desired state so
              # the caller can durably record the exact loss generation first.
              Repo.rollback(
                {:expired_lease_requires_reconciliation,
                 %{owner_token: lease.owner_token, owner_node: lease.owner_node}}
              )
          end

        stopped_agent =
          if agent.status == "stopped" and not is_nil(agent.stopped_at) do
            agent
          else
            agent
            |> Ecto.Changeset.change(%{
              status: "stopped",
              stopped_at: now,
              updated_at: now
            })
            |> Repo.update!()
          end

        %{agent: stopped_agent, lease: fenced_lease, lease_state: lease_state}
      end)
    end
  end

  def fence_for_stop(_agent_id, _opts), do: {:error, :invalid_runtime_lease}

  def begin_draining(agent_id, owner_token) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.transaction(fn ->
        scope = prelock_existing_lease!(agent_id, :owner, :settlement)
        agent = lock_agent!(agent_id)
        ensure_scope_agent!(agent, scope)
        _binding = lock_binding(agent)
        _guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        _operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        ensure_exact_live_lease!(lease, owner_token, now)
        ensure_coordination_lease!(lease, :owner, scope)

        update_lease!(lease, %{
          ready_at: nil,
          draining_at: lease.draining_at || now,
          updated_at: now
        })
      end)
    end
  end

  @doc "Lease removal is reserved for proof-gated physical termination reconciliation."
  def release(agent_id, owner_token) do
    with {:ok, _agent_id} <- cast_uuid(agent_id),
         {:ok, _owner_token} <- cast_uuid(owner_token) do
      {:error, :termination_proof_required}
    end
  end

  def owner?(agent_id, owner_token) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      agent_id
      |> owner_query(owner_token)
      |> Scope.exists_ready_agent_lease()
    else
      _invalid -> false
    end
  end

  def ready?(agent_id, owner_token) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      agent_id
      |> ready_query(owner_token)
      |> Scope.exists_ready_agent_lease()
    else
      _invalid_or_disabled -> false
    end
  end

  def fence_owner!(agent_id, owner_token) do
    require_transaction!()
    ensure_exact_runtime_enabled!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      scope = prelock_existing_lease!(agent_id, :owner, :settlement)
      agent = lock_agent!(agent_id)
      ensure_scope_agent!(agent, scope)
      _binding = lock_binding(agent)
      _guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      _operation = lock_operation(agent_id)
      now = DatabaseClock.now!()

      ensure_exact_live_lease!(lease, owner_token, now)
      ensure_coordination_lease!(lease, :owner, scope)
      :ok
    else
      _invalid -> Repo.rollback(:runtime_lease_lost)
    end
  end

  @doc """
  Fences only terminal settlement of work already admitted by an exact owner.

  Unlike `fence_owner!/2`, this does not admit progress or renewal. It accepts an
  expired/draining exact lease, or the immutable reconciled termination proof for
  that generation after the lease was deleted or replaced. The row trigger on
  the terminal work record remains the final topology/claim identity check.
  """
  def fence_settlement!(agent_id, owner_token) do
    require_transaction!()
    ensure_exact_runtime_enabled!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      user_id = prelock_settlement_agent!(agent_id)
      agent = lock_agent!(agent_id)
      ensure_scope_agent!(agent, %{user_id: user_id})
      _binding = lock_binding(agent)
      _guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      _operation = lock_operation(agent_id)

      ensure_settlement_authority!(lease, agent_id, owner_token)
    else
      _invalid -> Repo.rollback(:runtime_lease_lost)
    end
  end

  def fence_ready!(agent_id, owner_token) do
    _lease_until = fence_ready_lease_until!(agent_id, owner_token)
    :ok
  end

  @doc false
  def fence_ready_lease_until!(agent_id, owner_token) do
    require_transaction!()
    ensure_exact_runtime_enabled!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      scope = prelock_existing_lease!(agent_id, :ready, :admission)
      agent = lock_agent!(agent_id)
      ensure_scope_agent!(agent, scope)
      binding = lock_active_binding!(agent)
      guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      operation = lock_operation(agent_id)
      now = DatabaseClock.now!()

      ensure_no_lifecycle_operation!(operation)
      ensure_runnable!(agent)
      ensure_binding_matches!(agent, binding)
      ensure_initial_guard_allows_claim!(guard, now)
      ensure_exact_ready_lease!(lease, owner_token, now)
      ensure_coordination_lease!(lease, :ready, scope)

      SQL.query!(
        Repo,
        "SELECT set_config('maraithon.agent_lease_owner_token', $1, true)",
        [owner_token],
        log: false
      )

      lease.lease_until
    else
      _invalid -> Repo.rollback(:runtime_not_ready)
    end
  end

  @doc "Lists a bounded page of runnable Agents with no durable lease or recovery marker."
  def list_unowned_runnable_ids(limit \\ 100)

  def list_unowned_runnable_ids(limit) when is_integer(limit) and limit in 1..500 do
    from(agent in Agent,
      as: :agent,
      join: binding in Binding,
      on:
        binding.agent_id == agent.id and binding.user_id == agent.user_id and
          binding.status == "active",
      left_join: lease in AgentRuntimeLease,
      on: lease.agent_id == agent.id,
      left_join: guard in AgentRestartGuard,
      on: guard.agent_id == agent.id,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == agent.id,
      left_join: termination in AgentTerminationIncident,
      on: termination.agent_id == agent.id and termination.status in ["requested", "proven"],
      where: agent.status in ^@runnable_statuses,
      where: agent.install_status == "enabled",
      where: is_nil(lease.agent_id),
      where: is_nil(operation.agent_id),
      where: is_nil(termination.id),
      where:
        is_nil(guard.agent_id) or
          (guard.tripped == false and guard.needs_recovery == false and
             (is_nil(guard.blocked_until) or
                guard.blocked_until <= fragment("timezone('UTC', clock_timestamp())"))),
      order_by: [asc: agent.updated_at, asc: agent.id],
      limit: ^limit,
      select: agent.id
    )
    |> Scope.all_ready_agent()
  end

  def list_unowned_runnable_ids(_limit), do: []

  @doc "Lists bootstrap candidates inside the current ready partitions."
  def list_bootstrap_agents do
    case Protocol.mode() do
      :dark ->
        []

      :active ->
        case Scope.current() do
          {:ok, session} ->
            from(agent in Agent,
              as: :agent,
              left_join: operation in AgentLifecycleOperation,
              on: operation.agent_id == agent.id,
              where: agent.status in ["recovering", "running", "degraded"],
              where: is_nil(agent.removed_at),
              where: is_nil(operation.agent_id),
              order_by: [asc: agent.updated_at, asc: agent.id],
              select: agent
            )
            |> Scope.scope_ready_agent(session)
            |> Repo.all()

          _missing_or_stale_session ->
            []
        end

      _blocked ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def get(agent_id) do
    case cast_uuid(agent_id) do
      {:ok, agent_id} -> Repo.get(AgentRuntimeLease, agent_id)
      {:error, :invalid_runtime_lease} -> nil
    end
  end

  defp owner_query(agent_id, owner_token) do
    from(lease in AgentRuntimeLease,
      as: :lease,
      join: agent in Agent,
      as: :agent,
      on: agent.id == lease.agent_id,
      where: lease.agent_id == ^agent_id,
      where: lease.owner_token == ^owner_token,
      where: lease.lease_until > fragment("timezone('UTC', clock_timestamp())")
    )
  end

  defp ready_query(agent_id, owner_token) do
    from(lease in AgentRuntimeLease,
      as: :lease,
      join: agent in Agent,
      as: :agent,
      on: agent.id == lease.agent_id,
      join: binding in Binding,
      on: binding.agent_id == agent.id and binding.user_id == agent.user_id,
      left_join: guard in AgentRestartGuard,
      on: guard.agent_id == agent.id,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == agent.id,
      where: lease.agent_id == ^agent_id,
      where: lease.owner_token == ^owner_token,
      where: lease.lease_until > fragment("timezone('UTC', clock_timestamp())"),
      where: not is_nil(lease.ready_at),
      where: is_nil(lease.draining_at),
      where: agent.install_status == "enabled",
      where: agent.status in ^@runnable_statuses,
      where: not is_nil(agent.user_id),
      where: binding.status == "active",
      where: is_nil(operation.agent_id),
      where:
        is_nil(guard.agent_id) or
          (guard.tripped == false and guard.needs_recovery == false and
             (is_nil(guard.blocked_until) or
                guard.blocked_until <= fragment("timezone('UTC', clock_timestamp())")))
    )
  end

  defp with_termination_capability(agent_id, owner_token, opts, fun)
       when is_function(fun, 1) do
    with {:ok, digest, prepared} <-
           prepare_termination_capability(agent_id, owner_token, opts) do
      try do
        case fun.(digest) do
          {:ok,
           %AgentRuntimeLease{
             agent_id: ^agent_id,
             owner_token: ^owner_token,
             termination_capability_digest: ^digest
           }} = result ->
            result

          {:error, reason} = result ->
            if definite_claim_rollback?(reason) do
              discard_termination_capability(prepared)
              result
            else
              settle_uncertain_claim(
                agent_id,
                owner_token,
                digest,
                prepared,
                {:returned, result}
              )
            end

          uncertain_result ->
            settle_uncertain_claim(
              agent_id,
              owner_token,
              digest,
              prepared,
              {:returned, uncertain_result}
            )
        end
      rescue
        error ->
          settle_uncertain_claim(
            agent_id,
            owner_token,
            digest,
            prepared,
            {:raised, :error, error, __STACKTRACE__}
          )
      catch
        kind, reason ->
          settle_uncertain_claim(
            agent_id,
            owner_token,
            digest,
            prepared,
            {:raised, kind, reason, __STACKTRACE__}
          )
      end
    end
  end

  # Repo.rollback/1 returns its business reason only after rollback completes.
  # Adapter-level rollback/connection errors are not evidence that COMMIT failed.
  defp definite_claim_rollback?(:rollback), do: false
  defp definite_claim_rollback?(%DBConnection.ConnectionError{}), do: false
  defp definite_claim_rollback?(%DBConnection.TransactionError{}), do: false
  defp definite_claim_rollback?(_business_reason), do: true

  defp settle_uncertain_claim(agent_id, owner_token, digest, prepared, original_outcome) do
    case authoritative_claim_resolution(agent_id, owner_token, digest) do
      {:committed, lease} ->
        {:ok, lease}

      :confirmed_absent ->
        discard_termination_capability(prepared)
        resume_confirmed_absence(original_outcome)

      status when status in [:mismatch, :unavailable] ->
        # A live caller must not proactively orphan a possibly committed digest.
        # The caller-bound preparation remains bounded by controller DOWN and TTL.
        fail_uncertain_claim(original_outcome)
    end
  end

  defp authoritative_claim_resolution(agent_id, owner_token, digest) do
    # Claim holds the existing Agent row through COMMIT. Reacquiring that lock is
    # a commit barrier: an in-flight original transaction must first commit or
    # abort, so a subsequent missing lease is authoritative rather than a
    # snapshot racing an unresolved COMMIT.
    case Repo.transaction(fn ->
           _agent = lock_agent!(agent_id)
           lock_lease(agent_id)
         end) do
      {:ok,
       %AgentRuntimeLease{
         agent_id: ^agent_id,
         owner_token: ^owner_token,
         termination_capability_digest: ^digest
       } = lease} ->
        {:committed, lease}

      {:ok, nil} ->
        :confirmed_absent

      {:ok, %AgentRuntimeLease{}} ->
        :mismatch

      {:error, _reason} ->
        :unavailable
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp resume_confirmed_absence({:raised, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp resume_confirmed_absence({:returned, {:error, _reason} = result}), do: result

  defp resume_confirmed_absence({:returned, _unexpected}) do
    {:error, :runtime_lease_claim_failed}
  end

  defp fail_uncertain_claim({:raised, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp fail_uncertain_claim({:returned, _unexpected}) do
    {:error, :runtime_lease_claim_ambiguous}
  end

  defp prepare_termination_capability(agent_id, owner_token, opts) do
    case Keyword.fetch(opts, :watcher) do
      {:ok, watcher} ->
        case AgentWatcher.prepare_lease_capability(watcher, agent_id, owner_token) do
          {:ok, digest} when is_binary(digest) and byte_size(digest) == 32 ->
            {:ok, digest, {watcher, agent_id, owner_token}}

          {:ok, _invalid_digest} ->
            discard_termination_capability({watcher, agent_id, owner_token})
            {:error, :invalid_agent_termination_capability}

          {:error, _reason} = error ->
            discard_termination_capability({watcher, agent_id, owner_token})
            error

          _other ->
            discard_termination_capability({watcher, agent_id, owner_token})
            {:error, :watcher_unavailable}
        end

      :error ->
        {:ok, nil, :external_proof_only}
    end
  end

  defp discard_termination_capability(:external_proof_only), do: :ok

  defp discard_termination_capability({watcher, agent_id, owner_token}) do
    _ = AgentWatcher.discard_lease_capability(watcher, agent_id, owner_token)
    :ok
  end

  defp insert_lease!(
         agent_id,
         owner_token,
         owner_node,
         termination_capability_digest,
         now,
         lease_until,
         coordination
       ) do
    coordination_attrs =
      case coordination do
        %{legacy?: true} ->
          %{}

        %{session: session, partition: partition} ->
          %{
            coordination_activation_epoch: session.activation_epoch,
            coordination_partition_id: partition.partition_id,
            coordination_partition_epoch: partition.ownership_epoch,
            coordination_node_incarnation_id: session.id
          }
      end

    %AgentRuntimeLease{inserted_at: now, updated_at: now}
    |> AgentRuntimeLease.changeset(
      Map.merge(
        %{
          agent_id: agent_id,
          owner_token: owner_token,
          owner_node: owner_node,
          termination_capability_digest: termination_capability_digest,
          claimed_at: now,
          renewed_at: now,
          lease_until: lease_until,
          ready_at: nil,
          draining_at: nil
        },
        coordination_attrs
      )
    )
    |> Repo.insert!()
  end

  defp prelock_new_agent!(agent_id, privacy_mode) do
    user_id =
      case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, select: agent.user_id)) do
        user_id when is_binary(user_id) -> user_id
        _ -> Repo.rollback(:agent_not_found)
      end

    coordination = coordination_scope!(user_id)

    if coordination do
      Authority.fence_partition!(
        coordination.session,
        coordination.partition.partition_id,
        coordination.partition.ownership_epoch,
        :ready
      )
    end

    lock_user_privacy!(user_id, privacy_mode)

    if coordination,
      do: Map.put(coordination, :user_id, user_id),
      else: %{legacy?: true, user_id: user_id}
  end

  defp prelock_existing_or_new!(agent_id, authority_mode, privacy_mode) do
    case Repo.get(AgentRuntimeLease, agent_id) do
      nil -> prelock_new_agent!(agent_id, privacy_mode)
      _lease -> prelock_existing_lease!(agent_id, authority_mode, privacy_mode)
    end
  end

  defp prelock_existing_lease!(agent_id, authority_mode, privacy_mode)
       when authority_mode in [:ready, :owner] do
    user_id =
      case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, select: agent.user_id)) do
        user_id when is_binary(user_id) -> user_id
        _ -> Repo.rollback(:agent_not_found)
      end

    lease =
      case Repo.get(AgentRuntimeLease, agent_id) do
        %AgentRuntimeLease{} = lease -> lease
        nil -> Repo.rollback(:runtime_lease_lost)
      end

    coordination_fields? =
      not is_nil(lease.coordination_activation_epoch) and
        not is_nil(lease.coordination_partition_id) and
        not is_nil(lease.coordination_partition_epoch) and
        not is_nil(lease.coordination_node_incarnation_id)

    scope_result = Scope.active_or_legacy()

    case {scope_result, coordination_fields?} do
      {:legacy, false} ->
        lock_user_privacy!(user_id, privacy_mode)
        %{legacy?: true, user_id: user_id}

      {{:ok, _current_session}, true} ->
        session = %NodeIncarnation{
          id: lease.coordination_node_incarnation_id,
          activation_epoch: lease.coordination_activation_epoch
        }

        Authority.fence_partition!(
          session,
          lease.coordination_partition_id,
          lease.coordination_partition_epoch,
          authority_mode
        )

        lock_user_privacy!(user_id, privacy_mode)

        %{
          session: session,
          partition: %{
            partition_id: lease.coordination_partition_id,
            ownership_epoch: lease.coordination_partition_epoch
          },
          user_id: user_id
        }

      _ ->
        Logger.warning("Agent lease partition scope refused",
          failure_code: prelock_scope_failure_class(scope_result, coordination_fields?)
        )

        Repo.rollback(:partition_authority_lost)
    end
  end

  defp prelock_scope_failure_class({:error, reason}, _fields?),
    do: Maraithon.Redaction.error_class(reason)

  defp prelock_scope_failure_class(:legacy, true), do: "legacy_scope_with_coordinated_lease"
  defp prelock_scope_failure_class({:ok, _session}, false), do: "coordinated_lease_fields_missing"
  defp prelock_scope_failure_class(_other, _fields?), do: "unknown_error"

  defp lock_user_privacy!(user_id, privacy_mode) do
    case SQL.query!(
           Repo,
           """
           SELECT to_jsonb(user_row) ->> 'privacy_erasure_requested_at'
           FROM public.users AS user_row WHERE id = $1 FOR UPDATE
           """,
           [user_id]
         ).rows do
      [[nil]] -> :ok
      [[_requested_at]] when privacy_mode == :settlement -> :ok
      [[_requested_at]] -> Repo.rollback(:privacy_erasure_requested)
      [] -> Repo.rollback(:agent_user_missing)
    end
  end

  defp ensure_scope_agent!(%Agent{user_id: user_id}, %{user_id: user_id}), do: :ok
  defp ensure_scope_agent!(_agent, _scope), do: Repo.rollback(:agent_authority_changed)

  defp prelock_settlement_agent!(agent_id) do
    user_id =
      case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, select: agent.user_id)) do
        user_id when is_binary(user_id) -> user_id
        _ -> Repo.rollback(:agent_not_found)
      end

    lock_user_privacy!(user_id, :settlement)
    user_id
  end

  defp ensure_settlement_authority!(
         %AgentRuntimeLease{agent_id: agent_id, owner_token: owner_token} = lease,
         agent_id,
         owner_token
       ) do
    if (not is_nil(lease.ready_at) or not is_nil(lease.draining_at)) and
         not is_nil(lease.coordination_activation_epoch) and
         not is_nil(lease.coordination_partition_id) and
         not is_nil(lease.coordination_partition_epoch) and
         not is_nil(lease.coordination_node_incarnation_id) do
      :ok
    else
      Repo.rollback(:runtime_lease_lost)
    end
  end

  defp ensure_settlement_authority!(lease, agent_id, owner_token) do
    if is_nil(lease) or lease.owner_token != owner_token do
      lock_reconciled_settlement_proof!(agent_id, owner_token)
    else
      Repo.rollback(:runtime_lease_lost)
    end
  end

  defp lock_reconciled_settlement_proof!(agent_id, owner_token) do
    incident =
      Repo.one(
        from(incident in AgentTerminationIncident,
          where: incident.agent_id == ^agent_id,
          where: incident.lease_token == ^owner_token,
          where: incident.status == "reconciled",
          where: not is_nil(incident.reconciled_at),
          lock: "FOR SHARE"
        )
      )

    proof =
      case incident do
        %AgentTerminationIncident{proof_id: proof_id} when is_binary(proof_id) ->
          Repo.one(
            from(proof in AgentTerminationProof,
              where: proof.id == ^proof_id,
              where: proof.incident_id == ^incident.id,
              lock: "FOR SHARE"
            )
          )

        _ ->
          nil
      end

    if exact_reconciled_settlement_proof?(incident, proof, agent_id, owner_token) do
      :ok
    else
      Repo.rollback(:runtime_lease_lost)
    end
  end

  defp exact_reconciled_settlement_proof?(
         %AgentTerminationIncident{} = incident,
         %AgentTerminationProof{} = proof,
         agent_id,
         owner_token
       ) do
    not is_nil(incident.activation_epoch) and
      not is_nil(incident.node_incarnation_id) and
      not is_nil(incident.partition_id) and
      not is_nil(incident.partition_epoch) and
      incident.agent_id == agent_id and incident.lease_token == owner_token and
      incident.proof_id == proof.id and proof.incident_id == incident.id and
      proof.agent_id == incident.agent_id and proof.lease_token == incident.lease_token and
      proof.activation_epoch == incident.activation_epoch and
      proof.node_incarnation_id == incident.node_incarnation_id and
      proof.partition_id == incident.partition_id and
      proof.partition_epoch == incident.partition_epoch and
      proof.proof_kind == incident.proof_kind and proof.proved_at == incident.proved_at
  end

  defp exact_reconciled_settlement_proof?(_incident, _proof, _agent_id, _owner_token),
    do: false

  defp coordination_scope!(user_id) do
    case Scope.active_or_legacy() do
      :legacy ->
        nil

      {:ok, _session} ->
        case Scope.partition_for_user(user_id) do
          {:ok, session, partition} -> %{session: session, partition: partition}
          _ -> Repo.rollback(:partition_not_owned)
        end

      {:error, blocked} ->
        Repo.rollback({:coordination_protocol_blocked, blocked})
    end
  end

  # The scope proven at prelock (before any row locks) supplies the session so
  # the fence never blocks on the coordination Session under those locks.
  defp ensure_coordination_lease!(lease, mode, %{session: %NodeIncarnation{} = session}),
    do: Scope.fence_lease!(lease, mode, session)

  defp ensure_coordination_lease!(lease, mode, _legacy_scope), do: Scope.fence_lease!(lease, mode)

  defp update_lease!(lease, updates) do
    lease
    |> Ecto.Changeset.change(updates)
    |> Repo.update!()
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_active_binding!(%Agent{} = agent) do
    case lock_binding(agent) do
      %Binding{status: "active"} = binding -> binding
      _missing_or_inactive -> Repo.rollback(:agent_binding_not_active)
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

  defp ensure_no_open_termination_incident!(nil), do: :ok

  defp ensure_no_open_termination_incident!(_incident),
    do: Repo.rollback(:agent_termination_unproven)

  defp ensure_no_lifecycle_operation!(nil), do: :ok
  defp ensure_no_lifecycle_operation!(_operation), do: Repo.rollback(:agent_drain_pending)

  defp ensure_exact_runtime_enabled! do
    case exact_runtime_enabled() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp exact_runtime_enabled do
    cond do
      not RuntimeConfig.exact_agent_runtime_enabled?() ->
        {:error, :exact_runtime_disabled}

      not RuntimeConfig.exact_agent_runtime_ready?() ->
        {:error, :effect_protocol_not_exact}

      true ->
        :ok
    end
  end

  defp ensure_runnable!(agent) do
    unless runnable?(agent), do: Repo.rollback(:agent_not_runnable)
  end

  defp runnable?(%Agent{user_id: user_id, install_status: "enabled", status: status})
       when is_binary(user_id) and status in @runnable_statuses,
       do: true

  defp runnable?(_agent), do: false

  defp ensure_binding_matches!(agent, binding) do
    unless binding_matches?(agent, binding), do: Repo.rollback(:agent_binding_not_active)
  end

  defp binding_matches?(
         %Agent{id: agent_id, user_id: user_id},
         %Binding{agent_id: agent_id, user_id: user_id, status: "active"}
       )
       when is_binary(user_id),
       do: true

  defp binding_matches?(_agent, _binding), do: false

  defp ensure_initial_guard_allows_claim!(nil, _now), do: :ok

  defp ensure_initial_guard_allows_claim!(%AgentRestartGuard{} = guard, now) do
    cond do
      guard.tripped -> Repo.rollback(:agent_restart_tripped)
      guard.needs_recovery -> Repo.rollback(:agent_recovery_required)
      blocked?(guard, now) -> Repo.rollback(:agent_restart_backoff)
      true -> :ok
    end
  end

  defp ensure_due_recovery_guard!(
         %AgentRestartGuard{
           generation: generation,
           needs_recovery: true,
           tripped: false
         } = guard,
         generation,
         now
       ) do
    if blocked?(guard, now), do: Repo.rollback(:agent_restart_backoff), else: :ok
  end

  defp ensure_due_recovery_guard!(%AgentRestartGuard{tripped: true}, _generation, _now),
    do: Repo.rollback(:agent_restart_tripped)

  defp ensure_due_recovery_guard!(_guard, _generation, _now),
    do: Repo.rollback(:stale_recovery_generation)

  defp ensure_no_existing_lease!(nil, _now), do: :ok

  defp ensure_no_existing_lease!(%AgentRuntimeLease{} = lease, now) do
    if DateTime.compare(lease.lease_until, now) == :gt,
      do: Repo.rollback(:runtime_lease_owned),
      else: Repo.rollback(:expired_lease_requires_reconciliation)
  end

  defp ensure_exact_live_lease!(
         %AgentRuntimeLease{owner_token: owner_token} = lease,
         owner_token,
         now
       ) do
    if DateTime.compare(lease.lease_until, now) == :gt,
      do: :ok,
      else: Repo.rollback(:runtime_lease_expired)
  end

  defp ensure_exact_live_lease!(_lease, _owner_token, _now),
    do: Repo.rollback(:runtime_lease_lost)

  defp ensure_exact_ready_lease!(lease, owner_token, now) do
    ensure_exact_live_lease!(lease, owner_token, now)

    if is_nil(lease.ready_at) or not is_nil(lease.draining_at),
      do: Repo.rollback(:runtime_not_ready),
      else: :ok
  end

  defp guard_allows_ready?(nil, _now), do: true

  defp guard_allows_ready?(%AgentRestartGuard{} = guard, now) do
    not guard.tripped and not guard.needs_recovery and not blocked?(guard, now)
  end

  defp blocked?(%AgentRestartGuard{blocked_until: nil}, _now), do: false

  defp blocked?(%AgentRestartGuard{blocked_until: blocked_until}, now),
    do: DateTime.compare(blocked_until, now) == :gt

  defp later_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp ensure_no_processing_directive!(agent_id, reason) do
    case Repo.one(
           from(directive in AgentDirective,
             where: directive.agent_id == ^agent_id,
             where: directive.status == "processing",
             lock: "FOR UPDATE"
           )
         ) do
      nil -> :ok
      _processing -> Repo.rollback(reason)
    end
  end

  defp owner_node(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:owner_node, :ttl_ms, :watcher])) do
      current_owner = Atom.to_string(node())
      owner_node = Keyword.get(opts, :owner_node, current_owner)

      if owner_node == current_owner and byte_size(owner_node) in 1..255 and
           String.valid?(owner_node) and
           not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, owner_node),
         do: {:ok, owner_node},
         else: {:error, :invalid_runtime_lease}
    else
      {:error, :invalid_runtime_lease}
    end
  end

  defp ttl_ms(opts, allowed_keys) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed_keys)) do
      ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

      if is_integer(ttl_ms) and ttl_ms in @min_ttl_ms..@max_ttl_ms,
        do: {:ok, ttl_ms},
        else: {:error, :invalid_runtime_lease}
    else
      {:error, :invalid_runtime_lease}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_runtime_lease}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_runtime_lease}

  defp require_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "runtime lease fences require the caller's database transaction"
    end
  end
end
