defmodule Mix.Tasks.Maraithon.AgentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("maraithon.agent")
    :ok
  end

  test "list prints agents from the API" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/api/v1/agents", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-123"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"agents":[{"id":"agent-1","behavior":"prompt_agent","status":"running"}]})
      )
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Maraithon.Agent.run([
          "list",
          "--base-url",
          "http://localhost:#{bypass.port}",
          "--token",
          "token-123"
        ])
      end)

    assert output =~ "\"id\": \"agent-1\""
    assert output =~ "\"behavior\": \"prompt_agent\""
  end

  test "create sends the expected payload" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/api/v1/agents", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-123"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "behavior" => "prompt_agent",
               "config" => %{
                 "name" => "cli-agent",
                 "prompt" => "Watch my work",
                 "subscribe" => ["github:acme/repo", "notaui:tasks"],
                 "tools" => ["search_files", "notaui_list_tasks"],
                 "memory_limit" => 25,
                 "custom" => true
               },
               "budget" => %{"llm_calls" => 120, "tool_calls" => 240}
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, ~s({"id":"agent-1","behavior":"prompt_agent","status":"running"}))
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Maraithon.Agent.run([
          "create",
          "--base-url",
          "http://localhost:#{bypass.port}",
          "--token",
          "token-123",
          "--behavior",
          "prompt_agent",
          "--name",
          "cli-agent",
          "--prompt",
          "Watch my work",
          "--subscriptions",
          "github:acme/repo,notaui:tasks",
          "--tools",
          "search_files,notaui_list_tasks",
          "--memory-limit",
          "25",
          "--budget-llm-calls",
          "120",
          "--budget-tool-calls",
          "240",
          "--config-json",
          "{\"custom\":true}"
        ])
      end)

    assert output =~ "\"id\": \"agent-1\""
    assert output =~ "\"status\": \"running\""
  end
end
