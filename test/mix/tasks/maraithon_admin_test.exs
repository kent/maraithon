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
end
