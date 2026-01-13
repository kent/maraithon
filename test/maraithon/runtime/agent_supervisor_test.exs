defmodule Maraithon.Runtime.AgentSupervisorTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.AgentSupervisor

  # Note: Full agent lifecycle tests with database access are in agent_test.exs.
  # These tests verify the supervisor module's functions exist and have correct
  # signatures without actually starting agents (which require database access
  # that's tricky to set up before the agent's init runs).

  describe "start_agent/1" do
    test "function exists and accepts an agent struct" do
      # Verify the function is exported with correct arity
      assert function_exported?(AgentSupervisor, :start_agent, 1)
    end
  end

  describe "stop_agent/1" do
    test "function exists and accepts a pid" do
      # Verify the function is exported with correct arity
      assert function_exported?(AgentSupervisor, :stop_agent, 1)
    end

    test "returns error for non-existent pid" do
      # Create a dead pid by spawning and killing a process
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(pid)

      # Should return error for non-existent child
      result = AgentSupervisor.stop_agent(pid)
      assert result == {:error, :not_found}
    end
  end
end
