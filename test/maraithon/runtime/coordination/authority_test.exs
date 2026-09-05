defmodule Maraithon.Runtime.Coordination.AuthorityTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts.User
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobRunner}
  alias Maraithon.Runtime.Config

  alias Maraithon.Runtime.Coordination.{
    Authority,
    FairScheduler,
    Partitioning,
    Planner,
    Protocol,
    TaskAuthority,
    TaskClaims,
    TaskSupervisor,
    TaskTerminationAttestations
  }

  @revision String.duplicate("a", 40)
  @evidence_id "fly:machines-destroyed:test-evidence"
  @activated_by "operator@example.test"
  @evidence_digest :crypto.hash(:sha256, "non-secret-fleet-evidence")
  @evidence_digest_hex Base.encode16(@evidence_digest, case: :lower)
  @activation_evidence [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @activated_by,
    revision: @revision
  ]

  setup_all do
    {login, database} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        [[login, database]] =
          Repo.query!("SELECT session_user, current_database()", []).rows

        unless Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_$]*\z/, login) and
                 Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_$-]*\z/, database) do
          raise "unsafe PostgreSQL test role/database identity"
        end

        Repo.query!(
          ~s(ALTER ROLE "#{login}" IN DATABASE "#{database}" SET role TO maraithon_runtime),
          []
        )

        {login, database}
      end)

    restart_repo!()
    restart_task_system!()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SET ROLE NONE", [])
        Repo.query!(~s(ALTER ROLE "#{login}" IN DATABASE "#{database}" RESET role), [])
      end)

      restart_repo!()
    end)

    :ok
  end

  setup do
    # Reset application-owned capability/retry state before DataCase releases
    # this test's shared sandbox owner.
    on_exit(&restart_task_system!/0)
    :ok
  end

  test "direct SQL cannot activate before the catalog/backfill barrier" do
    attest_effect_protocol!()
    activate_effect_protocol!()

    defer_partition_catalog!()

    assert [[116]] =
             in_role!("maraithon_payload_verifier", fn ->
               Repo.query!("SELECT public.runtime_coordination_catalog_ready_count()", []).rows
             end)

    # Catch the expected check_violation inside a PostgreSQL subtransaction so
    # the outer SQL sandbox transaction remains usable.
    in_role!("maraithon_activation_operator", fn ->
      Repo.query!(
        """
        DO $block$
        DECLARE rejected boolean := false;
        BEGIN
          PERFORM set_config('maraithon.runtime_coordination_activation',
                             'ACTIVATE_PARTITION_FENCED_V1', true);
          BEGIN
            UPDATE public.runtime_coordination_protocols
            SET mode = 'partition_fenced_v1', activation_epoch = '00000000-0000-4000-8000-000000000001',
                activation_evidence_id = '#{@evidence_id}',
                activation_evidence_digest = decode('#{@evidence_digest_hex}', 'hex'),
                activated_by = '#{@activated_by}', exact_revision = '#{@revision}',
                updated_at = timezone('UTC', clock_timestamp())
            WHERE name = 'runtime';
          EXCEPTION WHEN check_violation THEN
            rejected := true;
          END;
          IF NOT rejected THEN RAISE EXCEPTION 'unsafe activation unexpectedly succeeded'; END IF;
        END
        $block$;
        """,
        []
      )
    end)

    assert [["dark"]] = Repo.query!("SELECT mode FROM runtime_coordination_protocols", []).rows
    finalize_partition_catalog!()

    assert [[120]] =
             in_role!("maraithon_payload_verifier", fn ->
               Repo.query!("SELECT public.runtime_coordination_catalog_ready_count()", []).rows
             end)

    assert {:ok, :activated} = activate_coordination!()
  end

  test "ACL readiness rejects every single forbidden privilege" do
    forbidden = [
      {"maraithon_runtime", "runtime_coordination_protocols", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_runtime", "effect_execution_protocols", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_runtime", "runtime_coordination_manifests", ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_runtime", "runtime_task_assignments", ~w(UPDATE)},
      {"maraithon_runtime", "agent_runtime_leases", ~w(UPDATE)},
      {"maraithon_runtime", "runtime_task_outcome_evidence", ~w(UPDATE DELETE TRUNCATE)},
      {"maraithon_runtime", "runtime_task_termination_proofs", ~w(UPDATE DELETE TRUNCATE)},
      {"maraithon_runtime", "effect_termination_attestations", ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_task_outcome_evidence",
       ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_coordination_protocols",
       ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_node_incarnations", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_partitions", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_task_assignments", ~w(UPDATE)},
      {"maraithon_incident_operator", "effect_termination_attestations",
       ~w(UPDATE DELETE TRUNCATE)},
      {"maraithon_activation_operator", "runtime_task_assignments", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_activation_operator", "runtime_task_termination_proofs",
       ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_payload_verifier", "runtime_task_outcome_evidence",
       ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_payload_verifier", "runtime_task_termination_proofs",
       ~w(INSERT UPDATE DELETE TRUNCATE)}
    ]

    assert [[true]] = Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows

    Enum.each(forbidden, fn {role, table, privileges} ->
      Enum.each(privileges, fn privilege ->
        # GRANT/REVOKE is not necessarily an ACL-preserving round trip when a
        # role also owns reviewed column grants. Roll back the whole probe to
        # restore the exact original ACL projection.
        assert {:error, :acl_probe_complete} =
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL ROLE maraithon_migrator", [])
                   Repo.query!("GRANT #{privilege} ON TABLE public.#{table} TO #{role}", [])
                   Repo.query!("SET LOCAL ROLE maraithon_runtime", [])

                   assert [[false]] =
                            Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows,
                          "ACL readiness accepted #{privilege} on #{table} for #{role}"

                   Repo.rollback(:acl_probe_complete)
                 end)

        assert [[true]] = Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows
      end)
    end)

    Enum.each(
      [
        {"maraithon_runtime", "runtime_task_assignments"},
        {"maraithon_runtime", "agent_runtime_leases"},
        {"maraithon_incident_operator", "runtime_task_assignments"},
        {"maraithon_incident_operator", "agent_runtime_leases"}
      ],
      fn {role, table} ->
        assert {:error, :acl_probe_complete} =
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL ROLE maraithon_migrator", [])

                   Repo.query!(
                     "GRANT UPDATE (termination_capability_digest) ON TABLE public.#{table} TO #{role}",
                     []
                   )

                   Repo.query!("SET LOCAL ROLE maraithon_runtime", [])

                   assert [[false]] =
                            Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows,
                          "ACL readiness accepted termination capability mutation on #{table} for #{role}"

                   Repo.rollback(:acl_probe_complete)
                 end)

        assert [[true]] = Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows
      end
    )
  end

  test "exact Agent readiness stays closed while coordination is dark" do
    attest_effect_protocol!()
    activate_effect_protocol!()
    old = Application.get_env(:maraithon, Maraithon.Runtime, [])
    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, old) end)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      old
      |> Keyword.put(:exact_agent_runtime_enabled, true)
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.put(:allow_legacy_effect_protocol_in_test, false)
    )

    assert Protocol.mode() == :dark
    refute Config.exact_agent_runtime_ready?()
  end

  test "durable deployment gate serializes drain, replacement, and successor admission" do
    target_generation = "maraithon-d260904150500-a1b2c3d4"
    image_digest = "sha256:" <> String.duplicate("b", 64)
    recovery_generation = "maraithon-d260904151000-e5f6a7b8"
    recovery_image_digest = "sha256:" <> String.duplicate("d", 64)

    attest_effect_protocol!()
    activate_effect_protocol!()
    finalize_partition_catalog!()
    assert {:ok, :activated} = activate_coordination!()

    current =
      Authority.register_node(
        revision: @revision,
        node_name: "deployment-current",
        ttl_ms: 300_000
      )
      |> ok!()

    current = Authority.mark_node_ready(current) |> ok!()

    waiting =
      Authority.register_node(
        revision: @revision,
        node_name: "deployment-waiting",
        ttl_ms: 300_000
      )
      |> ok!()

    assert {:ok, :armed} =
             in_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(target_generation, image_digest)
             end)

    forged_marker_id = Ecto.UUID.generate()

    in_role!("maraithon_migrator", fn ->
      Repo.query!(
        """
        DO $deployment_gate_probe$
        DECLARE rejected boolean := false;
        BEGIN
          PERFORM set_config(
            'maraithon.runtime_deployment_action', '#{forged_marker_id}', true
          );

          BEGIN
            INSERT INTO public.runtime_node_incarnations
              (id, activation_epoch, node_name, revision, state, lease_expires_at,
               revoked_at, metadata, inserted_at, updated_at)
            SELECT '#{forged_marker_id}'::uuid, protocol.activation_epoch,
                   '__maraithon_deployment_gate__', protocol.exact_revision, 'revoked',
                   timezone('UTC', clock_timestamp()),
                   timezone('UTC', clock_timestamp()),
                   pg_catalog.jsonb_build_object(
                     'kind', 'deployment_gate',
                     'sequence', 2,
                     'state', 'deploying',
                     'target_generation', '#{target_generation}',
                     'stable_generation', 'legacy',
                     'previous_generation', 'legacy',
                     'image_digest', '#{image_digest}'
                   ),
                   timezone('UTC', clock_timestamp()),
                   timezone('UTC', clock_timestamp())
            FROM public.runtime_coordination_protocols AS protocol
            WHERE protocol.name = 'runtime';
          EXCEPTION WHEN check_violation THEN
            rejected := true;
          END;

          IF NOT rejected THEN
            RAISE EXCEPTION 'non-quiescent deployment proof unexpectedly succeeded';
          END IF;
        END;
        $deployment_gate_probe$;
        """,
        []
      )
    end)

    assert [["handoff"]] =
             Repo.query!(
               """
               SELECT metadata ->> 'state'
               FROM public.runtime_node_incarnations
               WHERE node_name = '__maraithon_deployment_gate__'
               ORDER BY (metadata ->> 'sequence')::bigint DESC
               LIMIT 1
               """,
               []
             ).rows

    assert {:error, :deployment_admission_closed} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-late-legacy",
               ttl_ms: 300_000
             )

    assert {:error, :deployment_admission_closed} = Authority.mark_node_ready(waiting)

    assert {:ok, :draining} = Authority.begin_node_drain(current)
    assert {:ok, :draining} = Authority.begin_node_drain(waiting)

    assert {:ok, :proven} =
             in_role!("maraithon_migrator", fn ->
               Authority.prove_deployment_handoff(target_generation, image_digest)
             end)

    assert {:error, :deployment_admission_closed} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-early-successor",
               ttl_ms: 300_000,
               metadata: %{"deployment_generation" => target_generation}
             )

    assert Authority.deployment_gate_status() == %{
             state: "deploying",
             target_generation: target_generation,
             stable_generation: "legacy",
             image_digest: image_digest
           }

    assert {:error, {:deployment_generation_not_activating, "deploying"}} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.stabilize_deployment_generation(target_generation, image_digest)
             end)

    assert {:ok, :activated} =
             in_role!("maraithon_migrator", fn ->
               Authority.activate_deployment_generation(target_generation, image_digest)
             end)

    assert {:ok, :already_activating} =
             in_role!("maraithon_migrator", fn ->
               Authority.activate_deployment_generation(target_generation, image_digest)
             end)

    assert Authority.deployment_gate_status() == %{
             state: "activating",
             target_generation: target_generation,
             stable_generation: "legacy",
             image_digest: image_digest
           }

    forged_stable_marker_id = Ecto.UUID.generate()

    in_role!("maraithon_migrator", fn ->
      Repo.query!(
        """
        DO $deployment_stable_probe$
        DECLARE rejected boolean := false;
        BEGIN
          PERFORM set_config(
            'maraithon.runtime_deployment_action', '#{forged_stable_marker_id}', true
          );

          BEGIN
            INSERT INTO public.runtime_node_incarnations
              (id, activation_epoch, node_name, revision, state, lease_expires_at,
               revoked_at, metadata, inserted_at, updated_at)
            SELECT '#{forged_stable_marker_id}'::uuid, protocol.activation_epoch,
                   '__maraithon_deployment_gate__', protocol.exact_revision, 'revoked',
                   timezone('UTC', clock_timestamp()),
                   timezone('UTC', clock_timestamp()),
                   pg_catalog.jsonb_build_object(
                     'kind', 'deployment_gate',
                     'sequence', 4,
                     'state', 'stable',
                     'target_generation', '#{target_generation}',
                     'stable_generation', '#{target_generation}',
                     'previous_generation', 'legacy',
                     'image_digest', '#{image_digest}'
                   ),
                   timezone('UTC', clock_timestamp()),
                   timezone('UTC', clock_timestamp())
            FROM public.runtime_coordination_protocols AS protocol
            WHERE protocol.name = 'runtime';
          EXCEPTION WHEN check_violation THEN
            rejected := true;
          END;

          IF NOT rejected THEN
            RAISE EXCEPTION 'unready deployment stabilization unexpectedly succeeded';
          END IF;
        END;
        $deployment_stable_probe$;
        """,
        []
      )
    end)

    assert {:error, :deployment_generation_not_ready} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.stabilize_deployment_generation(target_generation, image_digest)
             end)

    activating =
      Authority.register_node(
        revision: @revision,
        node_name: "deployment-activating",
        ttl_ms: 300_000,
        metadata: %{"deployment_generation" => target_generation}
      )
      |> ok!()

    activating = Authority.mark_node_ready(activating) |> ok!()

    assert {:error, :deployment_generation_not_ready} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.stabilize_deployment_generation(target_generation, image_digest)
             end)

    assert {:error, :deployment_admission_closed} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-activating-legacy",
               ttl_ms: 300_000
             )

    assert {:error, {:deployment_handoff_not_quiescent, %{"no_live_nodes" => false}}} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.retarget_deployment_handoff(
                 target_generation,
                 image_digest,
                 recovery_generation,
                 recovery_image_digest
               )
             end)

    assert {:ok, :draining} = Authority.begin_node_drain(activating)

    assert {:ok, :retargeted} =
             in_role!("maraithon_migrator", fn ->
               Authority.retarget_deployment_handoff(
                 target_generation,
                 image_digest,
                 recovery_generation,
                 recovery_image_digest
               )
             end)

    assert {:ok, :already_retargeted} =
             in_role!("maraithon_migrator", fn ->
               Authority.retarget_deployment_handoff(
                 target_generation,
                 image_digest,
                 recovery_generation,
                 recovery_image_digest
               )
             end)

    assert {:error, :deployment_handoff_irreversible} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.abort_deployment_handoff(recovery_generation, recovery_image_digest)
             end)

    assert {:error, :deployment_admission_closed} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-early-recovery",
               ttl_ms: 300_000,
               metadata: %{"deployment_generation" => recovery_generation}
             )

    assert {:ok, :activated} =
             in_role!("maraithon_migrator", fn ->
               Authority.activate_deployment_generation(
                 recovery_generation,
                 recovery_image_digest
               )
             end)

    recovery =
      Authority.register_node(
        revision: @revision,
        node_name: "deployment-activating-recovery",
        ttl_ms: 300_000,
        metadata: %{"deployment_generation" => recovery_generation}
      )
      |> ok!()

    recovery = Authority.mark_node_ready(recovery) |> ok!()
    assert %Maraithon.Runtime.Coordination.NodeIncarnation{state: "ready"} = recovery

    ready_all_partitions!(recovery)

    assert {:ok, :stabilized} =
             in_role!("maraithon_migrator", fn ->
               Authority.stabilize_deployment_generation(
                 recovery_generation,
                 recovery_image_digest
               )
             end)

    assert Authority.deployment_gate_status() == %{
             state: "stable",
             target_generation: recovery_generation,
             stable_generation: recovery_generation,
             image_digest: recovery_image_digest
           }

    assert %Maraithon.Runtime.Coordination.NodeIncarnation{} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-successor",
               ttl_ms: 300_000,
               metadata: %{"deployment_generation" => recovery_generation}
             )
             |> ok!()

    assert {:error, :deployment_admission_closed} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-stale-legacy",
               ttl_ms: 300_000
             )

    assert {:error, :deployment_generation_already_used} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(target_generation, image_digest)
             end)

    assert {:error, :deployment_generation_already_used} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(
                 recovery_generation,
                 recovery_image_digest
               )
             end)
  end

  test "aborting a handoff preserves the failed target while reopening the stable generation" do
    failed_generation = "maraithon-d260904152000-a1b2c3d4"
    failed_image_digest = "sha256:" <> String.duplicate("e", 64)
    next_generation = "maraithon-d260904152500-e5f6a7b8"
    next_image_digest = "sha256:" <> String.duplicate("f", 64)

    attest_effect_protocol!()
    activate_effect_protocol!()
    finalize_partition_catalog!()
    assert {:ok, :activated} = activate_coordination!()

    assert {:ok, :armed} =
             in_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(failed_generation, failed_image_digest)
             end)

    assert {:ok, :aborted} =
             in_role!("maraithon_migrator", fn ->
               Authority.abort_deployment_handoff(failed_generation, failed_image_digest)
             end)

    assert [[metadata]] =
             Repo.query!(
               """
               SELECT metadata
               FROM public.runtime_node_incarnations
               WHERE node_name = '__maraithon_deployment_gate__'
               ORDER BY (metadata ->> 'sequence')::bigint DESC
               LIMIT 1
               """,
               []
             ).rows

    assert metadata == %{
             "image_digest" => failed_image_digest,
             "kind" => "deployment_gate",
             "previous_generation" => "legacy",
             "sequence" => 2,
             "stable_generation" => "legacy",
             "state" => "aborted",
             "target_generation" => failed_generation
           }

    assert {:ok, :already_aborted} =
             in_role!("maraithon_migrator", fn ->
               Authority.abort_deployment_handoff(failed_generation, failed_image_digest)
             end)

    assert %Maraithon.Runtime.Coordination.NodeIncarnation{} =
             Authority.register_node(
               revision: @revision,
               node_name: "deployment-restored-legacy",
               ttl_ms: 300_000
             )
             |> ok!()

    assert {:error, :deployment_generation_already_used} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(failed_generation, failed_image_digest)
             end)

    assert {:ok, :armed} =
             in_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(next_generation, next_image_digest)
             end)
  end

  test "handoff recovery reclaims expired ready and preparing authority" do
    target_generation = "maraithon-d260904153000-a1b2c3d4"
    image_digest = "sha256:" <> String.duplicate("9", 64)

    attest_effect_protocol!()
    activate_effect_protocol!()
    finalize_partition_catalog!()
    assert {:ok, :activated} = activate_coordination!()

    source =
      Authority.register_node(
        revision: @revision,
        node_name: "deployment-vanished-source",
        ttl_ms: 300_000
      )
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    source_leader = Authority.acquire_leader(source, 300_000) |> ok!()
    source_leader = Authority.mark_leader_ready(source_leader) |> ok!()
    ready_partition_id = 0
    preparing_partition_id = 1

    Authority.assign_partition(source_leader, source, ready_partition_id, ttl_ms: 300_000)
    |> ok!()

    Authority.mark_partition_ready(source, ready_partition_id) |> ok!()

    assert %Maraithon.Runtime.Coordination.Partition{state: "preparing"} =
             Authority.assign_partition(
               source_leader,
               source,
               preparing_partition_id,
               ttl_ms: 300_000
             )
             |> ok!()

    forged_leader_token = Ecto.UUID.generate()
    forged_node_token = Ecto.UUID.generate()

    in_role!("maraithon_runtime", fn ->
      Repo.query!(
        """
        DO $preparing_drain_probe$
        DECLARE
          attempted_state text;
          rejected boolean;
          rejection_message text;
        BEGIN
          PERFORM set_config(
            'maraithon.runtime_leader_action', '#{forged_leader_token}', true
          );
          PERFORM set_config(
            'maraithon.runtime_node_action', '#{forged_node_token}', true
          );

          FOREACH attempted_state IN ARRAY ARRAY['draining', 'blocked'] LOOP
            rejected := false;
            rejection_message := NULL;

            BEGIN
              UPDATE public.runtime_partitions
              SET state = attempted_state, ready_at = NULL,
                  draining_at = timezone('UTC', clock_timestamp()),
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = #{preparing_partition_id};
            EXCEPTION WHEN check_violation THEN
              GET STACKED DIAGNOSTICS rejection_message = MESSAGE_TEXT;
              rejected := true;
            END;

            IF NOT rejected THEN
              RAISE EXCEPTION
                'unfenced preparing partition transition to % unexpectedly succeeded',
                attempted_state;
            ELSIF rejection_message IS DISTINCT FROM
                    'partition drain requires exact leader or owner incarnation' THEN
              RAISE EXCEPTION
                'unfenced preparing partition transition to % was rejected for the wrong reason: %',
                attempted_state, rejection_message;
            END IF;
          END LOOP;
        END;
        $preparing_drain_probe$;
        """,
        []
      )
    end)

    assert [["preparing"]] =
             Repo.query!(
               "SELECT state FROM public.runtime_partitions WHERE partition_id = $1",
               [preparing_partition_id]
             ).rows

    assert {:ok, :armed} =
             in_role!("maraithon_migrator", fn ->
               Authority.arm_deployment_handoff(target_generation, image_digest)
             end)

    assert {:error,
            {:deployment_handoff_not_quiescent,
             %{
               "no_live_nodes" => false,
               "no_live_leader" => false,
               "no_admitting_partitions" => false
             }}} =
             with_session_role!("maraithon_migrator", fn ->
               Authority.prove_deployment_handoff(target_generation, image_digest)
             end)

    expire_deployment_topology!(
      source,
      source_leader,
      [ready_partition_id, preparing_partition_id]
    )

    assert {:ok, :proven} =
             in_role!("maraithon_migrator", fn ->
               Authority.prove_deployment_handoff(target_generation, image_digest)
             end)

    assert {:ok, :activated} =
             in_role!("maraithon_migrator", fn ->
               Authority.activate_deployment_generation(target_generation, image_digest)
             end)

    recovery =
      Authority.register_node(
        revision: @revision,
        node_name: "deployment-expired-authority-recovery",
        ttl_ms: 300_000,
        metadata: %{"deployment_generation" => target_generation}
      )
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    recovery_leader = Authority.acquire_leader(recovery, 300_000) |> ok!()
    recovery_leader = Authority.mark_leader_ready(recovery_leader) |> ok!()

    assert {:ok, %{expired: 2}} = Planner.plan_once(recovery_leader, limit: 2)
    assert {:ok, %{finalized: 2}} = Planner.plan_once(recovery_leader, limit: 2)

    for partition_id <- [ready_partition_id, preparing_partition_id] do
      Authority.assign_partition(
        recovery_leader,
        recovery,
        partition_id,
        ttl_ms: 300_000
      )
      |> ok!()

      assert %Maraithon.Runtime.Coordination.Partition{state: "ready"} =
               Authority.mark_partition_ready(recovery, partition_id) |> ok!()
    end
  end

  test "tenant concurrency is fair and deterministic under concurrent backlog" do
    %{node: node, partitions: partitions} = active_authority!(~w(tenant-a tenant-b))
    insert_user!("tenant-a")
    insert_user!("tenant-b")
    Enum.each(1..3, fn n -> insert_job!("tenant-a", "a-#{n}") end)
    insert_job!("tenant-b", "b-1")

    assert {:ok, {first, _assignment_a, _identity_a}} =
             FairScheduler.reserve_next(node, partitions)

    assert first.tenant_key == "user:tenant-a"
    assert first.payload == %{"dedupe" => "a-1"}

    # Default max_concurrency=1 makes the second reservation rotate to the
    # other tenant rather than repeatedly serving the lexicographically first.
    assert {:ok, {second, _assignment_b, _identity_b}} =
             FairScheduler.reserve_next(node, partitions)

    assert second.tenant_key == "user:tenant-b"
  end

  test "exact fair admission isolates generic, provider, and model lanes" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")

    generic = insert_job!("tenant-a", "generic", queue: "relationships")
    provider = insert_job!("tenant-a", "provider", queue: "runtime_provider_account")
    model = insert_job!("tenant-a", "model", queue: "runtime_model_user")

    assert {:ok, {reserved_model, _assignment, _identity}} =
             FairScheduler.reserve_next(node, partitions, queues: ["runtime_model_user"])

    assert reserved_model.id == model.id

    assert {:ok, {reserved_provider, _assignment, _identity}} =
             FairScheduler.reserve_next(node, partitions, queues: ["runtime_provider_account"])

    assert reserved_provider.id == provider.id

    assert {:ok, {reserved_generic, _assignment, _identity}} =
             FairScheduler.reserve_next(node, partitions,
               exclude_queues: ["runtime_provider_account", "runtime_model_user"]
             )

    assert reserved_generic.id == generic.id
  end

  test "exact fair admission runs independent source accounts together but keeps one account ordered" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")

    first = insert_job!("tenant-a", "source-account-one-first", partition_key: "source:one")

    assert {:ok, {reserved_first, _assignment, _identity}} =
             FairScheduler.reserve_next(node, partitions)

    assert reserved_first.id == first.id

    assert {:ok, _result} =
             FairScheduler.configure_tenant("user:tenant-a",
               max_concurrency: 3,
               rate_per_minute: 60,
               burst: 10
             )

    same_account =
      insert_job!("tenant-a", "source-account-one-second", partition_key: "source:one")

    other_account = insert_job!("tenant-a", "source-account-two", partition_key: "source:two")

    assert {:ok, {reserved_other, _assignment, _identity}} =
             FairScheduler.reserve_next(node, partitions)

    assert reserved_other.id == other_account.id
    assert {:ok, nil} = FairScheduler.reserve_next(node, partitions)
    assert Repo.get!(BackgroundJob, same_account.id).status == "pending"
  end

  test "commit-unknown background reservation clears only after locked absence" do
    %{node: _node, partitions: _partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "commit-unknown-background")
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()

    assert {:ok, identity} =
             TaskSupervisor.reserve("background_job", job.id, claim_token, assignment_id)

    assert {:ok, :uncommitted} = TaskAuthority.terminate_exact(identity)
    assert {:ok, :uncommitted} = TaskAuthority.terminate_exact(identity)
    assert TaskClaims.get(assignment_id) == nil
    assert Repo.get!(BackgroundJob, job.id).claim_token == nil
  end

  test "task reservation is capped by the earlier node lease" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    work_id = Ecto.UUID.generate()

    assert DateTime.compare(node.lease_expires_at, partition.lease_expires_at) == :lt

    assert {:ok, identity} =
             TaskSupervisor.reserve("background_job", work_id, claim_token, assignment_id)

    assert {:ok, assignment} =
             TaskClaims.reserve(node, partition, identity, ttl_ms: 300_000)

    assert assignment.lease_expires_at == node.lease_expires_at
    assert DateTime.compare(assignment.lease_expires_at, partition.lease_expires_at) == :lt
    assert {:ok, :never_activated} = TaskAuthority.terminate_exact(identity)
  end

  test "delayed commit-unknown cleanup accepts a clearly different background claim" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "commit-unknown-reclaimed-background")

    assert {:ok, stale_identity} =
             TaskSupervisor.reserve(
               "background_job",
               job.id,
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             )

    assert {:ok, {claimed_job, _assignment, current_identity}} =
             FairScheduler.reserve_next(node, partitions)

    assert claimed_job.id == job.id
    assert current_identity.claim_token != stale_identity.claim_token
    assert {:ok, :uncommitted} = TaskAuthority.terminate_exact(stale_identity)
    assert {:ok, :never_activated} = TaskAuthority.terminate_exact(current_identity)
  end

  test "local Task proof cannot be forged or bypassed by direct settlement" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    _job = insert_job!("tenant-a", "unforgeable-task-proof")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, partitions)

    assert byte_size(identity.termination_capability_digest) == 32

    assert [[digest]] =
             Repo.query!(
               "SELECT termination_capability_digest FROM runtime_task_assignments WHERE id = $1::uuid",
               [Ecto.UUID.dump!(assignment.id)]
             ).rows

    assert digest == identity.termination_capability_digest

    evidence_id = "task-supervisor:never_activated:#{assignment.local_task_id}"

    assert {:error, :local_task_termination_capability_required} =
             TaskClaims.record_local_termination(
               assignment,
               "never_activated",
               evidence_id
             )

    # The durable digest is public identity material, not the private preimage,
    # and replaying it as though it were the secret must fail.
    assert {:error, :task_termination_capability_mismatch} =
             TaskClaims.record_local_termination(
               assignment,
               "never_activated",
               evidence_id,
               digest
             )

    wrong_secret = :crypto.strong_rand_bytes(32)
    refute wrong_secret == digest
    encoded_candidate = Base.encode64(wrong_secret)
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maraithon, :repo, :query],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:repo_query_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :task_termination_capability_mismatch} =
             TaskClaims.record_local_termination(
               assignment,
               "never_activated",
               evidence_id,
               wrong_secret
             )

    refute_secret_telemetry(wrong_secret, encoded_candidate)
    assert TaskClaims.get(assignment.id).state == "reserved"

    reject_assignment_update!(
      assignment.id,
      "state = 'settled', settled_at = timezone('UTC', clock_timestamp()), " <>
        "outcome = 'cancelled_before_provider'"
    )

    parent = self()

    task =
      start_bound_task(identity, fn ->
        result = FairScheduler.activate_job(reserved_job, assignment)
        send(parent, {:unforgeable_task_running, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:unforgeable_task_running, {:ok, {_running_job, running_assignment}}}
    assert {:ok, requested} = TaskClaims.request_termination(running_assignment)
    assert requested.state == "termination_requested"

    reject_assignment_update!(
      assignment.id,
      "state = 'settled', settled_at = timezone('UTC', clock_timestamp()), " <>
        "outcome = 'cancelled_before_provider'"
    )

    send(task.pid, :finish)
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == task.ref
  end

  test "physical activation racing ahead of DB readiness proves never_activated" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    _job = insert_job!("tenant-a", "activation-race-never-activated")

    assert {:ok, {_reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, partitions)

    test_pid = self()

    task =
      start_bound_task(identity, fn ->
        send(test_pid, {:activation_race_physical_ready, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:activation_race_physical_ready, task_pid}, 2_000
    assert TaskClaims.get(assignment.id).state == "reserved"
    assert TaskClaims.get(assignment.id).ready_at == nil

    send(task_pid, :finish)
    assert_receive {:DOWN, ref, :process, ^task_pid, :normal} when ref == task.ref, 2_000

    # The controller-bound Authority asks Guardian to authenticate DOWN and
    # returns the durable canonical kind, not the transient physical observation.
    assert {:ok, :never_activated} = TaskAuthority.terminate_exact(identity)
    assert {:ok, :never_activated} = TaskAuthority.terminate_exact(identity)

    proven = TaskClaims.get(assignment.id)
    assert proven.state == "termination_proven"
    assert proven.outcome == nil
    assert {:ok, [_settled]} = TaskClaims.reconcile_proven()

    settled = TaskClaims.get(assignment.id)
    assert settled.state == "settled"
    assert settled.outcome == "cancelled_before_provider"

    assert [["never_activated", evidence_id]] =
             Repo.query!(
               """
               SELECT proof_kind, evidence_id
               FROM runtime_task_termination_proofs
               WHERE assignment_id = $1::uuid
               """,
               [Ecto.UUID.dump!(assignment.id)]
             ).rows

    assert evidence_id ==
             "task-supervisor:never_activated:#{assignment.local_task_id}"
  end

  test "owner crash after durable reserve aborts the never-activated incarnation" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "owner-crash")
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :reserve ->
            result = FairScheduler.reserve_next(node, [partition])
            send(parent, {:durably_reserved, result})
            receive do: (:crash_after_commit -> exit(:simulated_runner_crash))
        end
      end)

    # The gate keeps controller binding deterministic; this non-async DataCase
    # already runs its sandbox owner in shared mode for the child process.
    send(owner, :reserve)

    assert_receive {:durably_reserved, {:ok, {reserved_job, assignment, identity}}}, 2_000
    assert reserved_job.id == job.id
    owner_ref = Process.monitor(owner)
    send(owner, :crash_after_commit)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :simulated_runner_crash}
    _ = :sys.get_state(TaskAuthority)

    proven = TaskClaims.get(assignment.id)
    assert proven.state == "termination_proven"
    assert {:ok, [_settled]} = TaskClaims.reconcile_proven()

    final = TaskClaims.get(assignment.id)
    assert final.state == "settled"
    assert final.provider_boundary == "not_entered"
    assert final.outcome == "cancelled_before_provider"
    recovered_job = Repo.get!(BackgroundJob, job.id)
    assert recovered_job.status == "pending"
    assert is_nil(recovered_job.claim_token)
    assert is_nil(recovered_job.coordination_task_assignment_id)
    assert {:ok, :never_activated} = TaskSupervisor.terminate_exact(identity)
  end

  test "coupled supervisor restart proves a predecessor reservation never activated" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "predecessor")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, [partition])

    assert reserved_job.id == job.id

    old_authority = Process.whereis(TaskAuthority)
    old_ref = Process.monitor(old_authority)
    Process.exit(old_authority, :kill)
    assert_receive {:DOWN, ^old_ref, :process, ^old_authority, :killed}
    _ = :sys.get_state(TaskSupervisor)
    assert {:ok, new_supervisor_id} = TaskAuthority.identity()
    refute new_supervisor_id == identity.supervisor_id

    assert {:ok, :never_activated} = TaskSupervisor.terminate_exact(identity)
    proven = TaskClaims.get(assignment.id)
    assert proven.state == "termination_proven"
    assert {:ok, [_settled]} = TaskClaims.reconcile_proven()

    final = TaskClaims.get(assignment.id)
    assert final.state == "settled"
    assert final.outcome == "cancelled_before_provider"
  end

  test "job heartbeat failure rolls back the task lease renewal" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "renew-rollback")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, partitions)

    parent = self()

    task =
      start_bound_task(identity, fn ->
        result = FairScheduler.activate_job(reserved_job, assignment)
        send(parent, {:renewal_task_started, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:renewal_task_started, {:ok, {running_job, running_assignment}}}
    test_pid = self()

    runner =
      start_supervised!(
        {BackgroundJobRunner,
         name: :coordination_renewal_test_runner,
         poll_interval_ms: 600_000,
         claim_timeout_ms: 300_000,
         renew_job_writer: fn _job, _now ->
           send(test_pid, :injected_job_heartbeat_failure)
           {0, []}
         end}
      )

    key = {running_job.id, running_job.claim_token}

    :sys.replace_state(runner, fn state ->
      entry = %{
        job: running_job,
        task: task,
        coordination: %{assignment: running_assignment, identity: identity},
        phase: :executing,
        stop_reason: nil
      }

      %{state | running: %{key => entry}, monitors: %{task.ref => key}}
    end)

    before_renewal = TaskClaims.get(running_assignment.id)
    send(runner, :renew_claims)
    assert_receive :injected_job_heartbeat_failure
    _ = :sys.get_state(runner)
    after_renewal = TaskClaims.get(running_assignment.id)
    assert after_renewal.lease_expires_at == before_renewal.lease_expires_at
    refute Process.alive?(task.pid)
    assert job.id == running_job.id
  end

  test "external destruction proof cannot manufacture a provider outcome" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "provider-work")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, [partition])

    assert reserved_job.id == job.id
    parent = self()

    task =
      start_bound_task(identity, fn ->
        result =
          with {:ok, {running_job, running_assignment}} <-
                 FairScheduler.activate_job(reserved_job, assignment),
               {:ok, entered} <- TaskClaims.mark_provider_entered(running_assignment) do
            {:ok, running_job, entered}
          end

        send(parent, {:provider_entered, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:provider_entered, {:ok, running_job, entered}}

    # A normal settlement without immutable outcome evidence is rejected even
    # when direct SQL knows the assignment UUID/GUC.
    reject_assignment_update!(entered.id, """
      state = 'settled', provider_boundary = 'outcome_known',
      settled_at = timezone('UTC', clock_timestamp()), outcome = 'completed'
    """)

    assert TaskClaims.get(entered.id).state == "running"

    assert {:ok, requested} = TaskClaims.request_termination(entered)
    assert requested.provider_boundary == "outcome_unknown"

    proven =
      in_role!("maraithon_incident_operator", fn ->
        assert {:ok, proven} =
                 TaskClaims.record_external_termination(
                   requested,
                   "machine:destroyed:test",
                   @activated_by
                 )

        proven
      end)

    assert proven.state == "termination_proven"

    reject_assignment_update!(proven.id, """
      state = 'settled', settled_at = timezone('UTC', clock_timestamp()), outcome = 'completed'
    """)

    assert TaskClaims.get(proven.id).state == "termination_proven"

    assert {:ok, [{_, 1, "provider_outcome_ambiguous"}]} = TaskClaims.reconcile_proven(1)
    final = TaskClaims.get(proven.id)
    assert final.state == "outcome_ambiguous"
    assert final.outcome == "provider_outcome_ambiguous"
    assert Repo.get!(BackgroundJob, running_job.id).last_error == "provider_outcome_ambiguous"

    send(task.pid, :finish)
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == task.ref
  end

  test "operator background-job attestation proves external destruction for the exact identity only" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    _job = insert_job!("tenant-a", "provider-work")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, [partition])

    parent = self()

    task =
      start_bound_task(identity, fn ->
        result =
          with {:ok, {running_job, running_assignment}} <-
                 FairScheduler.activate_job(reserved_job, assignment),
               {:ok, entered} <- TaskClaims.mark_provider_entered(running_assignment) do
            {:ok, running_job, entered}
          end

        send(parent, {:provider_entered, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:provider_entered, {:ok, running_job, entered}}
    assert {:ok, requested} = TaskClaims.request_termination(entered)
    assert requested.provider_boundary == "outcome_unknown"

    evidence_id = "gcp-cloud-run-revision-delete:test-revision"
    confirmation = TaskTerminationAttestations.confirmation()

    operator_identity = %{
      assignment_id: requested.id,
      job_id: requested.work_id,
      claim_token: requested.claim_token,
      node_incarnation_id: requested.node_incarnation_id,
      supervisor_id: requested.supervisor_id,
      task_id: requested.local_task_id
    }

    # The deliberate-action interlock, an inexact identity, and the ordinary
    # runtime role are each refused without writing a proof.
    assert {:error, :task_termination_attestation_confirmation_required} =
             TaskTerminationAttestations.record(
               operator_identity,
               evidence_id,
               @activated_by,
               "PHYSICAL_TASK_TERMINATED?"
             )

    assert {:error, :task_termination_attestation_identity_mismatch} =
             in_role!("maraithon_incident_operator", fn ->
               TaskTerminationAttestations.record(
                 %{operator_identity | claim_token: Ecto.UUID.generate()},
                 evidence_id,
                 @activated_by,
                 confirmation
               )
             end)

    assert {:error, :task_termination_attestation_refused} =
             TaskTerminationAttestations.record(
               operator_identity,
               evidence_id,
               @activated_by,
               confirmation
             )

    assert TaskClaims.get(requested.id).state == "termination_requested"

    assert {:ok, %{task_assignment: proven}} =
             in_role!("maraithon_incident_operator", fn ->
               TaskTerminationAttestations.record(
                 operator_identity,
                 evidence_id,
                 @activated_by,
                 confirmation
               )
             end)

    assert proven.state == "termination_proven"

    # Lost-response replay accepts only the identical attestation.
    assert {:ok, %{task_assignment: %{id: replayed_id}}} =
             in_role!("maraithon_incident_operator", fn ->
               TaskTerminationAttestations.record(
                 operator_identity,
                 evidence_id,
                 @activated_by,
                 confirmation
               )
             end)

    assert replayed_id == proven.id

    assert {:error, :task_external_proof_mismatch} =
             in_role!("maraithon_incident_operator", fn ->
               TaskTerminationAttestations.record(
                 operator_identity,
                 "gcp-cloud-run-revision-delete:other-revision",
                 @activated_by,
                 confirmation
               )
             end)

    # Ordinary reconciliation settles the job as provider-ambiguous; the
    # attestation never manufactured an outcome.
    assert {:ok, [{_, 1, "provider_outcome_ambiguous"}]} = TaskClaims.reconcile_proven(1)
    final = TaskClaims.get(proven.id)
    assert final.state == "outcome_ambiguous"
    assert Repo.get!(BackgroundJob, running_job.id).last_error == "provider_outcome_ambiguous"

    send(task.pid, :finish)
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == task.ref
  end

  test "partition revocation cannot deadlock Guardian Effect persistence" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      fixture = insert_lock_order_fixture!(activation_epoch)

      node =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.get!(Maraithon.Runtime.Coordination.NodeIncarnation, fixture.node_id)
        end)

      parent = self()
      gate = make_ref()

      guardian =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL lock_timeout = '10s'", [])
              [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

              # This is the lock sequence reached by Guardian after its already-held
              # exact protocol pair: Effect -> node -> partition -> assignment.
              Repo.query!("SELECT id FROM public.effects WHERE id = $1::uuid FOR UPDATE", [
                Ecto.UUID.dump!(fixture.effect_id)
              ])

              send(parent, {:guardian_effect_locked, self(), backend_pid, gate})

              receive do
                {:continue_guardian, ^gate} -> :ok
              end

              Repo.query!(
                "SELECT id FROM public.runtime_node_incarnations WHERE id = $1::uuid FOR SHARE",
                [Ecto.UUID.dump!(fixture.node_id)]
              )

              Repo.query!(
                "SELECT partition_id FROM public.runtime_partitions WHERE partition_id = $1 FOR SHARE",
                [fixture.partition_id]
              )

              Repo.query!(
                "SELECT id FROM public.runtime_task_assignments WHERE id = $1::uuid FOR UPDATE",
                [Ecto.UUID.dump!(fixture.assignment_id)]
              )

              :guardian_complete
            end)
          end)
        end)

      revocation =
        Task.async(fn ->
          receive do
            {:start_revocation, ^gate} -> :ok
          end

          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:revocation_started, self(), backend_pid, gate})
            Authority.revoke_partition_workload(node, fixture.partition_id)
          end)
        end)

      guardian_pid = guardian.pid
      revocation_pid = revocation.pid

      try do
        assert_receive {:guardian_effect_locked, ^guardian_pid, guardian_backend_pid, ^gate},
                       10_000

        send(revocation.pid, {:start_revocation, gate})

        assert_receive {:revocation_started, ^revocation_pid, revocation_backend_pid, ^gate},
                       10_000

        await_database_blocker!(
          revocation,
          revocation_backend_pid,
          guardian_backend_pid
        )

        # The revoker is waiting at the Effect row, not while holding topology.
        # This NOWAIT probe would fail under the former topology -> Effect order.
        assert_topology_available!(fixture.node_id, fixture.partition_id)

        send(guardian.pid, {:continue_guardian, gate})

        assert {:ok, :guardian_complete} = Task.await(guardian, 10_000)

        # The fixture intentionally has a mismatched assignment claim so the
        # production revoker rolls back after traversing the contested locks.
        assert {:error, :coordination_task_authority_lost} = Task.await(revocation, 10_000)
      after
        shutdown_task(revocation)
        shutdown_task(guardian)
        delete_lock_order_fixture!(fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  test "node drain commits topology before waiting on Agent lease revocation" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      fixture = insert_provider_lock_order_fixture!(activation_epoch)

      node =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.get!(Maraithon.Runtime.Coordination.NodeIncarnation, fixture.node_id)
        end)

      parent = self()
      gate = make_ref()

      provider =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL lock_timeout = '10s'", [])
              [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

              Repo.query!(
                "SELECT agent_id FROM public.agent_runtime_leases WHERE agent_id = $1::uuid FOR UPDATE",
                [Ecto.UUID.dump!(fixture.agent_id)]
              )

              send(parent, {:provider_lease_locked, self(), backend_pid, gate})

              receive do
                {:continue_provider, ^gate} -> :ok
              end

              # Production provider entry holds this lease while asking for
              # ready topology. The committed drain fence must make it fail
              # closed without waiting behind the later lease revocation phase.
              rows =
                Repo.query!(
                  """
                  SELECT 1
                  FROM public.runtime_partitions AS partition
                  JOIN public.runtime_node_incarnations AS node
                    ON node.id = partition.owner_node_incarnation_id
                   AND node.activation_epoch = partition.activation_epoch
                  WHERE partition.partition_id = $1
                    AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
                    AND node.state = 'ready' AND node.ready_at IS NOT NULL
                  FOR SHARE OF partition, node
                  """,
                  [fixture.partition_id]
                ).rows

              case rows do
                [] -> :provider_fenced
                _ready -> Repo.rollback(:provider_not_fenced)
              end
            end)
          end)
        end)

      provider_pid = provider.pid

      assert_receive {:provider_lease_locked, ^provider_pid, provider_backend_pid, ^gate},
                     10_000

      drain =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:node_drain_started, self(), backend_pid, gate})
            Authority.begin_node_drain(node)
          end)
        end)

      drain_pid = drain.pid

      try do
        assert_receive {:node_drain_started, ^drain_pid, drain_backend_pid, ^gate}, 10_000

        # At this barrier the topology-only phase has committed and the next,
        # lease-only transaction is waiting on the provider's lease row.
        await_database_blocker!(drain, drain_backend_pid, provider_backend_pid)
        send(provider.pid, {:continue_provider, gate})

        assert {:ok, :provider_fenced} = Task.await(provider, 10_000)
        assert {:ok, :draining} = Task.await(drain, 10_000)
      after
        shutdown_task(drain)
        shutdown_task(provider)
        delete_provider_lock_order_fixture!(fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  test "node revocation defers without violating the database fence while partitions remain" do
    %{node: node} = active_authority!([Ecto.UUID.generate()])

    assert {:ok, :draining} = Authority.begin_node_drain(node)
    assert {:error, :node_not_drained} = Authority.revoke_node(node)

    assert [["draining"]] =
             Repo.query!(
               "SELECT state FROM public.runtime_node_incarnations WHERE id = $1::uuid",
               [Ecto.UUID.dump!(node.id)]
             ).rows
  end

  test "node and partition drains lock overlapping Agent leases in agent order" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      fixture = insert_partition_admission_fixture!(activation_epoch)

      try do
        commit_partition_agent_admission!(fixture)
        fence_partition_admission_topology!(fixture)

        node =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.get!(Maraithon.Runtime.Coordination.NodeIncarnation, fixture.node_id)
          end)

        parent = self()
        gate = make_ref()
        blocker = start_first_partition_lease_blocker!(parent, gate, fixture)

        try do
          blocker_pid = blocker.pid

          assert_receive {:first_partition_lease_locked, ^blocker_pid, blocker_backend_pid,
                          ^gate},
                         10_000

          partition_drain =
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                send(parent, {:ordered_partition_drain_started, self(), backend_pid, gate})
                Authority.revoke_partition_workload(node, fixture.partition_id)
              end)
            end)

          try do
            partition_drain_pid = partition_drain.pid

            assert_receive {:ordered_partition_drain_started, ^partition_drain_pid,
                            partition_backend_pid, ^gate},
                           10_000

            await_database_blocker!(partition_drain, partition_backend_pid, blocker_backend_pid)

            # Establish the first tuple waiter before starting the overlapping
            # node drain so the expected lock queue is deterministic.
            node_drain =
              Task.async(fn ->
                Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                  [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                  send(parent, {:ordered_node_drain_started, self(), backend_pid, gate})
                  Authority.begin_node_drain(node)
                end)
              end)

            try do
              node_drain_pid = node_drain.pid

              assert_receive {:ordered_node_drain_started, ^node_drain_pid, node_backend_pid,
                              ^gate},
                             10_000

              # Both drains take Agent lease rows in the same order. The node
              # drain must queue behind the first waiter rather than invert it.
              await_database_blocker!(node_drain, node_backend_pid, partition_backend_pid)

              send(blocker.pid, {:release_first_partition_lease, gate})
              assert {:ok, :first_lease_released} = Task.await(blocker, 10_000)

              assert {:ok, :revoked} = Task.await(partition_drain, 10_000)
              assert {:ok, :draining} = Task.await(node_drain, 10_000)

              assert partition_admission_lease_states!(fixture) ==
                       {2, fixture.ownership_epoch}
            after
              shutdown_task(node_drain)
            end
          after
            shutdown_task(partition_drain)
          end
        after
          shutdown_task(blocker)
        end
      after
        delete_partition_admission_fixture!(fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  test "partition drain commits its fence around open exact admission inserts" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      fixture = insert_partition_admission_fixture!(activation_epoch)

      try do
        node =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.get!(Maraithon.Runtime.Coordination.NodeIncarnation, fixture.node_id)
          end)

        parent = self()
        gate = make_ref()
        kinds = [:agent_lease, :task_assignment, :effect]

        # Open each transaction in a deterministic row-lock order. PostgreSQL
        # reports only the first conflicting tuple locker as the direct blocker;
        # releasing that transaction exposes the next admission in the queue.
        {admissions, backend_pids} =
          Enum.reduce(kinds, {%{}, %{}}, fn kind, {admissions, backend_pids} ->
            task = start_open_partition_admission!(parent, gate, kind, fixture)
            task_pid = task.pid

            assert_receive {:partition_admission_inserted, ^kind, ^task_pid, backend_pid, ^gate},
                           10_000

            {Map.put(admissions, kind, task), Map.put(backend_pids, kind, backend_pid)}
          end)

        try do
          lease_blocker = start_partition_admission_lease_blocker!(parent, gate, fixture)

          try do
            lease_blocker_pid = lease_blocker.pid

            assert_receive {:partition_admission_lease_blocker_started, ^lease_blocker_pid,
                            lease_blocker_backend_pid, ^gate},
                           10_000

            await_database_blocker!(
              lease_blocker,
              lease_blocker_backend_pid,
              Map.fetch!(backend_pids, :effect)
            )

            drain =
              Task.async(fn ->
                Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                  [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                  send(parent, {:partition_admission_drain_started, self(), backend_pid, gate})

                  Authority.begin_partition_drain(
                    fixture.leader,
                    fixture.partition_id,
                    kind: "shutdown"
                  )
                end)
              end)

            try do
              drain_pid = drain.pid

              assert_receive {:partition_admission_drain_started, ^drain_pid, drain_backend_pid,
                              ^gate},
                             10_000

              Enum.each(kinds, fn kind ->
                await_database_blocker!(
                  drain,
                  drain_backend_pid,
                  Map.fetch!(backend_pids, kind)
                )

                # The topology fence cannot commit while this admission remains
                # open. Commit lockers one by one and observe every exact class
                # become the drain's direct database blocker in turn.
                assert partition_admission_partition_state!(fixture) == {"ready", nil}

                send(Map.fetch!(admissions, kind).pid, {
                  :commit_partition_admission,
                  kind,
                  gate
                })

                assert {:ok, :admission_committed} =
                         Task.await(Map.fetch!(admissions, kind), 10_000)
              end)

              assert_receive {:partition_admission_lease_locked, ^lease_blocker_pid,
                              ^lease_blocker_backend_pid, ^gate},
                             10_000

              # Phase one has committed: the drain is now waiting in its
              # lease-only workload phase and holds no topology lock.
              await_database_blocker!(drain, drain_backend_pid, lease_blocker_backend_pid)
              assert_topology_available!(fixture.node_id, fixture.partition_id)
              assert partition_admission_partition_state!(fixture) == {"draining", nil}

              send(lease_blocker.pid, {:release_partition_admission_lease, gate})
              assert {:ok, :lease_released} = Task.await(lease_blocker, 10_000)

              assert {:ok, %Maraithon.Runtime.Coordination.Partition{} = draining} =
                       Task.await(drain, 10_000)

              assert draining.state == "draining"
              assert draining.ownership_epoch == fixture.ownership_epoch

              assert partition_admission_states!(fixture) ==
                       {true, "cancelled", "reserved", "draining", fixture.ownership_epoch, 0}

              # Agent termination convergence is independent and already
              # covered elsewhere. Remove those durable gates test-only so the
              # committed raw reservation is the exact release boundary.
              converge_partition_admission_lease_gates!(fixture)

              release_error =
                assert_raise Postgrex.Error, fn ->
                  Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                    Authority.release_drained_partition(fixture.leader, fixture.partition_id)
                  end)
                end

              assert release_error.postgres.code == :check_violation
              assert release_error.postgres.message =~ "exact task proof"

              assert partition_admission_partition_state!(fixture) ==
                       {"draining", fixture.ownership_epoch}
            after
              shutdown_task(drain)
            end
          after
            shutdown_task(lease_blocker)
          end
        after
          Enum.each(admissions, fn {_kind, task} -> shutdown_task(task) end)
        end
      after
        delete_partition_admission_fixture!(fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  test "stale repeatable-read exact admission inserts serialize after partition drain" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      fixture = insert_partition_admission_fixture!(activation_epoch)

      try do
        parent = self()
        gate = make_ref()
        kinds = [:agent_lease, :task_assignment, :effect]

        stale_admissions =
          Map.new(kinds, fn kind ->
            {kind, start_stale_partition_admission!(parent, gate, kind, fixture)}
          end)

        try do
          Enum.each(kinds, fn kind ->
            task_pid = Map.fetch!(stale_admissions, kind).pid

            assert_receive {:partition_admission_snapshot_pinned, ^kind, ^task_pid, _backend_pid,
                            ^gate},
                           10_000
          end)

          assert {:ok, %Maraithon.Runtime.Coordination.Partition{} = draining} =
                   Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                     Authority.begin_partition_drain(
                       fixture.leader,
                       fixture.partition_id,
                       kind: "shutdown"
                     )
                   end)

          assert draining.state == "draining"

          assert partition_admission_partition_state!(fixture) ==
                   {"draining", fixture.ownership_epoch}

          Enum.each(kinds, fn kind ->
            send(Map.fetch!(stale_admissions, kind).pid, {
              :attempt_stale_partition_admission,
              kind,
              gate
            })
          end)

          Enum.each(kinds, fn kind ->
            assert {:postgres_error, :serialization_failure, message} =
                     Task.await(Map.fetch!(stale_admissions, kind), 10_000)

            assert message =~ "could not serialize"
          end)

          assert partition_admission_row_counts!(fixture) == {0, 0, 0, 0}
        after
          Enum.each(stale_admissions, fn {_kind, task} -> shutdown_task(task) end)
        end
      after
        delete_partition_admission_fixture!(fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  test "partition drain revokes Agent leases across blocked and expired topology" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      blocked_fixture = insert_partition_admission_fixture!(activation_epoch)

      try do
        commit_partition_admission_work!(blocked_fixture)

        assert {:ok, %Maraithon.Runtime.Coordination.Partition{} = blocked} =
                 Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                   Authority.begin_partition_drain(
                     blocked_fixture.leader,
                     blocked_fixture.partition_id,
                     kind: "shutdown",
                     blocked?: true
                   )
                 end)

        assert blocked.state == "blocked"

        assert partition_drain_workload_states!(blocked_fixture) ==
                 {true, "cancelled", "termination_requested", "blocked",
                  blocked_fixture.ownership_epoch}
      after
        delete_partition_admission_fixture!(blocked_fixture)
      end

      expired_fixture = insert_partition_admission_fixture!(activation_epoch)

      try do
        commit_partition_admission_work!(expired_fixture)
        expire_partition_admission_topology!(expired_fixture)

        assert {:ok, %Maraithon.Runtime.Coordination.Partition{} = draining} =
                 Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                   Authority.begin_partition_drain(
                     expired_fixture.leader,
                     expired_fixture.partition_id,
                     kind: "lease_expired"
                   )
                 end)

        assert draining.state == "draining"

        assert partition_drain_workload_states!(expired_fixture) ==
                 {true, "cancelled", "termination_requested", "draining", nil}

        converge_release_lease_gate!(expired_fixture)
        converge_release_task_gate!(expired_fixture)

        assert {:ok, :released} =
                 Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                   Authority.release_drained_partition(
                     expired_fixture.leader,
                     expired_fixture.partition_id
                   )
                 end)

        assert partition_admission_partition_state!(expired_fixture) == {"unassigned", nil}
      after
        delete_partition_admission_fixture!(expired_fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  test "partition release serializes behind pending Effect settlement and durable gates" do
    protocol_snapshot = snapshot_protocol_pair!()

    try do
      activation_epoch = activate_committed_protocol_pair!()
      fixture = insert_release_race_fixture!(activation_epoch)

      try do
        node =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.get!(Maraithon.Runtime.Coordination.NodeIncarnation, fixture.node_id)
          end)

        release_marker_error =
          assert_raise Postgrex.Error, fn ->
            bypass_release_without_effect_drain_marker!(fixture)
          end

        assert release_marker_error.postgres.code == :check_violation

        assert release_marker_error.postgres.message =~
                 "partition release requires the current Effect drain marker to be cleared"

        assert release_race_partition_topology!(fixture) ==
                 {"draining", nil, fixture.activation_epoch, fixture.ownership_epoch,
                  fixture.node_id}

        isolation_error =
          assert_raise Postgrex.Error, fn ->
            forge_release_effect_drain_marker!(fixture, :repeatable_read)
          end

        assert isolation_error.postgres.code == :check_violation

        assert isolation_error.postgres.message =~
                 "partition Effect drain marker requires read committed isolation"

        assert is_nil(release_race_effects_drained_epoch!(fixture))

        marker_error =
          assert_raise Postgrex.Error, fn ->
            forge_release_effect_drain_marker!(fixture, :read_committed)
          end

        assert marker_error.postgres.code == :check_violation

        assert marker_error.postgres.message =~
                 "partition Effect drain marker requires an empty active Effect scope"

        assert is_nil(release_race_effects_drained_epoch!(fixture))

        parent = self()
        gate = make_ref()

        settlement =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Repo.query!("SET LOCAL lock_timeout = '10s'", [])

                Repo.query!(
                  "SELECT activation_epoch FROM public.runtime_coordination_protocols WHERE name = 'runtime' FOR SHARE",
                  []
                )

                Repo.query!(
                  "SELECT mode FROM public.effect_execution_protocols WHERE name = 'effects' FOR SHARE",
                  []
                )

                [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

                Repo.query!("SELECT id FROM public.effects WHERE id = $1::uuid FOR UPDATE", [
                  Ecto.UUID.dump!(fixture.effect_id)
                ])

                send(parent, {:release_settlement_effect_locked, self(), backend_pid, gate})

                receive do
                  {:defer_release_settlement, ^gate} ->
                    Repo.rollback(:settlement_deferred)
                end
              end)
            end)
          end)

        settlement_pid = settlement.pid

        assert_receive {:release_settlement_effect_locked, ^settlement_pid,
                        settlement_backend_pid, ^gate},
                       10_000

        release =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
              send(parent, {:partition_release_started, self(), backend_pid, gate})
              Authority.release_drained_partition(fixture.leader, fixture.partition_id)
            end)
          end)

        release_pid = release.pid

        try do
          assert_receive {:partition_release_started, ^release_pid, release_backend_pid, ^gate},
                         10_000

          await_database_blocker!(release, release_backend_pid, settlement_backend_pid)

          # Release is queued on the Effect row and has not taken node/partition.
          assert_topology_available!(fixture.node_id, fixture.partition_id)

          send(settlement.pid, {:defer_release_settlement, gate})

          assert {:error, :settlement_deferred} = Task.await(settlement, 10_000)
          assert {:error, :partition_effects_active} = Task.await(release, 10_000)
        after
          shutdown_task(release)
          shutdown_task(settlement)
        end

        # The retryable drain pass synchronously settles the pending Effect and
        # requests termination of the independent task, but release remains
        # fail-closed behind its durable Agent and task rows.
        assert {:ok, :revoked} =
                 Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                   Authority.revoke_partition_workload(node, fixture.partition_id)
                 end)

        assert release_race_states!(fixture) ==
                 {"cancelled", nil, true, "termination_requested", fixture.ownership_epoch}

        agent_gate_error =
          assert_raise Postgrex.Error, fn ->
            release_race_call!(fixture)
          end

        assert agent_gate_error.postgres.code == :check_violation
        assert agent_gate_error.postgres.message =~ "Agent termination proof"
        assert release_race_effects_drained_epoch!(fixture) == fixture.ownership_epoch

        # Test-only replica convergence stands in for the separately tested,
        # proof-gated Agent lease deletion. The unresolved task must still block.
        converge_release_lease_gate!(fixture)

        task_gate_error =
          assert_raise Postgrex.Error, fn ->
            release_race_call!(fixture)
          end

        assert task_gate_error.postgres.code == :check_violation
        assert task_gate_error.postgres.message =~ "exact task proof"
        assert release_race_effects_drained_epoch!(fixture) == fixture.ownership_epoch

        # Once the task ledger is terminal too, the same leader may release.
        converge_release_task_gate!(fixture)
        assert {:ok, :released} = release_race_call!(fixture)

        assert [["unassigned", nil]] =
                 Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                   Repo.query!(
                     "SELECT state, effects_drained_epoch FROM public.runtime_partitions WHERE partition_id = $1",
                     [fixture.partition_id]
                   ).rows
                 end)
      after
        delete_release_race_fixture!(fixture)
      end
    after
      restore_protocol_pair!(protocol_snapshot)
    end
  end

  defp active_authority!(user_ids) do
    attest_effect_protocol!()
    activate_effect_protocol!()
    finalize_partition_catalog!()
    assert {:ok, :activated} = activate_coordination!()

    node =
      Authority.register_node(revision: @revision, node_name: "test-node", ttl_ms: 300_000)
      |> ok!()

    node = Authority.mark_node_ready(node) |> ok!()
    leader = Authority.acquire_leader(node, 300_000) |> ok!()
    leader = Authority.mark_leader_ready(leader) |> ok!()

    partitions =
      user_ids
      |> Enum.map(&Partitioning.partition_for("user:" <> &1))
      |> Enum.uniq()
      |> Enum.map(fn partition_id ->
        Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000) |> ok!()
        Authority.mark_partition_ready(node, partition_id) |> ok!()
      end)

    %{node: node, leader: leader, partitions: partitions}
  end

  defp ready_all_partitions!(node) do
    leader = Authority.acquire_leader(node, 300_000) |> ok!()
    leader = Authority.mark_leader_ready(leader) |> ok!()

    Repo.query!("SELECT partition_id FROM public.runtime_partitions ORDER BY partition_id", []).rows
    |> Enum.each(fn [partition_id] ->
      Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000) |> ok!()
      Authority.mark_partition_ready(node, partition_id) |> ok!()
    end)
  end

  defp expire_deployment_topology!(node, leader, partition_ids) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL ROLE NONE", [])
      Repo.query!("SET LOCAL session_replication_role = replica", [])

      Repo.query!(
        """
        UPDATE public.runtime_node_incarnations
        SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second'
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(node.id)]
      )

      Repo.query!(
        """
        UPDATE public.runtime_leader_authorities
        SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second'
        WHERE role = 'partition_planner' AND action_token = $1::uuid
        """,
        [Ecto.UUID.dump!(leader.action_token)]
      )

      Repo.query!(
        """
        UPDATE public.runtime_partitions
        SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second'
        WHERE partition_id = ANY($1::smallint[])
        """,
        [partition_ids]
      )

      Repo.query!("SET LOCAL session_replication_role = origin", [])
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
    end)
  end

  defp activate_effect_protocol! do
    status =
      in_role!("maraithon_activation_operator", fn ->
        assert {:ok, status} =
                 ProtocolCutover.activate(
                   [confirmation: ProtocolCutover.activation_confirmation()] ++
                     @activation_evidence
                 )

        status
      end)

    assert status in [:activated, :already_active]
  end

  defp attest_effect_protocol! do
    status =
      in_role!("maraithon_activation_operator", fn ->
        assert {:ok, status} =
                 Protocol.attest_effect_activation_evidence(@activation_evidence)

        status
      end)

    assert status in [:attested, :already_attested]
  end

  defp activate_coordination! do
    in_role!("maraithon_activation_operator", fn ->
      Protocol.activate(coordination_activation_opts())
    end)
  end

  defp defer_partition_catalog! do
    in_role!("maraithon_migrator", fn ->
      Repo.query!(
        "ALTER TABLE public.background_jobs DROP CONSTRAINT background_jobs_partition_shape",
        []
      )

      Repo.query!(
        """
        ALTER TABLE public.background_jobs ADD CONSTRAINT background_jobs_partition_shape CHECK (
          (tenant_key IS NULL AND partition_id IS NULL) OR
          (octet_length(tenant_key) BETWEEN 1 AND 512 AND partition_id >= 0 AND partition_id < 64)
        ) NOT VALID
        """,
        []
      )

      Repo.query!(
        "ALTER TABLE public.scheduled_jobs DROP CONSTRAINT scheduled_jobs_partition_shape",
        []
      )

      Repo.query!(
        """
        ALTER TABLE public.scheduled_jobs ADD CONSTRAINT scheduled_jobs_partition_shape CHECK (
          (tenant_key IS NULL AND partition_id IS NULL) OR
          (octet_length(tenant_key) BETWEEN 1 AND 512 AND partition_id >= 0 AND partition_id < 64)
        ) NOT VALID
        """,
        []
      )
    end)
  end

  defp finalize_partition_catalog! do
    in_role!("maraithon_migrator", fn ->
      Repo.query!(
        "ALTER TABLE public.background_jobs VALIDATE CONSTRAINT background_jobs_partition_shape",
        []
      )

      Repo.query!(
        "ALTER TABLE public.scheduled_jobs VALIDATE CONSTRAINT scheduled_jobs_partition_shape",
        []
      )
    end)
  end

  defp coordination_activation_opts do
    [confirmation: Protocol.activation_confirmation()] ++ @activation_evidence
  end

  defp insert_user!(id) do
    case Repo.transaction(fn ->
           Repo.query!("SET LOCAL ROLE NONE", [])

           user =
             %User{}
             |> User.changeset(%{id: id, email: "#{id}@example.test"})
             |> Repo.insert!()

           Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
           user
         end) do
      {:ok, user} -> user
      {:error, reason} -> flunk("login-role insert failed: #{inspect(reason)}")
    end
  end

  defp insert_job!(user_id, dedupe, opts \\ []) do
    %BackgroundJob{}
    |> BackgroundJob.changeset(%{
      user_id: user_id,
      queue: Keyword.get(opts, :queue, "test"),
      job_type: "test",
      payload: %{"dedupe" => dedupe},
      dedupe_key: Ecto.UUID.generate(),
      partition_key: Keyword.get(opts, :partition_key),
      scheduled_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp start_bound_task(identity, fun) when is_function(fun, 0) do
    gate = make_ref()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        receive do: ({:bound, ^gate} -> :ok)
        :ok = TaskSupervisor.register_current!(identity)
        fun.()
      end)

    assert :ok = TaskSupervisor.bind_task(identity, task.pid)
    send(task.pid, {:bound, gate})
    task
  end

  defp reject_assignment_update!(assignment_id, set_sql) do
    Repo.query!(
      """
      DO $block$
      DECLARE rejected boolean := false;
      BEGIN
        PERFORM set_config('maraithon.runtime_task_action', '#{assignment_id}', true);
        BEGIN
          UPDATE public.runtime_task_assignments SET #{set_sql},
            updated_at = timezone('UTC', clock_timestamp())
          WHERE id = '#{assignment_id}'::uuid;
        EXCEPTION WHEN check_violation THEN
          rejected := true;
        END;
        IF NOT rejected THEN RAISE EXCEPTION 'unsafe assignment update unexpectedly succeeded'; END IF;
      END
      $block$;
      """,
      []
    )
  end

  defp restart_repo! do
    :ok = Supervisor.terminate_child(Maraithon.Supervisor, Repo)
    {:ok, _pid} = Supervisor.restart_child(Maraithon.Supervisor, Repo)
    :ok
  end

  defp restart_task_system! do
    parent = Maraithon.Runtime.Supervisor
    child = Maraithon.Runtime.TaskSystemSupervisor

    :ok = Supervisor.terminate_child(parent, child)
    {:ok, _pid} = Supervisor.restart_child(parent, child)
    _ = :sys.get_state(TaskAuthority)
    :ok
  end

  defp in_role!(role, fun)
       when role in [
              "maraithon_migrator",
              "maraithon_runtime",
              "maraithon_payload_verifier",
              "maraithon_incident_operator",
              "maraithon_activation_operator"
            ] and is_function(fun, 0) do
    case Repo.transaction(fn ->
           Repo.query!("SET LOCAL ROLE " <> role, [])
           value = fun.()
           Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
           value
         end) do
      {:ok, value} -> value
      {:error, reason} -> flunk("role-scoped transaction failed: #{inspect(reason)}")
    end
  end

  defp with_session_role!(role, fun)
       when role in [
              "maraithon_migrator",
              "maraithon_runtime",
              "maraithon_payload_verifier",
              "maraithon_incident_operator",
              "maraithon_activation_operator"
            ] and is_function(fun, 0) do
    Repo.query!("SET ROLE " <> role, [])

    try do
      fun.()
    after
      Repo.query!("SET ROLE maraithon_runtime", [])
    end
  end

  defp snapshot_protocol_pair! do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [effect] =
        Repo.query!(
          """
          SELECT mode, activated_at, activation_epoch, activation_evidence_id,
                 activation_evidence_digest, activated_by, exact_revision, updated_at
          FROM public.effect_execution_protocols WHERE name = 'effects'
          """,
          []
        ).rows

      [runtime] =
        Repo.query!(
          """
          SELECT mode, activated_at, activation_epoch, activation_evidence_id,
                 activation_evidence_digest, activated_by, exact_revision, updated_at
          FROM public.runtime_coordination_protocols WHERE name = 'runtime'
          """,
          []
        ).rows

      %{effect: effect, runtime: runtime}
    end)
  end

  defp activate_committed_protocol_pair! do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      effect_attestation =
        in_role!("maraithon_activation_operator", fn ->
          Protocol.attest_effect_activation_evidence(@activation_evidence)
        end)

      assert {:ok, effect_attestation_status} = effect_attestation
      assert effect_attestation_status in [:attested, :already_attested]

      effect_activation =
        in_role!("maraithon_activation_operator", fn ->
          ProtocolCutover.activate(
            [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
          )
        end)

      assert {:ok, effect_activation_status} = effect_activation
      assert effect_activation_status in [:activated, :already_active]

      runtime_activation =
        in_role!("maraithon_activation_operator", fn ->
          Protocol.activate(coordination_activation_opts())
        end)

      assert {:ok, runtime_activation_status} = runtime_activation
      assert runtime_activation_status in [:activated, :already_active]

      [[activation_epoch]] =
        Repo.query!(
          "SELECT activation_epoch FROM public.runtime_coordination_protocols WHERE name = 'runtime'",
          []
        ).rows

      Ecto.UUID.load!(activation_epoch)
    end)
  end

  defp restore_protocol_pair!(snapshot) do
    case Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
           Repo.transaction(fn ->
             Repo.query!("SET LOCAL ROLE NONE", [])
             Repo.query!("SET LOCAL session_replication_role = replica", [])
             restore_protocol_row!("effect_execution_protocols", "effects", snapshot.effect)
             restore_protocol_row!("runtime_coordination_protocols", "runtime", snapshot.runtime)
             :ok
           end)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> flunk("protocol-pair restoration failed: #{inspect(reason)}")
    end
  end

  defp restore_protocol_row!(table, name, row)
       when table in ["effect_execution_protocols", "runtime_coordination_protocols"] do
    [mode, activated_at, epoch, evidence_id, evidence_digest, activated_by, revision, updated_at] =
      row

    Repo.query!(
      """
      UPDATE public.#{table}
      SET mode = $1, activated_at = $2, activation_epoch = $3::uuid,
          activation_evidence_id = $4, activation_evidence_digest = $5,
          activated_by = $6, exact_revision = $7, updated_at = $8
      WHERE name = $9
      """,
      [
        mode,
        activated_at,
        epoch,
        evidence_id,
        evidence_digest,
        activated_by,
        revision,
        updated_at,
        name
      ]
    )
  end

  defp insert_partition_admission_fixture!(activation_epoch) do
    base = insert_provider_lock_order_fixture!(activation_epoch)

    params = %{
      "__maraithon_effect_protocol" => 2,
      "__maraithon_execution_lane" => "tool",
      "tool" => "time",
      "args" => %{}
    }

    extra = %{
      admission_agent_id: Ecto.UUID.generate(),
      admission_owner_token: Ecto.UUID.generate(),
      admission_termination_capability_digest: :crypto.strong_rand_bytes(32),
      assignment_id: Ecto.UUID.generate(),
      assignment_work_id: Ecto.UUID.generate(),
      assignment_claim_token: Ecto.UUID.generate(),
      assignment_supervisor_id: Ecto.UUID.generate(),
      assignment_local_task_id: Ecto.UUID.generate(),
      assignment_termination_capability_digest: :crypto.strong_rand_bytes(32),
      effect_id: Ecto.UUID.generate(),
      effect_idempotency_key: Ecto.UUID.generate()
    }

    {:ok, params_ciphertext} = Maraithon.Encrypted.Map.dump(params)

    binding =
      Maraithon.DurablePayload.binding_attrs!(
        %Maraithon.Effects.Effect{
          id: extra.effect_id,
          agent_id: base.agent_id,
          owner_user_id: base.user_id,
          params: params
        },
        Maraithon.Effects.Effect.payload_binding_spec()
      )

    try do
      result =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL ROLE NONE", [])
            Repo.query!("SET LOCAL session_replication_role = replica", [])

            [
              [
                previous_activation_epoch,
                previous_leader_epoch,
                nil,
                nil,
                "unassigned",
                nil,
                nil,
                nil,
                previous_leader_updated_at
              ]
            ] =
              Repo.query!(
                """
                SELECT activation_epoch, leader_epoch, node_incarnation_id, action_token,
                       state, lease_expires_at, ready_at, draining_at, updated_at
                FROM public.runtime_leader_authorities
                WHERE role = 'partition_planner'
                FOR UPDATE
                """,
                []
              ).rows

            leader_epoch = previous_leader_epoch + 1

            Repo.query!(
              """
              UPDATE public.runtime_leader_authorities
              SET activation_epoch = $1::uuid, leader_epoch = $2,
                  node_incarnation_id = $3::uuid, action_token = $4::uuid,
                  state = 'ready', lease_expires_at =
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                  ready_at = timezone('UTC', clock_timestamp()), draining_at = NULL,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE role = 'partition_planner'
              """,
              [
                Ecto.UUID.dump!(activation_epoch),
                leader_epoch,
                Ecto.UUID.dump!(base.node_id),
                Ecto.UUID.dump!(base.leader_action_token)
              ]
            )

            Repo.query!(
              """
              INSERT INTO public.agents
                (id, behavior, status, started_at, user_id, inserted_at, updated_at)
              VALUES ($1::uuid, 'prompt_agent', 'running',
                      timezone('UTC', clock_timestamp()), $2,
                      timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
              """,
              [Ecto.UUID.dump!(extra.admission_agent_id), base.user_id]
            )

            base
            |> Map.merge(extra)
            |> Map.merge(%{
              effect_params_ciphertext: params_ciphertext,
              effect_binding: binding,
              previous_leader_activation_epoch: previous_activation_epoch,
              previous_leader_epoch: previous_leader_epoch,
              previous_leader_updated_at: previous_leader_updated_at,
              leader: %{
                activation_epoch: activation_epoch,
                leader_epoch: leader_epoch,
                node_incarnation_id: base.node_id,
                action_token: base.leader_action_token
              }
            })
          end)
        end)

      case result do
        {:ok, fixture} -> fixture
        {:error, reason} -> raise "partition-admission fixture failed: #{inspect(reason)}"
      end
    rescue
      error ->
        delete_provider_lock_order_fixture!(base)
        reraise error, __STACKTRACE__
    end
  end

  defp commit_partition_agent_admission!(fixture) do
    assert {:ok, :agent_admitted} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
                 insert_partition_admission!(:agent_lease, fixture)
                 :agent_admitted
               end)
             end)
  end

  defp fence_partition_admission_topology!(fixture) do
    assert {:ok, :partition_fenced} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE NONE", [])
                 Repo.query!("SET LOCAL session_replication_role = replica", [])

                 Repo.query!(
                   """
                   UPDATE public.runtime_partitions
                   SET state = 'draining', ready_at = NULL,
                       draining_at = timezone('UTC', clock_timestamp()),
                       updated_at = timezone('UTC', clock_timestamp())
                   WHERE partition_id = $1
                   """,
                   [fixture.partition_id]
                 )

                 :partition_fenced
               end)
             end)
  end

  defp start_first_partition_lease_blocker!(parent, gate, fixture) do
    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '10s'", [])
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

          Repo.query!(
            """
            SELECT agent_id FROM public.agent_runtime_leases
            WHERE agent_id IN ($1::uuid, $2::uuid)
            ORDER BY agent_id
            LIMIT 1
            FOR UPDATE
            """,
            [
              Ecto.UUID.dump!(fixture.agent_id),
              Ecto.UUID.dump!(fixture.admission_agent_id)
            ]
          )

          send(parent, {:first_partition_lease_locked, self(), backend_pid, gate})

          receive do
            {:release_first_partition_lease, ^gate} -> :first_lease_released
          end
        end)
      end)
    end)
  end

  defp start_open_partition_admission!(parent, gate, kind, fixture) do
    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '10s'", [])
          Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

          insert_partition_admission!(kind, fixture)
          send(parent, {:partition_admission_inserted, kind, self(), backend_pid, gate})

          receive do
            {:commit_partition_admission, ^kind, ^gate} -> :admission_committed
          end
        end)
      end)
    end)
  end

  defp start_stale_partition_admission!(parent, gate, kind, fixture) do
    Task.async(fn ->
      try do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
            Repo.query!("SET LOCAL lock_timeout = '10s'", [])
            Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

            pin_partition_admission_snapshot!(fixture)
            send(parent, {:partition_admission_snapshot_pinned, kind, self(), backend_pid, gate})

            receive do
              {:attempt_stale_partition_admission, ^kind, ^gate} -> :ok
            end

            insert_partition_admission!(kind, fixture)
            :stale_admission_committed
          end)
        end)
      rescue
        error in Postgrex.Error ->
          {:postgres_error, error.postgres.code, error.postgres.message}
      end
    end)
  end

  defp start_partition_admission_lease_blocker!(parent, gate, fixture) do
    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '10s'", [])
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows

          send(
            parent,
            {:partition_admission_lease_blocker_started, self(), backend_pid, gate}
          )

          Repo.query!(
            "SELECT agent_id FROM public.agent_runtime_leases WHERE agent_id = $1::uuid FOR UPDATE",
            [Ecto.UUID.dump!(fixture.agent_id)]
          )

          send(parent, {:partition_admission_lease_locked, self(), backend_pid, gate})

          receive do
            {:release_partition_admission_lease, ^gate} -> :lease_released
          end
        end)
      end)
    end)
  end

  defp insert_partition_admission!(:agent_lease, fixture) do
    Repo.query!(
      """
      INSERT INTO public.agent_runtime_leases
        (agent_id, owner_token, owner_node, claimed_at, lease_until, renewed_at,
         termination_capability_digest, coordination_activation_epoch,
         coordination_partition_id, coordination_partition_epoch,
         coordination_node_incarnation_id, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, 'partition-admission',
              timezone('UTC', clock_timestamp()) - interval '1 second',
              timezone('UTC', clock_timestamp()) + interval '10 minutes',
              timezone('UTC', clock_timestamp()), $3, $4::uuid, $5, $6, $7::uuid,
              timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      """,
      [
        Ecto.UUID.dump!(fixture.admission_agent_id),
        Ecto.UUID.dump!(fixture.admission_owner_token),
        fixture.admission_termination_capability_digest,
        Ecto.UUID.dump!(fixture.activation_epoch),
        fixture.partition_id,
        fixture.ownership_epoch,
        Ecto.UUID.dump!(fixture.node_id)
      ]
    )
  end

  defp insert_partition_admission!(:task_assignment, fixture) do
    Repo.query!(
      "SELECT set_config('maraithon.runtime_task_action', $1, true)",
      [fixture.assignment_id]
    )

    Repo.query!(
      """
      INSERT INTO public.runtime_task_assignments
        (id, activation_epoch, work_kind, work_id, claim_token,
         partition_id, partition_epoch, node_incarnation_id, supervisor_id,
         local_task_id, termination_capability_digest, state, provider_boundary,
         lease_expires_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, 'background_job', $3::uuid, $4::uuid,
              $5, $6, $7::uuid, $8::uuid, $9::uuid, $10,
              'reserved', 'not_entered',
              timezone('UTC', clock_timestamp()) + interval '10 minutes',
              timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      """,
      [
        Ecto.UUID.dump!(fixture.assignment_id),
        Ecto.UUID.dump!(fixture.activation_epoch),
        Ecto.UUID.dump!(fixture.assignment_work_id),
        Ecto.UUID.dump!(fixture.assignment_claim_token),
        fixture.partition_id,
        fixture.ownership_epoch,
        Ecto.UUID.dump!(fixture.node_id),
        Ecto.UUID.dump!(fixture.assignment_supervisor_id),
        Ecto.UUID.dump!(fixture.assignment_local_task_id),
        fixture.assignment_termination_capability_digest
      ]
    )
  end

  defp insert_partition_admission!(:effect, fixture) do
    Repo.query!(
      "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
      []
    )

    Repo.query!(
      """
      INSERT INTO public.effects
        (id, agent_id, owner_user_id, idempotency_key, effect_type,
         params_ciphertext, params, effect_protocol_version,
         payload_encryption_version, payload_binding_version,
         payload_binding_key_tag, payload_binding_mac, execution_lane, status,
         runtime_owner_generation, coordination_activation_epoch,
         coordination_partition_id, coordination_partition_epoch,
         coordination_node_incarnation_id, attempts, max_attempts,
         inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, $4::uuid, 'tool_call',
              $5, '{"redacted": true}'::jsonb, 2, 1, $6, $7, $8, 'tool', 'pending',
              $9::uuid, $10::uuid, $11, $12, $13::uuid, 0, 3,
              timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      """,
      [
        Ecto.UUID.dump!(fixture.effect_id),
        Ecto.UUID.dump!(fixture.agent_id),
        fixture.user_id,
        Ecto.UUID.dump!(fixture.effect_idempotency_key),
        fixture.effect_params_ciphertext,
        fixture.effect_binding.payload_binding_version,
        fixture.effect_binding.payload_binding_key_tag,
        fixture.effect_binding.payload_binding_mac,
        Ecto.UUID.dump!(fixture.owner_token),
        Ecto.UUID.dump!(fixture.activation_epoch),
        fixture.partition_id,
        fixture.ownership_epoch,
        Ecto.UUID.dump!(fixture.node_id)
      ]
    )
  end

  defp pin_partition_admission_snapshot!(fixture) do
    assert [[1]] =
             Repo.query!(
               """
               SELECT 1
               FROM public.agent_runtime_leases AS lease
               JOIN public.runtime_node_incarnations AS node
                 ON node.id = lease.coordination_node_incarnation_id
                AND node.activation_epoch = lease.coordination_activation_epoch
               JOIN public.runtime_partitions AS partition
                 ON partition.partition_id = lease.coordination_partition_id
                AND partition.activation_epoch = lease.coordination_activation_epoch
                AND partition.ownership_epoch = lease.coordination_partition_epoch
                AND partition.owner_node_incarnation_id = lease.coordination_node_incarnation_id
               WHERE lease.agent_id = $1::uuid AND lease.owner_token = $2::uuid
                 AND lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
                 AND lease.lease_until > timezone('UTC', clock_timestamp())
                 AND node.state = 'ready' AND node.ready_at IS NOT NULL
                 AND node.lease_expires_at > timezone('UTC', clock_timestamp())
                 AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
                 AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
               """,
               [Ecto.UUID.dump!(fixture.agent_id), Ecto.UUID.dump!(fixture.owner_token)]
             ).rows

    :ok
  end

  defp commit_partition_admission_work!(fixture) do
    assert {:ok, :work_admitted} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
                 insert_partition_admission!(:task_assignment, fixture)
                 insert_partition_admission!(:effect, fixture)

                 Repo.query!(
                   "SELECT set_config('maraithon.runtime_task_action', $1, true)",
                   [fixture.assignment_id]
                 )

                 %{num_rows: 1} =
                   Repo.query!(
                     """
                     UPDATE public.runtime_task_assignments
                     SET state = 'running', ready_at = timezone('UTC', clock_timestamp()),
                         updated_at = timezone('UTC', clock_timestamp())
                     WHERE id = $1::uuid AND state = 'reserved'
                     """,
                     [Ecto.UUID.dump!(fixture.assignment_id)]
                   )

                 :work_admitted
               end)
             end)
  end

  defp expire_partition_admission_topology!(fixture) do
    assert {:ok, :topology_expired} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE NONE", [])
                 Repo.query!("SET LOCAL session_replication_role = replica", [])

                 Repo.query!(
                   """
                   UPDATE public.runtime_node_incarnations
                   SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 minute',
                       updated_at = timezone('UTC', clock_timestamp())
                   WHERE id = $1::uuid
                   """,
                   [Ecto.UUID.dump!(fixture.node_id)]
                 )

                 Repo.query!(
                   """
                   UPDATE public.runtime_partitions
                   SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 minute',
                       updated_at = timezone('UTC', clock_timestamp())
                   WHERE partition_id = $1
                   """,
                   [fixture.partition_id]
                 )

                 :topology_expired
               end)
             end)
  end

  defp partition_admission_lease_states!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[drained_leases, marker]] =
        Repo.query!(
          """
          SELECT
            (SELECT COUNT(*) FROM public.agent_runtime_leases
             WHERE agent_id IN ($1::uuid, $2::uuid)
               AND ready_at IS NULL AND draining_at IS NOT NULL),
            effects_drained_epoch
          FROM public.runtime_partitions
          WHERE partition_id = $3
          """,
          [
            Ecto.UUID.dump!(fixture.agent_id),
            Ecto.UUID.dump!(fixture.admission_agent_id),
            fixture.partition_id
          ]
        ).rows

      {drained_leases, marker}
    end)
  end

  defp partition_drain_workload_states!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[lease_drained, effect_state, task_state, partition_state, marker]] =
        Repo.query!(
          """
          SELECT
            EXISTS (
              SELECT 1 FROM public.agent_runtime_leases
              WHERE agent_id = $1::uuid AND ready_at IS NULL AND draining_at IS NOT NULL
            ),
            (SELECT status FROM public.effects WHERE id = $2::uuid),
            (SELECT state FROM public.runtime_task_assignments WHERE id = $3::uuid),
            partition.state, partition.effects_drained_epoch
          FROM public.runtime_partitions AS partition
          WHERE partition.partition_id = $4
          """,
          [
            Ecto.UUID.dump!(fixture.agent_id),
            Ecto.UUID.dump!(fixture.effect_id),
            Ecto.UUID.dump!(fixture.assignment_id),
            fixture.partition_id
          ]
        ).rows

      {lease_drained, effect_state, task_state, partition_state, marker}
    end)
  end

  defp partition_admission_states!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[lease_drained, effect_state, task_state, partition_state, marker, active_effects]] =
        Repo.query!(
          """
          SELECT
            EXISTS (
              SELECT 1 FROM public.agent_runtime_leases
              WHERE agent_id = $1::uuid AND ready_at IS NULL AND draining_at IS NOT NULL
            ),
            (SELECT status FROM public.effects WHERE id = $2::uuid),
            (SELECT state FROM public.runtime_task_assignments WHERE id = $3::uuid),
            partition.state, partition.effects_drained_epoch,
            (SELECT COUNT(*) FROM public.effects
             WHERE coordination_activation_epoch = $4::uuid
               AND coordination_partition_id = $5
               AND status IN ('pending', 'claimed', 'executing', 'cancelling'))
          FROM public.runtime_partitions AS partition
          WHERE partition.partition_id = $5
          """,
          [
            Ecto.UUID.dump!(fixture.admission_agent_id),
            Ecto.UUID.dump!(fixture.effect_id),
            Ecto.UUID.dump!(fixture.assignment_id),
            Ecto.UUID.dump!(fixture.activation_epoch),
            fixture.partition_id
          ]
        ).rows

      {lease_drained, effect_state, task_state, partition_state, marker, active_effects}
    end)
  end

  defp partition_admission_partition_state!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[state, marker]] =
        Repo.query!(
          "SELECT state, effects_drained_epoch FROM public.runtime_partitions WHERE partition_id = $1",
          [fixture.partition_id]
        ).rows

      {state, marker}
    end)
  end

  defp partition_admission_row_counts!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[leases, assignments, effects, active_effects]] =
        Repo.query!(
          """
          SELECT
            (SELECT COUNT(*) FROM public.agent_runtime_leases WHERE agent_id = $1::uuid),
            (SELECT COUNT(*) FROM public.runtime_task_assignments WHERE id = $2::uuid),
            (SELECT COUNT(*) FROM public.effects WHERE id = $3::uuid),
            (SELECT COUNT(*) FROM public.effects
             WHERE coordination_activation_epoch = $4::uuid
               AND coordination_partition_id = $5
               AND status IN ('pending', 'claimed', 'executing', 'cancelling'))
          """,
          [
            Ecto.UUID.dump!(fixture.admission_agent_id),
            Ecto.UUID.dump!(fixture.assignment_id),
            Ecto.UUID.dump!(fixture.effect_id),
            Ecto.UUID.dump!(fixture.activation_epoch),
            fixture.partition_id
          ]
        ).rows

      {leases, assignments, effects, active_effects}
    end)
  end

  defp converge_partition_admission_lease_gates!(fixture) do
    assert {:ok, :leases_deleted} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE NONE", [])
                 Repo.query!("SET LOCAL session_replication_role = replica", [])

                 Repo.query!(
                   "DELETE FROM public.agent_runtime_leases WHERE agent_id = $1::uuid",
                   [Ecto.UUID.dump!(fixture.agent_id)]
                 )

                 Repo.query!(
                   "DELETE FROM public.agent_runtime_leases WHERE agent_id = $1::uuid",
                   [Ecto.UUID.dump!(fixture.admission_agent_id)]
                 )

                 :leases_deleted
               end)
             end)
  end

  defp delete_partition_admission_fixture!(fixture) do
    result =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE NONE", [])
          Repo.query!("SET LOCAL session_replication_role = replica", [])

          Repo.query!("DELETE FROM public.effects WHERE id = $1::uuid", [
            Ecto.UUID.dump!(fixture.effect_id)
          ])

          Repo.query!("DELETE FROM public.runtime_task_assignments WHERE id = $1::uuid", [
            Ecto.UUID.dump!(fixture.assignment_id)
          ])

          Enum.each([fixture.agent_id, fixture.admission_agent_id], fn agent_id ->
            Repo.query!("DELETE FROM public.agent_runtime_leases WHERE agent_id = $1::uuid", [
              Ecto.UUID.dump!(agent_id)
            ])
          end)

          Repo.query!(
            """
            UPDATE public.runtime_leader_authorities
            SET activation_epoch = $1::uuid, leader_epoch = $2,
                node_incarnation_id = NULL, action_token = NULL,
                state = 'unassigned', lease_expires_at = NULL, ready_at = NULL,
                draining_at = NULL, updated_at = $3
            WHERE role = 'partition_planner' AND action_token = $4::uuid
            """,
            [
              fixture.previous_leader_activation_epoch,
              fixture.previous_leader_epoch,
              fixture.previous_leader_updated_at,
              Ecto.UUID.dump!(fixture.leader_action_token)
            ]
          )

          Repo.query!(
            """
            UPDATE public.runtime_partitions
            SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
                transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
                ready_at = NULL, draining_at = NULL, effects_drained_epoch = NULL,
                updated_at = timezone('UTC', clock_timestamp())
            WHERE partition_id = $1 AND owner_node_incarnation_id = $2::uuid
            """,
            [fixture.partition_id, Ecto.UUID.dump!(fixture.node_id)]
          )

          Repo.query!(
            """
            DELETE FROM public.runtime_partition_transitions
            WHERE partition_id = $1 AND (
              from_node_incarnation_id = $2::uuid OR
              to_node_incarnation_id = $2::uuid OR
              leader_node_incarnation_id = $2::uuid
            )
            """,
            [fixture.partition_id, Ecto.UUID.dump!(fixture.node_id)]
          )

          Repo.query!("DELETE FROM public.runtime_node_incarnations WHERE id = $1::uuid", [
            Ecto.UUID.dump!(fixture.node_id)
          ])

          Enum.each([fixture.agent_id, fixture.admission_agent_id], fn agent_id ->
            Repo.query!("DELETE FROM public.agents WHERE id = $1::uuid", [
              Ecto.UUID.dump!(agent_id)
            ])
          end)

          :ok
        end)
      end)

    assert {:ok, :ok} = result
  end

  defp insert_release_race_fixture!(activation_epoch) do
    base = insert_provider_lock_order_fixture!(activation_epoch)

    extra = %{
      effect_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      assignment_id: Ecto.UUID.generate(),
      assignment_work_id: Ecto.UUID.generate(),
      assignment_claim_token: Ecto.UUID.generate(),
      supervisor_id: Ecto.UUID.generate(),
      local_task_id: Ecto.UUID.generate(),
      termination_capability_digest: :crypto.strong_rand_bytes(32)
    }

    {:ok, params_ciphertext} =
      Maraithon.Encrypted.Map.dump(%{
        "__maraithon_effect_protocol" => 2,
        "__maraithon_execution_lane" => "tool",
        "tool" => "time",
        "args" => %{}
      })

    try do
      result =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL ROLE NONE", [])
            Repo.query!("SET LOCAL session_replication_role = replica", [])

            [
              [
                previous_activation_epoch,
                previous_leader_epoch,
                nil,
                nil,
                "unassigned",
                nil,
                nil,
                nil,
                previous_leader_updated_at
              ]
            ] =
              Repo.query!(
                """
                SELECT activation_epoch, leader_epoch, node_incarnation_id, action_token,
                       state, lease_expires_at, ready_at, draining_at, updated_at
                FROM public.runtime_leader_authorities
                WHERE role = 'partition_planner'
                FOR UPDATE
                """,
                []
              ).rows

            leader_epoch = previous_leader_epoch + 1

            Repo.query!(
              """
              UPDATE public.runtime_leader_authorities
              SET activation_epoch = $1::uuid, leader_epoch = $2,
                  node_incarnation_id = $3::uuid, action_token = $4::uuid,
                  state = 'ready', lease_expires_at =
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                  ready_at = timezone('UTC', clock_timestamp()), draining_at = NULL,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE role = 'partition_planner'
              """,
              [
                Ecto.UUID.dump!(activation_epoch),
                leader_epoch,
                Ecto.UUID.dump!(base.node_id),
                Ecto.UUID.dump!(base.leader_action_token)
              ]
            )

            Repo.query!(
              """
              UPDATE public.runtime_partition_transitions
              SET state = 'draining', updated_at = timezone('UTC', clock_timestamp())
              WHERE id = $1::uuid
              """,
              [Ecto.UUID.dump!(base.transition_id)]
            )

            Repo.query!(
              """
              UPDATE public.runtime_partitions
              SET state = 'draining', ready_at = NULL,
                  draining_at = timezone('UTC', clock_timestamp()),
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = $1
              """,
              [base.partition_id]
            )

            Repo.query!(
              """
              INSERT INTO public.runtime_task_assignments
                (id, activation_epoch, work_kind, work_id, claim_token,
                 partition_id, partition_epoch, node_incarnation_id, supervisor_id,
                 local_task_id, termination_capability_digest, state, provider_boundary,
                 lease_expires_at, ready_at, inserted_at, updated_at)
              VALUES ($1::uuid, $2::uuid, 'background_job', $3::uuid, $4::uuid,
                      $5, $6, $7::uuid, $8::uuid, $9::uuid, $10, 'running', 'entered',
                      timezone('UTC', clock_timestamp()) + interval '10 minutes',
                      timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
                      timezone('UTC', clock_timestamp()))
              """,
              [
                Ecto.UUID.dump!(extra.assignment_id),
                Ecto.UUID.dump!(activation_epoch),
                Ecto.UUID.dump!(extra.assignment_work_id),
                Ecto.UUID.dump!(extra.assignment_claim_token),
                base.partition_id,
                base.ownership_epoch,
                Ecto.UUID.dump!(base.node_id),
                Ecto.UUID.dump!(extra.supervisor_id),
                Ecto.UUID.dump!(extra.local_task_id),
                extra.termination_capability_digest
              ]
            )

            Repo.query!(
              """
              INSERT INTO public.effects
                (id, agent_id, owner_user_id, idempotency_key, effect_type,
                 params_ciphertext, params, effect_protocol_version,
                 payload_encryption_version, execution_lane, status,
                 runtime_owner_generation, coordination_activation_epoch,
                 coordination_partition_id, coordination_partition_epoch,
                 coordination_node_incarnation_id, attempts, max_attempts,
                 inserted_at, updated_at)
              VALUES ($1::uuid, $2::uuid, $3, $4::uuid, 'tool_call',
                      $5, '{"redacted": true}'::jsonb, 2, 1, 'tool', 'pending',
                      $6::uuid, $7::uuid, $8, $9, $10::uuid, 0, 3,
                      timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
              """,
              [
                Ecto.UUID.dump!(extra.effect_id),
                Ecto.UUID.dump!(base.agent_id),
                base.user_id,
                Ecto.UUID.dump!(extra.idempotency_key),
                params_ciphertext,
                Ecto.UUID.dump!(base.owner_token),
                Ecto.UUID.dump!(activation_epoch),
                base.partition_id,
                base.ownership_epoch,
                Ecto.UUID.dump!(base.node_id)
              ]
            )

            base
            |> Map.merge(extra)
            |> Map.merge(%{
              previous_leader_activation_epoch: previous_activation_epoch,
              previous_leader_epoch: previous_leader_epoch,
              previous_leader_updated_at: previous_leader_updated_at,
              leader: %{
                activation_epoch: activation_epoch,
                leader_epoch: leader_epoch,
                node_incarnation_id: base.node_id,
                action_token: base.leader_action_token
              }
            })
          end)
        end)

      case result do
        {:ok, fixture} -> fixture
        {:error, reason} -> raise "release-race fixture failed: #{inspect(reason)}"
      end
    rescue
      error ->
        delete_provider_lock_order_fixture!(base)
        reraise error, __STACKTRACE__
    end
  end

  defp delete_release_race_fixture!(fixture) do
    result =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE NONE", [])
          Repo.query!("SET LOCAL session_replication_role = replica", [])

          Repo.query!("DELETE FROM public.effects WHERE id = $1::uuid", [
            Ecto.UUID.dump!(fixture.effect_id)
          ])

          Repo.query!("DELETE FROM public.runtime_task_assignments WHERE id = $1::uuid", [
            Ecto.UUID.dump!(fixture.assignment_id)
          ])

          Repo.query!(
            """
            UPDATE public.runtime_leader_authorities
            SET activation_epoch = $1::uuid, leader_epoch = $2,
                node_incarnation_id = NULL, action_token = NULL,
                state = 'unassigned', lease_expires_at = NULL, ready_at = NULL,
                draining_at = NULL, updated_at = $3
            WHERE role = 'partition_planner' AND action_token = $4::uuid
            """,
            [
              fixture.previous_leader_activation_epoch,
              fixture.previous_leader_epoch,
              fixture.previous_leader_updated_at,
              Ecto.UUID.dump!(fixture.leader_action_token)
            ]
          )

          :ok
        end)
      end)

    assert {:ok, :ok} = result
    delete_provider_lock_order_fixture!(fixture)
  end

  defp bypass_release_without_effect_drain_marker!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        # Remove the independent durable gates only inside this doomed
        # transaction so the marker check is the boundary under test.
        Repo.query!("SET LOCAL ROLE NONE", [])
        Repo.query!("SET LOCAL session_replication_role = replica", [])

        Repo.query!("DELETE FROM public.agent_runtime_leases WHERE agent_id = $1::uuid", [
          Ecto.UUID.dump!(fixture.agent_id)
        ])

        Repo.query!(
          """
          UPDATE public.runtime_task_assignments
          SET state = 'outcome_ambiguous', provider_boundary = 'outcome_unknown',
              settled_at = timezone('UTC', clock_timestamp()),
              outcome = 'provider_outcome_ambiguous',
              updated_at = timezone('UTC', clock_timestamp())
          WHERE id = $1::uuid
          """,
          [Ecto.UUID.dump!(fixture.assignment_id)]
        )

        Repo.query!("SET LOCAL session_replication_role = origin", [])
        Repo.query!("SET LOCAL ROLE maraithon_runtime", [])

        Repo.query!(
          "SELECT set_config('maraithon.runtime_leader_action', $1, true)",
          [fixture.leader_action_token]
        )

        Repo.query!(
          """
          UPDATE public.runtime_partitions
          SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
              transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
              ready_at = NULL, draining_at = NULL, effects_drained_epoch = NULL,
              updated_at = timezone('UTC', clock_timestamp())
          WHERE partition_id = $1 AND activation_epoch = $2::uuid
            AND ownership_epoch = $3 AND owner_node_incarnation_id = $4::uuid
            AND state IN ('draining', 'blocked')
          """,
          [
            fixture.partition_id,
            Ecto.UUID.dump!(fixture.activation_epoch),
            fixture.ownership_epoch,
            Ecto.UUID.dump!(fixture.node_id)
          ]
        )
      end)
    end)
  end

  defp release_race_partition_topology!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[state, effects_drained_epoch, activation_epoch, ownership_epoch, node_id]] =
        Repo.query!(
          """
          SELECT state, effects_drained_epoch, activation_epoch::text,
                 ownership_epoch, owner_node_incarnation_id::text
          FROM public.runtime_partitions
          WHERE partition_id = $1
          """,
          [fixture.partition_id]
        ).rows

      {state, effects_drained_epoch, activation_epoch, ownership_epoch, node_id}
    end)
  end

  defp forge_release_effect_drain_marker!(fixture, isolation)
       when isolation in [:read_committed, :repeatable_read] do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        if isolation == :repeatable_read do
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        end

        Repo.query!("SET LOCAL ROLE maraithon_runtime", [])

        Repo.query!(
          "SELECT set_config('maraithon.runtime_node_action', $1, true)",
          [fixture.node_id]
        )

        Repo.query!(
          """
          UPDATE public.runtime_partitions
          SET effects_drained_epoch = ownership_epoch,
              updated_at = timezone('UTC', clock_timestamp())
          WHERE partition_id = $1 AND activation_epoch = $2::uuid
            AND ownership_epoch = $3 AND owner_node_incarnation_id = $4::uuid
            AND state IN ('draining', 'blocked')
          """,
          [
            fixture.partition_id,
            Ecto.UUID.dump!(fixture.activation_epoch),
            fixture.ownership_epoch,
            Ecto.UUID.dump!(fixture.node_id)
          ]
        )
      end)
    end)
  end

  defp release_race_call!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Authority.release_drained_partition(fixture.leader, fixture.partition_id)
    end)
  end

  defp release_race_effects_drained_epoch!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[effects_drained_epoch]] =
        Repo.query!(
          "SELECT effects_drained_epoch FROM public.runtime_partitions WHERE partition_id = $1",
          [fixture.partition_id]
        ).rows

      effects_drained_epoch
    end)
  end

  defp release_race_states!(fixture) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      [[effect_status]] =
        Repo.query!("SELECT status FROM public.effects WHERE id = $1::uuid", [
          Ecto.UUID.dump!(fixture.effect_id)
        ]).rows

      [[ready_at, draining_at]] =
        Repo.query!(
          "SELECT ready_at, draining_at FROM public.agent_runtime_leases WHERE agent_id = $1::uuid",
          [Ecto.UUID.dump!(fixture.agent_id)]
        ).rows

      [[assignment_state]] =
        Repo.query!("SELECT state FROM public.runtime_task_assignments WHERE id = $1::uuid", [
          Ecto.UUID.dump!(fixture.assignment_id)
        ]).rows

      [[effects_drained_epoch]] =
        Repo.query!(
          "SELECT effects_drained_epoch FROM public.runtime_partitions WHERE partition_id = $1",
          [fixture.partition_id]
        ).rows

      {effect_status, ready_at, not is_nil(draining_at), assignment_state, effects_drained_epoch}
    end)
  end

  defp converge_release_lease_gate!(fixture) do
    assert {:ok, :lease_converged} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE NONE", [])
                 Repo.query!("SET LOCAL session_replication_role = replica", [])

                 Repo.query!(
                   "DELETE FROM public.agent_runtime_leases WHERE agent_id = $1::uuid",
                   [Ecto.UUID.dump!(fixture.agent_id)]
                 )

                 :lease_converged
               end)
             end)
  end

  defp converge_release_task_gate!(fixture) do
    assert {:ok, :task_converged} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL ROLE NONE", [])
                 Repo.query!("SET LOCAL session_replication_role = replica", [])

                 Repo.query!(
                   """
                   UPDATE public.runtime_task_assignments
                   SET state = 'outcome_ambiguous', provider_boundary = 'outcome_unknown',
                       settled_at = timezone('UTC', clock_timestamp()),
                       outcome = 'provider_outcome_ambiguous',
                       updated_at = timezone('UTC', clock_timestamp())
                   WHERE id = $1::uuid
                   """,
                   [Ecto.UUID.dump!(fixture.assignment_id)]
                 )

                 :task_converged
               end)
             end)
  end

  defp insert_provider_lock_order_fixture!(activation_epoch) do
    available_partitions =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT partition_id FROM public.runtime_partitions WHERE state = 'unassigned'",
          []
        ).rows
        |> Enum.map(fn [partition_id] -> partition_id end)
        |> MapSet.new()
      end)

    nonce = System.unique_integer([:positive])

    {user_id, partition_id} =
      Enum.find_value(0..10_000, fn attempt ->
        user_id = "lock-order-provider-#{nonce}-#{attempt}"
        partition_id = Partitioning.partition_for("user:" <> user_id)
        if MapSet.member?(available_partitions, partition_id), do: {user_id, partition_id}
      end) || flunk("no unassigned partition was available for provider lock-order fixture")

    fixture = %{
      activation_epoch: activation_epoch,
      node_id: Ecto.UUID.generate(),
      transition_id: Ecto.UUID.generate(),
      leader_action_token: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      owner_token: Ecto.UUID.generate(),
      user_id: user_id,
      partition_id: partition_id
    }

    result =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE NONE", [])
          Repo.query!("SET LOCAL session_replication_role = replica", [])

          [[previous_epoch]] =
            Repo.query!(
              "SELECT ownership_epoch FROM public.runtime_partitions WHERE partition_id = $1 AND state = 'unassigned' FOR UPDATE",
              [partition_id]
            ).rows

          ownership_epoch = previous_epoch + 1

          Repo.query!(
            """
            INSERT INTO public.runtime_node_incarnations
              (id, activation_epoch, node_name, revision, state, lease_expires_at,
               ready_at, metadata, inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, 'lock-order-provider', $3, 'ready',
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                    timezone('UTC', clock_timestamp()), '{}'::jsonb,
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.node_id),
              Ecto.UUID.dump!(activation_epoch),
              @revision
            ]
          )

          Repo.query!(
            """
            INSERT INTO public.runtime_partition_transitions
              (id, activation_epoch, partition_id, partition_epoch,
               from_node_incarnation_id, kind, state, leader_node_incarnation_id,
               leader_epoch, leader_action_token, requested_at, ready_at,
               inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, $3, $4, $5::uuid, 'assign', 'ready',
                    $5::uuid, 1, $6::uuid, timezone('UTC', clock_timestamp()),
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
                    timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.transition_id),
              Ecto.UUID.dump!(activation_epoch),
              partition_id,
              ownership_epoch,
              Ecto.UUID.dump!(fixture.node_id),
              Ecto.UUID.dump!(fixture.leader_action_token)
            ]
          )

          %{num_rows: 1} =
            Repo.query!(
              """
              UPDATE public.runtime_partitions
              SET activation_epoch = $2::uuid, ownership_epoch = $3,
                  owner_node_incarnation_id = $4::uuid, transition_id = $5::uuid,
                  state = 'ready', lease_expires_at =
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                  ready_at = timezone('UTC', clock_timestamp()), draining_at = NULL,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = $1 AND state = 'unassigned'
              """,
              [
                partition_id,
                Ecto.UUID.dump!(activation_epoch),
                ownership_epoch,
                Ecto.UUID.dump!(fixture.node_id),
                Ecto.UUID.dump!(fixture.transition_id)
              ]
            )

          Repo.query!(
            """
            INSERT INTO public.agents
              (id, behavior, status, started_at, user_id, inserted_at, updated_at)
            VALUES ($1::uuid, 'prompt_agent', 'running',
                    timezone('UTC', clock_timestamp()), $2,
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            """,
            [Ecto.UUID.dump!(fixture.agent_id), user_id]
          )

          Repo.query!(
            """
            INSERT INTO public.agent_runtime_leases
              (agent_id, owner_token, owner_node, claimed_at, lease_until, renewed_at,
               ready_at, coordination_activation_epoch, coordination_partition_id,
               coordination_partition_epoch, coordination_node_incarnation_id,
               inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, 'lock-order-provider',
                    timezone('UTC', clock_timestamp()) - interval '1 second',
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
                    $3::uuid, $4, $5, $6::uuid,
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.agent_id),
              Ecto.UUID.dump!(fixture.owner_token),
              Ecto.UUID.dump!(activation_epoch),
              partition_id,
              ownership_epoch,
              Ecto.UUID.dump!(fixture.node_id)
            ]
          )

          Map.put(fixture, :ownership_epoch, ownership_epoch)
        end)
      end)

    case result do
      {:ok, committed_fixture} -> committed_fixture
      {:error, reason} -> flunk("provider lock-order fixture failed: #{inspect(reason)}")
    end
  end

  defp delete_provider_lock_order_fixture!(fixture) do
    case Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
           Repo.transaction(fn ->
             Repo.query!("SET LOCAL ROLE NONE", [])
             Repo.query!("SET LOCAL session_replication_role = replica", [])

             Repo.query!("DELETE FROM public.agent_runtime_leases WHERE agent_id = $1::uuid", [
               Ecto.UUID.dump!(fixture.agent_id)
             ])

             Repo.query!(
               """
               UPDATE public.runtime_partitions
               SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
                   transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
                   ready_at = NULL, draining_at = NULL, effects_drained_epoch = NULL,
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE partition_id = $1 AND owner_node_incarnation_id = $2::uuid
               """,
               [fixture.partition_id, Ecto.UUID.dump!(fixture.node_id)]
             )

             Repo.query!(
               "DELETE FROM public.runtime_partition_transitions WHERE id = $1::uuid",
               [Ecto.UUID.dump!(fixture.transition_id)]
             )

             Repo.query!(
               "DELETE FROM public.runtime_node_incarnations WHERE id = $1::uuid",
               [Ecto.UUID.dump!(fixture.node_id)]
             )

             Repo.query!("DELETE FROM public.agents WHERE id = $1::uuid", [
               Ecto.UUID.dump!(fixture.agent_id)
             ])

             :ok
           end)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> flunk("provider lock-order cleanup failed: #{inspect(reason)}")
    end
  end

  defp insert_lock_order_fixture!(activation_epoch) do
    fixture = %{
      activation_epoch: activation_epoch,
      node_id: Ecto.UUID.generate(),
      transition_id: Ecto.UUID.generate(),
      effect_id: Ecto.UUID.generate(),
      assignment_id: Ecto.UUID.generate(),
      effect_claim_token: Ecto.UUID.generate(),
      assignment_claim_token: Ecto.UUID.generate(),
      supervisor_id: Ecto.UUID.generate(),
      local_task_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      owner_generation: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      leader_action_token: Ecto.UUID.generate(),
      termination_capability_digest: :crypto.strong_rand_bytes(32)
    }

    {:ok, params_ciphertext} =
      Maraithon.Encrypted.Map.dump(%{
        "__maraithon_effect_protocol" => 2,
        "__maraithon_execution_lane" => "tool",
        "tool" => "time",
        "args" => %{}
      })

    result =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          # The fixture must be committed so two physical test connections can
          # contend on it. Replica mode bypasses one-way history triggers only
          # for this transaction; all shape constraints remain enforced.
          Repo.query!("SET LOCAL ROLE NONE", [])
          Repo.query!("SET LOCAL session_replication_role = replica", [])

          [[partition_id, previous_epoch]] =
            Repo.query!(
              """
              SELECT partition_id, ownership_epoch
              FROM public.runtime_partitions
              WHERE state = 'unassigned'
              ORDER BY partition_id
              LIMIT 1
              FOR UPDATE
              """,
              []
            ).rows

          ownership_epoch = previous_epoch + 1

          Repo.query!(
            """
            INSERT INTO public.runtime_node_incarnations
              (id, activation_epoch, node_name, revision, state, lease_expires_at,
               ready_at, metadata, inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, 'lock-order-fixture', $3, 'ready',
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                    timezone('UTC', clock_timestamp()), '{}'::jsonb,
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.node_id),
              Ecto.UUID.dump!(activation_epoch),
              @revision
            ]
          )

          Repo.query!(
            """
            INSERT INTO public.runtime_partition_transitions
              (id, activation_epoch, partition_id, partition_epoch,
               from_node_incarnation_id, kind, state, leader_node_incarnation_id,
               leader_epoch, leader_action_token, requested_at, inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, $3, $4, $5::uuid, 'shutdown', 'draining',
                    $5::uuid, 1, $6::uuid, timezone('UTC', clock_timestamp()),
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.transition_id),
              Ecto.UUID.dump!(activation_epoch),
              partition_id,
              ownership_epoch,
              Ecto.UUID.dump!(fixture.node_id),
              Ecto.UUID.dump!(fixture.leader_action_token)
            ]
          )

          %{num_rows: 1} =
            Repo.query!(
              """
              UPDATE public.runtime_partitions
              SET activation_epoch = $2::uuid, ownership_epoch = $3,
                  owner_node_incarnation_id = $4::uuid, transition_id = $5::uuid,
                  state = 'draining', lease_expires_at =
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                  ready_at = NULL, draining_at = timezone('UTC', clock_timestamp()),
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = $1 AND state = 'unassigned'
              """,
              [
                partition_id,
                Ecto.UUID.dump!(activation_epoch),
                ownership_epoch,
                Ecto.UUID.dump!(fixture.node_id),
                Ecto.UUID.dump!(fixture.transition_id)
              ]
            )

          Repo.query!(
            """
            INSERT INTO public.runtime_task_assignments
              (id, activation_epoch, work_kind, work_id, claim_token,
               partition_id, partition_epoch, node_incarnation_id, supervisor_id,
               local_task_id, termination_capability_digest, state, provider_boundary,
               lease_expires_at, ready_at, inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, 'effect', $3::uuid, $4::uuid,
                    $5, $6, $7::uuid, $8::uuid, $9::uuid, $10, 'running', 'entered',
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                    timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
                    timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.assignment_id),
              Ecto.UUID.dump!(activation_epoch),
              Ecto.UUID.dump!(fixture.effect_id),
              Ecto.UUID.dump!(fixture.assignment_claim_token),
              partition_id,
              ownership_epoch,
              Ecto.UUID.dump!(fixture.node_id),
              Ecto.UUID.dump!(fixture.supervisor_id),
              Ecto.UUID.dump!(fixture.local_task_id),
              fixture.termination_capability_digest
            ]
          )

          Repo.query!(
            """
            INSERT INTO public.effects
              (id, agent_id, owner_user_id, idempotency_key, effect_type,
               params_ciphertext, params, effect_protocol_version,
               payload_encryption_version, execution_lane, status, claimed_by,
               claimed_at, runtime_owner_generation, claim_token, claim_owner_node,
               claim_heartbeat_at, claim_expires_at, claim_supervisor_id, claim_task_id,
               coordination_activation_epoch, coordination_partition_id,
               coordination_partition_epoch, coordination_node_incarnation_id,
               coordination_task_assignment_id, attempts, max_attempts,
               inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, 'lock-order-fixture', $3::uuid, 'tool_call',
                    $4, '{"redacted": true}'::jsonb, 2, 1, 'tool', 'claimed',
                    'lock-order-fixture', timezone('UTC', clock_timestamp()), $5::uuid,
                    $6::uuid, 'lock-order-fixture', timezone('UTC', clock_timestamp()),
                    timezone('UTC', clock_timestamp()) + interval '10 minutes',
                    $7::uuid, $8::uuid, $9::uuid, $10, $11, $12::uuid, $13::uuid,
                    0, 3, timezone('UTC', clock_timestamp()),
                    timezone('UTC', clock_timestamp()))
            """,
            [
              Ecto.UUID.dump!(fixture.effect_id),
              Ecto.UUID.dump!(fixture.agent_id),
              Ecto.UUID.dump!(fixture.idempotency_key),
              params_ciphertext,
              Ecto.UUID.dump!(fixture.owner_generation),
              Ecto.UUID.dump!(fixture.effect_claim_token),
              Ecto.UUID.dump!(fixture.supervisor_id),
              Ecto.UUID.dump!(fixture.local_task_id),
              Ecto.UUID.dump!(activation_epoch),
              partition_id,
              ownership_epoch,
              Ecto.UUID.dump!(fixture.node_id),
              Ecto.UUID.dump!(fixture.assignment_id)
            ]
          )

          Map.merge(fixture, %{partition_id: partition_id, ownership_epoch: ownership_epoch})
        end)
      end)

    case result do
      {:ok, committed_fixture} -> committed_fixture
      {:error, reason} -> flunk("lock-order fixture failed: #{inspect(reason)}")
    end
  end

  defp delete_lock_order_fixture!(fixture) do
    case Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
           Repo.transaction(fn ->
             Repo.query!("SET LOCAL ROLE NONE", [])
             Repo.query!("SET LOCAL session_replication_role = replica", [])

             Repo.query!("DELETE FROM public.effects WHERE id = $1::uuid", [
               Ecto.UUID.dump!(fixture.effect_id)
             ])

             Repo.query!(
               "DELETE FROM public.runtime_task_assignments WHERE id = $1::uuid",
               [Ecto.UUID.dump!(fixture.assignment_id)]
             )

             Repo.query!(
               """
               UPDATE public.runtime_partitions
               SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
                   transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
                   ready_at = NULL, draining_at = NULL,
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE partition_id = $1 AND owner_node_incarnation_id = $2::uuid
               """,
               [fixture.partition_id, Ecto.UUID.dump!(fixture.node_id)]
             )

             Repo.query!(
               "DELETE FROM public.runtime_partition_transitions WHERE id = $1::uuid",
               [Ecto.UUID.dump!(fixture.transition_id)]
             )

             Repo.query!(
               "DELETE FROM public.runtime_node_incarnations WHERE id = $1::uuid",
               [Ecto.UUID.dump!(fixture.node_id)]
             )

             :ok
           end)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> flunk("lock-order fixture cleanup failed: #{inspect(reason)}")
    end
  end

  defp await_database_blocker!(waiter, waiter_backend_pid, blocker_backend_pid),
    do: await_database_blocker!(waiter, waiter_backend_pid, blocker_backend_pid, 500)

  defp await_database_blocker!(_waiter, waiter_backend_pid, blocker_backend_pid, 0) do
    flunk("backend #{waiter_backend_pid} never blocked behind backend #{blocker_backend_pid}")
  end

  defp await_database_blocker!(waiter, waiter_backend_pid, blocker_backend_pid, attempts) do
    case Task.yield(waiter, 10) do
      nil ->
        [[blocking_pids]] =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.query!("SELECT pg_catalog.pg_blocking_pids($1)", [waiter_backend_pid]).rows
          end)

        if blocker_backend_pid in blocking_pids do
          :ok
        else
          await_database_blocker!(
            waiter,
            waiter_backend_pid,
            blocker_backend_pid,
            attempts - 1
          )
        end

      completed ->
        flunk("waiter completed before the database-lock barrier: #{inspect(completed)}")
    end
  end

  defp assert_topology_available!(node_id, partition_id) do
    assert {:ok, :topology_available} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!(
                   "SELECT id FROM public.runtime_node_incarnations WHERE id = $1::uuid FOR UPDATE NOWAIT",
                   [Ecto.UUID.dump!(node_id)]
                 )

                 Repo.query!(
                   "SELECT partition_id FROM public.runtime_partitions WHERE partition_id = $1 FOR UPDATE NOWAIT",
                   [partition_id]
                 )

                 :topology_available
               end)
             end)
  end

  defp shutdown_task(%Task{} = task) do
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp refute_secret_telemetry(secret, encoded) do
    receive do
      {:repo_query_telemetry, _event, _measurements, metadata} ->
        refute term_contains_binary?(metadata, secret)
        refute term_contains_binary?(metadata, encoded)
        refute_secret_telemetry(secret, encoded)
    after
      0 -> :ok
    end
  end

  defp term_contains_binary?(term, needle) when is_binary(term),
    do: :binary.match(term, needle) != :nomatch

  defp term_contains_binary?(term, needle) when is_map(term),
    do: Enum.any?(Map.to_list(term), &term_contains_binary?(&1, needle))

  defp term_contains_binary?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&term_contains_binary?(&1, needle))

  defp term_contains_binary?(term, needle) when is_list(term),
    do: Enum.any?(term, &term_contains_binary?(&1, needle))

  defp term_contains_binary?(_term, _needle), do: false

  defp ok!({:ok, value}), do: value
end
