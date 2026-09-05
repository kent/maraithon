defmodule MaraithonWeb.DashboardLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AgentBuilder
  alias Maraithon.ActionCards
  alias Maraithon.Admin
  alias Maraithon.AgentMarketplace
  alias Maraithon.Agents
  alias Maraithon.Behaviors
  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connections
  alias Maraithon.Insights.Detail
  alias Maraithon.Insights
  alias Maraithon.OnboardingProof
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Projects.ProjectItem
  alias Maraithon.Redaction
  alias Maraithon.Runtime
  alias Maraithon.RunErrorCopy
  alias Maraithon.SourceLabels
  alias Maraithon.Timezones
  alias Maraithon.Todos
  alias Maraithon.Todos.PublicMetadata
  alias Maraithon.UserMemory
  alias MaraithonWeb.AgentActionCopy
  alias MaraithonWeb.LocalTime
  alias MaraithonWeb.OAuthFlashCopy
  alias MaraithonWeb.OperationFailureCopy
  alias MaraithonWeb.TodoActionCopy

  @refresh_interval 30_000
  @event_limit 50
  @activity_limit 40
  @failure_limit 20
  @safe_oauth_statuses ~w(connected error)

  @impl true
  def mount(_params, _session, socket) do
    user_id = current_user_id(socket)

    socket =
      socket
      |> assign(
        page_title: "Control Center",
        diagnostics_visible: admin_user?(socket.assigns.current_user),
        behaviors: Behaviors.list() |> Enum.sort(),
        launch: default_launch_params(),
        launch_error: nil,
        launch_mode: :create,
        editing_agent_id: nil,
        command: %{"message" => ""},
        agents: [],
        selected_agent: nil,
        events: [],
        inspection: empty_inspection(),
        total_spend: empty_spend(),
        agent_spend: nil,
        health: %{
          status: :unknown,
          checks: %{
            database: :unknown,
            agents: %{running: 0, degraded: 0, stopped: 0},
            memory_mb: 0,
            uptime_seconds: 0
          },
          version: nil
        },
        queue_metrics: %{
          effects: %{pending: 0, claimed: 0, completed: 0, failed: 0},
          jobs: %{pending: 0, dispatched: 0, delivered: 0, cancelled: 0}
        },
        recent_activity: [],
        recent_failures: [],
        recent_logs: [],
        fly_logs: empty_fly_logs(),
        connection_user_id: user_id,
        connection_return_to: "/dashboard",
        current_path: "/dashboard",
        connected_provider_count: 0,
        connections: [],
        raw_connections: [],
        connection_errors: [],
        chief_of_staff_package: nil,
        chief_of_staff_readiness: [],
        chief_of_staff_agent: nil,
        chief_of_staff_schedule: BriefingSchedules.summarize_for_prompt(nil),
        dashboard_errors: [],
        inspection_errors: [],
        global_memory_summaries: [],
        memory_profile: empty_memory_profile(),
        memory_rules: [],
        todos: [],
        open_todo_count: 0,
        todo_review_index: 0,
        todo_review_session: %{completed: 0, dismissed: 0, kept: 0, important: 0},
        todo_review_decided_ids: MapSet.new(),
        selected_todo_ids: MapSet.new(),
        selected_todo_id: nil,
        selected_todo: nil,
        projects: [],
        agent_overviews: [],
        project_form: to_form(default_project_form_params(), as: :project),
        project_item_form: to_form(default_project_item_form_params(), as: :project_item),
        project_item_types: ProjectItem.item_types(),
        insights: [],
        act_now_insights: [],
        monitor_insights: [],
        expanded_insight_ids: MapSet.new(),
        detail_opened_insight_ids: MapSet.new(),
        onboarding_preview: empty_onboarding_preview(),
        onboarding_preview_eligible?: OnboardingProof.eligible?(user_id)
      )

    socket =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, self(), :refresh)

        if socket.assigns.diagnostics_visible do
          send(self(), :load_fly_logs)
        end

        refresh_dashboard(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> apply_dashboard_params(params, uri)

    case legacy_agents_path(params) do
      nil ->
        {:noreply,
         assign(socket,
           selected_agent: nil,
           events: [],
           agent_spend: nil,
           inspection: empty_inspection(),
           inspection_errors: [],
           page_title: "Control Center"
         )}

      to ->
        {:noreply, push_navigate(socket, to: to)}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_dashboard(socket, scope: :light)}
  end

  def handle_info(:load_fly_logs, socket) do
    if socket.assigns.diagnostics_visible do
      {:noreply, refresh_fly_logs(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:onboarding_preview, {:ok, {:ok, preview}}, socket) do
    {:noreply,
     assign(socket,
       onboarding_preview: %{
         status: :ready,
         items: preview.items,
         sources: preview.sources,
         generated_at: preview.generated_at,
         error: nil
       }
     )}
  end

  def handle_async(:onboarding_preview, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       onboarding_preview: %{
         status: :error,
         items: [],
         sources: [],
         generated_at: nil,
         error: OperationFailureCopy.onboarding_preview(reason)
       }
     )}
  end

  def handle_async(:onboarding_preview, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       onboarding_preview: %{
         status: :error,
         items: [],
         sources: [],
         generated_at: nil,
         error: OperationFailureCopy.onboarding_preview(reason)
       }
     )}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    send(self(), :load_fly_logs)

    {:noreply,
     socket
     |> refresh_dashboard()
     |> put_flash(:info, "Dashboard refreshed")}
  end

  def handle_event("refresh_onboarding_preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:onboarding_preview, empty_onboarding_preview())
     |> maybe_start_onboarding_preview(force: true)}
  end

  def handle_event("refresh_fly_logs", _params, socket) do
    if socket.assigns.diagnostics_visible do
      send(self(), :load_fly_logs)
      {:noreply, put_flash(socket, :info, "Platform log refresh started")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("disconnect_connection", %{"provider" => provider}, socket) do
    case Connections.disconnect(socket.assigns.connection_user_id, provider) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(:info, "#{provider_label(provider)} disconnected")}

      {:error, :no_token} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(:error, "#{provider_label(provider)} is not connected")}

      {:error, :unsupported_provider} ->
        {:noreply, put_flash(socket, :error, "That connected app is not available.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(
           :error,
           OperationFailureCopy.disconnect(provider_label(provider), reason)
         )}
    end
  end

  def handle_event("update_project_form", %{"project" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :project_form,
       to_form(Map.merge(default_project_form_params(), params), as: :project)
     )}
  end

  def handle_event("create_project", %{"project" => params}, socket) do
    attrs = Map.take(params, ["name", "summary", "description", "priority"])

    case Projects.create_project(current_user_id(socket), attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project_form, to_form(default_project_form_params(), as: :project))
         |> assign(
           :project_item_form,
           to_form(
             default_project_item_form_params()
             |> Map.put("project_id", project.id),
             as: :project_item
           )
         )
         |> refresh_dashboard()
         |> put_flash(:info, "Project created")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :project_form,
           to_form(Map.merge(default_project_form_params(), params), as: :project)
         )
         |> put_flash(:error, OperationFailureCopy.project(:create, changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OperationFailureCopy.project(:create, reason))}
    end
  end

  def handle_event("update_project_item_form", %{"project_item" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :project_item_form,
       to_form(Map.merge(default_project_item_form_params(), params), as: :project_item)
     )}
  end

  def handle_event("create_project_item", %{"project_item" => params}, socket) do
    project_id = Map.get(params, "project_id")
    attrs = Map.take(params, ["item_type", "title", "content"])

    case Projects.create_project_item(project_id, current_user_id(socket), attrs) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(
           :project_item_form,
           to_form(
             default_project_item_form_params()
             |> Map.put("project_id", project_id || ""),
             as: :project_item
           )
         )
         |> refresh_dashboard()
         |> put_flash(:info, "Project context saved")}

      {:error, :project_not_found} ->
        {:noreply,
         socket
         |> assign(
           :project_item_form,
           to_form(Map.merge(default_project_item_form_params(), params), as: :project_item)
         )
         |> put_flash(:error, "Choose a valid project first")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :project_item_form,
           to_form(Map.merge(default_project_item_form_params(), params), as: :project_item)
         )
         |> put_flash(:error, OperationFailureCopy.project(:memory, changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OperationFailureCopy.project(:memory, reason))}
    end
  end

  def handle_event("install_chief_of_staff", params, socket) do
    user_id = current_user_id(socket)
    project_id = Map.get(params, "project_id") || first_project_id(socket.assigns.projects)
    schedule_config = chief_of_staff_install_config(params)

    binding_consent =
      chief_of_staff_binding_consent(
        params,
        user_id,
        project_id,
        socket.assigns.chief_of_staff_package,
        socket.assigns.chief_of_staff_readiness
      )

    cond do
      is_nil(project_id) ->
        {:noreply, put_flash(socket, :error, "Create a project before installing Chief of Staff")}

      true ->
        install_opts =
          [
            project_id: project_id,
            delivery_policy:
              chief_of_staff_delivery_policy(socket.assigns.chief_of_staff_readiness),
            config: schedule_config
          ]
          |> maybe_put_binding_consent(binding_consent)

        case Runtime.install_chief_of_staff(user_id, install_opts) do
          {:ok, %{install_status: "setup_required"} = agent} ->
            {:noreply,
             socket
             |> refresh_dashboard()
             |> put_flash(
               :info,
               "Chief of Staff installed. Connect the missing services to enable briefs."
             )
             |> push_navigate(to: "/agents?id=#{agent.id}&panel=apps")}

          {:ok, agent} ->
            {:noreply,
             socket
             |> refresh_dashboard()
             |> put_flash(:info, "Chief of Staff installed")
             |> push_navigate(to: "/agents?id=#{agent.id}&panel=inspect")}

          {:error, :project_not_found} ->
            {:noreply, put_flash(socket, :error, "Choose a valid project before installing")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, reason))}
        end
    end
  end

  def handle_event("decide_project_recommendation", params, socket) do
    user_id = current_user_id(socket)

    case Projects.decide_project_recommendation(
           params["project_id"],
           user_id,
           params["recommendation_id"],
           %{"decision" => params["decision"]}
         ) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, "Recommendation #{decision_label(params["decision"])}")}

      {:error, :project_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Project not found")}

      {:error, :recommendation_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Recommendation not found")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, OperationFailureCopy.project(:recommendation_decision, reason))}
    end
  end

  def handle_event("grant_project_repo_access", params, socket) do
    user_id = current_user_id(socket)

    case Projects.grant_project_repo_access(params["project_id"], user_id, %{
           "repo_full_name" => params["repo_full_name"],
           "scope" => params["scope"]
         }) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(
           :info,
           "Granted #{repo_scope_label(grant.scope)} access for #{grant.repo_full_name}"
         )}

      {:error, :project_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Project not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OperationFailureCopy.project(:repo_access, reason))}
    end
  end

  def handle_event("start_project_implementation_run", params, socket) do
    user_id = current_user_id(socket)

    case Projects.start_implementation_run(params["project_id"], user_id, %{
           "recommendation_id" => params["recommendation_id"]
         }) do
      {:ok, run} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, run.result_summary || "Delivery work started")}

      {:error, :project_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Project not found")}

      {:error, :recommendation_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Recommendation not found")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, OperationFailureCopy.project(:implementation_run, reason))}
    end
  end

  def handle_event("complete_todo", %{"id" => todo_id}, socket) do
    user_id = current_user_id(socket)

    case Todos.mark_done(user_id, todo_id, todo_action_opts(user_id, "Completed from dashboard.")) do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, "Work item completed")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:error, TodoActionCopy.error(:complete, :not_found))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TodoActionCopy.error(:complete, reason))}
    end
  end

  def handle_event("dismiss_todo", %{"id" => todo_id}, socket) do
    user_id = current_user_id(socket)

    case Todos.dismiss(user_id, todo_id, todo_action_opts(user_id, "Dismissed from dashboard.")) do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, "Work item dismissed")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:error, TodoActionCopy.error(:dismiss, :not_found))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TodoActionCopy.error(:dismiss, reason))}
    end
  end

  def handle_event("review_previous_todo", _params, socket) do
    previous_index = socket.assigns.todo_review_index - 1
    reviewable_count = reviewable_todo_count(socket)

    {:noreply,
     assign(
       socket,
       :todo_review_index,
       clamp_review_index(previous_index, reviewable_count)
     )}
  end

  def handle_event("review_next_todo", _params, socket) do
    next_index = socket.assigns.todo_review_index + 1
    reviewable_count = reviewable_todo_count(socket)

    {:noreply,
     assign(
       socket,
       :todo_review_index,
       clamp_review_index(next_index, reviewable_count)
     )}
  end

  def handle_event("review_keep_todo", %{"id" => todo_id}, socket) do
    socket = mark_todo_reviewed(socket, todo_id)

    {:noreply,
     socket
     |> increment_todo_review_session(:kept)
     |> clamp_todo_review_index()}
  end

  def handle_event("review_complete_todo", %{"id" => todo_id}, socket) do
    user_id = current_user_id(socket)

    case Todos.mark_done(
           user_id,
           todo_id,
           todo_action_opts(user_id, "Completed from dashboard review.")
         ) do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> mark_todo_reviewed(todo_id)
         |> increment_todo_review_session(:completed)
         |> refresh_dashboard()
         |> put_flash(:info, "Work item completed")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:error, TodoActionCopy.error(:complete, :not_found))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TodoActionCopy.error(:complete, reason))}
    end
  end

  def handle_event("review_dismiss_todo", %{"id" => todo_id}, socket) do
    user_id = current_user_id(socket)

    case Todos.dismiss(
           user_id,
           todo_id,
           todo_action_opts(user_id, "Dismissed from dashboard review.")
         ) do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> mark_todo_reviewed(todo_id)
         |> increment_todo_review_session(:dismissed)
         |> refresh_dashboard()
         |> put_flash(:info, "Work item dismissed")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:error, TodoActionCopy.error(:dismiss, :not_found))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TodoActionCopy.error(:dismiss, reason))}
    end
  end

  def handle_event("review_mark_important", %{"id" => todo_id}, socket) do
    case Todos.mark_important(current_user_id(socket), todo_id, source: "dashboard_review") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> mark_todo_reviewed(todo_id)
         |> increment_todo_review_session(:important)
         |> refresh_dashboard()
         |> put_flash(:info, "Work item kept active")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:error, TodoActionCopy.error(:mark_important, :not_found))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TodoActionCopy.error(:mark_important, reason))}
    end
  end

  def handle_event("toggle_todo_selection", %{"id" => todo_id}, socket) do
    selected_todo_ids =
      if visible_todo_id?(socket, todo_id) do
        toggle_mapset_member(socket.assigns.selected_todo_ids, todo_id)
      else
        socket.assigns.selected_todo_ids
      end

    {:noreply, assign(socket, :selected_todo_ids, selected_todo_ids)}
  end

  def handle_event("toggle_all_todos", _params, socket) do
    visible_ids = visible_todo_ids(socket)

    selected_todo_ids =
      if all_visible_todos_selected?(socket.assigns.todos, socket.assigns.selected_todo_ids) do
        MapSet.difference(socket.assigns.selected_todo_ids, visible_ids)
      else
        MapSet.union(socket.assigns.selected_todo_ids, visible_ids)
      end

    {:noreply, assign(socket, :selected_todo_ids, selected_todo_ids)}
  end

  def handle_event("clear_todo_selection", _params, socket) do
    {:noreply, assign(socket, :selected_todo_ids, MapSet.new())}
  end

  def handle_event("complete_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :complete)}
  end

  def handle_event("dismiss_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :dismiss)}
  end

  def handle_event("open_todo_detail", %{"id" => todo_id}, socket) do
    if visible_todo_id?(socket, todo_id) do
      {:noreply, push_patch(socket, to: todo_detail_path(todo_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_insight_detail", %{"id" => insight_id}, socket) do
    case insight_card(socket, insight_id) do
      %{insight: insight, detail: detail} ->
        expanded? = MapSet.member?(socket.assigns.expanded_insight_ids, insight_id)

        expanded_insight_ids =
          if expanded? do
            MapSet.delete(socket.assigns.expanded_insight_ids, insight_id)
          else
            MapSet.put(socket.assigns.expanded_insight_ids, insight_id)
          end

        detail_opened_insight_ids =
          if expanded? do
            socket.assigns.detail_opened_insight_ids
          else
            MapSet.put(socket.assigns.detail_opened_insight_ids, insight_id)
          end

        emit_insight_detail_toggle_telemetry(expanded?, insight, detail)

        {:noreply,
         assign(socket,
           expanded_insight_ids: expanded_insight_ids,
           detail_opened_insight_ids: detail_opened_insight_ids
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("ack_insight", %{"id" => insight_id}, socket) do
    card = insight_card(socket, insight_id)

    case Insights.acknowledge(current_user_id(socket), insight_id) do
      {:ok, _insight} ->
        maybe_emit_insight_action_telemetry(socket, "acknowledge", card, insight_id)

        {:noreply, socket |> refresh_insights() |> put_flash(:info, "Insight acknowledged")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OperationFailureCopy.insight(:acknowledge, reason))}
    end
  end

  def handle_event("dismiss_insight", %{"id" => insight_id}, socket) do
    card = insight_card(socket, insight_id)

    case Insights.dismiss(current_user_id(socket), insight_id) do
      {:ok, _insight} ->
        maybe_emit_insight_action_telemetry(socket, "dismiss", card, insight_id)

        {:noreply, socket |> refresh_insights() |> put_flash(:info, "Insight dismissed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OperationFailureCopy.insight(:dismiss, reason))}
    end
  end

  def handle_event("snooze_insight", %{"id" => insight_id}, socket) do
    snooze_until = DateTime.add(DateTime.utc_now(), 4, :hour)
    card = insight_card(socket, insight_id)

    case Insights.snooze(current_user_id(socket), insight_id, snooze_until) do
      {:ok, _insight} ->
        maybe_emit_insight_action_telemetry(socket, "snooze", card, insight_id)

        {:noreply,
         socket
         |> refresh_insights()
         |> put_flash(:info, "Insight snoozed for 4 hours")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OperationFailureCopy.insight(:snooze, reason))}
    end
  end

  def handle_event("new_agent", _params, socket) do
    {:noreply,
     assign(socket,
       launch: default_launch_params(),
       launch_error: nil,
       launch_mode: :create,
       editing_agent_id: nil
     )}
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    case Agents.get_agent_for_user(id, current_user_id(socket)) do
      nil ->
        {:noreply,
         socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}

      agent ->
        {:noreply,
         assign(socket,
           launch: launch_params_from_agent(agent),
           launch_error: nil,
           launch_mode: :edit,
           editing_agent_id: id
         )}
    end
  end

  def handle_event("launch_agent", %{"launch" => params}, socket) do
    launch = normalize_launch_params(params)

    with {:ok, start_params} <- build_agent_start_params(launch, current_user_id(socket)) do
      save_agent(socket, launch, start_params)
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, launch: launch, launch_error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: AgentActionCopy.error(:create, changeset)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: AgentActionCopy.error(:create, reason)
         )}
    end
  end

  def handle_event("start_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      case Runtime.start_existing_agent(id) do
        {:ok, _agent} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> refresh_if_selected(id)
           |> put_flash(:info, "Automation started")}

        {:error, :already_running} ->
          {:noreply,
           socket |> refresh_dashboard() |> put_flash(:info, AgentActionCopy.already_active())}

        {:error, :not_found} ->
          {:noreply,
           socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> put_flash(:error, AgentActionCopy.error(:start, reason))}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}
    end
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      case Runtime.stop_agent(id, "stopped_from_admin") do
        {:ok, _} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> refresh_if_selected(id)
           |> put_flash(:info, "Automation paused")}

        {:error, :not_found} ->
          {:noreply,
           socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      case Runtime.delete_agent(id) do
        :ok ->
          socket =
            socket
            |> maybe_reset_editor(id)
            |> refresh_dashboard()
            |> put_flash(:info, "Automation deleted")

          if socket.assigns.selected_agent && socket.assigns.selected_agent.id == id do
            {:noreply,
             socket
             |> assign(
               selected_agent: nil,
               events: [],
               agent_spend: nil,
               inspection: empty_inspection()
             )
             |> push_patch(to: "/dashboard")}
          else
            {:noreply, socket}
          end

        {:error, :not_found} ->
          {:noreply,
           socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> put_flash(:error, AgentActionCopy.error(:delete, reason))}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}
    end
  end

  def handle_event("send_message", %{"command" => %{"message" => raw_message}}, socket) do
    message = String.trim(raw_message || "")

    cond do
      socket.assigns.selected_agent == nil ->
        {:noreply, put_flash(socket, :error, "Select an automation first")}

      not agent_owned_by_current_user?(socket, socket.assigns.selected_agent.id) ->
        {:noreply, put_flash(socket, :error, AgentActionCopy.not_found())}

      message == "" ->
        {:noreply, put_flash(socket, :error, "Message cannot be empty")}

      true ->
        send_admin_message(socket, socket.assigns.selected_agent.id, message)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-10">
      <header class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-xl/8">
            Control Center
          </h1>
          <p class="mt-1 text-sm/6 text-zinc-500">
            <%= dashboard_greeting(@current_user, @chief_of_staff_schedule) %>
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            phx-click="refresh_now"
            class="rounded-md px-2 py-1 text-xs/5 font-medium text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
          >
            Refresh
          </button>
          <.button navigate={"/agents/new"}>
            New automation
          </.button>
        </div>
      </header>

      <%= if @dashboard_errors != [] do %>
        <.alert color="amber">
          <div class="space-y-2">
            <%= for error <- @dashboard_errors do %>
              <div>
                <p class="text-sm font-medium text-amber-900"><%= error.message %></p>
                <p class="mt-1 text-xs text-amber-800"><%= error.details %></p>
              </div>
            <% end %>
          </div>
        </.alert>
      <% end %>

      <.todo_review_board
        todos={@todos}
        todo_review_index={@todo_review_index}
        todo_review_session={@todo_review_session}
        todo_review_decided_ids={@todo_review_decided_ids}
        chief_of_staff_schedule={@chief_of_staff_schedule}
      />

      <section id="todos">
        <div class="flex flex-wrap items-end justify-between gap-3 border-b border-zinc-950/10 pb-3">
          <div>
            <h2 class="text-base/7 font-semibold text-zinc-950">Today</h2>
            <p class="mt-1 text-sm/6 text-zinc-500">
              <%= if @open_todo_count > 0 do %>
                <%= review_ready_label(@open_todo_count) %>
              <% else %>
                Nothing needs your review right now. Maraithon will add work here when messages, meetings, notes, or local context produce a concrete next move.
              <% end %>
            </p>
          </div>
          <.button navigate="/todos" variant="outline">Open Work</.button>
        </div>
      </section>

      <section>
        <div class="border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Overview</h2>
        </div>
        <dl class="mt-6 grid grid-cols-1 gap-x-8 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
          <.overview_stat
            label="Automations"
            value={length(@agents)}
            note={automation_status_note(@agents)}
          />
          <.overview_stat
            label="Open work"
            value={@open_todo_count}
            note={open_work_status_note(@open_todo_count)}
          />
          <.overview_stat
            label="Connected services"
            value={@connected_provider_count}
            note={connected_services_note(@connected_provider_count)}
          />
          <.overview_stat
            label="Projects"
            value={length(@projects)}
            note={projects_status_note(@projects)}
          />
        </dl>
      </section>

      <section>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Workspace</h2>
          <.link navigate="/connectors" class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950">
            Manage apps →
          </.link>
        </div>
        <dl class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.workspace_summary
            label="Connected services"
            value={@connected_provider_count}
            description={
              if @connected_provider_count == 0,
                do: "Connect work apps so Maraithon can see current context.",
                else: "Linked accounts feed every project."
            }
            href="/connectors"
            cta="Connected Apps"
          />
          <.workspace_summary
            label="Saved context"
            value={length(@memory_rules)}
            unit="rules"
            description={
              if @memory_profile.summary && @memory_profile.summary != "",
                do: @memory_profile.summary,
                else: "Using confirmed context until you save a standing preference."
            }
            href="#memory-detail"
            cta="View context"
          />
          <.workspace_summary
            label="Projects"
            value={length(@projects)}
            description={
              if length(@projects) == 0,
                do: "Projects hold notes, decisions, and grants.",
                else: "Each project carries its own context."
            }
            href="#projects"
            cta="View projects"
          />
        </dl>
      </section>

      <section id="chief-of-staff-install">
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Start Chief of Staff</h2>
          <span class="text-xs/5 text-zinc-500">
            <%= chief_of_staff_install_state(@chief_of_staff_agent, @chief_of_staff_readiness, @projects) %>
          </span>
        </div>

        <div class="mt-4 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10 bg-white">
          <div class="grid grid-cols-1 gap-4 px-4 py-4 sm:px-6 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-sm/6 font-semibold text-zinc-950">Chief of Staff</h3>
                <.badge color={chief_of_staff_badge_color(@chief_of_staff_agent)}>
                  <%= chief_of_staff_badge_label(@chief_of_staff_agent) %>
                </.badge>
              </div>
              <p class="mt-1 max-w-3xl text-sm/6 text-zinc-600">
                <%= chief_of_staff_summary(@chief_of_staff_package) %>
              </p>

              <div class="mt-3 flex flex-wrap gap-2">
                <span
                  :for={item <- @chief_of_staff_readiness}
                  class={connector_chip_class(item)}
                >
                  <%= item.label %>
                </span>
              </div>

              <div :if={chief_of_staff_missing_readiness(@chief_of_staff_readiness) != []} class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs/5">
                <%= for item <- chief_of_staff_missing_readiness(@chief_of_staff_readiness) do %>
                  <a
                    href={item.connect_path}
                    class="font-medium text-zinc-950 hover:text-zinc-700"
                  >
                    Connect <%= item.label %> →
                  </a>
                <% end %>
              </div>

              <p :if={@chief_of_staff_agent} class="mt-3 text-sm/6 text-zinc-500">
                Morning brief: <%= chief_of_staff_schedule_label(@chief_of_staff_schedule) %>
                <.link
                  navigate={"/agents?id=#{@chief_of_staff_agent.id}&panel=skills"}
                  class="ml-2 font-medium text-zinc-950 hover:text-zinc-700"
                >
                  Edit
                </.link>
              </p>
            </div>

            <div class="flex flex-wrap items-center justify-start gap-2 lg:justify-end">
              <%= cond do %>
                <% @chief_of_staff_agent && @chief_of_staff_agent.install_status != "setup_required" -> %>
                  <.button navigate={"/agents?id=#{@chief_of_staff_agent.id}&panel=inspect"} variant="outline">
                    Open
                  </.button>
                <% @projects == [] -> %>
                  <.button type="button" disabled>
                    Create project first
                  </.button>
                <% true -> %>
                  <form
                    id="chief-of-staff-install-form"
                    phx-submit="install_chief_of_staff"
                    class="grid grid-cols-2 items-end gap-2 sm:grid-cols-[minmax(0,10rem)_minmax(0,10rem)_auto]"
                  >
                    <input
                      type="hidden"
                      name="project_id"
                      value={chief_of_staff_project_id(@chief_of_staff_agent, @projects)}
                    />
                    <.field label="Brief time" for="chief_of_staff_morning_brief_hour">
                      <.c_select
                        id="chief_of_staff_morning_brief_hour"
                        name="schedule[morning_brief_hour_local]"
                      >
                        <option
                          :for={option <- chief_of_staff_morning_hour_options()}
                          value={option.value}
                          selected={option.value == chief_of_staff_install_hour(@chief_of_staff_agent, @chief_of_staff_schedule)}
                        >
                          <%= option.label %>
                        </option>
                      </.c_select>
                    </.field>
                    <.field label="Timezone" for="chief_of_staff_timezone">
                      <.c_select
                        id="chief_of_staff_timezone"
                        name="schedule[timezone]"
                      >
                        <option
                          :for={option <- chief_of_staff_timezone_options()}
                          value={option.value}
                          selected={option.value == chief_of_staff_install_timezone(@chief_of_staff_agent, @chief_of_staff_schedule)}
                        >
                          <%= option.label %>
                        </option>
                      </.c_select>
                    </.field>
                    <label
                      :if={chief_of_staff_missing_readiness(@chief_of_staff_readiness) == []}
                      class="col-span-2 flex max-w-xl items-start gap-2 text-xs/5 text-zinc-600 sm:col-span-3"
                    >
                      <input
                        id="chief-of-staff-binding-consent"
                        type="checkbox"
                        name="binding_consent[acknowledged]"
                        value="true"
                        required
                        class="mt-0.5 size-4 rounded border-zinc-300 text-zinc-950"
                      />
                      <span>
                        <%= chief_of_staff_consent_description(@chief_of_staff_readiness) %>
                      </span>
                    </label>
                    <.button
                      type="submit"
                      phx-disable-with="Installing..."
                      variant={if chief_of_staff_missing_readiness(@chief_of_staff_readiness) == [], do: "solid", else: "outline"}
                      class="col-span-2 sm:col-span-1"
                    >
                      <%= chief_of_staff_install_button_label(@chief_of_staff_agent, @chief_of_staff_readiness) %>
                    </.button>
                  </form>
              <% end %>
            </div>
          </div>
        </div>
      </section>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span>New project</span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Open</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Close</span>
        </summary>
        <.form
          for={@project_form}
          id="project-form"
          phx-change="update_project_form"
          phx-submit="create_project"
          class="space-y-4 border-t border-zinc-950/10 px-4 py-4 sm:px-6"
        >
          <.field label="Project name" for="project_name">
            <.c_input
              id="project_name"
              type="text"
              name="project[name]"
              value={@project_form[:name].value}
            />
          </.field>

          <.field label="Summary" for="project_summary">
            <.c_input
              id="project_summary"
              type="text"
              name="project[summary]"
              value={@project_form[:summary].value}
            />
          </.field>

          <.field label="Description" for="project_description">
            <.c_textarea
              id="project_description"
              name="project[description]"
              rows={4}
              value={@project_form[:description].value}
            />
          </.field>

          <.field label="Priority" for="project_priority">
            <.c_select
              id="project_priority"
              name="project[priority]"
            >
              <option value="low" selected={@project_form[:priority].value == "low"}>Low</option>
              <option value="normal" selected={@project_form[:priority].value == "normal"}>Normal</option>
              <option value="high" selected={@project_form[:priority].value == "high"}>High</option>
              <option value="critical" selected={@project_form[:priority].value == "critical"}>Critical</option>
            </.c_select>
          </.field>

          <div class="flex justify-end">
            <.button type="submit" phx-disable-with="Creating...">
              Create project
            </.button>
          </div>
        </.form>
      </details>

      <section
        :if={@memory_profile.summary not in [nil, ""] or @memory_rules != [] or @global_memory_summaries != []}
        id="memory-detail"
      >
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Saved context</h2>
        </div>
        <div class="mt-4 space-y-4">
          <p
            :if={@memory_profile.summary not in [nil, ""]}
            class="text-sm/6 text-zinc-700"
          >
            <%= @memory_profile.summary %>
          </p>

          <dl
            :if={memory_profile_fields(@memory_profile) != []}
            class="grid grid-cols-1 gap-x-8 gap-y-3 sm:grid-cols-2"
          >
            <div :for={field <- memory_profile_fields(@memory_profile)}>
              <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
              <dd class="mt-0.5 text-sm/6 text-zinc-700"><%= field.value %></dd>
            </div>
          </dl>

          <div :if={@memory_rules != []}>
            <p class="text-sm/6 font-medium text-zinc-950">Saved preferences</p>
            <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
              <li
                :for={rule <- Enum.take(@memory_rules, 3)}
                class="py-2.5"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    <%= memory_rule_kind_label(rule["kind"]) %>
                  </p>
                  <p class="mt-0.5 text-sm/6 text-zinc-700"><%= rule["instruction"] || rule["label"] %></p>
                </div>
              </li>
            </ul>
          </div>

          <div :if={@global_memory_summaries != []}>
            <p class="text-sm/6 font-medium text-zinc-950">Global state</p>
            <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
              <li
                :for={summary <- Enum.take(@global_memory_summaries, 3)}
                class="py-2.5"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    <%= memory_summary_label(summary.type) %>
                  </p>
                  <p class="mt-0.5 text-sm/6 text-zinc-700"><%= summary.content %></p>
                </div>
              </li>
            </ul>
          </div>
        </div>
      </section>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Add to project context</span>
            <span class="text-xs/5 text-zinc-500">notes · decisions · grants</span>
          </span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Open</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Close</span>
        </summary>
        <.form
          for={@project_item_form}
          id="project-item-form"
          phx-change="update_project_item_form"
          phx-submit="create_project_item"
          class="grid grid-cols-1 gap-4 border-t border-zinc-950/10 px-4 py-4 sm:px-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)_minmax(0,0.9fr)]"
        >
          <div class="space-y-4">
            <.field label="Project" for="project_item_project_id">
              <.c_select
                id="project_item_project_id"
                name="project_item[project_id]"
              >
                <option value="">Choose a project</option>
                <option
                  :for={{label, value} <- project_options(@projects)}
                  value={value}
                  selected={@project_item_form[:project_id].value == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>
            <.field label="Item type" for="project_item_item_type">
              <.c_select
                id="project_item_item_type"
                name="project_item[item_type]"
              >
                <option
                  :for={{label, value} <- project_item_type_options(@project_item_types)}
                  value={value}
                  selected={@project_item_form[:item_type].value == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>
          </div>

          <div class="space-y-4">
            <.field label="Title" for="project_item_title">
              <.c_input
                id="project_item_title"
                type="text"
                name="project_item[title]"
                value={@project_item_form[:title].value}
              />
            </.field>
            <p class="text-xs/5 text-zinc-500">
              Use this for concise labels like “Q2 launch goal” or “Ship project dashboard”.
            </p>
          </div>

          <div class="space-y-4">
            <.field label="Content" for="project_item_content">
              <.c_textarea
                id="project_item_content"
                name="project_item[content]"
                rows={4}
                value={@project_item_form[:content].value}
              />
            </.field>
            <div class="flex justify-end">
              <.button
                type="submit"
                phx-disable-with="Saving..."
                disabled={@projects == []}
              >
                Save
              </.button>
            </div>
          </div>
        </.form>
      </details>

      <section id="projects">
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Projects</h2>
          <span class="text-xs/5 text-zinc-500"><%= length(@projects) %> total</span>
        </div>
        <div class="mt-4 grid grid-cols-1 gap-4 xl:grid-cols-2">
          <%= for project_card <- @projects do %>
            <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 p-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-base/7 font-semibold text-zinc-950"><%= project_card.project.name %></h3>
                    <span class={project_status_class(project_card.project.status)}>
                      <%= project_card.project.status %>
                    </span>
                    <span class={project_priority_class(project_card.project.priority)}>
                      <%= project_priority_label(project_card.project.priority) %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs/5 text-zinc-500">
                    <%= project_card.project.slug %>
                  </p>
                  <p class="mt-3 text-sm/6 text-zinc-600">
                    <%= project_summary(project_card.project) %>
                  </p>
                </div>

                <.button
                  navigate={"/agents/new?behavior=github_product_planner&project_id=#{project_card.project.id}"}
                  variant="outline"
                  class="text-xs"
                >
                  Attach Project Manager
                </.button>
              </div>

              <div class="mt-4 flex flex-wrap gap-2">
                <.badge class="bg-white">
                  <%= pluralize(length(project_card.agents), "automation") %>
                </.badge>
                <.badge class="bg-white">
                  <%= length(project_card.items) %> recent items
                </.badge>
                <.badge class="bg-white">
                  <%= length(project_card.recommendations) %> PM recommendations
                </.badge>
              </div>

              <%= if project_card.agents != [] do %>
                <div class="mt-4">
                  <p class="text-sm/6 font-medium text-zinc-950">Attached automations</p>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <.badge
                      :for={agent <- project_card.agents}
                      color="zinc"
                      class="bg-zinc-950 text-white"
                    >
                      <%= get_in(agent.config || %{}, ["name"]) || automation_behavior_label(agent.behavior) %>
                    </.badge>
                  </div>
                </div>
              <% end %>

              <div class="mt-5 grid grid-cols-1 gap-4 lg:grid-cols-2">
                <div class="space-y-3">
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-sm/6 font-medium text-zinc-950">
                      Project context
                    </p>
                  </div>
                  <%= if project_card.items == [] do %>
                    <p class="text-sm/6 text-zinc-500">
                      Add a note, work item, or repo grant so Maraithon has enough detail to make useful recommendations.
                    </p>
                  <% else %>
                    <div
                      :for={item <- project_card.items}
                      class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3"
                    >
                      <div class="flex items-center justify-between gap-3">
                        <p class="text-sm/6 font-medium text-zinc-950"><%= item.title || item_type_label(item.item_type) %></p>
                        <.badge>
                          <%= item_type_label(item.item_type) %>
                        </.badge>
                      </div>
                      <p class="mt-2 text-sm/6 text-zinc-600"><%= item.content %></p>
                    </div>
                  <% end %>
                </div>

                <div class="space-y-3">
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Planning recommendations
                  </p>
                  <%= if project_card.recommendations == [] do %>
                    <p class="text-sm/6 text-zinc-500">
                      Add project context, then attach a Product Planner to turn it into ranked next steps.
                    </p>
                  <% else %>
                    <div
                      :for={recommendation <- project_card.recommendations}
                      class="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-3"
                    >
                      <div class="flex items-center justify-between gap-3">
                        <div>
                          <p class="text-sm/6 font-medium text-zinc-950"><%= recommendation.title %></p>
                          <div class="mt-2 flex flex-wrap gap-2">
                            <span class={recommendation_priority_class(recommendation.priority)}>
                              <%= recommendation_priority_label(recommendation.priority) %>
                            </span>
                            <%= if recommendation.decision do %>
                              <.badge class="bg-white">
                                <%= recommendation_decision_label(recommendation.decision.decision) %>
                              </.badge>
                            <% end %>
                            <%= if recommendation.repo_grant do %>
                              <.badge class="bg-white">
                                <%= repo_scope_label(recommendation.repo_grant.scope) %>
                              </.badge>
                            <% end %>
                            <%= if recommendation.latest_run do %>
                              <.badge class="bg-white">
                                <%= implementation_run_status_label(recommendation.latest_run.status) %>
                              </.badge>
                            <% end %>
                          </div>
                        </div>
                      </div>
                      <p class="mt-2 text-sm/6 text-zinc-600"><%= recommendation.summary %></p>
                      <p class="mt-2 text-sm/6 text-emerald-900">
                        <span class="font-medium">Next step:</span> <%= recommendation.recommended_action %>
                      </p>
                      <%= if recommendation.why_now do %>
                        <p class="mt-2 text-xs/5 text-emerald-800"><%= recommendation.why_now %></p>
                      <% end %>
                      <%= if recommendation.latest_run do %>
                        <p class="mt-2 text-xs/5 text-zinc-600"><%= recommendation.latest_run.result_summary %></p>
                        <div class="mt-2 flex flex-wrap items-center gap-3 text-xs/5 text-zinc-500">
                          <%= if recommendation.latest_run.branch_name do %>
                            <span>Branch: <code><%= recommendation.latest_run.branch_name %></code></span>
                          <% end %>
                          <%= if recommendation.latest_run.pull_request_url do %>
                            <a
                              href={recommendation.latest_run.pull_request_url}
                              target="_blank"
                              rel="noreferrer"
                              class="font-medium text-emerald-700 hover:text-emerald-800"
                            >
                              Open PR
                            </a>
                          <% end %>
                        </div>
                      <% end %>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <.button
                          type="button"
                          phx-click="decide_project_recommendation"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          phx-value-decision="accepted"
                          variant="outline"
                          class="text-xs text-emerald-800"
                        >
                          Accept
                        </.button>
                        <.button
                          type="button"
                          phx-click="decide_project_recommendation"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          phx-value-decision="deferred"
                          variant="outline"
                          class="text-xs"
                        >
                          Defer
                        </.button>
                        <.button
                          type="button"
                          phx-click="decide_project_recommendation"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          phx-value-decision="rejected"
                          variant="outline"
                          class="text-xs"
                        >
                          Reject
                        </.button>
                        <%= if recommendation.repo_full_name do %>
                          <.button
                            type="button"
                            phx-click="grant_project_repo_access"
                            phx-value-project_id={project_card.project.id}
                            phx-value-repo_full_name={recommendation.repo_full_name}
                            phx-value-scope="read_only"
                            variant="outline"
                            class="text-xs"
                          >
                            Grant Read Access
                          </.button>
                          <.button
                            type="button"
                            phx-click="grant_project_repo_access"
                            phx-value-project_id={project_card.project.id}
                            phx-value-repo_full_name={recommendation.repo_full_name}
                            phx-value-scope="branch_write"
                            variant="outline"
                            class="text-xs"
                          >
                            Grant Branch Access
                          </.button>
                        <% end %>
                        <.button
                          type="button"
                          phx-click="start_project_implementation_run"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          class="text-xs"
                        >
                          Start Delivery
                        </.button>
                      </div>
                    </div>
                  <% end %>

                  <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                    <p class="text-sm/6 font-medium text-zinc-950">
                      Repo Access
                    </p>
                    <%= if project_card.repo_grants == [] do %>
                      <p class="mt-2 text-sm/6 text-zinc-500">
                        Grant read access when a recommendation needs code context.
                      </p>
                    <% else %>
                      <div :for={grant <- project_card.repo_grants} class="mt-2 flex items-center justify-between gap-3 rounded-lg border border-zinc-950/10 px-3 py-2">
                        <div class="min-w-0">
                          <p class="truncate text-sm/6 font-medium text-zinc-950"><%= grant.repo_full_name %></p>
                          <p class="text-xs/5 text-zinc-500"><%= repo_scope_label(grant.scope) %></p>
                        </div>
                        <.badge>
                          <%= String.capitalize(grant.status) %>
                        </.badge>
                      </div>
                    <% end %>
                  </div>

                  <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                    <p class="text-sm/6 font-medium text-zinc-950">
                      Delivery Work
                    </p>
                    <%= if project_card.implementation_runs == [] do %>
                      <p class="mt-2 text-sm/6 text-zinc-500">
                        Accepted recommendations will appear here once you start delivery.
                      </p>
                    <% else %>
                      <div :for={run <- project_card.implementation_runs} class="mt-2 rounded-lg border border-zinc-950/10 px-3 py-2">
                        <div class="flex items-center justify-between gap-3">
                          <p class="text-sm/6 font-medium text-zinc-950"><%= implementation_run_status_label(run.status) %></p>
                          <span class="text-xs/5 text-zinc-500"><%= run.repo_full_name || "repo pending" %></span>
                        </div>
                        <p class="mt-2 text-sm/6 text-zinc-600"><%= run.result_summary %></p>
                        <div class="mt-2 flex flex-wrap items-center gap-3 text-xs/5 text-zinc-500">
                          <%= if run.branch_name do %>
                            <span>Branch: <code><%= run.branch_name %></code></span>
                          <% end %>
                          <%= if run.pull_request_url do %>
                            <a
                              href={run.pull_request_url}
                              target="_blank"
                              rel="noreferrer"
                              class="font-medium text-emerald-700 hover:text-emerald-800"
                            >
                              Open PR
                            </a>
                          <% end %>
                          <%= if get_in(run.metadata || %{}, ["plan_file_path"]) do %>
                            <span>Delivery plan recorded</span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @projects == [] do %>
            <p class="text-sm/6 text-zinc-500 xl:col-span-2">
              Create a project, add the active work, then attach an automation to recommend next moves.
            </p>
          <% end %>
        </div>
      </section>

      <%= if show_onboarding_preview?(@onboarding_preview_eligible?, @agents) do %>
        <.panel id="proof-of-value" body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div class="flex flex-wrap items-center gap-2">
                  <.heading level={2} class="text-base/7">3 things Maraithon would have caught this week</.heading>
                  <.badge color="emerald" class="bg-white">
                    Preview
                  </.badge>
                </div>
                <.text class="mt-1">
                  Recent examples from your connected accounts. This preview shows what Maraithon can catch continuously once you start an automation.
                </.text>
              </div>
              <.button
                type="button"
                phx-click="refresh_onboarding_preview"
                variant="outline"
                class="text-emerald-800"
              >
                Refresh preview
              </.button>
            </div>
          </:header>

          <div class="divide-y divide-zinc-950/5">
            <%= case @onboarding_preview.status do %>
              <% :loading -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 font-medium text-zinc-950">Checking recent activity...</p>
                  <p class="mt-1 text-sm/6 text-zinc-600">
                    Maraithon is checking recent activity from your linked accounts and selecting the most useful examples.
                  </p>
                </div>
              <% :ready when @onboarding_preview.items == [] -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 font-medium text-zinc-950">No follow-ups need attention in this preview.</p>
                  <p class="mt-1 text-sm/6 text-zinc-600">
                    That is a good sign. Once you start an automation, Maraithon checks quietly and only interrupts for concrete follow-through risk.
                  </p>
                </div>
              <% :ready -> %>
                <%= for item <- @onboarding_preview.items do %>
                  <div class="px-4 py-4 sm:px-6">
                    <div class="flex flex-wrap items-start justify-between gap-4">
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <span class={preview_source_class(item.source)}>
                            <%= preview_source_label(item.source) %>
                          </span>
                          <span class="text-xs/5 text-zinc-500">
                            <%= item.account_label %>
                          </span>
                        </div>
                        <p class="mt-2 text-base/7 font-semibold text-zinc-950"><%= item.title %></p>
                        <p class="mt-1 text-sm/6 text-zinc-600"><%= item.summary %></p>
                        <p class="mt-2 text-xs/5 font-medium text-zinc-500">
                          Why this matters
                        </p>
                        <p class="mt-1 text-sm/6 text-zinc-600"><%= item.rationale %></p>
                        <p class="mt-2 text-sm/6 text-indigo-700">
                          <span class="font-medium">Recommended move:</span> <%= item.recommended_action %>
                        </p>
                      </div>
                      <div class="w-full max-w-xs rounded-lg border border-zinc-950/10 bg-zinc-50 p-4">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Best next step
                        </p>
                        <p class="mt-2 text-sm/6 font-medium text-zinc-950">
                          Start <%= onboarding_behavior_label(item.suggested_behavior) %>
                        </p>
                        <p class="mt-1 text-sm/6 text-zinc-600">
                          This automation is the best fit to catch this kind of loop continuously and escalate only when it matters.
                        </p>
                        <.button
                          navigate={"/agents/new?behavior=#{item.suggested_behavior}"}
                          class="mt-3"
                        >
                          Use this setup
                        </.button>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% :error -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Could not prepare recent examples.
                  </p>
                  <p class="mt-1 text-sm/6 text-zinc-600">
                    <%= @onboarding_preview.error ||
                      "Refresh the preview, or start with the automation builder." %>
                  </p>
                </div>
              <% _ -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 text-zinc-600">Connect Gmail, Calendar, or Slack to preview what Maraithon can catch for you.</p>
                </div>
            <% end %>
          </div>
        </.panel>
      <% end %>

      <section class="space-y-6">
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Actionable insights</h2>
          <span class="text-xs/5 text-zinc-500"><%= length(@insights) %> open</span>
        </div>

          <.insight_group
            title="Needs Action"
            subtitle="Threads that currently need a direct decision or reply."
            cards={@act_now_insights}
            expanded_insight_ids={@expanded_insight_ids}
            chief_of_staff_schedule={@chief_of_staff_schedule}
          />
          <.insight_group
            title="Watching"
            subtitle="Important threads Maraithon is tracking without asking you to act right now."
            cards={@monitor_insights}
            expanded_insight_ids={@expanded_insight_ids}
            chief_of_staff_schedule={@chief_of_staff_schedule}
          />

          <%= if @insights == [] do %>
            <p class="text-sm/6 text-zinc-500">
              Follow-ups will appear here after a Chief of Staff, Inbox and Calendar Assistant, or Slack Follow-through automation starts reviewing recent context.
            </p>
          <% end %>
      </section>

      <section>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Automation overview</h2>
          <.link navigate="/agents" class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950">
            All automations →
          </.link>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-4 xl:grid-cols-2">
          <%= for overview <- @agent_overviews do %>
            <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 p-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-base/7 font-semibold text-zinc-950">
                      <%= agent_display_name(overview.agent) %>
                    </h3>
                    <span class={agent_status_class(overview.agent.status)}>
                      <%= automation_status_label(overview.agent.status) %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs/5 text-zinc-500">
                    <%= automation_behavior_label(overview.agent.behavior) %>
                  </p>
                  <p :if={overview.project_name} class="mt-2 text-sm/6 text-zinc-600">
                    Project: <span class="font-medium text-zinc-950"><%= overview.project_name %></span>
                  </p>
                </div>

                <.button
                  navigate={"/agents?id=#{overview.agent.id}"}
                  variant="outline"
                  class="text-xs"
                >
                  Open
                </.button>
              </div>

              <div class="mt-4 grid grid-cols-3 gap-3">
                <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    Updates
                  </p>
                  <p class="mt-2 text-lg/7 font-semibold text-zinc-950">
                    <%= overview.inspection.event_count %>
                  </p>
                </div>
                <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    Pending actions
                  </p>
                  <p class="mt-2 text-lg/7 font-semibold text-zinc-950">
                    <%= overview.inspection.effect_counts.pending %>
                  </p>
                </div>
                <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    Next checks
                  </p>
                  <p class="mt-2 text-lg/7 font-semibold text-zinc-950">
                    <%= overview.inspection.job_counts.pending %>
                  </p>
                </div>
              </div>

              <div class={[
                "mt-4 grid grid-cols-1 gap-4",
                @diagnostics_visible && "lg:grid-cols-2"
              ]}>
                <div>
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Recent updates
                  </p>
                  <%= if overview.recent_activity == [] do %>
                    <p class="mt-2 text-sm/6 text-zinc-500">No recent updates recorded.</p>
                  <% else %>
                    <div class="mt-2 space-y-2">
                      <div
                        :for={activity <- overview.recent_activity}
                        class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3"
                      >
                        <div class="flex items-center justify-between gap-3">
                          <p class="text-sm/6 font-medium text-zinc-950"><%= event_type_label(activity.event_type) %></p>
                          <span class="text-xs/5 text-zinc-500"><%= format_time(activity.inserted_at) %></span>
                        </div>
                        <p class="mt-2 text-xs/5 text-zinc-500"><%= event_preview(activity) %></p>
                      </div>
                    </div>
                  <% end %>
                </div>

                <div :if={@diagnostics_visible}>
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Technical notes
                  </p>
                  <%= if overview.inspection.recent_logs == [] do %>
                    <p class="mt-2 text-sm/6 text-zinc-500">No technical notes are available for this automation.</p>
                  <% else %>
                    <div class="mt-2 space-y-2">
                      <div
                        :for={log <- overview.inspection.recent_logs}
                        class="rounded-lg border border-zinc-950 bg-zinc-950 px-3 py-3"
                      >
                        <div class="flex items-center justify-between gap-3">
                          <span class={["text-xs/5 font-semibold", log_level_class(log.level)]}>
                            <%= log.level %>
                          </span>
                          <span class="text-xs/5 text-zinc-500">
                            <%= format_log_timestamp(log.timestamp) %>
                          </span>
                        </div>
                        <p class="mt-2 text-xs/5 text-zinc-100"><%= log_message_preview(log) %></p>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%= if overview.errors != [] do %>
                <.alert color="amber" class="mt-4">
                  <p class="text-sm/6 font-medium"><%= List.first(overview.errors).message %></p>
                  <p class="mt-1 text-xs/5"><%= List.first(overview.errors).details %></p>
                </.alert>
              <% end %>
            </div>
          <% end %>

          <%= if @agent_overviews == [] do %>
            <p class="text-sm/6 text-zinc-500 xl:col-span-2">
              Start a Chief of Staff or specialist automation to begin reviewing active work.
            </p>
          <% end %>
        </div>
      </section>

      <section :if={@diagnostics_visible}>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Health</h2>
          <span class={[health_badge_class(@health.status), "whitespace-nowrap"]}>
            <%= @health.status %>
          </span>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-x-8 gap-y-6 lg:grid-cols-2">
          <dl class="space-y-2 text-sm/6">
            <.health_row
              label="Database"
              value={to_string(@health.checks.database)}
              value_class={
                if @health.checks.database == :ok,
                  do: "text-emerald-700 font-medium",
                  else: "text-red-600 font-medium"
              }
            />
            <.health_row label="Memory" value={"#{@health.checks.memory_mb} MB"} />
            <.health_row label="Uptime" value={format_uptime(@health.checks.uptime_seconds)} />
            <.health_row
              label="Version"
              value={@health.version || "n/a"}
              value_class="font-mono text-xs/5 text-zinc-950"
            />
          </dl>

          <div class="space-y-5">
            <.queue_strip
              title="Effects queue"
              metrics={[
                %{label: "pending", value: @queue_metrics.effects.pending},
                %{label: "claimed", value: @queue_metrics.effects.claimed},
                %{label: "completed", value: @queue_metrics.effects.completed},
                %{
                  label: "failed",
                  value: @queue_metrics.effects.failed,
                  emphasis:
                    if(@queue_metrics.effects.failed > 0, do: "text-red-700", else: nil)
                }
              ]}
            />
            <.queue_strip
              title="Scheduled jobs"
              metrics={[
                %{label: "pending", value: @queue_metrics.jobs.pending},
                %{
                  label: "dispatched",
                  value: @queue_metrics.jobs.dispatched,
                  emphasis:
                    if(@queue_metrics.jobs.dispatched > 0, do: "text-amber-700", else: nil)
                },
                %{label: "delivered", value: @queue_metrics.jobs.delivered},
                %{label: "cancelled", value: @queue_metrics.jobs.cancelled}
              ]}
            />
          </div>
        </div>
      </section>

      <details :if={@diagnostics_visible} class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Operational activity</span>
            <span class="text-xs/5 text-zinc-500">
              <%= length(@recent_activity) %> events · <%= length(@recent_failures) %> failures
            </span>
          </span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Show</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Hide</span>
        </summary>
        <div class="grid grid-cols-1 gap-0 border-t border-zinc-950/10 lg:grid-cols-2 lg:divide-x lg:divide-zinc-950/5">
          <div class="px-4 py-4 sm:px-6">
            <p class="text-xs/5 font-medium text-zinc-500">Recent events</p>
            <div class="mt-2 max-h-80 space-y-2 overflow-y-auto">
              <div
                :for={activity <- @recent_activity}
                class="rounded-lg border border-zinc-950/10 p-3"
              >
                <div class="flex items-center justify-between gap-3">
                  <div class="truncate text-sm/6 font-medium text-zinc-950">
                    <%= activity.event_type %>
                  </div>
                  <div class="text-xs/5 text-zinc-500">
                    <%= format_time(activity.inserted_at) %>
                  </div>
                </div>
                <div class="mt-1 text-xs/5 text-zinc-500">
                  <span class="font-medium"><%= activity.behavior %></span>
                  <span class="mx-1">·</span>
                  <span class="font-mono"><%= short_id(activity.agent_id) %></span>
                </div>
                <div class="mt-2 rounded-md bg-zinc-50 px-2 py-1 text-xs/5 text-zinc-600">
                  <%= event_preview(activity) %>
                </div>
              </div>
              <%= if @recent_activity == [] do %>
                <p class="text-sm/6 text-zinc-500">No operational events have been recorded in this window.</p>
              <% end %>
            </div>
          </div>

          <div class="px-4 py-4 sm:px-6">
            <p class="text-xs/5 font-medium text-zinc-500">Needs attention</p>
            <div class="mt-2 max-h-80 space-y-2 overflow-y-auto">
              <div
                :for={failure <- @recent_failures}
                class="rounded-lg border border-red-200 bg-red-50/40 p-3"
              >
                <div class="flex items-center justify-between gap-3">
                  <div class="truncate text-sm/6 font-medium text-red-700">
                    <%= failure.type %> (<%= failure.source %>)
                  </div>
                  <div class="text-xs/5 text-zinc-500">
                    <%= format_time(failure.inserted_at) %>
                  </div>
                </div>
                <div class="mt-1 text-xs/5 text-zinc-500">
                  <span class="font-medium"><%= failure.behavior %></span>
                  <span class="mx-1">·</span>
                  <span class="font-mono"><%= short_id(failure.agent_id) %></span>
                  <span class="mx-1">·</span>
                  <span class="font-medium"><%= failure.status %></span>
                  <span class="mx-1">·</span>
                  <span>attempts <%= failure.attempts %></span>
                </div>
                <div class="mt-2 break-all rounded-md bg-white px-2 py-1 font-mono text-xs/5 text-zinc-700">
                  <%= failure_details_preview(failure) %>
                </div>
              </div>
              <%= if @recent_failures == [] do %>
                <p class="text-sm/6 text-zinc-500">No failures detected.</p>
              <% end %>
            </div>
          </div>
        </div>
      </details>

      <details :if={@diagnostics_visible} class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>System logs</span>
            <span class="text-xs/5 text-zinc-500">recent activity</span>
          </span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Show</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Hide</span>
        </summary>
        <div class="max-h-[28rem] overflow-y-auto border-t border-zinc-950/10 px-4 py-3 font-mono text-[11px] leading-5 sm:px-6">
          <%= for log <- @recent_logs do %>
            <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-zinc-950/5 py-1.5 last:border-0">
              <span class="text-zinc-500"><%= format_log_timestamp(log.timestamp) %></span>
              <span class={["font-semibold", log_level_text_class(log.level)]}>
                <%= log.level %>
              </span>
              <div class="min-w-0">
                <span class="break-words whitespace-pre-wrap text-zinc-700">
                  <%= log_message_preview(log) %>
                </span>
              </div>
            </div>
          <% end %>
          <%= if @recent_logs == [] do %>
            <p class="font-sans text-sm/6 text-zinc-500">No recent system logs are available in this window.</p>
          <% end %>
        </div>
      </details>

      <details :if={@diagnostics_visible} class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Platform logs</span>
            <span class="text-xs/5 text-zinc-500">deployment health</span>
          </span>
          <span class="flex items-center gap-3">
            <button
              type="button"
              phx-click="refresh_fly_logs"
              class="rounded-md border border-zinc-950/10 px-2 py-0.5 text-xs/5 font-medium text-zinc-700 hover:bg-zinc-950/5"
            >
              Refresh
            </button>
            <span class="text-xs/5 text-zinc-500 group-open:hidden">Show</span>
            <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Hide</span>
          </span>
        </summary>
        <div class="border-t border-zinc-950/10">
          <div :if={@fly_logs.apps != []} class="flex flex-wrap gap-1.5 px-4 pt-3 sm:px-6">
            <span
              :for={app <- @fly_logs.apps}
              class="rounded-md border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"
            >
              <%= app %>
            </span>
          </div>

          <div class="max-h-[28rem] overflow-y-auto px-4 py-3 font-mono text-[11px] leading-5 sm:px-6">
            <%= for error <- @fly_logs.errors do %>
              <div class="mb-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-red-800">
                <%= if error[:app] do %>
                  <span class="mr-2 font-semibold"><%= error.app %></span>
                <% end %>
                <span><%= error.message %></span>
              </div>
            <% end %>

            <%= if not @fly_logs.available and @fly_logs.apps == [] do %>
              <p class="font-sans text-sm/6 text-zinc-500">
                Platform log access is unavailable in this environment.
              </p>
            <% else %>
              <%= if @fly_logs.logs == [] do %>
                <p class="font-sans text-sm/6 text-zinc-500">No platform logs were returned for the configured apps.</p>
              <% else %>
                <%= for log <- @fly_logs.logs do %>
                  <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-zinc-950/5 py-1.5 last:border-0">
                    <span class="text-zinc-500"><%= format_log_timestamp(log.timestamp) %></span>
                    <span class={["font-semibold", log_level_text_class(log.level)]}>
                      <%= log.level %>
                    </span>
                    <div class="min-w-0">
                      <%= if app = fly_log_app_label(log) do %>
                        <span class="mr-2 text-zinc-500"><%= app %></span>
                      <% end %>
                      <span class="break-words whitespace-pre-wrap text-zinc-700">
                        <%= public_log_message(log.message) %>
                      </span>
                    </div>
                  </div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      </details>
      </div>
    </Layouts.app>
    """
  end

  defp save_agent(socket, launch, start_params) do
    case socket.assigns.editing_agent_id do
      nil ->
        case Runtime.start_agent(start_params) do
          {:ok, agent} ->
            {:noreply,
             socket
             |> assign(
               launch: default_launch_params(),
               launch_error: nil,
               launch_mode: :create,
               editing_agent_id: nil
             )
             |> refresh_dashboard()
             |> put_flash(:info, AgentActionCopy.success(:create, agent_display_name(agent)))
             |> push_patch(to: "/dashboard?id=#{agent.id}")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, launch: launch, launch_error: message)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: AgentActionCopy.error(:create, changeset)
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: AgentActionCopy.error(:create, reason)
             )}
        end

      id ->
        case Runtime.update_agent(id, start_params) do
          {:ok, agent} ->
            {:noreply,
             socket
             |> assign(
               launch: default_launch_params(),
               launch_error: nil,
               launch_mode: :create,
               editing_agent_id: nil
             )
             |> refresh_dashboard()
             |> refresh_if_selected(id)
             |> put_flash(:info, AgentActionCopy.success(:update, agent_display_name(agent)))
             |> push_patch(to: "/dashboard?id=#{agent.id}")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, launch: launch, launch_error: message)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: AgentActionCopy.error(:update, changeset)
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: AgentActionCopy.error(:update, reason)
             )}
        end
    end
  end

  defp send_admin_message(socket, agent_id, message) do
    case Runtime.send_message(agent_id, message, %{"source" => "admin_console"}) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(command: %{"message" => ""})
         |> refresh_if_selected(agent_id)
         |> put_flash(:info, "Message sent to automation")}

      {:error, :not_found} ->
        {:noreply,
         socket |> refresh_dashboard() |> put_flash(:error, AgentActionCopy.not_found())}

      {:error, :agent_stopped} ->
        {:noreply,
         put_flash(socket, :error, AgentActionCopy.error(:send_message, :agent_stopped))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AgentActionCopy.error(:send_message, reason))}
    end
  end

  defp refresh_dashboard(socket, opts \\ []) do
    # Timer ticks use :light scope: the slow, rarely-changing panels
    # (install state, insights, connections, projects, memory) reload only
    # on mount, navigation, and user actions.
    socket =
      if Keyword.get(opts, :scope, :full) == :full do
        socket
        |> refresh_chief_of_staff_install()
        |> refresh_insights()
        |> refresh_connections()
        |> refresh_projects()
        |> refresh_global_memory()
      else
        socket
      end

    socket = refresh_todos(socket)

    user_id = current_user_id(socket)

    socket =
      case Admin.safe_control_center_snapshot(
             user_id: user_id,
             activity_limit: @activity_limit,
             failure_limit: @failure_limit
           ) do
        {:ok, snapshot} ->
          assign(socket,
            agents: snapshot.agents,
            total_spend: snapshot.total_spend,
            health: snapshot.health,
            queue_metrics: snapshot.queue_metrics,
            recent_activity: snapshot.recent_activity,
            recent_failures: snapshot.recent_failures,
            recent_logs: snapshot.recent_logs,
            dashboard_errors: snapshot.errors
          )

        {:degraded, snapshot} ->
          assign(socket,
            health: snapshot.health,
            recent_logs: snapshot.recent_logs,
            dashboard_errors: snapshot.errors
          )
      end

    socket =
      if Keyword.get(opts, :include_fly_logs, false) do
        refresh_fly_logs(socket)
      else
        socket
      end

    socket =
      if socket.assigns.selected_agent do
        case refresh_selected_agent(socket, socket.assigns.selected_agent.id,
               health: socket.assigns.health
             ) do
          {:ok, socket} -> socket
          {:not_found, socket} -> socket
        end
      else
        socket
      end

    socket = refresh_agent_overviews(socket)

    maybe_start_onboarding_preview(socket, opts)
  end

  defp refresh_insights(socket) do
    timezone_info = dashboard_timezone(socket.assigns.chief_of_staff_schedule)

    act_now_cards =
      Insights.list_open_act_now_with_details_for_user(current_user_id(socket),
        limit: 20,
        timezone_info: timezone_info
      )

    monitor_cards =
      Insights.list_open_monitor_with_details_for_user(current_user_id(socket),
        limit: 20,
        timezone_info: timezone_info
      )

    cards = act_now_cards ++ monitor_cards
    visible_ids = MapSet.new(Enum.map(cards, &to_string(&1.insight.id)))

    emit_insight_detail_coverage_telemetry(cards)

    assign(socket,
      insights: cards,
      act_now_insights: act_now_cards,
      monitor_insights: monitor_cards,
      expanded_insight_ids: MapSet.intersection(socket.assigns.expanded_insight_ids, visible_ids),
      detail_opened_insight_ids:
        MapSet.intersection(socket.assigns.detail_opened_insight_ids, visible_ids)
    )
  end

  defp insight_card(socket, insight_id) when is_binary(insight_id) do
    Enum.find(socket.assigns.insights, fn
      %{insight: %{id: id}} -> to_string(id) == insight_id
      _ -> false
    end)
  end

  defp insight_card(_socket, _insight_id), do: nil

  defp emit_insight_detail_toggle_telemetry(expanded?, insight, detail) do
    event =
      if expanded? do
        [:maraithon, :dashboard, :insight_detail, :collapsed]
      else
        [:maraithon, :dashboard, :insight_detail, :expanded]
      end

    :telemetry.execute(event, %{count: 1}, Detail.telemetry_metadata(insight, detail))
  end

  defp maybe_emit_insight_action_telemetry(
         socket,
         action,
         %{insight: insight, detail: detail},
         insight_id
       )
       when is_binary(action) do
    metadata =
      Detail.telemetry_metadata(insight, detail)
      |> Map.put(:action, action)
      |> Map.put(
        :detail_opened_before_action,
        MapSet.member?(socket.assigns.detail_opened_insight_ids, insight_id)
      )

    :telemetry.execute([:maraithon, :dashboard, :insight_detail, :action], %{count: 1}, metadata)
  end

  defp maybe_emit_insight_action_telemetry(_socket, _action, _card, _insight_id), do: :ok

  defp emit_insight_detail_coverage_telemetry(cards) when is_list(cards) do
    :telemetry.execute(
      [:maraithon, :dashboard, :insight_detail, :coverage],
      Detail.coverage_measurements(cards),
      %{source: :dashboard_refresh}
    )
  end

  defp refresh_selected_agent(socket, id, opts \\ []) do
    case Admin.safe_agent_snapshot(
           id,
           user_id: current_user_id(socket),
           event_limit: @event_limit,
           log_limit: 80,
           health: Keyword.get(opts, :health, socket.assigns.health)
         ) do
      {:ok, snapshot} ->
        {:ok,
         assign(socket,
           selected_agent: snapshot.agent,
           events: snapshot.events,
           agent_spend: snapshot.spend,
           inspection: snapshot.inspection,
           inspection_errors: snapshot.errors
         )}

      {:degraded, snapshot} ->
        inspection =
          if socket.assigns.selected_agent && socket.assigns.selected_agent.id == id do
            merge_degraded_inspection(socket.assigns.inspection, snapshot.inspection)
          else
            snapshot.inspection
          end

        {:ok,
         assign(socket,
           selected_agent: socket.assigns.selected_agent,
           inspection: inspection,
           inspection_errors: snapshot.errors
         )}

      {:error, :not_found} ->
        {:not_found,
         assign(socket,
           selected_agent: nil,
           events: [],
           agent_spend: nil,
           inspection: empty_inspection(),
           inspection_errors: [],
           page_title: "Control Center"
         )}
    end
  end

  defp refresh_if_selected(socket, id) do
    if socket.assigns.selected_agent && socket.assigns.selected_agent.id == id do
      case refresh_selected_agent(socket, id) do
        {:ok, socket} -> socket
        {:not_found, socket} -> socket
      end
    else
      socket
    end
  end

  defp maybe_reset_editor(socket, id) do
    if socket.assigns.editing_agent_id == id do
      assign(socket,
        launch: default_launch_params(),
        launch_error: nil,
        launch_mode: :create,
        editing_agent_id: nil
      )
    else
      socket
    end
  end

  defp default_launch_params do
    AgentBuilder.default_launch_params()
  end

  defp default_project_form_params do
    %{"name" => "", "summary" => "", "description" => "", "priority" => "normal"}
  end

  defp default_project_item_form_params do
    %{"project_id" => "", "item_type" => "note", "title" => "", "content" => ""}
  end

  defp launch_params_from_agent(agent), do: AgentBuilder.launch_params_from_agent(agent)

  defp normalize_launch_params(params), do: AgentBuilder.normalize_launch_params(params)

  defp build_agent_start_params(launch, user_id),
    do: AgentBuilder.build_start_params(launch, user_id)

  defp empty_spend do
    %{
      total_cost: 0.0,
      input_tokens: 0,
      output_tokens: 0,
      llm_calls: 0
    }
  end

  defp empty_inspection do
    %{
      event_count: 0,
      effect_counts: %{pending: 0, claimed: 0, completed: 0, failed: 0, cancelled: 0},
      recent_effects: [],
      job_counts: %{pending: 0, dispatched: 0, delivered: 0, cancelled: 0},
      recent_jobs: [],
      recent_logs: []
    }
  end

  defp merge_degraded_inspection(current, degraded) do
    %{current | recent_logs: degraded.recent_logs}
  end

  defp empty_onboarding_preview do
    %{
      status: :idle,
      items: [],
      sources: [],
      generated_at: nil,
      error: nil
    }
  end

  defp empty_memory_profile do
    %{
      summary: "Maraithon is still learning how you prefer to work.",
      profile: %{},
      confidence: 0.0,
      source_window_start: nil,
      source_window_end: nil,
      updated_at: nil
    }
  end

  defp empty_fly_logs do
    %{
      available: false,
      apps: [],
      logs: [],
      next_tokens: %{},
      errors: []
    }
  end

  defp refresh_fly_logs(socket) do
    case Admin.fly_logs(limit: 120) do
      {:ok, snapshot} ->
        assign(socket, fly_logs: sanitize_fly_logs(snapshot))

      {:error, reason} ->
        assign(socket,
          fly_logs: %{
            available: false,
            apps: [],
            logs: [],
            next_tokens: %{},
            errors: [%{app: nil, message: OperationFailureCopy.fly_logs(reason)}]
          }
        )
    end
  end

  defp admin_user?(%{is_admin: true}), do: true
  defp admin_user?(_current_user), do: false

  defp sanitize_fly_logs(snapshot) when is_map(snapshot) do
    errors =
      snapshot
      |> Map.get(:errors, [])
      |> Enum.map(fn
        %{app: app} -> %{app: app, message: OperationFailureCopy.fly_logs(:snapshot_error)}
        _ -> %{app: nil, message: OperationFailureCopy.fly_logs(:snapshot_error)}
      end)

    Map.put(snapshot, :errors, errors)
  end

  defp refresh_connections(socket) do
    case Connections.safe_dashboard_snapshot(
           socket.assigns.connection_user_id,
           return_to: connection_return_to(socket)
         ) do
      {:ok, snapshot} ->
        assign(socket,
          connected_provider_count: snapshot.connected_count,
          connections: snapshot.providers,
          raw_connections: snapshot.raw_tokens,
          connection_errors: snapshot.errors
        )

      {:degraded, snapshot} ->
        assign(socket,
          connected_provider_count: snapshot.connected_count,
          connections: snapshot.providers,
          raw_connections: snapshot.raw_tokens,
          connection_errors: snapshot.errors
        )
    end
  end

  defp refresh_chief_of_staff_install(socket) do
    user_id = current_user_id(socket)
    package = chief_of_staff_package()
    required_connectors = AgentMarketplace.required_connectors_for("ai_chief_of_staff")

    readiness =
      user_id
      |> Connections.connector_readiness(required_connectors, return_to: "/dashboard")
      |> include_connected_chief_of_staff_telegram_readiness(user_id)
      |> include_connected_chief_of_staff_optional_readiness(
        user_id,
        AgentMarketplace.optional_connectors_for("ai_chief_of_staff")
      )

    assign(socket,
      chief_of_staff_package: package,
      chief_of_staff_readiness: readiness,
      chief_of_staff_agent:
        Agents.get_package_installation(user_id, "ai_chief_of_staff", preload: [:project]),
      chief_of_staff_schedule: BriefingSchedules.summarize_for_prompt(user_id)
    )
  end

  # Delivery is optional. A disconnected Telegram account must not prevent a
  # consented Chief from reading the sources it actually has (Gmail, Calendar,
  # and any connected Slack workspace). When Telegram is connected it remains
  # part of the same explicit consent envelope and enables brief delivery.
  defp include_connected_chief_of_staff_telegram_readiness(readiness, user_id)
       when is_list(readiness) and is_binary(user_id) do
    case ConnectedAccounts.get(user_id, "telegram") do
      %{status: "connected"} ->
        readiness ++
          [
            %{
              provider: "telegram",
              service: "delivery",
              label: "Telegram",
              status: :connected,
              connected?: true,
              connect_path: "/connectors/telegram?return_to=%2Fdashboard",
              details: "Delivers Chief of Staff briefs and follow-through."
            }
          ]

      _disconnected_or_unhealthy ->
        readiness
    end
  end

  defp include_connected_chief_of_staff_telegram_readiness(readiness, _user_id), do: readiness

  # Slack enriches the Chief when it is connected, but it must not turn an
  # otherwise-ready Gmail/Calendar installation into a setup-required state.
  # Only healthy optional services are added, so the consent envelope mirrors
  # every source the enabled Chief can actually read.
  defp include_connected_chief_of_staff_optional_readiness(readiness, user_id, connectors)
       when is_list(readiness) and is_binary(user_id) and is_map(connectors) do
    connected_optional_services =
      user_id
      |> Connections.connector_readiness(connectors, return_to: "/dashboard")
      |> Enum.filter(& &1.connected?)

    Enum.reduce(connected_optional_services, readiness, fn optional_service, services ->
      if Enum.any?(services, &same_connector_service?(&1, optional_service)) do
        services
      else
        services ++ [optional_service]
      end
    end)
  end

  defp include_connected_chief_of_staff_optional_readiness(readiness, _user_id, _connectors),
    do: readiness

  defp chief_of_staff_package do
    case Agents.get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version]) do
      nil ->
        _ = AgentMarketplace.sync_builtin_packages()
        Agents.get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version])

      package ->
        package
    end
  end

  defp refresh_projects(socket) do
    user_id = current_user_id(socket)

    projects =
      Projects.list_projects(user_id: user_id, preload: [:agents])
      |> Enum.map(fn project ->
        %{
          project: project,
          agents: project.agents,
          items: Projects.list_project_items(user_id: user_id, project_id: project.id, limit: 4),
          recommendations: Projects.list_project_recommendations(project.id, user_id, limit: 3),
          repo_grants:
            Projects.list_repo_grants(project_id: project.id, user_id: user_id, limit: 3),
          implementation_runs:
            Projects.list_implementation_runs(project_id: project.id, user_id: user_id, limit: 3)
        }
      end)

    assign(socket, :projects, projects)
  end

  defp refresh_global_memory(socket) do
    user_id = current_user_id(socket)

    assign(
      socket,
      global_memory_summaries: OperatorMemory.summaries_for_prompt(user_id),
      memory_profile: UserMemory.prompt_context(user_id),
      memory_rules: PreferenceMemory.active_rules(user_id)
    )
  end

  defp refresh_todos(socket) do
    user_id = current_user_id(socket)
    todos = Todos.list_for_user(user_id, limit: 50, statuses: ["open", "snoozed"])
    decided_ids = prune_todo_review_decided_ids(socket.assigns.todo_review_decided_ids, todos)
    reviewable_count = length(reviewable_todos(todos, decided_ids))
    visible_ids = todos |> Enum.map(& &1.id) |> MapSet.new()
    selected_todo_ids = MapSet.intersection(socket.assigns.selected_todo_ids, visible_ids)

    assign(socket,
      todos: todos,
      open_todo_count: length(todos),
      todo_review_decided_ids: decided_ids,
      todo_review_index:
        clamp_review_index(Map.get(socket.assigns, :todo_review_index, 0), reviewable_count),
      selected_todo_ids: selected_todo_ids,
      selected_todo: selected_todo_for_user(user_id, socket.assigns.selected_todo_id)
    )
  end

  defp increment_todo_review_session(socket, key)
       when key in [:completed, :dismissed, :kept, :important] do
    session =
      socket.assigns
      |> Map.get(:todo_review_session, %{})
      |> Map.update(key, 1, &(&1 + 1))

    assign(socket, :todo_review_session, session)
  end

  defp mark_todo_reviewed(socket, todo_id) when is_binary(todo_id) do
    decided_ids =
      socket.assigns
      |> Map.get(:todo_review_decided_ids, MapSet.new())
      |> MapSet.put(todo_id)

    assign(socket, :todo_review_decided_ids, decided_ids)
  end

  defp mark_todo_reviewed(socket, _todo_id), do: socket

  defp clamp_todo_review_index(socket) do
    reviewable_count = reviewable_todo_count(socket)

    assign(
      socket,
      :todo_review_index,
      clamp_review_index(socket.assigns.todo_review_index, reviewable_count)
    )
  end

  defp reviewable_todo_count(socket) do
    socket.assigns.todos
    |> reviewable_todos(Map.get(socket.assigns, :todo_review_decided_ids, MapSet.new()))
    |> length()
  end

  defp apply_bulk_todo_action(socket, action) do
    todo_ids = selected_visible_todo_ids(socket)

    if todo_ids == [] do
      put_flash(socket, :error, "Select at least one work item first")
    else
      {updated_count, errors} =
        Enum.reduce(todo_ids, {0, []}, fn todo_id, {count, errors} ->
          case run_todo_action(action, current_user_id(socket), todo_id, bulk_todo_note(action)) do
            {:ok, _todo} -> {count + 1, errors}
            {:error, reason} -> {count, [{todo_id, reason} | errors]}
          end
        end)

      socket =
        socket
        |> assign(:selected_todo_ids, MapSet.new())
        |> refresh_dashboard()

      put_flash(
        socket,
        bulk_todo_flash_kind(updated_count, errors),
        bulk_todo_flash(action, updated_count, errors)
      )
    end
  end

  defp run_todo_action(:complete, user_id, todo_id, note),
    do: Todos.mark_done(user_id, todo_id, todo_action_opts(user_id, note))

  defp run_todo_action(:dismiss, user_id, todo_id, note),
    do: Todos.dismiss(user_id, todo_id, todo_action_opts(user_id, note))

  defp todo_action_opts(user_id, note), do: Keyword.put(todo_actor_opts(user_id), :note, note)

  defp todo_actor_opts(user_id),
    do: [actor_type: "user", actor_id: user_id, actor_label: "User"]

  defp bulk_todo_note(:complete), do: "Completed from dashboard bulk action."
  defp bulk_todo_note(:dismiss), do: "Dismissed from dashboard bulk action."

  defp bulk_todo_flash_kind(0, [_ | _]), do: :error
  defp bulk_todo_flash_kind(_updated_count, _errors), do: :info

  defp bulk_todo_flash(action, updated_count, errors) do
    base =
      case action do
        :complete -> "Marked #{pluralize_work_item(updated_count)} done"
        :dismiss -> "Dismissed #{pluralize_work_item(updated_count)}"
      end

    case length(errors) do
      0 -> base
      error_count -> "#{base}; #{error_count} could not be updated"
    end
  end

  defp pluralize_work_item(1), do: "1 work item"
  defp pluralize_work_item(count), do: "#{count} work items"

  defp pluralize(1, label), do: "1 #{label}"
  defp pluralize(count, label), do: "#{count} #{label}s"

  defp review_ready_label(1), do: "1 open work item is ready to review."
  defp review_ready_label(count), do: "#{count} open work items are ready to review."

  defp remaining_today_label(1), do: "1 open work item remains in Today."
  defp remaining_today_label(count), do: "#{count} open work items remain in Today."

  defp selected_visible_todo_ids(socket) do
    socket.assigns.selected_todo_ids
    |> MapSet.intersection(visible_todo_ids(socket))
    |> MapSet.to_list()
  end

  defp visible_todo_id?(socket, todo_id) when is_binary(todo_id) do
    MapSet.member?(visible_todo_ids(socket), todo_id)
  end

  defp visible_todo_id?(_socket, _todo_id), do: false

  defp visible_todo_ids(socket) do
    socket.assigns.todos
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp all_visible_todos_selected?([], _selected_todo_ids), do: false

  defp all_visible_todos_selected?(todos, selected_todo_ids) when is_list(todos) do
    visible_ids = todos |> Enum.map(& &1.id) |> MapSet.new()
    MapSet.subset?(visible_ids, selected_todo_ids)
  end

  defp all_visible_todos_selected?(_todos, _selected_todo_ids), do: false

  defp toggle_mapset_member(mapset, value) do
    if MapSet.member?(mapset, value) do
      MapSet.delete(mapset, value)
    else
      MapSet.put(mapset, value)
    end
  end

  defp selected_todo_for_user(_user_id, nil), do: nil
  defp selected_todo_for_user(_user_id, ""), do: nil

  defp selected_todo_for_user(user_id, todo_id) when is_binary(user_id) and is_binary(todo_id) do
    Todos.get_for_user(user_id, todo_id)
  end

  defp selected_todo_for_user(_user_id, _todo_id), do: nil

  defp todo_detail_path(nil), do: "/dashboard"
  defp todo_detail_path(todo_id), do: "/dashboard?todo_id=#{URI.encode_www_form(todo_id)}"

  defp refresh_agent_overviews(socket) do
    projects_by_id =
      Map.new(socket.assigns.projects, fn %{project: project} -> {project.id, project.name} end)

    recent_activity_by_agent =
      socket.assigns.recent_activity
      |> Enum.filter(&agent_overview_activity_visible?(&1, socket.assigns.diagnostics_visible))
      |> Enum.group_by(& &1.agent_id)

    user_id = current_user_id(socket)
    max_concurrency = max(1, min(length(socket.assigns.agents), 4))

    overviews =
      socket.assigns.agents
      |> Task.async_stream(
        fn agent ->
          snapshot =
            case Admin.safe_agent_snapshot(
                   agent.id,
                   user_id: user_id,
                   event_limit: 4,
                   effect_limit: 3,
                   job_limit: 3,
                   log_limit: 4,
                   health: socket.assigns.health
                 ) do
              {:ok, snapshot} ->
                %{inspection: snapshot.inspection, errors: []}

              {:degraded, snapshot} ->
                %{inspection: snapshot.inspection, errors: snapshot.errors}

              {:error, :not_found} ->
                %{inspection: empty_inspection(), errors: []}
            end

          %{
            agent: agent,
            project_name: Map.get(projects_by_id, agent.project_id),
            recent_activity: Map.get(recent_activity_by_agent, agent.id, []) |> Enum.take(3),
            inspection: snapshot.inspection,
            errors: snapshot.errors
          }
        end,
        ordered: true,
        timeout: :infinity,
        max_concurrency: max_concurrency
      )
      |> Enum.map(fn {:ok, overview} -> overview end)

    assign(socket, :agent_overviews, overviews)
  end

  defp agent_overview_activity_visible?(_activity, true), do: true

  defp agent_overview_activity_visible?(%{event_type: event_type}, false)
       when is_binary(event_type) do
    normalized = String.downcase(event_type)
    not String.contains?(normalized, ["fail", "error", "exception"])
  end

  defp agent_overview_activity_visible?(_activity, false), do: true

  defp maybe_start_onboarding_preview(socket, opts) do
    preview = socket.assigns.onboarding_preview
    force? = Keyword.get(opts, :force, false)
    user_id = current_user_id(socket)

    cond do
      not show_onboarding_preview?(
        socket.assigns.onboarding_preview_eligible?,
        socket.assigns.agents
      ) ->
        assign(socket, :onboarding_preview, %{empty_onboarding_preview() | status: :hidden})

      preview.status == :loading and not force? ->
        socket

      preview.status == :ready and not force? ->
        socket

      preview.status == :error and not force? ->
        socket

      true ->
        socket
        |> assign(:onboarding_preview, %{empty_onboarding_preview() | status: :loading})
        |> start_async(:onboarding_preview, fn ->
          onboarding_proof_module().preview(user_id)
        end)
    end
  end

  defp onboarding_proof_module do
    Application.get_env(:maraithon, :onboarding_proof_module, OnboardingProof)
  end

  defp apply_dashboard_params(socket, params, uri) do
    user_id = current_user_id(socket)

    socket =
      assign(socket,
        connection_user_id: user_id,
        connection_return_to: connection_return_to_from_uri(uri),
        onboarding_preview_eligible?: OnboardingProof.eligible?(user_id)
      )

    socket
    |> assign_selected_todo_from_params(params)
    |> maybe_put_oauth_flash(params)
  end

  defp assign_selected_todo_from_params(socket, params) do
    user_id = current_user_id(socket)
    todo_id = normalized_text(Map.get(params, "todo_id"))
    selected_todo = selected_todo_for_user(user_id, todo_id)

    assign(socket,
      selected_todo_id: selected_todo && selected_todo.id,
      selected_todo: selected_todo
    )
  end

  defp maybe_put_oauth_flash(socket, %{"oauth_status" => status, "oauth_message" => message})
       when status in @safe_oauth_statuses and is_binary(message) do
    kind = if status == "connected", do: :info, else: :error
    put_flash(socket, kind, OAuthFlashCopy.message(status, message))
  end

  defp maybe_put_oauth_flash(socket, _params), do: socket

  defp connection_return_to(socket) do
    socket.assigns.connection_return_to || "/dashboard"
  end

  defp connection_return_to_from_uri(uri) do
    uri = URI.parse(uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["oauth_message", "oauth_provider", "oauth_status"])
      |> URI.encode_query()

    %URI{path: uri.path || "/", query: query}
    |> URI.to_string()
  rescue
    _ -> "/dashboard"
  end

  defp current_path_from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/dashboard"
      "" -> "/dashboard"
      path -> path
    end
  rescue
    _ -> "/dashboard"
  end

  defp legacy_agents_path(%{"id" => _id} = params) do
    query =
      params
      |> Map.take(["id", "panel", "status", "q"])
      |> Enum.reject(fn
        {"panel", value} -> value not in ["inspect", "edit"]
        {"status", value} -> value in [nil, "", "all"]
        {"q", value} -> value in [nil, ""]
        {_key, value} -> is_nil(value) or value == ""
      end)
      |> URI.encode_query()

    case query do
      "" -> "/agents"
      encoded -> "/agents?" <> encoded
    end
  end

  defp legacy_agents_path(_params), do: nil

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp first_project_id([%{project: %{id: id}} | _]) when is_binary(id), do: id
  defp first_project_id(_projects), do: nil

  defp chief_of_staff_summary(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp chief_of_staff_summary(_package) do
    "Daily briefing, follow-through, commitment tracking, and Telegram delivery for one project."
  end

  defp chief_of_staff_install_state(%{install_status: "setup_required"}, readiness, _projects) do
    if chief_of_staff_missing_readiness(readiness) == [] do
      "Ready to enable"
    else
      "Sources needed"
    end
  end

  defp chief_of_staff_install_state(%{install_status: install_status}, _readiness, _projects),
    do: install_status_label(install_status)

  defp chief_of_staff_install_state(_agent, _readiness, []), do: "Project required"

  defp chief_of_staff_install_state(_agent, readiness, _projects) do
    if chief_of_staff_missing_readiness(readiness) == [] do
      "Ready to install"
    else
      "Sources needed"
    end
  end

  defp chief_of_staff_badge_label(nil), do: "Not installed"
  defp chief_of_staff_badge_label(%{install_status: status}), do: install_status_label(status)

  defp chief_of_staff_badge_color(nil), do: "zinc"
  defp chief_of_staff_badge_color(%{install_status: "enabled"}), do: "emerald"
  defp chief_of_staff_badge_color(%{install_status: "setup_required"}), do: "amber"
  defp chief_of_staff_badge_color(_agent), do: "zinc"

  defp chief_of_staff_missing_readiness(readiness) when is_list(readiness) do
    Enum.reject(readiness, & &1.connected?)
  end

  defp chief_of_staff_missing_readiness(_readiness), do: []

  defp chief_of_staff_consent_description(readiness) when is_list(readiness) do
    services =
      readiness
      |> Enum.filter(& &1.connected?)
      |> Enum.map(& &1.label)
      |> Enum.uniq()

    service_text =
      case services do
        [] -> "the connected sources"
        [service] -> service
        [first, second] -> "#{first} and #{second}"
        many -> "#{Enum.join(Enum.drop(many, -1), ", ")}, and #{List.last(many)}"
      end

    "Allow Chief of Staff to use #{service_text}, this project's memory, and the package's listed tools for briefs and follow-through."
  end

  defp chief_of_staff_consent_description(_readiness) do
    "Allow Chief of Staff to use the connected sources, this project's memory, and the package's listed tools for briefs and follow-through."
  end

  defp chief_of_staff_binding_consent(
         %{"binding_consent" => %{"acknowledged" => "true"}},
         user_id,
         project_id,
         %{latest_version: version},
         readiness
       )
       when is_binary(user_id) and is_binary(project_id) and is_list(readiness) do
    if chief_of_staff_missing_readiness(readiness) == [] and
         Ecto.assoc_loaded?(version) and not is_nil(version) do
      connector_scope =
        readiness
        |> Enum.group_by(&to_string(&1.provider), fn item ->
          if is_binary(item.service), do: item.service, else: "provider"
        end)
        |> Map.new(fn {provider, services} ->
          {provider, %{"services" => services |> Enum.uniq() |> Enum.sort()}}
        end)

      credential_refs =
        Map.new(connector_scope, fn {provider, _scope} ->
          {provider, "connected-account:#{user_id}:#{provider}"}
        end)

      %{
        "actor_id" => user_id,
        "user_id" => user_id,
        "identity_key" => "chief-of-staff:#{user_id}:#{project_id}",
        "credential_refs" => credential_refs,
        "connector_scope" => connector_scope,
        "memory_scope" => %{"project_id" => project_id},
        "tool_policy" => chief_of_staff_tool_policy(version, readiness),
        "routing_bindings" => chief_of_staff_routing_bindings(project_id, readiness),
        "metadata" => %{
          "source" => "dashboard_explicit_consent",
          "agent_package_version_id" => version.id
        }
      }
    end
  end

  defp chief_of_staff_binding_consent(_params, _user_id, _project_id, _package, _readiness),
    do: nil

  defp maybe_put_binding_consent(opts, consent) when is_map(consent),
    do: Keyword.put(opts, :binding_consent, consent)

  defp maybe_put_binding_consent(opts, _consent), do: opts

  defp chief_of_staff_delivery_policy(readiness) when is_list(readiness) do
    if chief_of_staff_telegram_connected?(readiness),
      do: %{"telegram" => "enabled"},
      else: %{"telegram" => "disabled"}
  end

  defp chief_of_staff_delivery_policy(_readiness), do: %{"telegram" => "disabled"}

  defp chief_of_staff_tool_policy(version, readiness) do
    allowed_tools = version.tool_allowlist || []

    allowed_tools =
      if chief_of_staff_telegram_connected?(readiness),
        do: allowed_tools,
        else: List.delete(allowed_tools, "telegram.send")

    %{
      "allowed_tools" => allowed_tools,
      "allowed_mcp_servers" => version.mcp_allowlist || []
    }
  end

  defp chief_of_staff_routing_bindings(project_id, readiness) do
    if chief_of_staff_telegram_connected?(readiness),
      do: %{"telegram" => "project:#{project_id}"},
      else: %{}
  end

  defp chief_of_staff_telegram_connected?(readiness) when is_list(readiness) do
    Enum.any?(readiness, fn item ->
      item.provider == "telegram" and item.service == "delivery" and item.connected?
    end)
  end

  defp chief_of_staff_telegram_connected?(_readiness), do: false

  defp same_connector_service?(left, right) do
    left.provider == right.provider and left.service == right.service
  end

  defp chief_of_staff_install_config(params) when is_map(params) do
    schedule = Map.get(params, "schedule") || %{}

    %{}
    |> maybe_put_integer_config(
      "morning_brief_hour_local",
      Map.get(schedule, "morning_brief_hour_local"),
      &clamp_hour/1
    )
    |> maybe_put_integer_config(
      "timezone_offset_hours",
      Map.get(schedule, "timezone_offset_hours"),
      &clamp_timezone_offset/1
    )
    |> Map.merge(Timezones.config_updates(Map.get(schedule, "timezone") || ""))
  end

  defp chief_of_staff_install_config(_params), do: %{}

  defp chief_of_staff_project_id(%{project_id: project_id}, _projects) when is_binary(project_id),
    do: project_id

  defp chief_of_staff_project_id(_agent, projects), do: first_project_id(projects)

  defp chief_of_staff_install_button_label(%{install_status: "setup_required"}, readiness) do
    if chief_of_staff_missing_readiness(readiness) == [] do
      "Enable Chief of Staff"
    else
      "Save changes"
    end
  end

  defp chief_of_staff_install_button_label(_agent, readiness) do
    if chief_of_staff_missing_readiness(readiness) == [] do
      "Install Chief of Staff"
    else
      "Save for later"
    end
  end

  defp chief_of_staff_install_hour(%{config: config}, _schedule) when is_map(config) do
    config
    |> Map.get("morning_brief_hour_local")
    |> parse_integer(8)
    |> clamp_hour()
  end

  defp chief_of_staff_install_hour(_agent, %{morning: %{hour_local: hour}})
       when is_integer(hour) do
    clamp_hour(hour)
  end

  defp chief_of_staff_install_hour(_agent, _schedule), do: 8

  defp chief_of_staff_install_timezone(%{config: config}, _schedule) when is_map(config) do
    timezone_name = Map.get(config, "timezone") || Map.get(config, "timezone_name")

    offset =
      config |> Map.get("timezone_offset_hours") |> parse_integer(-5) |> clamp_timezone_offset()

    Timezones.selected_value(timezone_name, offset)
  end

  defp chief_of_staff_install_timezone(_agent, %{
         timezone_name: timezone_name,
         timezone_offset_hours: offset
       })
       when is_integer(offset) do
    Timezones.selected_value(timezone_name, clamp_timezone_offset(offset))
  end

  defp chief_of_staff_install_timezone(_agent, %{timezone_offset_hours: offset})
       when is_integer(offset) do
    Timezones.selected_value(nil, clamp_timezone_offset(offset))
  end

  defp chief_of_staff_install_timezone(_agent, _schedule), do: Timezones.selected_value(nil, -5)

  defp chief_of_staff_morning_hour_options do
    Enum.map(0..23, fn hour ->
      %{value: hour, label: display_time(hour, 0)}
    end)
  end

  defp chief_of_staff_timezone_options, do: Timezones.options()

  defp connector_chip_class(%{connected?: true}) do
    "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"
  end

  defp connector_chip_class(_item) do
    "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"
  end

  defp chief_of_staff_schedule_label(%{
         morning: %{display_time_local: time},
         local_timezone: timezone
       })
       when is_binary(time) and is_binary(timezone) do
    "#{time} #{timezone}"
  end

  defp chief_of_staff_schedule_label(_schedule), do: "8:00 AM UTC-05:00"

  defp install_status_label("enabled"), do: "Enabled"
  defp install_status_label("setup_required"), do: "Not enabled"
  defp install_status_label("paused"), do: "Paused"
  defp install_status_label("error"), do: "Error"
  defp install_status_label("removed"), do: "Removed"
  defp install_status_label(status) when is_binary(status), do: status
  defp install_status_label(_status), do: "unknown"

  defp maybe_put_integer_config(config, _key, nil, _normalizer), do: config
  defp maybe_put_integer_config(config, _key, "", _normalizer), do: config

  defp maybe_put_integer_config(config, key, value, normalizer)
       when is_binary(key) and is_function(normalizer, 1) do
    case parse_integer(value, nil) do
      nil -> config
      integer -> Map.put(config, key, normalizer.(integer))
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp clamp_hour(nil), do: 8
  defp clamp_hour(hour) when hour < 0, do: 0
  defp clamp_hour(hour) when hour > 23, do: 23
  defp clamp_hour(hour), do: hour

  defp clamp_timezone_offset(nil), do: -5
  defp clamp_timezone_offset(offset) when offset < -12, do: -12
  defp clamp_timezone_offset(offset) when offset > 14, do: 14
  defp clamp_timezone_offset(offset), do: offset

  defp display_time(hour, minute) when is_integer(hour) and is_integer(minute) do
    suffix = if hour < 12, do: "AM", else: "PM"
    display_hour = rem(hour, 12)
    display_hour = if display_hour == 0, do: 12, else: display_hour

    "#{display_hour}:#{minute |> Integer.to_string() |> String.pad_leading(2, "0")} #{suffix}"
  end

  defp show_onboarding_preview?(eligible?, agents), do: eligible? and agents == []

  defp agent_owned_by_current_user?(socket, agent_id) when is_binary(agent_id) do
    not is_nil(Agents.get_agent_for_user(agent_id, current_user_id(socket)))
  end

  defp agent_owned_by_current_user?(_socket, _agent_id), do: false

  defp provider_label(provider) when is_binary(provider),
    do: SourceLabels.label(provider, fallback: "Connector")

  defp provider_label(provider), do: to_string(provider)

  defp memory_summary_label("content_preferences"), do: "Content Preferences"
  defp memory_summary_label("telegram_behavior"), do: "Conversation Style"
  defp memory_summary_label("action_style"), do: "Action Style"
  defp memory_summary_label("interrupt_policy"), do: "Interrupt Policy"
  defp memory_summary_label(label), do: label

  defp memory_profile_fields(memory_profile) when is_map(memory_profile) do
    profile = Map.get(memory_profile, :profile, %{})

    [
      {"Current Focus", Map.get(profile, "current_focus")},
      {"Working Style", Map.get(profile, "working_style")},
      {"Communication", Map.get(profile, "communication_style")},
      {"Decision Style", Map.get(profile, "decision_style")},
      {"Important Context", Map.get(profile, "important_context")}
    ]
    |> Enum.map(fn {label, value} -> %{label: label, value: value} end)
    |> Enum.reject(fn field -> is_nil(normalized_text(field.value)) end)
    |> Enum.take(3)
  end

  defp memory_profile_fields(_memory_profile), do: []

  defp memory_rule_kind_label("content_filter"), do: "Filter"
  defp memory_rule_kind_label("urgency_boost"), do: "Urgency"
  defp memory_rule_kind_label("quiet_hours"), do: "Quiet Hours"
  defp memory_rule_kind_label("routing_preference"), do: "Routing"
  defp memory_rule_kind_label("action_preference"), do: "Action"
  defp memory_rule_kind_label("style_preference"), do: "Style"
  defp memory_rule_kind_label(kind), do: humanize_text_token(kind) || "Preference"

  defp project_options(projects) when is_list(projects) do
    Enum.map(projects, fn %{project: project} -> {project.name, project.id} end)
  end

  defp project_options(_projects), do: []

  defp project_item_type_options(item_types) when is_list(item_types) do
    Enum.map(item_types, fn item_type -> {item_type_label(item_type), item_type} end)
  end

  defp project_item_type_options(_item_types), do: []

  defp project_status_class("active"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp project_status_class("paused"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp project_status_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp project_priority_class("critical"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp project_priority_class("high"),
    do:
      "inline-flex rounded-md bg-orange-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-orange-700"

  defp project_priority_class("normal"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp project_priority_class(_priority),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp project_priority_label(value), do: humanize_text_token(value) || "Normal"

  defp recommendation_priority_class(priority) when is_integer(priority) and priority >= 90,
    do:
      "inline-flex rounded-md bg-emerald-600/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-800"

  defp recommendation_priority_class(priority) when is_integer(priority) and priority >= 80,
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-800"

  defp recommendation_priority_class(priority) when is_integer(priority) and priority >= 65,
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-800"

  defp recommendation_priority_class(_priority),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp recommendation_priority_label(priority) when is_integer(priority) and priority >= 90,
    do: "Critical path"

  defp recommendation_priority_label(priority) when is_integer(priority) and priority >= 80,
    do: "High impact"

  defp recommendation_priority_label(priority) when is_integer(priority) and priority >= 65,
    do: "Worth considering"

  defp recommendation_priority_label(_priority), do: "Later"

  defp project_summary(project) do
    project.summary || project.description ||
      "Add a project summary to keep recommendations focused."
  end

  defp item_type_label("todo"), do: "Work item"
  defp item_type_label("note"), do: "Note"
  defp item_type_label("decision"), do: "Decision"
  defp item_type_label("resource"), do: "Resource"
  defp item_type_label("grant"), do: "Grant"
  defp item_type_label(value), do: value

  defp recommendation_decision_label("accepted"), do: "Accepted"
  defp recommendation_decision_label("deferred"), do: "Deferred"
  defp recommendation_decision_label("rejected"), do: "Rejected"
  defp recommendation_decision_label(value), do: humanize_text_token(value) || "Decision"

  defp decision_label("accepted"), do: "accepted"
  defp decision_label("deferred"), do: "deferred"
  defp decision_label("rejected"), do: "rejected"
  defp decision_label(value), do: humanize_text_token(value) || "saved"

  defp repo_scope_label("read_only"), do: "Read only"
  defp repo_scope_label("branch_write"), do: "Branch write"
  defp repo_scope_label("pr_open"), do: "PR open"
  defp repo_scope_label(value), do: humanize_text_token(value) || "Repo scope"

  defp implementation_run_status_label("pending_plan"), do: "Planning"
  defp implementation_run_status_label("awaiting_repo_access"), do: "Awaiting Repo Access"
  defp implementation_run_status_label("queued"), do: "Queued"
  defp implementation_run_status_label("running"), do: "Running"
  defp implementation_run_status_label("blocked"), do: "Blocked"
  defp implementation_run_status_label("awaiting_review"), do: "Awaiting Review"
  defp implementation_run_status_label("completed"), do: "Completed"
  defp implementation_run_status_label("failed"), do: "Failed"
  defp implementation_run_status_label(value), do: humanize_text_token(value) || "Run"

  defp preview_source_label(source), do: provider_label(source)

  defp todo_status_label("open"), do: "Open"
  defp todo_status_label("snoozed"), do: "Snoozed"
  defp todo_status_label("done"), do: "Done"
  defp todo_status_label("dismissed"), do: "Dismissed"
  defp todo_status_label(value), do: humanize_text_token(value) || "Work item"

  defp todo_status_class("open"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp todo_status_class("snoozed"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp todo_status_class("done"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp todo_status_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp todo_source_label(source), do: insight_source_label(source)

  defp todo_source_account_value(todo) do
    metadata = public_todo_metadata(todo)

    metadata_account =
      todo.source_account_label ||
        fetch_map_value(metadata, "account") ||
        fetch_map_value(metadata, "account_email") ||
        fetch_map_value(metadata, "source_account_label")

    normalized_text(metadata_account)
  end

  defp agent_display_name(agent) do
    get_in(agent.config || %{}, ["name"]) ||
      get_in(agent.config || %{}, [:name]) ||
      automation_behavior_label(agent.behavior)
  end

  defp automation_behavior_label("founder_followthrough_agent"), do: "Chief of Staff"
  defp automation_behavior_label("inbox_calendar_advisor"), do: "Inbox and Calendar Assistant"
  defp automation_behavior_label("slack_followthrough_agent"), do: "Slack Follow-through"
  defp automation_behavior_label("github_product_planner"), do: "Project Manager"
  defp automation_behavior_label("repo_planner"), do: "Delivery Planner"

  defp automation_behavior_label(value) do
    value
    |> humanize_text_token()
    |> case do
      nil -> "Automation"
      label -> String.replace(label, " agent", " automation")
    end
  end

  defp automation_status_note(agents) do
    active = Enum.count(agents, &(&1.status == "running"))
    needs_attention = Enum.count(agents, &(&1.status == "degraded"))

    "#{active} active · #{needs_attention} need attention"
  end

  defp open_work_status_note(0), do: "no review-ready work"
  defp open_work_status_note(1), do: "1 item ready to review"
  defp open_work_status_note(count), do: "#{count} items ready to review"

  defp connected_services_note(0), do: "connect apps for context"
  defp connected_services_note(1), do: "1 service feeding context"
  defp connected_services_note(count), do: "#{count} services feeding context"

  defp projects_status_note([]), do: "add project context"
  defp projects_status_note([_project]), do: "1 active context"
  defp projects_status_note(projects), do: "#{length(projects)} active contexts"

  defp automation_status_label("running"), do: "active"
  defp automation_status_label("degraded"), do: "needs attention"
  defp automation_status_label("stopped"), do: "paused"
  defp automation_status_label(status), do: humanize_text_token(status) || "queued"

  defp agent_status_class("running"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp agent_status_class("degraded"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp agent_status_class("stopped"),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp agent_status_class(_status),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp preview_source_class("gmail"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp preview_source_class("calendar"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp preview_source_class("slack"),
    do:
      "inline-flex rounded-md bg-violet-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-violet-700"

  defp preview_source_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp onboarding_behavior_label(value), do: automation_behavior_label(value)

  defp insight_category_label("reply_urgent"), do: "Reply Needed"
  defp insight_category_label("tone_risk"), do: "Tone Risk"
  defp insight_category_label("event_important"), do: "Important Event"
  defp insight_category_label("event_prep_needed"), do: "Prep Needed"
  defp insight_category_label("commitment_unresolved"), do: "Commitment Due"
  defp insight_category_label("meeting_follow_up"), do: "Meeting Follow-Up"
  defp insight_category_label("product_opportunity"), do: "Roadmap"
  defp insight_category_label(_), do: "Insight"

  defp insight_source_label("gmail"), do: "Gmail"
  defp insight_source_label("google_calendar"), do: "Google Calendar"
  defp insight_source_label(source) when is_binary(source), do: SourceLabels.label(source)

  defp insight_source_label(_), do: "Maraithon"

  defp attention_mode_label("monitor"), do: "Watching"
  defp attention_mode_label(_), do: "Needs Action"

  defp attention_mode_class("monitor"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp attention_mode_class(_),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp insight_category_class("reply_urgent"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp insight_category_class("tone_risk"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp insight_category_class("event_important"),
    do:
      "inline-flex rounded-md bg-indigo-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-indigo-700"

  defp insight_category_class("event_prep_needed"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp insight_category_class("commitment_unresolved"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp insight_category_class("meeting_follow_up"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp insight_category_class("product_opportunity"),
    do: "inline-flex rounded-md bg-cyan-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-cyan-800"

  defp insight_category_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp insight_priority_class(priority) when is_integer(priority) and priority >= 80,
    do: "inline-flex rounded-md bg-red-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-red-700"

  defp insight_priority_class(priority) when is_integer(priority) and priority >= 60,
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp insight_priority_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp insight_priority_label(%{attention_mode: "monitor"}), do: "watching"

  defp insight_priority_label(%{priority: priority}) when is_integer(priority) and priority >= 85,
    do: "high priority"

  defp insight_priority_label(%{priority: priority}) when is_integer(priority) and priority >= 70,
    do: "priority"

  defp insight_priority_label(_insight), do: "normal priority"

  defp insight_source_context(insight) do
    case insight_account_label(insight) do
      nil -> "from #{insight_source_label(insight.source)}"
      account -> "from #{insight_source_label(insight.source)} · account #{account}"
    end
  end

  defp insight_account_label(insight) do
    metadata_account =
      insight_metadata_value(insight, "account") ||
        insight_metadata_value(insight, "account_email") ||
        insight_metadata_value(insight, "mailbox") ||
        insight_metadata_value(insight, "workspace_name") ||
        insight_metadata_value(insight, "team_name")

    case normalized_text(metadata_account) do
      nil ->
        insight_source_account_fallback(insight)

      value ->
        value
    end
  end

  defp insight_source_account_fallback(insight) do
    source = normalized_text(Map.get(insight, :source))

    case source do
      "slack" ->
        normalized_text(insight_metadata_value(insight, "team_id"))

      _ ->
        nil
    end
  end

  defp insight_why_now(insight) do
    case insight_metadata_value(insight, "why_now") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp insight_follow_up_ideas(insight) do
    case insight_metadata_value(insight, "follow_up_ideas") do
      values when is_list(values) ->
        values
        |> Enum.map(fn
          value when is_binary(value) ->
            value = String.trim(value)
            if value == "", do: nil, else: value

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp insight_metadata_value(%{metadata: metadata}, key)
       when is_map(metadata) and is_binary(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(metadata, fn
          {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
          _ -> nil
        end)
    end
  end

  defp insight_metadata_value(_insight, _key), do: nil

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp normalized_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalized_text(_value), do: nil

  defp detail_text(%{text: text}) when is_binary(text), do: text
  defp detail_text(_value), do: nil

  defp detail_origin_label(%{origin: :stored}), do: "Stored"
  defp detail_origin_label(%{origin: :reconstructed}), do: "Reconstructed"
  defp detail_origin_label(%{origin: :derived}), do: "Derived"
  defp detail_origin_label(_value), do: nil

  defp reason_origin_label(%{origin: :stored}), do: "Saved explanation"
  defp reason_origin_label(%{origin: :derived}), do: "Inferred from available context"
  defp reason_origin_label(_value), do: nil

  defp evidence_detail(
         %{label: "Source activity", occurred_at: %DateTime{} = occurred_at},
         schedule
       ),
       do: "Seen #{format_datetime(occurred_at, schedule)}"

  defp evidence_detail(%{label: "Deadline", occurred_at: %DateTime{} = occurred_at}, schedule),
    do: "Due #{format_datetime(occurred_at, schedule)}"

  defp evidence_detail(%{detail: detail}, _schedule), do: detail
  defp evidence_detail(_item, _schedule), do: nil

  defp evidence_metadata(item, schedule) when is_map(item) do
    [
      humanize_text_token(item.kind),
      format_datetime(item.occurred_at, schedule),
      item.source_ref
    ]
    |> Enum.reject(&blank_metadata?/1)
    |> Enum.join(" · ")
  end

  defp evidence_metadata(_item, _schedule), do: nil

  defp delivery_metadata(delivery, schedule) when is_map(delivery) do
    [
      format_datetime(delivery.sent_at, schedule),
      delivery.feedback && "feedback #{humanize_text_token(delivery.feedback)}",
      delivery.feedback_at && format_datetime(delivery.feedback_at, schedule),
      delivery_error_metadata(delivery)
    ]
    |> Enum.reject(&blank_metadata?/1)
    |> Enum.join(" · ")
  end

  defp delivery_metadata(_delivery, _schedule), do: nil

  defp delivery_error_metadata(%{error_message: error_message})
       when is_binary(error_message) and error_message != "" do
    OperationFailureCopy.insight_delivery(error_message)
  end

  defp delivery_error_metadata(_delivery), do: nil

  defp humanize_text_token(value) when is_atom(value),
    do: value |> Atom.to_string() |> humanize_text_token()

  defp humanize_text_token(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.capitalize(text)
    end
  end

  defp humanize_text_token(_value), do: nil

  defp blank_metadata?(nil), do: true
  defp blank_metadata?(""), do: true
  defp blank_metadata?("N/A"), do: true
  defp blank_metadata?(_value), do: false

  defp reviewable_todos(todos, decided_ids) when is_list(todos) do
    decided_ids = normalize_todo_review_decided_ids(decided_ids)

    Enum.reject(todos, fn todo ->
      MapSet.member?(decided_ids, todo.id)
    end)
  end

  defp reviewable_todos(_todos, _decided_ids), do: []

  defp prune_todo_review_decided_ids(decided_ids, todos) when is_list(todos) do
    current_ids = MapSet.new(Enum.map(todos, & &1.id))

    decided_ids
    |> normalize_todo_review_decided_ids()
    |> MapSet.intersection(current_ids)
  end

  defp prune_todo_review_decided_ids(_decided_ids, _todos), do: MapSet.new()

  defp normalize_todo_review_decided_ids(%MapSet{} = decided_ids), do: decided_ids
  defp normalize_todo_review_decided_ids(_decided_ids), do: MapSet.new()

  defp review_todo(todos, index) when is_list(todos) do
    Enum.at(todos, clamp_review_index(index, length(todos)))
  end

  defp review_todo(_todos, _index), do: nil

  defp review_queue_preview(todos, index) when is_list(todos) do
    todos
    |> Enum.drop(clamp_review_index(index, length(todos)) + 1)
    |> Enum.take(4)
  end

  defp review_queue_preview(_todos, _index), do: []

  defp todo_review_position(todos, index) when is_list(todos) do
    case length(todos) do
      0 -> "0 of 0"
      count -> "#{clamp_review_index(index, count) + 1} of #{count}"
    end
  end

  defp todo_review_position(_todos, _index), do: "0 of 0"

  defp todo_review_progress_width(todos, index) when is_list(todos) do
    case length(todos) do
      0 -> 0
      count -> round((clamp_review_index(index, count) + 1) * 100 / count)
    end
  end

  defp todo_review_progress_width(_todos, _index), do: 0

  defp todo_review_session_label(session) when is_map(session) do
    reviewed =
      [:completed, :dismissed, :kept, :important]
      |> Enum.map(&Map.get(session, &1, 0))
      |> Enum.sum()

    if reviewed == 0 do
      "No review actions yet"
    else
      "#{reviewed} reviewed now"
    end
  end

  defp todo_review_session_label(_session), do: "No review actions yet"

  defp clamp_review_index(_index, count) when not is_integer(count) or count <= 0, do: 0

  defp clamp_review_index(index, count) when is_integer(index) do
    index
    |> max(0)
    |> min(count - 1)
  end

  defp clamp_review_index(_index, count), do: clamp_review_index(0, count)

  defp todo_context_items(card, todo, chief_of_staff_schedule) do
    card_items =
      card
      |> ActionCards.context_items()
      |> Enum.map(fn item ->
        %{label: Map.get(item, :label), value: Map.get(item, :value)}
      end)

    fallback_items = fallback_todo_context_items(todo, chief_of_staff_schedule)

    (card_items ++ fallback_items)
    |> Enum.reject(fn item -> blank_metadata?(item.value) end)
    |> Enum.uniq_by(fn item -> {item.label, item.value} end)
    |> Enum.take(6)
  end

  defp todo_why_important(card, todo, chief_of_staff_schedule) do
    case Map.get(card, "why_now") do
      value when is_binary(value) and value != "" -> value
      _ -> fallback_todo_why_important(todo, chief_of_staff_schedule)
    end
  end

  defp todo_source_excerpt(card, todo) do
    case ActionCards.evidence_excerpt(card) do
      value when is_binary(value) and value != "" -> truncate(value, 280)
      _ -> fallback_todo_source_excerpt(todo)
    end
  end

  defp todo_action_hint(card, todo) do
    case ActionCards.prepared_action_hint(card) do
      value when is_binary(value) and value != "" -> value
      _ -> fallback_todo_action_hint(todo)
    end
  end

  defp todo_draft_preview(card) do
    case ActionCards.draft_preview(card || %{}) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp todo_decision_prompt(card) do
    card
    |> Map.get("decision_prompt")
    |> display_metadata_value()
  end

  defp todo_card_headline(card, todo) do
    card
    |> Map.get("headline")
    |> display_metadata_value()
    |> case do
      nil -> todo.title
      "" -> todo.title
      headline -> headline
    end
  end

  defp todo_source_health_text(card) do
    ActionCards.source_health_note(card || %{})
  end

  defp todo_learning_text(card) do
    case card do
      %{"attention_mode" => "stale_check"} ->
        "This choice helps Maraithon keep older work visible only when it still matters."

      _ ->
        nil
    end
  end

  defp stale_todo_review?(%{"attention_mode" => "stale_check"}), do: true
  defp stale_todo_review?(_card), do: false

  defp fallback_todo_context_items(todo, chief_of_staff_schedule) do
    metadata = public_todo_metadata(todo)

    [
      %{
        label: "Person",
        value:
          todo_metadata_text(
            metadata,
            ~w(person contact requested_by sender_name)
          )
      },
      %{
        label: "Company",
        value: todo_metadata_text(metadata, ~w(company organization account))
      },
      %{
        label: "Relationship",
        value: todo_metadata_text(metadata, ~w(relationship relationship_context context_brief))
      },
      %{
        label: "Project",
        value: todo_metadata_text(metadata, ~w(project project_name omni_project topic))
      },
      %{label: "Account", value: todo_source_account_value(todo)},
      %{
        label: "Due",
        value: todo.due_at && format_due_datetime(todo.due_at, chief_of_staff_schedule)
      }
    ]
  end

  defp fallback_todo_why_important(todo, chief_of_staff_schedule) do
    metadata = public_todo_metadata(todo)

    todo_metadata_text(metadata, ~w(why_now why_it_matters))
    |> case do
      nil when not is_nil(todo.due_at) ->
        "Due #{format_due_datetime(todo.due_at, chief_of_staff_schedule)}."

      nil ->
        todo_updated_why_text(todo, chief_of_staff_schedule)

      value ->
        value
    end
  end

  defp fallback_todo_source_excerpt(todo) do
    todo
    |> public_todo_metadata()
    |> todo_metadata_text(~w(source_quote quote source_excerpt body_excerpt))
    |> case do
      nil -> nil
      value -> truncate(value, 280)
    end
  end

  defp fallback_todo_action_hint(todo) do
    next_action = String.downcase(todo.next_action || "")

    cond do
      todo_action_draft_present?(todo) ->
        "Draft material is ready for approval."

      todo.source == "gmail" and String.contains?(next_action, ["reply", "email"]) ->
        "Draft the reply for approval."

      todo.source == "slack" and String.contains?(next_action, ["reply", "respond", "message"]) ->
        "Draft the Slack response for approval."

      true ->
        nil
    end
  end

  defp todo_updated_why_text(todo, chief_of_staff_schedule) do
    base =
      "#{attention_mode_label(todo.attention_mode)} item from #{todo_source_label(todo.source)}."

    case format_due_datetime(todo.updated_at, chief_of_staff_schedule) do
      nil -> base
      timestamp -> "#{base} Last updated #{timestamp}."
    end
  end

  defp todo_priority_label(%{attention_mode: "monitor"}), do: "watching"

  defp todo_priority_label(%{priority: priority}) when is_integer(priority) and priority >= 85,
    do: "high priority"

  defp todo_priority_label(%{priority: priority}) when is_integer(priority) and priority >= 70,
    do: "priority"

  defp todo_priority_label(_todo), do: "normal priority"

  defp todo_queue_preview_context(todo, chief_of_staff_schedule) do
    case display_metadata_value(todo.next_action) do
      value when is_binary(value) and value != "" ->
        "Next: #{value}"

      _ ->
        todo_queue_preview_fallback(todo, chief_of_staff_schedule)
    end
  end

  defp todo_queue_preview_fallback(%{due_at: due_at} = todo, chief_of_staff_schedule)
       when not is_nil(due_at) do
    "Due #{format_due_datetime(todo.due_at, chief_of_staff_schedule)}"
  end

  defp todo_queue_preview_fallback(todo, _chief_of_staff_schedule) do
    "#{todo_source_label(todo.source)} · #{todo_priority_label(todo)}"
  end

  defp public_todo_metadata(%{metadata: metadata}) when is_map(metadata),
    do: PublicMetadata.todo(metadata)

  defp public_todo_metadata(_todo), do: %{}

  defp todo_metadata_text(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      metadata
      |> fetch_map_value(key)
      |> display_metadata_value()
    end)
  end

  defp todo_metadata_text(_metadata, _keys), do: nil

  defp display_metadata_value(value) when is_binary(value), do: normalized_text(value)

  defp display_metadata_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_text()

  defp display_metadata_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_metadata_value(value) when is_float(value), do: Float.to_string(value)
  defp display_metadata_value(%DateTime{} = value), do: format_datetime(value)
  defp display_metadata_value(%NaiveDateTime{} = value), do: format_datetime(value)

  defp display_metadata_value(values) when is_list(values) do
    values
    |> Enum.map(&display_metadata_value/1)
    |> Enum.reject(&blank_metadata?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  defp display_metadata_value(value) when is_map(value) do
    Enum.find_value(
      ~w(display_name name title email company organization relationship summary text body value),
      fn key ->
        value
        |> fetch_map_value(key)
        |> display_metadata_value()
      end
    )
  end

  defp display_metadata_value(_value), do: nil

  defp todo_action_draft_present?(%{action_draft: draft}) when is_map(draft) do
    draft
    |> Map.values()
    |> Enum.any?(&present_action_draft_value?/1)
  end

  defp todo_action_draft_present?(_todo), do: false

  defp present_action_draft_value?(value) when is_binary(value), do: String.trim(value) != ""

  defp present_action_draft_value?(values) when is_list(values),
    do: Enum.any?(values, &present_action_draft_value?/1)

  defp present_action_draft_value?(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&present_action_draft_value?/1)
  end

  defp present_action_draft_value?(value), do: not is_nil(value)

  attr :todos, :list, required: true
  attr :todo_review_index, :integer, required: true
  attr :todo_review_session, :map, required: true
  attr :todo_review_decided_ids, :any, required: true
  attr :chief_of_staff_schedule, :any, required: true

  defp todo_review_board(assigns) do
    review_todos = reviewable_todos(assigns.todos, assigns.todo_review_decided_ids)
    current_todo = review_todo(review_todos, assigns.todo_review_index)

    assigns =
      assigns
      |> assign(:current_todo, current_todo)
      |> assign(:current_todo_card, current_todo && ActionCards.for_todo(current_todo))
      |> assign(:queue_preview, review_queue_preview(review_todos, assigns.todo_review_index))
      |> assign(:review_position, todo_review_position(review_todos, assigns.todo_review_index))
      |> assign(
        :progress_width,
        todo_review_progress_width(review_todos, assigns.todo_review_index)
      )
      |> assign(:can_go_previous, assigns.todo_review_index > 0)
      |> assign(:can_go_next, assigns.todo_review_index + 1 < length(review_todos))

    ~H"""
    <section id="todo-review" class="overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-sm">
      <div class="border-b border-zinc-950/10 px-4 py-4 sm:px-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-base/7 font-semibold text-zinc-950">Open work review</h2>
              <.badge color="emerald" class="bg-white">
                One commitment at a time
              </.badge>
            </div>
            <p class="mt-1 text-sm/6 text-zinc-600">
              Choose the next move for each open commitment.
            </p>
          </div>
          <div class="text-right">
            <p class="text-sm/6 font-medium text-zinc-950"><%= @review_position %></p>
            <p class="text-xs/5 text-zinc-500">
              <%= todo_review_session_label(@todo_review_session) %>
            </p>
          </div>
        </div>
      </div>

      <%= if @current_todo do %>
        <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_18rem] lg:divide-x lg:divide-zinc-950/10">
          <article id={"todo-review-card-#{@current_todo.id}"} class="px-4 py-5 sm:px-6">
            <div class="flex flex-wrap items-center gap-2">
              <span class={todo_status_class(@current_todo.status)}>
                <%= todo_status_label(@current_todo.status) %>
              </span>
              <span class={attention_mode_class(@current_todo.attention_mode)}>
                <%= attention_mode_label(@current_todo.attention_mode) %>
              </span>
              <span class="inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700">
                <%= todo_source_label(@current_todo.source) %>
              </span>
              <span :if={@current_todo.due_at} class="text-xs/5 font-medium text-amber-700">
                Due <%= format_due_datetime(@current_todo.due_at, @chief_of_staff_schedule) %>
              </span>
            </div>

            <h3 class="mt-3 text-xl/7 font-semibold tracking-tight text-zinc-950 sm:text-lg/7">
              <%= todo_card_headline(@current_todo_card, @current_todo) %>
            </h3>
            <p :if={@current_todo.summary not in [nil, ""]} class="mt-2 text-sm/6 text-zinc-600">
              <%= @current_todo.summary %>
            </p>

            <div :if={todo_decision_prompt(@current_todo_card)} class="mt-5 border-l border-zinc-950/10 pl-3">
              <p class="text-xs/5 font-medium text-zinc-500">Decision</p>
              <p class="mt-1 text-sm/6 text-zinc-800"><%= todo_decision_prompt(@current_todo_card) %></p>
              <p :if={todo_learning_text(@current_todo_card)} class="mt-2 text-xs/5 text-zinc-500">
                <%= todo_learning_text(@current_todo_card) %>
              </p>
            </div>

            <dl :if={todo_context_items(@current_todo_card, @current_todo, @chief_of_staff_schedule) != []} class="mt-5 grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
              <div :for={item <- todo_context_items(@current_todo_card, @current_todo, @chief_of_staff_schedule)} class="border-l border-zinc-950/10 pl-3">
                <dt class="text-xs/5 font-medium text-zinc-500"><%= item.label %></dt>
                <dd class="mt-0.5 text-sm/6 text-zinc-800"><%= item.value %></dd>
              </div>
            </dl>

            <div class="mt-5 grid grid-cols-1 gap-x-6 gap-y-4 lg:grid-cols-2">
              <div class="border-l border-zinc-950/10 pl-3">
                <p class="text-xs/5 font-medium text-zinc-500">Why it matters</p>
                <p class="mt-1 text-sm/6 text-zinc-700"><%= todo_why_important(@current_todo_card, @current_todo, @chief_of_staff_schedule) %></p>
              </div>
              <div class="border-l border-zinc-950/10 pl-3">
                <p class="text-xs/5 font-medium text-zinc-500">Suggested next step</p>
                <p class="mt-1 text-sm/6 text-zinc-700"><%= @current_todo.next_action %></p>
                <p :if={todo_draft_preview(@current_todo_card)} class="mt-2 text-sm/6 text-zinc-800">
                  <span class="font-medium text-zinc-950">Suggested reply:</span> <%= todo_draft_preview(@current_todo_card) %>
                </p>
                <p :if={todo_action_hint(@current_todo_card, @current_todo)} class="mt-2 text-sm/6 font-medium text-indigo-700">
                  <%= todo_action_hint(@current_todo_card, @current_todo) %>
                </p>
              </div>
            </div>

            <div :if={todo_source_excerpt(@current_todo_card, @current_todo)} class="mt-5 border-l border-zinc-950/10 pl-3">
              <p class="text-xs/5 font-medium text-zinc-500">Source context</p>
              <p class="mt-1 text-sm/6 text-zinc-700"><%= todo_source_excerpt(@current_todo_card, @current_todo) %></p>
            </div>

            <div :if={todo_source_health_text(@current_todo_card)} class="mt-5 border-l border-zinc-950/10 pl-3">
              <p class="text-xs/5 font-medium text-zinc-500">Context used</p>
              <p class="mt-1 text-sm/6 text-zinc-700"><%= todo_source_health_text(@current_todo_card) %></p>
            </div>

            <div class="mt-6 flex flex-wrap items-center gap-2">
              <.button
                :if={!stale_todo_review?(@current_todo_card)}
                type="button"
                phx-click="review_complete_todo"
                phx-value-id={@current_todo.id}
              >
                Done
              </.button>
              <.button
                :if={stale_todo_review?(@current_todo_card)}
                type="button"
                phx-click="review_mark_important"
                phx-value-id={@current_todo.id}
                variant="outline"
                class="text-amber-800"
              >
                Keep active
              </.button>
              <.button
                :if={!stale_todo_review?(@current_todo_card)}
                type="button"
                phx-click="review_keep_todo"
                phx-value-id={@current_todo.id}
                variant="outline"
              >
                Keep for later
              </.button>
              <.button
                type="button"
                phx-click="review_dismiss_todo"
                phx-value-id={@current_todo.id}
                variant="outline"
                class="text-rose-700"
              >
                Dismiss
              </.button>

              <div class="ml-auto flex items-center gap-1">
                <.button
                  type="button"
                  phx-click="review_previous_todo"
                  variant="plain"
                  disabled={not @can_go_previous}
                  class="text-xs text-zinc-500"
                >
                  Previous
                </.button>
                <.button
                  type="button"
                  phx-click="review_next_todo"
                  variant="plain"
                  disabled={not @can_go_next}
                  class="text-xs text-zinc-500"
                >
                  Next
                </.button>
              </div>
            </div>
          </article>

          <aside class="bg-zinc-50 px-4 py-5 sm:px-6">
            <div class="h-1.5 overflow-hidden rounded-full bg-zinc-200">
              <div class="h-full rounded-full bg-zinc-950" style={"width: #{@progress_width}%"} />
            </div>

            <dl class="mt-4 grid grid-cols-2 gap-3 text-sm/6">
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Done</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :completed, 0) %>
                </dd>
              </div>
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Dismissed</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :dismissed, 0) %>
                </dd>
              </div>
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Kept</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :kept, 0) %>
                </dd>
              </div>
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Kept active</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :important, 0) %>
                </dd>
              </div>
            </dl>

            <div :if={@queue_preview != []} class="mt-6">
              <p class="text-xs/5 font-medium text-zinc-500">Up next</p>
              <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
                <li :for={todo <- @queue_preview} class="py-2">
                  <p class="line-clamp-2 text-sm/6 font-medium text-zinc-950"><%= todo.title %></p>
                  <p class="mt-0.5 text-xs/5 text-zinc-500">
                    <%= todo_queue_preview_context(todo, @chief_of_staff_schedule) %>
                  </p>
                </li>
              </ul>
            </div>
            <p :if={@queue_preview == []} class="mt-6 text-sm/6 text-zinc-500">
              No more work items in this review.
            </p>
          </aside>
        </div>
      <% else %>
        <div class="px-4 py-8 sm:px-6">
          <%= if @todos == [] do %>
            <p class="text-sm/6 font-medium text-zinc-950">
              Nothing needs your review right now.
            </p>
            <p class="mt-1 text-sm/6 text-zinc-500">
              When a message, meeting, note, or local signal has a clear next move, it will appear here.
            </p>
          <% else %>
            <p class="text-sm/6 font-medium text-zinc-950">Review complete for now.</p>
            <p class="mt-1 text-sm/6 text-zinc-500">
              <%= remaining_today_label(length(@todos)) %>
            </p>
          <% end %>
        </div>
      <% end %>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :cards, :list, required: true
  attr :expanded_insight_ids, :any, required: true
  attr :chief_of_staff_schedule, :any, required: true

  defp insight_group(assigns) do
    ~H"""
    <section :if={@cards != []} class="overflow-hidden rounded-lg border border-zinc-950/10">
      <div class="border-b border-zinc-950/10 bg-zinc-50 px-4 py-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <h3 class="text-sm/6 font-semibold text-zinc-950"><%= @title %></h3>
            <p :if={@subtitle} class="mt-1 text-sm/6 text-zinc-600"><%= @subtitle %></p>
          </div>
          <.badge class="bg-white">
            <%= length(@cards) %>
          </.badge>
        </div>
      </div>

      <div class="divide-y divide-zinc-950/5">
        <%= for card <- @cards do %>
          <% insight = card.insight %>
          <% detail = card.detail %>
          <% expanded? = MapSet.member?(@expanded_insight_ids, to_string(insight.id)) %>
          <div class="px-4 py-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class={attention_mode_class(insight.attention_mode)}>
                    <%= attention_mode_label(insight.attention_mode) %>
                  </span>
                  <span class={insight_category_class(insight.category)}>
                    <%= insight_category_label(insight.category) %>
                  </span>
                  <span class={insight_priority_class(insight.priority)}>
                    <%= insight_priority_label(insight) %>
                  </span>
                  <span :if={insight.due_at} class="text-xs/5 text-amber-700">
                    due <%= format_due_datetime(insight.due_at, @chief_of_staff_schedule) %>
                  </span>
                </div>
                <p class="mt-2 text-sm/6 font-semibold text-zinc-950"><%= insight.title %></p>
                <p class="mt-1 text-xs/5 text-zinc-500"><%= insight_source_context(insight) %></p>
                <p class="mt-1 text-sm/6 text-zinc-600"><%= insight.summary %></p>
                <p class="mt-2 text-sm/6 text-indigo-700">
                  <span class="font-medium">
                    <%= if insight.attention_mode == "monitor", do: "Track:", else: "Action:" %>
                  </span>
                  <%= insight.recommended_action %>
                </p>
                <% why_now = insight_why_now(insight) %>
                <%= if why_now do %>
                  <p class="mt-2 text-xs/5 font-medium text-zinc-500">
                    Why now
                  </p>
                  <p class="mt-1 text-sm/6 text-zinc-600"><%= why_now %></p>
                <% end %>
                <% ideas = insight_follow_up_ideas(insight) %>
                <%= if ideas != [] do %>
                  <p class="mt-2 text-xs/5 font-medium text-zinc-500">
                    Possible moves
                  </p>
                  <ul class="mt-1 space-y-1 text-sm/6 text-zinc-600">
                    <%= for idea <- ideas do %>
                      <li>- <%= idea %></li>
                    <% end %>
                  </ul>
                <% end %>
                <.button
                  type="button"
                  phx-click="toggle_insight_detail"
                  phx-value-id={insight.id}
                  aria-expanded={to_string(expanded?)}
                  aria-controls={"insight-detail-#{insight.id}"}
                  variant="outline"
                  class="mt-3 text-xs"
                >
                  <%= if expanded?, do: "Hide source context", else: "Show source context" %>
                </.button>

                <%= if expanded? do %>
                  <div
                    id={"insight-detail-#{insight.id}"}
                    class="mt-4 space-y-4 rounded-lg border border-zinc-950/10 bg-zinc-50 p-4"
                  >
                    <.insight_detail_section
                      title="Request"
                      value={
                        detail_text(detail.promise_text) ||
                          Detail.missing_context_copy(:promise_text)
                      }
                      origin={detail_origin_label(detail.promise_text)}
                    />
                    <.insight_detail_section
                      title="Requester"
                      value={detail_text(detail.requested_by) || Detail.missing_context_copy(:requested_by)}
                      origin={detail_origin_label(detail.requested_by)}
                    />
                    <div class="space-y-2">
                      <div class="flex items-center gap-2">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Source context checked
                        </p>
                      </div>
                      <%= if detail.evidence_checked == [] do %>
                        <p class="text-sm/6 text-zinc-600">
                          <%= Detail.missing_context_copy(:source_evidence) %>
                        </p>
                      <% else %>
                        <ul class="space-y-2 text-sm/6 text-zinc-700">
                          <%= for item <- detail.evidence_checked do %>
                            <li class="rounded-lg border border-zinc-950/10 bg-white px-3 py-2">
                              <p class="font-medium text-zinc-950"><%= item.label %></p>
                              <p :if={evidence_detail(item, @chief_of_staff_schedule)} class="mt-1 text-zinc-600">
                                <%= evidence_detail(item, @chief_of_staff_schedule) %>
                              </p>
                              <p class="mt-1 text-xs/5 text-zinc-500">
                                <%= evidence_metadata(item, @chief_of_staff_schedule) %>
                              </p>
                            </li>
                          <% end %>
                        </ul>
                      <% end %>
                    </div>
                    <div class="space-y-2">
                      <div class="flex items-center gap-2">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Delivery checked
                        </p>
                      </div>
                      <%= if detail.delivery_evidence == [] do %>
                        <p class="text-sm/6 text-zinc-600">
                          <%= Detail.missing_context_copy(:delivery_evidence) %>
                        </p>
                      <% else %>
                        <ul class="space-y-2 text-sm/6 text-zinc-700">
                          <%= for delivery <- detail.delivery_evidence do %>
                            <li class="rounded-lg border border-zinc-950/10 bg-white px-3 py-2">
                              <div class="flex flex-wrap items-center gap-2">
                                <span class="font-medium text-zinc-950">
                                  <%= humanize_text_token(delivery.channel) %>
                                </span>
                                <.badge>
                                  <%= humanize_text_token(delivery.status) %>
                                </.badge>
                              </div>
                              <p class="mt-1 text-zinc-600"><%= delivery.destination_label %></p>
                              <p class="mt-1 text-xs/5 text-zinc-500">
                                <%= delivery_metadata(delivery, @chief_of_staff_schedule) %>
                              </p>
                            </li>
                          <% end %>
                        </ul>
                      <% end %>
                    </div>
                    <div class="space-y-2">
                      <div class="flex items-center gap-2">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Why this needs review
                        </p>
                        <.badge
                          :if={detail.open_loop_reason}
                          class="bg-white"
                        >
                          <%= reason_origin_label(detail.open_loop_reason) %>
                        </.badge>
                      </div>
                      <%= if detail.open_loop_reason do %>
                        <p class="text-sm/6 text-zinc-700"><%= detail.open_loop_reason.text %></p>
                        <ul
                          :if={detail.open_loop_reason.origin == :derived and detail.open_loop_reason.factors != []}
                          class="space-y-1 text-sm/6 text-zinc-600"
                        >
                          <%= for factor <- detail.open_loop_reason.factors do %>
                            <li>- <%= factor %></li>
                          <% end %>
                        </ul>
                      <% else %>
                        <p class="text-sm/6 text-zinc-600">
                          <%= Detail.missing_context_copy(:open_loop_reason) %>
                        </p>
                      <% end %>
                    </div>
                    <div :if={detail.data_gaps != []} class="space-y-2">
                      <p class="text-xs/5 font-medium text-zinc-500">
                        Missing context
                      </p>
                      <ul class="space-y-1 text-sm/6 text-zinc-600">
                        <%= for gap <- detail.data_gaps do %>
                          <li>- <%= gap %></li>
                        <% end %>
                      </ul>
                    </div>
                  </div>
                <% end %>
              </div>
              <div class="flex flex-wrap gap-2">
                <.button
                  type="button"
                  phx-click="ack_insight"
                  phx-value-id={insight.id}
                  variant="outline"
                  class="text-xs text-emerald-800"
                >
                  Acknowledge
                </.button>
                <.button
                  type="button"
                  phx-click="snooze_insight"
                  phx-value-id={insight.id}
                  variant="outline"
                  class="text-xs text-amber-800"
                >
                  Snooze 4h
                </.button>
                <.button
                  type="button"
                  phx-click="dismiss_insight"
                  phx-value-id={insight.id}
                  variant="outline"
                  class="text-xs text-rose-700"
                >
                  Dismiss
                </.button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, default: nil
  attr :origin, :string, default: nil

  defp insight_detail_section(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-center gap-2">
        <p class="text-xs/5 font-medium text-zinc-500">
          <%= @title %>
        </p>
        <span
          :if={@origin}
          class="rounded-md bg-white px-1.5 py-0.5 text-xs/5 font-medium text-zinc-600 ring-1 ring-zinc-950/10"
        >
          <%= @origin %>
        </span>
      </div>
      <p class="text-sm/6 text-zinc-700"><%= @value %></p>
    </div>
    """
  end

  defp health_badge_class(:healthy),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp health_badge_class(:unhealthy),
    do: "inline-flex rounded-md bg-red-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-red-700"

  defp health_badge_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :description, :string, default: nil
  attr :href, :string, default: nil
  attr :cta, :string, default: nil

  defp workspace_summary(assigns) do
    ~H"""
    <div class="border-l border-zinc-950/10 pl-4">
      <dt class="text-xs/5 font-medium text-zinc-500"><%= @label %></dt>
      <dd class="mt-1 flex items-baseline gap-1.5">
        <span class="text-xl/7 font-semibold tracking-tight text-zinc-950"><%= @value %></span>
        <span :if={@unit} class="text-xs/5 text-zinc-500"><%= @unit %></span>
      </dd>
      <dd :if={@description} class="mt-1.5 text-sm/6 text-zinc-600 line-clamp-2">
        <%= @description %>
      </dd>
      <dd :if={@href && @cta} class="mt-2">
        <.link href={@href} class="text-xs/5 font-medium text-zinc-950 hover:text-zinc-700">
          <%= @cta %> →
        </.link>
      </dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil

  defp overview_stat(assigns) do
    ~H"""
    <div class="border-l border-zinc-950/10 pl-4">
      <dt class="text-sm/6 font-medium text-zinc-500"><%= @label %></dt>
      <dd class="mt-1 text-2xl/8 font-semibold tracking-tight text-zinc-950">
        <%= @value %>
      </dd>
      <dd :if={@note} class="mt-1 text-xs/5 text-zinc-500"><%= @note %></dd>
    </div>
    """
  end

  def dashboard_greeting(user, schedule \\ nil, now \\ DateTime.utc_now())

  def dashboard_greeting(user, schedule, %DateTime{} = now) do
    name =
      user
      |> case do
        %{name: name} when is_binary(name) and name != "" -> name
        %{email: email} when is_binary(email) -> email |> String.split("@") |> List.first()
        _ -> nil
      end
      |> case do
        nil -> nil
        value -> value |> String.split([".", "_"]) |> List.first() |> String.capitalize()
      end

    period = greeting_period(local_dashboard_hour(schedule, now))

    if name, do: "Good #{period}, #{name}", else: "Good #{period}"
  end

  def dashboard_greeting(user, schedule, _now),
    do: dashboard_greeting(user, schedule, DateTime.utc_now())

  defp local_dashboard_hour(schedule, %DateTime{} = now) do
    timezone = dashboard_timezone(schedule)
    offset_hours = Timezones.offset_at(timezone.name, now, timezone.offset_hours)

    now
    |> DateTime.add(offset_hours, :hour)
    |> Map.fetch!(:hour)
  end

  defp greeting_period(hour) when is_integer(hour) and hour < 12, do: "morning"
  defp greeting_period(hour) when is_integer(hour) and hour < 17, do: "afternoon"
  defp greeting_period(_hour), do: "evening"

  attr :title, :string, required: true
  attr :metrics, :list, required: true

  defp queue_strip(assigns) do
    ~H"""
    <div>
      <p class="text-xs/5 font-medium text-zinc-500"><%= @title %></p>
      <dl class="mt-1.5 grid grid-cols-4 divide-x divide-zinc-950/5 rounded-lg border border-zinc-950/10">
        <div :for={m <- @metrics} class="flex flex-col items-baseline px-3 py-2">
          <dt class="text-xs/5 text-zinc-500"><%= m.label %></dt>
          <dd class={["text-sm/6 font-semibold", Map.get(m, :emphasis) || "text-zinc-950"]}>
            <%= m.value %>
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :string, default: "font-medium text-zinc-950"

  defp health_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <dt class="text-zinc-500"><%= @label %></dt>
      <dd class={@value_class}><%= @value %></dd>
    </div>
    """
  end

  defp event_preview(%{payload: payload} = activity) when is_map(payload) do
    payload
    |> product_payload_message()
    |> safe_product_detail(event_type_summary(Map.get(activity, :event_type)))
  end

  defp event_preview(%{event_type: event_type}), do: event_type_summary(event_type)
  defp event_preview(_activity), do: "Maraithon updated this workspace."

  defp event_type_label(event_type) when is_binary(event_type) do
    normalized = String.downcase(event_type)

    cond do
      String.contains?(normalized, ["fail", "error"]) ->
        "Needs attention"

      String.contains?(normalized, ["complete", "success", "finish"]) ->
        "Completed work"

      String.contains?(normalized, ["start", "run", "claim"]) ->
        "Work in progress"

      String.contains?(normalized, "insight") ->
        "Insight updated"

      String.contains?(normalized, ["effect", "action"]) ->
        "Action updated"

      true ->
        "Workspace update"
    end
  end

  defp event_type_label(_event_type), do: "Workspace update"

  defp product_payload_message(payload) when is_map(payload) do
    Enum.find_value(["message", "summary", "title", "description", "status", "action"], fn key ->
      case fetch_map_value(payload, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp product_payload_message(_payload), do: nil

  defp event_type_summary(event_type) when is_binary(event_type) do
    normalized = String.downcase(event_type)

    cond do
      String.contains?(normalized, ["fail", "error"]) ->
        "Maraithon could not finish this step. Review the latest automation status."

      String.contains?(normalized, ["complete", "success", "finish"]) ->
        "Maraithon finished this update."

      String.contains?(normalized, ["start", "run", "claim"]) ->
        "Maraithon is preparing this update."

      String.contains?(normalized, "insight") ->
        "Maraithon updated an insight."

      String.contains?(normalized, ["effect", "action"]) ->
        "Maraithon updated an action."

      true ->
        "Maraithon updated this workspace."
    end
  end

  defp event_type_summary(_event_type), do: "Maraithon updated this workspace."

  defp failure_details_preview(failure), do: RunErrorCopy.runtime_failure(failure)

  defp log_message_preview(%{message: message}), do: public_log_message(message)

  defp log_message_preview(message), do: public_log_message(message)

  defp public_log_message(message) when is_binary(message) do
    cond do
      database_query_log?(message) ->
        if String.contains?(message, "QUERY ERROR") do
          "Database query failed."
        else
          "Database query completed."
        end

      true ->
        message
        |> Redaction.redact_string()
        |> redact_common_log_values()
        |> safe_product_detail("Diagnostic details are hidden from this view.")
    end
  end

  defp public_log_message(message) do
    message
    |> inspect(limit: 8)
    |> redact_common_log_values()
    |> safe_product_detail("Diagnostic details are hidden from this view.")
  end

  defp database_query_log?(message) when is_binary(message) do
    normalized = String.trim_leading(message)

    String.contains?(message, ["QUERY OK", "QUERY ERROR"]) or
      String.starts_with?(normalized, [
        "SELECT ",
        "INSERT INTO ",
        "UPDATE ",
        "DELETE FROM ",
        "begin",
        "commit",
        "rollback"
      ])
  end

  defp redact_common_log_values(message) when is_binary(message) do
    message
    |> String.replace(
      ~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i,
      "[redacted-email]"
    )
    |> then(fn text ->
      Regex.replace(
        ~r/\b(token|secret|api[_-]?key|password|chat_id)=("[^"]*"|'[^']*'|\S+)/i,
        text,
        fn _match, key, _value -> "#{key}=<redacted>" end
      )
    end)
  end

  defp redact_common_log_values(message), do: message

  defp safe_product_detail(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> fallback
      technical_detail?(trimmed) -> fallback
      true -> truncate(trimmed, 500)
    end
  end

  defp safe_product_detail(_value, fallback), do: fallback

  defp technical_detail?(value) when is_binary(value) do
    lower = String.downcase(value)

    String.contains?(lower, [
      "dbconnection",
      "ecto.",
      "http_status",
      "internal_stacktrace",
      "nsurlerrordomain",
      "oauth_tokens",
      "postgrex",
      "stacktrace",
      "token=",
      "traceback"
    ]) or String.contains?(value, ["{", "}", "=>", "#PID<"])
  end

  defp technical_detail?(_value), do: false

  defp truncate(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp short_id(nil), do: "n/a"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8) <> "..."

  defp format_log_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%H:%M:%S")

      _ ->
        timestamp
    end
  end

  defp format_log_timestamp(_), do: "n/a"

  defp log_level_class(level) when level in [:error, :critical, :alert, :emergency],
    do: "text-red-300"

  defp log_level_class(level) when level in [:warning, :notice], do: "text-amber-300"
  defp log_level_class(:info), do: "text-emerald-300"
  defp log_level_class(:debug), do: "text-sky-300"

  defp log_level_class(level) when is_binary(level) do
    case level do
      "error" -> log_level_class(:error)
      "critical" -> log_level_class(:critical)
      "alert" -> log_level_class(:alert)
      "emergency" -> log_level_class(:emergency)
      "warning" -> log_level_class(:warning)
      "notice" -> log_level_class(:notice)
      "info" -> log_level_class(:info)
      "debug" -> log_level_class(:debug)
      _ -> "text-zinc-300"
    end
  end

  defp log_level_class(_), do: "text-zinc-300"

  defp log_level_text_class(level) when level in [:error, :critical, :alert, :emergency],
    do: "text-red-700"

  defp log_level_text_class(level) when level in [:warning, :notice], do: "text-amber-700"
  defp log_level_text_class(:info), do: "text-emerald-700"
  defp log_level_text_class(:debug), do: "text-sky-700"

  defp log_level_text_class(level) when is_binary(level) do
    case level do
      "error" -> log_level_text_class(:error)
      "critical" -> log_level_text_class(:critical)
      "alert" -> log_level_text_class(:alert)
      "emergency" -> log_level_text_class(:emergency)
      "warning" -> log_level_text_class(:warning)
      "notice" -> log_level_text_class(:notice)
      "info" -> log_level_text_class(:info)
      "debug" -> log_level_text_class(:debug)
      _ -> "text-zinc-600"
    end
  end

  defp log_level_text_class(_), do: "text-zinc-600"

  defp fly_log_app_label(%{app: app}) when is_binary(app) do
    safe_product_detail(app, nil)
  end

  defp fly_log_app_label(_log), do: nil

  defp format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  defp format_uptime(_), do: "Unavailable"

  defp format_time(nil), do: "No timestamp"

  defp format_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_time(dt)
      _ -> datetime
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_due_datetime(nil, _chief_of_staff_schedule), do: nil

  defp format_due_datetime(datetime, chief_of_staff_schedule) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_due_datetime(dt, chief_of_staff_schedule)
      _ -> datetime
    end
  end

  defp format_due_datetime(%DateTime{} = dt, chief_of_staff_schedule) do
    timezone = dashboard_timezone(chief_of_staff_schedule)
    offset_hours = Timezones.offset_at(timezone.name, dt, timezone.offset_hours)
    display_time = DateTime.add(dt, offset_hours, :hour)
    timezone_label = Timezones.label(timezone.name, offset_hours)

    "#{Calendar.strftime(display_time, "%b %-d, %-I:%M %p")} #{timezone_label}"
  end

  defp format_due_datetime(%NaiveDateTime{} = dt, chief_of_staff_schedule) do
    timezone = dashboard_timezone(chief_of_staff_schedule)
    timezone_label = Timezones.label(timezone.name, timezone.offset_hours)

    "#{Calendar.strftime(dt, "%b %-d, %-I:%M %p")} #{timezone_label}"
  end

  defp format_datetime(nil, _chief_of_staff_schedule), do: nil

  defp format_datetime(datetime, chief_of_staff_schedule) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_datetime(dt, chief_of_staff_schedule)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt, chief_of_staff_schedule) do
    LocalTime.format_datetime(dt, nil, dashboard_timezone(chief_of_staff_schedule))
  end

  defp format_datetime(%NaiveDateTime{} = dt, chief_of_staff_schedule) do
    LocalTime.format_datetime(dt, nil, dashboard_timezone(chief_of_staff_schedule))
  end

  defp dashboard_timezone(schedule) when is_map(schedule) do
    timezone_name = fetch_map_value(schedule, "timezone_name")
    offset_hours = fetch_map_value(schedule, "timezone_offset_hours")

    normalize_dashboard_timezone(timezone_name, offset_hours)
  end

  defp dashboard_timezone(_schedule), do: normalize_dashboard_timezone(nil, -5)

  defp normalize_dashboard_timezone(timezone_name, offset_hours) do
    case Timezones.normalize(to_string(timezone_name || "")) do
      "offset:" <> offset ->
        %{name: nil, offset_hours: Timezones.normalize_offset(offset)}

      normalized when is_binary(normalized) ->
        fallback = offset_hours || Timezones.standard_offset(normalized)
        %{name: normalized, offset_hours: Timezones.normalize_offset(fallback)}

      _other ->
        %{name: nil, offset_hours: Timezones.normalize_offset(offset_hours)}
    end
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
