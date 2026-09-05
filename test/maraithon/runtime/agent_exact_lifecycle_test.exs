defmodule Maraithon.Runtime.AgentExactLifecycleTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.EffectTaskSupervisor
  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.Runtime.Coordination.{Authority, Partition, Partitioning, TaskClaims}
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @activation_evidence [
    evidence_id: "test:stopped-fleet:agent-exact-lifecycle",
    evidence_digest: :crypto.hash(:sha256, "test stopped fleet evidence"),
    activated_by: "agent-exact-lifecycle@example.test",
    revision: String.duplicate("a", 40)
  ]

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      original_runtime
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.delete(:coordination_test_session)
      |> Keyword.delete(:coordination_test_leader)
    )

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, original_runtime) end)

    assert ProtocolCutover.mode() == :legacy

    assert {:ok, :attested} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    assert {:ok, :activated} = activate_exact()
    :ok
  end

  test "preclaims a ready exact lease and exposes only local token metadata" do
    agent = running_agent("exact-launch")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} = start_exact(agent, supervisor, watcher)
    wait_for_state(pid, :idle)

    assert [{^pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
    assert {:ok, ^owner_token} = Ecto.UUID.cast(owner_token)

    with_agent_suspended(pid, fn ->
      lease = AgentLeases.get(agent.id)
      assert lease.owner_token == owner_token
      assert lease.ready_at != nil
      assert lease.draining_at == nil
      assert Agents.get_agent(agent.id).status == "running"
      assert :global.whereis_name({:maraithon_agent, agent.id}) == :undefined

      assert RuntimeAgent.child_spec(%{agent: agent, owner_token: owner_token}).restart ==
               :temporary
    end)

    terminate_exact(watcher, pid)
  end

  test "exact Agents reject raw mailbox workload paths" do
    agent = running_agent("exact-raw-workload-fence")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} = start_exact(agent, supervisor, watcher)
    wait_for_state(pid, :idle)

    send(pid, {:agent_dispatch, {:message, "raw", %{}, Ecto.UUID.generate()}})
    send(pid, {:agent_dispatch, {:pubsub_event, "raw:topic", %{"value" => 1}}})
    send(pid, {:agent_dispatch, {:wakeup, "wakeup", Ecto.UUID.generate(), %{}}})

    assert {:idle, _data} = :sys.get_state(pid, 30_000)

    with_agent_suspended(pid, fn ->
      refute Enum.any?(Events.list_events(agent.id), fn event ->
               event.event_type in [
                 "message_received",
                 "pubsub_event_received",
                 "wakeup_received"
               ]
             end)

      assert Repo.aggregate(AgentDirective, :count, :id) == 0
    end)

    terminate_exact(watcher, pid)
  end

  test "renews the same owner token in every resident state" do
    agent = running_agent("exact-renewal")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 50)

    wait_for_state(pid, :idle)

    expected_token = registry_token(agent.id)
    probe_id = attach_lease_renewal_probe(pid)
    on_exit(fn -> :telemetry.detach(probe_id) end)

    Enum.each([:idle, :working, :waiting_effect, :recovering], fn state ->
      :sys.replace_state(pid, fn {_old_state, data} -> {state, data} end)
      previous = with_agent_suspended(pid, fn -> AgentLeases.get(agent.id).renewed_at end)
      flush_lease_renewals(pid)

      assert_receive {:lease_renewed, ^pid}, 5_000

      with_agent_suspended(pid, fn ->
        assert %{renewed_at: renewed_at, owner_token: ^expected_token} =
                 AgentLeases.get(agent.id)

        assert DateTime.compare(renewed_at, previous) == :gt
      end)
    end)

    :sys.replace_state(pid, fn {_old_state, data} -> {:idle, data} end)
    terminate_exact(watcher, pid)
  end

  test "guards a live-lease DOWN before admitting a fresh recovery generation" do
    agent = running_agent("exact-recovery")
    {supervisor, watcher} = exact_runtime(recover?: false, reresume_backoffs: [0])

    {:ok, first_pid} = start_exact(agent, supervisor, watcher)
    wait_for_state(first_pid, :idle)
    first_token = registry_token(agent.id)

    :ok = :sys.suspend(first_pid)
    ref = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}, 1_000
    await_watcher_release(watcher, first_pid, 100)

    guard =
      assert_eventually_value(fn ->
        case AgentRestartGuards.get(agent.id) do
          %{last_owner_token: ^first_token, needs_recovery: true} = guard -> guard
          _other -> nil
        end
      end)

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "running"

    {:ok, recovered_pid} =
      start_exact(agent, supervisor, watcher, recovery_generation: guard.generation)

    wait_for_state(recovered_pid, :idle)
    recovered_token = registry_token(agent.id)
    refute recovered_token == first_token

    lease =
      with_agent_suspended(recovered_pid, fn ->
        recovered_guard = AgentRestartGuards.get(agent.id)
        assert recovered_guard.generation == guard.generation
        refute recovered_guard.needs_recovery

        lease = AgentLeases.get(agent.id)
        assert lease.owner_token == recovered_token
        assert lease.ready_at != nil
        lease
      end)

    recovered_ref = Process.monitor(recovered_pid)
    send(recovered_pid, {:agent_dispatch, {:control, :stop, "delayed_old", first_token}})
    send(recovered_pid, {:agent_dispatch, {:control, :stop, "legacy_unqualified"}})
    refute_receive {:DOWN, ^recovered_ref, :process, ^recovered_pid, _reason}, 100
    assert Process.alive?(recovered_pid)
    assert registry_token(agent.id) == recovered_token

    started = agent.id |> Events.list_events(limit: 20) |> List.last()
    assert started.event_type == "agent_started"
    assert DateTime.compare(started.created_at, lease.ready_at) in [:eq, :gt]

    send(
      recovered_pid,
      {:agent_dispatch, {:control, :stop, "test_cleanup", recovered_token}}
    )

    assert_receive {:DOWN, ^recovered_ref, :process, ^recovered_pid, :normal}, 15_000
    await_watcher_release(watcher, recovered_pid, 100)
    assert AgentLeases.get(agent.id) == nil
  end

  test "an unproven crash report cannot stale a live incarnation or mutate durable work" do
    agent = running_agent("unproven-crash")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 5_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)

    {:ok, effect_id} =
      with_agent_suspended(pid, fn ->
        Effects.request(agent.id, :tool_call, "time", %{}, runtime_owner_generation: owner_token)
      end)

    assert {:ignored, :termination_proof_required} =
             AgentRestartGuards.record_crash(agent.id, owner_token, :unproven_report,
               backoffs_ms: [0]
             )

    with_agent_suspended(pid, fn ->
      assert AgentLeases.get(agent.id).owner_token == owner_token
      assert AgentRestartGuards.get(agent.id) == nil
      assert Repo.get!(Effect, effect_id).status == "pending"
    end)
  end

  test "Runtime stop fences the local token before exact cleanup and release" do
    agent = running_agent("local-runtime-stop")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 5_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)

    {:ok, effect_id} =
      with_agent_suspended(pid, fn ->
        Effects.request(agent.id, :tool_call, "time", %{}, runtime_owner_generation: owner_token)
      end)

    ref = Process.monitor(pid)

    assert {:ok, %{drain_status: :reconciliation_pending, stopped_at: %DateTime{}}} =
             Runtime.stop_agent(agent.id, "local_exact_stop")

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    await_watcher_release(watcher, pid, 100)
    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
    assert Repo.get!(Effect, effect_id).status == "cancelled"
  end

  test "lease-free local PID remains pending without an unqualified bridge stop" do
    agent = running_agent("legacy-bridge-pending")
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _registered} = Registry.register(AgentRegistry, agent.id, :legacy_unfenced)
        send(parent, {:legacy_registered, self()})

        receive do
          message -> send(parent, {:legacy_received, message})
        end
      end)

    assert_receive {:legacy_registered, ^pid}, 1_000

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "legacy_pending")

    refute_receive {:legacy_received, _message}, 100
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
  end

  test "an unreachable remote owner is fenced without broad work cancellation" do
    agent = running_agent("remote-runtime-stop")
    lease = ready_manual_lease(agent, "remote-owner@runtime-stop")

    {:ok, effect_id} =
      Effects.request(agent.id, :tool_call, "time", %{},
        runtime_owner_generation: lease.owner_token
      )

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "remote_exact_stop")

    stopped_agent = Agents.get_agent(agent.id)
    fenced_lease = AgentLeases.get(agent.id)

    assert stopped_agent.status == "stopped"
    assert fenced_lease.owner_token == lease.owner_token
    assert fenced_lease.owner_node == "remote-owner@runtime-stop"
    assert fenced_lease.ready_at == nil
    assert fenced_lease.draining_at != nil
    assert Repo.get!(Effect, effect_id).status == "pending"
  end

  test "a concurrent start cannot flip stopped intent while a drain token exists" do
    agent = running_agent("drain-start-race")
    lease = ready_manual_lease(agent, "remote-owner@start-race")

    assert {:ok, %{lease_state: :live}} = AgentLeases.fence_for_stop(agent.id)
    assert Agents.get_agent(agent.id).status == "stopped"

    assert {:error, :agent_drain_pending} = Runtime.start_existing_agent(agent.id)
    assert Agents.get_agent(agent.id).status == "stopped"
    assert AgentLeases.get(agent.id).owner_token == lease.owner_token
  end

  test "an already-draining exact owner can settle after desired status changes again" do
    agent = running_agent("drain-status-flip")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 5_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)

    {:ok, effect_id} =
      with_agent_suspended(pid, fn ->
        Effects.request(agent.id, :tool_call, "time", %{}, runtime_owner_generation: owner_token)
      end)

    assert {:ok, %{agent: stopped_agent, lease_state: :live}} =
             AgentLeases.fence_for_stop(agent.id)

    assert {:ok, _terminated_agent} = Agents.update_agent(stopped_agent, %{status: "terminated"})

    ref = Process.monitor(pid)
    send(pid, {:agent_dispatch, {:control, :stop, "status_changed", owner_token}})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    await_watcher_release(watcher, pid, 100)

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "terminated"
    assert Repo.get!(Effect, effect_id).status == "cancelled"
  end

  test "a delayed exact DOWN finalizes the stop and cancels unentered work" do
    agent = running_agent("delayed-down")
    {_supervisor, watcher} = exact_runtime(recover?: false)
    lease = ready_manual_lease(agent, Atom.to_string(node()), watcher)

    {:ok, effect_id} =
      Effects.request(agent.id, :tool_call, "time", %{},
        runtime_owner_generation: lease.owner_token
      )

    dummy = registered_owner(agent.id, lease.owner_token)
    assert :ok = AgentWatcher.track(watcher, dummy, agent.id, lease.owner_token)

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "remote_delayed_down")

    assert Repo.get!(Effect, effect_id).status == "pending"
    assert AgentLeases.get(agent.id).draining_at != nil

    ref = Process.monitor(dummy)
    Process.exit(dummy, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dummy, :killed}, 1_000

    await_watcher_release(watcher, dummy, 100)

    assert AgentRestartGuards.get(agent.id) == nil

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
    assert Repo.get!(Effect, effect_id).status == "cancelled"
  end

  test "an expired stop records exact loss and never resurrects drain authority" do
    agent = running_agent("expired-runtime-stop")
    lease = ready_manual_lease(agent, Atom.to_string(node()))

    {:ok, effect_id} =
      Effects.request(agent.id, :tool_call, "time", %{},
        runtime_owner_generation: lease.owner_token
      )

    expired_until = DateTime.add(lease.ready_at, 1, :microsecond)

    lease
    |> Ecto.Changeset.change(%{lease_until: expired_until})
    |> Repo.update!()

    assert {:error, :agent_stop_reconciliation_pending} =
             Runtime.stop_agent(agent.id, "expired_exact_stop")

    current_agent = Agents.get_agent(agent.id)
    fenced_lease = AgentLeases.get(agent.id)

    assert current_agent.status == "running"
    assert fenced_lease.owner_token == lease.owner_token
    assert fenced_lease.lease_until == expired_until
    assert AgentRestartGuards.get(agent.id) == nil
    assert Repo.get!(Effect, effect_id).status == "pending"

    assert %{status: "requested", lease_token: owner_token} =
             AgentTerminations.get_by_lease(lease.owner_token)

    assert owner_token == lease.owner_token
  end

  test "message Directive binds its run and admits its Effect under one exact claim" do
    agent = running_agent("directive-message")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 30_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)
    message_id = "directive-message-1"

    {near_expiry, send_result} =
      with_agent_suspended(pid, fn ->
        lease = AgentLeases.get(agent.id)
        near_expiry = DateTime.add(DatabaseClock.now!(), 5, :second)

        lease
        |> Ecto.Changeset.change(lease_until: near_expiry)
        |> Repo.update!()

        result =
          Runtime.send_message(agent.id, "hello exact runtime", %{
            "message_id" => message_id
          })

        {near_expiry, result}
      end)

    assert {:ok, %{directive_id: directive_id, message_id: ^message_id}} = send_result

    waiting_data =
      assert_eventually_value(fn ->
        case :sys.get_state(pid, 30_000) do
          {:waiting_effect, data} -> data
          _other -> nil
        end
      end)

    {effect_id, runner} =
      with_agent_suspended(pid, fn ->
        directive = Repo.get!(AgentDirective, directive_id)
        [{effect_id, effect_info}] = Map.to_list(waiting_data.pending_effects)
        effect = Repo.get!(Effect, effect_id)
        renewed_lease = AgentLeases.get(agent.id)

        assert directive.status == "processing"
        assert directive.claimed_by_generation == owner_token
        assert directive.claim_token == waiting_data.current_directive_claim_token
        assert directive.active_run_id == waiting_data.current_run_id
        assert directive.effect_count == 1
        assert directive.effect_admitted_at != nil
        assert effect.agent_run_id == directive.active_run_id
        assert effect.agent_run_step_id == effect_info.run_step_id
        assert DateTime.compare(renewed_lease.lease_until, near_expiry) == :gt

        requested_event =
          agent.id
          |> Events.list_events(limit: 50)
          |> Enum.find(&(&1.event_type == "effect_requested"))

        assert requested_event != nil

        test_pid = self()

        task_starter = fn claimed_effect, _completion_writer, _completion_sleeper ->
          runner = self()

          Task.Supervisor.async_nolink(
            Maraithon.Runtime.ExactEffectTaskSupervisor,
            fn ->
              identity = %{
                effect_id: claimed_effect.id,
                agent_id: claimed_effect.agent_id,
                claim_token: claimed_effect.claim_token,
                assignment_id: claimed_effect.coordination_task_assignment_id,
                supervisor_id: claimed_effect.claim_supervisor_id,
                task_id: claimed_effect.claim_task_id
              }

              receive do
                {:effect_task_bound, effect_id} when effect_id == claimed_effect.id -> :ok
              end

              :ok = EffectTaskSupervisor.register_current!(identity)
              send(test_pid, {:effect_claimed, claimed_effect, self()})

              receive do
                {:finish_test_effect, effect_id} when effect_id == claimed_effect.id ->
                  send(
                    runner,
                    {:effect_done, claimed_effect.id, claimed_effect.claim_token,
                     claimed_effect.claimed_by, claimed_effect.claimed_at, :test_completed}
                  )
              after
                30_000 -> exit(:test_effect_release_timeout)
              end
            end,
            shutdown: :brutal_kill
          )
        end

        runner = start_supervised!({EffectRunner, task_starter: task_starter})
        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
        send(runner, :poll)

        assert_receive {:effect_claimed, claimed_effect, effect_task}, 30_000
        assert claimed_effect.id == effect_id
        assert :ok = :sys.suspend(runner)
        assignment = TaskClaims.get(claimed_effect.coordination_task_assignment_id)

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   assert {:active, claimed_effect.coordination_activation_epoch} ==
                            CoordinationProtocol.lock_effect_pair!()

                   active =
                     TaskClaims.activate_effect_in_transaction!(
                       assignment,
                       claimed_effect.agent_id,
                       claimed_effect.runtime_owner_generation
                     )

                   entered =
                     TaskClaims.enter_effect_provider_in_transaction!(
                       active,
                       claimed_effect.agent_id,
                       claimed_effect.runtime_owner_generation
                     )

                   assert entered.state == "running"
                   assert entered.provider_boundary == "entered"

                   assert {1, nil} =
                            Repo.update_all(
                              from(stored in Effect,
                                where: stored.id == ^claimed_effect.id,
                                where: stored.status == "claimed",
                                where: stored.claim_token == ^claimed_effect.claim_token
                              ),
                              set: [
                                status: "executing",
                                updated_at: Maraithon.Runtime.DatabaseClock.now!()
                              ]
                            )

                   :ok
                 end)

        assert :ok =
                 EffectRunner.persist_completed_once(claimed_effect, %{
                   "content" => "RESPOND: durable terminal"
                 })

        send(
          pid,
          {:agent_dispatch,
           {:effect_result, effect_id, {:ok, %{content: "forged mailbox value"}}}}
        )

        send(effect_task, {:finish_test_effect, effect_id})
        {effect_id, runner}
      end)

    wait_for_state(pid, :idle)

    with_agent_suspended(pid, fn ->
      completed = Repo.get!(AgentDirective, directive_id)
      assert completed.status == "completed"

      run = Repo.get!(Maraithon.Agents.AgentRun, completed.active_run_id)
      acknowledged_effect = Repo.get!(Effect, effect_id)
      snapshot = Snapshot.latest(agent.id)

      assert run.status == "completed"
      assert acknowledged_effect.result_acknowledged_at != nil
      assert snapshot != nil

      response_event =
        agent.id
        |> Events.list_events(limit: 50)
        |> Enum.find(&(&1.event_type == "agent_response"))

      assert response_event.payload["response"] == "durable terminal"
      assert snapshot.sequence_num == response_event.sequence_num
    end)

    assert :ok = AgentSupervisor.stop_agent(pid, "test_cleanup", owner_token)
    assert Repo.get!(AgentDirective, directive_id).status == "completed"
    assert :ok = :sys.resume(runner)
    assert :ok = stop_supervised(EffectRunner)
  end

  test "durable scheduled checkpoint settles Event Snapshot and Directive atomically" do
    agent = running_agent("directive-checkpoint")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 5_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)

    {:ok, job_id} =
      with_agent_suspended(pid, fn ->
        Scheduler.schedule_at(
          agent.id,
          "checkpoint",
          DateTime.add(DateTime.utc_now(), -1, :second),
          %{"source" => "focused_test"}
        )
      end)

    {:idle, initial_data} = :sys.get_state(pid, 30_000)
    assert :ok = :sys.suspend(pid)
    scheduler = start_supervised!({Scheduler, []})

    try do
      send(scheduler, {:fire, job_id})
      _ = :sys.get_state(scheduler, 30_000)
      _ = :sys.get_state(scheduler, 30_000)
      assert :ok = :sys.suspend(scheduler)
    after
      :ok = :sys.resume(pid)
    end

    checkpoint_data =
      assert_eventually_value(fn ->
        case :sys.get_state(pid, 30_000) do
          {:idle, data} when data.sequence_num > initial_data.sequence_num -> data
          _other -> nil
        end
      end)

    assert checkpoint_data.sequence_num > initial_data.sequence_num

    try do
      with_agent_suspended(pid, fn ->
        directive = Repo.get_by!(AgentDirective, dedupe_key: "scheduled_job:#{job_id}")
        job = Repo.get!(ScheduledJob, job_id)
        snapshot = Snapshot.latest(agent.id)

        assert directive.status == "completed"
        assert job.status == "delivered"
        assert directive.terminal_by_generation == owner_token
        assert is_binary(directive.terminal_claim_token)
        assert snapshot != nil

        checkpoint_event =
          agent.id
          |> Events.list_events(limit: 50)
          |> Enum.find(&(&1.event_type == "checkpoint_created"))

        assert checkpoint_event != nil
        assert snapshot.sequence_num == checkpoint_event.sequence_num
        assert Repo.get!(Maraithon.Agents.Agent, agent.id).active_run_id == nil
      end)

      assert :ok = AgentSupervisor.stop_agent(pid, "test_cleanup", owner_token)
    after
      :ok = :sys.resume(scheduler)
    end

    assert :ok = stop_supervised(Scheduler)
  end

  test "an exact scheduler cancels overdue timers after an agent becomes non-runnable" do
    agent = running_agent("scheduled-ineligible")

    {:ok, job_id} =
      Scheduler.schedule_at(
        agent.id,
        "checkpoint",
        DateTime.add(DateTime.utc_now(), -1, :second),
        %{"source" => "focused_test"}
      )

    agent
    |> Ecto.Changeset.change(%{
      status: "stopped",
      stopped_at: DatabaseClock.now!(),
      updated_at: DatabaseClock.now!()
    })
    |> Repo.update!()

    scheduler = start_supervised!({Scheduler, []})
    send(scheduler, {:fire, job_id})
    _ = :sys.get_state(scheduler, 30_000)

    assert Repo.get!(ScheduledJob, job_id).status == "cancelled"
    refute Repo.get_by(AgentDirective, dedupe_key: "scheduled_job:#{job_id}")
  end

  test "checkpoint Event and Snapshot are atomic against an exact monitored loss" do
    agent = running_agent("checkpoint-loss")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 60_000, renew_interval_ms: 5_000)

    wait_for_state(pid, :idle)

    assert with_agent_suspended(pid, fn -> Snapshot.latest(agent.id) end) == nil

    ref = Process.monitor(pid)
    send(pid, {:wakeup, "checkpoint", Ecto.UUID.generate(), %{}})
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    await_watcher_release(watcher, pid, 100)

    checkpoint_events =
      agent.id
      |> Events.list_events(limit: 20)
      |> Enum.filter(&(&1.event_type == "checkpoint_created"))

    case {checkpoint_events, Snapshot.latest(agent.id)} do
      {[], nil} ->
        :ok

      {[checkpoint_event], snapshot} when is_map(snapshot) ->
        assert snapshot.sequence_num == checkpoint_event.sequence_num

      inconsistent ->
        flunk("checkpoint Event/Snapshot were not atomic: #{inspect(inconsistent)}")
    end
  end

  test "does not claim when the mandatory watcher is unavailable" do
    agent = running_agent("watcher-preclaim")
    supervisor = exact_supervisor()
    missing_watcher = :"missing_watcher_#{System.unique_integer([:positive])}"

    assert {:error, :watcher_unavailable} =
             AgentSupervisor.start_agent(agent,
               admission: :bootstrap,
               supervisor: supervisor,
               watcher: missing_watcher,
               ttl_ms: 2_000,
               renew_interval_ms: 50
             )

    assert AgentLeases.get(agent.id) == nil
    assert AgentRestartGuards.get(agent.id) == nil
  end

  test "does not claim when the supervisor is absent at preflight" do
    agent = running_agent("definite-spawn-failure")
    {_supervisor, watcher} = exact_runtime(recover?: false)
    missing_supervisor = :"missing_supervisor_#{System.unique_integer([:positive])}"

    assert {:error, :agent_supervisor_unavailable} =
             AgentSupervisor.start_agent(agent,
               admission: :bootstrap,
               supervisor: missing_supervisor,
               watcher: watcher,
               ttl_ms: 2_000,
               renew_interval_ms: 50
             )

    assert AgentLeases.get(agent.id) == nil
    assert AgentRestartGuards.get(agent.id) == nil
  end

  defp running_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{
          "name" => name,
          "prompt" => "test",
          "subscribe" => [],
          "tools" => []
        }
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    :ok = ensure_user_partition!(agent.user_id)
    agent
  end

  defp ready_manual_lease(agent, owner_node, watcher \\ nil) do
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)
    session = Keyword.fetch!(runtime, :coordination_test_session)
    partition_id = agent.user_id |> Partitioning.tenant_key() |> Partitioning.partition_for()
    partition = Repo.get!(Partition, partition_id)
    owner_token = Ecto.UUID.generate()

    termination_capability_digest =
      if watcher do
        {:ok, digest} =
          AgentWatcher.prepare_lease_capability(watcher, agent.id, owner_token)

        digest
      else
        :crypto.hash(:sha256, :crypto.strong_rand_bytes(32))
      end

    now = DatabaseClock.now!()

    try do
      %AgentRuntimeLease{}
      |> AgentRuntimeLease.changeset(%{
        agent_id: agent.id,
        owner_token: owner_token,
        owner_node: owner_node,
        termination_capability_digest: termination_capability_digest,
        claimed_at: now,
        renewed_at: now,
        lease_until: DateTime.add(now, 60, :second),
        ready_at: nil,
        draining_at: nil,
        coordination_activation_epoch: session.activation_epoch,
        coordination_partition_id: partition.partition_id,
        coordination_partition_epoch: partition.ownership_epoch,
        coordination_node_incarnation_id: session.id
      })
      |> Repo.insert!()

      {:ok, ready} = AgentLeases.mark_ready(agent.id, owner_token)
      ready
    rescue
      error ->
        if watcher,
          do: AgentWatcher.discard_lease_capability(watcher, agent.id, owner_token)

        reraise error, __STACKTRACE__
    end
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
          node_name: "agent-exact-lifecycle@test",
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

  defp registered_owner(agent_id, owner_token) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_token)
        send(parent, {:owner_registered, self(), result})
        receive do: (:terminate -> :ok)
      end)

    assert_receive {:owner_registered, ^pid, {:ok, _owner}}, 1_000
    pid
  end

  defp exact_runtime(opts) do
    supervisor = exact_supervisor()
    suffix = System.unique_integer([:positive])
    watcher_name = :"exact_watcher_#{suffix}"

    watcher =
      start_supervised!(
        {AgentWatcher,
         [
           name: watcher_name,
           agent_supervisor: supervisor,
           reconcile?: false,
           recover?: Keyword.get(opts, :recover?, true),
           reresume_backoffs: Keyword.get(opts, :reresume_backoffs, [0]),
           crash_loop_max: 3,
           crash_loop_window_ms: 60_000
         ]},
        id: watcher_name
      )

    {supervisor, watcher}
  end

  defp exact_supervisor do
    suffix = System.unique_integer([:positive])
    name = :"exact_supervisor_#{suffix}"

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: name, max_restarts: 20, max_seconds: 60},
      id: name
    )
  end

  defp start_exact(agent, supervisor, watcher, opts \\ []) do
    AgentSupervisor.start_agent(
      agent,
      Keyword.merge(
        [
          admission: :bootstrap,
          supervisor: supervisor,
          watcher: watcher,
          ttl_ms: 60_000,
          renew_interval_ms: 5_000
        ],
        opts
      )
    )
  end

  defp registry_token(agent_id) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{_pid, owner_token}] -> owner_token
      _other -> nil
    end
  end

  defp attach_lease_renewal_probe(pid) do
    handler_id = {__MODULE__, :lease_renewal, System.unique_integer([:positive])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:maraithon, :repo, :query],
        fn _event, _measurements, metadata, {receiver, agent_pid} ->
          query = Map.get(metadata, :query, "")

          if self() == agent_pid and is_binary(query) and
               String.starts_with?(query, ~s(UPDATE "agent_runtime_leases")) do
            send(receiver, {:lease_renewed, agent_pid})
          end
        end,
        {test_pid, pid}
      )

    handler_id
  end

  defp flush_lease_renewals(pid) do
    receive do
      {:lease_renewed, ^pid} -> flush_lease_renewals(pid)
    after
      0 -> :ok
    end
  end

  defp with_agent_suspended(pid, fun) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      :ok = :sys.resume(pid)
    end
  end

  defp terminate_exact(watcher, pid) do
    :ok = :sys.suspend(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    await_watcher_release(watcher, pid, 100)
  end

  defp await_watcher_release(_watcher, _pid, 0),
    do: flunk("AgentWatcher did not reconcile the exact DOWN")

  defp await_watcher_release(watcher, pid, attempts) do
    case :sys.get_state(watcher) do
      %{pids: pids, pending_downs: pending} when not is_map_key(pids, pid) ->
        if map_size(pending) == 0,
          do: :ok,
          else: await_watcher_release(watcher, pid, attempts - 1)

      _state ->
        await_watcher_release(watcher, pid, attempts - 1)
    end
  end

  defp wait_for_state(pid, expected), do: wait_for_state(pid, expected, 100)

  defp wait_for_state(_pid, expected, 0), do: flunk("Agent did not enter #{expected}")

  defp wait_for_state(pid, expected, attempts) do
    try do
      case :sys.get_state(pid, 30_000) do
        {^expected, _data} -> :ok
        _other -> retry(fn -> wait_for_state(pid, expected, attempts - 1) end)
      end
    catch
      :exit, _reason -> retry(fn -> wait_for_state(pid, expected, attempts - 1) end)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.(), do: :ok, else: retry(fn -> assert_eventually(fun, attempts - 1) end)
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> retry(fn -> assert_eventually_value(fun, attempts - 1) end)
      false -> retry(fn -> assert_eventually_value(fun, attempts - 1) end)
      value -> value
    end
  end

  defp assert_eventually_value(_fun, 0), do: flunk("value was not available before timeout")

  defp retry(fun), do: fun.()
end
