defmodule MaraithonWeb.AgentControllerTest do
  # async: false because creating agents spawns processes that need DB access
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Agents

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

    :ok
  end

  describe "GET /api/v1/agents" do
    test "returns empty list when no agents", %{conn: conn} do
      conn = get(conn, "/api/v1/agents")

      assert json_response(conn, 200) == %{"agents" => []}
    end

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

  describe "GET /api/v1/agents/:id" do
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "POST /api/v1/agents/:id/ask" do
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/ask", %{message: "hello"})

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "POST /api/v1/agents/:id/stop" do
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/stop", %{})

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "GET /api/v1/agents/:id/events" do
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/events")

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "GET /api/v1/agents/:id/spend" do
    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/#{Ecto.UUID.generate()}/spend")

      assert json_response(conn, 404)["error"] == "not_found"
    end

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

  describe "GET /api/v1/spend" do
    test "returns total spend", %{conn: conn} do
      conn = get(conn, "/api/v1/spend")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "total_cost_usd")
      assert Map.has_key?(response, "input_tokens")
      assert Map.has_key?(response, "output_tokens")
      assert Map.has_key?(response, "llm_calls")
    end
  end

  describe "GET /api/v1/agents/:id - existing agent" do
    test "returns agent status", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
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

  describe "POST /api/v1/agents" do
    test "creates an agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents", %{
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

  describe "POST /api/v1/agents/:id/ask - existing agent" do
    test "returns agent_stopped for stopped agent", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
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

  describe "POST /api/v1/agents/:id/stop - existing agent" do
    test "stops an existing agent", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
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

  describe "GET /api/v1/agents/:id/events - existing agent" do
    test "returns events for agent", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
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

    test "accepts limit parameter", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

      conn = get(conn, "/api/v1/agents/#{agent.id}/events?limit=10")

      response = json_response(conn, 200)
      assert is_list(response["events"])
    end

    test "accepts types parameter as comma-separated string", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
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
