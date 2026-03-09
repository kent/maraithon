defmodule Maraithon.Tools.ActionToolsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.OAuth

  alias Maraithon.Tools.{
    GitHubCreateIssueComment,
    LinearCreateComment,
    LinearCreateIssue,
    LinearUpdateIssueState,
    SlackPostMessage
  }

  setup do
    original_github = Application.get_env(:maraithon, :github, [])
    original_slack = Application.get_env(:maraithon, :slack, [])
    original_linear = Application.get_env(:maraithon, :linear, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :github, original_github)
      Application.put_env(:maraithon, :slack, original_slack)
      Application.put_env(:maraithon, :linear, original_linear)
    end)

    :ok
  end

  test "GitHubCreateIssueComment posts a GitHub comment" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :github,
      api_token: "github-token",
      api_base_url: "http://localhost:#{bypass.port}"
    )

    Bypass.expect_once(bypass, "POST", "/repos/acme/widgets/issues/42/comments", fn conn ->
      assert ["Bearer github-token"] == Plug.Conn.get_req_header(conn, "authorization")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["body"] == "Ship it"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          "id" => 99,
          "html_url" => "https://github.com/acme/widgets/issues/42#issuecomment-99",
          "body" => "Ship it"
        })
      )
    end)

    assert {:ok, %{comment: %{"id" => 99}}} =
             GitHubCreateIssueComment.execute(%{
               "owner" => "acme",
               "repo" => "widgets",
               "issue_number" => 42,
               "body" => "Ship it"
             })
  end

  test "SlackPostMessage posts to a connected workspace" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")

    assert {:ok, _token} =
             OAuth.store_tokens("user-1", "slack:T123", %{
               access_token: "slack-token",
               scopes: ["chat:write"]
             })

    Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
      assert ["Bearer slack-token"] == Plug.Conn.get_req_header(conn, "authorization")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["channel"] == "C456"
      assert request["text"] == "Heads up"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "ts" => "123.456"}))
    end)

    assert {:ok, %{source: "slack", ts: "123.456"}} =
             SlackPostMessage.execute(%{
               "user_id" => "user-1",
               "team_id" => "T123",
               "channel" => "C456",
               "text" => "Heads up"
             })
  end

  test "LinearCreateComment creates a comment for a connected user" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :linear, api_url: "http://localhost:#{bypass.port}/graphql")

    assert {:ok, _token} =
             OAuth.store_tokens("user-1", "linear", %{
               access_token: "linear-token",
               scopes: ["read", "write"]
             })

    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      assert ["Bearer linear-token"] == Plug.Conn.get_req_header(conn, "authorization")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["query"] =~ "commentCreate"
      assert request["variables"]["input"]["issueId"] == "issue-1"
      assert request["variables"]["input"]["body"] == "Needs follow-up"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "commentCreate" => %{
              "success" => true,
              "comment" => %{
                "id" => "comment-1",
                "body" => "Needs follow-up",
                "url" => "https://linear.app"
              }
            }
          }
        })
      )
    end)

    assert {:ok, %{comment: %{"id" => "comment-1"}}} =
             LinearCreateComment.execute(%{
               "user_id" => "user-1",
               "issue_id" => "issue-1",
               "body" => "Needs follow-up"
             })
  end

  test "LinearCreateIssue creates an issue for a connected user" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :linear, api_url: "http://localhost:#{bypass.port}/graphql")

    assert {:ok, _token} =
             OAuth.store_tokens("user-2", "linear", %{
               access_token: "linear-token",
               scopes: ["read", "write"]
             })

    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["query"] =~ "issueCreate"
      assert request["variables"]["input"]["teamId"] == "team-1"
      assert request["variables"]["input"]["title"] == "Add automation"
      assert request["variables"]["input"]["labelIds"] == ["label-1", "label-2"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "issue-99",
                "identifier" => "ENG-99",
                "title" => "Add automation",
                "url" => "https://linear.app"
              }
            }
          }
        })
      )
    end)

    assert {:ok, %{issue: %{"id" => "issue-99"}}} =
             LinearCreateIssue.execute(%{
               "user_id" => "user-2",
               "team_id" => "team-1",
               "title" => "Add automation",
               "label_ids" => "label-1,label-2"
             })
  end

  test "LinearUpdateIssueState updates issue state for a connected user" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :linear, api_url: "http://localhost:#{bypass.port}/graphql")

    assert {:ok, _token} =
             OAuth.store_tokens("user-3", "linear", %{
               access_token: "linear-token",
               scopes: ["read", "write"]
             })

    Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["query"] =~ "issueUpdate"
      assert request["variables"]["id"] == "issue-7"
      assert request["variables"]["input"]["stateId"] == "state-done"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueUpdate" => %{
              "success" => true,
              "issue" => %{
                "id" => "issue-7",
                "identifier" => "ENG-7",
                "state" => %{"name" => "Done", "type" => "completed"}
              }
            }
          }
        })
      )
    end)

    assert {:ok, %{issue: %{"state" => %{"name" => "Done"}}}} =
             LinearUpdateIssueState.execute(%{
               "user_id" => "user-3",
               "issue_id" => "issue-7",
               "state_id" => "state-done"
             })
  end
end
