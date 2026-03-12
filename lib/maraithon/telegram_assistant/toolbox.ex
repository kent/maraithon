defmodule Maraithon.TelegramAssistant.Toolbox do
  @moduledoc """
  Curated Telegram-safe tool surface for the unified operator assistant.
  """

  alias Maraithon.Admin
  alias Maraithon.AgentBuilder
  alias Maraithon.Agents
  alias Maraithon.Connectors.Linear
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Linear, as: LinearOAuth
  alias Maraithon.Runtime
  alias Maraithon.TelegramAssistant
  alias Maraithon.Tools

  @immediate_agent_actions ~w(start stop restart)
  @external_action_tools %{
    "gmail_send" => %{
      tool: "gmail_send_message",
      target_type: "gmail_thread"
    },
    "slack_post" => %{
      tool: "slack_post_message",
      target_type: "slack_channel"
    },
    "linear_create_issue" => %{
      tool: "linear_create_issue",
      target_type: "linear_issue"
    },
    "linear_create_comment" => %{
      tool: "linear_create_comment",
      target_type: "linear_issue"
    },
    "linear_update_issue_state" => %{
      tool: "linear_update_issue_state",
      target_type: "linear_issue"
    },
    "notaui_complete_task" => %{
      tool: "notaui_complete_task",
      target_type: "task"
    },
    "notaui_update_task" => %{
      tool: "notaui_update_task",
      target_type: "task"
    }
  }

  def tool_definitions(_context) do
    [
      tool_definition(
        "get_open_work_summary",
        "Summarize open work, recent insights, and active agents for the linked user.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 10}
          }
        }
      ),
      tool_definition(
        "inspect_open_insight",
        "Inspect one open insight or the latest linked insight detail.",
        %{
          "type" => "object",
          "properties" => %{
            "insight_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "gmail_search_messages",
        "Search Gmail threads or messages for the linked user.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "gmail_get_message",
        "Fetch one Gmail message by message id.",
        %{
          "type" => "object",
          "required" => ["message_id"],
          "properties" => %{"message_id" => %{"type" => "string"}}
        }
      ),
      tool_definition(
        "calendar_list_events",
        "List Google Calendar events for the linked user.",
        %{
          "type" => "object",
          "properties" => %{
            "calendar_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "time_min" => %{"type" => "string"},
            "time_max" => %{"type" => "string"},
            "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "slack_search_messages",
        "Search Slack message context using the linked user's connected workspace.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "team_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "slack_get_thread_context",
        "Fetch a Slack thread and replies from one channel.",
        %{
          "type" => "object",
          "required" => ["channel", "thread_ts"],
          "properties" => %{
            "team_id" => %{"type" => "string"},
            "channel" => %{"type" => "string"},
            "thread_ts" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
          }
        }
      ),
      tool_definition(
        "linear_list_or_lookup",
        "List Linear teams or look up one issue by identifier.",
        %{
          "type" => "object",
          "properties" => %{
            "identifier" => %{"type" => "string"},
            "team_id" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
          }
        }
      ),
      tool_definition(
        "notaui_list_tasks",
        "List tasks from Notaui.",
        %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{"type" => "string"},
            "statuses" => %{"type" => "array", "items" => %{"type" => "string"}},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "list_agents",
        "List the linked user's saved agents and runtime status.",
        %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string"},
            "behavior" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "inspect_agent",
        "Inspect one agent, including runtime, spend, logs, events, and queued work.",
        %{
          "type" => "object",
          "required" => ["agent_id"],
          "properties" => %{"agent_id" => %{"type" => "string"}}
        }
      ),
      tool_definition(
        "prepare_agent_action",
        "Prepare or execute an agent lifecycle or CRUD action.",
        %{
          "type" => "object",
          "required" => ["action"],
          "properties" => %{
            "action" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "launch" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "prepare_external_action",
        "Prepare a Gmail, Slack, Linear, or Notaui write action for confirmation.",
        %{
          "type" => "object",
          "required" => ["action_type", "payload"],
          "properties" => %{
            "action_type" => %{"type" => "string"},
            "payload" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "query_agent",
        "Ask a running agent a question and wait briefly for a response.",
        %{
          "type" => "object",
          "required" => ["agent_id", "message"],
          "properties" => %{
            "agent_id" => %{"type" => "string"},
            "message" => %{"type" => "string"},
            "timeout_ms" => %{"type" => "integer", "minimum" => 1000, "maximum" => 30000}
          }
        }
      )
    ]
  end

  def execute(tool_name, args, runtime_context)
      when is_binary(tool_name) and is_map(args) and is_map(runtime_context) do
    case tool_name do
      "get_open_work_summary" ->
        get_open_work_summary(runtime_context, args)

      "inspect_open_insight" ->
        inspect_open_insight(runtime_context, args)

      "gmail_search_messages" ->
        inject_user_and_execute("gmail_search", runtime_context, args)

      "gmail_get_message" ->
        inject_user_and_execute("gmail_get_message", runtime_context, args)

      "calendar_list_events" ->
        inject_user_and_execute("google_calendar_list_events", runtime_context, args)

      "slack_search_messages" ->
        slack_search(runtime_context, args)

      "slack_get_thread_context" ->
        slack_thread_context(runtime_context, args)

      "linear_list_or_lookup" ->
        linear_list_or_lookup(runtime_context, args)

      "notaui_list_tasks" ->
        Tools.execute("notaui_list_tasks", args)

      "list_agents" ->
        list_agents(runtime_context, args)

      "inspect_agent" ->
        inspect_agent(runtime_context, args)

      "prepare_agent_action" ->
        prepare_agent_action(runtime_context, args)

      "prepare_external_action" ->
        prepare_external_action(runtime_context, args)

      "query_agent" ->
        query_agent(runtime_context, args)

      _ ->
        {:error, "unknown_telegram_tool: #{tool_name}"}
    end
  end

  defp get_open_work_summary(runtime_context, args) do
    user_id = runtime_context.user_id
    limit = normalize_limit(Map.get(args, "limit"), 5, 10)

    insights =
      Insights.list_open_for_user(user_id, limit: limit)
      |> Enum.map(fn insight ->
        %{
          id: insight.id,
          title: insight.title,
          source: insight.source,
          priority: insight.priority,
          recommended_action: insight.recommended_action
        }
      end)

    agents =
      Agents.list_agents(user_id: user_id)
      |> Enum.map(fn agent ->
        %{
          id: agent.id,
          name: get_in(agent.config || %{}, ["name"]),
          behavior: agent.behavior,
          status: agent.status
        }
      end)

    {:ok,
     %{
       insight_count: length(insights),
       top_insights: insights,
       agent_count: length(agents),
       agents: agents
     }}
  end

  defp inspect_open_insight(runtime_context, args) do
    linked_item = get_in(runtime_context.context, [:linked_item])

    case Map.get(args, "insight_id") do
      insight_id when is_binary(insight_id) and insight_id != "" ->
        insight =
          Insights.list_open_with_details_for_user(runtime_context.user_id, limit: 20)
          |> Enum.find(fn %{insight: insight} -> insight.id == insight_id end)

        case insight do
          %{insight: insight, detail: detail} ->
            {:ok,
             %{
               id: insight.id,
               title: insight.title,
               summary: insight.summary,
               recommended_action: insight.recommended_action,
               detail: detail
             }}

          nil ->
            {:error, "insight_not_found"}
        end

      _ ->
        case linked_item do
          %{} = item when map_size(item) > 0 -> {:ok, item}
          _ -> {:error, "no_linked_insight"}
        end
    end
  end

  defp slack_search(runtime_context, args) do
    args =
      args
      |> Map.put("user_id", runtime_context.user_id)
      |> maybe_put_default("team_id", runtime_context.default_slack_team_id)

    Tools.execute("slack_search_messages", args)
  end

  defp slack_thread_context(runtime_context, args) do
    args =
      args
      |> Map.put("user_id", runtime_context.user_id)
      |> maybe_put_default("team_id", runtime_context.default_slack_team_id)

    Tools.execute("slack_get_thread_replies", args)
  end

  defp linear_list_or_lookup(runtime_context, args) do
    with {:ok, access_token} <- OAuth.get_valid_access_token(runtime_context.user_id, "linear") do
      case Map.get(args, "identifier") do
        identifier when is_binary(identifier) and identifier != "" ->
          lookup_linear_issue(access_token, identifier)

        _ ->
          with {:ok, teams} <- Linear.get_teams(access_token) do
            {:ok, %{teams: teams}}
          end
      end
    else
      {:error, :no_token} -> {:error, "linear_not_connected"}
      {:error, :reauth_required} -> {:error, "linear_reauth_required"}
      {:error, reason} -> {:error, "linear_lookup_failed: #{inspect(reason)}"}
    end
  end

  defp list_agents(runtime_context, args) do
    Agents.list_agents(user_id: runtime_context.user_id)
    |> Enum.filter(&matches_agent_filter?(&1, args))
    |> Enum.map(fn agent ->
      %{
        id: agent.id,
        name: get_in(agent.config || %{}, ["name"]),
        behavior: agent.behavior,
        status: agent.status,
        started_at: agent.started_at,
        updated_at: agent.updated_at
      }
    end)
    |> then(&{:ok, %{count: length(&1), agents: &1}})
  end

  defp inspect_agent(runtime_context, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} <- Agents.get_agent_for_user(agent_id, runtime_context.user_id) do
      case Admin.safe_agent_snapshot(agent_id,
             user_id: runtime_context.user_id,
             event_limit: 12,
             effect_limit: 12,
             job_limit: 12,
             log_limit: 20
           ) do
        {:ok, snapshot} -> {:ok, snapshot}
        {:degraded, snapshot} -> {:ok, Map.put(snapshot, :degraded, true)}
        {:error, :not_found} -> {:error, "agent_not_found"}
        {:error, reason} -> {:error, "agent_inspection_failed: #{inspect(reason)}"}
      end
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_agent_action(runtime_context, args) do
    with true <- TelegramAssistant.agent_control_enabled?() || {:error, "agent_control_disabled"},
         {:ok, action} <- required_string(args, "action") do
      case action do
        "create" ->
          prepare_agent_create(runtime_context, args)

        "update" ->
          prepare_agent_update(runtime_context, args)

        "delete" ->
          prepare_agent_delete(runtime_context, args)

        action when action in @immediate_agent_actions ->
          execute_immediate_agent_action(runtime_context, action, args)

        _ ->
          {:error, "unsupported_agent_action"}
      end
    else
      false -> {:error, "agent_control_disabled"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_external_action(runtime_context, args) do
    with true <- TelegramAssistant.write_tools_enabled?() || {:error, "write_tools_disabled"},
         {:ok, action_type} <- required_string(args, "action_type"),
         %{} = spec <- Map.get(@external_action_tools, action_type),
         payload when is_map(payload) <- Map.get(args, "payload", %{}) do
      executable_payload = Map.put(payload, "user_id", runtime_context.user_id)
      preview_text = external_action_preview(action_type, executable_payload)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: action_type,
        target_type: spec.target_type,
        target_id: external_target_id(action_type, executable_payload),
        payload: executable_payload,
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to confirm, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      false -> {:error, "write_tools_disabled"}
      nil -> {:error, "unsupported_external_action"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "invalid_external_payload"}
    end
  end

  defp query_agent(runtime_context, args) do
    with true <- TelegramAssistant.agent_control_enabled?() || {:error, "agent_control_disabled"},
         {:ok, agent_id} <- required_string(args, "agent_id"),
         {:ok, message} <- required_string(args, "message"),
         %{} <- Agents.get_agent_for_user(agent_id, runtime_context.user_id),
         {:ok, result} <-
           Runtime.request_response(
             agent_id,
             message,
             %{"source" => "telegram_assistant", "run_id" => runtime_context.run_id},
             timeout_ms: normalize_timeout(Map.get(args, "timeout_ms"))
           ) do
      {:ok, result}
    else
      false -> {:error, "agent_control_disabled"}
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp prepare_agent_create(runtime_context, args) do
    launch = stringify_map(Map.get(args, "launch", %{}))

    with {:ok, start_params} <- AgentBuilder.build_start_params(launch, runtime_context.user_id) do
      preview_text = create_agent_preview(start_params)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: "agent_create",
        target_type: "agent",
        payload: %{"start_params" => start_params, "launch" => launch},
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to create it, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp prepare_agent_update(runtime_context, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} = agent <- Agents.get_agent_for_user(agent_id, runtime_context.user_id) do
      launch =
        agent
        |> AgentBuilder.launch_params_from_agent()
        |> Map.merge(stringify_map(Map.get(args, "launch", %{})))

      with {:ok, update_params} <-
             AgentBuilder.build_start_params(launch, runtime_context.user_id) do
        preview_text = update_agent_preview(agent, update_params)

        expires_at =
          DateTime.add(
            DateTime.utc_now(),
            TelegramAssistant.confirmation_window_seconds(),
            :second
          )

        TelegramAssistant.create_prepared_action(%{
          user_id: runtime_context.user_id,
          chat_id: runtime_context.chat_id,
          conversation_id: runtime_context.conversation_id,
          run_id: runtime_context.run_id,
          action_type: "agent_update",
          target_type: "agent",
          target_id: agent.id,
          payload: %{
            "agent_id" => agent.id,
            "update_params" => Map.take(update_params, ["behavior", "config", "budget"]),
            "launch" => launch
          },
          preview_text: preview_text,
          status: "awaiting_confirmation",
          expires_at: expires_at
        })
        |> case do
          {:ok, prepared_action} ->
            {:ok,
             %{
               status: "awaiting_confirmation",
               prepared_action_id: prepared_action.id,
               preview_text: preview_text,
               requires_confirmation: true,
               message:
                 "#{preview_text} Reply `yes` or use the buttons to apply the update, or `no` to cancel."
             }}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_agent_delete(runtime_context, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} = agent <- Agents.get_agent_for_user(agent_id, runtime_context.user_id) do
      preview_text = delete_agent_preview(agent)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: "agent_delete",
        target_type: "agent",
        target_id: agent.id,
        payload: %{"agent_id" => agent.id},
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to delete it, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_immediate_agent_action(runtime_context, action, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} = agent <- Agents.get_agent_for_user(agent_id, runtime_context.user_id),
         {:ok, result} <- perform_agent_action(action, agent_id) do
      preview_text = immediate_agent_preview(action, agent)
      now = DateTime.utc_now()

      {:ok, prepared_action} =
        TelegramAssistant.create_prepared_action(%{
          user_id: runtime_context.user_id,
          chat_id: runtime_context.chat_id,
          conversation_id: runtime_context.conversation_id,
          run_id: runtime_context.run_id,
          action_type: "agent_#{action}",
          target_type: "agent",
          target_id: agent.id,
          payload: %{"agent_id" => agent.id},
          preview_text: preview_text,
          status: "executed",
          expires_at: now,
          confirmed_at: now,
          executed_at: now
        })

      {:ok,
       %{
         status: "executed",
         prepared_action_id: prepared_action.id,
         message: immediate_agent_result_text(action, agent, result),
         result: result
       }}
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp inject_user_and_execute(tool_name, runtime_context, args) do
    tool_name
    |> Tools.execute(Map.put(args, "user_id", runtime_context.user_id))
    |> normalize_tool_result()
  end

  defp normalize_tool_result({:ok, result}), do: {:ok, result}
  defp normalize_tool_result({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp normalize_tool_result({:error, reason}), do: {:error, inspect(reason)}

  defp lookup_linear_issue(access_token, identifier) do
    query = """
    query LookupIssue($identifier: String!) {
      issues(filter: { identifier: { eq: $identifier } }, first: 1) {
        nodes {
          id
          identifier
          title
          description
          url
          priority
          state {
            id
            name
            type
          }
          team {
            id
            key
            name
          }
        }
      }
    }
    """

    case LinearOAuth.graphql(access_token, query, %{identifier: identifier}) do
      {:ok, %{"issues" => %{"nodes" => [issue | _]}}} ->
        {:ok, %{issue: issue}}

      {:ok, %{"issues" => %{"nodes" => []}}} ->
        {:error, "linear_issue_not_found"}

      {:error, reason} ->
        {:error, "linear_lookup_failed: #{inspect(reason)}"}
    end
  end

  defp matches_agent_filter?(agent, args) do
    status = Map.get(args, "status")
    behavior = Map.get(args, "behavior")

    (is_nil(status) or agent.status == status) and
      (is_nil(behavior) or agent.behavior == behavior)
  end

  defp perform_agent_action("start", agent_id), do: Runtime.start_existing_agent(agent_id)

  defp perform_agent_action("stop", agent_id),
    do: Runtime.stop_agent(agent_id, "telegram_operator")

  defp perform_agent_action("restart", agent_id) do
    with {:ok, _stop} <- Runtime.stop_agent(agent_id, "telegram_operator_restart"),
         {:ok, restarted} <- Runtime.start_existing_agent(agent_id) do
      {:ok, restarted}
    end
  end

  defp external_action_preview("gmail_send", payload) do
    "Send Gmail message to #{Map.get(payload, "to")} with subject \"#{Map.get(payload, "subject")}\"."
  end

  defp external_action_preview("slack_post", payload) do
    "Post Slack message to #{Map.get(payload, "channel")} on workspace #{Map.get(payload, "team_id")}."
  end

  defp external_action_preview("linear_create_issue", payload) do
    "Create Linear issue \"#{Map.get(payload, "title")}\" in team #{Map.get(payload, "team_id")}."
  end

  defp external_action_preview("linear_create_comment", payload) do
    "Add a Linear comment to issue #{Map.get(payload, "issue_id")}."
  end

  defp external_action_preview("linear_update_issue_state", payload) do
    "Move Linear issue #{Map.get(payload, "issue_id")} to state #{Map.get(payload, "state_id")}."
  end

  defp external_action_preview("notaui_complete_task", payload) do
    "Complete Notaui task #{Map.get(payload, "task_id")}."
  end

  defp external_action_preview("notaui_update_task", payload) do
    "Update Notaui task #{Map.get(payload, "task_id")}."
  end

  defp external_action_preview(_action_type, _payload),
    do: "Prepare the requested external action."

  defp external_target_id(action_type, payload)
       when action_type in [
              "gmail_send",
              "slack_post",
              "notaui_complete_task",
              "notaui_update_task"
            ] do
    Map.get(payload, "thread_id") || Map.get(payload, "channel") || Map.get(payload, "task_id")
  end

  defp external_target_id(_action_type, payload),
    do: Map.get(payload, "issue_id") || Map.get(payload, "state_id")

  defp create_agent_preview(start_params) do
    config = Map.get(start_params, "config", %{})
    name = Map.get(config, "name") || start_params["behavior"]
    "Create agent #{name} using behavior #{start_params["behavior"]}."
  end

  defp update_agent_preview(agent, update_params) do
    name = get_in(agent.config || %{}, ["name"]) || agent.behavior
    behavior = Map.get(update_params, "behavior", agent.behavior)
    "Update agent #{name} with behavior #{behavior} and apply the new configuration."
  end

  defp delete_agent_preview(agent) do
    name = get_in(agent.config || %{}, ["name"]) || agent.behavior
    "Delete agent #{name}. This removes its saved definition and runtime history dependencies."
  end

  defp immediate_agent_preview(action, agent) do
    name = get_in(agent.config || %{}, ["name"]) || agent.behavior
    "#{String.capitalize(action)} agent #{name}."
  end

  defp immediate_agent_result_text("start", agent, _result) do
    "Started agent #{agent_name(agent)}."
  end

  defp immediate_agent_result_text("stop", agent, _result) do
    "Stopped agent #{agent_name(agent)}."
  end

  defp immediate_agent_result_text("restart", agent, _result) do
    "Restarted agent #{agent_name(agent)}."
  end

  defp immediate_agent_result_text(_action, agent, _result) do
    "Updated agent #{agent_name(agent)}."
  end

  defp agent_name(agent) do
    get_in(agent.config || %{}, ["name"]) || agent.behavior
  end

  defp normalize_limit(value, _default, max_limit) when is_integer(value),
    do: value |> max(1) |> min(max_limit)

  defp normalize_limit(_value, default, _max_limit), do: default

  defp normalize_timeout(value) when is_integer(value), do: value |> max(1_000) |> min(30_000)
  defp normalize_timeout(_value), do: 12_000

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing_#{key}"}
    end
  end

  defp tool_definition(name, description, parameters) do
    %{
      "name" => name,
      "description" => description,
      "parameters" => parameters
    }
  end

  defp maybe_put_default(args, key, value) when is_binary(value) and value != "" do
    Map.put_new(args, key, value)
  end

  defp maybe_put_default(args, _key, _value), do: args

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_map(_map), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)
end
