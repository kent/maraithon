# ==============================================================================
# Agent Supervisor Unit Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The AgentSupervisor is the "process manager" for all running agents. Think of
# it like a task manager on your computer - it's responsible for:
#
# - **Starting Agents**: When you create a new agent via API, the supervisor
#   starts a new process for it
# - **Stopping Agents**: When you stop an agent, the supervisor terminates
#   its process cleanly
# - **Fault Tolerance**: If an agent process crashes, the supervisor handles
#   it gracefully (doesn't crash the whole system)
#
# From a user's perspective, the supervisor ensures:
# - New agents start immediately when created
# - Stopped agents actually stop (no zombie processes)
# - One misbehaving agent can't take down other agents
# - System resources are managed properly
#
# Example: Creating Multiple Agents
#
#   User creates Agent A via API
#        │
#        ▼
#   AgentSupervisor.start_agent(agent_a)
#        │
#        ▼
#   ┌─────────────────────────────────────┐
#   │        Agent Supervisor             │
#   │                                     │
#   │   ┌─────────┐                       │
#   │   │ Agent A │ ◄── Running           │
#   │   └─────────┘                       │
#   └─────────────────────────────────────┘
#
#   User creates Agent B via API
#        │
#        ▼
#   AgentSupervisor.start_agent(agent_b)
#        │
#        ▼
#   ┌─────────────────────────────────────┐
#   │        Agent Supervisor             │
#   │                                     │
#   │   ┌─────────┐   ┌─────────┐         │
#   │   │ Agent A │   │ Agent B │ ◄── New │
#   │   └─────────┘   └─────────┘         │
#   └─────────────────────────────────────┘
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the AgentSupervisor breaks, users experience:
# - New agents failing to start
# - "Agent not found" errors when trying to stop agents
# - Zombie processes consuming memory
# - System crashes when agents fail
# - Inability to manage running agents
#
# The supervisor is a critical infrastructure component that must work reliably!
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the AgentSupervisor module, which is a
# DynamicSupervisor that manages agent processes. It provides functions
# to start and stop agent processes dynamically at runtime.
#
# OTP Supervision Architecture:
# -----------------------------
#
#   ┌───────────────────────────────────────────────────────────────────────────┐
#   │                        Application Supervisor                             │
#   │                                                                           │
#   │   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐        │
#   │   │    Registry     │   │    Scheduler    │   │ AgentSupervisor │        │
#   │   │                 │   │                 │   │ (DynamicSupervisor)      │
#   │   └─────────────────┘   └─────────────────┘   └─────────────────┘        │
#   │                                                       │                   │
#   │                                              ┌────────┴────────┐          │
#   │                                              │                 │          │
#   │                                        ┌─────────┐       ┌─────────┐      │
#   │                                        │ Agent 1 │       │ Agent 2 │      │
#   │                                        │ Process │       │ Process │      │
#   │                                        └─────────┘       └─────────┘      │
#   └───────────────────────────────────────────────────────────────────────────┘
#
# DynamicSupervisor vs Supervisor:
# --------------------------------
# A regular Supervisor starts a fixed set of children at boot time.
# A DynamicSupervisor starts with NO children and allows adding/removing
# children at runtime - perfect for agents that are created/stopped on demand.
#
# Key Functions:
# --------------
# - start_agent/1: Start a new agent process under supervision
#   - Takes an agent struct (with id, behavior, config)
#   - Returns {:ok, pid} or {:error, reason}
#
# - stop_agent/1: Stop an agent process
#   - Takes a pid
#   - Returns :ok or {:error, :not_found}
#
# Test Categories:
# ----------------
# - Function Existence: Verify exported functions exist with correct arity
# - Error Handling: Verify proper errors for invalid inputs
#
# Note on Test Limitations:
# -------------------------
# Full agent lifecycle tests (starting real agents, verifying state, etc.)
# are in agent_test.exs. Those tests properly set up database sandbox access
# for spawned processes. These tests focus on verifying the module's
# interface without requiring database access.
#
# Dependencies:
# -------------
# - Maraithon.Runtime.AgentSupervisor (the module being tested)
# - Process (for creating test PIDs)
#
# ==============================================================================

defmodule Maraithon.Runtime.AgentSupervisorTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.AgentSupervisor

  # ============================================================================
  # MODULE INTERFACE TESTS
  # ============================================================================
  #
  # These tests verify that the AgentSupervisor module exports the expected
  # functions. Full agent lifecycle tests with database access are in
  # agent_test.exs, which properly handles sandbox access for spawned processes.
  # ============================================================================

  # ----------------------------------------------------------------------------
  # START AGENT TESTS
  # ----------------------------------------------------------------------------
  #
  # Verifies the start_agent/1 function interface.
  # Actually starting agents requires database access which is tested elsewhere.
  # ----------------------------------------------------------------------------

  describe "start_agent/1" do
    @doc """
    Verifies that the start_agent/1 function is exported with the correct arity.
    This is a sanity check to ensure the public API hasn't changed.
    """
    test "function exists and accepts an agent struct" do
      # Verify the function is exported with correct arity
      assert function_exported?(AgentSupervisor, :start_agent, 1)
    end
  end

  # ----------------------------------------------------------------------------
  # STOP AGENT TESTS
  # ----------------------------------------------------------------------------
  #
  # Verifies the stop_agent/1 function interface and error handling.
  # The stop function should return {:error, :not_found} for invalid PIDs.
  # ----------------------------------------------------------------------------

  describe "stop_agent/1" do
    @doc """
    Verifies that the stop_agent/1 function is exported with the correct arity.
    This is a sanity check to ensure the public API hasn't changed.
    """
    test "function exists and accepts a pid" do
      # Verify the function is exported with correct arity
      assert function_exported?(AgentSupervisor, :stop_agent, 1)
    end

    @doc """
    Verifies that stopping a non-existent process returns an error.

    This tests the error handling path when someone tries to stop:
    - An agent that has already stopped
    - An agent that never existed
    - A PID from another supervisor

    The error should be {:error, :not_found}, not a crash.
    """
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
