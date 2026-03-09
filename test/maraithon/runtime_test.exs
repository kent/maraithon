# ==============================================================================
# Runtime Module Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The Runtime module is the "control panel" for managing agents. It's the
# programmatic interface for all agent lifecycle operations:
#
# - **Starting Agents**: Create new agents and begin execution
# - **Stopping Agents**: Gracefully shut down agents
# - **Messaging Agents**: Send messages to running agents
# - **Querying Status**: Check if agents are running, stopped, or degraded
# - **Retrieving Events**: Get the history of what an agent has done
# - **Resuming Agents**: Restart agents after server restart
#
# From a user's perspective, the Runtime module powers:
# - The API endpoints that create and manage agents
# - The dashboard's agent controls (stop, send message)
# - The automatic agent resume on server restart
#
# Example Use Cases:
# 1. POST /api/v1/agents → Runtime.start_agent() creates and starts agent
# 2. POST /api/v1/agents/:id/stop → Runtime.stop_agent() stops agent
# 3. POST /api/v1/agents/:id/ask → Runtime.send_message() sends message
# 4. Server restart → Runtime.resume_all_agents() restarts all agents
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the Runtime module breaks, users experience:
# - Inability to create new agents
# - Inability to stop runaway agents
# - Lost messages to agents
# - Agents that don't resume after server restart
# - Incorrect status information in the dashboard
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the Maraithon.Runtime module, which provides
# high-level functions for agent management. It coordinates between the
# database (Agents context), the runtime system (AgentSupervisor), and
# the agent processes themselves.
#
# Runtime Architecture:
# ---------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                         Runtime Module                                   │
#   │                                                                          │
#   │   API/Dashboard                                                          │
#   │        │                                                                 │
#   │        ▼                                                                 │
#   │   ┌─────────────────┐                                                   │
#   │   │    Runtime      │  ◄── Coordinates all agent operations             │
#   │   │    Module       │                                                   │
#   │   └─────────────────┘                                                   │
#   │        │      │      │                                                  │
#   │        │      │      └──────────────────────┐                           │
#   │        ▼      ▼                             ▼                           │
#   │   ┌────────┐  ┌────────────┐  ┌─────────────────┐                       │
#   │   │Database│  │ Supervisor │  │  Agent Process  │                       │
#   │   │(Agents)│  │ (start/    │  │  (send message, │                       │
#   │   │        │  │  stop)     │  │   get status)   │                       │
#   │   └────────┘  └────────────┘  └─────────────────┘                       │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Key Functions:
# --------------
# - start_agent/1: Create agent in DB, start process via Supervisor
# - stop_agent/2: Stop process, update DB status to "stopped"
# - send_message/3: Find running agent, send message
# - get_agent_status/1: Query agent status from DB and runtime
# - get_events/2: Query event history for an agent
# - resume_all_agents/0: Restart all agents marked as "running" in DB
#
# Test Categories:
# ----------------
# - Agent Lifecycle: Start, stop, resume operations
# - Message Handling: Sending messages to running/stopped agents
# - Status Queries: Getting agent status
# - Event Queries: Retrieving agent event history
# - Error Handling: Non-existent agents, stopped agents
#
# Dependencies:
# -------------
# - Maraithon.Runtime (the module being tested)
# - Maraithon.Agents (database operations)
# - Maraithon.Runtime.Scheduler (for agent wakeups)
# - Ecto SQL Sandbox (for database isolation)
#
# Setup Requirements:
# -------------------
# This test uses `async: false` because:
# 1. The Scheduler is a named GenServer (only one instance can run)
# 2. Tests need to start/stop the Scheduler
# 3. Agent processes need database sandbox access
#
# ==============================================================================

defmodule Maraithon.RuntimeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime
  alias Maraithon.Agents

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # Sets up a fresh Scheduler for each test. The Scheduler is required for
  # agent operations but we don't want it from the application supervisor
  # because it won't have database sandbox access.
  # ----------------------------------------------------------------------------
  setup do
    # Stop any existing scheduler
    case Process.whereis(Maraithon.Runtime.Scheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    {:ok, scheduler_pid} = Maraithon.Runtime.Scheduler.start_link([])
    Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), scheduler_pid)

    on_exit(fn ->
      case Process.whereis(Maraithon.Runtime.Scheduler) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end
    end)

    %{scheduler_pid: scheduler_pid}
  end

  # ============================================================================
  # STATUS QUERY TESTS
  # ============================================================================
  #
  # These tests verify that agent status queries work correctly.
  # ============================================================================

  describe "get_agent_status/1" do
    @doc """
    Verifies that querying a non-existent agent returns not_found.
    This prevents showing status for agents that don't exist.
    """
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.get_agent_status(Ecto.UUID.generate())
    end

    @doc """
    Verifies that querying an existing agent returns its status.
    The status struct should include id, status, and behavior.
    """
    test "returns status for existing agent" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, status} = Runtime.get_agent_status(agent.id)

      assert status.id == agent.id
      assert status.status == "running"
      assert status.behavior == "watchdog_summarizer"
    end
  end

  # ============================================================================
  # EVENT QUERY TESTS
  # ============================================================================
  #
  # These tests verify that event queries work correctly.
  # ============================================================================

  describe "get_events/2" do
    @doc """
    Verifies that querying events for a non-existent agent returns not_found.
    """
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.get_events(Ecto.UUID.generate())
    end

    @doc """
    Verifies that querying events for a new agent returns empty list.
    New agents haven't done anything yet, so they have no events.
    """
    test "returns events for existing agent" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, events} = Runtime.get_events(agent.id)

      assert is_list(events)
      assert events == []
    end
  end

  # ============================================================================
  # MESSAGE SENDING TESTS
  # ============================================================================
  #
  # These tests verify that sending messages to agents works correctly.
  # ============================================================================

  describe "send_message/3" do
    @doc """
    Verifies that sending a message to a non-existent agent returns not_found.
    """
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.send_message(Ecto.UUID.generate(), "hello")
    end

    @doc """
    Verifies that sending a message to a stopped agent returns agent_stopped.
    Users can't send messages to agents that aren't running.
    """
    test "returns agent_stopped for stopped agent" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "stopped",
          started_at: DateTime.utc_now(),
          stopped_at: DateTime.utc_now()
        })

      assert {:error, :agent_stopped} = Runtime.send_message(agent.id, "hello")
    end
  end

  # ============================================================================
  # AGENT STOP TESTS
  # ============================================================================
  #
  # These tests verify that stopping agents works correctly.
  # ============================================================================

  describe "stop_agent/2" do
    @doc """
    Verifies that stopping a non-existent agent returns not_found.
    """
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.stop_agent(Ecto.UUID.generate())
    end

    @doc """
    Verifies that stopping an existing agent updates the database.
    The agent should be marked as "stopped" with a stopped_at timestamp.
    """
    test "stops existing agent and updates database" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, result} = Runtime.stop_agent(agent.id)

      assert result.stopped_at != nil

      # Verify database was updated
      updated_agent = Agents.get_agent(agent.id)
      assert updated_agent.status == "stopped"
      assert updated_agent.stopped_at != nil
    end

    @doc """
    Verifies that custom stop reasons can be provided.
    Stop reasons are useful for debugging and audit trails.
    """
    test "accepts custom reason" do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _result} = Runtime.stop_agent(agent.id, "test_reason")

      # Verify agent was stopped
      updated_agent = Agents.get_agent(agent.id)
      assert updated_agent.status == "stopped"
    end
  end

  # ============================================================================
  # AGENT START TESTS
  # ============================================================================
  #
  # These tests verify that starting agents works correctly.
  # ============================================================================

  describe "start_agent/1" do
    @doc """
    Verifies that starting an agent with an invalid behavior returns error.
    Only registered behaviors can be used.
    """
    test "returns error for invalid behavior" do
      params = %{
        "behavior" => "nonexistent_behavior",
        "config" => %{}
      }

      # This will return an error because the behavior is invalid
      result = Runtime.start_agent(params)

      # Should be an error for invalid behavior
      assert match?({:error, _}, result)
    end

    # Note: Tests that require running agent processes are covered in
    # test/maraithon/runtime/agent_test.exs which properly handles
    # database sandbox access for spawned processes.
  end

  # ============================================================================
  # AGENT RESUME TESTS
  # ============================================================================
  #
  # These tests verify that resuming agents after server restart works.
  # ============================================================================

  describe "resume_all_agents/0" do
    @doc """
    Verifies that resume_all_agents returns ok when there are no agents.
    This is the base case - no agents to resume.
    """
    test "returns ok when no agents to resume" do
      # Don't create any resumable agents - just verify the function works
      # with no agents to resume
      assert :ok = Runtime.resume_all_agents()
    end

    @doc """
    Verifies that stopped agents are NOT resumed.
    Only agents with status = "running" should be resumed.
    """
    test "returns ok even with stopped agents" do
      # Create a stopped agent (won't be resumed)
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "stopped",
          started_at: DateTime.utc_now(),
          stopped_at: DateTime.utc_now()
        })

      # Should succeed without trying to start stopped agents
      assert :ok = Runtime.resume_all_agents()

      # The agent should still exist
      assert Agents.get_agent(agent.id) != nil
    end
  end

  # Note: Tests for running agents (get_agent_status with runtime info,
  # send_message to running agent) are covered in test/maraithon/runtime/agent_test.exs
  # which properly handles database sandbox access for spawned processes.
end
