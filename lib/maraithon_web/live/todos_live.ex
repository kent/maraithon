defmodule MaraithonWeb.TodosLive do
  use MaraithonWeb, :live_view

  alias Maraithon.{BriefingSchedules, Projects, Repo, SourceLabels, Timezones}
  alias Maraithon.Todos
  alias Maraithon.Todos.{Brief, BriefActions, DecisionSignals, SourceActions, Todo}
  alias MaraithonWeb.TodoActionCopy

  require Logger

  @page_limit 50
  @brief_poll_ms 3_000
  @brief_max_polls 40
  @generating_progress "Reading the source"
  @default_filters %{
    "q" => "",
    "status" => "active",
    "attention" => "all",
    "due" => "all",
    "source" => "all",
    "project" => "all",
    "agent" => "all",
    "sort" => "rank",
    "dir" => "desc",
    "page" => "1"
  }
  @default_new_todo_params %{
    "title" => "",
    "next_action" => "",
    "due_at" => "",
    "priority" => "50",
    "project_id" => "",
    "notes" => ""
  }
  @empty_state_filter_keys ~w(q status attention due source project agent)
  @status_options [
    {"Active", "active"},
    {"Open", "open"},
    {"Snoozed", "snoozed"},
    {"Done", "done"},
    {"Dismissed", "dismissed"},
    {"All", "all"}
  ]
  @attention_options [
    {"Any attention", "all"},
    {"Needs action", "act_now"},
    {"Decisions", "decision"},
    {"Watching", "monitor"}
  ]
  @agent_options [
    {"Any helper", "all"},
    {"Maraithon can help", "can_help"},
    {"Needs you", "needs_you"}
  ]
  @due_options [
    {"Any due date", "all"},
    {"Past due", "overdue"},
    {"Due today", "today"},
    {"Next 7 days", "week"},
    {"No due date", "no_due"}
  ]
  @source_options [
    {"All sources", "all"},
    {"Gmail", "gmail"},
    {"Calendar", "calendar"},
    {"Google Calendar", "google_calendar"},
    {"Slack", "slack"},
    {"Telegram", "telegram"},
    {"iMessage", "imessage"},
    {"Notes", "notes"},
    {"Reminders", "reminders"},
    {"Files", "files"},
    {"Browser History", "browser_history"},
    {"Voice Memos", "voice_memos"},
    {"GitHub", "github"},
    {"Added by you", "manual"}
  ]
  @priority_options [
    {"Normal", "50"},
    {"High", "75"},
    {"Critical", "90"}
  ]
  @shortcut_groups [
    {"Move",
     [
       %{keys: ["j", "↓", "→"], label: "Next todo"},
       %{keys: ["k", "↑", "←"], label: "Previous todo"},
       %{keys: ["o", "Enter"], label: "Open active todo"},
       %{keys: ["u", "Esc"], label: "Back to the list"}
     ]},
    {"Process",
     [
       %{keys: ["x"], label: "Select active todo"},
       %{keys: ["e"], label: "Mark done"},
       %{keys: ["#"], label: "Dismiss"}
     ]},
    {"Find",
     [
       %{keys: ["/"], label: "Focus search"},
       %{keys: ["?"], label: "Show keyboard shortcuts"}
     ]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Todos",
       current_path: "/todos",
       filters: @default_filters,
       filter_form: to_form(@default_filters, as: :filters),
       status_options: @status_options,
       attention_options: @attention_options,
       agent_options: @agent_options,
       due_options: @due_options,
       source_options: @source_options,
       priority_options: @priority_options,
       shortcut_groups: @shortcut_groups,
       new_todo_form: to_form(@default_new_todo_params, as: :todo),
       new_todo_errors: %{},
       new_project_form: to_form(%{"name" => ""}, as: :project),
       projects: [],
       project_options: [{"Inbox", ""}],
       project_filter_options: [{"All projects", "all"}, {"Inbox", "inbox"}],
       todos: [],
       todo_navigation_ids: [],
       total_count: 0,
       active_todo_id: nil,
       selected_todo_ids: MapSet.new(),
       selected_todo_id: nil,
       selected_todo: nil,
       timezone_info: default_timezone_info(),
       brief: nil,
       brief_state: :idle,
       brief_todo_id: nil,
       brief_progress: nil,
       brief_polls_left: 0,
       reply_target: nil,
       reply_target_state: :idle,
       reply_target_todo_id: nil,
       reply_form: to_form(%{"subject" => "", "body" => ""}, as: :reply),
       reply_sending?: false,
       reply_sent: nil,
       todos_loaded?: false,
       page: 1,
       total_pages: 1
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)
    raw_todo_id = normalize_text(Map.get(params, "todo_id"))
    selected_todo_id = normalize_todo_id(raw_todo_id)

    if connected?(socket) and selected_todo_id do
      _ =
        Todos.record_user_opened(current_user_id(socket), selected_todo_id,
          actor_type: "user",
          source: "todos_detail"
        )
    end

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
      |> assign(:selected_todo_id, selected_todo_id)

    socket =
      cond do
        not connected?(socket) ->
          socket

        raw_todo_id && is_nil(selected_todo_id) ->
          push_patch(socket, to: todos_path(filters), replace: true)

        true ->
          # URL navigation is the natural, low-frequency invalidation point
          # for project labels/options and the user's timezone. Internal todo
          # events keep using the cached context to stay inexpensive.
          socket = refresh_todos(socket, reload_context?: true)

          socket =
            if selected_todo_id && is_nil(socket.assigns.selected_todo) &&
                 is_nil(socket.redirected) do
              push_patch(socket, to: todos_path(socket.assigns.filters), replace: true)
            else
              socket
            end

          load_brief(socket)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: todos_path(normalize_filters(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/todos")}
  end

  def handle_event("assign_todo_project", %{"assignment" => params}, socket) do
    todo_id = normalize_text(params["todo_id"])
    project_id = normalize_text(params["project_id"])

    user_id = current_user_id(socket)

    case Todos.update_for_user(
           user_id,
           todo_id,
           %{"project_id" => project_id},
           todo_action_opts(user_id, "Project changed from todo detail.")
         ) do
      {:ok, _todo} ->
        {:noreply, socket |> refresh_todos() |> put_flash(:info, "Project updated.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Project could not be updated.")}
    end
  end

  def handle_event("create_project", %{"project" => %{"name" => name}}, socket) do
    case normalize_text(name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Enter a project name.")}

      project_name ->
        case Projects.create_project(current_user_id(socket), %{"name" => project_name}) do
          {:ok, project} ->
            {:noreply,
             socket
             |> assign(:new_project_form, to_form(%{"name" => ""}, as: :project))
             |> refresh_todos(reload_context?: true)
             |> put_flash(:info, "#{project.name} created.")}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "That project could not be created.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Project creation failed. Try again.")}
        end
    end
  end

  def handle_event("create_todo", %{"todo" => params}, socket) do
    params = normalize_new_todo_params(params)
    user_id = current_user_id(socket)

    case build_manual_todo_attrs(user_id, params, socket.assigns.timezone_info) do
      {:ok, attrs} ->
        case Todos.upsert_many(
               user_id,
               [attrs],
               todo_action_opts(user_id, "Added from todo list.")
             ) do
          {:ok, [todo]} ->
            {:noreply,
             socket
             |> assign(:new_todo_form, to_form(@default_new_todo_params, as: :todo))
             |> assign(:new_todo_errors, %{})
             |> put_flash(:info, "Todo added.")
             |> push_patch(to: todo_detail_path(@default_filters, todo.id))}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:new_todo_form, to_form(params, as: :todo))
             |> assign(:new_todo_errors, %{})
             |> refresh_todos()
             |> put_flash(:error, TodoActionCopy.error(:create, reason))}
        end

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:new_todo_form, to_form(params, as: :todo))
         |> assign(:new_todo_errors, errors)
         |> put_flash(:error, "Check the follow-up details and try again.")}
    end
  end

  def handle_event("create_todo", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter a follow-up before adding it.")}
  end

  def handle_event("toggle_todo_selection", %{"id" => todo_id}, socket) do
    if visible_todo_id?(socket, todo_id) do
      {:noreply,
       assign(socket,
         selected_todo_ids: toggle_mapset_member(socket.assigns.selected_todo_ids, todo_id),
         active_todo_id: todo_id
       )}
    else
      {:noreply, socket}
    end
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

  def handle_event("todo_shortcut", %{"key" => key}, socket) when key in ["j", "k"] do
    direction = if key == "j", do: :next, else: :previous
    {:noreply, navigate_todo_shortcut(socket, direction)}
  end

  def handle_event("todo_shortcut", %{"key" => key} = params, socket)
      when key in ["o", "Enter"] do
    {:noreply, open_active_todo(socket, Map.get(params, "id"))}
  end

  def handle_event("todo_shortcut", %{"key" => "x"} = params, socket) do
    case shortcut_target_todo(socket, Map.get(params, "id")) do
      %Todo{id: todo_id} -> handle_event("toggle_todo_selection", %{"id" => todo_id}, socket)
      nil -> {:noreply, socket}
    end
  end

  def handle_event("todo_shortcut", %{"key" => "e"} = params, socket) do
    case shortcut_target_todo(socket, Map.get(params, "id")) do
      %Todo{id: todo_id, status: status} when status in ["open", "snoozed"] ->
        handle_event("complete_todo", %{"id" => todo_id}, socket)

      _todo ->
        {:noreply, socket}
    end
  end

  def handle_event("todo_shortcut", %{"key" => "#"} = params, socket) do
    case shortcut_target_todo(socket, Map.get(params, "id")) do
      %Todo{id: todo_id, status: status} when status in ["open", "snoozed"] ->
        handle_event("dismiss_todo", %{"id" => todo_id}, socket)

      _todo ->
        {:noreply, socket}
    end
  end

  def handle_event("todo_shortcut", %{"key" => key}, socket) when key in ["u", "Escape"] do
    if socket.assigns.selected_todo do
      {:noreply, push_patch(socket, to: todos_path(socket.assigns.filters))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("todo_shortcut", _params, socket), do: {:noreply, socket}

  def handle_event(
        "resolve_todo_shortcut",
        %{"action" => action, "id" => todo_id},
        socket
      )
      when action in ["complete", "dismiss"] and is_binary(todo_id) do
    result =
      case shortcut_target_todo(socket, todo_id) do
        %Todo{status: status} when status in ["open", "snoozed"] ->
          case action do
            "complete" -> resolve_todo(socket, todo_id, :complete)
            "dismiss" -> resolve_todo(socket, todo_id, :dismiss)
          end

        _todo ->
          {:error, socket}
      end

    case result do
      {:ok, socket} -> {:reply, %{ok: true}, socket}
      {:error, socket} -> {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("resolve_todo_shortcut", _params, socket) do
    {:reply, %{ok: false}, socket}
  end

  def handle_event("complete_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :complete)}
  end

  def handle_event("dismiss_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :dismiss)}
  end

  def handle_event("see_less_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :see_less)}
  end

  def handle_event("complete_todo", %{"id" => todo_id}, socket) do
    case resolve_todo(socket, todo_id, :complete) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("dismiss_todo", %{"id" => todo_id}, socket) do
    case resolve_todo(socket, todo_id, :dismiss) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("see_less_todo", %{"id" => todo_id}, socket) do
    selected? = socket.assigns.selected_todo_id == todo_id
    user_id = current_user_id(socket)
    preferred_next_todo_id = preferred_next_todo_id(navigation_todo_ids(socket), todo_id)

    case Todos.see_less_like(
           user_id,
           todo_id,
           Keyword.put(todo_actor_opts(user_id), :source, "todos_page")
         ) do
      {:ok, _result} ->
        socket =
          socket
          |> prepare_active_todo_after_resolution(todo_id, preferred_next_todo_id)
          |> refresh_todos()
          |> put_flash(:info, "Similar work will show up less often.")

        socket =
          if selected? do
            maybe_advance_after_resolution(socket, true, todo_id, preferred_next_todo_id)
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:error, TodoActionCopy.error(:see_less, reason))}
    end
  end

  def handle_event("open_todo_detail", %{"id" => todo_id}, socket) do
    if visible_todo_id?(socket, todo_id) do
      {:noreply,
       socket
       |> assign(:active_todo_id, todo_id)
       |> push_patch(to: todo_detail_path(socket.assigns.filters, todo_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_todo_next_action", %{"id" => todo_id, "todo" => params}, socket) do
    next_action = normalize_text(Map.get(params, "next_action"))

    cond do
      is_nil(next_action) ->
        {:noreply, put_flash(socket, :error, "Enter a next action before saving.")}

      String.length(next_action) < 4 ->
        {:noreply, put_flash(socket, :error, "Enter a next action with at least 4 characters.")}

      true ->
        user_id = current_user_id(socket)

        case Todos.update_for_user(
               user_id,
               todo_id,
               %{"next_action" => next_action},
               todo_action_opts(user_id, "Next action updated from todo detail.")
             ) do
          {:ok, _todo} ->
            {:noreply,
             socket
             |> refresh_todos()
             |> put_flash(:info, "Updated next action.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> refresh_todos()
             |> put_flash(:error, TodoActionCopy.error(:update_next_action, reason))}
        end
    end
  end

  def handle_event("save_todo_next_action", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter a next action before saving.")}
  end

  def handle_event("regenerate_brief", _params, socket) do
    case socket.assigns.selected_todo do
      %Todo{} = todo ->
        {:noreply,
         socket
         |> reset_reply_target()
         |> start_brief_generation(todo, force: true)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("update_reply", %{"reply" => params}, socket) do
    {:noreply, assign(socket, :reply_form, to_form(reply_form_params(params), as: :reply))}
  end

  def handle_event("send_reply", %{"reply" => params}, socket) do
    with %Todo{} = todo <- socket.assigns.selected_todo,
         false <- socket.assigns.reply_sending? do
      user_id = current_user_id(socket)
      edits = reply_form_params(params)

      {:noreply,
       socket
       |> assign(:reply_form, to_form(edits, as: :reply))
       |> assign(:reply_sending?, true)
       |> assign(:reply_target_state, :sending)
       |> start_async({:send_reply, todo.id}, fn ->
         BriefActions.send_reply(user_id, todo, edits)
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("send_reply", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:todo_brief, todo_id}, result, socket) do
    if todo_id == socket.assigns.brief_todo_id do
      handle_brief_result(result, todo_id, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_async({:send_reply, todo_id}, result, socket) do
    socket = assign(socket, :reply_sending?, false)

    case socket.assigns.selected_todo do
      %Todo{id: ^todo_id} ->
        case result do
          {:ok, {:ok, %{completed?: completed?, target: target}}} ->
            {:noreply,
             socket
             |> assign(:reply_sent, %{target: target, completed?: completed?})
             |> assign(:reply_target_state, :sent)
             |> refresh_todos()
             |> put_flash(:info, sent_flash(target, completed?))}

          {:ok, {:error, reason}} ->
            {:noreply,
             socket
             |> assign(:reply_target_state, :failed)
             |> put_flash(:error, send_error_copy(reason))}

          {:exit, reason} ->
            {:noreply,
             socket
             |> assign(:reply_target_state, :failed)
             |> put_flash(:error, send_error_copy(reason))}
        end

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:todo_brief_progress, todo_id, label}, socket) do
    if todo_id == socket.assigns.brief_todo_id and socket.assigns.brief_state == :generating do
      {:noreply, assign(socket, :brief_progress, label)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:todo_brief_poll, todo_id}, socket) do
    with true <- todo_id == socket.assigns.brief_todo_id,
         :waiting <- socket.assigns.brief_state,
         %Todo{} = todo <- Todos.get_for_user(current_user_id(socket), todo_id) do
      cond do
        brief = Brief.current(todo) ->
          {:noreply,
           socket
           |> assign(selected_todo: todo, brief: brief, brief_state: :ready, brief_progress: nil)
           |> seed_reply_form(todo)}

        Brief.generating?(todo) and socket.assigns.brief_polls_left > 0 ->
          Process.send_after(self(), {:todo_brief_poll, todo_id}, @brief_poll_ms)
          {:noreply, assign(socket, :brief_polls_left, socket.assigns.brief_polls_left - 1)}

        true ->
          {:noreply, start_brief_generation(socket, todo, force: true)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Loads the current brief for the selected todo, or starts generating one
  # for open work. Safe to call on every handle_params: a generation already
  # in flight for the same todo is left alone.
  defp load_brief(socket) do
    case socket.assigns.selected_todo do
      nil ->
        socket
        |> assign(brief: nil, brief_state: :idle, brief_todo_id: nil, brief_progress: nil)
        |> reset_reply_target()

      %Todo{} = todo ->
        socket =
          if socket.assigns.brief_todo_id == todo.id, do: socket, else: reset_reply_target(socket)

        cond do
          socket.assigns.brief_todo_id == todo.id and
              socket.assigns.brief_state in [:generating, :waiting] ->
            socket

          brief = Brief.current(todo) ->
            socket
            |> assign(
              brief: brief,
              brief_state: :ready,
              brief_todo_id: todo.id,
              brief_progress: nil
            )
            |> seed_reply_form(todo)

          todo.status in ~w(open snoozed) and connected?(socket) ->
            start_brief_generation(socket, todo, force: false)

          true ->
            assign(socket,
              brief: Brief.stored(todo),
              brief_state: :idle,
              brief_todo_id: todo.id,
              brief_progress: nil
            )
        end
    end
  end

  defp start_brief_generation(socket, %Todo{} = todo, opts) do
    user_id = current_user_id(socket)
    parent = self()
    force? = Keyword.get(opts, :force, false)

    socket
    |> assign(
      brief: if(force?, do: nil, else: socket.assigns.brief),
      brief_state: :generating,
      brief_todo_id: todo.id,
      brief_progress: @generating_progress,
      brief_polls_left: @brief_max_polls
    )
    |> start_async({:todo_brief, todo.id}, fn ->
      Brief.generate_and_store(user_id, todo.id,
        force: force?,
        on_progress: fn label -> send(parent, {:todo_brief_progress, todo.id, label}) end
      )
    end)
  end

  defp handle_brief_result({:ok, {:ok, %Todo{} = todo}}, _todo_id, socket) do
    {:noreply,
     socket
     |> refresh_todos()
     |> assign(
       brief: Brief.current(todo) || Brief.stored(todo),
       brief_state: :ready,
       brief_progress: nil
     )
     |> seed_reply_form(todo)}
  end

  defp handle_brief_result({:ok, {:error, :in_progress}}, todo_id, socket) do
    Process.send_after(self(), {:todo_brief_poll, todo_id}, @brief_poll_ms)

    {:noreply,
     assign(socket,
       brief_state: :waiting,
       brief_progress: "Finishing a brief already in progress"
     )}
  end

  defp handle_brief_result({:ok, {:error, reason}}, todo_id, socket) do
    Logger.warning("todo brief failed on detail page", todo_id: todo_id, reason: inspect(reason))
    {:noreply, assign(socket, brief_state: :failed, brief_progress: nil)}
  end

  defp handle_brief_result({:exit, reason}, todo_id, socket) do
    Logger.warning("todo brief crashed on detail page", todo_id: todo_id, reason: inspect(reason))
    {:noreply, assign(socket, brief_state: :failed, brief_progress: nil)}
  end

  # Seeds the editable reply from the brief. Preparation of the connected
  # send target is deliberately deferred to the Send click: resolving a Gmail
  # target writes a real draft into the mailbox, which must not happen just
  # because the page was opened.
  defp seed_reply_form(socket, %Todo{} = todo) do
    case Brief.reply(todo) do
      nil ->
        reset_reply_target(socket)

      reply ->
        socket
        |> assign(reply_form: reply_form_for(reply), reply_sent: nil)
        |> assign(
          reply_target: nil,
          reply_target_state: if(BriefActions.sendable?(todo), do: :ready, else: :unavailable),
          reply_target_todo_id: todo.id
        )
    end
  end

  defp reset_reply_target(socket) do
    assign(socket,
      reply_target: nil,
      reply_target_state: :idle,
      reply_target_todo_id: nil,
      reply_form: to_form(%{"subject" => "", "body" => ""}, as: :reply),
      reply_sending?: false,
      reply_sent: nil
    )
  end

  defp reply_form_for(reply) when is_map(reply) do
    to_form(
      %{
        "subject" => Map.get(reply, "subject") || "",
        "body" => Map.get(reply, "body") || ""
      },
      as: :reply
    )
  end

  defp reply_form_params(params) when is_map(params) do
    %{
      "subject" => params |> Map.get("subject", "") |> to_string(),
      "body" => params |> Map.get("body", "") |> to_string()
    }
  end

  defp reply_form_params(_params), do: %{"subject" => "", "body" => ""}

  defp sent_flash(%{channel: "slack", destination: destination}, completed?) do
    where = if is_binary(destination), do: " to #{destination}", else: ""
    "Posted#{where}." <> completion_suffix(completed?)
  end

  defp sent_flash(%{channel: "gmail", destination: destination}, completed?) do
    where = if is_binary(destination), do: " to #{destination}", else: ""
    "Email sent#{where}." <> completion_suffix(completed?)
  end

  defp sent_flash(_target, completed?), do: "Sent." <> completion_suffix(completed?)

  defp completion_suffix(true), do: " Marked done."
  defp completion_suffix(false), do: " Kept open for the remaining work."

  defp send_error_copy({:prepared_action_not_executed, _status, error}) when is_binary(error),
    do: "Could not send: #{error}"

  defp send_error_copy(_reason),
    do: "Could not send the reply. Copy it and send it from the source instead."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div
        id="todo-keyboard-scope"
        phx-hook=".TodoKeyboardShortcuts"
        data-view={if(@selected_todo, do: "detail", else: "index")}
        data-selected-todo-id={@selected_todo && @selected_todo.id}
        aria-busy={if(!@todos_loaded?, do: "true")}
      >
        <.todo_loading_shell :if={!@todos_loaded?} />

        <div :if={@todos_loaded?} id="todo-ready-content">
          <%= if @selected_todo do %>
            <.todo_detail_panel
              todo={@selected_todo}
              navigation_ids={@todo_navigation_ids}
              filters={@filters}
              project_options={@project_options}
              timezone_info={@timezone_info}
              brief={@brief}
              brief_state={@brief_state}
              brief_progress={@brief_progress}
              reply_form={@reply_form}
              reply_target={@reply_target}
              reply_target_state={@reply_target_state}
              reply_sending?={@reply_sending?}
              reply_sent={@reply_sent}
            />
          <% else %>
            <div class="space-y-4">
              <.page_header title="Todos">
                <:actions>
                  <.shortcut_help_button />
                </:actions>
              </.page_header>

          <details class="group">
            <summary class="inline-flex cursor-pointer list-none items-center gap-6 rounded-lg border border-zinc-950/10 bg-white px-3 py-2 text-sm/6 font-medium text-zinc-700 hover:text-zinc-950">
              Add a todo
              <span class="text-zinc-400 group-open:rotate-45" aria-hidden="true">+</span>
            </summary>
            <div class="mt-3">
              <.panel body_class="px-5 py-4">
          <:header>
            <div class="flex flex-wrap items-end justify-between gap-3">
              <h2 class="text-sm/6 font-semibold text-zinc-950">New todo</h2>
              <.form for={@new_project_form} id="new-project-form" phx-submit="create_project" class="flex items-center gap-2">
                <.c_input
                  id={@new_project_form[:name].id}
                  name={@new_project_form[:name].name}
                  value={@new_project_form[:name].value}
                  placeholder="New project"
                  maxlength="160"
                />
                <.button type="submit" variant="outline" phx-disable-with="Adding...">Add project</.button>
              </.form>
            </div>
          </:header>

          <.form
            for={@new_todo_form}
            id="new-todo-form"
            phx-submit="create_todo"
            class="grid gap-4 lg:grid-cols-[minmax(12rem,1fr)_minmax(14rem,1.2fr)_11rem_12rem_9rem_auto]"
          >
            <.field
              label="Work item"
              for={@new_todo_form[:title].id}
              error={new_todo_error(@new_todo_errors, "title")}
            >
              <.c_input
                id={@new_todo_form[:title].id}
                name={@new_todo_form[:title].name}
                value={@new_todo_form[:title].value}
                placeholder="What needs to be done?"
                maxlength="240"
                required
              />
            </.field>

            <.field
              label="Next action"
              for={@new_todo_form[:next_action].id}
              error={new_todo_error(@new_todo_errors, "next_action")}
            >
              <.c_input
                id={@new_todo_form[:next_action].id}
                name={@new_todo_form[:next_action].name}
                value={@new_todo_form[:next_action].value}
                placeholder="Send reply, decide owner, confirm ETA"
                maxlength="1000"
                required
              />
            </.field>

            <.field label="Project" for={@new_todo_form[:project_id].id}>
              <.c_select
                id={@new_todo_form[:project_id].id}
                name={@new_todo_form[:project_id].name}
              >
                <option
                  :for={{label, value} <- @project_options}
                  value={value}
                  selected={@new_todo_form[:project_id].value == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field
              label="Due"
              for={@new_todo_form[:due_at].id}
              error={new_todo_error(@new_todo_errors, "due_at")}
            >
              <.c_input
                id={@new_todo_form[:due_at].id}
                name={@new_todo_form[:due_at].name}
                type="datetime-local"
                value={@new_todo_form[:due_at].value}
              />
            </.field>

            <.field label="Urgency" for={@new_todo_form[:priority].id}>
              <.c_select id={@new_todo_form[:priority].id} name={@new_todo_form[:priority].name}>
                <option :for={{label, value} <- @priority_options} value={value} selected={@new_todo_form[:priority].value == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <div class="flex items-end">
              <.button type="submit" phx-disable-with="Adding...">Add</.button>
            </div>

            <.field label="Notes" for={@new_todo_form[:notes].id} class="lg:col-span-5">
              <.c_textarea
                id={@new_todo_form[:notes].id}
                name={@new_todo_form[:notes].name}
                value={@new_todo_form[:notes].value}
                rows={2}
                maxlength="8000"
                placeholder="Context, source, or reply constraints"
              />
            </.field>
          </.form>
        </.panel>

            </div>
          </details>

          <details class="group">
            <summary class="inline-flex cursor-pointer list-none items-center gap-3 rounded-lg border border-zinc-950/10 bg-white px-3 py-2 text-sm/6 font-medium text-zinc-700 hover:text-zinc-950">
              Search and filter
              <span class="text-xs/5 text-zinc-500"><%= active_filter_label(@filters) %></span>
            </summary>
            <div class="mt-3">
              <.panel body_class="px-5 py-4">
          <.form
            for={@filter_form}
            id="todo-filters"
            phx-change="update_filters"
            phx-submit="update_filters"
            class="grid gap-4 md:grid-cols-2 xl:grid-cols-[minmax(14rem,1.5fr)_repeat(6,minmax(8rem,1fr))_auto]"
          >
            <.field label="Search" for={@filter_form[:q].id}>
              <.c_input
                id={@filter_form[:q].id}
                name={@filter_form[:q].name}
                value={@filter_form[:q].value}
                placeholder="Search title, next action, person, account, source"
                phx-debounce="250"
                data-todo-search="true"
              />
            </.field>

            <.field label="Status" for={@filter_form[:status].id}>
              <.c_select id={@filter_form[:status].id} name={@filter_form[:status].name}>
                <option :for={{label, value} <- @status_options} value={value} selected={@filters["status"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Project" for={@filter_form[:project].id}>
              <.c_select id={@filter_form[:project].id} name={@filter_form[:project].name}>
                <option
                  :for={{label, value} <- @project_filter_options}
                  value={value}
                  selected={@filters["project"] == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Attention" for={@filter_form[:attention].id}>
              <.c_select id={@filter_form[:attention].id} name={@filter_form[:attention].name}>
                <option :for={{label, value} <- @attention_options} value={value} selected={@filters["attention"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Help" for={@filter_form[:agent].id}>
              <.c_select id={@filter_form[:agent].id} name={@filter_form[:agent].name}>
                <option
                  :for={{label, value} <- @agent_options}
                  value={value}
                  selected={@filters["agent"] == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Due" for={@filter_form[:due].id}>
              <.c_select id={@filter_form[:due].id} name={@filter_form[:due].name}>
                <option :for={{label, value} <- @due_options} value={value} selected={@filters["due"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Source" for={@filter_form[:source].id}>
              <.c_select id={@filter_form[:source].id} name={@filter_form[:source].name}>
                <option :for={{label, value} <- @source_options} value={value} selected={@filters["source"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <div class="flex items-end">
              <.button type="button" variant="outline" phx-click="clear_filters">Reset</.button>
            </div>
          </.form>
        </.panel>

            </div>
          </details>

        <.panel body_class="px-5 py-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <p class="text-sm/6 text-zinc-500">
                <%= result_count_label(@todos, @total_count, @page) %>
              </p>
              <.badge color="zinc"><%= active_filter_label(@filters) %></.badge>
            </div>
          </:header>

          <div class={[
            "min-w-0 py-2",
            MapSet.size(@selected_todo_ids) > 0 && "pb-24"
          ]}>
              <.todo_bulk_toolbar selected_todo_ids={@selected_todo_ids} />

              <.table>
                <.table_head>
                  <.table_row>
                    <.table_header class="w-10">
                      <input
                        type="checkbox"
                        aria-label="Select all todos"
                        checked={all_visible_todos_selected?(@todos, @selected_todo_ids)}
                        phx-click="toggle_all_todos"
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_header>
                    <.sortable_table_header filters={@filters} field="title" class="min-w-[20rem]">
                      Todo
                    </.sortable_table_header>
                    <.table_header class="min-w-40">Context</.table_header>
                    <.sortable_table_header filters={@filters} field="due" class="min-w-32">
                      Due
                    </.sortable_table_header>
                    <.table_header class="w-24 text-right">Action</.table_header>
                  </.table_row>
                </.table_head>
                <.table_body>
                  <.table_row :if={@todos == []}>
                    <.table_cell colspan="5" class="py-10 text-center text-sm/6 text-zinc-500">
                      <%= empty_message(@filters) %>
                    </.table_cell>
                  </.table_row>

                  <.table_row
                    :for={todo <- @todos}
                    :key={todo.id}
                    id={"todo-#{todo.id}"}
                    phx-click="open_todo_detail"
                    phx-value-id={todo.id}
                    data-todo-row="true"
                    data-todo-id={todo.id}
                    data-active={to_string(todo.id == @active_todo_id)}
                    aria-current={if(todo.id == @active_todo_id, do: "true")}
                    class={todo_row_class(todo, @selected_todo_ids)}
                  >
                    <.table_cell class="w-10 align-top">
                      <span
                        data-active-indicator="true"
                        class="absolute inset-y-2 left-0 hidden w-0.5 rounded-full bg-blue-600 group-data-[active=true]:block"
                        aria-hidden="true"
                      />
                      <input
                        type="checkbox"
                        aria-label={"Select #{todo.title}"}
                        checked={MapSet.member?(@selected_todo_ids, todo.id)}
                        phx-click="toggle_todo_selection"
                        phx-value-id={todo.id}
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_cell>
                    <.table_cell class="max-w-2xl whitespace-normal align-top">
                      <div class="flex flex-wrap items-center gap-2">
                        <div class="font-medium text-zinc-950"><%= todo.title %></div>
                        <.badge :if={todo.status != "open"} color={status_color(todo.status)}>
                          <%= todo_status_label(todo.status) %>
                        </.badge>
                        <.badge :if={todo_decision_signal?(todo)} color="indigo">Decision</.badge>
                        <.badge :if={todo.priority >= 75} color={priority_color(todo.priority)}>
                          <%= priority_label(todo.priority) %>
                        </.badge>
                      </div>
                      <p :if={present?(todo.next_action)} class="mt-1 line-clamp-1 text-sm/6 text-zinc-600">
                        <span class="font-medium text-zinc-800"><%= todo_next_action_label(todo) %>:</span>
                        <%= todo.next_action %>
                      </p>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top">
                      <div class="text-sm/6 text-zinc-700"><%= todo_project_name(todo, @projects) %></div>
                      <div class="mt-1 flex flex-wrap items-center gap-1.5">
                        <span class="text-xs/5 text-zinc-500"><%= todo_source_label(todo.source) %></span>
                        <.badge color={agent_actionability_color(todo.agent_actionability)}>
                          <%= agent_actionability_label(todo) %>
                        </.badge>
                      </div>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top text-xs/5 text-zinc-500">
                      <%= format_datetime(todo.due_at, "No due date", @timezone_info) %>
                    </.table_cell>
                    <.table_cell class="align-top text-right">
                      <.button
                        :if={todo.status in ["open", "snoozed"]}
                        type="button"
                        data-todo-resolve="complete"
                        data-todo-id={todo.id}
                        phx-click="complete_todo"
                        phx-value-id={todo.id}
                        variant="plain"
                        class="text-xs text-zinc-500 hover:text-zinc-950"
                      >
                        Done
                      </.button>
                    </.table_cell>
                  </.table_row>
                </.table_body>
              </.table>
          </div>

          <nav
            :if={@total_pages > 1}
            id="todo-pagination"
            aria-label="Todo pages"
            class="flex flex-wrap items-center justify-between gap-3 border-t border-zinc-950/10 py-4"
          >
            <p class="text-sm/6 text-zinc-500">Page <%= @page %> of <%= @total_pages %></p>
            <div class="flex items-center gap-2">
              <.button :if={@page == 1} type="button" variant="outline" disabled>
                Previous
              </.button>
              <.button
                :if={@page > 1}
                patch={todos_path(@filters, %{"page" => Integer.to_string(@page - 1)})}
                variant="outline"
              >
                Previous
              </.button>
              <.button
                :if={@page < @total_pages}
                patch={todos_path(@filters, %{"page" => Integer.to_string(@page + 1)})}
                variant="outline"
              >
                Next
              </.button>
              <.button :if={@page == @total_pages} type="button" variant="outline" disabled>
                Next
              </.button>
            </div>
          </nav>
        </.panel>
            </div>
          <% end %>

          <.shortcut_help_modal shortcut_groups={@shortcut_groups} />
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".TodoKeyboardShortcuts">
          export default {
            mounted() {
              this.shortcutsOpen = false
              this.optimisticRows = new Map()
              this.processingTodoIds = new Set()

              this.handleClick = (event) => {
                const trigger = event.target?.closest?.("[data-shortcuts-trigger='true']")
                const close = event.target?.closest?.("[data-shortcuts-close='true']")
                const resolve = event.target?.closest?.("[data-todo-resolve]")

                if (trigger) {
                  event.preventDefault()
                  event.stopPropagation()
                  this.openShortcuts()
                } else if (close) {
                  event.preventDefault()
                  event.stopPropagation()
                  this.closeShortcuts()
                } else if (resolve) {
                  event.preventDefault()
                  event.stopPropagation()
                  this.optimisticallyResolveTodo(resolve.dataset.todoId, resolve.dataset.todoResolve)
                }
              }

              this.handleKeydown = (event) => {
                if (event.metaKey || event.ctrlKey || event.altKey) return

                const target = event.target
                const tag = target?.tagName
                const typing = target?.isContentEditable || tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT"
                const key = event.key.length === 1 ? event.key.toLowerCase() : event.key

                if (this.shortcutsOpen) {
                  if (key === "Escape") {
                    event.preventDefault()
                    this.closeShortcuts()
                  }
                  return
                }

                if (typing) return

                if (key === "?") {
                  event.preventDefault()
                  this.openShortcuts()
                  return
                }

                if (event.shiftKey && key !== "#") return

                if (key === "/" && this.el.dataset.view === "index") {
                  const search = this.el.querySelector("[data-todo-search='true']")
                  if (search) {
                    event.preventDefault()
                    const filters = search.closest("details")
                    if (filters) filters.open = true
                    window.requestAnimationFrame(() => {
                      search.focus()
                      search.select()
                    })
                  }
                  return
                }

                const normalizedKey = this.normalizeKey(key)
                const indexKeys = ["j", "k", "o", "Enter", "x", "e", "#"]
                const detailKeys = ["j", "k", "u", "Escape", "e", "#"]
                const allowed = this.el.dataset.view === "detail" ? detailKeys : indexKeys

                if (!allowed.includes(normalizedKey)) return
                event.preventDefault()

                if (this.el.dataset.view === "index" && ["j", "k"].includes(normalizedKey)) {
                  this.moveActiveTodo(normalizedKey === "j" ? 1 : -1)
                  return
                }

                const todoId = this.activeTodoId()

                if (this.el.dataset.view === "index" && normalizedKey === "x") {
                  this.toggleActiveCheckbox()
                }

                if (["e", "#"].includes(normalizedKey) && todoId) {
                  const action = normalizedKey === "e" ? "complete" : "dismiss"
                  this.optimisticallyResolveTodo(todoId, action)
                  return
                }

                this.pushEvent("todo_shortcut", {key: normalizedKey, id: todoId})
              }

              this.el.addEventListener("click", this.handleClick)
              window.addEventListener("keydown", this.handleKeydown)
              this.scrollActiveTodoIntoView()
            },
            beforeUpdate() {
              this.activeTodoIdBeforeUpdate = this.activeTodoId()
            },
            updated() {
              this.syncShortcutModal()
              this.restoreActiveTodoAfterUpdate()
              this.scrollActiveTodoIntoView()
            },
            destroyed() {
              this.el.removeEventListener("click", this.handleClick)
              window.removeEventListener("keydown", this.handleKeydown)
              document.documentElement.classList.remove("overflow-hidden")
            },
            normalizeKey(key) {
              if (key === "ArrowDown" || key === "ArrowRight") return "j"
              if (key === "ArrowUp" || key === "ArrowLeft") return "k"
              return key
            },
            todoRows() {
              return Array.from(this.el.querySelectorAll("[data-todo-row='true']:not([hidden])"))
            },
            activeTodoRow() {
              return this.el.querySelector("[data-todo-row='true'][data-active='true']:not([hidden])")
            },
            activeTodoId() {
              if (this.el.dataset.view === "detail") return this.el.dataset.selectedTodoId || null
              return this.activeTodoRow()?.dataset.todoId || null
            },
            setActiveTodo(row) {
              if (!row) return

              this.todoRows().forEach((candidate) => {
                const active = candidate === row
                candidate.dataset.active = active ? "true" : "false"
                if (active) candidate.setAttribute("aria-current", "true")
                else candidate.removeAttribute("aria-current")
              })

              row.scrollIntoView({block: "nearest"})
            },
            moveActiveTodo(offset) {
              const rows = this.todoRows()
              const activeRow = this.activeTodoRow()
              const activeIndex = rows.indexOf(activeRow)
              const targetIndex = Math.max(0, Math.min(rows.length - 1, activeIndex + offset))
              this.setActiveTodo(rows[targetIndex])
            },
            toggleActiveCheckbox() {
              const checkbox = this.activeTodoRow()?.querySelector("input[type='checkbox']")
              if (checkbox) checkbox.checked = !checkbox.checked
            },
            optimisticallyResolveTodo(todoId, action) {
              if (!todoId || !["complete", "dismiss"].includes(action)) return
              if (this.processingTodoIds.has(todoId)) return
              this.processingTodoIds.add(todoId)

              const row = this.el.querySelector(`[data-todo-row='true'][data-todo-id='${todoId}']`)

              if (row) {
                const rows = this.todoRows()
                const index = rows.indexOf(row)
                const nextRow = rows[index + 1] || rows[index - 1]
                this.optimisticRows.set(todoId, row)
                row.hidden = true
                this.setActiveTodo(nextRow)
              } else {
                this.el.setAttribute("aria-busy", "true")
                const button = this.el.querySelector(`[data-todo-resolve='${action}'][data-todo-id='${todoId}']`)

                if (button) {
                  this.processingButton = {
                    element: button,
                    html: button.innerHTML,
                    disabled: button.disabled
                  }
                  button.disabled = true
                  button.textContent = action === "complete" ? "Marking done…" : "Dismissing…"
                }
              }

              this.pushEvent("resolve_todo_shortcut", {action, id: todoId}, (reply) => {
                this.el.removeAttribute("aria-busy")
                const optimisticRow = this.optimisticRows.get(todoId)

                if (reply?.ok !== true && optimisticRow?.isConnected) {
                  optimisticRow.hidden = false
                  this.setActiveTodo(optimisticRow)
                }

                this.optimisticRows.delete(todoId)
                this.processingTodoIds.delete(todoId)

                if (this.processingButton?.element?.isConnected) {
                  this.processingButton.element.innerHTML = this.processingButton.html
                  this.processingButton.element.disabled = this.processingButton.disabled
                }

                this.processingButton = null
              })
            },
            scrollActiveTodoIntoView() {
              if (this.el.dataset.view !== "index") return
              window.requestAnimationFrame(() => {
                this.activeTodoRow()?.scrollIntoView({block: "nearest"})
              })
            },
            restoreActiveTodoAfterUpdate() {
              if (this.el.dataset.view !== "index" || !this.activeTodoIdBeforeUpdate) return
              const row = this.el.querySelector(`[data-todo-row='true'][data-todo-id='${this.activeTodoIdBeforeUpdate}']`)
              if (row) this.setActiveTodo(row)
              this.activeTodoIdBeforeUpdate = null
            },
            openShortcuts() {
              this.shortcutsOpen = true
              this.syncShortcutModal()
              window.requestAnimationFrame(() => {
                this.el.querySelector("#todo-shortcuts-close")?.focus()
              })
            },
            closeShortcuts() {
              this.shortcutsOpen = false
              this.syncShortcutModal()
              window.requestAnimationFrame(() => {
                this.el.querySelector("[data-shortcuts-trigger='true']")?.focus()
              })
            },
            syncShortcutModal() {
              const modal = this.el.querySelector("[data-shortcuts-modal='true']")
              if (modal) modal.hidden = !this.shortcutsOpen
              document.documentElement.classList.toggle("overflow-hidden", this.shortcutsOpen)
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_todos(socket, opts \\ []) do
    socket =
      if Keyword.get(opts, :reload_context?, false) or not socket.assigns.todos_loaded? do
        load_todo_context(socket)
      else
        socket
      end

    user_id = current_user_id(socket)
    query_opts = todo_query_opts(socket.assigns.filters, socket.assigns.timezone_info)
    requested_page = filter_page(socket.assigns.filters)
    selected_todo = selected_todo_for_user(user_id, socket.assigns.selected_todo_id)

    {todos, todo_navigation_ids, total_count, total_pages, page} =
      case selected_todo do
        %Todo{id: selected_todo_id} ->
          navigation_ids = Todos.list_ids_for_user(user_id, query_opts)
          count = length(navigation_ids)
          pages = max(div(count + @page_limit - 1, @page_limit), 1)
          selected_page = todo_page_for_id(navigation_ids, selected_todo_id)

          {[], navigation_ids, count, pages, selected_page || min(requested_page, pages)}

        nil ->
          {todos, count, pages, current_page} =
            load_todo_page(user_id, query_opts, requested_page)

          navigation_ids = Enum.map(todos, & &1.id)
          {todos, navigation_ids, count, pages, current_page}
      end

    filters = Map.put(socket.assigns.filters, "page", Integer.to_string(page))

    visible_ids =
      case selected_todo do
        %Todo{} ->
          todo_navigation_ids
          |> Enum.slice((page - 1) * @page_limit, @page_limit)
          |> MapSet.new()

        nil ->
          todos |> Enum.map(& &1.id) |> MapSet.new()
      end

    selected_todo_ids = MapSet.intersection(socket.assigns.selected_todo_ids, visible_ids)

    active_todo_id =
      case selected_todo do
        %Todo{id: todo_id} -> todo_id
        nil -> resolved_active_todo_id(todos, socket.assigns.active_todo_id, nil)
      end

    socket =
      assign(socket,
        filters: filters,
        filter_form: to_form(filters, as: :filters),
        todos: todos,
        todo_navigation_ids: todo_navigation_ids,
        total_count: total_count,
        todos_loaded?: true,
        page: page,
        total_pages: total_pages,
        active_todo_id: active_todo_id,
        selected_todo_ids: selected_todo_ids,
        selected_todo_id: selected_todo && selected_todo.id,
        selected_todo: selected_todo
      )

    if connected?(socket) and is_nil(selected_todo) and requested_page != page do
      push_patch(socket, to: todos_path(filters), replace: true)
    else
      socket
    end
  end

  defp load_todo_context(socket) do
    user_id = current_user_id(socket)
    timezone_info = user_timezone_info(user_id)
    projects = Projects.list_projects(user_id: user_id, status: "active")

    assign(socket,
      projects: projects,
      project_options: [{"Inbox", ""} | Enum.map(projects, &{&1.name, &1.id})],
      project_filter_options: [
        {"All projects", "all"},
        {"Inbox", "inbox"} | Enum.map(projects, &{&1.name, &1.id})
      ],
      timezone_info: timezone_info
    )
  end

  defp load_todo_page(user_id, query_opts, requested_page) do
    {:ok, result} =
      Repo.transaction(fn ->
        # SQL Sandbox owns the outer transaction and sets this isolation at
        # checkout. Everywhere else this is the first statement after BEGIN.
        unless Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        end

        count = Todos.count_for_user(user_id, query_opts) || 0
        pages = max(div(count + @page_limit - 1, @page_limit), 1)
        page = min(requested_page, pages)

        todos =
          Todos.list_for_user(
            user_id,
            Keyword.merge(query_opts,
              limit: @page_limit,
              offset: (page - 1) * @page_limit
            )
          )

        {todos, count, pages, page}
      end)

    result
  end

  attr :selected_todo_ids, :any, required: true

  defp todo_bulk_toolbar(assigns) do
    assigns = assign(assigns, :selected_count, MapSet.size(assigns.selected_todo_ids))

    ~H"""
    <div
      :if={@selected_count > 0}
      id="todo-bulk-actions"
      class="pointer-events-none fixed inset-x-3 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-50 flex justify-center sm:inset-x-6 lg:bottom-6"
    >
      <div class="pointer-events-auto flex max-w-[calc(100vw-1.5rem)] flex-wrap items-center justify-center gap-1.5 rounded-lg border border-zinc-950/20 bg-zinc-950/95 px-2.5 py-2 text-white shadow-xl ring-1 ring-white/10 backdrop-blur">
        <span class="rounded-md border border-white/10 bg-white/10 px-3 py-1.5 text-sm/6 font-semibold">
          <%= @selected_count %> selected
        </span>
        <button
          type="button"
          phx-click="clear_todo_selection"
          aria-label="Clear selection"
          class="rounded-md px-2 py-1.5 text-sm/6 text-zinc-300 hover:bg-white/10 hover:text-white focus:outline-none focus:ring-2 focus:ring-white/30"
        >
          ×
        </button>
        <span class="mx-0.5 hidden h-6 w-px bg-white/15 sm:block" aria-hidden="true"></span>
        <.button
          type="button"
          phx-click="complete_selected_todos"
          variant="plain"
          class="text-xs text-zinc-200 hover:bg-white/10 hover:text-white"
        >
          Done
        </.button>
        <.button
          type="button"
          phx-click="dismiss_selected_todos"
          variant="plain"
          class="text-xs text-zinc-200 hover:bg-white/10 hover:text-white"
        >
          Dismiss
        </.button>
        <.button
          type="button"
          phx-click="see_less_selected_todos"
          variant="plain"
          class="text-xs text-zinc-200 hover:bg-white/10 hover:text-white"
        >
          Show less
        </.button>
      </div>
    </div>
    """
  end

  defp todo_loading_shell(assigns) do
    ~H"""
    <section
      id="todo-loading-shell"
      data-todo-loading-shell="true"
      role="status"
      aria-live="polite"
      aria-label="Loading todos"
      class="space-y-4"
    >
      <span class="sr-only">Loading todos…</span>

      <div class="animate-pulse space-y-4 motion-reduce:animate-none" aria-hidden="true">
        <div class="flex items-center justify-between gap-4">
          <div class="h-9 w-28 rounded-md bg-zinc-200"></div>
          <div class="h-9 w-28 rounded-md bg-zinc-200"></div>
        </div>

        <div class="h-10 w-32 rounded-lg border border-zinc-950/5 bg-white shadow-sm"></div>

        <.panel body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="flex items-center gap-2">
                <div class="h-9 w-24 rounded-md bg-zinc-100"></div>
                <div class="h-9 w-28 rounded-md bg-zinc-100"></div>
                <div class="h-9 w-20 rounded-md bg-zinc-100"></div>
              </div>
              <div class="flex items-center gap-3">
                <div class="h-5 w-16 rounded bg-zinc-100"></div>
                <div class="h-9 w-32 rounded-md bg-zinc-100"></div>
              </div>
            </div>
          </:header>

          <div class="overflow-hidden">
            <div class="min-w-[58rem]">
              <div class="grid grid-cols-[2.5rem_minmax(20rem,1.6fr)_minmax(10rem,0.7fr)_9rem_5rem] items-center gap-4 border-b border-zinc-950/10 bg-zinc-50/70 px-5 py-3">
                <div class="size-4 rounded bg-zinc-200"></div>
                <div class="h-3 w-16 rounded bg-zinc-200"></div>
                <div class="h-3 w-14 rounded bg-zinc-200"></div>
                <div class="h-3 w-10 rounded bg-zinc-200"></div>
                <div class="ml-auto h-3 w-12 rounded bg-zinc-200"></div>
              </div>

              <div
                :for={_row <- 1..6}
                class="grid min-h-24 grid-cols-[2.5rem_minmax(20rem,1.6fr)_minmax(10rem,0.7fr)_9rem_5rem] items-start gap-4 border-b border-zinc-950/5 px-5 py-4 last:border-b-0"
              >
                <div class="mt-1 size-4 rounded bg-zinc-100"></div>
                <div class="space-y-3">
                  <div class="h-4 w-2/5 rounded bg-zinc-200"></div>
                  <div class="h-3 w-4/5 rounded bg-zinc-100"></div>
                </div>
                <div class="space-y-3">
                  <div class="h-3.5 w-20 rounded bg-zinc-200"></div>
                  <div class="h-5 w-24 rounded-md bg-zinc-100"></div>
                </div>
                <div class="h-3.5 w-20 rounded bg-zinc-100"></div>
                <div class="ml-auto h-7 w-12 rounded-md bg-zinc-100"></div>
              </div>
            </div>
          </div>
        </.panel>
      </div>
    </section>
    """
  end

  attr :compact, :boolean, default: false

  defp shortcut_help_button(assigns) do
    ~H"""
    <.button
      id="todo-shortcuts-trigger"
      type="button"
      variant="outline"
      data-shortcuts-trigger="true"
      aria-haspopup="dialog"
      aria-controls="todo-shortcuts-modal"
      title="Keyboard shortcuts (?)"
      class={@compact && "px-2 text-xs"}
    >
      <span class="text-base/5" aria-hidden="true">⌨</span>
      <span :if={!@compact}>Shortcuts</span>
      <kbd class="rounded border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 text-[11px]/4 font-medium text-zinc-500">
        ?
      </kbd>
    </.button>
    """
  end

  attr :shortcut_groups, :list, required: true

  defp shortcut_help_modal(assigns) do
    ~H"""
    <div
      id="todo-shortcuts-modal"
      class="fixed inset-0 z-50"
      data-shortcuts-modal="true"
      hidden
    >
      <div
        class="absolute inset-0 bg-zinc-950/35"
        data-shortcuts-close="true"
        aria-hidden="true"
      />
      <div class="relative mx-auto flex min-h-full w-full max-w-xl items-start px-3 pt-[12vh] sm:px-6">
        <section
          class="w-full overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-xl ring-1 ring-zinc-950/5"
          role="dialog"
          aria-modal="true"
          aria-labelledby="todo-shortcuts-title"
          aria-describedby="todo-shortcuts-description"
        >
          <header class="flex items-start justify-between gap-4 border-b border-zinc-950/10 px-5 py-4">
            <div>
              <h2 id="todo-shortcuts-title" class="text-base/6 font-semibold text-zinc-950">
                Keyboard shortcuts
              </h2>
              <p id="todo-shortcuts-description" class="mt-1 text-sm/6 text-zinc-500">
                The blue row is the active todo. Shortcuts do not run while you are typing.
              </p>
            </div>
            <.button
              id="todo-shortcuts-close"
              type="button"
              variant="plain"
              data-shortcuts-close="true"
              aria-label="Close keyboard shortcuts"
              class="-mr-2 -mt-1 px-2 text-zinc-500"
            >
              <span class="text-lg/5" aria-hidden="true">×</span>
            </.button>
          </header>

          <div class="grid gap-5 px-5 py-5 sm:grid-cols-2">
            <section :for={{group, shortcuts} <- @shortcut_groups}>
              <h3 class="text-xs/5 font-semibold uppercase tracking-wide text-zinc-500">
                <%= group %>
              </h3>
              <dl class="mt-2 divide-y divide-zinc-950/5">
                <div
                  :for={shortcut <- shortcuts}
                  class="flex items-center justify-between gap-4 py-2 text-sm/6"
                >
                  <dt class="text-zinc-700"><%= shortcut.label %></dt>
                  <dd class="flex shrink-0 items-center gap-1">
                    <kbd
                      :for={key <- shortcut.keys}
                      class="min-w-6 rounded border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 text-center text-xs/5 font-semibold text-zinc-700 shadow-sm"
                    >
                      <%= key %>
                    </kbd>
                  </dd>
                </div>
              </dl>
            </section>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :filters, :map, required: true
  attr :field, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp sortable_table_header(assigns) do
    assigns =
      assigns
      |> assign(:next_dir, next_sort_dir(assigns.filters, assigns.field))
      |> assign(:indicator, sort_indicator(assigns.filters, assigns.field))

    ~H"""
    <.table_header class={@class}>
      <.link
        patch={todos_path(@filters, %{"sort" => @field, "dir" => @next_dir, "page" => "1"})}
        class="inline-flex items-center gap-1 text-zinc-500 hover:text-zinc-950"
      >
        <%= render_slot(@inner_block) %>
        <span :if={@indicator != ""} class="text-[10px]/4 text-zinc-400"><%= @indicator %></span>
      </.link>
    </.table_header>
    """
  end

  attr :todo, :any, required: true
  attr :navigation_ids, :list, required: true
  attr :filters, :map, required: true
  attr :project_options, :list, required: true
  attr :timezone_info, :map, required: true
  attr :brief, :any, default: nil
  attr :brief_state, :atom, default: :idle
  attr :brief_progress, :string, default: nil
  attr :reply_form, :any, required: true
  attr :reply_target, :any, default: nil
  attr :reply_target_state, :atom, default: :idle
  attr :reply_sending?, :boolean, default: false
  attr :reply_sent, :any, default: nil

  defp todo_detail_panel(assigns) do
    can_edit_next_action = todo_next_action_editable?(assigns.todo)
    source_action = SourceActions.for_todo(assigns.todo) || %{}
    {previous_todo, next_todo} = todo_neighbor_targets(assigns.navigation_ids, assigns.todo.id)

    assigns =
      assigns
      |> assign(:can_edit_next_action, can_edit_next_action)
      |> assign(:previous_todo, previous_todo)
      |> assign(:next_todo, next_todo)
      |> assign(:previous_todo_path, todo_navigation_path(assigns.filters, previous_todo))
      |> assign(:next_todo_path, todo_navigation_path(assigns.filters, next_todo))
      |> assign(:decision_signal?, todo_decision_signal?(assigns.todo))
      |> assign(:facts, todo_fact_rows(assigns.todo, assigns.timezone_info))
      |> assign(:open_url, Map.get(source_action, "open_url"))
      |> assign(:open_label, Map.get(source_action, "open_label"))
      |> assign(:reply, brief_reply(assigns.brief))
      |> assign(:source_history, source_history(assigns.brief, source_action))
      |> assign(:source_subject, source_subject(assigns.brief, source_action))
      |> assign(
        :next_action_form,
        to_form(%{"next_action" => assigns.todo.next_action || ""}, as: :todo)
      )

    ~H"""
    <div id="todo-detail" class="mx-auto max-w-5xl space-y-5">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <.link
          patch={todos_path(@filters)}
          class="inline-flex items-center gap-1 text-sm/6 font-medium text-zinc-500 hover:text-zinc-950"
        >
          <span aria-hidden="true">←</span> Back to todos
        </.link>

        <nav id="todo-sibling-navigation" aria-label="Todo navigation" class="flex items-center gap-1">
          <.button
            :if={@previous_todo}
            id="previous-todo"
            patch={@previous_todo_path}
            variant="plain"
            class="text-xs text-zinc-500"
            aria-label="Previous todo"
            aria-keyshortcuts="ArrowLeft K"
            title="Previous todo (K or Left arrow)"
          >
            <span aria-hidden="true">←</span> Previous
          </.button>
          <.button
            :if={is_nil(@previous_todo)}
            id="previous-todo"
            type="button"
            disabled
            variant="plain"
            class="text-xs text-zinc-400"
            aria-label="Previous todo"
          >
            <span aria-hidden="true">←</span> Previous
          </.button>
          <.button
            :if={@next_todo}
            id="next-todo"
            patch={@next_todo_path}
            variant="plain"
            class="text-xs text-zinc-500"
            aria-label="Next todo"
            aria-keyshortcuts="ArrowRight J"
            title="Next todo (J or Right arrow)"
          >
            Next <span aria-hidden="true">→</span>
          </.button>
          <.button
            :if={is_nil(@next_todo)}
            id="next-todo"
            type="button"
            disabled
            variant="plain"
            class="text-xs text-zinc-400"
            aria-label="Next todo"
          >
            Next <span aria-hidden="true">→</span>
          </.button>
          <.shortcut_help_button compact />
        </nav>
      </div>

      <header class="border-b border-zinc-950/10 pb-5">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <.badge color={status_color(@todo.status)}><%= todo_status_label(@todo.status) %></.badge>
              <.badge color={attention_color(@todo.attention_mode)}>
                <%= attention_mode_label(@todo.attention_mode) %>
              </.badge>
              <.badge :if={@decision_signal?} color="indigo">Decision</.badge>
              <.badge :if={@todo.priority >= 75} color={priority_color(@todo.priority)}>
                <%= priority_label(@todo.priority) %>
              </.badge>
            </div>
            <h1 class="mt-3 text-2xl/8 font-semibold tracking-tight text-zinc-950"><%= @todo.title %></h1>
            <p :if={present?(@todo.summary)} class="mt-2 max-w-3xl text-sm/6 text-zinc-600">
              <%= @todo.summary %>
            </p>
          </div>

          <div id="todo-primary-actions" class="flex shrink-0 flex-wrap items-center gap-2">
            <.button
              :if={@can_edit_next_action}
              type="button"
              data-todo-resolve="complete"
              data-todo-id={@todo.id}
              phx-click="complete_todo"
              phx-value-id={@todo.id}
            >
              Mark done
            </.button>
            <.button navigate={~p"/todos/#{@todo.id}/chat"} variant="outline">
              Ask Maraithon
            </.button>
            <.button
              :if={@can_edit_next_action}
              type="button"
              data-todo-resolve="dismiss"
              data-todo-id={@todo.id}
              phx-click="dismiss_todo"
              phx-value-id={@todo.id}
              variant="plain"
              class="text-xs text-zinc-600"
            >
              Dismiss
            </.button>
            <.button
              :if={@can_edit_next_action}
              type="button"
              phx-click="see_less_todo"
              phx-value-id={@todo.id}
              variant="plain"
              class="text-xs text-zinc-600"
            >
              Show less
            </.button>
          </div>
        </div>
      </header>

      <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_17rem]">
        <div class="space-y-5">
          <.reply_panel
            :if={@reply || @source_history != []}
            todo={@todo}
            reply={@reply}
            source_history={@source_history}
            source_subject={@source_subject}
            timezone_info={@timezone_info}
            reply_form={@reply_form}
            reply_target={@reply_target}
            reply_target_state={@reply_target_state}
            reply_sending?={@reply_sending?}
            reply_sent={@reply_sent}
            open_url={@open_url}
            open_label={@open_label}
          />

          <.brief_panel
            todo={@todo}
            brief={@brief}
            brief_state={@brief_state}
            brief_progress={@brief_progress}
            timezone_info={@timezone_info}
          />
        </div>

        <aside class="space-y-4">
          <.panel body_class="px-4 py-4">
            <:header>
              <h2 class="text-sm/6 font-semibold text-zinc-950">Todo</h2>
            </:header>

            <div>
              <p class="text-xs/5 font-medium text-zinc-500">Project</p>
              <form id={"todo-project-form-#{@todo.id}"} phx-change="assign_todo_project" class="mt-1">
                <input type="hidden" name="assignment[todo_id]" value={@todo.id} />
                <.c_select id={"todo-project-#{@todo.id}"} name="assignment[project_id]">
                  <option
                    :for={{label, value} <- @project_options}
                    value={value}
                    selected={(@todo.project_id || "") == value}
                  >
                    <%= label %>
                  </option>
                </.c_select>
              </form>
            </div>

            <dl :if={@facts != []} class="mt-4 space-y-3 border-t border-zinc-950/10 pt-4">
              <div :for={fact <- @facts}>
                <dt class="text-xs/5 font-medium text-zinc-500"><%= fact.label %></dt>
                <dd class="text-sm/6 text-zinc-800"><%= fact.value %></dd>
              </div>
            </dl>

            <details :if={@can_edit_next_action} class="mt-4 border-t border-zinc-950/10 pt-4">
              <summary class="cursor-pointer list-none text-xs/5 font-medium text-zinc-500 hover:text-zinc-950">
                Edit next action
              </summary>
              <.form
                for={@next_action_form}
                id={"todo-next-action-form-#{@todo.id}"}
                phx-submit="save_todo_next_action"
                phx-value-id={@todo.id}
                class="mt-3"
              >
                <.c_textarea
                  id={"todo-next-action-#{@todo.id}"}
                  name={@next_action_form[:next_action].name}
                  value={@next_action_form[:next_action].value}
                  rows={3}
                  maxlength="1000"
                  required
                />
                <div class="mt-2 flex justify-end">
                  <.button type="submit" variant="outline" class="text-xs" phx-disable-with="Saving...">
                    Save next action
                  </.button>
                </div>
              </.form>
            </details>
          </.panel>
        </aside>
      </div>

    </div>
    """
  end

  attr :todo, Todo, required: true
  attr :brief, :any, default: nil
  attr :brief_state, :atom, required: true
  attr :brief_progress, :string, default: nil
  attr :timezone_info, :any, required: true

  defp brief_panel(assigns) do
    assigns =
      assigns
      |> assign(:loading?, assigns.brief_state in [:generating, :waiting])
      |> assign(
        :show_brief?,
        is_map(assigns.brief) and assigns.brief_state not in [:generating, :waiting]
      )
      |> assign(
        :can_regenerate?,
        assigns.todo.status in ~w(open snoozed) and
          assigns.brief_state not in [:generating, :waiting]
      )
      |> assign(:fallback_fields, brief_fallback_fields(assigns.todo))

    ~H"""
    <.panel id="todo-brief" body_class="px-5 py-5">
      <:header>
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h2 class="text-sm/6 font-semibold text-zinc-950">Brief</h2>
            <p
              :if={@loading? and @fallback_fields == []}
              class="flex items-center gap-2 text-sm/6 text-zinc-500"
            >
              <span class="inline-block size-2 animate-pulse rounded-full bg-zinc-400" aria-hidden="true"></span>
              <%= @brief_progress || "Reading the source" %>
            </p>
            <p :if={@show_brief? and brief_effort_label(@brief)} class="text-sm/6 text-zinc-500">
              <%= brief_effort_label(@brief) %>
            </p>
          </div>
          <.button
            :if={@can_regenerate?}
            type="button"
            variant="plain"
            class="text-xs text-zinc-600"
            phx-click="regenerate_brief"
          >
            Regenerate
          </.button>
        </div>
      </:header>

      <div :if={@loading? and @fallback_fields == []} class="space-y-3" aria-busy="true">
        <div class="h-3 w-2/3 animate-pulse rounded bg-zinc-100"></div>
        <div class="h-3 w-full animate-pulse rounded bg-zinc-100"></div>
        <div class="h-3 w-5/6 animate-pulse rounded bg-zinc-100"></div>
        <div class="h-3 w-1/2 animate-pulse rounded bg-zinc-100"></div>
      </div>

      <.alert :if={@brief_state == :failed} color="amber" class="mb-4">
        The brief could not be built right now. Try Regenerate, or ask Maraithon.
      </.alert>

      <div :if={@show_brief?} class="space-y-5">
        <section :if={@brief["why_it_matters"]}>
          <h3 class="text-xs/5 font-semibold uppercase tracking-wide text-zinc-500">Why this matters</h3>
          <p class="mt-1 text-sm/6 text-zinc-800"><%= @brief["why_it_matters"] %></p>
        </section>

        <section :if={@brief["situation"]}>
          <h3 class="text-xs/5 font-semibold uppercase tracking-wide text-zinc-500">The situation</h3>
          <p class="mt-1 whitespace-pre-line text-sm/6 text-zinc-800"><%= @brief["situation"] %></p>
        </section>

        <section :if={@brief["recommendation"] || brief_list(@brief, "steps") != []}>
          <h3 class="text-xs/5 font-semibold uppercase tracking-wide text-zinc-500">Do this</h3>
          <p :if={@brief["recommendation"]} class="mt-1 text-sm/6 font-medium text-zinc-950">
            <%= @brief["recommendation"] %>
          </p>
          <ol
            :if={brief_list(@brief, "steps") != []}
            class="mt-2 list-decimal space-y-1.5 pl-5 text-sm/6 text-zinc-800 marker:text-zinc-400"
          >
            <li :for={step <- brief_list(@brief, "steps")}><%= step %></li>
          </ol>
        </section>

        <section :if={brief_list(@brief, "open_questions") != []}>
          <h3 class="text-xs/5 font-semibold uppercase tracking-wide text-zinc-500">Your call</h3>
          <ul class="mt-1 list-disc space-y-1 pl-5 text-sm/6 text-zinc-800 marker:text-zinc-400">
            <li :for={question <- brief_list(@brief, "open_questions")}><%= question %></li>
          </ul>
        </section>

        <p :if={brief_generated_label(@brief, @timezone_info)} class="border-t border-zinc-950/10 pt-3 text-xs/5 text-zinc-400">
          <%= brief_generated_label(@brief, @timezone_info) %>
        </p>
      </div>

      <dl :if={not @show_brief? and @fallback_fields != []} class="divide-y divide-zinc-950/5">
        <div :for={field <- @fallback_fields} class="py-3 first:pt-0 last:pb-0">
          <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
          <dd class="mt-1 whitespace-pre-wrap break-words text-sm/6 text-zinc-800"><%= field.value %></dd>
        </div>
      </dl>
    </.panel>
    """
  end

  attr :todo, Todo, required: true
  attr :reply, :any, default: nil
  attr :source_history, :list, default: []
  attr :source_subject, :string, default: nil
  attr :timezone_info, :any, required: true
  attr :reply_form, :any, required: true
  attr :reply_target, :any, default: nil
  attr :reply_target_state, :atom, required: true
  attr :reply_sending?, :boolean, default: false
  attr :reply_sent, :any, default: nil
  attr :open_url, :string, default: nil
  attr :open_label, :string, default: nil

  defp reply_panel(assigns) do
    reply = if is_map(assigns.reply), do: assigns.reply, else: %{}

    assigns =
      assigns
      |> assign(:heading, source_panel_heading(reply, assigns.todo))
      |> assign(:reply_heading, reply_heading(reply, assigns.todo))
      |> assign(
        :subheading,
        source_panel_subheading(assigns.source_subject, reply, assigns.reply_target)
      )
      |> assign(:provider_label, reply_provider_label(reply))
      |> assign(:gmail?, reply["channel"] == "gmail" or assigns.todo.source == "gmail")
      |> assign(:send_label, BriefActions.send_label(reply["channel"]))

    ~H"""
    <.panel id="todo-reply" body_class="p-0">
      <:header>
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h2 class="text-sm/6 font-semibold text-zinc-950"><%= @heading %></h2>
            <p :if={@subheading} class="text-sm/6 text-zinc-500"><%= @subheading %></p>
          </div>
          <.badge :if={@reply_target_state == :ready} color="emerald">Ready to send</.badge>
          <.badge :if={@reply_target_state == :sent} color="blue">Sent</.badge>
        </div>
      </:header>

      <div :if={@source_history != []} id="todo-source-history" class="divide-y divide-zinc-950/5">
        <article :for={message <- @source_history} class="flex gap-3 px-5 py-4">
          <div class={[
            "mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
            if(message["from_user"], do: "bg-zinc-900 text-white", else: "bg-zinc-100 text-zinc-600")
          ]}>
            <%= source_message_initial(message) %>
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <p class="text-sm/6 font-semibold text-zinc-950"><%= source_message_speaker(message) %></p>
              <p :if={present?(message["at"])} class="text-xs/5 text-zinc-400">
                <%= format_source_message_at(message["at"], @timezone_info) %>
              </p>
            </div>
            <p class="mt-1 whitespace-pre-line break-words text-sm/6 text-zinc-700"><%= message["text"] %></p>
          </div>
        </article>
      </div>

      <div :if={@reply_sent} class="px-5 py-5">
        <.alert color="emerald"><%= reply_sent_copy(@reply_sent) %></.alert>
      </div>

      <.form
        :if={@reply != nil and is_nil(@reply_sent)}
        for={@reply_form}
        id="todo-reply-form"
        phx-change="update_reply"
        phx-submit="send_reply"
        class={["space-y-4 px-5 py-5", @source_history != [] && "border-t border-zinc-950/10"]}
      >
        <div>
          <h3 class="text-sm/6 font-semibold text-zinc-950"><%= @reply_heading %></h3>
          <p class="text-xs/5 text-zinc-500">Review the wording, then send without leaving this todo.</p>
        </div>
        <.field :if={@gmail?} label="Subject" for="todo-reply-subject">
          <.c_input
            id="todo-reply-subject"
            name={@reply_form[:subject].name}
            value={@reply_form[:subject].value}
            maxlength="255"
          />
        </.field>

        <.field label="Message" for="todo-reply-body">
          <.c_textarea
            id="todo-reply-body"
            name={@reply_form[:body].name}
            value={@reply_form[:body].value}
            rows={if(@gmail?, do: 10, else: 6)}
            maxlength="8000"
            required
          />
        </.field>

        <div class="flex flex-wrap items-center justify-end gap-2">
          <p
            :if={@reply_sending?}
            class="mr-auto flex items-center gap-2 text-xs/5 text-zinc-500"
          >
            <span class="inline-block size-2 animate-pulse rounded-full bg-zinc-400" aria-hidden="true"></span>
            Sending through <%= @provider_label %>
          </p>
          <p :if={@reply_target_state == :unavailable} class="mr-auto text-xs/5 text-zinc-500">
            Direct send is not available here. Copy it and send from <%= @provider_label %>.
          </p>
          <.button
            type="button"
            variant="outline"
            id="todo-reply-copy"
            phx-hook=".CopyReply"
            data-copy-target="todo-reply-body"
          >
            Copy
          </.button>
          <.button :if={@open_url} href={@open_url} target="_blank" rel="noopener" variant="outline">
            <%= @open_label || "Open source" %>
          </.button>
          <.button
            :if={@reply_target_state in [:ready, :sending, :failed]}
            type="submit"
            disabled={@reply_sending?}
            phx-disable-with="Sending..."
          >
            <%= @send_label %>
          </.button>
        </div>
      </.form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyReply">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.getElementById(this.el.dataset.copyTarget)
              if (!target) return
              const text = target.value || target.textContent || ""
              const done = () => {
                const original = this.el.textContent
                this.el.textContent = "Copied"
                setTimeout(() => { this.el.textContent = original }, 1500)
              }
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(done).catch(() => {})
              } else {
                target.select()
                document.execCommand("copy")
                done()
              }
            })
          }
        }
      </script>
    </.panel>
    """
  end

  defp brief_reply(%{"reply" => %{"body" => body} = reply}) when is_binary(body) and body != "",
    do: reply

  defp brief_reply(_brief), do: nil

  defp source_history(%{"source_history" => history}, _source_action)
       when is_list(history) and history != [],
       do: Enum.filter(history, &is_map/1)

  defp source_history(_brief, %{"conversation" => history}) when is_list(history),
    do: Enum.filter(history, &is_map/1)

  defp source_history(_brief, _source_action), do: []

  defp source_subject(%{"source_subject" => subject}, _source_action)
       when is_binary(subject) and subject != "",
       do: subject

  defp source_subject(_brief, %{"subject" => subject}) when is_binary(subject), do: subject
  defp source_subject(_brief, _source_action), do: nil

  defp source_panel_heading(%{"channel" => "gmail"}, _todo), do: "Email thread"
  defp source_panel_heading(%{"channel" => "slack"}, _todo), do: "Slack thread"
  defp source_panel_heading(_reply, %Todo{source: "gmail"}), do: "Email thread"
  defp source_panel_heading(_reply, _todo), do: "Conversation"

  defp source_panel_subheading(subject, reply, target) do
    [subject, reply_subheading(reply, target)]
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp source_message_speaker(%{"from_user" => true}), do: "You"

  defp source_message_speaker(message) when is_map(message) do
    [Map.get(message, "speaker"), Map.get(message, "from")]
    |> Enum.find(&present?/1)
    |> reply_display_name()
    |> case do
      nil -> "Them"
      speaker -> speaker
    end
  end

  defp source_message_speaker(_message), do: "Them"

  defp source_message_initial(message) do
    message
    |> source_message_speaker()
    |> String.first()
    |> to_string()
    |> String.upcase()
  end

  defp format_source_message_at(value, timezone_info) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> format_datetime(datetime, nil, timezone_info)
      _other -> value
    end
  end

  defp format_source_message_at(value, _timezone_info), do: value

  defp brief_list(brief, key) when is_map(brief) do
    case Map.get(brief, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp brief_list(_brief, _key), do: []

  defp brief_effort_label(%{"effort" => "under_2_min"}), do: "Under 2 minutes"
  defp brief_effort_label(%{"effort" => "under_15_min"}), do: "Under 15 minutes"
  defp brief_effort_label(%{"effort" => "longer"}), do: "Needs a focused block"
  defp brief_effort_label(_brief), do: nil

  defp brief_generated_label(%{"generated_at" => iso} = brief, timezone_info)
       when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} ->
        model = Map.get(brief, "model")
        base = "Generated #{format_datetime(at, nil, timezone_info)}"
        if is_binary(model) and model != "", do: base <> " with " <> model, else: base

      _ ->
        nil
    end
  end

  defp brief_generated_label(_brief, _timezone_info), do: nil

  defp brief_fallback_fields(%Todo{} = todo) do
    [
      %{label: "Next action", value: todo.next_action},
      %{label: "Action plan", value: todo.action_plan}
    ]
    |> Enum.reject(&blank?(&1.value))
  end

  defp reply_heading(reply, %Todo{} = todo) do
    name =
      [Map.get(reply, "to"), todo.counterparty_label]
      |> Enum.find(&present?/1)
      |> reply_display_name()

    if name, do: "Reply to #{name}", else: "Reply"
  end

  defp reply_display_name(nil), do: nil

  defp reply_display_name(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp reply_subheading(reply, target) do
    provider = reply_provider_label(reply)

    destination =
      case target do
        %{destination: destination} when is_binary(destination) -> destination
        _ -> nil
      end

    [provider, destination]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp reply_provider_label(%{"channel" => "gmail"}), do: "Email"
  defp reply_provider_label(%{"channel" => "slack"}), do: "Slack"
  defp reply_provider_label(%{"channel" => "imessage"}), do: "Messages"
  defp reply_provider_label(%{"channel" => "whatsapp"}), do: "WhatsApp"
  defp reply_provider_label(_reply), do: "the source"

  defp reply_sent_copy(%{target: target, completed?: completed?}) do
    sent_flash(target, completed?)
  end

  defp reply_sent_copy(_sent), do: "Sent."

  defp todo_fact_rows(%Todo{} = todo, timezone_info) do
    [
      %{label: "Source", value: todo_source_label(todo.source)},
      %{label: "Account", value: todo_source_account_value(todo)},
      %{label: "Suggested project", value: todo_project_suggestion(todo)},
      %{label: "Due", value: format_datetime(todo.due_at, nil, timezone_info)},
      %{label: "Snoozed until", value: format_datetime(todo.snoozed_until, nil, timezone_info)},
      %{label: "Updated", value: format_datetime(todo.updated_at, nil, timezone_info)}
    ]
    |> Enum.reject(&blank?(&1.value))
  end

  defp todo_next_action_editable?(%Todo{status: status}), do: status in ~w(open snoozed)

  defp apply_bulk_todo_action(socket, action) do
    todo_ids = selected_visible_todo_ids(socket)

    if todo_ids == [] do
      put_flash(socket, :error, "Select at least one work item first.")
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
        |> refresh_todos()

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

  defp run_todo_action(:see_less, user_id, todo_id, _note) do
    case Todos.see_less_like(
           user_id,
           todo_id,
           Keyword.put(todo_actor_opts(user_id), :source, "todos_page_bulk")
         ) do
      {:ok, %{todo: todo}} -> {:ok, todo}
      {:error, reason} -> {:error, reason}
    end
  end

  defp todo_action_opts(user_id, note), do: Keyword.put(todo_actor_opts(user_id), :note, note)

  defp todo_actor_opts(user_id),
    do: [actor_type: "user", actor_id: user_id, actor_label: "User"]

  defp bulk_todo_note(:complete), do: "Completed from Work bulk action."
  defp bulk_todo_note(:dismiss), do: "Dismissed from Work bulk action."
  defp bulk_todo_note(:see_less), do: "Dismissed from Work bulk see less action."

  defp bulk_todo_flash_kind(0, [_ | _]), do: :error
  defp bulk_todo_flash_kind(_updated_count, _errors), do: :info

  defp bulk_todo_flash(action, updated_count, errors) do
    base =
      case action do
        :complete -> "Marked #{pluralize_work_item(updated_count)} done"
        :dismiss -> "Dismissed #{pluralize_work_item(updated_count)}"
        :see_less -> "Similar work will show up less often"
      end

    case length(errors) do
      0 -> base
      error_count -> "#{base}; #{error_count} could not be updated"
    end
  end

  defp pluralize_work_item(1), do: "1 work item"
  defp pluralize_work_item(count), do: "#{count} work items"

  defp normalize_new_todo_params(params) when is_map(params) do
    %{
      "title" => normalize_text(Map.get(params, "title")) || "",
      "next_action" => normalize_text(Map.get(params, "next_action")) || "",
      "due_at" => normalize_text(Map.get(params, "due_at")) || "",
      "priority" => normalize_new_todo_priority(Map.get(params, "priority")),
      "project_id" => normalize_text(Map.get(params, "project_id")) || "",
      "notes" => normalize_text(Map.get(params, "notes")) || ""
    }
  end

  defp normalize_new_todo_params(_params), do: @default_new_todo_params

  defp build_manual_todo_attrs(user_id, params, timezone_info) do
    title = normalize_text(params["title"])
    next_action = normalize_text(params["next_action"])
    notes = normalize_text(params["notes"])
    due_at_result = parse_new_todo_due_at(params["due_at"], timezone_info)

    errors =
      %{}
      |> maybe_put_text_error("title", title, "Enter a work item with at least 4 characters.")
      |> maybe_put_text_error(
        "next_action",
        next_action,
        "Enter a next action with at least 4 characters."
      )
      |> maybe_put_due_error(due_at_result)

    if map_size(errors) == 0 do
      {:ok,
       %{
         "source" => "manual",
         "kind" => "general",
         "title" => title,
         "summary" => manual_todo_summary(notes, next_action),
         "next_action" => next_action,
         "due_at" => elem(due_at_result, 1),
         "notes" => notes,
         "priority" => String.to_integer(params["priority"]),
         "project_id" => normalize_text(params["project_id"]),
         "dedupe_key" => "manual:web:#{Ecto.UUID.generate()}",
         "metadata" => %{
           "created_from" => "todos_web",
           "created_by_user_id" => user_id
         }
       }}
    else
      {:error, errors}
    end
  end

  defp manual_todo_summary(notes, _next_action) when is_binary(notes), do: notes
  defp manual_todo_summary(_notes, next_action), do: next_action

  defp maybe_put_text_error(errors, key, value, message) do
    if is_binary(value) and String.length(value) >= 4 do
      errors
    else
      Map.put(errors, key, message)
    end
  end

  defp maybe_put_due_error(errors, {:error, _reason}) do
    Map.put(errors, "due_at", "Enter a valid due date and time.")
  end

  defp maybe_put_due_error(errors, {:ok, _due_at}), do: errors

  defp new_todo_error(errors, key) when is_map(errors), do: Map.get(errors, key)
  defp new_todo_error(_errors, _key), do: nil

  defp normalize_new_todo_priority(value) when value in ~w(50 75 90), do: value
  defp normalize_new_todo_priority(_value), do: "50"

  defp parse_new_todo_due_at(nil, _timezone_info), do: {:ok, nil}
  defp parse_new_todo_due_at("", _timezone_info), do: {:ok, nil}

  defp parse_new_todo_due_at(value, timezone_info) when is_binary(value) do
    value
    |> normalize_datetime_local_value()
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive_datetime} -> {:ok, local_naive_to_utc(naive_datetime, timezone_info)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_new_todo_due_at(_value, _timezone_info), do: {:error, :invalid_due_at}

  defp normalize_datetime_local_value(value) do
    value = String.trim(value)

    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, value) do
      value <> ":00"
    else
      value
    end
  end

  defp local_naive_to_utc(%NaiveDateTime{} = naive_datetime, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)

    local_datetime =
      DateTime.new!(
        NaiveDateTime.to_date(naive_datetime),
        NaiveDateTime.to_time(naive_datetime),
        "Etc/UTC"
      )

    offset =
      Timezones.offset_for_local(timezone_info.name, local_datetime, timezone_info.offset_hours)

    DateTime.add(local_datetime, -offset, :hour)
  end

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

  defp resolved_active_todo_id(todos, current_active_todo_id, selected_todo)
       when is_list(todos) do
    visible_ids = Enum.map(todos, & &1.id)
    selected_todo_id = if selected_todo, do: selected_todo.id

    cond do
      selected_todo_id in visible_ids -> selected_todo_id
      current_active_todo_id in visible_ids -> current_active_todo_id
      true -> todos |> List.first() |> todo_id()
    end
  end

  defp todo_id(%Todo{id: todo_id}), do: todo_id
  defp todo_id(_todo), do: nil

  defp index_active_todo(%{assigns: %{selected_todo: nil}} = socket) do
    Enum.find(socket.assigns.todos, &(&1.id == socket.assigns.active_todo_id))
  end

  defp index_active_todo(_socket), do: nil

  defp shortcut_target_todo(socket, todo_id) when is_binary(todo_id) do
    case socket.assigns.selected_todo do
      %Todo{id: ^todo_id} = todo -> todo
      _selected_todo -> Enum.find(socket.assigns.todos, &(&1.id == todo_id))
    end
  end

  defp shortcut_target_todo(%{assigns: %{selected_todo: %Todo{} = todo}}, _todo_id), do: todo
  defp shortcut_target_todo(socket, _todo_id), do: index_active_todo(socket)

  defp open_active_todo(socket, todo_id) do
    case shortcut_target_todo(socket, todo_id) do
      %Todo{id: todo_id} ->
        socket
        |> assign(:active_todo_id, todo_id)
        |> push_patch(to: todo_detail_path(socket.assigns.filters, todo_id))

      nil ->
        socket
    end
  end

  defp resolve_todo(socket, todo_id, :complete) do
    user_id = current_user_id(socket)
    detail? = socket.assigns.selected_todo_id == todo_id
    preferred_next_todo_id = preferred_next_todo_id(navigation_todo_ids(socket), todo_id)

    case Todos.mark_done(user_id, todo_id, todo_action_opts(user_id, "Completed from Work page.")) do
      {:ok, _todo} ->
        {:ok,
         socket
         |> prepare_active_todo_after_resolution(todo_id, preferred_next_todo_id)
         |> refresh_todos()
         |> put_flash(:info, "Work item done.")
         |> maybe_advance_after_resolution(detail?, todo_id, preferred_next_todo_id)}

      {:error, reason} ->
        {:error,
         socket
         |> refresh_todos()
         |> put_flash(:error, TodoActionCopy.error(:complete, reason))}
    end
  end

  defp resolve_todo(socket, todo_id, :dismiss) do
    user_id = current_user_id(socket)
    detail? = socket.assigns.selected_todo_id == todo_id
    preferred_next_todo_id = preferred_next_todo_id(navigation_todo_ids(socket), todo_id)

    case Todos.dismiss(user_id, todo_id, todo_action_opts(user_id, "Dismissed from Work page.")) do
      {:ok, _todo} ->
        {:ok,
         socket
         |> prepare_active_todo_after_resolution(todo_id, preferred_next_todo_id)
         |> refresh_todos()
         |> put_flash(:info, "Work item dismissed.")
         |> maybe_advance_after_resolution(detail?, todo_id, preferred_next_todo_id)}

      {:error, reason} ->
        {:error,
         socket
         |> refresh_todos()
         |> put_flash(:error, TodoActionCopy.error(:dismiss, reason))}
    end
  end

  defp navigate_todo_shortcut(
         %{assigns: %{selected_todo: %Todo{id: todo_id}}} = socket,
         direction
       ) do
    {previous_todo, next_todo} =
      todo_neighbor_targets(navigation_todo_ids(socket), todo_id)

    target_todo = if direction == :next, do: next_todo, else: previous_todo

    case target_todo do
      %{id: target_todo_id} = target ->
        socket
        |> assign(:active_todo_id, target_todo_id)
        |> push_patch(to: todo_navigation_path(socket.assigns.filters, target))

      nil ->
        socket
    end
  end

  defp navigate_todo_shortcut(socket, direction) do
    {previous_todo, next_todo} =
      todo_neighbors(socket.assigns.todos, socket.assigns.active_todo_id)

    target_todo = if direction == :next, do: next_todo, else: previous_todo

    case target_todo do
      %Todo{id: target_todo_id} -> assign(socket, :active_todo_id, target_todo_id)
      nil -> socket
    end
  end

  defp todo_neighbors(todos, todo_id) when is_list(todos) and is_binary(todo_id) do
    case Enum.find_index(todos, &(&1.id == todo_id)) do
      nil ->
        {nil, nil}

      index ->
        previous_todo = if index > 0, do: Enum.at(todos, index - 1)
        {previous_todo, Enum.at(todos, index + 1)}
    end
  end

  defp todo_neighbors(_todos, _todo_id), do: {nil, nil}

  defp todo_neighbor_targets(todo_ids, todo_id)
       when is_list(todo_ids) and is_binary(todo_id) do
    case Enum.find_index(todo_ids, &(&1 == todo_id)) do
      nil ->
        {nil, nil}

      index ->
        {todo_navigation_target(todo_ids, index - 1), todo_navigation_target(todo_ids, index + 1)}
    end
  end

  defp todo_neighbor_targets(_todo_ids, _todo_id), do: {nil, nil}

  defp todo_navigation_target(todo_ids, index) when index >= 0 do
    case Enum.at(todo_ids, index) do
      todo_id when is_binary(todo_id) -> %{id: todo_id, page: div(index, @page_limit) + 1}
      _missing -> nil
    end
  end

  defp todo_navigation_target(_todo_ids, _index), do: nil

  defp todo_page_for_id(todo_ids, todo_id) when is_list(todo_ids) and is_binary(todo_id) do
    case Enum.find_index(todo_ids, &(&1 == todo_id)) do
      nil -> nil
      index -> div(index, @page_limit) + 1
    end
  end

  defp todo_page_for_id(_todo_ids, _todo_id), do: nil

  defp todo_navigation_path(filters, %{id: todo_id, page: page}) do
    filters
    |> Map.put("page", Integer.to_string(page))
    |> todo_detail_path(todo_id)
  end

  defp todo_navigation_path(_filters, _target), do: nil

  defp navigation_todo_ids(%{
         assigns: %{selected_todo: %Todo{}, todo_navigation_ids: todo_ids}
       }),
       do: todo_ids

  defp navigation_todo_ids(socket), do: Enum.map(socket.assigns.todos, & &1.id)

  defp preferred_next_todo_id(todo_ids, todo_id) do
    case todo_neighbor_targets(todo_ids, todo_id) do
      {_previous_todo, %{id: next_todo_id}} -> next_todo_id
      {%{id: previous_todo_id}, nil} -> previous_todo_id
      _neighbors -> nil
    end
  end

  defp prepare_active_todo_after_resolution(socket, resolved_todo_id, preferred_todo_id) do
    if resolved_todo_id in [socket.assigns.active_todo_id, socket.assigns.selected_todo_id] do
      assign(socket, :active_todo_id, preferred_todo_id)
    else
      socket
    end
  end

  defp maybe_advance_after_resolution(socket, false, _resolved_todo_id, _preferred_todo_id),
    do: socket

  defp maybe_advance_after_resolution(socket, true, resolved_todo_id, preferred_todo_id) do
    current_todo_ids = navigation_todo_ids(socket)
    remaining_todo_ids = Enum.reject(current_todo_ids, &(&1 == resolved_todo_id))

    next_todo_id =
      if preferred_todo_id in remaining_todo_ids,
        do: preferred_todo_id,
        else: List.first(remaining_todo_ids)

    case next_todo_id do
      nil ->
        push_patch(socket, to: todos_path(socket.assigns.filters))

      todo_id ->
        target = %{id: todo_id, page: todo_page_for_id(current_todo_ids, todo_id) || 1}
        push_patch(socket, to: todo_navigation_path(socket.assigns.filters, target))
    end
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

  defp selected_todo_for_user(user_id, todo_id)
       when is_binary(user_id) and is_binary(todo_id) do
    case Todos.get_for_user(user_id, todo_id) do
      %Todo{} = todo -> todo
      _other -> nil
    end
  end

  defp selected_todo_for_user(_user_id, _todo_id), do: nil

  defp todo_query_opts(filters, timezone_info) do
    [
      query: normalize_text(filters["q"]),
      statuses: status_filter(filters["status"]),
      attention_mode: attention_filter(filters["attention"]),
      decision_only?: decision_filter?(filters["attention"]),
      source: source_filter(filters["source"]),
      project_id: project_filter(filters["project"]),
      agent_actionability: agent_filter(filters["agent"]),
      sort_by: filters["sort"],
      sort_dir: filters["dir"]
    ]
    |> Keyword.merge(due_filter(filters["due"], timezone_info))
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      _entry -> false
    end)
  end

  defp status_filter("active"), do: ["open", "snoozed"]
  defp status_filter("all"), do: nil
  defp status_filter(status) when status in ~w(open snoozed done dismissed), do: [status]
  defp status_filter(_status), do: ["open", "snoozed"]

  defp attention_filter("all"), do: nil
  defp attention_filter("decision"), do: nil
  defp attention_filter(attention) when attention in ~w(act_now monitor), do: attention
  defp attention_filter(_attention), do: nil

  defp decision_filter?("decision"), do: true
  defp decision_filter?(_attention), do: false

  defp source_filter("all"), do: nil
  defp source_filter(source) when is_binary(source), do: source
  defp source_filter(_source), do: nil

  defp project_filter(value) when value in [nil, "", "all"], do: nil
  defp project_filter("inbox"), do: "inbox"

  defp project_filter(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp project_filter(_value), do: nil

  defp agent_filter("can_help"), do: "can_help"
  defp agent_filter("needs_you"), do: "needs_you"
  defp agent_filter(_value), do: nil

  defp due_filter("overdue", _timezone_info), do: [due_before: DateTime.utc_now()]

  defp due_filter("today", timezone_info) do
    today = local_today(timezone_info)

    [
      due_after: local_boundary_to_utc(today, ~T[00:00:00], timezone_info),
      due_before: local_boundary_to_utc(today, ~T[23:59:59], timezone_info)
    ]
  end

  defp due_filter("week", _timezone_info) do
    now = DateTime.utc_now()
    week_out = now |> DateTime.add(7, :day)

    [due_after: now, due_before: week_out]
  end

  defp due_filter("no_due", _timezone_info), do: [due_nil?: true]
  defp due_filter(_due, _timezone_info), do: []

  defp normalize_filters(params) when is_map(params) do
    %{
      "q" => normalize_text(Map.get(params, "q")) || "",
      "status" =>
        normalize_choice(
          Map.get(params, "status"),
          ~w(active open snoozed done dismissed all),
          "active"
        ),
      "attention" =>
        normalize_choice(Map.get(params, "attention"), ~w(all act_now decision monitor), "all"),
      "due" => normalize_choice(Map.get(params, "due"), ~w(all overdue today week no_due), "all"),
      "source" => normalize_source(Map.get(params, "source")),
      "project" => normalize_project_filter(Map.get(params, "project")),
      "agent" => normalize_choice(Map.get(params, "agent"), ~w(all can_help needs_you), "all"),
      "sort" =>
        normalize_choice(
          Map.get(params, "sort"),
          ~w(rank title source status attention priority due updated),
          "rank"
        ),
      "dir" => normalize_choice(Map.get(params, "dir"), ~w(asc desc), "desc"),
      "page" => params |> Map.get("page") |> normalize_page() |> Integer.to_string()
    }
  end

  defp normalize_filters(_params), do: @default_filters

  defp normalize_choice(value, allowed, fallback) when is_binary(value) do
    value = String.trim(value)
    if value in allowed, do: value, else: fallback
  end

  defp normalize_choice(_value, _allowed, fallback), do: fallback

  defp normalize_page(value) when is_integer(value) and value > 0, do: value

  defp normalize_page(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  defp normalize_page(_value), do: 1

  defp normalize_todo_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, todo_id} -> todo_id
      :error -> nil
    end
  end

  defp normalize_todo_id(_value), do: nil

  defp filter_page(filters) when is_map(filters), do: normalize_page(Map.get(filters, "page"))
  defp filter_page(_filters), do: 1

  defp normalize_project_filter(value) when value in [nil, ""], do: "all"
  defp normalize_project_filter(value) when value in ["all", "inbox"], do: value

  defp normalize_project_filter(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> uuid
      :error -> "all"
    end
  end

  defp normalize_project_filter(_value), do: "all"

  defp normalize_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "all"
      source -> source
    end
  end

  defp normalize_source(_value), do: "all"

  defp todos_path(filters, extra_params \\ %{}) do
    query =
      filters
      |> Map.merge(extra_params)
      |> Enum.reject(fn {key, value} ->
        blank?(value) or Map.get(@default_filters, key) == value
      end)
      |> Enum.into(%{})

    if map_size(query) == 0, do: ~p"/todos", else: ~p"/todos?#{query}"
  end

  defp todo_detail_path(filters, todo_id) do
    query =
      filters
      |> Enum.reject(fn {key, value} ->
        blank?(value) or Map.get(@default_filters, key) == value
      end)
      |> Enum.into(%{})

    if map_size(query) == 0,
      do: ~p"/todos/#{todo_id}",
      else: ~p"/todos/#{todo_id}?#{query}"
  end

  defp current_path_from_uri(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/todos"
      "" -> "/todos"
      path -> path
    end
  rescue
    _ -> "/todos"
  end

  defp next_sort_dir(%{"sort" => field, "dir" => "asc"}, field), do: "desc"
  defp next_sort_dir(_filters, _field), do: "asc"

  defp sort_indicator(%{"sort" => field, "dir" => "asc"}, field), do: "^"
  defp sort_indicator(%{"sort" => field, "dir" => "desc"}, field), do: "v"
  defp sort_indicator(_filters, _field), do: ""

  defp todo_row_class(%Todo{} = todo, selected_todo_ids) do
    [
      "group relative cursor-pointer transition-all duration-100 hover:bg-zinc-950/[0.025] data-[active=true]:bg-blue-50 data-[active=true]:outline data-[active=true]:outline-2 data-[active=true]:-outline-offset-2 data-[active=true]:outline-blue-500/40",
      MapSet.member?(selected_todo_ids, todo.id) && "bg-blue-50/60"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp todo_project_suggestion(%Todo{metadata: metadata}) when is_map(metadata) do
    case fetch_map_value(metadata, "project_suggestion") do
      suggestion when is_map(suggestion) ->
        name = fetch_map_value(suggestion, "name")
        evidence = fetch_map_value(suggestion, "evidence")

        [name, evidence]
        |> Enum.filter(&present?/1)
        |> Enum.join(" — ")
        |> normalize_text()

      _other ->
        nil
    end
  end

  defp todo_project_suggestion(_todo), do: nil

  defp todo_source_account_value(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    metadata_account =
      todo.source_account_label ||
        fetch_map_value(metadata, "account") ||
        fetch_map_value(metadata, "account_email") ||
        fetch_map_value(metadata, "mailbox") ||
        fetch_map_value(metadata, "workspace_name") ||
        fetch_map_value(metadata, "google_account_email")

    normalize_text(metadata_account)
  end

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

  defp result_count_label(todos, total_count, page) do
    shown = length(todos)
    first = (page - 1) * @page_limit + 1
    last = first + shown - 1

    cond do
      total_count > shown -> "Showing #{first}–#{last} of #{total_count} matching work items."
      total_count == 1 -> "1 work item shown."
      true -> "#{total_count} work items shown."
    end
  end

  defp active_filter_label(filters) do
    [
      option_label(@status_options, filters["status"]),
      option_label(@attention_options, filters["attention"]),
      option_label(@due_options, filters["due"]),
      option_label(@source_options, filters["source"]),
      project_filter_label(filters["project"]),
      option_label(@agent_options, filters["agent"])
    ]
    |> Enum.reject(&(&1 in [nil, "Any attention", "Any due date", "All sources", "Any helper"]))
    |> case do
      [] -> "Default view"
      labels -> Enum.join(labels, " / ")
    end
  end

  defp project_filter_label("all"), do: nil
  defp project_filter_label("inbox"), do: "Inbox"
  defp project_filter_label(value) when is_binary(value), do: "Project"
  defp project_filter_label(_value), do: nil

  defp option_label(options, value) do
    Enum.find_value(options, fn
      {label, ^value} -> label
      _option -> nil
    end)
  end

  defp empty_message(%{"q" => query} = filters) do
    source_label = source_filter_label(filters)

    cond do
      present?(query) ->
        "No work matches that search."

      filters["attention"] == "decision" ->
        "No decisions are waiting in this filter."

      filters["due"] == "overdue" ->
        "No past-due work in this filter."

      filters["due"] == "today" ->
        "No work due today in this filter."

      filters["due"] == "week" ->
        "No work due in the next 7 days in this filter."

      filters["due"] == "no_due" ->
        "No unscheduled work in this filter."

      filters["status"] == "done" ->
        "No completed work in this filter."

      filters["status"] == "dismissed" ->
        "No dismissed work in this filter."

      filters["status"] == "snoozed" ->
        "No snoozed work in this filter."

      filters["status"] == "open" ->
        "No open work in this filter."

      filters["attention"] == "monitor" ->
        "No watched work in this filter."

      filters["attention"] == "act_now" ->
        "No action-needed work in this filter."

      source_label ->
        "No work from #{source_label} in this filter."

      default_filter_view?(filters) ->
        "Your open work list is clear. Add a follow-up manually, or Maraithon will surface commitments when the next move is clear."

      true ->
        "No work in this filter."
    end
  end

  defp source_filter_label(%{"source" => source}) when source not in [nil, "", "all"] do
    option_label(@source_options, source) || todo_source_label(source)
  end

  defp source_filter_label(_filters), do: nil

  defp default_filter_view?(filters) do
    Enum.all?(@empty_state_filter_keys, fn key ->
      Map.get(filters, key, Map.fetch!(@default_filters, key)) ==
        Map.fetch!(@default_filters, key)
    end)
  end

  defp status_color("open"), do: "emerald"
  defp status_color("snoozed"), do: "amber"
  defp status_color("done"), do: "blue"
  defp status_color("dismissed"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp attention_color("monitor"), do: "cyan"
  defp attention_color(_attention), do: "emerald"

  defp priority_color(priority) when is_integer(priority) and priority >= 90, do: "red"
  defp priority_color(priority) when is_integer(priority) and priority >= 75, do: "amber"
  defp priority_color(priority) when is_integer(priority) and priority >= 50, do: "blue"
  defp priority_color(_priority), do: "zinc"

  defp priority_label(priority) when is_integer(priority) and priority >= 90, do: "Critical"
  defp priority_label(priority) when is_integer(priority) and priority >= 75, do: "High"
  defp priority_label(priority) when is_integer(priority) and priority >= 50, do: "Normal"
  defp priority_label(_priority), do: "Low"

  defp todo_project_name(%Todo{project_id: nil}, _projects), do: "Inbox"

  defp todo_project_name(%Todo{project_id: project_id}, projects) do
    case Enum.find(projects, &(&1.id == project_id)) do
      nil -> "Project unavailable"
      project -> project.name
    end
  end

  defp agent_actionability_label(%Todo{agent_action_label: label})
       when is_binary(label) and label != "",
       do: label

  defp agent_actionability_label(%Todo{agent_actionability: "can_prepare"}),
    do: "Maraithon can prepare"

  defp agent_actionability_label(%Todo{agent_actionability: "can_execute"}),
    do: "Maraithon can execute"

  defp agent_actionability_label(_todo), do: "Needs you"

  defp agent_actionability_color("can_prepare"), do: "blue"
  defp agent_actionability_color("can_execute"), do: "emerald"
  defp agent_actionability_color(_value), do: "zinc"

  defp todo_status_label("open"), do: "Open"
  defp todo_status_label("snoozed"), do: "Snoozed"
  defp todo_status_label("done"), do: "Done"
  defp todo_status_label("dismissed"), do: "Dismissed"
  defp todo_status_label(value), do: label(value)

  defp attention_mode_label("monitor"), do: "Watching"
  defp attention_mode_label(_attention), do: "Needs action"

  defp todo_decision_signal?(%Todo{} = todo), do: DecisionSignals.needs_decision?(todo)
  defp todo_decision_signal?(_todo), do: false

  defp todo_next_action_label(%Todo{} = todo) do
    if todo_decision_signal?(todo), do: "Recommended", else: "Next"
  end

  defp todo_source_label("gmail"), do: "Gmail"
  defp todo_source_label("google_calendar"), do: "Google Calendar"

  defp todo_source_label(source) when is_binary(source) and source != "",
    do: SourceLabels.label(source)

  defp todo_source_label(_source), do: "Maraithon"

  defp format_datetime(nil, fallback, _timezone_info), do: fallback

  defp format_datetime(%DateTime{} = datetime, _fallback, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    offset = Timezones.offset_at(timezone_info.name, datetime, timezone_info.offset_hours)
    label = Timezones.label(timezone_info.name, offset)

    datetime
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp format_datetime(%NaiveDateTime{} = datetime, _fallback, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    label = Timezones.label(timezone_info.name, timezone_info.offset_hours)
    Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp format_datetime(value, _fallback, _timezone_info), do: to_string(value)

  defp user_timezone_info(user_id) when is_binary(user_id) do
    case BriefingSchedules.summarize_for_prompt(user_id) do
      %{timezone_name: timezone_name, timezone_offset_hours: offset_hours} ->
        normalize_timezone_info(%{name: timezone_name, offset_hours: offset_hours})

      _other ->
        default_timezone_info()
    end
  rescue
    _exception -> default_timezone_info()
  end

  defp user_timezone_info(_user_id), do: default_timezone_info()

  defp normalize_timezone_info(%{name: name, offset_hours: offset_hours}) do
    %{name: name, offset_hours: Timezones.normalize_offset(offset_hours)}
  end

  defp normalize_timezone_info(_timezone_info), do: default_timezone_info()

  defp default_timezone_info, do: %{name: nil, offset_hours: -5}

  defp local_today(timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    now = DateTime.utc_now()
    offset = Timezones.offset_at(timezone_info.name, now, timezone_info.offset_hours)

    now
    |> DateTime.add(offset, :hour)
    |> DateTime.to_date()
  end

  defp local_boundary_to_utc(%Date{} = date, %Time{} = time, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    local_boundary = DateTime.new!(date, time, "Etc/UTC")

    offset =
      Timezones.offset_for_local(timezone_info.name, local_boundary, timezone_info.offset_hours)

    DateTime.add(local_boundary, -offset, :hour)
  end

  defp label(value) when is_atom(value), do: value |> Atom.to_string() |> label()

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> "Not set"
      text -> String.capitalize(text)
    end
  end

  defp label(value), do: to_string(value)

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp blank?(value), do: not present?(value)
end
