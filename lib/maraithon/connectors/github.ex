defmodule Maraithon.Connectors.GitHub do
  @moduledoc """
  GitHub webhook connector.

  Receives GitHub webhooks and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `github:{owner}/{repo}`

  Example: `github:acme/widgets`

  ## Supported Events

  - `issues.opened` → `issue_opened`
  - `issues.closed` → `issue_closed`
  - `issues.reopened` → `issue_reopened`
  - `issues.labeled` → `issue_labeled`
  - `pull_request.opened` → `pr_opened`
  - `pull_request.closed` → `pr_closed` or `pr_merged`
  - `pull_request.review_requested` → `pr_review_requested`
  - `push` → `push`
  - `create` → `branch_created` or `tag_created`
  - `delete` → `branch_deleted` or `tag_deleted`
  - `issue_comment.created` → `comment_created`

  ## Configuration

      config :maraithon, :github,
        webhook_secret: "your_webhook_secret"

  ## Webhook Setup

  1. Go to your repo's Settings → Webhooks
  2. Add webhook URL: `https://your-domain.com/webhooks/github`
  3. Content type: `application/json`
  4. Secret: Match your config
  5. Select events you want to receive
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.Connectors.Connector

  require Logger

  @impl true
  def verify_signature(conn, raw_body) do
    secret = get_webhook_secret()

    case Plug.Conn.get_req_header(conn, "x-hub-signature-256") do
      ["sha256=" <> signature] ->
        if secret == "" do
          # No secret configured but signature provided - can't verify
          if allow_unsigned?() do
            :ok
          else
            {:error, :webhook_secret_not_configured}
          end
        else
          expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

          if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
            :ok
          else
            {:error, :invalid_signature}
          end
        end

      [] ->
        # No signature header - only allow if explicitly configured
        if allow_unsigned?() do
          :ok
        else
          {:error, :missing_signature}
        end

      _ ->
        {:error, :invalid_signature_format}
    end
  end

  @impl true
  def handle_webhook(conn, params) do
    event_type = get_github_event(conn)
    repo = get_in(params, ["repository", "full_name"])

    if is_nil(repo) do
      # Some events like "ping" don't have a repository
      if event_type == "ping" do
        {:ignore, "ping event"}
      else
        {:error, :missing_repository}
      end
    else
      topic = "github:#{repo}"

      case parse_event(event_type, params) do
        {:ok, event} ->
          Logger.info("GitHub webhook received",
            event_type: event.type,
            repo: repo
          )
          {:ok, topic, event}

        {:ignore, reason} ->
          {:ignore, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ===========================================================================
  # Event Parsing
  # ===========================================================================

  defp parse_event("issues", %{"action" => action} = params) do
    issue = params["issue"]

    event_type =
      case action do
        "opened" -> "issue_opened"
        "closed" -> "issue_closed"
        "reopened" -> "issue_reopened"
        "labeled" -> "issue_labeled"
        "unlabeled" -> "issue_unlabeled"
        "assigned" -> "issue_assigned"
        _ -> "issue_#{action}"
      end

    data = %{
      issue_number: issue["number"],
      title: issue["title"],
      body: issue["body"],
      author: get_in(issue, ["user", "login"]),
      labels: Enum.map(issue["labels"] || [], & &1["name"]),
      state: issue["state"],
      url: issue["html_url"]
    }

    {:ok, Connector.build_event(event_type, "github", data, params)}
  end

  defp parse_event("pull_request", %{"action" => action} = params) do
    pr = params["pull_request"]

    event_type =
      case action do
        "opened" -> "pr_opened"
        "closed" ->
          if pr["merged"], do: "pr_merged", else: "pr_closed"
        "reopened" -> "pr_reopened"
        "review_requested" -> "pr_review_requested"
        "synchronize" -> "pr_updated"
        _ -> "pr_#{action}"
      end

    data = %{
      pr_number: pr["number"],
      title: pr["title"],
      body: pr["body"],
      author: get_in(pr, ["user", "login"]),
      head_branch: get_in(pr, ["head", "ref"]),
      base_branch: get_in(pr, ["base", "ref"]),
      state: pr["state"],
      merged: pr["merged"],
      url: pr["html_url"],
      additions: pr["additions"],
      deletions: pr["deletions"],
      changed_files: pr["changed_files"]
    }

    {:ok, Connector.build_event(event_type, "github", data, params)}
  end

  defp parse_event("push", params) do
    commits = params["commits"] || []

    data = %{
      ref: params["ref"],
      branch: parse_branch(params["ref"]),
      before: params["before"],
      after: params["after"],
      pusher: get_in(params, ["pusher", "name"]),
      commits: Enum.map(commits, fn c ->
        %{
          sha: c["id"],
          message: c["message"],
          author: get_in(c, ["author", "name"]),
          url: c["url"],
          added: c["added"],
          modified: c["modified"],
          removed: c["removed"]
        }
      end),
      commit_count: length(commits),
      forced: params["forced"]
    }

    {:ok, Connector.build_event("push", "github", data, params)}
  end

  defp parse_event("issue_comment", %{"action" => "created"} = params) do
    comment = params["comment"]
    issue = params["issue"]

    data = %{
      comment_id: comment["id"],
      body: comment["body"],
      author: get_in(comment, ["user", "login"]),
      issue_number: issue["number"],
      issue_title: issue["title"],
      url: comment["html_url"]
    }

    {:ok, Connector.build_event("comment_created", "github", data, params)}
  end

  defp parse_event("create", params) do
    ref_type = params["ref_type"]

    event_type =
      case ref_type do
        "branch" -> "branch_created"
        "tag" -> "tag_created"
        _ -> "ref_created"
      end

    data = %{
      ref: params["ref"],
      ref_type: ref_type,
      description: params["description"]
    }

    {:ok, Connector.build_event(event_type, "github", data, params)}
  end

  defp parse_event("delete", params) do
    ref_type = params["ref_type"]

    event_type =
      case ref_type do
        "branch" -> "branch_deleted"
        "tag" -> "tag_deleted"
        _ -> "ref_deleted"
      end

    data = %{
      ref: params["ref"],
      ref_type: ref_type
    }

    {:ok, Connector.build_event(event_type, "github", data, params)}
  end

  defp parse_event("ping", _params) do
    {:ignore, "ping event"}
  end

  defp parse_event(event_type, params) do
    # Generic handler for other events
    data = %{
      action: params["action"],
      sender: get_in(params, ["sender", "login"])
    }

    {:ok, Connector.build_event(event_type, "github", data, params)}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp get_github_event(conn) do
    case Plug.Conn.get_req_header(conn, "x-github-event") do
      [event] -> event
      _ -> "unknown"
    end
  end

  defp get_webhook_secret do
    Application.get_env(:maraithon, :github, [])
    |> Keyword.get(:webhook_secret, "")
  end

  defp allow_unsigned? do
    Application.get_env(:maraithon, :github, [])
    |> Keyword.get(:allow_unsigned, false)
  end

  defp parse_branch("refs/heads/" <> branch), do: branch
  defp parse_branch(ref), do: ref
end
