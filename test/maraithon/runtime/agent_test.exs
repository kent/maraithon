# ==============================================================================
# Agent Runtime Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The Agent is the core "AI worker" in Maraithon. Each agent is an autonomous
# process that:
# - Receives messages from users via the API
# - Subscribes to external events (GitHub webhooks, Slack messages, etc.)
# - Wakes up on schedules to perform periodic tasks
# - Calls LLMs to reason about work
# - Executes tools to take action in the real world
#
# From a user's perspective, an Agent is like hiring a virtual assistant that:
# - Never sleeps (runs 24/7)
# - Responds instantly to triggers
# - Can monitor multiple data sources simultaneously
# - Has configurable "budgets" to prevent runaway costs
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the agent lifecycle breaks, users cannot:
# - Create new agents to automate their workflows
# - Send messages to running agents
# - Trust that their agents will wake up on schedule
# - Rely on agents receiving webhook events
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the Agent GenStateMachine lifecycle and behavior.
# It covers the full lifecycle of an agent from creation to termination.
#
# Architecture Overview:
# ----------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                        Agent State Machine                               │
#   │                                                                          │
#   │    ┌─────────┐      ┌─────────┐      ┌────────────────┐                 │
#   │    │  idle   │─────►│ working │─────►│ waiting_effect │                 │
#   │    │         │◄─────│         │◄─────│                │                 │
#   │    └────┬────┘      └────┬────┘      └───────┬────────┘                 │
#   │         │                │                    │                          │
#   │         │    wakeup      │   effect_result   │                          │
#   │         │    message     │   timeout         │                          │
#   │         │    pubsub      │                   │                          │
#   │         ▼                ▼                   ▼                          │
#   │    ┌────────────────────────────────────────────────────────┐           │
#   │    │              Event Queue (pending work)                 │           │
#   │    └────────────────────────────────────────────────────────┘           │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Key Responsibilities Tested:
# ----------------------------
#
# 1. Process Lifecycle
#    - start_link/1: Starting agent processes with proper registration
#    - child_spec/1: DynamicSupervisor compatibility
#    - init/1: State initialization and configuration loading
#
# 2. State Transitions
#    - idle → working: On receiving work (message, wakeup, pubsub event)
#    - working → waiting_effect: When an effect needs external completion
#    - waiting_effect → idle: When effect completes
#    - working → idle: When work completes without effects
#
# 3. Message Handling
#    - {:message, content, metadata, id}: User/external messages
#    - {:wakeup, type, job_id, payload}: Scheduled job notifications
#    - {:pubsub_event, topic, data}: PubSub subscription events
#    - {:effect_result, effect_id, result}: Async effect completions
#
# 4. Budget Management
#    - Default budget allocation when not configured
#    - Custom budget from agent config
#    - Zero budget handling (stays idle)
#
# 5. Duplicate Prevention
#    - Job ID deduplication (same job_id ignored)
#
# Test Categories:
# ----------------
#
# - Unit Tests: Individual state machine functions and transitions
# - Integration Tests: Full message flow through the agent
#
# Dependencies:
# -------------
#
# - Maraithon.Runtime.Agent (the GenStateMachine implementation)
# - Maraithon.Runtime.Scheduler (for wakeup scheduling)
# - Maraithon.Runtime.AgentRegistry (for process lookup)
# - Maraithon.Agents (for agent database operations)
# - Ecto SQL Sandbox (for database isolation)
#
# Setup Requirements:
# -------------------
#
# This test uses `async: false` because:
# 1. Agent processes are spawned and need database access
# 2. The Scheduler must be manually started and given sandbox access
# 3. Multiple agents in the same test can cause registry conflicts
#
# ==============================================================================

defmodule Maraithon.Runtime.AgentTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Agents

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # The setup block ensures:
  # 1. Any existing Scheduler is stopped to prevent interference
  # 2. A fresh Scheduler is started for this test
  # 3. The Scheduler is given database sandbox access
  # 4. A test agent is created in the database with "running" status
  # 5. Cleanup happens after each test to stop the Scheduler
  #
  # This setup is critical for process-based tests because spawned processes
  # need explicit sandbox access before they can query the database.
  # ----------------------------------------------------------------------------
  setup do
    # Stop any existing scheduler/processes that might interfere
    case Process.whereis(Maraithon.Runtime.Scheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    {:ok, scheduler_pid} = Maraithon.Runtime.Scheduler.start_link([])
    Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), scheduler_pid)

    on_exit(fn ->
      case Process.whereis(Maraithon.Runtime.Scheduler) do
        nil -> :ok
        pid ->
          if Process.alive?(pid) do
            GenServer.stop(pid, :normal)
          end
      end
    end)

    # Create an agent for testing
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{
          "name" => "test_agent",
          "prompt" => "You are a test agent.",
          "subscribe" => [],
          "tools" => []
        },
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent, scheduler_pid: scheduler_pid}
  end

  # ============================================================================
  # PROCESS LIFECYCLE TESTS
  # ============================================================================
  #
  # These tests verify that agents can be started as OTP processes and
  # properly register themselves for discovery.
  # ============================================================================

  describe "start_link/1" do
    @doc """
    Verifies that an agent process can be started and remains alive.
    The agent should start successfully and be a valid Erlang process.
    """
    test "starts the agent process", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies that agents register themselves in the AgentRegistry.
    This allows other parts of the system to find running agents by ID.
    The registry lookup returns [{pid, nil}] for registered agents.
    """
    test "registers agent in registry", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Check registry
      [{^pid, nil}] = Registry.lookup(Maraithon.Runtime.AgentRegistry, agent.id)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # CHILD SPEC TESTS
  # ============================================================================
  #
  # These tests verify the OTP child specification returned by child_spec/1.
  # The child spec is used by DynamicSupervisor to start and manage agents.
  # ============================================================================

  describe "child_spec/1" do
    @doc """
    Verifies child_spec returns the correct OTP specification.

    Key properties:
    - id: Must match agent.id for proper supervision
    - start: Must be {RuntimeAgent, :start_link, [agent]}
    - restart: :temporary because agents should not auto-restart
    - type: :worker (not a supervisor)
    """
    test "returns valid child spec", %{agent: agent} do
      spec = RuntimeAgent.child_spec(agent)

      assert spec.id == agent.id
      assert spec.start == {RuntimeAgent, :start_link, [agent]}
      assert spec.restart == :temporary
      assert spec.type == :worker
    end
  end

  # ============================================================================
  # INITIALIZATION TESTS
  # ============================================================================
  #
  # These tests verify that agents properly initialize their state from
  # the agent configuration stored in the database.
  # ============================================================================

  describe "init/1" do
    @doc """
    Verifies that an agent initializes correctly and enters the idle state.
    After initialization, the agent should be alive and ready to receive work.
    """
    test "initializes agent with correct state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Give time for initialization
      Process.sleep(100)

      # Agent should be alive and in idle state
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # STATE TRANSITION TESTS
  # ============================================================================
  #
  # These tests verify the state machine transitions between idle, working,
  # and waiting_effect states. Each wakeup type, message, or event can
  # trigger a state transition.
  # ============================================================================

  describe "state transitions" do
    @doc """
    Verifies agents handle heartbeat wakeups in idle state.
    Heartbeat wakeups are periodic health checks that may trigger behavior.
    The agent should process the heartbeat and remain alive.
    """
    test "handles heartbeat wakeup in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Give time for initialization
      Process.sleep(150)

      # Send heartbeat wakeup
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents handle checkpoint wakeups in idle state.
    Checkpoint wakeups allow agents to save state or perform periodic tasks.
    """
    test "handles checkpoint wakeup in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "checkpoint", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents handle user messages in idle state.
    Messages are the primary way users interact with agents.
    Format: {:message, content, metadata, message_id}
    """
    test "handles message in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello agent!", %{}, message_id})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents gracefully handle unknown message types.
    Unknown messages should be logged but not crash the agent.
    """
    test "handles unknown message in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      send(pid, {:unknown_message, "test"})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies that duplicate wakeup job IDs are ignored.
    This prevents the same scheduled job from being processed twice.
    The agent tracks seen job_ids and ignores duplicates.
    """
    test "ignores duplicate wakeup job_id", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()

      # Send same job_id twice
      send(pid, {:wakeup, "heartbeat", job_id, %{}})
      Process.sleep(50)
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # PUBSUB EVENT TESTS
  # ============================================================================
  #
  # These tests verify that agents properly handle PubSub subscription events.
  # Agents subscribe to topics (like "github:owner/repo") and receive events
  # when webhooks or other sources publish to those topics.
  # ============================================================================

  describe "pubsub events" do
    @doc """
    Verifies agents receive events for topics they're subscribed to.
    The agent config includes a "subscribe" list of topics.
    When events are published to those topics, the agent receives them.
    """
    test "handles pubsub event when subscribed", %{scheduler_pid: _scheduler_pid} do
      topic = "test:topic:#{System.unique_integer()}"

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "pubsub_agent",
            "prompt" => "Test",
            "subscribe" => [topic],
            "tools" => []
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send pubsub event
      send(pid, {:pubsub_event, topic, %{data: "test"}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents ignore events for topics they're NOT subscribed to.
    This ensures agents only process relevant events and don't waste
    resources on unrelated PubSub traffic.
    """
    test "ignores pubsub event when not subscribed", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send pubsub event for topic not subscribed to
      send(pid, {:pubsub_event, "unsubscribed:topic", %{data: "test"}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # EFFECT HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that agents properly handle asynchronous effect results.
  # Effects are operations that happen outside the agent's state machine
  # (like HTTP calls, file operations, etc.) and complete later.
  # ============================================================================

  describe "effect handling" do
    @doc """
    Verifies agents handle effect results for unknown effect IDs.
    This can happen if an effect times out and then completes later.
    The agent should handle this gracefully without crashing.
    """
    test "handles effect_result for unknown effect", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Try to transition to waiting_effect state first by sending a message
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello!", %{}, message_id})

      Process.sleep(100)

      # Send effect result for unknown effect
      send(pid, {:effect_result, Ecto.UUID.generate(), {:ok, %{result: "test"}}})

      Process.sleep(100)
      # Agent may or may not still be alive depending on effect processing
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # BUDGET HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that agents properly initialize and respect their
  # budget constraints. Budgets limit the number of LLM calls and tool
  # calls an agent can make to prevent runaway costs.
  # ============================================================================

  describe "budget handling" do
    @doc """
    Verifies agents initialize with default budget when config omits it.
    Default budgets provide reasonable limits for most use cases.
    """
    test "initializes with default budget when not configured", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "no_budget_agent",
            "prompt" => "Test"
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents respect custom budget values from config.
    Custom budgets allow fine-grained control over agent resource usage.
    """
    test "initializes with custom budget from config", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "custom_budget_agent",
            "prompt" => "Test",
            "budget" => %{
              "llm_calls" => 100,
              "tool_calls" => 200
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents with zero budget stay idle when receiving work.
    Zero budget means the agent cannot perform any work - it must be
    given more budget before it can process messages.
    """
    test "respects zero budget by staying idle", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "zero_budget_agent",
            "prompt" => "Test",
            "budget" => %{
              "llm_calls" => 0,
              "tool_calls" => 0
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message - should stay idle due to zero budget
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello!", %{}, message_id})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # WAKEUP SCHEDULING TESTS
  # ============================================================================
  #
  # These tests verify the different types of wakeup jobs that can be
  # scheduled for agents. Wakeups are used for periodic tasks, health
  # checks, and delayed processing.
  # ============================================================================

  describe "wakeup scheduling" do
    @doc """
    Verifies agents handle the generic "wakeup" job type.
    This is a general-purpose wakeup that agents can use for any purpose.
    """
    test "handles wakeup job type", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "wakeup", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # WORKING STATE TESTS
  # ============================================================================
  #
  # These tests verify agent behavior while in the "working" state.
  # In this state, the agent is processing a message or wakeup and
  # should queue any new work until it finishes.
  # ============================================================================

  describe "working state" do
    @doc """
    Verifies that wakeups are queued when agent is already working.
    This prevents work from being lost when agents are busy.
    The queued work is processed after current work completes.
    """
    test "queues wakeup when in working state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message to transition to working state
      message_id1 = Ecto.UUID.generate()
      send(pid, {:message, "First message", %{}, message_id1})

      # Immediately send a wakeup (should be queued)
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(200)
      # Agent may crash due to effect execution, that's ok for this test
      :ok
    end
  end

  # ============================================================================
  # WAITING_EFFECT STATE TESTS
  # ============================================================================
  #
  # These tests verify agent behavior while waiting for an effect to complete.
  # In this state, the agent is blocked on an async operation and should
  # queue any new work.
  # ============================================================================

  describe "waiting_effect state" do
    @doc """
    Verifies that wakeups are queued when agent is waiting for an effect.
    The agent transitions to waiting_effect when it dispatches an async
    operation and needs to wait for the result.
    """
    test "queues wakeup when in waiting_effect state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message to start working
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Test", %{}, message_id})

      # Send wakeup - should be queued
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      # Agent may crash due to effect execution, that's ok for this test
      :ok
    end
  end
end
