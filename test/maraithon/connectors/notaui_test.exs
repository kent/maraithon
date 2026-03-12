defmodule Maraithon.Connectors.NotauiTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Notaui
  alias Maraithon.OAuth

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

  test "uses a stored user oauth token when user_id is provided" do
    bypass = Bypass.open()
    user_id = "notaui-user-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :notaui,
      mcp_url: "http://localhost:#{bypass.port}/mcp",
      client_id: "client-id",
      client_secret: "client-secret",
      redirect_uri: "http://localhost:4000/auth/notaui/callback"
    )

    {:ok, _token} =
      OAuth.store_tokens(user_id, "notaui", %{
        access_token: "user-access-token",
        refresh_token: "user-refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        scopes: ["tasks:read", "tasks:write"]
      })

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      assert {"authorization", "Bearer user-access-token"} in conn.req_headers
      assert Plug.Conn.get_req_header(conn, "x-notaui-account-id") == []
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["params"]["name"] == "task.list"

      payload = [%{"id" => "task-99", "title" => "User task", "status" => "available"}]

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

    assert {:ok, [%{"id" => "task-99"}]} = Notaui.list_tasks(user_id, %{})
  end

  test "discovers accessible accounts for a bearer token" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :notaui,
      mcp_url: "http://localhost:#{bypass.port}/mcp",
      client_id: "client-id",
      client_secret: "client-secret",
      redirect_uri: "http://localhost:4000/auth/notaui/callback"
    )

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer discovered-token"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["params"]["name"] == "account.list"

      payload = [
        %{"id" => "acct-team", "label" => "Team Workspace"},
        %{"id" => "acct-default", "label" => "Personal", "is_default" => true}
      ]

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

    assert {:ok, snapshot} = Notaui.discover_accounts("discovered-token")
    assert snapshot["account_count"] == 2
    assert snapshot["default_account_id"] == "acct-default"
    assert snapshot["default_account_label"] == "Personal"
    assert Enum.any?(snapshot["accounts"], &(&1["id"] == "acct-default" and &1["is_default"]))
  end

  test "adds X-Notaui-Account-ID when a non-default account is requested" do
    bypass = Bypass.open()
    user_id = "notaui-accounted-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :notaui,
      mcp_url: "http://localhost:#{bypass.port}/mcp",
      client_id: "client-id",
      client_secret: "client-secret",
      redirect_uri: "http://localhost:4000/auth/notaui/callback"
    )

    {:ok, _token} =
      OAuth.store_tokens(user_id, "notaui", %{
        access_token: "user-access-token",
        refresh_token: "user-refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        scopes: ["tasks:read", "tasks:write"],
        external_account_id: "acct-default",
        metadata: %{
          "default_account_id" => "acct-default",
          "default_account_label" => "Personal",
          "accounts" => [
            %{"id" => "acct-default", "label" => "Personal", "is_default" => true},
            %{"id" => "acct-team", "label" => "Team Workspace", "is_default" => false}
          ]
        }
      })

    connected_account = ConnectedAccounts.get(user_id, "notaui")
    assert connected_account.external_account_id == "acct-default"

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-access-token"]
      assert Plug.Conn.get_req_header(conn, "x-notaui-account-id") == ["acct-team"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["params"]["name"] == "task.list"
      refute Map.has_key?(req["params"]["arguments"], "account_id")

      payload = [%{"id" => "task-100", "title" => "Scoped task", "status" => "available"}]

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

    assert {:ok, [%{"id" => "task-100"}]} =
             Notaui.list_tasks(user_id, %{"account_id" => "acct-team"})
  end

  test "rejects an unknown account id before issuing the MCP request" do
    bypass = Bypass.open()
    user_id = "notaui-unknown-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :notaui,
      mcp_url: "http://localhost:#{bypass.port}/mcp",
      client_id: "client-id",
      client_secret: "client-secret",
      redirect_uri: "http://localhost:4000/auth/notaui/callback"
    )

    {:ok, _token} =
      OAuth.store_tokens(user_id, "notaui", %{
        access_token: "user-access-token",
        refresh_token: "user-refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        scopes: ["tasks:read"],
        external_account_id: "acct-default",
        metadata: %{
          "default_account_id" => "acct-default",
          "accounts" => [%{"id" => "acct-default", "label" => "Personal", "is_default" => true}]
        }
      })

    assert {:error, :unknown_account_id} =
             Notaui.list_tasks(user_id, %{"account_id" => "acct-missing"})
  end
end
