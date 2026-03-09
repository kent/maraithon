defmodule Maraithon.Tools.NotauiToolsTest do
  use ExUnit.Case, async: false

  alias Maraithon.Tools.{NotauiListTasks, NotauiCompleteTask, NotauiUpdateTask}

  setup do
    original_config = Application.get_env(:maraithon, :notaui, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :notaui, original_config)
    end)

    :ok
  end

  test "NotauiListTasks returns tasks with filters" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :notaui,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "client-id",
      client_secret: "client-secret"
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
      assert req["params"]["arguments"]["limit"] == 5
      assert req["params"]["arguments"]["statuses"] == ["inbox", "available"]

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

    assert {:ok, result} =
             NotauiListTasks.execute(%{"limit" => 5, "statuses" => "inbox,available"})

    assert result.source == "notaui"
    assert result.task_count == 1
  end

  test "NotauiCompleteTask requires task_id" do
    assert {:error, "task_id is required"} = NotauiCompleteTask.execute(%{})
  end

  test "NotauiCompleteTask completes task" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :notaui,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "client-id",
      client_secret: "client-secret"
    )

    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "access-token"}))
    end)

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["params"]["name"] == "task.complete"
      assert req["params"]["arguments"]["task_id"] == "task-42"

      task = %{"id" => "task-42", "title" => "Review todos", "status" => "completed"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(task)}]
          }
        })
      )
    end)

    assert {:ok, %{task: %{"status" => "completed"}}} =
             NotauiCompleteTask.execute(%{"task_id" => "task-42"})
  end

  test "NotauiUpdateTask requires at least one update field" do
    assert {:error, "at least one update field is required"} =
             NotauiUpdateTask.execute(%{"task_id" => "task-42"})
  end

  test "NotauiUpdateTask updates task fields" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :notaui,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "client-id",
      client_secret: "client-secret"
    )

    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "access-token"}))
    end)

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["params"]["name"] == "task.update"
      assert req["params"]["arguments"]["task_id"] == "task-42"
      assert req["params"]["arguments"]["status"] == "waiting"
      assert req["params"]["arguments"]["flagged"] == true

      task = %{
        "id" => "task-42",
        "title" => "Review todos",
        "status" => "waiting",
        "flagged" => true
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(task)}]
          }
        })
      )
    end)

    assert {:ok, %{task: %{"status" => "waiting", "flagged" => true}}} =
             NotauiUpdateTask.execute(%{
               "task_id" => "task-42",
               "status" => "waiting",
               "flagged" => true
             })
  end
end
