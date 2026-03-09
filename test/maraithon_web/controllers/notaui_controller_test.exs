defmodule MaraithonWeb.NotauiControllerTest do
  use MaraithonWeb.ConnCase, async: false

  setup do
    original_config = Application.get_env(:maraithon, :notaui, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :notaui, original_config)
    end)

    :ok
  end

  describe "POST /api/v1/integrations/notaui/sync" do
    test "publishes a Notaui task snapshot", %{conn: conn} do
      bypass = Bypass.open()
      topic = "notaui:test-sync"

      Application.put_env(:maraithon, :notaui,
        base_url: "http://localhost:#{bypass.port}",
        client_id: "client-id",
        client_secret: "client-secret",
        scope: "tasks:read"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "access-token"}))
      end)

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)
        assert req["params"]["name"] == "task.list"
        assert req["params"]["arguments"]["statuses"] == ["available"]

        tasks = [%{"id" => "task-1", "title" => "Review todos", "status" => "available"}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => req["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => Jason.encode!(tasks)}]
            }
          })
        )
      end)

      :ok = Phoenix.PubSub.subscribe(Maraithon.PubSub, topic)

      conn =
        post(conn, "/api/v1/integrations/notaui/sync", %{
          topic: topic,
          filter: %{statuses: ["available"], limit: 25}
        })

      response = json_response(conn, 202)
      assert response["status"] == "published"
      assert response["topic"] == topic
      assert response["task_count"] == 1

      assert_receive {:pubsub_event, ^topic, event}
      assert event.type == "notaui_task_snapshot"
    end

    test "returns error when Notaui is not configured", %{conn: conn} do
      Application.put_env(:maraithon, :notaui, [])

      conn = post(conn, "/api/v1/integrations/notaui/sync", %{})

      assert json_response(conn, 400)["error"] == "notaui integration is not configured"
    end
  end
end
