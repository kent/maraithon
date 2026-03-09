defmodule Maraithon.AdminTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Admin
  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Events
  alias Maraithon.Runtime.ScheduledJob

  describe "dashboard_snapshot/1" do
    test "returns health, queue metrics, activity, and failures" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _event} = Events.append(agent.id, "issue_opened", %{title: "Investigate regression"})

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
end
