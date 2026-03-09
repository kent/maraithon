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

  describe "GET /api/v1/admin/fly/logs" do
    test "returns configured Fly platform logs", %{conn: conn} do
      previous = Application.get_env(:maraithon, Maraithon.FlyLogs, [])
      bypass = Bypass.open()

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.FlyLogs, previous)
      end)

      Application.put_env(:maraithon, Maraithon.FlyLogs,
        api_token: "FlyV1 test-token",
        api_base_url: "http://localhost:#{bypass.port}/api/v1",
        apps: ["maraithon", "maraithon-db"],
        region: "yyz",
        receive_timeout_ms: 1_000
      )

      Bypass.expect_once(bypass, "GET", "/api/v1/apps/maraithon-db/logs", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["FlyV1 test-token"]
        assert URI.decode_query(conn.query_string) == %{"region" => "yyz"}

        body = %{
          "data" => [
            %{
              "id" => "db-log-1",
              "attributes" => %{
                "timestamp" => "2026-03-09T12:15:00Z",
                "message" => "database machine restarted",
                "level" => "warn",
                "instance" => "db-machine",
                "region" => "yyz",
                "meta" => %{"event" => %{"provider" => "runner"}}
              }
            }
          ],
          "meta" => %{"next_token" => "db-next"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      conn = get(conn, "/api/v1/admin/fly/logs?app=maraithon-db&limit=25")

      response = json_response(conn, 200)
      assert response["available"] == true
      assert response["apps"] == ["maraithon-db"]
      assert response["next_tokens"] == %{"maraithon-db" => "db-next"}

      assert Enum.any?(response["logs"], fn log ->
               log["message"] == "database machine restarted" and
                 log["metadata"]["provider"] == "runner"
             end)
    end
  end
end
