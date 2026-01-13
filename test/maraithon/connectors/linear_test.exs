defmodule Maraithon.Connectors.LinearTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Maraithon.Connectors.Linear

  describe "handle_webhook/2" do
    test "parses Issue create event" do
      params = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Bug report",
          "description" => "Something is broken",
          "state" => %{"name" => "Todo"},
          "team" => %{"key" => "ENG"},
          "assignee" => %{"name" => "John Doe"},
          "labels" => [%{"name" => "bug"}]
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, topic, event} = Linear.handle_webhook(conn, params)

      # Topic is based on team.key
      assert topic == "linear:ENG"
      assert event.type == "issue_created"
      assert event.source == "linear"
      assert event.data.issue_id == "issue-123"
      assert event.data.title == "Bug report"
    end

    test "parses Issue update event" do
      params = %{
        "action" => "update",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Updated title",
          "state" => %{"name" => "In Progress"},
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, topic, event} = Linear.handle_webhook(conn, params)

      assert topic == "linear:ENG"
      assert event.type == "issue_updated"
    end

    test "parses Comment create event" do
      params = %{
        "action" => "create",
        "type" => "Comment",
        "data" => %{
          "id" => "comment-123",
          "body" => "This is a comment",
          "issue" => %{
            "id" => "issue-456",
            "title" => "Parent issue",
            "team" => %{"key" => "ENG"}
          },
          "user" => %{"name" => "Commenter"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, topic, event} = Linear.handle_webhook(conn, params)

      assert topic == "linear:ENG"
      assert event.type == "comment_created"
      assert event.data.comment_id == "comment-123"
      assert event.data.body == "This is a comment"
    end

    test "parses Project update event" do
      params = %{
        "action" => "update",
        "type" => "Project",
        "data" => %{
          "id" => "project-123",
          "name" => "Q1 Roadmap",
          "state" => "started",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, topic, event} = Linear.handle_webhook(conn, params)

      assert topic == "linear:ENG"
      assert event.type == "project_updated"
    end

    test "handles Cycle events" do
      params = %{
        "action" => "create",
        "type" => "Cycle",
        "data" => %{
          "id" => "cycle-123",
          "name" => "Sprint 1",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "cycle_created"
    end

    test "returns ignore for events without team info" do
      params = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Bug report"
          # No team info
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      assert {:ignore, "no team info"} = Linear.handle_webhook(conn, params)
    end

    test "parses Issue remove event" do
      params = %{
        "action" => "remove",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Deleted issue",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "issue_removed"
    end

    test "parses Comment update event" do
      params = %{
        "action" => "update",
        "type" => "Comment",
        "data" => %{
          "id" => "comment-123",
          "body" => "Updated comment",
          "issue" => %{
            "id" => "issue-456",
            "title" => "Parent issue",
            "team" => %{"key" => "ENG"}
          },
          "user" => %{"name" => "Commenter"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "comment_updated"
    end

    test "parses Comment remove event" do
      params = %{
        "action" => "remove",
        "type" => "Comment",
        "data" => %{
          "id" => "comment-123",
          "body" => "Deleted comment",
          "issue" => %{
            "id" => "issue-456",
            "team" => %{"key" => "ENG"}
          }
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "comment_removed"
    end

    test "parses Project create event" do
      params = %{
        "action" => "create",
        "type" => "Project",
        "data" => %{
          "id" => "project-123",
          "name" => "New Project",
          "state" => "planned",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "project_created"
    end

    test "parses Cycle update event" do
      params = %{
        "action" => "update",
        "type" => "Cycle",
        "data" => %{
          "id" => "cycle-123",
          "name" => "Sprint 1 Updated",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "cycle_updated"
    end

    test "parses IssueLabel create event" do
      params = %{
        "action" => "create",
        "type" => "IssueLabel",
        "data" => %{
          "id" => "label-123",
          "name" => "urgent",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "label_created"
    end

    test "handles unknown event type" do
      params = %{
        "action" => "create",
        "type" => "CustomType",
        "data" => %{
          "id" => "custom-123",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "customtype_create"
    end

    test "extracts team key from issue" do
      params = %{
        "action" => "create",
        "type" => "Comment",
        "data" => %{
          "id" => "comment-123",
          "body" => "Test comment",
          "issue" => %{
            "id" => "issue-456",
            "team" => %{"key" => "DESIGN"}
          }
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, topic, _event} = Linear.handle_webhook(conn, params)

      assert topic == "linear:DESIGN"
    end
  end

  describe "verify_signature/2" do
    test "returns ok when no signature and no secret configured" do
      Application.put_env(:maraithon, :linear, webhook_secret: "")
      on_exit(fn -> Application.delete_env(:maraithon, :linear) end)

      conn = conn(:post, "/webhooks/linear", %{})

      assert :ok = Linear.verify_signature(conn, "{}")
    end

    test "returns error when secret configured but no signature" do
      Application.put_env(:maraithon, :linear, webhook_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :linear) end)

      conn = conn(:post, "/webhooks/linear", %{})

      assert {:error, :missing_signature} = Linear.verify_signature(conn, "{}")
    end
  end

  describe "handle_webhook/2 - issue events with project key" do
    test "parses Issue event with project key in topic" do
      params = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Bug report",
          "team" => %{"key" => "ENG"},
          "project" => %{"key" => "BACKEND", "name" => "Backend"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, topic, event} = Linear.handle_webhook(conn, params)

      assert topic == "linear:ENG:BACKEND"
      assert event.data.project_key == "BACKEND"
    end

    test "parses Issue update with changes" do
      params = %{
        "action" => "update",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Updated title",
          "state" => %{"name" => "In Progress", "type" => "started"},
          "team" => %{"key" => "ENG"}
        },
        "updatedFrom" => %{
          "state" => %{"name" => "Todo"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "issue_updated"
      assert event.data.changes != nil
      assert event.data.changes["state"]["name"] == "Todo"
    end
  end

  describe "handle_webhook/2 - project events" do
    test "parses Project remove event" do
      params = %{
        "action" => "remove",
        "type" => "Project",
        "data" => %{
          "id" => "project-123",
          "name" => "Deleted Project",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "project_removed"
    end
  end

  describe "handle_webhook/2 - cycle events" do
    test "parses Cycle remove event" do
      params = %{
        "action" => "remove",
        "type" => "Cycle",
        "data" => %{
          "id" => "cycle-123",
          "name" => "Sprint 1",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "cycle_removed"
    end
  end

  describe "handle_webhook/2 - label events" do
    test "parses IssueLabel update event" do
      params = %{
        "action" => "update",
        "type" => "IssueLabel",
        "data" => %{
          "id" => "label-123",
          "name" => "high-priority",
          "color" => "#ff0000",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "label_updated"
    end

    test "parses IssueLabel remove event" do
      params = %{
        "action" => "remove",
        "type" => "IssueLabel",
        "data" => %{
          "id" => "label-123",
          "name" => "deprecated-label",
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.type == "label_removed"
    end
  end

  describe "handle_webhook/2 - issue with labels" do
    test "extracts labels from issue" do
      params = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Bug with labels",
          "team" => %{"key" => "ENG"},
          "labels" => [
            %{"id" => "l1", "name" => "bug", "color" => "#ff0000"},
            %{"id" => "l2", "name" => "urgent", "color" => "#ffaa00"}
          ]
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert length(event.data.labels) == 2
      assert Enum.any?(event.data.labels, fn l -> l.name == "bug" end)
    end

    test "handles nil labels" do
      params = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue-123",
          "title" => "Issue without labels",
          "team" => %{"key" => "ENG"},
          "labels" => nil
        },
        "organizationId" => "org-123"
      }

      conn = conn(:post, "/webhooks/linear", params)

      {:ok, _topic, event} = Linear.handle_webhook(conn, params)

      assert event.data.labels == []
    end
  end

  # ===========================================================================
  # API Function Tests
  # ===========================================================================

  describe "create_issue/4" do
    test "creates an issue successfully" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "issue-new-123",
                "identifier" => "ENG-123",
                "title" => "New Issue",
                "url" => "https://linear.app/team/issue/ENG-123"
              }
            }
          }
        }))
      end)

      {:ok, issue} = Linear.create_issue("access_token", "team-123", "New Issue")

      assert issue["id"] == "issue-new-123"
      assert issue["identifier"] == "ENG-123"

      Application.delete_env(:maraithon, :linear)
    end

    test "creates an issue with options" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        # Verify options are included
        assert request["variables"]["input"]["description"] == "Test description"
        assert request["variables"]["input"]["priority"] == 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "issue-456",
                "identifier" => "ENG-456",
                "title" => "Issue with opts",
                "url" => "https://linear.app/team/issue/ENG-456"
              }
            }
          }
        }))
      end)

      {:ok, issue} = Linear.create_issue("token", "team-123", "Issue with opts",
        description: "Test description",
        priority: 1
      )

      assert issue["identifier"] == "ENG-456"

      Application.delete_env(:maraithon, :linear)
    end

    test "returns error when create fails" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => false
            }
          }
        }))
      end)

      assert {:error, :create_failed} = Linear.create_issue("token", "team-123", "Failing Issue")

      Application.delete_env(:maraithon, :linear)
    end
  end

  describe "create_comment/3" do
    test "creates a comment successfully" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "commentCreate" => %{
              "success" => true,
              "comment" => %{
                "id" => "comment-123",
                "body" => "New comment",
                "url" => "https://linear.app/issue/comment"
              }
            }
          }
        }))
      end)

      {:ok, comment} = Linear.create_comment("token", "issue-123", "New comment")

      assert comment["id"] == "comment-123"
      assert comment["body"] == "New comment"

      Application.delete_env(:maraithon, :linear)
    end

    test "returns error when comment create fails" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "commentCreate" => %{
              "success" => false
            }
          }
        }))
      end)

      assert {:error, :create_failed} = Linear.create_comment("token", "issue-123", "Failing")

      Application.delete_env(:maraithon, :linear)
    end
  end

  describe "update_issue_state/3" do
    test "updates issue state successfully" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "issueUpdate" => %{
              "success" => true,
              "issue" => %{
                "id" => "issue-123",
                "identifier" => "ENG-123",
                "state" => %{
                  "name" => "Done",
                  "type" => "completed"
                }
              }
            }
          }
        }))
      end)

      {:ok, issue} = Linear.update_issue_state("token", "issue-123", "state-done")

      assert issue["state"]["name"] == "Done"

      Application.delete_env(:maraithon, :linear)
    end

    test "returns error when update fails" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "issueUpdate" => %{
              "success" => false
            }
          }
        }))
      end)

      assert {:error, :update_failed} = Linear.update_issue_state("token", "issue-123", "state-invalid")

      Application.delete_env(:maraithon, :linear)
    end
  end

  describe "get_teams/1" do
    test "returns teams successfully" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :linear,
        api_url: "http://localhost:#{bypass.port}/graphql"
      )

      Bypass.expect_once(bypass, "POST", "/graphql", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "teams" => %{
              "nodes" => [
                %{"id" => "team1", "key" => "ENG", "name" => "Engineering"},
                %{"id" => "team2", "key" => "DES", "name" => "Design"}
              ]
            }
          }
        }))
      end)

      {:ok, teams} = Linear.get_teams("token")

      assert length(teams) == 2
      assert Enum.any?(teams, fn t -> t["key"] == "ENG" end)

      Application.delete_env(:maraithon, :linear)
    end
  end
end
