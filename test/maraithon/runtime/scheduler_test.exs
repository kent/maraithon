defmodule Maraithon.Runtime.SchedulerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Repo
  alias Maraithon.Agents

  setup do
    # Create an agent for testing
    {:ok, agent} = Agents.create_agent(%{
      behavior: "watchdog_summarizer",
      config: %{},
      status: "running",
      started_at: DateTime.utc_now()
    })

    %{agent: agent}
  end

  describe "schedule_at/4" do
    test "schedules a job at a specific time", %{agent: agent} do
      fire_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      {:ok, job_id} = Scheduler.schedule_at(agent.id, "test_job", fire_at, %{foo: "bar"})

      assert is_binary(job_id)

      job = Repo.get(ScheduledJob, job_id)
      assert job.agent_id == agent.id
      assert job.job_type == "test_job"
      assert job.status == "pending"
      assert job.payload == %{"foo" => "bar"}
    end

    test "schedules job with empty payload", %{agent: agent} do
      fire_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      {:ok, job_id} = Scheduler.schedule_at(agent.id, "simple_job", fire_at)

      job = Repo.get(ScheduledJob, job_id)
      assert job.payload == %{}
    end
  end

  describe "schedule_in/4" do
    test "schedules a job after a delay", %{agent: agent} do
      before = DateTime.utc_now()

      {:ok, job_id} = Scheduler.schedule_in(agent.id, "delayed_job", 5_000, %{delay: true})

      _after_time = DateTime.utc_now()

      job = Repo.get(ScheduledJob, job_id)
      assert job.status == "pending"
      assert job.job_type == "delayed_job"

      # fire_at should be approximately 5 seconds in the future
      diff_ms = DateTime.diff(job.fire_at, before, :millisecond)
      assert diff_ms >= 5_000
      assert diff_ms <= 5_100
    end
  end

  describe "cancel/2" do
    test "cancels pending jobs for an agent", %{agent: agent} do
      fire_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      {:ok, job1_id} = Scheduler.schedule_at(agent.id, "cancel_test", fire_at)
      {:ok, job2_id} = Scheduler.schedule_at(agent.id, "cancel_test", fire_at)

      # Cancel jobs of this type
      {count, _} = Scheduler.cancel(agent.id, "cancel_test")
      assert count == 2

      # Verify both are cancelled
      job1 = Repo.get(ScheduledJob, job1_id)
      job2 = Repo.get(ScheduledJob, job2_id)
      assert job1.status == "cancelled"
      assert job2.status == "cancelled"
    end

    test "only cancels pending jobs, not delivered ones", %{agent: agent} do
      fire_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      {:ok, job_id} = Scheduler.schedule_at(agent.id, "partial_cancel", fire_at)

      # Mark job as delivered
      job = Repo.get(ScheduledJob, job_id)
      job
      |> ScheduledJob.changeset(%{status: "delivered"})
      |> Repo.update!()

      # Try to cancel
      {count, _} = Scheduler.cancel(agent.id, "partial_cancel")
      assert count == 0

      # Job should still be delivered
      job = Repo.get(ScheduledJob, job_id)
      assert job.status == "delivered"
    end
  end

  describe "start_link/1" do
    test "starts the scheduler" do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      assert {:ok, pid} = Scheduler.start_link([])
      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info/2" do
    test "handles :poll message" do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Send poll message
      send(pid, :poll)
      Process.sleep(100)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "handles :recover_overdue message" do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Send recover message
      send(pid, :recover_overdue)
      Process.sleep(100)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "handles {:fire, job_id} message", %{agent: agent} do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Create a pending job
      fire_at = DateTime.utc_now()
      {:ok, job_id} = Scheduler.schedule_at(agent.id, "fire_test", fire_at)

      # Fire the job
      send(pid, {:fire, job_id})
      Process.sleep(100)

      # Job should be delivered
      job = Repo.get(ScheduledJob, job_id)
      assert job.status == "delivered"

      GenServer.stop(pid, :normal)
    end

    test "handles {:fire, job_id} for non-existent job" do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Fire a non-existent job
      send(pid, {:fire, Ecto.UUID.generate()})
      Process.sleep(100)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_call/3" do
    test "handles :clear_in_flight call" do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])

      # Call clear_in_flight
      :ok = GenServer.call(pid, :clear_in_flight)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info - job already delivered" do
    test "handles {:fire, job_id} for already delivered job", %{agent: agent} do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Create and mark as delivered
      fire_at = DateTime.utc_now()
      {:ok, job_id} = Scheduler.schedule_at(agent.id, "already_delivered", fire_at)

      # Mark as delivered manually
      job = Repo.get(ScheduledJob, job_id)
      job
      |> ScheduledJob.changeset(%{status: "delivered", delivered_at: DateTime.utc_now()})
      |> Repo.update!()

      # Try to fire already delivered job
      send(pid, {:fire, job_id})
      Process.sleep(100)

      # Should handle gracefully and still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "job delivery to non-running agent" do
    test "logs warning when agent is not running", %{agent: agent} do
      # Stop existing scheduler if running
      case Process.whereis(Scheduler) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = Scheduler.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Create job for agent that exists but isn't running (no RuntimeAgent started for it)
      # The agent from setup has an entry in agents table but isn't registered in AgentRegistry
      fire_at = DateTime.utc_now()
      {:ok, job_id} = Scheduler.schedule_at(agent.id, "orphan_job", fire_at)

      # Fire the job - agent won't be found in AgentRegistry
      send(pid, {:fire, job_id})
      Process.sleep(100)

      # Job should still be marked as delivered
      job = Repo.get(ScheduledJob, job_id)
      assert job.status == "delivered"

      GenServer.stop(pid, :normal)
    end
  end
end
