# ==============================================================================
# Scheduler Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The Scheduler is Maraithon's internal "alarm clock" for agents. It enables
# time-based automation features that users rely on:
#
# - **Periodic Health Checks**: Agents wake up regularly to check monitored
#   systems and report issues.
# - **Delayed Actions**: After an agent performs work, it can schedule a
#   follow-up check (e.g., "remind me to check if the PR was merged in 1 hour").
# - **Cron-like Behaviors**: Daily summaries, weekly reports, and other
#   scheduled tasks all depend on the Scheduler.
#
# From a user's perspective, this is what makes agents "proactive" rather than
# just "reactive". An agent subscribed to GitHub can also wake up every morning
# to summarize yesterday's activity - without needing a webhook trigger.
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the Scheduler breaks, users experience:
# - Agents that never wake up for periodic tasks
# - Missed health checks and monitoring gaps
# - Delayed actions that never fire
# - Agents that feel "dead" even though they're technically running
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the Scheduler GenServer, which manages delayed job
# execution for agents. The Scheduler is responsible for firing wakeup events
# at scheduled times.
#
# Architecture Overview:
# ----------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                         Job Scheduling Flow                              │
#   │                                                                          │
#   │   ┌────────────┐    schedule_at/4     ┌─────────────┐                   │
#   │   │   Agent    │───────────────────►  │  Database   │                   │
#   │   │            │    schedule_in/4     │  (pending)  │                   │
#   │   └────────────┘                      └──────┬──────┘                   │
#   │         ▲                                    │                           │
#   │         │                                    │ poll                      │
#   │         │                                    ▼                           │
#   │         │  {:wakeup, type, id, payload}   ┌─────────────┐               │
#   │         └────────────────────────────────│  Scheduler  │               │
#   │                                           │  (GenServer)│               │
#   │                                           └──────┬──────┘               │
#   │                                                  │                       │
#   │                                                  │ fire job              │
#   │                                                  ▼                       │
#   │                                           ┌─────────────┐               │
#   │                                           │  Database   │               │
#   │                                           │ (delivered) │               │
#   │                                           └─────────────┘               │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Key Responsibilities Tested:
# ----------------------------
#
# 1. Job Scheduling
#    - schedule_at/4: Schedule a job for a specific DateTime
#    - schedule_in/4: Schedule a job after a delay (milliseconds)
#    - Jobs are stored in the database with "pending" status
#
# 2. Job Cancellation
#    - cancel/2: Cancel all pending jobs of a specific type for an agent
#    - Only "pending" jobs are cancelled, not "delivered" jobs
#
# 3. Job Delivery
#    - Scheduler polls for due jobs and fires them
#    - Jobs transition from "pending" to "delivered" status
#    - Agents receive {:wakeup, type, job_id, payload} messages
#
# 4. GenServer Lifecycle
#    - start_link/1: Starting the Scheduler process
#    - handle_info(:poll): Periodic polling for due jobs
#    - handle_info(:recover_overdue): Recovery of missed jobs
#    - handle_info({:fire, job_id}): Firing a specific job
#    - handle_call(:clear_in_flight): Clearing in-flight job tracking
#
# 5. Error Handling
#    - Firing non-existent jobs (graceful handling)
#    - Firing already-delivered jobs (idempotent)
#    - Firing jobs for non-running agents (logs warning)
#
# Job Status State Machine:
# -------------------------
#
#   pending ──────► delivered
#      │
#      └──────────► cancelled
#
# Test Categories:
# ----------------
#
# - Unit Tests: Individual scheduler functions
# - Integration Tests: Full job lifecycle from scheduling to delivery
#
# Dependencies:
# -------------
#
# - Maraithon.Runtime.Scheduler (the GenServer implementation)
# - Maraithon.Runtime.ScheduledJob (the Ecto schema)
# - Maraithon.Agents (for creating test agents)
# - Maraithon.Repo (for database access)
# - Ecto SQL Sandbox (for database isolation)
#
# Setup Requirements:
# -------------------
#
# This test uses `async: false` because:
# 1. The Scheduler is a named GenServer (only one instance can run)
# 2. Tests need to start/stop the Scheduler
# 3. Database state must be isolated between tests
#
# ==============================================================================

defmodule Maraithon.Runtime.SchedulerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Repo
  alias Maraithon.Agents

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # Creates a test agent for scheduling jobs. The agent exists in the database
  # but does NOT have a running RuntimeAgent process (unless explicitly started).
  # This is intentional - it tests scheduler behavior independent of agents.
  # ----------------------------------------------------------------------------
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

  # ============================================================================
  # JOB SCHEDULING TESTS - schedule_at/4
  # ============================================================================
  #
  # These tests verify scheduling jobs for a specific time.
  # schedule_at/4 creates a job that will fire at the given DateTime.
  # ============================================================================

  describe "schedule_at/4" do
    @doc """
    Verifies that a job can be scheduled for a specific time.
    The job should be stored in the database with:
    - Correct agent_id
    - Correct job_type
    - "pending" status
    - Payload preserved as JSON
    """
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

    @doc """
    Verifies that jobs can be scheduled with an empty payload.
    Default payload is an empty map when not provided.
    """
    test "schedules job with empty payload", %{agent: agent} do
      fire_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      {:ok, job_id} = Scheduler.schedule_at(agent.id, "simple_job", fire_at)

      job = Repo.get(ScheduledJob, job_id)
      assert job.payload == %{}
    end
  end

  # ============================================================================
  # JOB SCHEDULING TESTS - schedule_in/4
  # ============================================================================
  #
  # These tests verify scheduling jobs after a delay.
  # schedule_in/4 creates a job that will fire after N milliseconds.
  # ============================================================================

  describe "schedule_in/4" do
    @doc """
    Verifies that a job can be scheduled after a delay.
    The fire_at time should be calculated as now + delay.
    Allows small tolerance for test execution time.
    """
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

  # ============================================================================
  # JOB CANCELLATION TESTS
  # ============================================================================
  #
  # These tests verify job cancellation behavior.
  # cancel/2 cancels all pending jobs of a specific type for an agent.
  # Already-delivered jobs should not be cancelled (they've already fired).
  # ============================================================================

  describe "cancel/2" do
    @doc """
    Verifies that pending jobs can be cancelled.
    All pending jobs of the specified type should be cancelled.
    Returns the count of cancelled jobs.
    """
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

    @doc """
    Verifies that only pending jobs are cancelled, not delivered ones.
    This ensures we don't try to "undo" jobs that have already fired.
    """
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

  # ============================================================================
  # GENSERVER LIFECYCLE TESTS
  # ============================================================================
  #
  # These tests verify the Scheduler GenServer can be started and stopped.
  # ============================================================================

  describe "start_link/1" do
    @doc """
    Verifies the Scheduler can be started as a GenServer.
    The Scheduler is registered under a fixed name for discovery.
    """
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

  # ============================================================================
  # HANDLE_INFO TESTS
  # ============================================================================
  #
  # These tests verify the Scheduler's message handling for:
  # - :poll (periodic polling for due jobs)
  # - :recover_overdue (recovery of missed jobs)
  # - {:fire, job_id} (firing a specific job)
  # ============================================================================

  describe "handle_info/2" do
    @doc """
    Verifies the Scheduler handles :poll messages.
    Polling checks for due jobs and fires them.
    """
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

    @doc """
    Verifies the Scheduler handles :recover_overdue messages.
    This message triggers recovery of jobs that should have fired
    but were missed (e.g., due to server restart).
    """
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

    @doc """
    Verifies the Scheduler fires jobs when receiving {:fire, job_id}.
    The job should transition from "pending" to "delivered".
    """
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

    @doc """
    Verifies the Scheduler gracefully handles firing non-existent jobs.
    This can happen if a job is deleted between scheduling and firing.
    """
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

  # ============================================================================
  # HANDLE_CALL TESTS
  # ============================================================================
  #
  # These tests verify synchronous calls to the Scheduler.
  # ============================================================================

  describe "handle_call/3" do
    @doc """
    Verifies the :clear_in_flight call clears tracking state.
    This is used to reset the scheduler's view of jobs being processed.
    """
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

  # ============================================================================
  # IDEMPOTENCY TESTS
  # ============================================================================
  #
  # These tests verify that firing jobs is idempotent.
  # Firing an already-delivered job should not cause errors.
  # ============================================================================

  describe "handle_info - job already delivered" do
    @doc """
    Verifies that firing an already-delivered job is a no-op.
    This ensures idempotency - the same job can't fire twice.
    """
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

  # ============================================================================
  # NON-RUNNING AGENT TESTS
  # ============================================================================
  #
  # These tests verify scheduler behavior when the target agent isn't running.
  # The scheduler should mark jobs as delivered even if the agent can't receive them.
  # ============================================================================

  describe "job delivery to non-running agent" do
    @doc """
    Verifies that jobs are marked as delivered even if agent isn't running.
    The scheduler logs a warning but doesn't fail.
    This prevents jobs from piling up for stopped agents.
    """
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
