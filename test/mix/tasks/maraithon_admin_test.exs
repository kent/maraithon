defmodule Mix.Tasks.Maraithon.AdminTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("maraithon.admin")
    :ok
  end

  test "dashboard prints the fleet snapshot" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/api/v1/admin/dashboard", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-123"]

      assert URI.decode_query(conn.query_string) == %{
               "activity_limit" => "10",
               "log_limit" => "50"
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"health":{"status":"healthy"},"queue_metrics":{},"recent_activity":[],"recent_failures":[],"recent_logs":[],"total_spend":{"llm_calls":0}})
      )
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Maraithon.Admin.run([
          "dashboard",
          "--base-url",
          "http://localhost:#{bypass.port}",
          "--token",
          "token-123",
          "--activity-limit",
          "10",
          "--log-limit",
          "50"
        ])
      end)

    assert output =~ "\"status\": \"healthy\""
    assert output =~ "\"llm_calls\": 0"
  end

  test "fly-logs prints the Fly platform log payload" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/api/v1/admin/fly/logs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-123"]

      assert URI.decode_query(conn.query_string) == %{
               "app" => "maraithon-db",
               "limit" => "25"
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"available":true,"apps":["maraithon-db"],"logs":[{"message":"database restarted","metadata":{"provider":"runner"}}],"next_tokens":{"maraithon-db":"next-123"},"errors":[]})
      )
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Maraithon.Admin.run([
          "fly-logs",
          "--base-url",
          "http://localhost:#{bypass.port}",
          "--token",
          "token-123",
          "--app",
          "maraithon-db",
          "--limit",
          "25"
        ])
      end)

    assert output =~ "\"database restarted\""
    assert output =~ "\"maraithon-db\": \"next-123\""
  end

  test "refresh-insights queues a user-scoped insight rebuild" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/api/v1/admin/insights/refresh", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-123"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "reason" => "after_code_change",
               "user_id" => "kent@runner.now"
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"user_id":"kent@runner.now","eligible_count":2,"queued_count":1,"queued":[{"agent_id":"agent-1","behavior":"founder_followthrough_agent"}],"skipped":[{"agent_id":"agent-2","behavior":"slack_followthrough_agent","reason":"agent_not_running"}]})
      )
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Maraithon.Admin.run([
          "refresh-insights",
          "--base-url",
          "http://localhost:#{bypass.port}",
          "--token",
          "token-123",
          "--user-id",
          "kent@runner.now",
          "--reason",
          "after_code_change"
        ])
      end)

    assert output =~ "\"user_id\": \"kent@runner.now\""
    assert output =~ "\"queued_count\": 1"
    assert output =~ "\"agent_not_running\""
  end
end
