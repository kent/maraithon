defmodule Maraithon.Runtime.Coordination.WakeScopeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.WakeCoordinator

  alias Maraithon.Runtime.Coordination.{
    Authority,
    Partitioning,
    Protocol,
    Scope,
    Session
  }

  @revision String.duplicate("b", 40)
  @evidence_id "fly:machines-destroyed:wake-scope-test"
  @activated_by "wake-scope@example.test"
  @evidence_digest :crypto.hash(:sha256, "wake-scope-test-evidence")
  @activation_evidence [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @activated_by,
    revision: @revision
  ]

  setup do
    old_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      old_runtime
      |> Keyword.put(:exact_agent_runtime_enabled, true)
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.put(:allow_legacy_effect_protocol_in_test, false)
    )

    session =
      start_supervised!(
        {Session,
         tick_ms: 600_000,
         node_ttl_ms: 300_000,
         partition_ttl_ms: 300_000,
         required_workers: [__MODULE__.NeverReady]}
      )

    # The initial dark-protocol coordinate message is a mailbox barrier; no sleep.
    _ = :sys.get_state(session)

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, old_runtime)

      try do
        :sys.replace_state(session, fn state ->
          %{state | session: nil, leader: nil, phase: :dormant}
        end)
      catch
        :exit, {:noproc, _details} -> :ok
      end
    end)

    :ok
  end

  test "legacy Effect mode remains available while coordination is dark" do
    assert Protocol.mode() == :dark
    assert Scope.active_or_legacy() == :legacy
    assert AgentLeases.list_bootstrap_agents() == []

    assert {:ok, summary} = WakeCoordinator.reconcile_once()
    assert summary.gate == :closed
    assert summary.ownership == []
    assert summary.admissions == []
  end

  test "deployment handoff keeps the replacement Session dormant without crashing" do
    target_generation = "maraithon-d260904151500-c3d4e5f6"
    image_digest = "sha256:" <> String.duplicate("c", 64)
    previous_generation = System.get_env("K_REVISION")

    on_exit(fn ->
      if previous_generation,
        do: System.put_env("K_REVISION", previous_generation),
        else: System.delete_env("K_REVISION")
    end)

    System.put_env("K_REVISION", target_generation)
    activate_protocols!()
    set_role!("maraithon_migrator")

    assert {:ok, :armed} =
             Authority.arm_deployment_handoff(target_generation, image_digest)

    assert {:ok, :proven} =
             Authority.prove_deployment_handoff(target_generation, image_digest)

    set_role!("maraithon_runtime")
    session = Process.whereis(Session)
    monitor = Process.monitor(session)

    send(session, :coordinate)
    state = :sys.get_state(session)

    assert state.phase == :dormant
    assert state.session == nil
    assert Process.whereis(Session) == session
    refute_receive {:DOWN, ^monitor, :process, ^session, _reason}
  end

  test "proof-bound lifecycle DOWN converges every intentional action without crash recovery" do
    {user_a, user_b} = distinct_partition_users("expected-lifecycle")
    %{node_a: node_a} = active_two_node_authority!(user_a, user_b)
    put_session!(node_a)
    watcher = lifecycle_watcher!()

    Enum.each([:stop, :pause, :update, :upgrade, :remove, :delete], fn kind ->
      agent = create_bound_agent!(user_a)
      lease = AgentLeases.claim(agent.id, ttl_ms: 300_000, watcher: watcher) |> ok!()
      _ready = AgentLeases.mark_ready(agent.id, lease.owner_token) |> ok!()
      pid = registered_owner(agent.id, lease.owner_token)

      assert :ok = AgentWatcher.track(watcher, pid, agent.id, lease.owner_token)

      assert {:ok, fence} =
               AgentLifecycleOperations.begin(
                 agent.id,
                 kind,
                 %{"test_action" => Atom.to_string(kind)},
                 fn locked -> lifecycle_mutation(locked, kind) end
               )

      assert fence.operation.expected_owner_token == lease.owner_token
      down_ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^down_ref, :process, ^pid, :killed}, 1_000

      await_lifecycle_watcher_release(watcher, pid, 100)
      watcher_state = :sys.get_state(watcher)
      assert MapSet.size(watcher_state.recoveries) == 0

      assert AgentLeases.get(agent.id) == nil
      assert AgentRestartGuards.get(agent.id) == nil
      assert AgentLifecycleOperations.get(agent.id) == nil

      incident = AgentTerminations.get_by_lease(lease.owner_token)
      assert incident.status == "reconciled"
      assert AgentTerminations.proof_for(incident.id).proof_kind == "local_down"

      case kind do
        :delete ->
          assert Agents.get_agent(agent.id, include_removed: true) == nil

        :pause ->
          assert %{status: "stopped", install_status: "paused"} =
                   Agents.get_agent(agent.id, include_removed: true)

        :remove ->
          assert %{status: "stopped", install_status: "removed"} =
                   Agents.get_agent(agent.id, include_removed: true)

        resumed when resumed in [:update, :upgrade] ->
          assert %{status: "running"} = Agents.get_agent(agent.id, include_removed: true)
          # The proof handler's Wake pass is explicitly closed to admission.
          assert AgentLeases.get(agent.id) == nil

        :stop ->
          assert %{status: "stopped"} = Agents.get_agent(agent.id, include_removed: true)
      end
    end)
  end

  test "two ready nodes select disjoint due, recovery, and bootstrap work before LIMIT" do
    {user_a, user_b} = distinct_partition_users("selection")
    %{node_a: node_a, node_b: node_b} = active_two_node_authority!(user_a, user_b)

    # Insert B first so a global LIMIT 1 would starve A before an Elixir-side filter.
    agent_b = create_bound_agent!(user_b)
    directive_b = enqueue_due!(agent_b, "due-b")
    agent_a = create_bound_agent!(user_a)
    directive_a = enqueue_due!(agent_a, "due-a")
    order_directives!(directive_b.id, directive_a.id)

    recovery_b = create_bound_agent!(user_b)
    put_recovery_guard!(recovery_b)
    recovery_a = create_bound_agent!(user_a)
    put_recovery_guard!(recovery_a)

    put_session!(node_a)
    assert AgentDirectives.list_due_agent_ids(1) == [agent_a.id]
    assert AgentDirectives.list_recovery_agent_ids(1) == [recovery_a.id]
    assert AgentLeases.list_unowned_runnable_ids(1) == [agent_a.id]

    assert AgentLeases.list_bootstrap_agents() |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([agent_a.id, recovery_a.id])

    put_session!(node_b)
    assert AgentDirectives.list_due_agent_ids(1) == [agent_b.id]
    assert AgentDirectives.list_recovery_agent_ids(1) == [recovery_b.id]
    assert AgentLeases.list_unowned_runnable_ids(1) == [agent_b.id]

    assert AgentLeases.list_bootstrap_agents() |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([agent_b.id, recovery_b.id])
  end

  test "expired claims and recorded generations are partition exact while lease discovery is global" do
    {user_a, user_b} = distinct_partition_users("reconciliation")
    %{node_a: node_a, node_b: node_b} = active_two_node_authority!(user_a, user_b)

    claim_b = create_expired_claim!(node_b, user_b, "claim-b", 120)
    claim_a = create_expired_claim!(node_a, user_a, "claim-a", 60)
    claim_a_agent_id = claim_a.agent.id
    claim_a_directive_id = claim_a.directive.id
    claim_b_agent_id = claim_b.agent.id
    claim_b_directive_id = claim_b.directive.id

    put_session!(node_a)

    assert [{^claim_a_agent_id, ^claim_a_directive_id, {:ok, recovered_a}}] =
             AgentDirectives.reconcile_expired_claims(1)

    assert recovered_a.status == "pending"
    assert Repo.get!(AgentDirective, claim_b.directive.id).status == "processing"

    put_session!(node_b)

    assert [{^claim_b_agent_id, ^claim_b_directive_id, {:ok, recovered_b}}] =
             AgentDirectives.reconcile_expired_claims(1)

    assert recovered_b.status == "pending"

    ownership_b = create_expired_lease!(node_b, user_b, 120)
    ownership_a = create_expired_lease!(node_a, user_a, 60)
    ownership_a_agent_id = ownership_a.agent.id
    ownership_a_token = ownership_a.lease.owner_token
    ownership_b_agent_id = ownership_b.agent.id
    ownership_b_token = ownership_b.lease.owner_token

    put_session!(node_a)

    # Expired lease discovery is deliberately global and non-authorizing: the
    # oldest lease is found even though it belongs to node_b. The exact
    # guard/lease transaction below still rechecks every identity and DB clock.
    assert [
             {^ownership_b_agent_id, ^ownership_b_token, {:requested, incident_b},
              :termination_proof_required}
           ] = AgentDirectives.reconcile_expired_ownership(1, backoffs_ms: [0])

    assert incident_b.agent_id == ownership_b_agent_id
    assert incident_b.lease_token == ownership_b_token
    assert Repo.get!(AgentRuntimeLease, ownership_b.agent.id).owner_token == ownership_b_token
    assert Repo.get!(AgentRuntimeLease, ownership_a.agent.id).owner_token == ownership_a_token

    put_session!(node_b)

    assert [
             {^ownership_b_agent_id, ^ownership_b_token, {:duplicate, duplicate_b},
              :termination_proof_required},
             {^ownership_a_agent_id, ^ownership_a_token, {:requested, incident_a},
              :termination_proof_required}
           ] = AgentDirectives.reconcile_expired_ownership(2, backoffs_ms: [0])

    assert duplicate_b.id == incident_b.id
    assert incident_a.agent_id == ownership_a_agent_id
    assert incident_a.lease_token == ownership_a_token
    assert Repo.get!(AgentRuntimeLease, ownership_a.agent.id).owner_token == ownership_a_token

    recorded_b = create_recorded_generation!(node_b, user_b, "recorded-b", 120)
    recorded_a = create_recorded_generation!(node_a, user_a, "recorded-a", 60)
    recorded_a_agent_id = recorded_a.agent.id
    recorded_b_agent_id = recorded_b.agent.id

    put_session!(node_a)

    assert [{^recorded_a_agent_id, {:ok, settled_a}}] =
             AgentDirectives.reconcile_recorded_generations(1)

    assert settled_a.status == "pending"
    assert Repo.get!(AgentDirective, recorded_b.directive.id).status == "processing"

    put_session!(node_b)

    assert [{^recorded_b_agent_id, {:ok, settled_b}}] =
             AgentDirectives.reconcile_recorded_generations(1)

    assert settled_b.status == "pending"
  end

  test "stale ownership epochs and revoked node sessions return no wake work" do
    {user_a, user_b} = distinct_partition_users("stale")

    %{
      node_a: node_a,
      node_b: node_b,
      leader: leader,
      partition_a: partition_a
    } = active_two_node_authority!(user_a, user_b)

    agent = create_bound_agent!(user_a)
    directive = enqueue_due!(agent, "stale-due")
    put_session!(node_a)
    assert AgentDirectives.list_due_agent_ids(1) == [agent.id]

    assert {:ok, draining} =
             Authority.begin_partition_drain(leader, partition_a.partition_id,
               target_node_incarnation_id: node_b.id
             )

    assert draining.ownership_epoch == partition_a.ownership_epoch
    assert {:ok, :revoked} = Authority.revoke_partition_workload(node_a, partition_a.partition_id)

    assert {:ok, :released} =
             Authority.release_drained_partition(leader, partition_a.partition_id)

    assert {:ok, preparing} =
             Authority.assign_partition(leader, node_b, partition_a.partition_id, ttl_ms: 300_000)

    assert preparing.ownership_epoch == partition_a.ownership_epoch + 1
    assert {:ok, ready} = Authority.mark_partition_ready(node_b, partition_a.partition_id)

    # The synchronous handoff commits are PostgreSQL barriers. The cached old
    # session can no longer see the row after the ownership epoch advances.
    assert AgentDirectives.list_due_agent_ids(1) == []
    assert AgentLeases.list_unowned_runnable_ids(1) == []

    put_session!(node_b)
    assert AgentDirectives.list_due_agent_ids(1) == [agent.id]

    assert {:ok, :draining} = Authority.begin_node_drain(node_b)
    assert {:error, :coordination_session_stale} = Scope.current()
    assert AgentDirectives.list_due_agent_ids(1) == []
    assert AgentDirectives.list_recovery_agent_ids(1) == []
    assert AgentLeases.list_unowned_runnable_ids(1) == []
    assert AgentLeases.list_bootstrap_agents() == []

    assert {:ok,
            %{
              ownership: [],
              recorded: [],
              lifecycle: [],
              recoveries: [],
              admissions: [],
              tripped_effects: 0,
              gate: :closed
            }} = WakeCoordinator.reconcile_once(admit_recoveries: false, limit: 1)

    assert Repo.get!(AgentDirective, directive.id).status == "pending"
    assert ready.ownership_epoch == partition_a.ownership_epoch + 1
  end

  defp active_two_node_authority!(user_a, user_b) do
    activate_protocols!()
    set_role!("maraithon_runtime")

    node_a =
      Authority.register_node(revision: @revision, node_name: "wake-node-a", ttl_ms: 300_000)
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    node_b =
      Authority.register_node(revision: @revision, node_name: "wake-node-b", ttl_ms: 300_000)
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    leader =
      Authority.acquire_leader(node_a, 300_000) |> ok!() |> Authority.mark_leader_ready() |> ok!()

    partition_a = assign_user_partition!(leader, node_a, user_a)
    partition_b = assign_user_partition!(leader, node_b, user_b)

    %{
      node_a: node_a,
      node_b: node_b,
      leader: leader,
      partition_a: partition_a,
      partition_b: partition_b
    }
  end

  defp assign_user_partition!(leader, node, user_id) do
    partition_id = Partitioning.partition_for("user:" <> user_id)
    Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000) |> ok!()
    Authority.mark_partition_ready(node, partition_id) |> ok!()
  end

  defp activate_protocols! do
    set_role!("maraithon_activation_operator")

    assert {:ok, evidence_status} =
             Protocol.attest_effect_activation_evidence(@activation_evidence)

    assert evidence_status in [:attested, :already_attested]

    assert {:ok, effect_status} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
             )

    assert effect_status in [:activated, :already_active]
    assert {:ok, coordination_status} = Protocol.activate(coordination_activation_opts())
    assert coordination_status in [:activated, :already_active]
    reset_role!()
  end

  defp coordination_activation_opts do
    [confirmation: Protocol.activation_confirmation()] ++ @activation_evidence
  end

  defp create_bound_agent!(user_id) do
    reset_role!()
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    set_role!("maraithon_runtime")

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        install_status: "enabled",
        status: "running"
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    agent
  end

  defp enqueue_due!(agent, dedupe) do
    {:ok, directive} =
      AgentDirectives.enqueue(agent.id, agent.user_id, "message", %{"dedupe" => dedupe}, dedupe)

    directive
  end

  defp put_recovery_guard!(agent) do
    now = DatabaseClock.now!()

    %AgentRestartGuard{inserted_at: now, updated_at: now}
    |> AgentRestartGuard.changeset(%{
      agent_id: agent.id,
      generation: Ecto.UUID.generate(),
      last_owner_token: Ecto.UUID.generate(),
      blocked_until: nil,
      window_started_at: now,
      crash_count: 1,
      tripped: false,
      needs_recovery: true,
      last_reason: "scope_test"
    })
    |> Repo.insert!()
  end

  defp create_expired_claim!(node, user_id, dedupe, age_seconds) do
    agent = create_bound_agent!(user_id)
    _directive = enqueue_due!(agent, dedupe)
    put_session!(node)
    lease = AgentLeases.claim(agent.id, ttl_ms: 300_000) |> ok!()
    _ready = AgentLeases.mark_ready(agent.id, lease.owner_token) |> ok!()
    claimed = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token) |> ok!()

    Repo.query!(
      """
      UPDATE public.agent_directives
      SET claimed_at = timezone('UTC', clock_timestamp()) - ($2::bigint * interval '1 second'),
          claim_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(claimed.id), age_seconds]
    )

    %{agent: agent, directive: claimed, lease: lease}
  end

  defp create_expired_lease!(node, user_id, age_seconds) do
    agent = create_bound_agent!(user_id)
    put_session!(node)
    lease = AgentLeases.claim(agent.id, ttl_ms: 300_000) |> ok!()
    expire_lease!(agent.id, age_seconds)
    %{agent: agent, lease: lease}
  end

  defp create_recorded_generation!(node, user_id, dedupe, age_seconds) do
    agent = create_bound_agent!(user_id)
    _directive = enqueue_due!(agent, dedupe)
    put_session!(node)
    lease = AgentLeases.claim(agent.id, ttl_ms: 300_000) |> ok!()
    _ready = AgentLeases.mark_ready(agent.id, lease.owner_token) |> ok!()
    claimed = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token) |> ok!()
    expire_lease!(agent.id, age_seconds)

    assert {:requested, incident} =
             AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])

    attest_external_termination!(incident)
    assert {:recorded, _guard} = AgentTerminations.reconcile_incident(incident.id)

    %{agent: agent, directive: claimed, lease: lease}
  end

  defp expire_lease!(agent_id, age_seconds) do
    # Expiry is a test-only clock fixture. The runtime role intentionally has no
    # table-wide UPDATE grant after the exact column-ACL hardening.
    reset_role!()
    Repo.query!("SET LOCAL session_replication_role = replica", [])

    try do
      Repo.query!(
        """
        UPDATE public.agent_runtime_leases
        SET claimed_at = timezone('UTC', clock_timestamp()) - (($2::bigint + 2) * interval '1 second'),
            renewed_at = timezone('UTC', clock_timestamp()) - (($2::bigint + 1) * interval '1 second'),
            lease_until = timezone('UTC', clock_timestamp()) - ($2::bigint * interval '1 second'),
            ready_at = NULL, draining_at = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE agent_id = $1::uuid
        """,
        [Ecto.UUID.dump!(agent_id), age_seconds]
      )
    after
      Repo.query!("SET LOCAL session_replication_role = origin", [])
      set_role!("maraithon_runtime")
    end
  end

  defp order_directives!(older_id, newer_id) do
    Repo.query!(
      """
      UPDATE public.agent_directives
      SET available_at = CASE id
            WHEN $1::uuid THEN timezone('UTC', clock_timestamp()) - interval '2 minutes'
            ELSE timezone('UTC', clock_timestamp()) - interval '1 minute'
          END,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id IN ($1::uuid, $2::uuid)
      """,
      [Ecto.UUID.dump!(older_id), Ecto.UUID.dump!(newer_id)]
    )
  end

  defp put_session!(node) do
    :sys.replace_state(Session, fn state ->
      %{state | session: node, leader: nil, phase: :ready}
    end)

    assert %{phase: :ready, session: %{id: id}} = :sys.get_state(Session)
    assert id == node.id
    :ok
  end

  defp distinct_partition_users(prefix) do
    first = "#{prefix}-0@example.test"
    first_partition = Partitioning.partition_for("user:" <> first)

    second =
      1
      |> Stream.iterate(&(&1 + 1))
      |> Enum.find_value(fn number ->
        candidate = "#{prefix}-#{number}@example.test"

        if Partitioning.partition_for("user:" <> candidate) != first_partition,
          do: candidate,
          else: nil
      end)

    {first, second}
  end

  defp lifecycle_watcher! do
    name = String.to_atom("wake_scope_lifecycle_watcher_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AgentWatcher,
       name: name,
       reconcile?: false,
       recover?: false,
       poll_interval_ms: 60_000,
       reresume_backoffs: [0]}
    )

    name
  end

  defp registered_owner(agent_id, owner_token) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_token)
        send(parent, {:owner_registered, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owner_registered, ^pid, {:ok, _owner}}, 1_000
    pid
  end

  defp await_lifecycle_watcher_release(_watcher, _pid, 0),
    do: flunk("AgentWatcher did not reconcile the exact lifecycle DOWN")

  defp await_lifecycle_watcher_release(watcher, pid, attempts) do
    case :sys.get_state(watcher) do
      %{pids: pids, pending_downs: pending} when not is_map_key(pids, pid) ->
        if map_size(pending) == 0,
          do: :ok,
          else: await_lifecycle_watcher_release(watcher, pid, attempts - 1)

      _state ->
        await_lifecycle_watcher_release(watcher, pid, attempts - 1)
    end
  end

  defp attest_external_termination!(incident) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous = Application.get_env(:maraithon, AgentTerminations)

    Application.put_env(:maraithon, AgentTerminations,
      external_attestation_public_key: public_key
    )

    try do
      evidence_id = "wake-scope-destroyed:#{incident.lease_token}"
      digest = :crypto.hash(:sha256, "wake scope exact node destruction")
      proved_by = "wake-scope@example.test"
      payload = AgentTerminations.attestation_payload(incident, evidence_id, digest, proved_by)
      signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

      set_role!("maraithon_incident_operator")

      assert {:attested, _proof} =
               AgentTerminations.attest_external(incident.id, %{
                 evidence_id: evidence_id,
                 evidence_digest: digest,
                 signature: signature,
                 proved_by: proved_by
               })
    after
      set_role!("maraithon_runtime")

      if previous,
        do: Application.put_env(:maraithon, AgentTerminations, previous),
        else: Application.delete_env(:maraithon, AgentTerminations)
    end
  end

  defp lifecycle_mutation(agent, kind) when kind in [:update, :upgrade] do
    %{
      "action" => Atom.to_string(kind),
      "attrs" => %{
        "behavior" => agent.behavior,
        "config" => Map.put(agent.config || %{}, "lifecycle_test", Atom.to_string(kind))
      }
    }
  end

  defp lifecycle_mutation(_agent, kind), do: %{"action" => Atom.to_string(kind)}

  defp set_role!(role)
       when role in [
              "maraithon_runtime",
              "maraithon_migrator",
              "maraithon_activation_operator",
              "maraithon_incident_operator"
            ] do
    Repo.query!("SET LOCAL ROLE " <> role, [])
    :ok
  end

  defp reset_role! do
    Repo.query!("RESET ROLE", [])
    :ok
  end

  defp ok!({:ok, value}), do: value
end
