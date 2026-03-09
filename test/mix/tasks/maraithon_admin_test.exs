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
end
