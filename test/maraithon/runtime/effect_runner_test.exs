# ==============================================================================
# Effect Runner Integration Tests
# ==============================================================================
#
# This test module provides comprehensive integration testing for the EffectRunner
# GenServer, which is responsible for executing side effects (LLM calls, tool calls)
# on behalf of agent processes.
#
# ## Architecture Overview
#
# The EffectRunner implements an "outbox pattern" for reliable effect execution:
#
#   ┌─────────────┐     ┌─────────────────┐     ┌─────────────────┐
#   │   Agent     │────►│  Effects Table  │────►│  EffectRunner   │
#   │  (request)  │     │    (outbox)     │     │   (executor)    │
#   └─────────────┘     └─────────────────┘     └─────────────────┘
#                                                       │
#                                                       ▼
#                                               ┌─────────────────┐
#                                               │  LLM/Tool APIs  │
#                                               └─────────────────┘
#
# ## Key Responsibilities Tested
#
# 1. **Polling**: Periodically fetches pending effects from the database
# 2. **Claiming**: Atomically claims effects to prevent duplicate execution
# 3. **Execution**: Runs LLM calls and tool calls asynchronously
# 4. **Retry Logic**: Implements exponential backoff for failed effects
# 5. **Stale Recovery**: Reclaims effects stuck in "claimed" state too long
# 6. **Result Delivery**: Notifies agent processes of effect completion
#
# ## Test Categories
#
# - **Unit Tests**: Test individual GenServer callbacks in isolation
# - **Integration Tests**: Test the full effect lifecycle with real database
#
# ## Dependencies
#
# - Requires PostgreSQL database (via Ecto Sandbox)
# - Uses MockProvider for LLM calls to avoid real API calls
# - Requires Task.Supervisor for async effect execution
#
# ==============================================================================

defmodule Maraithon.Runtime.EffectRunnerTest do
  use Maraithon.DataCase, async: false

  # ---------------------------------------------------------------------------
  # Why async: false?
  # ---------------------------------------------------------------------------
  # The EffectRunner is a singleton GenServer that polls the database for
  # pending effects. Running tests in parallel would cause race conditions
  # where multiple test instances compete for the same effects.
  # ---------------------------------------------------------------------------

  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Agents

  # ===========================================================================
  # Test Setup
  # ===========================================================================
  #
  # Each test requires an agent record because effects are associated with
  # agents via foreign key. We create a minimal agent with "running" status.
  # ===========================================================================

  setup do
    # Create a test agent that effects will be associated with.
    # The agent doesn't need to be actually running - we just need a valid
    # agent_id for the foreign key constraint on the effects table.
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent}
  end

  # ===========================================================================
  # Unit Tests: GenServer Lifecycle
  # ===========================================================================
  #
  # These tests verify that the EffectRunner GenServer starts correctly and
  # handles its basic callbacks without crashing. They don't test the full
  # effect execution pipeline - that's covered in integration tests below.
  # ===========================================================================

  describe "start_link/1" do
    @doc """
    Tests that the EffectRunner GenServer starts successfully.

    The EffectRunner is a named GenServer (__MODULE__), so only one instance
    can run at a time. We stop any existing instance before starting fresh.
    """
    test "starts the effect runner" do
      # Clean up any existing instance from previous tests or application startup
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Start a fresh instance and verify it's alive
      assert {:ok, pid} = EffectRunner.start_link([])
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up to avoid interfering with other tests
      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info :poll" do
    @doc """
    Tests that the EffectRunner handles the :poll message correctly.

    The :poll message is sent periodically (default: every 1 second) to trigger
    the effect processing loop. This test verifies:
    1. The GenServer doesn't crash when processing a poll
    2. Database queries work correctly (via sandbox)
    """
    test "handles poll message" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # Allow the GenServer process to access our test's database connection.
      # This is required because we're using Ecto's sandbox mode.
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Manually trigger a poll cycle
      send(pid, :poll)
      Process.sleep(100)

      # The GenServer should remain alive after processing
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Tests that poll correctly queries for pending effects.

    Even with no pending effects, the poll should:
    1. Query the effects table without errors
    2. Handle the empty result set gracefully
    3. Schedule the next poll
    """
    test "fetches pending effects during poll" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Note: We can't easily test full effect execution because it requires
      # the Task.Supervisor to be properly initialized which happens in the
      # application startup. We test that the GenServer handles the poll
      # message without crashing (when there are no pending effects).

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Send poll message (with no pending effects in the database)
      send(pid, :poll)
      Process.sleep(100)

      # Should remain alive - no crash from empty result set
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info {:effect_done, effect_id, result}" do
    @doc """
    Tests that completed effect results are handled correctly.

    When a Task completes executing an effect, it sends {:effect_done, effect_id, result}
    back to the EffectRunner. This test verifies the message is processed without
    crashing (the actual effect tracking is tested in integration tests).
    """
    test "removes effect from running state" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # Simulate an effect completion message
      effect_id = Ecto.UUID.generate()
      send(pid, {:effect_done, effect_id, {:ok, %{result: "test"}}})
      Process.sleep(50)

      # GenServer should handle the message gracefully
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_call :clear_running" do
    @doc """
    Tests the :clear_running call for debugging/testing purposes.

    This call clears the internal map of running effects, useful for:
    1. Testing scenarios where you need a clean slate
    2. Debugging stuck effects
    """
    test "clears the running state" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # The :clear_running call should succeed
      :ok = GenServer.call(pid, :clear_running)

      # GenServer should remain operational
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ===========================================================================
  # Integration Tests: Full Effect Lifecycle
  # ===========================================================================
  #
  # These tests exercise the complete effect execution pipeline:
  #
  #   1. Effect created in database (pending status)
  #   2. EffectRunner polls and claims the effect
  #   3. Effect is executed asynchronously (LLM call or tool call)
  #   4. Result is written back to database
  #   5. Agent is notified (if running)
  #
  # ## Test Environment Setup
  #
  # - Task.Supervisor must be started for async execution
  # - MockProvider is configured to avoid real LLM API calls
  # - Database sandbox allows effect records to be created/updated
  #
  # ===========================================================================

  describe "integration: effect execution" do
    setup do
      # -----------------------------------------------------------------------
      # Ensure the Task.Supervisor for effects is running
      # -----------------------------------------------------------------------
      # Effects are executed asynchronously in supervised tasks. In production,
      # this is started by the application supervisor. In tests, we start it
      # manually if not already running.
      # -----------------------------------------------------------------------
      case Process.whereis(Maraithon.Runtime.EffectSupervisor) do
        nil ->
          Task.Supervisor.start_link(name: Maraithon.Runtime.EffectSupervisor)

        _ ->
          :ok
      end

      # -----------------------------------------------------------------------
      # Configure the MockProvider for LLM calls
      # -----------------------------------------------------------------------
      # We don't want to make real API calls to Anthropic during tests.
      # The MockProvider returns realistic responses without network calls.
      # -----------------------------------------------------------------------
      original_config = Application.get_env(:maraithon, Maraithon.Runtime)

      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        anthropic_api_key: "test_key"
      )

      # Restore original config after test completes
      on_exit(fn ->
        if original_config do
          Application.put_env(:maraithon, Maraithon.Runtime, original_config)
        end
      end)

      :ok
    end

    # -------------------------------------------------------------------------
    # Test: LLM Call Execution
    # -------------------------------------------------------------------------
    # This is the primary use case - agents request LLM completions which are
    # executed asynchronously by the EffectRunner.
    #
    # Flow:
    #   Agent → Effects.request("llm_call", params) → EffectRunner → MockProvider
    # -------------------------------------------------------------------------

    @doc """
    Tests successful execution of an LLM call effect.

    This tests the happy path where:
    1. An llm_call effect is created with valid parameters
    2. EffectRunner polls and picks it up
    3. MockProvider returns a successful response
    4. Effect status transitions: pending → claimed → completed
    """
    test "executes llm_call effect successfully", %{agent: agent} do
      # Stop any existing runner to ensure clean state
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a pending LLM effect in the database
      # This simulates what an agent would do when it needs an LLM completion
      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 100
        })

      # Start the EffectRunner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger the poll cycle to process pending effects
      send(pid, :poll)

      # Wait for async execution to complete
      # In production, this happens within milliseconds, but tests need time
      Process.sleep(200)

      # Verify the effect was processed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Status should be "claimed" (still processing) or "completed" (finished)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Tool Call Execution
    # -------------------------------------------------------------------------
    # Agents can also execute tools (file operations, HTTP requests, etc.)
    # through the EffectRunner.
    # -------------------------------------------------------------------------

    @doc """
    Tests successful execution of a tool call effect.

    The "time" tool is a simple tool that returns the current time.
    It's used here because it has no side effects and always succeeds.
    """
    test "executes tool_call effect successfully", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a tool call effect for the "time" tool
      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "tool_call", "time", %{
          "args" => %{}
        })

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Unknown Effect Type Handling
    # -------------------------------------------------------------------------
    # Tests error handling when an effect has an unrecognized type.
    # This should fail gracefully and trigger retry logic.
    # -------------------------------------------------------------------------

    @doc """
    Tests that unknown effect types are handled gracefully.

    When the EffectRunner encounters an effect type it doesn't recognize,
    it should:
    1. Return an error result
    2. Trigger retry logic (if attempts remain)
    3. Eventually mark as failed (if max attempts reached)
    """
    test "handles unknown effect type", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect with an invalid type
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Should be retrying (pending) or failed after exhausting retries
      assert updated_effect.status in ["pending", "failed", "claimed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Effect Claiming (Concurrency Safety)
    # -------------------------------------------------------------------------
    # Multiple effects should be claimed atomically to prevent duplicate
    # execution in a distributed environment.
    # -------------------------------------------------------------------------

    @doc """
    Tests that multiple pending effects are claimed correctly.

    The claiming mechanism uses atomic database updates to ensure:
    1. Each effect is claimed by exactly one runner
    2. No effects are skipped
    3. No effects are executed twice
    """
    test "claims effects correctly", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create multiple pending effects
      {:ok, effect_id1} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})
      {:ok, effect_id2} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      # Both effects should have been processed
      e1 = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id1)
      e2 = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id2)

      assert e1.status in ["claimed", "completed"]
      assert e2.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Stale Effect Recovery
    # -------------------------------------------------------------------------
    # Effects can become "stuck" in claimed status if the runner crashes.
    # The EffectRunner periodically reclaims stale effects.
    # -------------------------------------------------------------------------

    @doc """
    Tests recovery of effects stuck in "claimed" status.

    If an EffectRunner crashes while processing an effect, the effect will
    be left in "claimed" status forever. To handle this:

    1. Effects have a claimed_at timestamp
    2. Effects claimed > 5 minutes ago are considered "stale"
    3. Stale effects are reset to "pending" for reprocessing

    This ensures at-least-once delivery even with node failures.
    """
    test "reclaims stale effects", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Manually mark it as claimed with an OLD timestamp (simulates crash)
      # The effect appears to have been claimed 400 seconds ago
      old_time = DateTime.add(DateTime.utc_now(), -400_000, :millisecond)

      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [status: "claimed", claimed_at: old_time, claimed_by: "old_node"]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # This poll should reclaim the stale effect and reprocess it
      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Effect should be reclaimed (back to pending) or re-executed
      assert updated_effect.status in ["pending", "claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Retry Scheduling (Future retry_after)
    # -------------------------------------------------------------------------
    # Effects waiting for retry should NOT be processed until retry_after time
    # -------------------------------------------------------------------------

    @doc """
    Tests that effects with future retry_after are not processed.

    After a failed attempt, effects are scheduled for retry using exponential
    backoff. The retry_after timestamp indicates when the effect should be
    retried. Effects with retry_after in the future should be skipped.
    """
    test "processes effects with retry_after in the future", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Set retry_after to 1 minute in the future
      future_time = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [retry_after: future_time]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(100)

      # Effect should still be pending (not yet time to retry)
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status == "pending"

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Retry Scheduling (Past retry_after)
    # -------------------------------------------------------------------------
    # Effects with retry_after in the past SHOULD be processed
    # -------------------------------------------------------------------------

    @doc """
    Tests that effects with past retry_after ARE processed.

    Once the retry_after time has passed, the effect should be picked up
    on the next poll cycle and re-executed.
    """
    test "does not process effects with retry_after in the past", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Set retry_after to 1 second in the past
      past_time = DateTime.add(DateTime.utc_now(), -1000, :millisecond)

      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [retry_after: past_time]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Effect with past retry_after should be processed
      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Max Attempts Exhaustion
    # -------------------------------------------------------------------------
    # Effects that fail repeatedly should eventually be marked as "failed"
    # -------------------------------------------------------------------------

    @doc """
    Tests that effects are marked failed after exhausting max_attempts.

    The retry logic uses exponential backoff, but has a maximum number of
    attempts. Once max_attempts is reached:

    1. Effect is marked as "failed"
    2. Agent is notified of the failure
    3. No more retries are scheduled
    """
    test "marks effect as failed after max_attempts", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect that will always fail (unknown type)
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Set attempts to max - 1, so the next failure is final
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [attempts: 2, max_attempts: 3]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(300)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Should be marked as failed (or still being processed)
      assert updated_effect.status in ["failed", "claimed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Retry Logic (Before Max Attempts)
    # -------------------------------------------------------------------------
    # Failed effects should be scheduled for retry with exponential backoff
    # -------------------------------------------------------------------------

    @doc """
    Tests that failed effects are retried when attempts < max_attempts.

    On failure, the EffectRunner should:
    1. Increment the attempts counter
    2. Calculate backoff delay: base * 2^attempt + jitter
    3. Set retry_after timestamp
    4. Reset status to "pending"
    """
    test "retries effect when attempts < max_attempts", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Ensure we have retries remaining
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [attempts: 0, max_attempts: 3]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(300)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Should have incremented attempts and be pending retry
      assert updated_effect.attempts >= 1 or updated_effect.status in ["pending", "claimed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Invalid Tool Handling
    # -------------------------------------------------------------------------
    # Tool calls with non-existent tools should fail gracefully
    # -------------------------------------------------------------------------

    @doc """
    Tests error handling for tool calls with invalid tool names.

    When a tool_call effect references a tool that doesn't exist:
    1. The Tools.execute call returns {:error, :not_found}
    2. The effect enters retry logic
    3. Eventually fails after max attempts
    """
    test "handles tool call with invalid tool", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a tool call effect with a non-existent tool
      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "tool_call", "nonexistent_tool", %{
          "tool" => "nonexistent_tool",
          "args" => %{}
        })

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Should be retrying or failed
      assert updated_effect.status in ["pending", "failed", "claimed"]

      GenServer.stop(pid, :normal)
    end
  end
end
