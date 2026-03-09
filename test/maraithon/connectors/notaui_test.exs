defmodule Maraithon.Connectors.NotauiTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Connectors.Notaui

  setup do
    original_config = Application.get_env(:maraithon, :notaui, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :notaui, original_config)
    end)

    :ok
  end

  test "returns not configured when credentials are missing" do
    Application.put_env(:maraithon, :notaui, base_url: "https://api.notaui.com")

    assert {:error, :not_configured} = Notaui.list_tasks(%{})
  end

  test "lists tasks through Notaui MCP" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :notaui,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "client-id",
      client_secret: "client-secret",
      scope: "tasks:read",
      timeout_ms: 5000
    )

    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      assert {"authorization", "Basic Y2xpZW50LWlkOmNsaWVudC1zZWNyZXQ="} in conn.req_headers
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["grant_type"] == "client_credentials"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "access-token"}))
    end)

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      assert {"authorization", "Bearer access-token"} in conn.req_headers
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["method"] == "tools/call"
      assert req["params"]["name"] == "task.list"

      payload = [%{"id" => "task-1", "title" => "Review docs", "status" => "available"}]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]
          }
        })
      )
    end)

    assert {:ok, [%{"id" => "task-1", "status" => "available"}]} = Notaui.list_tasks(%{})
  end

  test "publishes task snapshot event" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :notaui,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "client-id",
      client_secret: "client-secret",
      scope: "tasks:read",
      timeout_ms: 5000
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

      payload = [%{"id" => "task-1", "title" => "Review docs", "status" => "available"}]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]
          }
        })
      )
    end)

    topic = "notaui:test"
    :ok = Phoenix.PubSub.subscribe(Maraithon.PubSub, topic)

    assert {:ok, %{topic: ^topic, task_count: 1, event_type: "notaui_task_snapshot"}} =
             Notaui.publish_task_snapshot(topic, %{"limit" => 10})

    assert_receive {:pubsub_event, ^topic, event}
    assert event.source == "notaui"
    assert event.type == "notaui_task_snapshot"
    assert event.data.task_count == 1
  end
end
