defmodule Maraithon.Connectors.GitHubTest do
  # Non-async due to application config modification
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Maraithon.Connectors.GitHub

  describe "verify_signature/2" do
    setup do
      Application.put_env(:maraithon, :github, webhook_secret: "test_webhook_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :github) end)
      :ok
    end

    test "returns :ok for valid signature" do
      secret = "test_webhook_secret"
      payload = ~s({"action": "opened"})

      signature =
        :crypto.mac(:hmac, :sha256, secret, payload)
        |> Base.encode16(case: :lower)

      conn =
        conn(:post, "/webhooks/github", payload)
        |> put_req_header("x-hub-signature-256", "sha256=#{signature}")

      assert :ok = GitHub.verify_signature(conn, payload)
    end

    test "returns error for invalid signature" do
      payload = ~s({"action": "opened"})

      conn =
        conn(:post, "/webhooks/github", payload)
        |> put_req_header("x-hub-signature-256", "sha256=invalid_signature")

      assert {:error, :invalid_signature} = GitHub.verify_signature(conn, payload)
    end

    test "returns error for missing signature header" do
      payload = ~s({"action": "opened"})
      conn = conn(:post, "/webhooks/github", payload)

      assert {:error, :missing_signature} = GitHub.verify_signature(conn, payload)
    end

    test "returns error when secret not configured and signature provided" do
      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: false)

      payload = ~s({"action": "opened"})

      conn =
        conn(:post, "/webhooks/github", payload)
        |> put_req_header("x-hub-signature-256", "sha256=some_signature")

      assert {:error, :webhook_secret_not_configured} = GitHub.verify_signature(conn, payload)
    end
  end

  describe "handle_webhook/2" do
    test "parses push event" do
      params = %{
        "ref" => "refs/heads/main",
        "repository" => %{
          "full_name" => "owner/repo"
        },
        "commits" => [
          %{"id" => "abc123", "message" => "Test commit", "author" => %{"name" => "Dev"}}
        ],
        "pusher" => %{"name" => "testuser"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "push")

      {:ok, topic, event} = GitHub.handle_webhook(conn, params)

      assert topic == "github:owner/repo"
      assert event.type == "push"
      assert event.source == "github"
      assert event.data.ref == "refs/heads/main"
      assert event.data.branch == "main"
    end

    test "parses pull_request opened event" do
      params = %{
        "action" => "opened",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "body" => "PR description",
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature-branch"},
          "base" => %{"ref" => "main"},
          "state" => "open",
          "merged" => false,
          "html_url" => "https://github.com/owner/repo/pull/42"
        },
        "repository" => %{
          "full_name" => "owner/repo"
        }
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, topic, event} = GitHub.handle_webhook(conn, params)

      assert topic == "github:owner/repo"
      assert event.type == "pr_opened"
      assert event.data.pr_number == 42
      assert event.data.title == "Test PR"
    end

    test "parses issues opened event" do
      params = %{
        "action" => "opened",
        "issue" => %{
          "number" => 123,
          "title" => "Bug report",
          "body" => "Description",
          "user" => %{"login" => "reporter"},
          "state" => "open",
          "labels" => [],
          "html_url" => "https://github.com/owner/repo/issues/123"
        },
        "repository" => %{
          "full_name" => "owner/repo"
        }
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      {:ok, topic, event} = GitHub.handle_webhook(conn, params)

      assert topic == "github:owner/repo"
      assert event.type == "issue_opened"
      assert event.data.issue_number == 123
    end

    test "parses issue_comment created event" do
      params = %{
        "action" => "created",
        "issue" => %{
          "number" => 123,
          "title" => "Parent issue"
        },
        "comment" => %{
          "id" => 456,
          "body" => "This is a comment",
          "user" => %{"login" => "commenter"},
          "html_url" => "https://github.com/owner/repo/issues/123#comment-456"
        },
        "repository" => %{
          "full_name" => "owner/repo"
        }
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issue_comment")

      {:ok, topic, event} = GitHub.handle_webhook(conn, params)

      assert topic == "github:owner/repo"
      assert event.type == "comment_created"
      assert event.data.issue_number == 123
      assert event.data.body == "This is a comment"
    end

    test "parses create branch event" do
      params = %{
        "ref" => "new-feature",
        "ref_type" => "branch",
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "create")

      {:ok, topic, event} = GitHub.handle_webhook(conn, params)

      assert topic == "github:owner/repo"
      assert event.type == "branch_created"
    end

    test "handles ping event" do
      params = %{
        "zen" => "Keep it logically awesome.",
        "hook_id" => 12345,
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "ping")

      assert {:ignore, "ping event"} = GitHub.handle_webhook(conn, params)
    end

    test "parses pull_request closed (merged) event" do
      params = %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "body" => "PR description",
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature"},
          "base" => %{"ref" => "main"},
          "state" => "closed",
          "merged" => true,
          "html_url" => "https://github.com/owner/repo/pull/42"
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "pr_merged"
    end

    test "parses pull_request closed (not merged) event" do
      params = %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "merged" => false,
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature"},
          "base" => %{"ref" => "main"},
          "state" => "closed"
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "pr_closed"
    end

    test "parses pull_request reopened event" do
      params = %{
        "action" => "reopened",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature"},
          "base" => %{"ref" => "main"},
          "state" => "open"
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "pr_reopened"
    end

    test "parses pull_request review_requested event" do
      params = %{
        "action" => "review_requested",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature"},
          "base" => %{"ref" => "main"}
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "pr_review_requested"
    end

    test "parses pull_request synchronize event" do
      params = %{
        "action" => "synchronize",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature"},
          "base" => %{"ref" => "main"}
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "pr_updated"
    end

    test "parses issues closed event" do
      params = %{
        "action" => "closed",
        "issue" => %{
          "number" => 123,
          "title" => "Bug report",
          "user" => %{"login" => "reporter"},
          "state" => "closed",
          "labels" => []
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "issue_closed"
    end

    test "parses issues reopened event" do
      params = %{
        "action" => "reopened",
        "issue" => %{
          "number" => 123,
          "title" => "Bug report",
          "user" => %{"login" => "reporter"},
          "state" => "open",
          "labels" => []
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "issue_reopened"
    end

    test "parses issues labeled event" do
      params = %{
        "action" => "labeled",
        "issue" => %{
          "number" => 123,
          "title" => "Bug report",
          "user" => %{"login" => "reporter"},
          "state" => "open",
          "labels" => [%{"name" => "bug"}]
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "issue_labeled"
      assert event.data.labels == ["bug"]
    end

    test "parses delete branch event" do
      params = %{
        "ref" => "old-feature",
        "ref_type" => "branch",
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "delete")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "branch_deleted"
    end

    test "parses create tag event" do
      params = %{
        "ref" => "v1.0.0",
        "ref_type" => "tag",
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "create")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "tag_created"
    end

    test "parses delete tag event" do
      params = %{
        "ref" => "v0.9.0",
        "ref_type" => "tag",
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "delete")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "tag_deleted"
    end

    test "returns error for missing repository" do
      params = %{
        "action" => "opened"
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      assert {:error, :missing_repository} = GitHub.handle_webhook(conn, params)
    end

    test "handles ping without repository" do
      params = %{
        "zen" => "Keep it logically awesome.",
        "hook_id" => 12345
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "ping")

      assert {:ignore, "ping event"} = GitHub.handle_webhook(conn, params)
    end

    test "handles unknown event type" do
      params = %{
        "action" => "test",
        "sender" => %{"login" => "testuser"},
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "custom_event")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "custom_event"
    end

    test "handles event without x-github-event header" do
      params = %{
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn = conn(:post, "/webhooks/github", params)

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "unknown"
    end
  end

  describe "verify_signature/2 with allow_unsigned" do
    test "returns ok when allow_unsigned and no signature" do
      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
      on_exit(fn -> Application.delete_env(:maraithon, :github) end)

      payload = ~s({"action": "opened"})
      conn = conn(:post, "/webhooks/github", payload)

      assert :ok = GitHub.verify_signature(conn, payload)
    end

    test "returns ok when allow_unsigned and signature present but no secret" do
      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
      on_exit(fn -> Application.delete_env(:maraithon, :github) end)

      payload = ~s({"action": "opened"})

      conn =
        conn(:post, "/webhooks/github", payload)
        |> put_req_header("x-hub-signature-256", "sha256=anything")

      assert :ok = GitHub.verify_signature(conn, payload)
    end
  end

  describe "handle_webhook/2 - additional events" do
    test "parses issues unlabeled event" do
      params = %{
        "action" => "unlabeled",
        "issue" => %{
          "number" => 123,
          "title" => "Bug report",
          "user" => %{"login" => "reporter"},
          "state" => "open",
          "labels" => []
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "issue_unlabeled"
    end

    test "parses issues assigned event" do
      params = %{
        "action" => "assigned",
        "issue" => %{
          "number" => 123,
          "title" => "Bug report",
          "user" => %{"login" => "reporter"},
          "state" => "open",
          "labels" => []
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "issues")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "issue_assigned"
    end

    test "parses unknown pull_request action" do
      params = %{
        "action" => "edited",
        "pull_request" => %{
          "number" => 42,
          "title" => "Test PR",
          "user" => %{"login" => "testuser"},
          "head" => %{"ref" => "feature"},
          "base" => %{"ref" => "main"},
          "state" => "open"
        },
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "pull_request")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "pr_edited"
    end

    test "handles create unknown ref type" do
      params = %{
        "ref" => "some-ref",
        "ref_type" => "unknown",
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "create")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "ref_created"
    end

    test "handles delete unknown ref type" do
      params = %{
        "ref" => "some-ref",
        "ref_type" => "unknown",
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "delete")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "ref_deleted"
    end

    test "parses push event with commit details" do
      params = %{
        "ref" => "refs/heads/main",
        "before" => "abc123",
        "after" => "def456",
        "forced" => false,
        "repository" => %{"full_name" => "owner/repo"},
        "pusher" => %{"name" => "testuser"},
        "commits" => [
          %{
            "id" => "abc123",
            "message" => "Test commit",
            "author" => %{"name" => "Dev"},
            "url" => "https://github.com/owner/repo/commit/abc123",
            "added" => ["new_file.txt"],
            "modified" => ["existing_file.txt"],
            "removed" => ["old_file.txt"]
          }
        ]
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "push")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "push"
      assert event.data.branch == "main"
      assert event.data.commit_count == 1
      assert length(event.data.commits) == 1
    end

    test "parses push event without ref prefix" do
      params = %{
        "ref" => "main",
        "repository" => %{"full_name" => "owner/repo"},
        "commits" => []
      }

      conn =
        conn(:post, "/webhooks/github", params)
        |> put_req_header("x-github-event", "push")

      {:ok, _topic, event} = GitHub.handle_webhook(conn, params)

      assert event.type == "push"
      # Should keep ref as-is if no prefix
      assert event.data.branch == "main"
    end
  end
end
