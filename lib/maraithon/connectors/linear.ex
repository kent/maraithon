defmodule Maraithon.Connectors.Linear do
  @moduledoc """
  Linear webhook connector.

  Receives Linear webhooks and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `linear:{team_key}` or `linear:{team_key}:{project_key}`

  Example: `linear:eng` or `linear:eng:backend`

  ## Event Types

  - `issue_created` - New issue created
  - `issue_updated` - Issue updated (status, assignee, etc.)
  - `issue_removed` - Issue deleted
  - `comment_created` - Comment added to issue
  - `comment_updated` - Comment edited
  - `comment_removed` - Comment deleted
  - `project_created` - New project created
  - `project_updated` - Project updated
  - `cycle_created` - New cycle/sprint created
  - `cycle_updated` - Cycle updated

  ## How it Works

  1. Create a Linear OAuth app or use API key
  2. Configure webhook in Linear settings
  3. Point webhook URL to `/webhooks/linear`
  4. Set webhook secret to match config
  5. Linear sends events to your webhook

  ## Configuration

      config :maraithon, :linear,
        webhook_secret: "your_webhook_secret"
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.OAuth.Linear, as: LinearOAuth
  alias Maraithon.Connectors.Connector

  require Logger

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(conn, raw_body) do
    signature = get_header(conn, "linear-signature")

    if is_nil(signature) do
      # Check if webhook secret is configured
      webhook_secret = get_webhook_secret()

      if webhook_secret == "" do
        :ok
      else
        {:error, :missing_signature}
      end
    else
      LinearOAuth.verify_signature(raw_body, signature)
    end
  end

  @impl true
  def handle_webhook(_conn, params) do
    action = params["action"]
    type = params["type"]
    data = params["data"]

    # Extract team info for topic
    team_key = extract_team_key(data)

    if is_nil(team_key) do
      {:ignore, "no team info"}
    else
      case type do
        "Issue" ->
          handle_issue_event(action, data, team_key, params)

        "Comment" ->
          handle_comment_event(action, data, team_key, params)

        "Project" ->
          handle_project_event(action, data, team_key, params)

        "Cycle" ->
          handle_cycle_event(action, data, team_key, params)

        "IssueLabel" ->
          handle_label_event(action, data, team_key, params)

        _ ->
          # Generic handler for other types
          topic = "linear:#{team_key}"
          event_type = "#{String.downcase(type)}_#{action}"

          normalized = Connector.build_event(event_type, "linear", %{
            type: type,
            action: action,
            data: data
          }, params)

          {:ok, topic, normalized}
      end
    end
  end

  # ===========================================================================
  # Event Handlers
  # ===========================================================================

  defp handle_issue_event(action, data, team_key, params) do
    project_key = get_in(data, ["project", "key"])

    topic =
      if project_key do
        "linear:#{team_key}:#{project_key}"
      else
        "linear:#{team_key}"
      end

    event_type =
      case action do
        "create" -> "issue_created"
        "update" -> "issue_updated"
        "remove" -> "issue_removed"
        _ -> "issue_#{action}"
      end

    issue_data = %{
      issue_id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      description: data["description"],
      priority: data["priority"],
      state: get_in(data, ["state", "name"]),
      state_type: get_in(data, ["state", "type"]),
      assignee: get_in(data, ["assignee", "name"]),
      assignee_email: get_in(data, ["assignee", "email"]),
      creator: get_in(data, ["creator", "name"]),
      project: get_in(data, ["project", "name"]),
      project_key: project_key,
      team_key: team_key,
      labels: extract_labels(data["labels"]),
      estimate: data["estimate"],
      due_date: data["dueDate"],
      url: data["url"],
      created_at: data["createdAt"],
      updated_at: data["updatedAt"]
    }

    # Include what changed for updates
    issue_data =
      if action == "update" and params["updatedFrom"] do
        Map.put(issue_data, :changes, params["updatedFrom"])
      else
        issue_data
      end

    normalized = Connector.build_event(event_type, "linear", issue_data, params)

    Logger.info("Linear issue event",
      event: event_type,
      identifier: data["identifier"],
      team: team_key
    )

    {:ok, topic, normalized}
  end

  defp handle_comment_event(action, data, team_key, params) do
    issue = data["issue"] || %{}
    project_key = get_in(issue, ["project", "key"])

    topic =
      if project_key do
        "linear:#{team_key}:#{project_key}"
      else
        "linear:#{team_key}"
      end

    event_type =
      case action do
        "create" -> "comment_created"
        "update" -> "comment_updated"
        "remove" -> "comment_removed"
        _ -> "comment_#{action}"
      end

    comment_data = %{
      comment_id: data["id"],
      body: data["body"],
      author: get_in(data, ["user", "name"]),
      author_email: get_in(data, ["user", "email"]),
      issue_id: issue["id"],
      issue_identifier: issue["identifier"],
      issue_title: issue["title"],
      team_key: team_key,
      url: data["url"],
      created_at: data["createdAt"],
      updated_at: data["updatedAt"]
    }

    normalized = Connector.build_event(event_type, "linear", comment_data, params)

    Logger.info("Linear comment event",
      event: event_type,
      issue: issue["identifier"],
      team: team_key
    )

    {:ok, topic, normalized}
  end

  defp handle_project_event(action, data, team_key, params) do
    topic = "linear:#{team_key}"

    event_type =
      case action do
        "create" -> "project_created"
        "update" -> "project_updated"
        "remove" -> "project_removed"
        _ -> "project_#{action}"
      end

    project_data = %{
      project_id: data["id"],
      name: data["name"],
      key: data["key"],
      description: data["description"],
      state: data["state"],
      lead: get_in(data, ["lead", "name"]),
      team_key: team_key,
      start_date: data["startDate"],
      target_date: data["targetDate"],
      url: data["url"]
    }

    normalized = Connector.build_event(event_type, "linear", project_data, params)
    {:ok, topic, normalized}
  end

  defp handle_cycle_event(action, data, team_key, params) do
    topic = "linear:#{team_key}"

    event_type =
      case action do
        "create" -> "cycle_created"
        "update" -> "cycle_updated"
        "remove" -> "cycle_removed"
        _ -> "cycle_#{action}"
      end

    cycle_data = %{
      cycle_id: data["id"],
      name: data["name"],
      number: data["number"],
      team_key: team_key,
      starts_at: data["startsAt"],
      ends_at: data["endsAt"],
      completed_at: data["completedAt"]
    }

    normalized = Connector.build_event(event_type, "linear", cycle_data, params)
    {:ok, topic, normalized}
  end

  defp handle_label_event(action, data, team_key, params) do
    topic = "linear:#{team_key}"

    event_type =
      case action do
        "create" -> "label_created"
        "update" -> "label_updated"
        "remove" -> "label_removed"
        _ -> "label_#{action}"
      end

    label_data = %{
      label_id: data["id"],
      name: data["name"],
      color: data["color"],
      team_key: team_key
    }

    normalized = Connector.build_event(event_type, "linear", label_data, params)
    {:ok, topic, normalized}
  end

  # ===========================================================================
  # API Helpers
  # ===========================================================================

  @doc """
  Creates an issue in Linear.
  """
  def create_issue(access_token, team_id, title, opts \\ []) do
    query = """
    mutation CreateIssue($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue {
          id
          identifier
          title
          url
        }
      }
    }
    """

    input =
      %{
        teamId: team_id,
        title: title
      }
      |> maybe_put(:description, opts[:description])
      |> maybe_put(:priority, opts[:priority])
      |> maybe_put(:assigneeId, opts[:assignee_id])
      |> maybe_put(:projectId, opts[:project_id])
      |> maybe_put(:stateId, opts[:state_id])
      |> maybe_put(:labelIds, opts[:label_ids])

    case LinearOAuth.graphql(access_token, query, %{input: input}) do
      {:ok, %{"issueCreate" => %{"success" => true, "issue" => issue}}} ->
        {:ok, issue}

      {:ok, %{"issueCreate" => %{"success" => false}}} ->
        {:error, :create_failed}

      error ->
        error
    end
  end

  @doc """
  Adds a comment to an issue.
  """
  def create_comment(access_token, issue_id, body) do
    query = """
    mutation CreateComment($input: CommentCreateInput!) {
      commentCreate(input: $input) {
        success
        comment {
          id
          body
          url
        }
      }
    }
    """

    input = %{issueId: issue_id, body: body}

    case LinearOAuth.graphql(access_token, query, %{input: input}) do
      {:ok, %{"commentCreate" => %{"success" => true, "comment" => comment}}} ->
        {:ok, comment}

      {:ok, %{"commentCreate" => %{"success" => false}}} ->
        {:error, :create_failed}

      error ->
        error
    end
  end

  @doc """
  Updates an issue's state.
  """
  def update_issue_state(access_token, issue_id, state_id) do
    query = """
    mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) {
        success
        issue {
          id
          identifier
          state {
            name
            type
          }
        }
      }
    }
    """

    case LinearOAuth.graphql(access_token, query, %{id: issue_id, input: %{stateId: state_id}}) do
      {:ok, %{"issueUpdate" => %{"success" => true, "issue" => issue}}} ->
        {:ok, issue}

      {:ok, %{"issueUpdate" => %{"success" => false}}} ->
        {:error, :update_failed}

      error ->
        error
    end
  end

  @doc """
  Gets teams for the authenticated user.
  """
  def get_teams(access_token) do
    query = """
    query Teams {
      teams {
        nodes {
          id
          key
          name
        }
      }
    }
    """

    case LinearOAuth.graphql(access_token, query) do
      {:ok, %{"teams" => %{"nodes" => teams}}} ->
        {:ok, teams}

      error ->
        error
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp extract_team_key(data) do
    # Try to get team key from various places in the payload
    cond do
      data["team"] && data["team"]["key"] ->
        data["team"]["key"]

      data["issue"] && data["issue"]["team"] && data["issue"]["team"]["key"] ->
        data["issue"]["team"]["key"]

      true ->
        nil
    end
  end

  defp extract_labels(nil), do: []

  defp extract_labels(labels) when is_list(labels) do
    Enum.map(labels, fn l -> %{id: l["id"], name: l["name"], color: l["color"]} end)
  end

  defp extract_labels(_), do: []

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value] -> value
      _ -> nil
    end
  end

  defp get_webhook_secret do
    Application.get_env(:maraithon, :linear, [])
    |> Keyword.get(:webhook_secret, "")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
