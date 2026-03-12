defmodule Maraithon.AdminTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Admin
  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Events
  alias Maraithon.Runtime.ScheduledJob

  describe "dashboard_snapshot/1" do
    test "returns health, queue metrics, activity, and failures" do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _event} = Events.append(agent.id, "issue_opened", %{title: "Investigate regression"})

      Maraithon.LogBuffer.record(%{
        level: :info,
        message: "runtime initialized",
        metadata: %{agent_id: agent.id}
      })

      _ = :sys.get_state(Maraithon.LogBuffer)

      {:ok, _failed_effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "failed",
          attempts: 2,
          error: "Tool timeout"
        })
        |> Repo.insert()

      stale_claimed_at = DateTime.add(DateTime.utc_now(), -600, :second)

      {:ok, _stale_job} =
        %ScheduledJob{}
        |> ScheduledJob.changeset(%{
          agent_id: agent.id,
          job_type: "wakeup",
          fire_at: DateTime.utc_now(),
          status: "dispatched",
          claimed_at: stale_claimed_at,
          attempts: 3
        })
        |> Repo.insert()

      snapshot = Admin.dashboard_snapshot(activity_limit: 10, failure_limit: 10)

      assert snapshot.health.status in [:healthy, :unhealthy]
      assert snapshot.queue_metrics.effects.failed == 1
      assert snapshot.queue_metrics.jobs.dispatched == 1
      assert Enum.any?(snapshot.recent_activity, &(&1.event_type == "issue_opened"))
      assert Enum.any?(snapshot.recent_failures, &(&1.source == "effect"))
      assert Enum.any?(snapshot.recent_failures, &(&1.source == "job"))
      assert Enum.any?(snapshot.recent_logs, &(&1.message == "runtime initialized"))
    end
  end

  describe "safe_control_center_snapshot/1" do
    test "returns a degraded snapshot when database-backed queries fail" do
      health = %{
        status: :unhealthy,
        checks: %{database: :error, agents: %{running: 0, degraded: 0, stopped: 0}},
        version: "test"
      }

      assert {:degraded, snapshot} =
               Admin.safe_control_center_snapshot(
                 health: health,
                 db_fetcher: fn ->
                   raise DBConnection.ConnectionError, message: "queue timeout"
                 end
               )

      assert snapshot.degraded
      assert snapshot.health == health
      assert is_list(snapshot.recent_logs)
      assert snapshot.errors != []
      assert hd(snapshot.errors).scope == "control_center"
    end
  end

  describe "recent_failures/1" do
    test "returns most recent failures first" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      old_failure_time = DateTime.add(DateTime.utc_now(), -120, :second)
      new_failure_time = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, old_effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "failed",
          attempts: 1,
          error: "Old failure",
          updated_at: old_failure_time
        })
        |> Repo.insert()

      {:ok, new_effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "failed",
          attempts: 1,
          error: "New failure",
          updated_at: new_failure_time
        })
        |> Repo.insert()

      failures = Admin.recent_failures(2)

      assert length(failures) == 2
      assert hd(failures).id == new_effect.id
      assert Enum.at(failures, 1).id == old_effect.id
    end
  end

  describe "agent_inspection/2" do
    test "returns agent-specific queue, event, and log details" do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped"
        })

      {:ok, _event} = Events.append(agent.id, "inspection_event", %{ok: true})

      {:ok, _effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "pending",
          attempts: 0
        })
        |> Repo.insert()

      {:ok, _job} =
        %ScheduledJob{}
        |> ScheduledJob.changeset(%{
          agent_id: agent.id,
          job_type: "heartbeat",
          fire_at: DateTime.utc_now(),
          status: "pending",
          attempts: 1
        })
        |> Repo.insert()

      Maraithon.LogBuffer.record(%{
        level: :info,
        message: "agent inspection ready",
        metadata: %{agent_id: agent.id}
      })

      _ = :sys.get_state(Maraithon.LogBuffer)

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      inspection = Admin.agent_inspection(agent.id, effect_limit: 5, job_limit: 5, log_limit: 5)

      assert inspection.event_count == 1
      assert inspection.effect_counts.pending == 1
      assert inspection.job_counts.pending == 1
      assert Enum.any?(inspection.recent_effects, &(&1.effect_type == "tool_call"))
      assert Enum.any?(inspection.recent_jobs, &(&1.job_type == "heartbeat"))
      assert Enum.any?(inspection.recent_logs, &(&1.message == "agent inspection ready"))
    end
  end

  describe "safe_agent_snapshot/2" do
    test "returns a degraded inspection snapshot with in-app logs preserved" do
      Maraithon.LogBuffer.clear()

      Maraithon.LogBuffer.record(%{
        level: :error,
        message: "agent query failed",
        metadata: %{"agent_id" => "agent-123"}
      })

      _ = :sys.get_state(Maraithon.LogBuffer)

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      health = %{
        status: :unhealthy,
        checks: %{database: :error, agents: %{running: 0, degraded: 0, stopped: 0}},
        version: "test"
      }

      assert {:degraded, snapshot} =
               Admin.safe_agent_snapshot("agent-123",
                 health: health,
                 fetcher: fn -> raise DBConnection.ConnectionError, message: "queue timeout" end
               )

      assert snapshot.degraded
      assert snapshot.agent == nil
      assert snapshot.events == []
      assert snapshot.errors != []
      assert Enum.any?(snapshot.inspection.recent_logs, &(&1.message == "agent query failed"))
    end
  end
end
