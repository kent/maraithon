defmodule MaraithonWeb.EventControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.{Accounts, AgentIsolation, AgentSubscriptions, Agents, Repo}
  alias Maraithon.Runtime.AgentDirective

  describe "POST /api/v1/events" do
    test "publishes event to topic", %{conn: conn} do
      conn =
        post(conn, "/api/v1/events", %{
          topic: "test_topic",
          payload: %{foo: "bar"}
        })

      response = json_response(conn, 202)
      assert response["status"] == "published"
      assert response["topic"] == "test_topic"
    end

    test "persists subscriber delivery for the split exact runtime", %{conn: conn} do
      {:ok, user} = Accounts.get_or_create_user_by_email("event-ingress@example.com")

      {:ok, agent} =
        Agents.create_agent(%{
          user_id: user.id,
          behavior: "prompt_agent",
          status: "running",
          started_at: DateTime.utc_now(),
          config: %{
            "name" => "event ingress",
            "prompt" => "Handle durable events.",
            "subscribe" => ["test:durable"]
          }
        })

      {:ok, _binding} =
        AgentIsolation.grant_binding_consent(
          agent,
          Maraithon.DataCase.binding_consent(agent)
        )

      {:ok, _subscriptions} = AgentSubscriptions.sync_for_agent(agent)

      conn =
        conn
        |> put_req_header("idempotency-key", "event-ingress-1")
        |> post("/api/v1/events", %{
          topic: "test:durable",
          payload: %{source_id: "event-1"}
        })

      assert json_response(conn, 202)["status"] == "published"

      directive = Repo.get_by!(AgentDirective, agent_id: agent.id)
      assert directive.status == "pending"
      assert directive.kind == "channel_ingress"
      assert directive.payload["topic"] == "test:durable"
      assert directive.payload["payload"] == %{"source_id" => "event-1"}

      retry_conn =
        build_conn()
        |> put_req_header("idempotency-key", "event-ingress-1")
        |> post("/api/v1/events", %{
          topic: "test:durable",
          payload: %{source_id: "event-1"}
        })

      assert json_response(retry_conn, 202)["status"] == "published"
      assert Repo.aggregate(AgentDirective, :count, :id) == 1

      conflicting_conn =
        build_conn()
        |> put_req_header("idempotency-key", "event-ingress-1")
        |> post("/api/v1/events", %{
          topic: "test:durable",
          payload: %{source_id: "event-2"}
        })

      assert json_response(conflicting_conn, 409)["error"] ==
               "idempotency key conflicts with an earlier event"

      assert Repo.aggregate(AgentDirective, :count, :id) == 1
    end

    test "returns error when topic is missing", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{payload: %{foo: "bar"}})

      assert json_response(conn, 400)["error"] == "topic is required"
    end

    test "returns error when topic is empty string", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: "", payload: %{}})

      assert json_response(conn, 400)["error"] == "topic is required"
    end

    test "returns a client error for malformed event input", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: ["not", "a", "topic"]})
      assert json_response(conn, 400)["error"] == "topic is invalid"

      conn =
        build_conn()
        |> put_req_header("idempotency-key", String.duplicate("x", 201))
        |> post("/api/v1/events", %{topic: "test_topic"})

      assert json_response(conn, 400)["error"] == "idempotency key is invalid"
    end

    test "uses empty payload when not provided", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: "test_topic"})

      response = json_response(conn, 202)
      assert response["status"] == "published"
    end
  end

  describe "GET /api/v1/events/topics" do
    test "returns active subscriber topic summaries", %{conn: conn} do
      {:ok, user} = Accounts.get_or_create_user_by_email("topic-summary@example.com")

      {:ok, first_agent} =
        Agents.create_agent(%{
          user_id: user.id,
          behavior: "prompt_agent",
          config: %{
            "name" => "calendar watcher",
            "prompt" => "Watch calendar events.",
            "subscribe" => ["calendar:primary", "gmail:inbox"]
          },
          status: "running"
        })

      {:ok, second_agent} =
        Agents.create_agent(%{
          user_id: user.id,
          behavior: "prompt_agent",
          config: %{
            "name" => "calendar helper",
            "prompt" => "Also watch calendar events.",
            "subscribe" => ["calendar:primary"]
          },
          status: "running"
        })

      for agent <- [first_agent, second_agent] do
        {:ok, _binding} =
          AgentIsolation.grant_binding_consent(
            agent,
            Maraithon.DataCase.binding_consent(agent)
          )
      end

      conn = get(conn, "/api/v1/events/topics")

      response = json_response(conn, 200)
      assert response["count"] == 2

      calendar_topic = Enum.find(response["topics"], &(&1["topic"] == "calendar:primary"))
      gmail_topic = Enum.find(response["topics"], &(&1["topic"] == "gmail:inbox"))

      assert calendar_topic["subscriber_count"] == 2
      assert first_agent.id in calendar_topic["agent_ids"]
      assert second_agent.id in calendar_topic["agent_ids"]
      assert is_binary(calendar_topic["updated_at"])

      assert gmail_topic["subscriber_count"] == 1
      assert first_agent.id in gmail_topic["agent_ids"]
    end
  end
end
