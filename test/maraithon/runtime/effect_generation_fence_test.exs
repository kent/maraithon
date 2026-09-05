defmodule Maraithon.Runtime.EffectGenerationFenceTest do
  use Maraithon.DataCase, async: false

  @moduletag database_role: :session

  alias Ecto.Adapters.SQL
  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.DurablePayloadContraction
  alias Maraithon.DurablePayloadVerification
  alias Maraithon.Effects
  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.CancellationPlan
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Effects.TerminationAttestations
  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.EffectClaimRenewer
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.EffectTaskAuthority
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  alias Maraithon.Runtime.Coordination.{
    Authority,
    Partition,
    Partitioning,
    Scope,
    TaskClaims
  }

  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @activation_evidence [
    evidence_id: "test:stopped-fleet:effect-generation-fence",
    evidence_digest: :crypto.hash(:sha256, "test stopped fleet evidence"),
    activated_by: "effect-generation-fence@example.test",
    revision: String.duplicate("a", 40)
  ]

  defmodule BlockingProvider do
    @moduledoc false

    def complete(params) do
      test_pid = Application.fetch_env!(:maraithon, :generation_fence_test_pid)
      send(test_pid, {:exact_provider_entered, self(), params})

      receive do
        :release ->
          {:ok,
           %{
             content: "released",
             model: "blocking-v1",
             tokens_in: 1,
             tokens_out: 1,
             finish_reason: "stop",
             usage: %{}
           }}
      after
        10_000 -> {:error, :provider_timeout}
      end
    end
  end

  setup_all do
    # Stable Guardian/Authority processes can outlive a prior sandbox owner.
    # Start this case from an empty physical-task generation.
    restart_task_system!()
    :ok
  end

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      original_runtime
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.delete(:coordination_test_session)
    )

    # DataCase registered Sandbox.stop_owner/1 first. ExUnit runs this later
    # callback first, so all retained capabilities and retry timers are stopped
    # synchronously while the current shared sandbox owner still exists.
    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      restart_task_system!()
    end)

    assert ProtocolCutover.mode() == :legacy

    assert {:ok, :attested} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)

    :ok
  end

  test "public Effect changesets cannot mass-assign execution authority" do
    changeset =
      Effect.changeset(%Effect{}, %{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate(),
        effect_type: "tool_call",
        runtime_owner_generation: Ecto.UUID.generate(),
        claim_token: Ecto.UUID.generate(),
        status: "completed",
        cancellation_state: "settled",
        result_envelope: %{"status" => "ok"}
      })

    refute Map.has_key?(changeset.changes, :runtime_owner_generation)
    refute Map.has_key?(changeset.changes, :claim_token)
    refute Map.has_key?(changeset.changes, :status)
    refute Map.has_key?(changeset.changes, :cancellation_state)
    refute Map.has_key?(changeset.changes, :result_envelope)
  end

  test "claim renewal is a stable no-op with no exact work in legacy mode" do
    renewer = Process.whereis(EffectClaimRenewer)
    assert is_pid(renewer)
    assert {:ok, %{active: 0, lost: 0}} = EffectClaimRenewer.renew_now()
    assert Process.whereis(EffectClaimRenewer) == renewer
  end

  test "legacy payload writers dual-write before irreversible encrypted contraction" do
    agent = legacy_agent("durable-payload-encryption")
    sentinel = "payload-sentinel-#{System.unique_integer([:positive])}"

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{"secret" => sentinel})

    effect = Repo.get!(Effect, effect_id)
    assert get_in(effect.params, ["args", "secret"]) == sentinel
    assert get_in(effect.legacy_params, ["args", "secret"]) == sentinel
    assert effect.payload_encryption_version == 1

    assert %{rows: [[legacy_effect_params, 0]]} =
             SQL.query!(
               Repo,
               """
               SELECT params,
                      position(convert_to($2, 'UTF8') in params_ciphertext)
               FROM public.effects
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(effect_id), sentinel]
             )

    assert get_in(legacy_effect_params, ["args", "secret"]) == sentinel

    assert {:ok, directive} =
             AgentDirectives.enqueue(
               agent.id,
               agent.user_id,
               "message",
               %{"body" => sentinel},
               "payload-encryption-#{System.unique_integer([:positive])}"
             )

    stored_directive = Repo.get!(AgentDirective, directive.id)
    assert stored_directive.payload == %{"body" => sentinel}
    assert stored_directive.legacy_payload == %{"body" => sentinel}
    assert stored_directive.payload_encryption_version == 1

    assert %{rows: [[%{"body" => ^sentinel}, 0]]} =
             SQL.query!(
               Repo,
               """
               SELECT payload,
                      position(convert_to($2, 'UTF8') in payload_ciphertext)
               FROM public.agent_directives
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(directive.id), sentinel]
             )

    settle_legacy_effect!(effect_id)
    settle_legacy_directive!(stored_directive)

    assert {:ok, :contracted} =
             authoritative_payload_contraction(fn ->
               assert {:ok, 1} = Effects.backfill_legacy_payload_encryption()
               assert {:ok, 1} = AgentDirectives.backfill_legacy_payload_encryption()
               :contracted
             end)

    assert Repo.get!(Effect, effect_id).params == effect.params
    assert Repo.get!(AgentDirective, directive.id).payload == stored_directive.payload

    assert %{rows: [[%{"redacted" => true}, %{"redacted" => true}]]} =
             SQL.query!(
               Repo,
               """
               SELECT
                 (SELECT params FROM public.effects WHERE id = $1::uuid),
                 (SELECT payload FROM public.agent_directives WHERE id = $2::uuid)
               """,
               [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(directive.id)]
             )
  end

  test "an unactivated exact Agent incarnation expires its spawn-monitor window" do
    agent = legacy_agent("exact-activation-watchdog")

    assert {:ok, pid} =
             RuntimeAgent.start_link(%{
               agent: agent,
               owner_token: Ecto.UUID.generate(),
               guard_generation: nil,
               lease_ttl_ms: 1_000,
               lease_renew_interval_ms: 1
             })

    Process.unlink(pid)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :exact_activation_timeout}, 1_500
  end

  test "structural index attestation accepts equivalent catalogs and rejects drift" do
    as_database_owner(fn ->
      expiry_name = "effects_exact_claim_expiry_index"
      SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE INDEX #{expiry_name}
        ON public.effects USING btree (
          claim_expires_at ASC NULLS LAST,
          id ASC NULLS LAST
        )
        WHERE status IN ('claimed', 'executing')
          AND runtime_owner_generation IS NOT NULL
          AND claim_token IS NOT NULL
        """,
        []
      )

      assert %{rows: [[true]]} =
               SQL.query!(
                 Repo,
                 "SELECT public.generation_fenced_effect_index_matches($1)",
                 [expiry_name]
               )

      SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE INDEX #{expiry_name}
        ON public.effects (id, claim_expires_at)
        WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL AND
              claim_token IS NOT NULL
        """,
        []
      )

      assert %{rows: [[false]]} =
               SQL.query!(
                 Repo,
                 "SELECT public.generation_fenced_effect_index_matches($1)",
                 [expiry_name]
               )

      SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE INDEX #{expiry_name}
        ON public.effects (claim_expires_at DESC, id)
        WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL AND
              claim_token IS NOT NULL
        """,
        []
      )

      assert %{rows: [[false]]} =
               SQL.query!(
                 Repo,
                 "SELECT public.generation_fenced_effect_index_matches($1)",
                 [expiry_name]
               )

      SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE INDEX #{expiry_name}
        ON public.effects (claim_expires_at, id)
        WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL
        """,
        []
      )

      assert %{rows: [[false]]} =
               SQL.query!(
                 Repo,
                 "SELECT public.generation_fenced_effect_index_matches($1)",
                 [expiry_name]
               )

      SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE INDEX #{expiry_name}
        ON public.effects (claim_expires_at, id)
        WHERE status = 'CLAIMED' AND runtime_owner_generation IS NOT NULL AND
              claim_token IS NOT NULL
        """,
        []
      )

      assert %{rows: [[false]]} =
               SQL.query!(
                 Repo,
                 "SELECT public.generation_fenced_effect_index_matches($1)",
                 [expiry_name]
               )

      SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE INDEX #{expiry_name}
        ON public.effects (claim_expires_at, id)
        WHERE status IN ('claimed', 'executing') AND
              runtime_owner_generation IS NOT NULL AND claim_token IS NOT NULL
        """,
        []
      )

      physical_name = "effects_physical_task_identity_unique_index"
      SQL.query!(Repo, "DROP INDEX public.#{physical_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE UNIQUE INDEX #{physical_name}
        ON public.effects (claim_owner_node text_pattern_ops, claim_supervisor_id, claim_task_id)
        WHERE claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL
        """,
        []
      )

      assert %{rows: [[false]]} =
               SQL.query!(
                 Repo,
                 "SELECT public.generation_fenced_effect_index_matches($1)",
                 [physical_name]
               )

      SQL.query!(Repo, "DROP INDEX public.#{physical_name}", [])

      SQL.query!(
        Repo,
        """
        CREATE UNIQUE INDEX #{physical_name}
        ON public.effects (claim_owner_node, claim_supervisor_id, claim_task_id)
        WHERE claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL
        """,
        []
      )
    end)
  end

  test "activation lock contention fails closed and remains retryable" do
    parent = self()

    {blocker, blocker_ref} =
      spawn_monitor(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            SQL.query!(Repo, "LOCK TABLE public.effects IN ROW EXCLUSIVE MODE", [])
            send(parent, :effect_activation_lock_held)

            receive do
              :release_effect_activation_lock -> :ok
            end
          end)
        end)
      end)

    assert_receive :effect_activation_lock_held, 2_000

    assert {:error, :effect_protocol_lock_timeout} =
             ProtocolCutover.activate(
               [
                 confirmation: ProtocolCutover.activation_confirmation(),
                 lock_timeout_ms: 100
               ] ++ @activation_evidence
             )

    assert ProtocolCutover.mode() == :legacy
    send(blocker, :release_effect_activation_lock)
    assert_receive {:DOWN, ^blocker_ref, :process, ^blocker, :normal}, 2_000
  end

  test "direct SQL activation refuses a missing required migration record" do
    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "DELETE FROM public.schema_migrations WHERE version = 20260810132102",
        []
      )
    end)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            SQL.query!(Repo, "SET LOCAL ROLE maraithon_activation_operator", [])

            SQL.query!(
              Repo,
              "SELECT set_config('maraithon.effect_protocol_activation', 'generation_fenced_v1', true)",
              []
            )

            SQL.query!(
              Repo,
              """
              UPDATE public.effect_execution_protocols
              SET mode = 'generation_fenced_v1',
                  activated_at = timezone('UTC', clock_timestamp()),
                  activation_epoch = $1::uuid
              WHERE name = 'effects'
              """,
              [Ecto.UUID.dump!(Ecto.UUID.generate())]
            )
          end,
          mode: :savepoint
        )
      end

    assert Exception.message(error) =~
             "requires separated payload verifier privileges and catalog authority"

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        """
        INSERT INTO public.schema_migrations(version, inserted_at)
        VALUES (20260810132102, timezone('UTC', clock_timestamp()))
        ON CONFLICT (version) DO NOTHING
        """,
        []
      )
    end)
  end

  test "activation attests constraint definitions and trigger function source" do
    assert {:ok, :activated} = activate_exact()

    assert {:error, :constraint_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(Repo, "RESET ROLE", [])

                 SQL.query!(
                   Repo,
                   "ALTER TABLE public.effects DROP CONSTRAINT effects_execution_status_check",
                   []
                 )

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.effects
                   ADD CONSTRAINT effects_execution_status_check CHECK (TRUE)
                   """,
                   []
                 )

                 assert {:blocked, :durable_payload_verifier_privileges_not_ready} =
                          ProtocolCutover.mode()

                 Repo.rollback(:constraint_drift_probe)
               end,
               mode: :savepoint
             )

    assert :ok = ProtocolCutover.activation_preconditions()

    assert {:error, :function_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(Repo, "RESET ROLE", [])

                 SQL.query!(
                   Repo,
                   """
                   CREATE OR REPLACE FUNCTION public.enforce_effect_execution_protocol()
                   RETURNS trigger
                   LANGUAGE plpgsql
                   SET search_path = pg_catalog, public
                   AS $function$
                   BEGIN
                     IF TG_OP = 'DELETE' THEN
                       RETURN OLD;
                     END IF;

                     RETURN NEW;
                   END;
                   $function$;
                   """,
                   []
                 )

                 assert {:blocked, :durable_payload_verifier_privileges_not_ready} =
                          ProtocolCutover.mode()

                 Repo.rollback(:function_drift_probe)
               end,
               mode: :savepoint
             )

    assert :ok = ProtocolCutover.activation_preconditions()

    assert {:error, :catalog_helper_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(Repo, "RESET ROLE", [])

                 SQL.query!(
                   Repo,
                   """
                   CREATE OR REPLACE FUNCTION public.generation_fenced_effect_indexes_ready_count()
                   RETURNS bigint
                   LANGUAGE sql
                   STABLE
                   SET search_path = pg_catalog, public
                   AS $function$ SELECT 5::bigint $function$;
                   """,
                   []
                 )

                 assert {:blocked, {:effect_protocol_catalog_helpers_not_ready, 6}} =
                          ProtocolCutover.mode()

                 Repo.rollback(:catalog_helper_drift_probe)
               end,
               mode: :savepoint
             )

    assert {:error, :manifest_guard_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(Repo, "RESET ROLE", [])

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.effect_execution_protocol_manifests
                   DISABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger
                   """,
                   []
                 )

                 assert {:blocked, :durable_payload_verifier_privileges_not_ready} =
                          ProtocolCutover.mode()

                 Repo.rollback(:manifest_guard_drift_probe)
               end,
               mode: :savepoint
             )

    assert :ok = ProtocolCutover.activation_preconditions()
  end

  test "activation refuses unresolved durable Agent run and step rows" do
    agent = legacy_agent("effect-cutover-work-graph")
    now = DateTime.utc_now()

    run =
      %AgentRun{}
      |> AgentRun.changeset(%{
        agent_id: agent.id,
        user_id: agent.user_id,
        behavior: agent.behavior,
        status: "running",
        trigger_type: "manual",
        started_at: now
      })
      |> Repo.insert!()

    step =
      %AgentRunStep{}
      |> AgentRunStep.changeset(%{
        agent_run_id: run.id,
        agent_id: agent.id,
        sequence: 1,
        step_type: "tool",
        status: "requested",
        started_at: now
      })
      |> Repo.insert!()

    assert {:error, {:durable_agent_work_requires_drain, 0, 1, 1}} = activate_exact()

    assert_raise Postgrex.Error, ~r/requires drained durable Agent work/, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SET LOCAL ROLE maraithon_activation_operator", [])

          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.effect_protocol_activation', 'generation_fenced_v1', true)",
            []
          )

          SQL.query!(
            Repo,
            """
            UPDATE public.effect_execution_protocols
            SET mode = 'generation_fenced_v1',
                activated_at = timezone('UTC', clock_timestamp()),
                activation_epoch = gen_random_uuid(),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE name = 'effects'
            """,
            []
          )
        end,
        mode: :savepoint
      )
    end

    step
    |> AgentRunStep.changeset(%{
      status: "failed",
      error: "cutover_drained",
      completed_at: now
    })
    |> Repo.update!()

    run
    |> AgentRun.changeset(%{status: "completed", completed_at: now})
    |> Repo.update!()

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("agent_runs", limit: 10)

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("agent_run_steps", limit: 10)

    assert {:ok, :activated} = activate_exact()
  end

  test "exact activation rejects unmarked Directive writers" do
    agent = legacy_agent("directive-protocol-writer-fence")

    assert {:ok, directive} =
             AgentDirectives.enqueue(
               agent.id,
               agent.user_id,
               "message",
               %{"body" => "encrypted"},
               "directive-writer-fence"
             )

    settle_legacy_directive!(directive)

    assert {:ok, {:ok, 1}} =
             authoritative_payload_contraction(fn ->
               AgentDirectives.backfill_legacy_payload_encryption()
             end)

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("agent_directives", limit: 10)

    assert {:ok, :activated} = activate_exact()

    assert_raise Postgrex.Error,
                 ~r/requires generation-fenced writer marker/,
                 fn ->
                   Repo.transaction(
                     fn ->
                       SQL.query!(
                         Repo,
                         "UPDATE public.agent_directives SET attempts = attempts WHERE id = $1::uuid",
                         [Ecto.UUID.dump!(directive.id)]
                       )
                     end,
                     mode: :savepoint
                   )
                 end
  end

  test "activation is DB-owned, refuses undrained legacy work, and cannot downgrade" do
    SQL.query!(Repo, "CREATE TEMP TABLE effect_execution_protocols (name text, mode text)", [])

    SQL.query!(
      Repo,
      "INSERT INTO pg_temp.effect_execution_protocols VALUES ('effects', 'generation_fenced_v1')",
      []
    )

    SQL.query!(Repo, "SET LOCAL search_path = pg_temp, public", [])
    assert ProtocolCutover.mode() == :legacy
    SQL.query!(Repo, "SET LOCAL search_path = public", [])
    SQL.query!(Repo, "DROP TABLE pg_temp.effect_execution_protocols", [])

    agent = legacy_agent("effect-cutover")
    owner_generation = Ecto.UUID.generate()

    assert {:error, :durable_effect_cancellation_disabled} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    assert {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SET LOCAL ROLE maraithon_activation_operator", [])

          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.effect_protocol_activation', 'generation_fenced_v1', true)",
            []
          )

          SQL.query!(
            Repo,
            """
            UPDATE public.effect_execution_protocols
            SET mode = 'generation_fenced_v1',
                activated_at = timezone('UTC', clock_timestamp()),
                activation_epoch = $1::uuid
            WHERE name = 'effects'
            """,
            [Ecto.UUID.dump!(Ecto.UUID.generate())]
          )
        end,
        mode: :savepoint
      )
    end

    assert {:error, {:legacy_effects_require_drain, 1, 0}} = activate_exact()

    now = DateTime.utc_now()

    Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
      set: [
        status: "completed",
        result: %{"ok" => true},
        result_envelope: TerminalEnvelope.success(),
        updated_at: now
      ]
    )

    assert {:error, {:legacy_effects_require_drain, 0, 1}} = activate_exact()

    Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
      set: [result_acknowledged_at: now, updated_at: now]
    )

    assert {:ok, {:ok, 1}} =
             authoritative_payload_contraction(fn ->
               Effects.backfill_legacy_payload_encryption()
             end)

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("effects", limit: 10)

    assert {:ok, :activated} = activate_exact()
    assert ProtocolCutover.mode() == :exact
    assert {:ok, :already_active} = activate_exact()

    assert {:error, :safe_legacy_delete_probe} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               assert {1, nil} =
                        Repo.delete_all(from(effect in Effect, where: effect.id == ^effect_id))

               Repo.rollback(:safe_legacy_delete_probe)
             end)

    assert Repo.get!(Effect, effect_id).runtime_owner_generation == nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SET LOCAL ROLE maraithon_activation_operator", [])

          SQL.query!(
            Repo,
            "UPDATE public.effect_execution_protocols SET mode = 'legacy' WHERE name = 'effects'",
            []
          )
        end,
        mode: :savepoint
      )
    end

    assert ProtocolCutover.mode() == :exact

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "RESET ROLE", [])
          SQL.query!(Repo, "TRUNCATE public.effect_execution_protocols", [])
        end,
        mode: :savepoint
      )
    end

    assert ProtocolCutover.mode() == :exact

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "RESET ROLE", [])
          SQL.query!(Repo, "TRUNCATE public.effects", [])
        end,
        mode: :savepoint
      )
    end

    assert ProtocolCutover.mode() == :exact

    as_database_owner(fn ->
      SQL.query!(Repo, "DROP INDEX public.effects_exact_pending_claim_index", [])
    end)

    assert {:blocked, :durable_payload_verifier_privileges_not_ready} =
             ProtocolCutover.mode()

    assert {:error, {:effect_protocol_mismatch, :durable_payload_verifier_privileges_not_ready}} =
             ProtocolCutover.activation_preconditions()

    assert {:error, :durable_payload_verifier_privileges_not_ready} = activate_exact()

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        """
        CREATE INDEX effects_exact_pending_claim_index
          ON public.effects (retry_after NULLS FIRST, inserted_at, id)
          WHERE status = 'pending' AND runtime_owner_generation IS NOT NULL
        """,
        []
      )

      SQL.query!(
        Repo,
        "ALTER TABLE public.effects DISABLE TRIGGER enforce_effect_execution_protocol_trigger",
        []
      )
    end)

    assert {:blocked, :durable_payload_verifier_privileges_not_ready} =
             ProtocolCutover.mode()

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects ENABLE TRIGGER enforce_effect_execution_protocol_trigger",
        []
      )

      SQL.query!(
        Repo,
        "ALTER TABLE public.effects DROP CONSTRAINT effects_execution_status_check",
        []
      )

      SQL.query!(
        Repo,
        """
        ALTER TABLE public.effects
        ADD CONSTRAINT effects_execution_status_check
        CHECK (status IN ('pending', 'claimed', 'executing', 'cancelling', 'completed', 'failed', 'cancelled'))
        NOT VALID
        """,
        []
      )
    end)

    assert {:blocked, :durable_payload_verifier_privileges_not_ready} =
             ProtocolCutover.mode()

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects VALIDATE CONSTRAINT effects_execution_status_check",
        []
      )
    end)

    assert :ok = ProtocolCutover.activation_preconditions()

    assert {:ok, :already_active} =
             activate_exact()
  end

  test "exact admission requires the current ready Agent generation and old SQL cannot claim it" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-admission")

    assert {:error, :effect_runtime_owner_generation_required} =
             Effects.request(agent.id, :tool_call, "time", %{})

    assert {:error, _reason} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: Ecto.UUID.generate()
             )

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    effect = Repo.get!(Effect, effect_id)
    assert effect.status == "pending"
    assert effect.runtime_owner_generation == owner_generation
    assert is_nil(effect.claim_token)

    # SQL sandbox wraps the test in one transaction, so clear the transaction-
    # local marker installed by nested exact admission before proving that an
    # unmarked writer is rejected.
    SQL.query!(Repo, "SELECT set_config('maraithon.effect_writer_protocol', '', true)", [])

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()
          now = DatabaseClock.now!()

          %Effect{}
          |> Effect.protocol_changeset(%{
            id: Ecto.UUID.generate(),
            agent_id: agent.id,
            owner_user_id: agent.user_id,
            idempotency_key: Ecto.UUID.generate(),
            effect_type: "tool_call",
            params: %{"__maraithon_effect_protocol" => 2},
            status: "claimed",
            runtime_owner_generation: owner_generation,
            claim_token: Ecto.UUID.generate(),
            claim_owner_node: Atom.to_string(node()),
            claim_heartbeat_at: now,
            claim_expires_at: DateTime.add(now, 60, :second),
            claim_supervisor_id: Ecto.UUID.generate(),
            claim_task_id: Ecto.UUID.generate(),
            claimed_by: Atom.to_string(node()),
            claimed_at: now
          })
          |> Repo.insert!()
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            """
            UPDATE effects
            SET status = 'claimed', claimed_by = 'old@node',
                claimed_at = timezone('UTC', clock_timestamp())
            WHERE id = $1::uuid
            """,
            [Ecto.UUID.dump!(effect_id)]
          )
        end,
        mode: :savepoint
      )
    end

    assert Repo.get!(Effect, effect_id).status == "pending"

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            "UPDATE effects SET result_dispatch_attempts = 9 WHERE id = $1::uuid",
            [Ecto.UUID.dump!(effect_id)]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          SQL.query!(
            Repo,
            "UPDATE effects SET runtime_owner_generation = $2::uuid WHERE id = $1::uuid",
            [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "DELETE FROM effects WHERE id = $1::uuid", [
            Ecto.UUID.dump!(effect_id)
          ])
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          SQL.query!(Repo, "DELETE FROM effects WHERE id = $1::uuid", [
            Ecto.UUID.dump!(effect_id)
          ])
        end,
        mode: :savepoint
      )
    end

    assert Repo.get!(Effect, effect_id).status == "pending"
  end

  test "stale Agent generation cannot cancel successor-owned work" do
    assert {:ok, :activated} = activate_exact()
    watcher = effect_generation_watcher(max_crashes: 3, backoffs_ms: [0])
    {agent, old_generation} = exact_agent("effect-stale-cancel", watcher: watcher)

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: old_generation
             )

    assert {:recorded, guard} =
             prove_local_agent_down(watcher, agent.id, old_generation)

    assert {:ok, successor} =
             AgentLeases.claim_recovery(agent.id, guard.generation, ttl_ms: 60_000)

    assert {:ok, _ready} =
             AgentLeases.finish_recovery(agent.id, successor.owner_token, guard.generation)

    assert {:error, :effect_cancellation_owner_generation_lost} =
             EffectRunner.cancel_active_for_agent(agent.id, "stale_cleanup",
               expected_runtime_owner_generation: old_generation
             )

    assert Repo.get!(Effect, effect_id).status == "pending"

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "successor_cleanup",
               expected_runtime_owner_generation: successor.owner_token
             )

    cancelled = Repo.get!(Effect, effect_id)
    assert cancelled.status == "cancelled"
    assert cancelled.runtime_owner_generation == old_generation
    assert is_nil(cancelled.coordination_task_assignment_id)
    assert is_nil(cancelled.claim_token)
    assert is_nil(cancelled.claim_owner_node)
    assert is_nil(cancelled.claim_supervisor_id)
    assert is_nil(cancelled.claim_task_id)
  end

  test "protocol pair marks exact writes only after the canonical pair matches" do
    SQL.query!(Repo, "SELECT set_config('maraithon.effect_writer_protocol', '', true)", [])

    assert {:ok, :legacy} =
             Repo.transaction(fn ->
               assert CoordinationProtocol.locked_pair!() == :legacy

               assert %{rows: [[""]]} =
                        SQL.query!(
                          Repo,
                          "SELECT current_setting('maraithon.effect_writer_protocol', true)",
                          []
                        )

               :legacy
             end)

    assert {:ok, :activated} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
             )

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    SQL.query!(Repo, "SELECT set_config('maraithon.effect_writer_protocol', '', true)", [])

    assert {:error, {:runtime_effect_protocol_pair_mismatch, {:dark, :exact}}} =
             Repo.transaction(fn -> CoordinationProtocol.locked_pair!() end, mode: :savepoint)

    assert %{rows: [[""]]} =
             SQL.query!(
               Repo,
               "SELECT current_setting('maraithon.effect_writer_protocol', true)",
               []
             )

    Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)

    assert {:ok, :activated} =
             CoordinationProtocol.activate(
               [confirmation: CoordinationProtocol.activation_confirmation()] ++
                 @activation_evidence
             )

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    SQL.query!(Repo, "SELECT set_config('maraithon.effect_writer_protocol', '', true)", [])

    assert {:ok, :exact} =
             Repo.transaction(fn ->
               assert CoordinationProtocol.locked_pair!() == :exact

               assert %{rows: [["generation_fenced_v1"]]} =
                        SQL.query!(
                          Repo,
                          "SELECT current_setting('maraithon.effect_writer_protocol', true)",
                          []
                        )

               :exact
             end)
  end

  test "pre-command exact CAS installs a fresh writer marker before provider entry" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-fresh-entry-marker")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, _effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "fresh marker"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)

    # SQL Sandbox can retain SET LOCAL through nested savepoints. Explicitly
    # erase that artifact so provider entry proves the task's final CAS opened
    # its own transaction and installed a new exact-writer marker.
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.effect_writer_protocol', '', true)",
      []
    )

    assert %{rows: [[""]]} =
             SQL.query!(
               Repo,
               "SELECT current_setting('maraithon.effect_writer_protocol', true)",
               []
             )

    send(runner, :poll)
    _ = :sys.get_state(runner, 15_000)
    assert_receive {:exact_provider_entered, worker, _params}, 10_000
    send(worker, :release)
  end

  test "a Binding pause committed during exact launch prevents provider entry" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-binding-entry-fence")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{"model" => "blocking-v1", "messages" => []},
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    authority = Process.whereis(EffectTaskAuthority)
    :ok = :sys.suspend(authority)

    on_exit(fn ->
      if Process.alive?(authority) do
        try do
          :sys.resume(authority)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    send(runner, :poll)

    binding = Repo.get_by!(Binding, agent_id: agent.id, user_id: agent.user_id)
    binding |> Ecto.Changeset.change(status: "paused") |> Repo.update!()

    :ok = :sys.resume(authority)
    _ = :sys.get_state(runner, 15_000)
    refute_receive {:exact_provider_entered, _worker, _params}, 200
    refute Repo.get!(Effect, effect_id).status == "completed"
  end

  test "a lifecycle fence committed during exact launch prevents provider entry" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-lifecycle-entry-fence")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{"model" => "blocking-v1", "messages" => []},
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    authority = Process.whereis(EffectTaskAuthority)
    :ok = :sys.suspend(authority)

    on_exit(fn ->
      if Process.alive?(authority) do
        try do
          :sys.resume(authority)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    send(runner, :poll)

    assert {:ok, _fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :stop,
               %{"reason" => "concurrent_entry_fence"},
               fn _locked -> %{"action" => "stop"} end
             )

    :ok = :sys.resume(authority)
    _ = :sys.get_state(runner, 15_000)
    refute_receive {:exact_provider_entered, _worker, _params}, 200
    refute Repo.get!(Effect, effect_id).status == "completed"
  end

  test "DB-first cancellation kills the exact physical task before settling ambiguity" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-cancel")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "block"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    _ = :sys.get_state(runner, 15_000)
    assert_receive {:exact_provider_entered, worker, _params}, 10_000
    worker_ref = Process.monitor(worker)

    claimed = Repo.get!(Effect, effect_id)
    assert claimed.status == "executing"
    assert claimed.claim_token != owner_generation
    assert claimed.claim_owner_node == Atom.to_string(node())
    assert claimed.claim_supervisor_id != nil
    assert claimed.claim_task_id != nil

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)
    :ok = :sys.suspend(runner)

    on_exit(fn ->
      if Process.alive?(runner) do
        try do
          :sys.resume(runner)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    # Claim renewal is an independent supervised heartbeat, not EffectRunner
    # poll progress or a synchronous cancellation RPC side effect.
    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()
    :ok = :sys.resume(runner)
    renewed = Repo.get!(Effect, effect_id)
    assert DateTime.compare(renewed.claim_expires_at, claimed.claim_expires_at) == :gt

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          SQL.query!(
            Repo,
            "UPDATE effects SET claim_task_id = $2::uuid WHERE id = $1::uuid",
            [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
          )
        end,
        mode: :savepoint
      )
    end

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "agent_stopped",
               expected_runtime_owner_generation: owner_generation
             )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    settled = Repo.get!(Effect, effect_id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
    assert settled.cancellation_target_claim_token == claimed.claim_token
    assert settled.claim_token == claimed.claim_token
    assert settled.result_envelope == TerminalEnvelope.error(:effect_outcome_ambiguous)
    assert settled.cancellation_settled_at != nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
            set: [status: "completed"]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
            set: [error: "rewritten_terminal_outcome"]
          )
        end,
        mode: :savepoint
      )
    end

    replay = %CancellationPlan{
      agent_id: agent.id,
      user_id: agent.user_id,
      reason: "agent_stopped",
      claims: [
        %{
          effect_id: claimed.id,
          agent_id: agent.id,
          claim_token: claimed.claim_token,
          runtime_owner_generation: claimed.runtime_owner_generation,
          owner_node: claimed.claim_owner_node,
          assignment_id: claimed.coordination_task_assignment_id,
          supervisor_id: claimed.claim_supervisor_id,
          task_id: claimed.claim_task_id
        }
      ],
      pending_cancelled: 0,
      requested: 1,
      more?: false
    }

    assert {:ok, %{duplicate_settlements: 1, unresolved: []}} =
             Effects.finish_cancel_active_for_agent_post_commit(replay)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()
          Repo.delete_all(from(effect in Effect, where: effect.id == ^effect_id))
        end,
        mode: :savepoint
      )
    end

    # Exact terminal delivery bookkeeping is a reviewed monotonic exception to
    # immutable terminal provenance: reserve advances attempts/timestamps and
    # acknowledgement may be set once without changing the outcome.
    assert {:ok, true} = Effects.reserve_terminal_result_dispatch(settled)
    reserved = Repo.get!(Effect, effect_id)
    assert reserved.result_dispatch_attempts == 1
    assert reserved.result_dispatched_at != nil
    assert reserved.result_dispatch_after != nil
    assert {:ok, false} = Effects.reserve_terminal_result_dispatch(reserved)

    assert {:ok, 1} = Effects.acknowledge_terminal_result(effect_id, agent.id)
    acknowledged = Repo.get!(Effect, effect_id)
    assert acknowledged.result_acknowledged_at != nil
    assert acknowledged.result_envelope == settled.result_envelope

    assert {:ok, 1} =
             Effects.purge_terminal_payloads(
               DateTime.add(acknowledged.result_acknowledged_at, 1, :second)
             )

    purged = Repo.get!(Effect, effect_id)
    assert purged.payload_purged_at != nil
    assert purged.params == nil
    assert purged.result == nil
    assert purged.result_envelope == settled.result_envelope
    assert purged.result_acknowledged_at == acknowledged.result_acknowledged_at

    assert {:cached_payload_expired, %{status: "failed", result_envelope: result_envelope}} =
             Effects.check_idempotency(purged.idempotency_key)

    assert result_envelope == settled.result_envelope

    assert {:error, :safe_delete_probe} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               assert {1, nil} =
                        Repo.delete_all(from(effect in Effect, where: effect.id == ^effect_id))

               Repo.rollback(:safe_delete_probe)
             end)
  end

  test "heartbeat preserves a live running task until its upstream lease cap advances" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-unchanged-cap")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "unchanged cap"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    _ = :sys.get_state(runner, 15_000)
    assert_receive {:exact_provider_entered, worker, _params}, 10_000
    worker_ref = Process.monitor(worker)

    effect = Repo.get!(Effect, effect_id)
    assignment = TaskClaims.get(effect.coordination_task_assignment_id)

    assert assignment.state == "running"
    assert effect.claim_expires_at == assignment.lease_expires_at

    {1, _rows} =
      Repo.update_all(
        from(lease in Maraithon.Runtime.AgentRuntimeLease,
          where: lease.agent_id == ^agent.id,
          where: lease.owner_token == ^owner_generation
        ),
        set: [lease_until: assignment.lease_expires_at]
      )

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)

    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    renewal_key = {
      effect.id,
      effect.agent_id,
      effect.claim_token,
      effect.coordination_task_assignment_id,
      effect.claim_supervisor_id,
      effect.claim_task_id
    }

    first_deadline =
      renewer
      |> :sys.get_state(30_000)
      |> Map.fetch!(:renewal_deadlines)
      |> Map.fetch!(renewal_key)

    assert Repo.get!(Effect, effect_id).claim_expires_at == effect.claim_expires_at
    assert TaskClaims.get(assignment.id).lease_expires_at == assignment.lease_expires_at
    assert Process.alive?(worker)
    assert Process.whereis(EffectClaimRenewer) == renewer
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0

    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    second_deadline =
      renewer
      |> :sys.get_state(30_000)
      |> Map.fetch!(:renewal_deadlines)
      |> Map.fetch!(renewal_key)

    assert second_deadline == first_deadline
    assert Process.alive?(worker)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0

    send(worker, :release)
  end

  test "coordinated claim honors its exact Agent lease cap before the first heartbeat" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-initial-agent-cap")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, capped_lease} =
             AgentLeases.renew(agent.id, owner_generation, ttl_ms: 30_000)

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "initial Agent cap"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    _ = :sys.get_state(runner, 15_000)
    assert_receive {:exact_provider_entered, worker, _params}, 10_000
    worker_ref = Process.monitor(worker)

    effect = Repo.get!(Effect, effect_id)
    assignment = TaskClaims.get(effect.coordination_task_assignment_id)

    assert assignment.state == "running"
    assert assignment.lease_expires_at == capped_lease.lease_until
    assert effect.claim_expires_at == capped_lease.lease_until

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)

    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()
    assert TaskClaims.get(assignment.id).lease_expires_at == capped_lease.lease_until
    assert Repo.get!(Effect, effect_id).claim_expires_at == capped_lease.lease_until
    assert Process.alive?(worker)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0

    send(worker, :release)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 10_000
    _ = :sys.get_state(runner, 15_000)

    assert TaskClaims.get(assignment.id).state == "settled"
    assert Repo.get!(Effect, effect_id).status == "completed"
    assert {:ok, []} = EffectTaskSupervisor.active_identities()
  end

  test "generic cancellation cannot forge a pre-provider outcome intent" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-preflight-intent-forgery")

    assert {:error, :invalid_effect_cancellation} =
             Cancellation.prepare(agent.id, "effect_preflight_failed:forged",
               expected_runtime_owner_generation: owner_generation
             )

    assert {:error, :invalid_effect_cancellation} =
             Cancellation.prepare(agent.id, "effect_preflight_retry:forged",
               expected_runtime_owner_generation: owner_generation
             )

    for internal_abort <- [
          "claim_liveness_expired",
          "effect_runner_shutdown",
          "effect_task_exited_without_outcome",
          "effect_task_start_ambiguous"
        ] do
      assert {:error, :invalid_effect_cancellation} =
               Cancellation.prepare(agent.id, internal_abort,
                 expected_runtime_owner_generation: owner_generation
               )
    end
  end

  test "heartbeat recognizes exact Guardian preactivation without extending either lease" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-preactivation")

    %{
      effect_id: effect_id,
      identity: identity,
      renewer: renewer,
      worker: worker,
      worker_ref: worker_ref
    } = start_gated_preactivation!(agent, owner_generation)

    before_effect = Repo.get!(Effect, effect_id)
    before_assignment = TaskClaims.get(identity.assignment_id)

    assert before_effect.status == "claimed"
    assert before_effect.claim_token == identity.claim_token
    assert before_effect.claim_supervisor_id == identity.supervisor_id
    assert before_effect.claim_task_id == identity.task_id
    assert before_effect.coordination_task_assignment_id == identity.assignment_id
    assert before_assignment.state == "reserved"
    assert before_assignment.provider_boundary == "not_entered"
    assert before_assignment.ready_at == nil

    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    renewal_key = {
      identity.effect_id,
      identity.agent_id,
      identity.claim_token,
      identity.assignment_id,
      identity.supervisor_id,
      identity.task_id
    }

    first_local_deadline =
      renewer
      |> :sys.get_state(30_000)
      |> Map.fetch!(:renewal_deadlines)
      |> Map.fetch!(renewal_key)

    after_effect = Repo.get!(Effect, effect_id)
    after_assignment = TaskClaims.get(identity.assignment_id)

    assert after_effect.claim_expires_at == before_effect.claim_expires_at
    assert after_effect.claim_heartbeat_at == before_effect.claim_heartbeat_at
    assert after_effect.updated_at == before_effect.updated_at
    assert after_assignment.lease_expires_at == before_assignment.lease_expires_at
    assert after_assignment.updated_at == before_assignment.updated_at
    assert after_assignment.state == "reserved"
    assert after_assignment.provider_boundary == "not_entered"
    assert after_assignment.ready_at == nil
    assert Process.alive?(worker)
    assert Process.whereis(EffectClaimRenewer) == renewer
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0

    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    second_local_deadline =
      renewer
      |> :sys.get_state(30_000)
      |> Map.fetch!(:renewal_deadlines)
      |> Map.fetch!(renewal_key)

    assert second_local_deadline == first_local_deadline
    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    third_local_deadline =
      renewer
      |> :sys.get_state(30_000)
      |> Map.fetch!(:renewal_deadlines)
      |> Map.fetch!(renewal_key)

    assert third_local_deadline == first_local_deadline

    repeated_effect = Repo.get!(Effect, effect_id)
    repeated_assignment = TaskClaims.get(identity.assignment_id)
    assert repeated_effect.claim_expires_at == before_effect.claim_expires_at
    assert repeated_effect.claim_heartbeat_at == before_effect.claim_heartbeat_at
    assert repeated_effect.updated_at == before_effect.updated_at
    assert repeated_assignment.lease_expires_at == before_assignment.lease_expires_at
    assert repeated_assignment.updated_at == before_assignment.updated_at
    assert Process.alive?(worker)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0

    assert {:ok, plan} =
             Cancellation.prepare(agent.id, "preactivation_regression_cleanup",
               expected_runtime_owner_generation: owner_generation
             )

    assert {:ok, %{requested: 1, claims_settled: 1, unresolved: []}} =
             Cancellation.execute(plan)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000
  end

  test "preactivation heartbeat fails closed when the Effect lease is expired" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-preactivation-effect-expired")

    %{
      effect_id: effect_id,
      identity: identity,
      worker: worker,
      worker_ref: worker_ref
    } = start_gated_preactivation!(agent, owner_generation)

    assignment_before = TaskClaims.get(identity.assignment_id)

    with_coordinated_effect_trigger_disabled(fn ->
      SQL.query!(
        Repo,
        """
        UPDATE public.effects
        SET claim_heartbeat_at = timezone('UTC', clock_timestamp()) - interval '2 seconds',
            claim_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second'
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(effect_id)]
      )
    end)

    assert {:error, :effect_claim_heartbeat_failed} = EffectClaimRenewer.renew_now()
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    assert TaskClaims.get(identity.assignment_id).lease_expires_at ==
             assignment_before.lease_expires_at

    await_task_termination_proof!(identity.assignment_id)
  end

  test "preactivation heartbeat fails closed when the Task lease is expired" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-preactivation-task-expired")

    %{
      effect_id: effect_id,
      identity: identity,
      worker: worker,
      worker_ref: worker_ref
    } = start_gated_preactivation!(agent, owner_generation)

    effect_before = Repo.get!(Effect, effect_id)

    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.runtime_task_action', $1, true)",
      [identity.assignment_id]
    )

    SQL.query!(
      Repo,
      """
      UPDATE public.runtime_task_assignments
      SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second'
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(identity.assignment_id)]
    )

    assert {:error, :effect_claim_heartbeat_failed} = EffectClaimRenewer.renew_now()
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    stored_effect = Repo.get!(Effect, effect_id)
    assert stored_effect.claim_expires_at == effect_before.claim_expires_at
    assert stored_effect.claim_heartbeat_at == effect_before.claim_heartbeat_at
    await_task_termination_proof!(identity.assignment_id)
  end

  test "preactivation TaskClaims rejects final-freshness authority drift" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-preactivation-final-freshness")

    %{
      effect_id: effect_id,
      identity: identity,
      renewer: renewer,
      worker: worker,
      worker_ref: worker_ref
    } = start_gated_preactivation!(agent, owner_generation)

    assignment = TaskClaims.get(identity.assignment_id)

    probe = %{
      agent_id: agent.id,
      owner_generation: owner_generation,
      effect_id: effect_id,
      assignment: assignment
    }

    drifts = [
      {"Effect state", &drift_preactivation_effect_state!/1},
      {"Task termination_requested state", &drift_preactivation_task_state!/1},
      {"Effect/assignment identity", &drift_preactivation_effect_assignment!/1},
      {"node ready state", &drift_preactivation_node!/1},
      {"partition ready state", &drift_preactivation_partition!/1},
      {"Agent lease ready state", &drift_preactivation_agent_lease!/1}
    ]

    with_suspended_renewer(renewer, fn ->
      for {label, drift} <- drifts do
        result =
          Repo.transaction(
            fn ->
              assert {:active, _activation_epoch} =
                       CoordinationProtocol.lock_effect_pair!()

              assert %{rows: [["generation_fenced_v1"]]} =
                       SQL.query!(
                         Repo,
                         "SELECT current_setting('maraithon.effect_writer_protocol', true)",
                         []
                       )

              drift.(probe)

              TaskClaims.renew_effect_in_transaction!(
                assignment,
                agent.id,
                owner_generation,
                60_000
              )
            end,
            mode: :savepoint
          )

        assert result == {:error, :coordination_task_authority_lost},
               "#{label} remained eligible for preactivation renewal"

        assert_pristine_preactivation_pair!(probe)
      end
    end)

    assert Process.alive?(worker)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0
  end

  test "preactivation final freshness rechecks expiry after the Effect lock" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-preactivation-lock-delay-expiry")

    %{
      effect_id: effect_id,
      identity: identity,
      renewer: renewer,
      worker: worker,
      worker_ref: worker_ref
    } = start_gated_preactivation!(agent, owner_generation)

    assignment = TaskClaims.get(identity.assignment_id)

    probe = %{
      agent_id: agent.id,
      owner_generation: owner_generation,
      effect_id: effect_id,
      assignment: assignment
    }

    with_suspended_renewer(renewer, fn ->
      assert {:error, :coordination_task_authority_lost} =
               Repo.transaction(
                 fn ->
                   assert {:active, _activation_epoch} =
                            CoordinationProtocol.lock_effect_pair!()

                   with_coordinated_effect_trigger_disabled(fn ->
                     assert %{num_rows: 1} =
                              SQL.query!(
                                Repo,
                                """
                                UPDATE public.effects
                                SET claim_expires_at =
                                      timezone('UTC', clock_timestamp()) + interval '2 seconds'
                                WHERE id = $1::uuid
                                """,
                                [Ecto.UUID.dump!(effect_id)]
                              )
                   end)

                   # Mirror the production ordering: the exact Effect is live
                   # when its row lock is acquired. PostgreSQL then advances its
                   # own clock while that lock is held, before TaskClaims performs
                   # the final all-authority freshness statement.
                   assert %{rows: [[_locked_effect_id]]} =
                            SQL.query!(
                              Repo,
                              """
                              SELECT id
                              FROM public.effects
                              WHERE id = $1::uuid
                                AND status = 'claimed'
                                AND claim_expires_at > timezone('UTC', clock_timestamp())
                              FOR UPDATE
                              """,
                              [Ecto.UUID.dump!(effect_id)]
                            )

                   SQL.query!(
                     Repo,
                     """
                     SELECT pg_sleep(
                       GREATEST(
                         EXTRACT(EPOCH FROM (
                           claim_expires_at - timezone('UTC', clock_timestamp())
                         ))::double precision,
                         0.0
                       ) + 0.100
                     )
                     FROM public.effects
                     WHERE id = $1::uuid
                     """,
                     [Ecto.UUID.dump!(effect_id)]
                   )

                   assert %{rows: [[true, true]]} =
                            SQL.query!(
                              Repo,
                              """
                              SELECT
                                effect.claim_expires_at <=
                                  timezone('UTC', clock_timestamp()),
                                task.lease_expires_at >
                                  timezone('UTC', clock_timestamp())
                              FROM public.effects AS effect
                              JOIN public.runtime_task_assignments AS task
                                ON task.id = effect.coordination_task_assignment_id
                              WHERE effect.id = $1::uuid
                              """,
                              [Ecto.UUID.dump!(effect_id)]
                            )

                   TaskClaims.renew_effect_in_transaction!(
                     assignment,
                     agent.id,
                     owner_generation,
                     60_000
                   )
                 end,
                 mode: :savepoint
               )
    end)

    assert_pristine_preactivation_pair!(probe)
    assert Process.alive?(worker)
    refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 0
  end

  test "heartbeat protocol uncertainty immediately terminates physical exact work" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-uncertainty")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, _effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "heartbeat"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    _ = :sys.get_state(runner, 15_000)
    assert_receive {:exact_provider_entered, worker, _params}, 10_000
    worker_ref = Process.monitor(worker)

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)
    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects DISABLE TRIGGER enforce_effect_execution_protocol_trigger",
        []
      )
    end)

    assert {:error, :effect_claim_heartbeat_failed} = EffectClaimRenewer.renew_now()
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects ENABLE TRIGGER enforce_effect_execution_protocol_trigger",
        []
      )
    end)
  end

  test "cancellation before task activation settles and retains the exact reservation proof" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-preactivation-cancel")
    now = DatabaseClock.now!()
    effect_id = Ecto.UUID.generate()
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()

    assert {:ok, identity} =
             Maraithon.Runtime.EffectTaskSupervisor.reserve_coordinated(
               effect_id,
               agent.id,
               claim_token,
               assignment_id
             )

    insert_claimed_exact_effect!(
      agent,
      owner_generation,
      claim_token,
      Atom.to_string(node()),
      identity.supervisor_id,
      identity.task_id,
      now,
      effect_id,
      :reserved,
      identity.termination_capability_digest,
      assignment_id
    )

    assert {:ok, plan} =
             Cancellation.prepare(agent.id, "cancel_before_activation",
               expected_runtime_owner_generation: owner_generation
             )

    cancelling = Repo.get!(Effect, effect_id)
    reserved = TaskClaims.get(assignment_id)

    assert cancelling.status == "cancelling"
    assert cancelling.cancellation_state == "requested"
    assert cancelling.cancellation_target_claim_token == claim_token
    assert cancelling.coordination_task_assignment_id == assignment_id
    assert reserved.state == "reserved"
    assert reserved.provider_boundary == "not_entered"
    assert reserved.ready_at == nil
    assert reserved.termination_requested_at == nil
    assert reserved.termination_proven_at == nil
    assert reserved.settled_at == nil
    assert reserved.outcome == nil

    assert %{rows: []} =
             SQL.query!(
               Repo,
               """
               SELECT proof_kind
               FROM public.runtime_task_termination_proofs
               WHERE assignment_id = $1::uuid
               """,
               [Ecto.UUID.dump!(assignment_id)]
             )

    assert {:ok, %{requested: 1, claims_settled: 1, unresolved: []}} =
             Cancellation.execute(plan)

    settled_assignment = TaskClaims.get(assignment_id)
    assert settled_assignment.state == "settled"
    assert settled_assignment.provider_boundary == "not_entered"
    assert settled_assignment.outcome == "cancelled_before_provider"

    assert %{rows: [["never_activated", evidence_id]]} =
             SQL.query!(
               Repo,
               """
               SELECT proof_kind, evidence_id
               FROM public.runtime_task_termination_proofs
               WHERE assignment_id = $1::uuid
               """,
               [Ecto.UUID.dump!(assignment_id)]
             )

    assert evidence_id == "task-supervisor:never_activated:#{identity.task_id}"

    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ExactEffectTaskSupervisor, fn ->
        Maraithon.Runtime.EffectTaskSupervisor.register_current!(identity)
        send(test_pid, :late_effect_task_authorized)
      end)

    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000
    refute_receive :late_effect_task_authorized, 50

    settled = Repo.get!(Effect, effect_id)
    assert settled.status == "cancelled"
    assert settled.cancellation_state == "settled"
    assert settled.coordination_task_assignment_id == assignment_id
    assert settled.claim_token == claim_token
    assert settled.claim_owner_node == Atom.to_string(node())
    assert %DateTime{} = settled.claim_heartbeat_at
    assert %DateTime{} = settled.claim_expires_at
    assert settled.claim_supervisor_id == identity.supervisor_id
    assert settled.claim_task_id == identity.task_id
    assert settled.cancellation_target_claim_token == claim_token
    assert %DateTime{} = settled.cancellation_last_attempt_at
    assert is_nil(settled.claimed_by)
    assert is_nil(settled.claimed_at)
  end

  test "a still-running task generation cannot be overwritten by a retry successor" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-running-retry-fence")
    configure_blocking_provider()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "retry fence"}]
               },
               runtime_owner_generation: owner_generation
             )

    pending = Repo.get!(Effect, effect_id)
    stop_existing_runner()
    BootGate.close()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)

    :sys.replace_state(runner, fn state ->
      %{state | running: Map.put(state.running, effect_id, pending)}
    end)

    BootGate.open()
    send(runner, :poll)
    _ = :sys.get_state(runner, 15_000)

    refute_receive {:exact_provider_entered, _worker, _params}, 100

    unclaimed = Repo.get!(Effect, effect_id)
    assert unclaimed.status == "pending"
    assert unclaimed.claim_token == nil

    :sys.replace_state(runner, fn state ->
      %{state | running: Map.delete(state.running, effect_id)}
    end)
  end

  test "an exact executing Effect can return to pending after a proven retry settlement" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-proven-retry")
    now = DatabaseClock.now!()

    effect =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        Atom.to_string(node()),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        now
      )

    assignment = TaskClaims.get(effect.coordination_task_assignment_id)

    assert {:ok, {1, _rows}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               entered =
                 TaskClaims.enter_effect_provider_in_transaction!(
                   assignment,
                   agent.id,
                   owner_generation
                 )

               assert entered.provider_boundary == "entered"

               Repo.update_all(
                 from(stored in Effect,
                   where: stored.id == ^effect.id and stored.status == "claimed"
                 ),
                 set: [status: "executing", updated_at: DatabaseClock.now!()]
               )
             end)

    assert {:ok, {1, _rows}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               settled =
                 TaskClaims.settle_effect_in_transaction(
                   assignment,
                   agent.id,
                   owner_generation,
                   "retry_scheduled"
                 )

               assert settled.state == "settled"
               assert settled.provider_boundary == "outcome_known"
               assert settled.outcome == "retry_scheduled"

               Repo.update_all(
                 from(stored in Effect,
                   where: stored.id == ^effect.id and stored.status == "executing"
                 ),
                 set: [
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
                   attempts: 1,
                   retry_after: DateTime.add(DatabaseClock.now!(), 1, :second),
                   updated_at: DatabaseClock.now!()
                 ]
               )
             end)

    retried = Repo.get!(Effect, effect.id)
    assert retried.status == "pending"
    assert retried.claim_token == nil
    assert retried.coordination_task_assignment_id == nil
    assert retried.attempts == 1
  end

  test "coupled Task.Supervisor restart kills predecessor tasks before absence settlement" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-registry-restart")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "block"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    _ = :sys.get_state(runner, 30_000)
    assert_receive {:exact_provider_entered, worker, _params}, 10_000
    worker_ref = Process.monitor(worker)
    :ok = :sys.suspend(runner, 30_000)

    on_exit(fn ->
      if Process.alive?(runner) do
        try do
          :sys.resume(runner)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, old_identity} = Maraithon.Runtime.EffectTaskSupervisor.identity()
    old_task_supervisor = Process.whereis(Maraithon.Runtime.ExactEffectTaskSupervisor)
    task_supervisor_ref = Process.monitor(old_task_supervisor)
    Process.exit(old_task_supervisor, :kill)

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^old_task_supervisor, _reason}, 2_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    # A synchronous system-state call runs only after the nested one-for-all
    # group has killed predecessor tasks and installed a fresh authority.
    _ = :sys.get_state(Maraithon.Runtime.EffectTaskSupervisor)
    # Guardian owns the predecessor monitor and its bounded persistence retry.
    # Drain that authenticated-DOWN callback before issuing reconciliation SQL
    # through the shared sandbox owner.
    _ = :sys.get_state(Maraithon.Runtime.TaskGuardian, 30_000)
    new_task_supervisor = Process.whereis(Maraithon.Runtime.ExactEffectTaskSupervisor)
    refute new_task_supervisor == old_task_supervisor
    assert {:ok, new_identity} = Maraithon.Runtime.EffectTaskSupervisor.identity()
    refute new_identity == old_identity

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "registry_restarted",
               expected_runtime_owner_generation: owner_generation
             )

    settled = Repo.get!(Effect, effect_id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
    assert settled.cancellation_target_claim_token == settled.claim_token

    :ok = :sys.resume(runner)
  end

  test "expired claims are fenced in bounded pages without takeover" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-expired-page")
    expired_heartbeat = DatabaseClock.now!() |> DateTime.add(-120, :second)

    first =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        "expired-owner@invalid",
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        expired_heartbeat
      )

    second =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        "expired-owner@invalid",
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        expired_heartbeat
      )

    assert [%CancellationPlan{claims: [%{effect_id: first_page_id}]} = first_plan] =
             Cancellation.fence_expired_claims(1)

    assert first_page_id in [first.id, second.id]
    assert {:pending, %{unresolved: [_unreachable]}} = Cancellation.execute(first_plan)

    assert [%CancellationPlan{claims: [%{effect_id: second_page_id}]} = second_plan] =
             Cancellation.fence_expired_claims(1)

    assert second_page_id in [first.id, second.id]
    refute second_page_id == first_page_id
    assert {:pending, %{unresolved: [_unreachable]}} = Cancellation.execute(second_plan)

    assert Enum.all?([first.id, second.id], fn effect_id ->
             effect = Repo.get!(Effect, effect_id)

             effect.status == "cancelling" and effect.cancellation_state == "requested" and
               is_nil(effect.cancellation_settled_at)
           end)
  end

  test "a tripped restart guard settles pending work from every orphan generation" do
    assert {:ok, :activated} = activate_exact()
    first_watcher = effect_generation_watcher(max_crashes: 3, backoffs_ms: [0])

    {agent, first_generation} =
      exact_agent("effect-crash-loop-pending", watcher: first_watcher)

    assert {:ok, first_effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: first_generation
             )

    assert {:recorded, first_guard} =
             prove_local_agent_down(first_watcher, agent.id, first_generation)

    refute first_guard.tripped

    second_watcher = effect_generation_watcher(max_crashes: 2, backoffs_ms: [0])

    assert {:ok, second_lease} =
             AgentLeases.claim_recovery(agent.id, first_guard.generation,
               ttl_ms: 60_000,
               watcher: second_watcher
             )

    assert {:ok, _ready_lease} =
             AgentLeases.finish_recovery(
               agent.id,
               second_lease.owner_token,
               first_guard.generation
             )

    assert {:ok, second_effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: second_lease.owner_token
             )

    assert {:recorded, tripped_guard} =
             prove_local_agent_down(second_watcher, agent.id, second_lease.owner_token)

    assert tripped_guard.tripped

    for {effect_id, generation} <- [
          {first_effect_id, first_generation},
          {second_effect_id, second_lease.owner_token}
        ] do
      cancelled = Repo.get!(Effect, effect_id)
      assert cancelled.status == "cancelled"
      assert cancelled.cancellation_state == "settled"
      assert cancelled.error == "agent_crash_loop_tripped"
      assert cancelled.runtime_owner_generation == generation
    end
  end

  test "only proven tripped work converges after exact storage readiness is repaired" do
    assert {:ok, :activated} = activate_exact()
    watcher = effect_generation_watcher(max_crashes: 1, backoffs_ms: [0])

    {agent, owner_generation} =
      exact_agent("effect-crash-loop-deferred", watcher: watcher)

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects DISABLE TRIGGER enforce_effect_execution_protocol_trigger",
        []
      )
    end)

    assert {:blocked, :durable_payload_verifier_privileges_not_ready} = ProtocolCutover.mode()

    assert {:ignored, :termination_proof_required} =
             AgentRestartGuards.record_crash(
               agent.id,
               owner_generation,
               :simulated_storage_drift_crash,
               max_crashes: 1,
               backoffs_ms: [0]
             )

    assert Repo.get!(Effect, effect_id).status == "pending"

    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects ENABLE TRIGGER enforce_effect_execution_protocol_trigger",
        []
      )
    end)

    assert {:recorded, guard} =
             prove_local_agent_down(watcher, agent.id, owner_generation)

    assert guard.tripped
    assert Repo.get!(Effect, effect_id).status == "cancelled"
    assert {:ok, 0} = AgentRestartGuards.reconcile_tripped_pending(10)
  end

  test "unreachable physical ownership remains durably cancelling" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-unreachable")
    now = DatabaseClock.now!()
    claim_token = Ecto.UUID.generate()

    effect =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        claim_token,
        "unreachable@invalid",
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        now
      )

    assignment = TaskClaims.get(effect.coordination_task_assignment_id)

    assert {:ok, %{provider_boundary: "entered"}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               TaskClaims.enter_effect_provider_in_transaction!(
                 assignment,
                 agent.id,
                 owner_generation
               )
             end)

    assert {:error, :effect_task_termination_incomplete} =
             EffectRunner.cancel_active_for_agent(agent.id, "agent_stopped",
               expected_runtime_owner_generation: owner_generation
             )

    cancelling = Repo.get!(Effect, effect.id)
    assert cancelling.status == "cancelling"
    assert cancelling.cancellation_state == "requested"
    assert cancelling.cancellation_target_claim_token == claim_token
    assert cancelling.claim_token == claim_token
    assert cancelling.result_envelope == nil
    assert cancelling.cancellation_settled_at == nil
    assert cancelling.cancellation_last_attempt_at != nil
    assert cancelling.cancellation_last_error != nil

    identity = %{
      effect_id: cancelling.id,
      claim_token: cancelling.claim_token,
      owner_node: cancelling.claim_owner_node,
      supervisor_id: cancelling.claim_supervisor_id,
      task_id: cancelling.claim_task_id
    }

    assert {:error, :effect_termination_confirmation_required} =
             TerminationAttestations.record(
               identity,
               "infra-ticket-1234",
               "operator@example.com",
               "WRONG_CONFIRMATION"
             )

    assert {:ok, %{attestation: attestation, task_assignment: proven_assignment}} =
             as_incident_operator(fn ->
               TerminationAttestations.record(
                 identity,
                 "infra-ticket-1234",
                 "operator@example.com",
                 TerminationAttestations.confirmation()
               )
             end)

    assert attestation.effect_id == cancelling.id
    assert TerminationAttestations.proof?(identity)

    # The incident transaction records the attestation and exact Task proof
    # atomically before ordinary runtime reconciliation receives settlement DML.
    assert proven_assignment.id == cancelling.coordination_task_assignment_id
    assert proven_assignment.state == "termination_proven"

    assert {:ok, %{claims_settled: 1, unresolved: []}} =
             Cancellation.reconcile_agent(agent.id, 10)

    settled = Repo.get!(Effect, effect.id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
    assert settled.result_envelope == TerminalEnvelope.error(:effect_outcome_ambiguous)

    assert {:ok, %{attestation: retried_attestation, task_assignment: retried_assignment}} =
             as_incident_operator(fn ->
               TerminationAttestations.record(
                 identity,
                 "infra-ticket-1234",
                 "operator@example.com",
                 TerminationAttestations.confirmation()
               )
             end)

    assert retried_attestation.id == attestation.id
    assert retried_assignment.id == proven_assignment.id
    assert retried_assignment.state in ["termination_proven", "settled", "outcome_ambiguous"]

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "RESET ROLE", [])

          SQL.query!(
            Repo,
            "DELETE FROM public.effect_termination_attestations WHERE id = $1::uuid",
            [Ecto.UUID.dump!(attestation.id)]
          )
        end,
        mode: :savepoint
      )
    end

    acknowledged_at = DatabaseClock.now!()

    assert {:ok, :deleted} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               {1, _rows} =
                 Repo.update_all(
                   from(stored in Effect, where: stored.id == ^effect.id),
                   set: [result_acknowledged_at: acknowledged_at, updated_at: acknowledged_at]
                 )

               {1, _rows} =
                 Repo.delete_all(from(stored in Effect, where: stored.id == ^effect.id))

               :deleted
             end)

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM public.effect_termination_attestations WHERE id = $1::uuid",
               [Ecto.UUID.dump!(attestation.id)]
             )
  end

  test "lifecycle recovery cancels pending exact work and closes the work graph atomically" do
    assert {:ok, :activated} = activate_exact()
    watcher = effect_generation_watcher(backoffs_ms: [0])

    {agent, owner_generation} =
      exact_agent("effect-lifecycle-convergence", watcher: watcher)

    assert {:ok, _directive} =
             AgentDirectives.enqueue(
               agent.id,
               agent.user_id,
               "message",
               %{"body" => "crash-boundary"},
               "lifecycle-convergence"
             )

    assert {:ok, directive} =
             AgentDirectives.claim_next(agent.id, agent.user_id, owner_generation)

    assert {:ok, run} =
             Agents.start_exact_runtime_agent_run(agent, owner_generation, %{
               trigger_type: "message",
               trigger: %{"directive_id" => directive.id}
             })

    assert {:ok, step} =
             Agents.record_agent_run_step(run.id, agent.id, %{
               sequence: 1,
               step_type: "effect",
               effect_type: "tool_call",
               status: "requested",
               request_payload: %{"tool" => "time"}
             })

    effect_id = Ecto.UUID.generate()

    assert {:ok, %Effect{id: ^effect_id}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()
               now = DatabaseClock.now!()

               stored_directive =
                 Repo.one!(
                   from(stored in AgentDirective,
                     where: stored.id == ^directive.id,
                     lock: "FOR UPDATE"
                   )
                 )

               assert {:ok, stored_directive} =
                        AgentDirectives.bind_run_locked(stored_directive, run.id, now)

               assert {:ok, _stored_directive, 1} =
                        AgentDirectives.admit_effect_locked(stored_directive, run.id, now)

               attrs =
                 %{
                   id: effect_id,
                   agent_id: agent.id,
                   owner_user_id: agent.user_id,
                   idempotency_key: Ecto.UUID.generate(),
                   effect_type: "tool_call",
                   params: %{
                     "__maraithon_effect_protocol" => 2,
                     "tool" => "time",
                     "args" => %{}
                   },
                   status: "pending",
                   runtime_owner_generation: owner_generation,
                   agent_run_id: run.id,
                   agent_run_step_id: step.id,
                   attempts: 0,
                   max_attempts: 3
                 }
                 |> Map.merge(exact_effect_scope!(agent.id, owner_generation))

               %Effect{}
               |> Effect.protocol_changeset(attrs)
               |> Repo.insert!()
             end)

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :update,
               %{"revision" => "after-crash"},
               fn locked ->
                 %{
                   "action" => "update",
                   "attrs" => %{
                     "behavior" => locked.behavior,
                     "config" => Map.put(locked.config || %{}, "revision", "after-crash")
                   }
                 }
               end
             )

    assert {:ok, %{status: :reconciliation_pending, reason: :runtime_lease_owned}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert {:reconciled_without_loss, _incident} =
             prove_local_agent_down(watcher, agent.id, owner_generation)

    assert Repo.get!(Effect, effect_id).status == "cancelled"

    assert {:ok, %{status: :finalized, agent: resumed}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert resumed.status == "running"
    assert resumed.active_run_id == nil
    assert resumed.config["revision"] == "after-crash"
    assert Repo.get!(AgentDirective, directive.id).status == "cancelled"
    assert Repo.get!(AgentRun, run.id).status == "cancelled"
    assert Repo.get!(AgentRunStep, step.id).status == "failed"
    assert AgentLifecycleOperations.get(agent.id) == nil
  end

  test "lifecycle delete erases an unacknowledged terminal exact result without false ack" do
    assert {:ok, :activated} = activate_exact()
    watcher = effect_generation_watcher(backoffs_ms: [0])

    {agent, owner_generation} =
      exact_agent("effect-lifecycle-erasure", watcher: watcher)

    now = DatabaseClock.now!()

    claimed =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        Atom.to_string(node()),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        now
      )

    assert {:ok, {1, nil}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()
               assignment = TaskClaims.get(claimed.coordination_task_assignment_id)

               entered =
                 TaskClaims.enter_effect_provider_in_transaction!(
                   assignment,
                   agent.id,
                   owner_generation
                 )

               settled =
                 TaskClaims.settle_effect_in_transaction(
                   entered,
                   agent.id,
                   owner_generation,
                   "completed"
                 )

               assert settled.state == "settled"
               assert settled.provider_boundary == "outcome_known"

               Repo.update_all(
                 from(effect in Effect,
                   where: effect.id == ^claimed.id and effect.status == "claimed"
                 ),
                 set: [
                   status: "completed",
                   result: %{"ok" => true},
                   error: nil,
                   result_envelope: TerminalEnvelope.success(),
                   completion_claimed_by: claimed.claim_owner_node,
                   completion_claimed_at: now,
                   claimed_by: nil,
                   claimed_at: nil,
                   updated_at: now
                 ]
               )
             end)

    terminal = Repo.get!(Effect, claimed.id)
    assert terminal.result_acknowledged_at == nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()
          Repo.delete_all(from(effect in Effect, where: effect.id == ^claimed.id))
        end,
        mode: :savepoint
      )
    end

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :delete,
               %{"reason" => "operator_requested"},
               fn _locked -> %{"action" => "delete"} end
             )

    assert {:reconciled_without_loss, _incident} =
             prove_local_agent_down(watcher, agent.id, owner_generation)

    # Recording the fenced local-termination proof drives lifecycle
    # reconciliation to completion; a later finalize call is idempotently gone.
    assert {:error, :not_found} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert Repo.get(Effect, claimed.id) == nil
    assert Agents.get_agent(agent.id) == nil
  end

  defp with_suspended_renewer(renewer, fun)
       when is_pid(renewer) and is_function(fun, 0) do
    assert Process.whereis(EffectClaimRenewer) == renewer
    assert :ok = :sys.suspend(renewer, 30_000)

    try do
      fun.()
    after
      assert :ok = :sys.resume(renewer, 30_000)
    end
  end

  defp drift_preactivation_effect_state!(%{effect_id: effect_id}) do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
      []
    )

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               """
               UPDATE public.effects
               SET status = 'cancelling',
                   cancellation_state = 'requested',
                   cancellation_reason = 'preactivation_freshness_probe',
                   cancellation_requested_at = timezone('UTC', clock_timestamp()),
                   cancellation_target_claim_token = claim_token,
                   error = 'preactivation_freshness_probe',
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE id = $1::uuid AND status = 'claimed'
               """,
               [Ecto.UUID.dump!(effect_id)]
             )
  end

  defp drift_preactivation_task_state!(%{assignment: assignment}) do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.runtime_task_action', $1, true)",
      [assignment.id]
    )

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               """
               UPDATE public.runtime_task_assignments
               SET state = 'termination_requested',
                   termination_requested_at = timezone('UTC', clock_timestamp()),
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE id = $1::uuid AND state = 'reserved'
                 AND provider_boundary = 'not_entered' AND ready_at IS NULL
               """,
               [Ecto.UUID.dump!(assignment.id)]
             )
  end

  defp drift_preactivation_effect_assignment!(%{effect_id: effect_id}) do
    with_effect_assignment_pair_trigger_bypass(fn ->
      assert %{num_rows: 1} =
               SQL.query!(
                 Repo,
                 """
                 UPDATE public.effects
                 SET coordination_task_assignment_id = $2::uuid,
                     updated_at = timezone('UTC', clock_timestamp())
                 WHERE id = $1::uuid AND status = 'claimed'
                 """,
                 [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
               )
    end)
  end

  defp drift_preactivation_node!(%{assignment: assignment}) do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.runtime_node_action', $1, true)",
      [assignment.node_incarnation_id]
    )

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               """
               UPDATE public.runtime_node_incarnations
               SET state = 'draining', ready_at = NULL,
                   draining_at = COALESCE(
                     draining_at,
                     timezone('UTC', clock_timestamp())
                   ),
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE id = $1::uuid AND activation_epoch = $2::uuid
                 AND state = 'ready'
               """,
               [
                 Ecto.UUID.dump!(assignment.node_incarnation_id),
                 Ecto.UUID.dump!(assignment.activation_epoch)
               ]
             )
  end

  defp drift_preactivation_partition!(%{assignment: assignment}) do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.runtime_node_action', $1, true)",
      [assignment.node_incarnation_id]
    )

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               """
               UPDATE public.runtime_partitions
               SET state = 'draining', ready_at = NULL,
                   draining_at = COALESCE(
                     draining_at,
                     timezone('UTC', clock_timestamp())
                   ),
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE partition_id = $1 AND activation_epoch = $2::uuid
                 AND ownership_epoch = $3
                 AND owner_node_incarnation_id = $4::uuid
                 AND state = 'ready'
               """,
               [
                 assignment.partition_id,
                 Ecto.UUID.dump!(assignment.activation_epoch),
                 assignment.partition_epoch,
                 Ecto.UUID.dump!(assignment.node_incarnation_id)
               ]
             )
  end

  defp drift_preactivation_agent_lease!(%{
         agent_id: agent_id,
         owner_generation: owner_generation,
         assignment: assignment
       }) do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.agent_lease_owner_token', $1, true)",
      [owner_generation]
    )

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               """
               UPDATE public.agent_runtime_leases
               SET ready_at = NULL,
                   draining_at = COALESCE(
                     draining_at,
                     timezone('UTC', clock_timestamp())
                   ),
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE agent_id = $1::uuid AND owner_token = $2::uuid
                 AND coordination_activation_epoch = $3::uuid
                 AND coordination_partition_id = $4
                 AND coordination_partition_epoch = $5
                 AND coordination_node_incarnation_id = $6::uuid
                 AND ready_at IS NOT NULL AND draining_at IS NULL
               """,
               [
                 Ecto.UUID.dump!(agent_id),
                 Ecto.UUID.dump!(owner_generation),
                 Ecto.UUID.dump!(assignment.activation_epoch),
                 assignment.partition_id,
                 assignment.partition_epoch,
                 Ecto.UUID.dump!(assignment.node_incarnation_id)
               ]
             )
  end

  defp assert_pristine_preactivation_pair!(%{
         effect_id: effect_id,
         agent_id: agent_id,
         owner_generation: owner_generation,
         assignment: expected_assignment
       }) do
    effect = Repo.get!(Effect, effect_id)
    assignment = TaskClaims.get(expected_assignment.id)

    assert effect.status == "claimed"
    assert effect.cancellation_state == nil
    assert effect.coordination_task_assignment_id == assignment.id
    assert effect.claim_token == assignment.claim_token
    assert effect.claim_supervisor_id == assignment.supervisor_id
    assert effect.claim_task_id == assignment.local_task_id
    assert assignment.state == "reserved"
    assert assignment.provider_boundary == "not_entered"
    assert assignment.ready_at == nil
    assert assignment.termination_requested_at == nil

    assert %{rows: [["ready", true, "ready", true, true, true]]} =
             SQL.query!(
               Repo,
               """
               SELECT node.state, node.ready_at IS NOT NULL,
                      partition.state, partition.ready_at IS NOT NULL,
                      lease.ready_at IS NOT NULL, lease.draining_at IS NULL
               FROM public.runtime_task_assignments AS task
               JOIN public.runtime_node_incarnations AS node
                 ON node.id = task.node_incarnation_id
                AND node.activation_epoch = task.activation_epoch
               JOIN public.runtime_partitions AS partition
                 ON partition.partition_id = task.partition_id
                AND partition.activation_epoch = task.activation_epoch
                AND partition.ownership_epoch = task.partition_epoch
                AND partition.owner_node_incarnation_id = task.node_incarnation_id
               JOIN public.agent_runtime_leases AS lease
                 ON lease.agent_id = $2::uuid AND lease.owner_token = $3::uuid
                AND lease.coordination_activation_epoch = task.activation_epoch
                AND lease.coordination_partition_id = task.partition_id
                AND lease.coordination_partition_epoch = task.partition_epoch
                AND lease.coordination_node_incarnation_id = task.node_incarnation_id
               WHERE task.id = $1::uuid
               """,
               [
                 Ecto.UUID.dump!(assignment.id),
                 Ecto.UUID.dump!(agent_id),
                 Ecto.UUID.dump!(owner_generation)
               ]
             )
  end

  defp with_effect_assignment_pair_trigger_bypass(fun) when is_function(fun, 0) do
    with_coordinated_effect_trigger_disabled(fn ->
      SQL.query!(
        Repo,
        """
        ALTER TABLE public.effects
        DISABLE TRIGGER enforce_effect_assignment_final_pair_effect_trigger
        """,
        []
      )

      try do
        fun.()
      after
        SQL.query!(
          Repo,
          """
          ALTER TABLE public.effects
          ENABLE TRIGGER enforce_effect_assignment_final_pair_effect_trigger
          """,
          []
        )
      end
    end)
  end

  defp as_incident_operator(fun) when is_function(fun, 0) do
    SQL.query!(Repo, "SET LOCAL ROLE maraithon_incident_operator", [])

    try do
      fun.()
    after
      SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
    end
  end

  defp as_database_owner(fun) when is_function(fun, 0) do
    # Flush deferred Effect/assignment pair checks before catalog DDL. PostgreSQL
    # rejects ALTER TABLE while the relation still has pending trigger events.
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
    SQL.query!(Repo, "RESET ROLE", [])

    try do
      fun.()
    after
      SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
      SQL.query!(Repo, "SET CONSTRAINTS ALL DEFERRED", [])
    end
  end

  defp with_coordinated_effect_trigger_disabled(fun) when is_function(fun, 0) do
    as_database_owner(fn ->
      SQL.query!(
        Repo,
        "ALTER TABLE public.effects DISABLE TRIGGER enforce_coordinated_effect_trigger",
        []
      )

      try do
        SQL.query!(
          Repo,
          "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
          []
        )

        fun.()
      after
        SQL.query!(
          Repo,
          "ALTER TABLE public.effects ENABLE TRIGGER enforce_coordinated_effect_trigger",
          []
        )
      end
    end)
  end

  defp authoritative_payload_contraction(fun) when is_function(fun, 0) do
    result =
      DurablePayloadContraction.transaction(
        [
          confirmation: ProtocolCutover.activation_confirmation(),
          evidence_id: Keyword.fetch!(@activation_evidence, :evidence_id),
          evidence_digest: Keyword.fetch!(@activation_evidence, :evidence_digest),
          operator: Keyword.fetch!(@activation_evidence, :activated_by),
          revision: Keyword.fetch!(@activation_evidence, :revision)
        ],
        fun
      )

    SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
    result
  end

  defp settle_legacy_effect!(effect_id) do
    now = DatabaseClock.now!()

    assert {1, _rows} =
             Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
               set: [
                 status: "completed",
                 result: %{"ok" => true},
                 result_envelope: TerminalEnvelope.success(),
                 result_acknowledged_at: now,
                 updated_at: now
               ]
             )
  end

  defp settle_legacy_directive!(directive) do
    now = DatabaseClock.now!()

    directive
    |> AgentDirective.changeset(%{
      status: "cancelled",
      terminal_at: now,
      terminal_acknowledged_at: now,
      last_error_code: "cancelled",
      updated_at: now
    })
    |> Repo.update!()
  end

  defp effect_generation_watcher(opts) do
    suffix = System.unique_integer([:positive])
    watcher_name = :"effect_generation_watcher_#{suffix}"

    start_supervised!(
      {AgentWatcher,
       name: watcher_name,
       reconcile?: false,
       recover?: false,
       crash_loop_max: Keyword.get(opts, :max_crashes, 3),
       crash_loop_window_ms: Keyword.get(opts, :window_ms, 600_000),
       reresume_backoffs: Keyword.get(opts, :backoffs_ms, [0]),
       down_retry_backoffs: [1],
       shutdown_down_barrier_ms: 0},
      id: watcher_name
    )
  end

  defp prove_local_agent_down(watcher, agent_id, owner_generation) do
    pid = registered_effect_owner(agent_id, owner_generation)
    assert :ok = AgentWatcher.track(watcher, pid, agent_id, owner_generation)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    await_effect_watcher_release(watcher, pid, 100)

    case AgentRestartGuards.get(agent_id) do
      %{last_owner_token: ^owner_generation} = guard ->
        {:recorded, guard}

      _no_loss_guard ->
        incident = AgentTerminations.get_by_lease(owner_generation)
        assert incident.status == "reconciled"
        {:reconciled_without_loss, incident}
    end
  end

  defp registered_effect_owner(agent_id, owner_generation) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_generation)
        send(parent, {:effect_owner_registered, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:effect_owner_registered, ^pid, {:ok, _owner}}, 2_000
    pid
  end

  defp await_effect_watcher_release(_watcher, _pid, 0),
    do: flunk("AgentWatcher did not reconcile exact Effect-generation owner DOWN")

  defp await_effect_watcher_release(watcher, pid, attempts) do
    case :sys.get_state(watcher, 30_000) do
      %{pids: pids, pending_downs: pending} when not is_map_key(pids, pid) ->
        if map_size(pending) == 0,
          do: :ok,
          else: await_effect_watcher_release(watcher, pid, attempts - 1)

      _state ->
        await_effect_watcher_release(watcher, pid, attempts - 1)
    end
  end

  defp exact_effect_scope!(agent_id, owner_generation) do
    case Scope.partition_for_agent_owner(agent_id, owner_generation) do
      {:ok, session, partition} -> exact_effect_scope(session, partition)
      {:error, reason} -> flunk("exact Effect authority unavailable: #{inspect(reason)}")
    end
  end

  defp exact_effect_scope(session, partition) do
    %{
      coordination_activation_epoch: session.activation_epoch,
      coordination_partition_id: partition.partition_id,
      coordination_partition_epoch: partition.ownership_epoch,
      coordination_node_incarnation_id: session.id
    }
  end

  defp earlier_datetime(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp await_task_termination_proof!(assignment_id, attempts \\ 20)

  defp await_task_termination_proof!(_assignment_id, 0),
    do: flunk("Guardian did not persist the exact Task termination proof")

  defp await_task_termination_proof!(assignment_id, attempts) do
    guardian = Process.whereis(Maraithon.Runtime.TaskGuardian)
    state = :sys.get_state(guardian, 30_000)

    # Drive the fixed production retry handler only after authenticated DOWN
    # has enqueued durable persistence. This is synchronization, not proof.
    if MapSet.size(state.pending_persistence_set) > 0 do
      send(guardian, :retry_pending_task_terminations)
      _ = :sys.get_state(guardian, 30_000)
    else
      :erlang.yield()
    end

    case SQL.query!(
           Repo,
           """
           SELECT 1
           FROM public.runtime_task_termination_proofs
           WHERE assignment_id = $1::uuid
           LIMIT 1
           """,
           [Ecto.UUID.dump!(assignment_id)]
         ).rows do
      [[1]] -> :ok
      [] -> await_task_termination_proof!(assignment_id, attempts - 1)
    end
  end

  defp start_gated_preactivation!(agent, owner_generation) do
    BootGate.open()

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    test_pid = self()

    # Deterministic barrier at the production ordering boundary: the exact
    # child is PID-bound and Guardian-registered, but cannot activate durably or
    # enter provider code until the test releases it.
    task_starter = fn effect, _completion_writer, _completion_sleeper ->
      gate = make_ref()

      identity = %{
        effect_id: effect.id,
        agent_id: effect.agent_id,
        claim_token: effect.claim_token,
        assignment_id: effect.coordination_task_assignment_id,
        supervisor_id: effect.claim_supervisor_id,
        task_id: effect.claim_task_id
      }

      task =
        Task.Supervisor.async_nolink(
          Maraithon.Runtime.ExactEffectTaskSupervisor,
          fn ->
            receive do
              {:begin_effect_preactivation, ^gate} -> :ok
            end

            :ok = Maraithon.Runtime.EffectTaskSupervisor.register_current!(identity)
            send(test_pid, {:effect_preactivation_gated, self(), identity})

            receive do
              {:continue_effect_preactivation, ^gate} -> :ok
            end
          end,
          shutdown: :brutal_kill
        )

      case Maraithon.Runtime.EffectTaskSupervisor.bind_task(identity, task.pid) do
        :ok ->
          send(task.pid, {:begin_effect_preactivation, gate})
          {:bound_task, task}

        {:error, reason} ->
          _ =
            Task.Supervisor.terminate_child(
              Maraithon.Runtime.ExactEffectTaskSupervisor,
              task.pid
            )

          {:error, reason}
      end
    end

    runner = start_supervised!({EffectRunner, task_starter: task_starter})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)

    send(runner, :poll)

    assert_receive {:effect_preactivation_gated, worker, identity}, 15_000
    _ = :sys.get_state(runner, 15_000)
    worker_ref = Process.monitor(worker)

    assert identity.effect_id == effect_id

    assert {:ok, [guardian_identity]} =
             Maraithon.Runtime.EffectTaskSupervisor.active_identities()

    assert guardian_identity == identity

    %{
      effect_id: effect_id,
      identity: identity,
      renewer: renewer,
      runner: runner,
      worker: worker,
      worker_ref: worker_ref
    }
  end

  defp insert_claimed_exact_effect!(
         agent,
         owner_generation,
         claim_token,
         owner_node,
         supervisor_id,
         task_id,
         now,
         effect_id \\ Ecto.UUID.generate(),
         assignment_state \\ :running,
         termination_capability_digest \\ :crypto.hash(:sha256, Ecto.UUID.generate()),
         assignment_id \\ Ecto.UUID.generate()
       ) do
    {:ok, effect} =
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_write!()
        {:ok, session, partition} = Scope.partition_for_agent_owner(agent.id, owner_generation)

        attrs =
          %{
            id: effect_id,
            agent_id: agent.id,
            owner_user_id: agent.user_id,
            idempotency_key: Ecto.UUID.generate(),
            effect_type: "tool_call",
            params: %{"__maraithon_effect_protocol" => 2, "tool" => "time", "args" => %{}},
            status: "pending",
            runtime_owner_generation: owner_generation,
            attempts: 0,
            max_attempts: 3
          }
          |> Map.merge(exact_effect_scope(session, partition))

        pending =
          %Effect{}
          |> Effect.protocol_changeset(attrs)
          |> Repo.insert!()

        {:ok, assignment} =
          TaskClaims.reserve(
            session,
            partition,
            %{
              work_kind: "effect",
              work_id: pending.id,
              claim_token: claim_token,
              assignment_id: assignment_id,
              supervisor_id: supervisor_id,
              local_task_id: task_id,
              termination_capability_digest: termination_capability_digest
            },
            ttl_ms: 60_000,
            authority_lease_cap:
              Repo.get_by!(Maraithon.Runtime.AgentRuntimeLease,
                agent_id: agent.id,
                owner_token: owner_generation
              ).lease_until
          )

        claim_expires_at =
          now
          |> DateTime.add(60, :second)
          |> earlier_datetime(assignment.lease_expires_at)

        {1, _rows} =
          Repo.update_all(
            from(effect in Effect,
              where: effect.id == ^pending.id and effect.status == "pending"
            ),
            set: [
              status: "claimed",
              claim_token: claim_token,
              claim_owner_node: owner_node,
              claim_heartbeat_at: now,
              claim_expires_at: claim_expires_at,
              claim_supervisor_id: supervisor_id,
              claim_task_id: task_id,
              claimed_by: owner_node,
              claimed_at: now,
              coordination_task_assignment_id: assignment.id,
              updated_at: now
            ]
          )

        claimed = Repo.get!(Effect, pending.id)

        case assignment_state do
          :reserved ->
            claimed

          :running ->
            running =
              TaskClaims.activate_effect_in_transaction!(
                assignment,
                agent.id,
                owner_generation
              )

            assert running.state == "running"
            claimed
        end
      end)

    effect
  end

  defp activate_exact do
    effect_result =
      ProtocolCutover.activate(
        [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
      )

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)

    case effect_result do
      {:ok, effect_status} when effect_status in [:activated, :already_active] ->
        Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)

        runtime_result =
          CoordinationProtocol.activate(
            [confirmation: CoordinationProtocol.activation_confirmation()] ++ @activation_evidence
          )

        Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)

        case runtime_result do
          {:ok, runtime_status} when runtime_status in [:activated, :already_active] ->
            ensure_coordination_authority!()
            {:ok, effect_status}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  defp ensure_coordination_authority! do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    unless Keyword.get(runtime, :coordination_test_session) do
      {:ok, joining} =
        Authority.register_node(
          node_name: "effect-generation-fence@test",
          revision: String.duplicate("a", 40),
          ttl_ms: 300_000
        )

      {:ok, session} = Authority.mark_node_ready(joining)
      {:ok, preparing_leader} = Authority.acquire_leader(session, 300_000)
      {:ok, leader} = Authority.mark_leader_ready(preparing_leader)

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        runtime
        |> Keyword.put(:coordination_test_session, session)
        |> Keyword.put(:coordination_test_leader, leader)
      )
    end

    :ok
  end

  defp ensure_user_partition!(user_id) do
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)
    session = Keyword.fetch!(runtime, :coordination_test_session)
    leader = Keyword.fetch!(runtime, :coordination_test_leader)
    partition_id = user_id |> Partitioning.tenant_key() |> Partitioning.partition_for()

    case Repo.get!(Partition, partition_id) do
      %Partition{state: "unassigned"} ->
        {:ok, _preparing} =
          Authority.assign_partition(leader, session, partition_id, ttl_ms: 300_000)

        {:ok, _ready} = Authority.mark_partition_ready(session, partition_id)
        :ok

      %Partition{
        state: "ready",
        owner_node_incarnation_id: owner_id,
        activation_epoch: activation_epoch
      }
      when owner_id == session.id and activation_epoch == session.activation_epoch ->
        :ok
    end
  end

  defp legacy_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{"name" => name, "prompt" => "test", "subscribe" => [], "tools" => []}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    agent
  end

  defp exact_agent(name, opts \\ []) do
    agent = legacy_agent(name)
    :ok = ensure_user_partition!(agent.user_id)

    claim_opts =
      [ttl_ms: 60_000] ++
        case Keyword.fetch(opts, :watcher) do
          {:ok, watcher} -> [watcher: watcher]
          :error -> []
        end

    {:ok, claimed} = AgentLeases.claim(agent.id, claim_opts)
    {:ok, _ready} = AgentLeases.mark_ready(agent.id, claimed.owner_token)
    {agent, claimed.owner_token}
  end

  defp configure_blocking_provider do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_test_pid = Application.get_env(:maraithon, :generation_fence_test_pid)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(original_runtime, :llm_provider, BlockingProvider)
    )

    Application.put_env(:maraithon, :generation_fence_test_pid, self())

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)

      if is_nil(original_test_pid) do
        Application.delete_env(:maraithon, :generation_fence_test_pid)
      else
        Application.put_env(:maraithon, :generation_fence_test_pid, original_test_pid)
      end

      LLMRateLimiter.reset()
    end)
  end

  defp restart_task_system! do
    parent = Maraithon.Runtime.Supervisor
    child = Maraithon.Runtime.TaskSystemSupervisor

    :ok = Supervisor.terminate_child(parent, child)
    {:ok, _pid} = Supervisor.restart_child(parent, child)

    # Synchronous readiness fence; no sleep and no unsupervised replacement.
    _ = :sys.get_state(EffectTaskAuthority)
    :ok
  end

  defp stop_existing_runner do
    case Process.whereis(EffectRunner) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end
end
