defmodule MaraithonWeb.AdminControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Events
  alias Maraithon.Runtime.ScheduledJob

  describe "GET /api/v1/admin/dashboard" do
    test "returns fleet snapshot with spend and logs", %{conn: conn} do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped"
        })

      {:ok, _event} = Events.append(agent.id, "dashboard_event", %{ok: true})

      Maraithon.LogBuffer.record(%{
        level: :info,
        message: "dashboard log entry",
        metadata: %{agent_id: agent.id}
      })

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      conn = get(conn, "/api/v1/admin/dashboard")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "health")
      assert Map.has_key?(response, "queue_metrics")
      assert Map.has_key?(response, "total_spend")
      assert Enum.any?(response["recent_activity"], &(&1["event_type"] == "dashboard_event"))
      assert Enum.any?(response["recent_logs"], &(&1["message"] == "dashboard log entry"))
    end
  end

  describe "GET /api/v1/admin/agents/:id/inspection" do
    test "returns agent inspection payload", %{conn: conn} do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"name" => "inspectable"},
          status: "stopped"
        })

      {:ok, _event} = Events.append(agent.id, "inspection_event", %{message: "ready"})

      {:ok, _effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "pending",
          attempts: 1
        })
        |> Maraithon.Repo.insert()

      {:ok, _job} =
        %ScheduledJob{}
        |> ScheduledJob.changeset(%{
          agent_id: agent.id,
          job_type: "heartbeat",
          fire_at: DateTime.utc_now(),
          status: "pending",
          attempts: 1
        })
        |> Maraithon.Repo.insert()

      Maraithon.LogBuffer.record(%{
        level: :warning,
        message: "inspection log entry",
        metadata: %{agent_id: agent.id}
      })

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      conn = get(conn, "/api/v1/admin/agents/#{agent.id}/inspection")

      response = json_response(conn, 200)
      assert response["agent"]["id"] == agent.id
      assert response["spend"]["llm_calls"] == 0
      assert Enum.any?(response["events"], &(&1["event_type"] == "inspection_event"))
      assert response["inspection"]["effect_counts"]["pending"] == 1
      assert response["inspection"]["job_counts"]["pending"] == 1

      assert Enum.any?(
               response["inspection"]["recent_logs"],
               &(&1["message"] == "inspection log entry")
             )
    end
  end
end
