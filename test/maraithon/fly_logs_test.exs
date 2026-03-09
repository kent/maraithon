defmodule Maraithon.FlyLogsTest do
  use ExUnit.Case, async: false

  alias Maraithon.FlyLogs

  setup do
    previous = Application.get_env(:maraithon, Maraithon.FlyLogs, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.FlyLogs, previous)
    end)

    :ok
  end

  test "returns an unavailable snapshot when Fly log access is not configured" do
    Application.put_env(:maraithon, Maraithon.FlyLogs,
      api_token: "",
      api_base_url: "https://api.fly.io/api/v1",
      apps: [],
      region: nil,
      receive_timeout_ms: 1_000
    )

    assert {:ok, snapshot} = FlyLogs.recent_logs()
    refute snapshot.available
    assert snapshot.logs == []
    assert [%{message: "FLY_API_TOKEN is not configured"}] = snapshot.errors
  end

  test "fetches and normalizes Fly logs" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/api/v1/apps/maraithon/logs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["FlyV1 test-token"]
      assert URI.decode_query(conn.query_string) == %{"region" => "yyz"}

      body = %{
        "data" => [
          %{
            "id" => "log-1",
            "attributes" => %{
              "timestamp" => "2026-03-09T12:00:00Z",
              "message" =>
                Jason.encode!(%{
                  "message" => "database connection dropped",
                  "severity" => "ERROR",
                  "timestamp" => "2026-03-09T12:00:01Z",
                  "request_id" => "req-123"
                }),
              "level" => "info",
              "instance" => "machine-1",
              "region" => "yyz",
              "meta" => %{"event" => %{"provider" => "app"}}
            }
          },
          %{
            "id" => "log-2",
            "attributes" => %{
              "timestamp" => "2026-03-09T11:59:59Z",
              "message" => "\e[33m WARN\e[0m Trial machine stopping",
              "level" => "warn",
              "instance" => "machine-1",
              "region" => "yyz",
              "meta" => %{"event" => %{"provider" => "runner"}}
            }
          }
        ],
        "meta" => %{"next_token" => "next-123"}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    Application.put_env(:maraithon, Maraithon.FlyLogs,
      api_token: "FlyV1 test-token",
      api_base_url: "http://localhost:#{bypass.port}/api/v1",
      apps: ["maraithon"],
      region: "yyz",
      receive_timeout_ms: 1_000
    )

    assert {:ok, snapshot} = FlyLogs.recent_logs(limit: 10)
    assert snapshot.available
    assert snapshot.apps == ["maraithon"]
    assert snapshot.next_tokens == %{"maraithon" => "next-123"}
    assert snapshot.errors == []

    structured = Enum.find(snapshot.logs, &(&1.id == "log-1"))
    platform = Enum.find(snapshot.logs, &(&1.id == "log-2"))

    assert structured.level == "error"
    assert structured.message == "database connection dropped"
    assert structured.metadata["request_id"] == "req-123"
    assert structured.metadata["provider"] == "app"

    assert platform.level == "warn"
    assert platform.message == "WARN Trial machine stopping"
    assert platform.metadata["provider"] == "runner"
  end

  test "requires a single selected app when paginating with next_token" do
    Application.put_env(:maraithon, Maraithon.FlyLogs,
      api_token: "FlyV1 test-token",
      api_base_url: "https://api.fly.io/api/v1",
      apps: ["maraithon", "maraithon-db"],
      region: "yyz",
      receive_timeout_ms: 1_000
    )

    assert {:error, "next_token requires exactly one selected app"} =
             FlyLogs.recent_logs(next_token: "older-page")
  end
end
