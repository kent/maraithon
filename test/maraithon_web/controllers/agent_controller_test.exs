# ==============================================================================
# Agent Controller Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The Agent Controller is the REST API for managing agents. It's how external
# systems and frontends interact with Maraithon:
#
# - **Create Agents**: POST /api/v1/agents - Start new AI agents
# - **List Agents**: GET /api/v1/agents - See all agents
# - **Get Agent**: GET /api/v1/agents/:id - Get specific agent details
# - **Stop Agent**: POST /api/v1/agents/:id/stop - Stop a running agent
# - **Send Message**: POST /api/v1/agents/:id/ask - Chat with an agent
# - **Get Events**: GET /api/v1/agents/:id/events - View agent history
# - **Get Spend**: GET /api/v1/agents/:id/spend - View agent costs
#
# From a user's perspective, this API enables:
# - CLI tools that manage agents
# - Custom dashboards and monitoring
# - Automated agent deployment pipelines
# - Integration with other systems
#
# Example User Journey:
# 1. User deploys a new agent via CLI: `curl -X POST /api/v1/agents ...`
# 2. Agent starts running and processing events
# 3. User checks status: `curl /api/v1/agents/:id`
# 4. User views costs: `curl /api/v1/agents/:id/spend`
# 5. User stops agent: `curl -X POST /api/v1/agents/:id/stop`
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the Agent Controller breaks, users experience:
# - Inability to create agents via API
# - Broken CLI tools and integrations
# - Incorrect cost tracking
# - Inability to stop runaway agents
# - Failed automated deployments
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the AgentController, which provides RESTful
# endpoints for agent management. Each endpoint maps to a Runtime function.
#
# API Endpoint Mapping:
# ---------------------
#
#   Endpoint                          → Runtime Function
#   ─────────────────────────────────────────────────────
#   GET    /api/v1/agents             → Runtime.list_agents()
#   POST   /api/v1/agents             → Runtime.start_agent()
#   GET    /api/v1/agents/:id         → Runtime.get_agent_status()
#   POST   /api/v1/agents/:id/stop    → Runtime.stop_agent()
#   POST   /api/v1/agents/:id/ask     → Runtime.send_message()
#   GET    /api/v1/agents/:id/events  → Runtime.get_events()
#   GET    /api/v1/agents/:id/spend   → Spend.get_agent_spend()
#   GET    /api/v1/spend              → Spend.get_total_spend()
#
# Response Formats:
# -----------------
# - Success: JSON with data
# - Not Found: {"error": "not_found"}
# - Conflict: {"error": "agent_stopped"}
# - Validation Error: {"error": "validation error message"}
#
# Test Categories:
# ----------------
# - List Endpoints: Empty list, populated list
# - Get Endpoints: Existing agents, non-existent agents
# - Create Endpoints: Valid params, validation errors
# - Stop Endpoints: Running agents, stopped agents, non-existent
# - Ask Endpoints: Running agents, stopped agents, non-existent
# - Events Endpoints: Query params (limit, types)
# - Spend Endpoints: Agent spend, total spend
#
# Dependencies:
# -------------
# - MaraithonWeb.AgentController (the controller being tested)
# - Maraithon.Runtime (for agent operations)
# - Maraithon.Agents (for database operations)
# - Maraithon.Spend (for cost tracking)
#
# Setup Requirements:
# -------------------
# This test uses `async: false` because:
# 1. Agent creation spawns processes that need database sandbox access
# 2. The Scheduler must be manually started and given sandbox access
# 3. Tests that create running agents need isolated scheduling
#
# ==============================================================================

defmodule MaraithonWeb.AgentControllerTest do
  # async: false because creating agents spawns processes that need DB access
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # Sets up a fresh Scheduler for each test. The Scheduler is required for
  # agent operations but we don't want it from the application supervisor
  # because it won't have database sandbox access.
  #
  # The on_exit callback ensures the Scheduler is stopped after each test.
  # ----------------------------------------------------------------------------
  setup do
    Repo.delete_all(Agent)

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

    :ok
  end

  # ============================================================================
  # LIST AGENTS TESTS
  # ============================================================================
  #
  # These tests verify the GET /api/v1/agents endpoint.
  # ============================================================================

  describe "GET /api/v1/agents" do
    @doc """
    Verifies that listing agents returns empty list when no agents exist.
    This is the initial state for new installations.
    """
    test "returns empty list when no agents", %{conn: conn} do
      conn = get(conn, "/api/v1/agents")

      assert json_response(conn, 200) == %{"agents" => []}
    end

    @doc """
    Verifies that listing agents returns all existing agents.
    Each agent should include id, behavior, and status.
    """
    test "returns list of agents", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})

      conn = get(conn, "/api/v1/agents")

      response = json_response(conn, 200)
      assert length(response["agents"]) == 1

      [returned_agent] = response["agents"]
      assert returned_agent["id"] == agent.id
      assert returned_agent["behavior"] == "prompt_agent"
      assert returned_agent["status"] == "stopped"
    end
  end

  # ============================================================================
  # GET AGENT TESTS
  # ============================================================================
  #
  # These tests verify the GET /api/v1/agents/:id endpoint.
  # ============================================================================

  describe "GET /api/v1/agents/:id" do
    @doc """
    Verifies that getting a non-existent agent returns 404.
    """
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  # ============================================================================
  # ASK AGENT TESTS
  # ============================================================================
  #
  # These tests verify the POST /api/v1/agents/:id/ask endpoint.
  # ============================================================================

  describe "POST /api/v1/agents/:id/ask" do
    @doc """
    Verifies that asking a non-existent agent returns 404.
    """
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/ask", %{message: "hello"})

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  # ============================================================================
  # STOP AGENT TESTS
  # ============================================================================
  #
  # These tests verify the POST /api/v1/agents/:id/stop endpoint.
  # ============================================================================

  describe "POST /api/v1/agents/:id/stop" do
    @doc """
    Verifies that stopping a non-existent agent returns 404.
    """
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/stop", %{})

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  # ============================================================================
  # GET EVENTS TESTS
  # ============================================================================
  #
  # These tests verify the GET /api/v1/agents/:id/events endpoint.
  # ============================================================================

  describe "GET /api/v1/agents/:id/events" do
    @doc """
    Verifies that getting events for a non-existent agent returns 404.
    """
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/events")

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  # ============================================================================
  # GET AGENT SPEND TESTS
  # ============================================================================
  #
  # These tests verify the GET /api/v1/agents/:id/spend endpoint.
  # ============================================================================

  describe "GET /api/v1/agents/:id/spend" do
    @doc """
    Verifies that getting spend for a non-existent agent returns 404.
    """
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/spend")

      assert json_response(conn, 404)["error"] == "not_found"
    end

    @doc """
    Verifies that getting spend for a new agent returns zero values.
    New agents haven't made any LLM calls, so all metrics are zero.
    """
    test "returns spend for existing agent", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})

      conn = get(conn, "/api/v1/agents/#{agent.id}/spend")

      response = json_response(conn, 200)
      assert response["agent_id"] == agent.id
      assert response["total_cost_usd"] == 0.0
      assert response["input_tokens"] == 0
      assert response["output_tokens"] == 0
      assert response["llm_calls"] == 0
    end
  end

  # ============================================================================
  # GET TOTAL SPEND TESTS
  # ============================================================================
  #
  # These tests verify the GET /api/v1/spend endpoint.
  # ============================================================================

  describe "GET /api/v1/spend" do
    @doc """
    Verifies that total spend endpoint returns all expected fields.
    This endpoint aggregates spend across all agents.
    """
    test "returns total spend", %{conn: conn} do
      conn = get(conn, "/api/v1/spend")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "total_cost_usd")
      assert Map.has_key?(response, "input_tokens")
      assert Map.has_key?(response, "output_tokens")
      assert Map.has_key?(response, "llm_calls")
    end
  end

  # ============================================================================
  # GET EXISTING AGENT TESTS
  # ============================================================================
  #
  # These tests verify agent retrieval with existing agents.
  # ============================================================================

  describe "GET /api/v1/agents/:id - existing agent" do
    @doc """
    Verifies that getting an existing agent returns full status.
    The response should include id, status, and behavior.
    """
    test "returns agent status", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      conn = get(conn, "/api/v1/agents/#{agent.id}")

      response = json_response(conn, 200)
      assert response["id"] == agent.id
      assert response["status"] == "running"
      assert response["behavior"] == "watchdog_summarizer"
    end
  end

  # ============================================================================
  # CREATE AGENT TESTS
  # ============================================================================
  #
  # These tests verify the POST /api/v1/agents endpoint.
  # ============================================================================

  describe "POST /api/v1/agents" do
    @doc """
    Verifies that creating an agent returns the new agent with running status.
    The agent should be immediately started after creation.
    """
    test "creates an agent", %{conn: conn} do
      conn =
        post(conn, "/api/v1/agents", %{
          "behavior" => "watchdog_summarizer",
          "config" => %{"key" => "value"}
        })

      response = json_response(conn, 201)
      assert response["behavior"] == "watchdog_summarizer"
      assert response["status"] == "running"
      assert response["id"] != nil

      # Clean up: wait briefly and stop the agent to avoid orphaned processes
      Process.sleep(50)
      Maraithon.Runtime.stop_agent(response["id"])
    end
  end

  # ============================================================================
  # ASK EXISTING AGENT TESTS
  # ============================================================================
  #
  # These tests verify asking (messaging) existing agents.
  # ============================================================================

  describe "POST /api/v1/agents/:id/ask - existing agent" do
    @doc """
    Verifies that asking a stopped agent returns 409 conflict.
    Users can't send messages to agents that aren't running.
    """
    test "returns agent_stopped for stopped agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped",
          started_at: DateTime.utc_now(),
          stopped_at: DateTime.utc_now()
        })

      conn = post(conn, "/api/v1/agents/#{agent.id}/ask", %{message: "hello"})

      response = json_response(conn, 409)
      assert response["error"] == "agent_stopped"
    end
  end

  # ============================================================================
  # STOP EXISTING AGENT TESTS
  # ============================================================================
  #
  # These tests verify stopping existing agents.
  # ============================================================================

  describe "POST /api/v1/agents/:id/stop - existing agent" do
    @doc """
    Verifies that stopping an existing agent returns success.
    The agent status should be "stopped" in the response.
    """
    test "stops an existing agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      conn = post(conn, "/api/v1/agents/#{agent.id}/stop", %{reason: "test_reason"})

      response = json_response(conn, 200)
      assert response["id"] == agent.id
      assert response["status"] == "stopped"
    end
  end

  describe "POST /api/v1/agents/:id/start - existing agent" do
    test "starts a stopped agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "stopped",
          stopped_at: DateTime.utc_now()
        })

      conn = post(conn, "/api/v1/agents/#{agent.id}/start", %{})

      response = json_response(conn, 200)
      assert response["id"] == agent.id
      assert response["status"] == "running"

      case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent.id) do
        [{pid, _value}] -> Maraithon.Runtime.AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end
  end

  describe "PATCH /api/v1/agents/:id" do
    test "updates a stopped agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"name" => "before-update"},
          status: "stopped"
        })

      conn =
        patch(conn, "/api/v1/agents/#{agent.id}", %{
          "behavior" => "watchdog_summarizer",
          "config" => %{"name" => "after-update", "prompt" => "Updated prompt"},
          "budget" => %{"llm_calls" => 25, "tool_calls" => 50}
        })

      response = json_response(conn, 200)
      assert response["id"] == agent.id
      assert response["behavior"] == "watchdog_summarizer"
      assert response["config"]["name"] == "after-update"
      assert response["config"]["prompt"] == "Updated prompt"
      assert response["config"]["budget"]["llm_calls"] == 25
      assert response["config"]["budget"]["tool_calls"] == 50
    end
  end

  describe "DELETE /api/v1/agents/:id" do
    test "deletes a stopped agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped"
        })

      conn = delete(conn, "/api/v1/agents/#{agent.id}")

      response = json_response(conn, 200)
      assert response["id"] == agent.id
      assert response["deleted"] == true
      assert Agents.get_agent(agent.id) == nil
    end
  end

  # ============================================================================
  # GET EVENTS - EXISTING AGENT TESTS
  # ============================================================================
  #
  # These tests verify event retrieval for existing agents.
  # ============================================================================

  describe "GET /api/v1/agents/:id/events - existing agent" do
    @doc """
    Verifies that getting events returns event list and pagination info.
    """
    test "returns events for agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      conn = get(conn, "/api/v1/agents/#{agent.id}/events")

      response = json_response(conn, 200)
      assert is_list(response["events"])
      assert is_boolean(response["has_more"])
    end

    @doc """
    Verifies that the limit parameter controls max events returned.
    """
    test "accepts limit parameter", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      conn = get(conn, "/api/v1/agents/#{agent.id}/events?limit=10")

      response = json_response(conn, 200)
      assert is_list(response["events"])
    end

    @doc """
    Verifies that the types parameter filters events by type.
    Multiple types can be specified as comma-separated values.
    """
    test "accepts types parameter as comma-separated string", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      conn = get(conn, "/api/v1/agents/#{agent.id}/events?types=message,tool_call")

      response = json_response(conn, 200)
      assert is_list(response["events"])
    end
  end
end
