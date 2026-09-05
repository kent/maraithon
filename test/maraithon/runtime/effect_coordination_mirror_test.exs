defmodule Maraithon.Runtime.EffectCoordinationMirrorTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Effects
  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Coordination.Authority
  alias Maraithon.Runtime.Coordination.Partitioning
  alias Maraithon.Runtime.Coordination.Protocol
  alias Maraithon.Runtime.Coordination.Session
  alias Maraithon.Runtime.Coordination.TaskClaims
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.EffectTaskAuthority
  alias Maraithon.Runtime.EffectTaskSupervisor
  alias Maraithon.Runtime.TaskGuardian
  alias Maraithon.Runtime.Effects.{LLMRateLimiter, ToolCallCommand}
  alias Maraithon.Todos.Todo

  @revision "abcdef0123456789abcdef0123456789abcdef01"
  @evidence_id "fly:machines-destroyed:effect-coordination-test"
  @activated_by "operator@example.test"
  @evidence_digest :crypto.hash(:sha256, "effect-coordination-test-evidence")
  @activation_evidence [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @activated_by,
    revision: @revision
  ]

  defmodule BoundaryProvider do
    @moduledoc false

    def complete(params) do
      test_pid = Application.fetch_env!(:maraithon, :effect_coordination_test_pid)
      mode = Application.fetch_env!(:maraithon, :effect_coordination_provider_mode)
      send(test_pid, {:coordination_provider_entered, self(), params})

      case mode do
        :success ->
          receive do
            :release ->
              {:ok,
               %{
                 content: "coordinated",
                 model: "coordination-test-v1",
                 tokens_in: 1,
                 tokens_out: 1,
                 finish_reason: "stop",
                 usage: %{}
               }}
          end

        :crash ->
          Process.exit(self(), :kill)
      end
    end
  end

  setup_all do
    restart_task_system!()
    :ok
  end

  setup tags do
    # Stop retained Guardian capability/retry state before DataCase releases the
    # current shared sandbox owner.
    on_exit(&restart_task_system!/0)

    context =
      active_effect_authority!(agent_watcher?: tags[:agent_owner_proof_fallback] == true)

    configure_provider!(:success)
    BootGate.open()
    LLMRateLimiter.reset()
    {:ok, context}
  end

  test "commit-unknown rollback is locked, scrubbed, and replayed as uncommitted", context do
    effect = insert_pending_effect!(context, "commit-unknown-rollback")
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()

    assert {:ok, identity} =
             EffectTaskSupervisor.reserve_coordinated(
               effect.id,
               effect.agent_id,
               claim_token,
               assignment_id
             )

    assert {:ok, :uncommitted} = EffectTaskSupervisor.terminate_exact(identity)
    assert {:ok, :uncommitted} = EffectTaskSupervisor.terminate_exact(identity)

    assert Repo.get!(Effect, effect.id).status == "pending"
    assert TaskClaims.get(assignment_id) == nil
    refute Map.has_key?(:sys.get_state(EffectTaskAuthority).reservations, identity.task_id)
    assert {:ok, active_identities} = EffectTaskSupervisor.active_identities()
    refute Enum.any?(active_identities, &(&1.task_id == identity.task_id))
  end

  test "delayed commit-unknown cleanup accepts a later Effect claim in the same authority",
       context do
    effect = insert_pending_effect!(context, "commit-unknown-reclaimed-effect")

    assert {:ok, stale_identity} =
             EffectTaskSupervisor.reserve_coordinated(
               effect.id,
               effect.agent_id,
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             )

    test_pid = self()

    starter = fn claimed, _writer, _sleeper ->
      current_identity = %{
        effect_id: claimed.id,
        agent_id: claimed.agent_id,
        claim_token: claimed.claim_token,
        assignment_id: claimed.coordination_task_assignment_id,
        supervisor_id: claimed.claim_supervisor_id,
        task_id: claimed.claim_task_id
      }

      Task.Supervisor.async_nolink(Maraithon.Runtime.ExactEffectTaskSupervisor, fn ->
        receive do: ({:effect_task_bound, id} when id == claimed.id -> :ok)
        :ok = EffectTaskSupervisor.register_current!(current_identity)
        send(test_pid, {:later_effect_claim, current_identity})
        receive do: (:finish -> :ok)
      end)
    end

    runner = start_runner!(task_starter: starter)
    send(runner, :poll)
    assert_receive {:later_effect_claim, current_identity}, 10_000
    assert current_identity.supervisor_id == stale_identity.supervisor_id
    assert current_identity.claim_token != stale_identity.claim_token
    assert current_identity.task_id != stale_identity.task_id
    assert current_identity.assignment_id != stale_identity.assignment_id

    assert {:ok, :uncommitted} = EffectTaskSupervisor.terminate_exact(stale_identity)
    assert {:ok, :never_activated} = EffectTaskSupervisor.terminate_exact(current_identity)
  end

  test "an already-bound child that activates before starter return is not rebound", context do
    effect = insert_pending_effect!(context, "already-bound-child")
    test_pid = self()

    starter = fn claimed, _writer, _sleeper ->
      starter_owner = self()

      identity = %{
        effect_id: claimed.id,
        agent_id: claimed.agent_id,
        claim_token: claimed.claim_token,
        assignment_id: claimed.coordination_task_assignment_id,
        supervisor_id: claimed.claim_supervisor_id,
        task_id: claimed.claim_task_id
      }

      gate = make_ref()

      task =
        Task.Supervisor.async_nolink(Maraithon.Runtime.ExactEffectTaskSupervisor, fn ->
          receive do: ({:bound, ^gate} -> :ok)
          :ok = EffectTaskSupervisor.register_current!(identity)
          send(starter_owner, {:already_bound_before_return, self()})
          send(test_pid, {:already_bound_activated, self()})
          receive do: (:finish -> :ok)
        end)

      :ok = EffectTaskSupervisor.bind_task(identity, task.pid)
      send(task.pid, {:bound, gate})

      receive do
        {:already_bound_before_return, pid} when pid == task.pid -> :ok
      after
        2_000 -> exit(:already_bound_child_did_not_activate)
      end

      {:bound_task, task}
    end

    runner = start_runner!(task_starter: starter)
    send(runner, :poll)
    assert_receive {:already_bound_activated, worker}, 10_000
    assert Process.alive?(worker)
    assert :sys.get_state(runner).tasks[effect.id].pid == worker
    send(worker, :finish)
  end

  test "the final entry transaction is durable before blocking provider invocation",
       context do
    effect = insert_pending_effect!(context, "completion")
    runner = start_runner!()
    send(runner, :poll)

    assert_receive {:coordination_provider_entered, worker, _params}, 10_000

    claimed = Repo.get!(Effect, effect.id)
    assert claimed.status == "executing"
    assert is_binary(claimed.coordination_task_assignment_id)

    entered = TaskClaims.get(claimed.coordination_task_assignment_id)
    assert entered.state == "running"
    assert entered.provider_boundary == "entered"
    assert outcome_evidence_count(entered.id) == 0

    worker_ref = Process.monitor(worker)
    send(worker, :release)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 10_000

    _ = :sys.get_state(runner, 15_000)
    completed = Repo.get!(Effect, effect.id)
    settled = TaskClaims.get(claimed.coordination_task_assignment_id)

    assert completed.status == "completed"
    assert settled.state == "settled"

    assert completed.result["content"] == "coordinated"
    assert settled.provider_boundary == "outcome_known"
    assert settled.outcome == "completed"
    assert outcome_evidence_count(settled.id) == 1
    assert [["completed"]] = outcome_evidence(settled.id)
    assert termination_proof_count(settled.id) == 0

    authority_state = :sys.get_state(EffectTaskAuthority)
    refute Map.has_key?(authority_state.reservations, claimed.claim_task_id)
    refute MapSet.member?(authority_state.cleanup_set, claimed.claim_task_id)
  end

  test "Guardian stages spontaneous entered Effect DOWN without a live runner", context do
    effect = insert_pending_effect!(context, "spontaneous-entered-down")
    runner = start_runner!()
    send(runner, :poll)

    assert_receive {:coordination_provider_entered, worker, _params}, 10_000
    claimed = Repo.get!(Effect, effect.id)
    assignment = TaskClaims.get(claimed.coordination_task_assignment_id)
    assert assignment.state == "running"
    assert assignment.provider_boundary == "entered"

    :ok = :sys.suspend(runner)

    on_exit(fn ->
      if Process.alive?(runner), do: :sys.resume(runner)
    end)

    worker_ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 10_000

    # Guardian independently owns convergence; controller-bound access is not
    # replayable from this test process.
    _ = :sys.get_state(TaskGuardian)

    send(Process.whereis(TaskGuardian), :retry_pending_task_terminations)
    _ = :sys.get_state(TaskGuardian, 15_000)

    cancelling = Repo.get!(Effect, effect.id)
    proven = TaskClaims.get(claimed.coordination_task_assignment_id)
    assert cancelling.status == "cancelling"
    assert cancelling.cancellation_state == "requested"
    assert cancelling.cancellation_reason == "effect_task_exited_without_outcome"
    assert proven.state == "termination_proven"
    assert proven.provider_boundary == "outcome_unknown"
    assert is_nil(proven.outcome)
    assert termination_proof_count(proven.id) == 1

    :ok = :sys.resume(runner)
  end

  @tag agent_owner_proof_fallback: true
  test "reconciled old Agent proof settles owner work after a successor on blocked topology",
       context do
    old_generation = context.owner_generation

    owner_case = insert_claimed_task!(context, "owner-proof-fallback", :reserved)
    activation_case = insert_claimed_task!(context, "ready-activation-fence", :reserved)
    renewal_case = insert_claimed_task!(context, "ready-renewal-fence", :running)

    assert {:ok, plan} =
             Cancellation.prepare_exact_claims(
               context.agent.id,
               [owner_case.effect],
               "owner_proof_fallback"
             )

    assert Repo.get!(Effect, owner_case.effect.id).status == "cancelling"

    incident = prove_exact_agent_down!(context.watcher, context.agent.id, old_generation)
    assert incident.status == "reconciled"
    assert incident.lease_token == old_generation
    assert AgentLeases.get(context.agent.id) == nil

    guard = AgentRestartGuards.get(context.agent.id)
    assert guard.last_owner_token == old_generation
    assert guard.needs_recovery

    assert {:ok, claimed_successor} =
             AgentLeases.claim_recovery(context.agent.id, guard.generation, ttl_ms: 300_000)

    assert {:ok, successor} =
             AgentLeases.finish_recovery(
               context.agent.id,
               claimed_successor.owner_token,
               guard.generation
             )

    assert successor.owner_token != old_generation
    assert successor.ready_at != nil

    block_and_expire_topology!(context)

    assert {:error, :coordination_task_authority_lost} =
             Repo.transaction(fn ->
               _effect = lock_effect_for_update!(activation_case.effect.id)

               TaskClaims.activate_effect_in_transaction!(
                 activation_case.assignment,
                 context.agent.id,
                 old_generation
               )
             end)

    assert {:error, :coordination_task_authority_lost} =
             Repo.transaction(fn ->
               _effect = lock_effect_for_update!(renewal_case.effect.id)

               TaskClaims.renew_effect_in_transaction!(
                 renewal_case.assignment,
                 context.agent.id,
                 old_generation,
                 60_000
               )
             end)

    invalid_owner_identities = [
      {context.agent.id, Ecto.UUID.generate()},
      {Ecto.UUID.generate(), Ecto.UUID.generate()}
    ]

    Enum.each(invalid_owner_identities, fn {agent_id, generation} ->
      assert {:error, :coordination_task_authority_lost} =
               Repo.transaction(fn ->
                 _effect = lock_effect_for_update!(renewal_case.effect.id)

                 TaskClaims.settle_effect_before_provider_in_transaction!(
                   renewal_case.assignment,
                   agent_id,
                   generation
                 )
               end)
    end)

    assert {:ok, proven} =
             Cancellation.record_local_coordination_termination(
               owner_case.assignment,
               "never_activated",
               "ignored-for-canonical-reserved-proof",
               owner_case.capability_secret
             )

    assert proven.state == "termination_proven"
    assert proven.provider_boundary == "not_entered"

    assert {:ok, %{requested: 1, claims_settled: 1, unresolved: []}} =
             Cancellation.execute(plan)

    settled = TaskClaims.get(owner_case.assignment.id)
    cancelled = Repo.get!(Effect, owner_case.effect.id)

    assert settled.state == "settled"
    assert settled.provider_boundary == "not_entered"
    assert settled.outcome == "cancelled_before_provider"
    assert cancelled.status == "cancelled"
    assert cancelled.cancellation_state == "settled"
    assert AgentLeases.get(context.agent.id).owner_token == successor.owner_token
  end

  test "pre-provider failure stays a nonterminal intent until authenticated physical DOWN",
       context do
    test_pid = self()

    observer = fn claimed, :termination_pending ->
      identity = %{
        effect_id: claimed.id,
        agent_id: claimed.agent_id,
        claim_token: claimed.claim_token,
        assignment_id: claimed.coordination_task_assignment_id,
        supervisor_id: claimed.claim_supervisor_id,
        task_id: claimed.claim_task_id
      }

      send(test_pid, {:pre_provider_failure_staged, self(), identity})

      receive do
        :exit_after_staging -> :ok
      end
    end

    runner = start_runner!(pre_provider_outcome_observer: observer)

    effect =
      insert_pending_effect!(context, "proof-first-pre-provider-failure", %{
        effect_type: "unknown_effect_type",
        params: %{"__maraithon_effect_protocol" => 2}
      })

    send(runner, :poll)

    assert_receive {:pre_provider_failure_staged, worker, identity}, 15_000

    staged = Repo.get!(Effect, effect.id)
    reserved = TaskClaims.get(identity.assignment_id)

    assert staged.status == "cancelling"
    assert staged.cancellation_state == "requested"
    assert staged.last_failure_code == "__maraithon_pre_provider_intent_v1"
    assert staged.last_failure_attempt == staged.attempts
    assert reserved.state == "reserved"
    assert reserved.provider_boundary == "not_entered"
    assert reserved.ready_at == nil
    assert termination_proof_count(reserved.id) == 0
    assert Effects.terminal_result(staged) == {:error, :effect_outcome_ambiguous}

    send(worker, :exit_after_staging)

    {failed, settled} =
      after_runner_barrier(runner, fn ->
        stored = Repo.get!(Effect, effect.id)
        assignment = TaskClaims.get(identity.assignment_id)

        if stored.status == "failed" and match?(%{state: "settled"}, assignment),
          do: {:ok, {stored, assignment}},
          else: :retry
      end)

    assert Effects.terminal_result(failed) == {:error, :unknown_effect_type}
    assert settled.provider_boundary == "not_entered"
    assert settled.outcome == "cancelled_before_provider"
    assert termination_proof_count(settled.id) == 1
    assert termination_proof_kinds(settled.id) == ["never_activated"]

    corrupted_effect =
      insert_pending_effect!(context, "corrupted-proof-first-pre-provider-failure", %{
        effect_type: "unknown_effect_type",
        params: %{"__maraithon_effect_protocol" => 2}
      })

    send(runner, :poll)
    assert_receive {:pre_provider_failure_staged, corrupted_worker, corrupted_identity}, 15_000

    corrupt_pre_provider_reason_suffix!(corrupted_effect.id)
    assert Maraithon.Effects.ProtocolCutover.mode() == :exact
    corrupted_worker_ref = Process.monitor(corrupted_worker)
    send(corrupted_worker, :exit_after_staging)

    assert_receive {:DOWN, ^corrupted_worker_ref, :process, ^corrupted_worker, :normal}, 5_000

    {cancelled, corrupted_settled} =
      after_runner_barrier(runner, fn ->
        stored = Repo.get!(Effect, corrupted_effect.id)
        assignment = TaskClaims.get(corrupted_identity.assignment_id)

        if stored.status == "cancelled" and match?(%{state: "settled"}, assignment),
          do: {:ok, {stored, assignment}},
          else: :retry
      end)

    assert Effects.terminal_result(cancelled) == {:error, :effect_outcome_ambiguous}
    assert corrupted_settled.outcome == "cancelled_before_provider"
    assert termination_proof_count(corrupted_settled.id) == 1
  end

  test "deterministic command preflight refusals never enter the provider boundary", context do
    runner = start_runner!()

    refusals = [
      {"unknown-command",
       %{
         effect_type: "unknown_effect_type",
         params: %{"__maraithon_effect_protocol" => 2}
       }},
      {"invalid-llm-request",
       %{
         params: %{
           "__maraithon_effect_protocol" => 2,
           "messages" => "not-a-message-list"
         }
       }},
      {"unknown-tool",
       %{
         effect_type: "tool_call",
         params: %{
           "__maraithon_effect_protocol" => 2,
           "tool" => "definitely_not_a_registered_tool",
           "args" => %{}
         }
       }},
      {"policy-refusal",
       %{
         effect_type: "tool_call",
         params: %{
           "__maraithon_effect_protocol" => 2,
           "tool" => "gmail_send_message",
           "args" => %{
             "to" => "recipient@example.test",
             "subject" => "must not send",
             "body" => "preflight must refuse this unconfirmed action"
           }
         }
       }}
    ]

    Enum.each(refusals, fn {suffix, overrides} ->
      effect = insert_pending_effect!(context, suffix, overrides)
      send(runner, :poll)

      {failed, settled} =
        after_runner_barrier(runner, fn ->
          stored = Repo.get!(Effect, effect.id)

          assignment =
            if stored.coordination_task_assignment_id,
              do: TaskClaims.get(stored.coordination_task_assignment_id)

          if stored.status == "failed" and match?(%{state: "settled"}, assignment),
            do: {:ok, {stored, assignment}},
            else: :retry
        end)

      assert failed.status == "failed"
      assert failed.last_failure_code == nil
      assert failed.last_failure_attempt == nil

      case suffix do
        "unknown-command" ->
          assert Effects.terminal_result(failed) == {:error, :unknown_effect_type}

        "invalid-llm-request" ->
          assert Effects.terminal_result(failed) ==
                   {:error, {:invalid_request, "redacted_detail"}}

        "unknown-tool" ->
          assert Effects.terminal_result(failed) == {:error, "redacted_detail"}

        "policy-refusal" ->
          assert {:error, {:tool_policy_needs_confirmation, decision}} =
                   Effects.terminal_result(failed)

          assert decision["reason_code"] == "confirmation_required"
      end

      assert settled.provider_boundary == "not_entered"
      assert settled.outcome == "cancelled_before_provider"
      assert outcome_evidence_count(settled.id) == 0
      assert termination_proof_count(settled.id) == 1
      refute_receive {:coordination_provider_entered, _worker, _params}, 10
    end)
  end

  test "prepared tool authority is fenced against policy, version, and allowlist drift",
       context do
    {agent, allowed_version, replacement_version} =
      install_tool_authority_package!(context.agent)

    todo = insert_tool_authority_todo!(agent.user_id)
    original_title = todo.title
    test_pid = self()

    prepared_observer = fn claimed, ToolCallCommand, prepared ->
      send(
        test_pid,
        {:tool_command_prepared, self(), claimed.id, prepared.authority_binding,
         Map.has_key?(prepared.policy_context, :agent_policy) or
           Map.has_key?(prepared.policy_context, "agent_policy")}
      )

      receive do
        {:release_tool_command, effect_id} when effect_id == claimed.id -> :ok
      end
    end

    runner = start_runner!(command_prepared_observer: prepared_observer)

    Enum.each([:policy, :version, :allowlist], fn drift ->
      reset_tool_authority!(agent.id, allowed_version.id)
      current_agent = Repo.get!(Maraithon.Agents.Agent, agent.id)
      effect_context = %{context | agent: current_agent}
      changed_title = "must-not-run-#{drift}"

      effect =
        insert_pending_effect!(effect_context, "tool-authority-#{drift}", %{
          effect_type: "tool_call",
          params: %{
            "__maraithon_effect_protocol" => 2,
            "tool" => "update_todo",
            "args" => %{"todo_id" => todo.id, "title" => changed_title},
            "confirmation_state" => "confirmed"
          }
        })

      send(runner, :poll)
      effect_id = effect.id

      assert_receive {:tool_command_prepared, worker, ^effect_id, authority_binding,
                      policy_embedded?},
                     15_000

      assert Enum.sort(Map.keys(authority_binding)) ==
               Enum.sort([
                 :version,
                 :digest,
                 :agent_id,
                 :binding_id,
                 :agent_package_id,
                 :agent_package_version_id
               ])

      assert byte_size(authority_binding.digest) == 32
      refute policy_embedded?

      # Bind the supervised command task explicitly to this test's sandbox
      # owner before it enters the final database transaction. This avoids a
      # child-exit checkout race obscuring the provider-entry invariant.
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker)

      case drift do
        :policy ->
          replace_binding_tool_policy!(current_agent, %{"denied_tools" => ["update_todo"]})

        :version ->
          assert {:ok, _upgraded} =
                   Agents.upgrade_agent_installation(current_agent, replacement_version)

        :allowlist ->
          version = Repo.get!(Maraithon.Agents.AgentPackageVersion, allowed_version.id)

          assert {:ok, _changed} =
                   Agents.update_agent_package_version(version, %{tool_allowlist: []})
      end

      send(worker, {:release_tool_command, effect_id})

      {terminal, settled} =
        after_runner_barrier(runner, fn ->
          stored = Repo.get!(Effect, effect.id)

          assignment =
            if stored.coordination_task_assignment_id,
              do: TaskClaims.get(stored.coordination_task_assignment_id)

          if stored.status in ["failed", "completed"] and
               match?(%{state: "settled"}, assignment),
             do: {:ok, {stored, assignment}},
             else: :retry
        end)

      assert terminal.status == "failed"
      assert Effects.terminal_result(terminal) == {:error, :stale_effect_context}
      assert terminal.last_failure_code == nil
      assert terminal.last_failure_attempt == nil
      assert settled.provider_boundary == "not_entered"
      assert settled.outcome == "cancelled_before_provider"
      assert outcome_evidence_count(settled.id) == 0
      assert termination_proof_count(settled.id) == 0
      assert Repo.get!(Todo, todo.id).title == original_title
    end)
  end

  test "proof-safe pre-provider requeue preserves prior timeout provenance",
       context do
    effect =
      insert_pending_effect!(context, "before-entry-crash", %{
        attempts: 1,
        last_failure_code: "timeout",
        last_failure_attempt: 1
      })

    test_pid = self()

    starter = fn _claimed, _writer, _sleeper ->
      Task.Supervisor.async_nolink(Maraithon.Runtime.ExactEffectTaskSupervisor, fn ->
        send(test_pid, {:before_entry_task_started, self()})

        receive do
          :release_before_entry_crash -> exit(:before_provider_entry)
        end
      end)
    end

    runner = start_runner!(task_starter: starter)
    send(runner, :poll)
    assert_receive {:before_entry_task_started, worker}, 10_000

    claimed = Repo.get!(Effect, effect.id)
    assignment_id = claimed.coordination_task_assignment_id
    assert claimed.status == "claimed"
    assert TaskClaims.get(assignment_id).state == "reserved"

    worker_ref = Process.monitor(worker)
    send(worker, :release_before_entry_crash)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :before_provider_entry}, 10_000

    {pending, settled} =
      after_runner_barrier(runner, fn ->
        stored = Repo.get!(Effect, effect.id)
        assignment = TaskClaims.get(assignment_id)

        if stored.status == "pending" and match?(%{state: "settled"}, assignment),
          do: {:ok, {stored, assignment}},
          else: :retry
      end)

    assert is_nil(pending.claim_token)
    assert is_nil(pending.coordination_task_assignment_id)
    assert is_nil(pending.cancellation_state)
    assert pending.last_failure_code == "timeout"
    assert pending.last_failure_attempt == 1
    assert settled.provider_boundary == "not_entered"
    assert settled.outcome == "cancelled_before_provider"
    assert outcome_evidence_count(settled.id) == 0
    assert termination_proof_count(settled.id) == 1
  end

  test "a crash after the entry commit remains provider-outcome ambiguous", context do
    configure_provider!(:crash)
    effect = insert_pending_effect!(context, "entered-crash")
    runner = start_runner!()
    send(runner, :poll)

    assert_receive {:coordination_provider_entered, _worker, _params}, 10_000

    {failed, ambiguous} =
      after_runner_barrier(runner, fn ->
        stored = Repo.get!(Effect, effect.id)

        assignment =
          if stored.coordination_task_assignment_id,
            do: TaskClaims.get(stored.coordination_task_assignment_id)

        if stored.status == "failed" and match?(%{state: "outcome_ambiguous"}, assignment),
          do: {:ok, {stored, assignment}},
          else: :retry
      end)

    assert failed.error == "effect_outcome_ambiguous"
    assert failed.cancellation_state == "settled"
    assert is_nil(failed.last_failure_code)
    assert is_nil(failed.last_failure_attempt)
    assert ambiguous.provider_boundary == "outcome_unknown"
    assert ambiguous.outcome == "provider_outcome_ambiguous"
    assert outcome_evidence_count(ambiguous.id) == 0
    assert termination_proof_count(ambiguous.id) == 1
  end

  defp active_effect_authority!(opts \\ []) do
    assert {:ok, :attested} =
             as_activation_operator(fn ->
               Protocol.attest_effect_activation_evidence(@activation_evidence)
             end)

    Repo.query!(
      "ALTER TABLE public.background_jobs VALIDATE CONSTRAINT background_jobs_partition_shape",
      []
    )

    Repo.query!(
      "ALTER TABLE public.scheduled_jobs VALIDATE CONSTRAINT scheduled_jobs_partition_shape",
      []
    )

    assert {:ok, :activated} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
             )

    assert {:ok, :activated} =
             as_activation_operator(fn -> Protocol.activate(coordination_activation_opts()) end)

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [])

    user_id = "coord-effect-#{System.unique_integer([:positive])}@example.test"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{"name" => "coord-effect", "prompt" => "test", "subscribe" => [], "tools" => []}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))

    node =
      Authority.register_node(
        revision: @revision,
        node_name: "coord-effect-test",
        ttl_ms: 300_000
      )
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    leader =
      Authority.acquire_leader(node, 300_000)
      |> ok!()
      |> Authority.mark_leader_ready()
      |> ok!()

    partition_id = Partitioning.partition_for("user:" <> user_id)

    partition =
      Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000)
      |> ok!()

    partition = Authority.mark_partition_ready(node, partition.partition_id) |> ok!()

    old_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, old_runtime) end)

    session =
      start_supervised!({Session, tick_ms: 600_000, required_workers: []})

    _ = :sys.get_state(session, 15_000)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(old_runtime, :multinode_coordination_enabled, true)
    )

    :sys.replace_state(session, fn state ->
      %{state | phase: :ready, session: node, leader: leader}
    end)

    watcher =
      if Keyword.get(opts, :agent_watcher?, false),
        do: start_agent_watcher!(),
        else: nil

    claim_opts =
      if watcher,
        do: [ttl_ms: 300_000, watcher: watcher],
        else: [ttl_ms: 300_000]

    {:ok, lease} = AgentLeases.claim(agent.id, claim_opts)
    {:ok, ready_lease} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    owner_generation = lease.owner_token

    %{
      agent: agent,
      lease: ready_lease,
      owner_generation: owner_generation,
      node: node,
      partition: partition,
      watcher: watcher
    }
  end

  defp insert_pending_effect!(context, suffix, overrides \\ %{}) do
    attrs =
      %{
        id: Ecto.UUID.generate(),
        agent_id: context.agent.id,
        owner_user_id: context.agent.user_id,
        idempotency_key: Ecto.UUID.generate(),
        effect_type: "llm_call",
        params: %{
          "__maraithon_effect_protocol" => 2,
          "model" => "coordination-test-v1",
          "messages" => [%{"role" => "user", "content" => suffix}]
        },
        status: "pending",
        runtime_owner_generation: context.owner_generation,
        attempts: 0,
        max_attempts: 3,
        coordination_activation_epoch: context.node.activation_epoch,
        coordination_partition_id: context.partition.partition_id,
        coordination_partition_epoch: context.partition.ownership_epoch,
        coordination_node_incarnation_id: context.node.id
      }
      |> Map.merge(overrides)

    {:ok, effect} =
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_write!()
        %Effect{} |> Effect.protocol_changeset(attrs) |> Repo.insert!()
      end)

    effect
  end

  defp insert_claimed_task!(context, suffix, assignment_state)
       when assignment_state in [:reserved, :running] do
    capability_secret = :crypto.strong_rand_bytes(32)
    effect_id = Ecto.UUID.generate()
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    supervisor_id = Ecto.UUID.generate()
    local_task_id = Ecto.UUID.generate()

    assert {:ok, result} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               pending =
                 %Effect{}
                 |> Effect.protocol_changeset(%{
                   id: effect_id,
                   agent_id: context.agent.id,
                   owner_user_id: context.agent.user_id,
                   idempotency_key: Ecto.UUID.generate(),
                   effect_type: "llm_call",
                   params: %{
                     "__maraithon_effect_protocol" => 2,
                     "model" => "coordination-test-v1",
                     "messages" => [%{"role" => "user", "content" => suffix}]
                   },
                   status: "pending",
                   runtime_owner_generation: context.owner_generation,
                   attempts: 0,
                   max_attempts: 3,
                   coordination_activation_epoch: context.node.activation_epoch,
                   coordination_partition_id: context.partition.partition_id,
                   coordination_partition_epoch: context.partition.ownership_epoch,
                   coordination_node_incarnation_id: context.node.id
                 })
                 |> Repo.insert!()

               assert {:ok, assignment} =
                        TaskClaims.reserve(
                          context.node,
                          context.partition,
                          %{
                            work_kind: "effect",
                            work_id: pending.id,
                            claim_token: claim_token,
                            assignment_id: assignment_id,
                            supervisor_id: supervisor_id,
                            local_task_id: local_task_id,
                            termination_capability_digest:
                              :crypto.hash(:sha256, capability_secret)
                          },
                          ttl_ms: 60_000,
                          authority_lease_cap: context.lease.lease_until
                        )

               now = DatabaseClock.now!()

               claim_expires_at =
                 earlier_datetime(DateTime.add(now, 60, :second), assignment.lease_expires_at)

               assert {1, _rows} =
                        Repo.update_all(
                          from(effect in Effect,
                            where: effect.id == ^pending.id and effect.status == "pending"
                          ),
                          set: [
                            status: "claimed",
                            claim_token: claim_token,
                            claim_owner_node: context.lease.owner_node,
                            claim_heartbeat_at: now,
                            claim_expires_at: claim_expires_at,
                            claim_supervisor_id: supervisor_id,
                            claim_task_id: local_task_id,
                            claimed_by: context.lease.owner_node,
                            claimed_at: now,
                            coordination_task_assignment_id: assignment.id,
                            updated_at: now
                          ]
                        )

               assignment =
                 case assignment_state do
                   :reserved ->
                     assignment

                   :running ->
                     TaskClaims.activate_effect_in_transaction!(
                       assignment,
                       context.agent.id,
                       context.owner_generation
                     )
                 end

               %{
                 assignment: assignment,
                 capability_secret: capability_secret,
                 effect: Repo.get!(Effect, pending.id)
               }
             end)

    result
  end

  defp install_tool_authority_package!(agent) do
    suffix = System.unique_integer([:positive])

    {:ok, package} =
      Agents.create_agent_package(%{
        slug: "runtime-tool-authority-#{suffix}",
        name: "Runtime tool authority #{suffix}"
      })

    {:ok, package} =
      Agents.publish_agent_package_version(package, %{
        version: "1.0.0",
        behavior: "prompt_agent",
        tool_allowlist: ["update_todo"]
      })

    allowed_version = package.latest_version

    {:ok, package} =
      Agents.publish_agent_package_version(package, %{
        version: "2.0.0",
        behavior: "prompt_agent",
        tool_allowlist: ["update_todo"]
      })

    replacement_version = package.latest_version

    config =
      agent.config
      |> Kernel.||(%{})
      |> Map.put("agent_package_version_id", allowed_version.id)

    {:ok, installed} =
      Agents.update_agent(agent, %{
        agent_package_id: package.id,
        agent_package_version_id: allowed_version.id,
        config: config
      })

    {installed, allowed_version, replacement_version}
  end

  defp reset_tool_authority!(agent_id, allowed_version_id) do
    agent = Repo.get!(Maraithon.Agents.Agent, agent_id)
    allowed_version = Repo.get!(Maraithon.Agents.AgentPackageVersion, allowed_version_id)

    unless allowed_version.tool_allowlist == ["update_todo"] do
      assert {:ok, _version} =
               Agents.update_agent_package_version(allowed_version, %{
                 tool_allowlist: ["update_todo"]
               })
    end

    if agent.agent_package_version_id != allowed_version_id do
      assert {:ok, _agent} = Agents.upgrade_agent_installation(agent, allowed_version)
    end

    replace_binding_tool_policy!(agent, %{})
  end

  defp replace_binding_tool_policy!(agent, tool_policy) when is_map(tool_policy) do
    # Exercise the final provider-entry fence against an adversarial committed
    # database mutation. Ordinary re-consent cannot change Binding authority
    # while an Agent lease is live, so this intentionally bypasses the Ecto
    # consent changeset without bypassing PostgreSQL transaction visibility.
    assert %{num_rows: 1} =
             Repo.query!(
               """
               UPDATE public.agent_isolation_bindings
               SET tool_policy = $2::jsonb,
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE agent_id = $1::uuid
               """,
               [Ecto.UUID.dump!(agent.id), tool_policy]
             )

    Repo.get_by!(Binding, agent_id: agent.id)
  end

  defp insert_tool_authority_todo!(user_id) do
    %Todo{}
    |> Todo.changeset(%{
      user_id: user_id,
      owner_user_id: user_id,
      source: "runtime_tool_authority_test",
      kind: "general",
      title: "Original tool authority title",
      summary: "Tool authority provider-entry regression fixture.",
      next_action: "Remain unchanged when prepared authority becomes stale.",
      dedupe_key: "runtime-tool-authority:#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp start_agent_watcher! do
    name = :"effect_coordination_agent_watcher_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AgentWatcher,
       name: name,
       reconcile?: false,
       recover?: false,
       crash_loop_max: 3,
       crash_loop_window_ms: 600_000,
       reresume_backoffs: [0],
       down_retry_backoffs: [1],
       shutdown_down_barrier_ms: 0},
      id: name
    )
  end

  defp prove_exact_agent_down!(watcher, agent_id, owner_generation) when is_pid(watcher) do
    owner = registered_agent_owner!(agent_id, owner_generation)
    assert :ok = AgentWatcher.track(watcher, owner, agent_id, owner_generation)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2_000

    await_reconciled_agent_proof!(watcher, owner, owner_generation, 100)
  end

  defp registered_agent_owner!(agent_id, owner_generation) do
    parent = self()

    owner =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_generation)
        send(parent, {:effect_coordination_agent_registered, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:effect_coordination_agent_registered, ^owner, {:ok, _value}}, 2_000
    owner
  end

  defp await_reconciled_agent_proof!(_watcher, _owner, _owner_generation, 0),
    do: flunk("AgentWatcher did not reconcile the exact old Agent proof")

  defp await_reconciled_agent_proof!(watcher, owner, owner_generation, attempts) do
    state = :sys.get_state(watcher, 30_000)
    incident = AgentTerminations.get_by_lease(owner_generation)

    if not is_map_key(state.pids, owner) and map_size(state.pending_downs) == 0 and
         match?(%{status: "reconciled"}, incident) do
      incident
    else
      :erlang.yield()
      await_reconciled_agent_proof!(watcher, owner, owner_generation, attempts - 1)
    end
  end

  defp block_and_expire_topology!(context) do
    Repo.query!("SET LOCAL ROLE NONE", [])
    Repo.query!("SET LOCAL session_replication_role = replica", [])

    try do
      assert %{num_rows: 1} =
               Repo.query!(
                 """
                 UPDATE public.runtime_node_incarnations
                 SET state = 'draining', ready_at = NULL,
                     draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
                     lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 minute',
                     updated_at = timezone('UTC', clock_timestamp())
                 WHERE id = $1::uuid AND activation_epoch = $2::uuid
                 """,
                 [
                   Ecto.UUID.dump!(context.node.id),
                   Ecto.UUID.dump!(context.node.activation_epoch)
                 ]
               )

      assert %{num_rows: 1} =
               Repo.query!(
                 """
                 UPDATE public.runtime_partitions
                 SET state = 'blocked', ready_at = NULL,
                     draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
                     lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 minute',
                     updated_at = timezone('UTC', clock_timestamp())
                 WHERE partition_id = $1 AND activation_epoch = $2::uuid
                   AND ownership_epoch = $3 AND owner_node_incarnation_id = $4::uuid
                 """,
                 [
                   context.partition.partition_id,
                   Ecto.UUID.dump!(context.node.activation_epoch),
                   context.partition.ownership_epoch,
                   Ecto.UUID.dump!(context.node.id)
                 ]
               )
    after
      Repo.query!("SET LOCAL session_replication_role = origin", [])
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
    end

    assert [["draining", true, "blocked", true]] =
             Repo.query!(
               """
               SELECT node.state,
                      node.lease_expires_at <= timezone('UTC', clock_timestamp()),
                      partition.state,
                      partition.lease_expires_at <= timezone('UTC', clock_timestamp())
               FROM public.runtime_node_incarnations AS node
               JOIN public.runtime_partitions AS partition
                 ON partition.partition_id = $3
                AND partition.activation_epoch = node.activation_epoch
                AND partition.owner_node_incarnation_id = node.id
               WHERE node.id = $1::uuid AND node.activation_epoch = $2::uuid
               """,
               [
                 Ecto.UUID.dump!(context.node.id),
                 Ecto.UUID.dump!(context.node.activation_epoch),
                 context.partition.partition_id
               ]
             ).rows
  end

  defp lock_effect_for_update!(effect_id) do
    Repo.one!(from(effect in Effect, where: effect.id == ^effect_id, lock: "FOR UPDATE"))
  end

  defp earlier_datetime(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp corrupt_pre_provider_reason_suffix!(effect_id) do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [])
    Repo.query!("RESET ROLE", [])

    try do
      Repo.query!(
        "ALTER TABLE public.effects DISABLE TRIGGER enforce_coordinated_effect_trigger",
        []
      )

      Repo.query!(
        "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
        []
      )

      Repo.query!(
        """
        UPDATE public.effects
        SET cancellation_reason = 'effect_preflight_failed:corrupted_suffix'
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(effect_id)]
      )

      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [])
    after
      Repo.query!(
        "ALTER TABLE public.effects ENABLE TRIGGER enforce_coordinated_effect_trigger",
        []
      )

      Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
      Repo.query!("SET CONSTRAINTS ALL DEFERRED", [])
    end
  end

  defp start_runner!(opts \\ []) do
    runner = start_supervised!({EffectRunner, opts})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    runner
  end

  defp configure_provider!(mode) do
    old_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    old_pid = Application.get_env(:maraithon, :effect_coordination_test_pid)
    old_mode = Application.get_env(:maraithon, :effect_coordination_provider_mode)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(old_runtime, :llm_provider, BoundaryProvider)
    )

    Application.put_env(:maraithon, :effect_coordination_test_pid, self())
    Application.put_env(:maraithon, :effect_coordination_provider_mode, mode)

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, old_runtime)
      restore_env(:effect_coordination_test_pid, old_pid)
      restore_env(:effect_coordination_provider_mode, old_mode)
      LLMRateLimiter.reset()
    end)
  end

  defp outcome_evidence(assignment_id) do
    Repo.query!(
      "SELECT outcome FROM runtime_task_outcome_evidence WHERE assignment_id = $1::uuid",
      [Ecto.UUID.dump!(assignment_id)]
    ).rows
  end

  defp outcome_evidence_count(assignment_id), do: length(outcome_evidence(assignment_id))

  defp termination_proof_count(assignment_id) do
    Repo.query!(
      "SELECT count(*) FROM runtime_task_termination_proofs WHERE assignment_id = $1::uuid",
      [Ecto.UUID.dump!(assignment_id)]
    ).rows
    |> then(fn [[count]] -> count end)
  end

  defp termination_proof_kinds(assignment_id) do
    Repo.query!(
      """
      SELECT proof_kind
      FROM runtime_task_termination_proofs
      WHERE assignment_id = $1::uuid
      ORDER BY proof_kind
      """,
      [Ecto.UUID.dump!(assignment_id)]
    ).rows
    |> Enum.map(fn [proof_kind] -> proof_kind end)
  end

  defp after_runner_barrier(runner, fun, attempts \\ 100)
  defp after_runner_barrier(_runner, _fun, 0), do: flunk("condition did not become durable")

  defp after_runner_barrier(runner, fun, attempts) do
    runner_state = :sys.get_state(runner, 30_000)
    # Runner completion and the VM-authenticated child DOWN are independent.
    # Drain Guardian's current callback before observing the coupled durable
    # Effect/assignment state through the shared sandbox connection.
    _ = Maraithon.Effects.Cancellation.reconcile(32)
    _ = :sys.get_state(Maraithon.Runtime.TaskGuardian, 30_000)

    case {map_size(runner_state.running), fun.()} do
      {0, {:ok, value}} ->
        value

      {_still_monitored_or_running, _condition} ->
        after_runner_barrier(runner, fun, attempts - 1)
    end
  end

  defp as_activation_operator(fun) do
    Repo.query!("SET ROLE maraithon_activation_operator", [])

    try do
      fun.()
    after
      Repo.query!("RESET ROLE", [])
    end
  end

  defp coordination_activation_opts do
    [confirmation: Protocol.activation_confirmation()] ++ @activation_evidence
  end

  defp restart_task_system! do
    parent = Maraithon.Runtime.Supervisor
    child = Maraithon.Runtime.TaskSystemSupervisor

    :ok = Supervisor.terminate_child(parent, child)
    {:ok, _pid} = Supervisor.restart_child(parent, child)
    _ = :sys.get_state(EffectTaskAuthority)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)
  defp ok!({:ok, value}), do: value
end
