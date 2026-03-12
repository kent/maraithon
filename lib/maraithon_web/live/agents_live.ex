defmodule MaraithonWeb.AgentsLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Admin
  alias Maraithon.AgentBuilder
  alias Maraithon.Agents
  alias Maraithon.Runtime

  @refresh_interval 5_000
  @event_limit 50
  @status_options ~w(all running degraded stopped)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Agents",
        current_path: "/agents",
        status_options: @status_options,
        filters: default_filters(),
        all_agents: [],
        agents: [],
        selected_agent_id: nil,
        selected_agent: nil,
        selected_panel: nil,
        events: [],
        inspection: empty_inspection(),
        agent_spend: empty_spend(),
        inspection_errors: [],
        launch: default_launch_params(),
        launch_error: nil,
        route_state: nil
      )

    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = %{
      status: normalize_status(Map.get(params, "status")),
      q: normalize_query(Map.get(params, "q"))
    }

    requested_id = normalize_id(Map.get(params, "id"))
    requested_panel = normalize_panel(Map.get(params, "panel"))
    raw_panel = Map.get(params, "panel")

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> refresh_registry()

    case apply_selection(socket, requested_id, requested_panel, raw_panel) do
      {:ok, socket} ->
        route_state = %{
          id: socket.assigns.selected_agent_id,
          panel: socket.assigns.selected_panel,
          status: filters.status,
          q: filters.q
        }

        {:noreply, maybe_emit_route_telemetry(socket, route_state)}

      {:sanitize, socket, to, flash} ->
        {:noreply, socket |> maybe_put_flash(flash) |> push_patch(to: to)}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = refresh_registry(socket)

    socket =
      case refresh_selected_workspace(socket) do
        {:ok, socket} -> socket
        {:sanitize, socket, to, flash} -> socket |> maybe_put_flash(flash) |> push_patch(to: to)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    next_filters = %{
      status: normalize_status(Map.get(filters, "status")),
      q: normalize_query(Map.get(filters, "q"))
    }

    {:noreply, push_patch(socket, to: agents_path_for_socket(socket, next_filters))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: agents_path_for_socket(socket, default_filters()))}
  end

  def handle_event("start_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      case Runtime.start_existing_agent(id) do
        {:ok, _agent} ->
          emit_action_telemetry("start", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Agent started")}

        {:error, :already_running} ->
          emit_action_telemetry("start", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Agent is already running")}

        {:error, :not_found} ->
          emit_action_telemetry("start", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          emit_action_telemetry("start", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
      end
    else
      emit_action_telemetry("start", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("stop_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      case Runtime.stop_agent(id, "stopped_from_agents_tab") do
        {:ok, _result} ->
          emit_action_telemetry("stop", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Agent stopped")}

        {:error, :not_found} ->
          emit_action_telemetry("stop", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          emit_action_telemetry("stop", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, "Failed to stop agent: #{inspect(reason)}")}
      end
    else
      emit_action_telemetry("stop", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("delete_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      case Runtime.delete_agent(id) do
        :ok ->
          emit_action_telemetry("delete", surface, id, :ok)

          socket =
            socket
            |> refresh_registry()
            |> assign(launch_error: nil)
            |> put_flash(:info, "Agent deleted")

          {:noreply, clear_missing_selection(socket, id)}

        {:error, :not_found} ->
          emit_action_telemetry("delete", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          emit_action_telemetry("delete", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, "Failed to delete agent: #{inspect(reason)}")}
      end
    else
      emit_action_telemetry("delete", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("save_agent", %{"launch" => params}, socket) do
    launch = normalize_launch_params(params)
    id = socket.assigns.selected_agent_id

    with true <- is_binary(id),
         true <- agent_owned_by_current_user?(socket, id),
         {:ok, start_params} <- build_agent_start_params(launch, current_user_id(socket)),
         {:ok, agent} <- Runtime.update_agent(id, start_params) do
      emit_action_telemetry("update", :workspace, agent.id, :ok)

      {:noreply,
       socket
       |> assign(launch: default_launch_params(), launch_error: nil)
       |> refresh_registry()
       |> refresh_selected_workspace_or_clear()
       |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} updated")
       |> push_patch(to: agents_path(socket.assigns.filters, %{id: agent.id, panel: :inspect}))}
    else
      false ->
        emit_action_telemetry("update", :workspace, id || "unknown", :error)
        {:noreply, socket |> clear_missing_selection(id) |> put_flash(:error, "Agent not found")}

      {:error, message} when is_binary(message) ->
        emit_action_telemetry("update", :workspace, id, :error)
        {:noreply, assign(socket, launch: launch, launch_error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        emit_action_telemetry("update", :workspace, id, :error)

        {:noreply,
         assign(
           socket,
           launch: launch,
           launch_error: "Failed to update agent: #{changeset_errors(changeset)}"
         )}

      {:error, reason} ->
        emit_action_telemetry("update", :workspace, id, :error)

        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to update agent: #{inspect(reason)}"
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <section class="overflow-hidden rounded-[2rem] bg-[radial-gradient(circle_at_top_left,_rgba(56,189,248,0.2),_transparent_28%),linear-gradient(135deg,_#0f172a,_#0f766e_50%,_#164e63)] px-6 py-7 text-white shadow-xl">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="max-w-3xl">
              <p class="text-xs font-semibold uppercase tracking-[0.3em] text-cyan-200">
                Agents Workspace
              </p>
              <h1 class="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">Create, control, and inspect every agent you own</h1>
              <p class="mt-3 max-w-2xl text-sm text-slate-200 sm:text-base">
                Manage lifecycle actions, edit saved definitions, and inspect spend, queued work, events, and logs without leaving this page.
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-3">
              <span class="rounded-full border border-white/15 bg-white/10 px-4 py-2 text-sm font-medium text-white">
                <%= length(@all_agents) %> total
              </span>
              <a
                href={~p"/agents/new"}
                class="inline-flex items-center rounded-full bg-white px-4 py-2 text-sm font-medium text-slate-900 hover:bg-slate-100"
              >
                New Agent
              </a>
            </div>
          </div>
        </section>

        <section class="rounded-2xl bg-white shadow">
          <div class="border-b border-slate-200 px-5 py-5">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 class="text-lg font-semibold text-slate-900">Registry</h2>
                <p class="mt-1 text-sm text-slate-500">
                  Search by name, behavior, or id. Row actions operate directly on the selected agent.
                </p>
              </div>
              <form id="agent-filters" phx-change="update_filters" class="flex flex-wrap items-center gap-3">
                <label class="sr-only" for="agent-search">Search agents</label>
                <input
                  id="agent-search"
                  type="search"
                  name="filters[q]"
                  value={@filters.q}
                  placeholder="Search name, behavior, or id"
                  class="w-72 rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-cyan-500 focus:outline-none focus:ring-2 focus:ring-cyan-200"
                />
                <label class="sr-only" for="agent-status">Filter by status</label>
                <select
                  id="agent-status"
                  name="filters[status]"
                  class="rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-cyan-500 focus:outline-none focus:ring-2 focus:ring-cyan-200"
                >
                  <option
                    :for={status <- @status_options}
                    value={status}
                    selected={status == @filters.status}
                  >
                    <%= humanize_status(status) %>
                  </option>
                </select>
                <button
                  :if={@filters.status != "all" or @filters.q != ""}
                  type="button"
                  phx-click="clear_filters"
                  class="inline-flex items-center rounded-xl border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Reset
                </button>
              </form>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-slate-200 text-sm">
              <thead class="bg-slate-50">
                <tr>
                  <th class="px-4 py-3 text-left font-medium text-slate-500">Agent</th>
                  <th class="px-4 py-3 text-left font-medium text-slate-500">Status</th>
                  <th class="px-4 py-3 text-left font-medium text-slate-500">Subscriptions</th>
                  <th class="px-4 py-3 text-left font-medium text-slate-500">Updated</th>
                  <th class="px-4 py-3 text-right font-medium text-slate-500">Actions</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-200 bg-white">
                <%= for agent <- @agents do %>
                  <tr class={row_class(@selected_agent_id, agent.id)}>
                    <td class="px-4 py-4 align-top">
                      <div class="font-semibold text-slate-900"><%= agent_name(agent.config) %></div>
                      <div class="text-xs text-slate-500"><%= agent.behavior %></div>
                      <div class="mt-1 font-mono text-[11px] text-slate-400"><%= agent.id %></div>
                    </td>
                    <td class="px-4 py-4 align-top">
                      <.status_badge status={agent.status} />
                    </td>
                    <td class="px-4 py-4 align-top text-xs text-slate-600">
                      <%= subscriptions_preview(agent.config) %>
                    </td>
                    <td class="px-4 py-4 align-top text-xs text-slate-500">
                      <%= format_datetime(agent.updated_at) %>
                    </td>
                    <td class="px-4 py-4 align-top">
                      <div class="flex flex-wrap justify-end gap-2">
                        <.link
                          patch={agents_path(@filters, %{id: agent.id, panel: :inspect})}
                          class="inline-flex items-center rounded-md border border-slate-300 px-2.5 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Inspect
                        </.link>
                        <.link
                          patch={agents_path(@filters, %{id: agent.id, panel: :edit})}
                          class="inline-flex items-center rounded-md border border-slate-300 px-2.5 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Edit
                        </.link>
                        <%= if agent.status in ["running", "degraded"] do %>
                          <button
                            type="button"
                            phx-click="stop_agent"
                            phx-value-id={agent.id}
                            phx-value-surface="row"
                            phx-disable-with="Stopping..."
                            class="inline-flex items-center rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800 hover:bg-amber-100"
                          >
                            Stop
                          </button>
                        <% else %>
                          <button
                            type="button"
                            phx-click="start_agent"
                            phx-value-id={agent.id}
                            phx-value-surface="row"
                            phx-disable-with="Starting..."
                            class="inline-flex items-center rounded-md border border-emerald-200 bg-emerald-50 px-2.5 py-1.5 text-xs font-medium text-emerald-800 hover:bg-emerald-100"
                          >
                            Start
                          </button>
                        <% end %>
                        <button
                          type="button"
                          phx-click="delete_agent"
                          phx-value-id={agent.id}
                          phx-value-surface="row"
                          phx-disable-with="Deleting..."
                          data-confirm="Delete this agent and all dependent records?"
                          class="inline-flex items-center rounded-md border border-rose-200 bg-rose-50 px-2.5 py-1.5 text-xs font-medium text-rose-700 hover:bg-rose-100"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>

                <%= if @all_agents == [] do %>
                  <tr>
                    <td colspan="5" class="px-4 py-12">
                      <div class="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-6 py-8 text-center">
                        <p class="text-base font-semibold text-slate-900">No agents exist yet.</p>
                        <p class="mt-2 text-sm text-slate-600">
                          Start with the builder, then come back here to inspect, edit, or control the runtime.
                        </p>
                        <a
                          href={~p"/agents/new"}
                          class="mt-4 inline-flex items-center rounded-full bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800"
                        >
                          Create your first agent
                        </a>
                      </div>
                    </td>
                  </tr>
                <% end %>

                <%= if @all_agents != [] and @agents == [] do %>
                  <tr>
                    <td colspan="5" class="px-4 py-12">
                      <div class="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-6 py-8 text-center">
                        <p class="text-base font-semibold text-slate-900">No agents match the current filters.</p>
                        <p class="mt-2 text-sm text-slate-600">
                          Clear the current search or status filter to see the full registry again.
                        </p>
                        <button
                          type="button"
                          phx-click="clear_filters"
                          class="mt-4 inline-flex items-center rounded-full border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
                        >
                          Reset filters
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </section>

        <section class="overflow-hidden rounded-2xl bg-white shadow">
          <div class="border-b border-slate-200 px-5 py-5">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 class="text-lg font-semibold text-slate-900">Selected Agent Workspace</h2>
                <p class="mt-1 text-sm text-slate-500">
                  Inspect runtime state or edit the saved definition for the selected agent.
                </p>
              </div>

              <%= if @selected_agent do %>
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    patch={agents_path(@filters, %{id: @selected_agent.id, panel: :inspect})}
                    class={workspace_tab_class(@selected_panel == :inspect)}
                  >
                    Inspect
                  </.link>
                  <.link
                    patch={agents_path(@filters, %{id: @selected_agent.id, panel: :edit})}
                    class={workspace_tab_class(@selected_panel == :edit)}
                  >
                    Edit
                  </.link>
                </div>
              <% end %>
            </div>
          </div>

          <%= if @inspection_errors != [] do %>
            <div class="border-b border-amber-200 bg-amber-50 px-5 py-4">
              <%= for error <- @inspection_errors do %>
                <div class="text-sm text-amber-900">
                  <p class="font-medium"><%= error.message %></p>
                  <p class="mt-1 text-xs text-amber-800"><%= error.details %></p>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @selected_agent do %>
            <div class="space-y-6 px-5 py-5">
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <div class="flex flex-wrap items-center gap-3">
                    <h3 class="text-2xl font-semibold text-slate-900"><%= agent_name(@selected_agent.config) %></h3>
                    <.status_badge status={@selected_agent.status} />
                  </div>
                  <p class="mt-1 text-sm text-slate-500"><%= @selected_agent.behavior %></p>
                  <p class="mt-2 font-mono text-xs text-slate-400"><%= @selected_agent.id %></p>
                </div>

                <div class="flex flex-wrap gap-2">
                  <%= if @selected_panel == :inspect do %>
                    <.link
                      patch={agents_path(@filters, %{id: @selected_agent.id, panel: :edit})}
                      class="inline-flex items-center rounded-md border border-slate-300 px-3 py-2 text-xs font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Edit Definition
                    </.link>
                  <% else %>
                    <.link
                      patch={agents_path(@filters, %{id: @selected_agent.id, panel: :inspect})}
                      class="inline-flex items-center rounded-md border border-slate-300 px-3 py-2 text-xs font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Back to Inspect
                    </.link>
                  <% end %>

                  <%= if @selected_agent.status in ["running", "degraded"] do %>
                    <button
                      type="button"
                      phx-click="stop_agent"
                      phx-value-id={@selected_agent.id}
                      phx-value-surface="workspace"
                      phx-disable-with="Stopping..."
                      class="inline-flex items-center rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs font-medium text-amber-800 hover:bg-amber-100"
                    >
                      Stop Agent
                    </button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="start_agent"
                      phx-value-id={@selected_agent.id}
                      phx-value-surface="workspace"
                      phx-disable-with="Starting..."
                      class="inline-flex items-center rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs font-medium text-emerald-800 hover:bg-emerald-100"
                    >
                      Start Agent
                    </button>
                  <% end %>

                  <button
                    type="button"
                    phx-click="delete_agent"
                    phx-value-id={@selected_agent.id}
                    phx-value-surface="workspace"
                    phx-disable-with="Deleting..."
                    data-confirm="Delete this agent and all dependent records?"
                    class="inline-flex items-center rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs font-medium text-rose-700 hover:bg-rose-100"
                  >
                    Delete Agent
                  </button>
                </div>
              </div>

              <%= if @selected_panel == :edit do %>
                <div class="rounded-2xl border border-slate-200 bg-slate-50 p-5">
                  <div class="mb-4">
                    <h3 class="text-lg font-semibold text-slate-900">Edit Agent</h3>
                    <p class="mt-1 text-sm text-slate-600">
                      Save a new definition for this agent. Running agents restart with the updated config.
                    </p>
                  </div>

                  <%= if @launch_error do %>
                    <div class="mb-4 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800">
                      <%= @launch_error %>
                    </div>
                  <% end %>

                  <form id="agent-edit-form" phx-submit="save_agent" class="space-y-4">
                    <input
                      type="hidden"
                      name="launch[builder_mode]"
                      value={Map.get(@launch, "builder_mode", "advanced")}
                    />

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                      <div>
                        <label for="launch_behavior" class="block text-sm font-medium text-slate-700">
                          Behavior
                        </label>
                        <select
                          id="launch_behavior"
                          name="launch[behavior]"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        >
                          <%= for behavior <- behaviors() do %>
                            <option value={behavior} selected={behavior == @launch["behavior"]}>
                              <%= behavior %>
                            </option>
                          <% end %>
                        </select>
                      </div>

                      <div>
                        <label for="launch_name" class="block text-sm font-medium text-slate-700">
                          Name
                        </label>
                        <input
                          id="launch_name"
                          type="text"
                          name="launch[name]"
                          value={@launch["name"]}
                          placeholder="optional display name"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>
                    </div>

                    <div>
                      <label for="launch_prompt" class="block text-sm font-medium text-slate-700">
                        Prompt
                      </label>
                      <textarea
                        id="launch_prompt"
                        name="launch[prompt]"
                        rows="4"
                        class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                      ><%= @launch["prompt"] %></textarea>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                      <div>
                        <label for="launch_subscriptions" class="block text-sm font-medium text-slate-700">
                          Subscriptions
                        </label>
                        <input
                          id="launch_subscriptions"
                          type="text"
                          name="launch[subscriptions]"
                          value={@launch["subscriptions"]}
                          placeholder="github:owner/repo,email:kent"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>

                      <div>
                        <label for="launch_tools" class="block text-sm font-medium text-slate-700">
                          Tools
                        </label>
                        <input
                          id="launch_tools"
                          type="text"
                          name="launch[tools]"
                          value={@launch["tools"]}
                          placeholder="read_file,search_files,http_get"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                      <div>
                        <label for="launch_memory_limit" class="block text-sm font-medium text-slate-700">
                          Memory Limit
                        </label>
                        <input
                          id="launch_memory_limit"
                          type="number"
                          min="1"
                          name="launch[memory_limit]"
                          value={@launch["memory_limit"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>

                      <div>
                        <label for="launch_budget_llm_calls" class="block text-sm font-medium text-slate-700">
                          LLM Call Budget
                        </label>
                        <input
                          id="launch_budget_llm_calls"
                          type="number"
                          min="1"
                          name="launch[budget_llm_calls]"
                          value={@launch["budget_llm_calls"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>

                      <div>
                        <label for="launch_budget_tool_calls" class="block text-sm font-medium text-slate-700">
                          Tool Call Budget
                        </label>
                        <input
                          id="launch_budget_tool_calls"
                          type="number"
                          min="1"
                          name="launch[budget_tool_calls]"
                          value={@launch["budget_tool_calls"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>
                    </div>

                    <div>
                      <label for="launch_config_json" class="block text-sm font-medium text-slate-700">
                        Additional Config JSON
                      </label>
                      <textarea
                        id="launch_config_json"
                        name="launch[config_json]"
                        rows="5"
                        class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 font-mono text-sm text-slate-900 shadow-sm"
                        placeholder={"{\"custom_key\":\"value\"}"}
                      ><%= @launch["config_json"] %></textarea>
                    </div>

                    <div class="flex justify-end">
                      <button
                        type="submit"
                        phx-disable-with="Saving..."
                        class="inline-flex items-center rounded-full bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800"
                      >
                        Save Changes
                      </button>
                    </div>
                  </form>
                </div>
              <% else %>
                <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
                  <div class="space-y-6">
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                      <.summary_card title="Started" value={format_datetime(@selected_agent.started_at)} />
                      <.summary_card title="Stopped" value={format_datetime(@selected_agent.stopped_at)} />
                      <.summary_card title="Subscriptions" value={subscriptions_preview(@selected_agent.config)} />
                      <.summary_card title="Tools" value={tools_preview(@selected_agent.config)} />
                      <.summary_card title="Event Count" value={to_string(@inspection.event_count)} />
                      <.summary_card title="Agent Spend" value={"$#{Float.round(@agent_spend.total_cost, 4)}"} value_class="text-amber-700" />
                    </div>

                    <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                      <div class="rounded-2xl bg-amber-50 p-4">
                        <div class="text-xs font-semibold uppercase tracking-[0.18em] text-amber-700">
                          Spend Summary
                        </div>
                        <dl class="mt-3 space-y-2 text-sm">
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">LLM Calls</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.llm_calls %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Input Tokens</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.input_tokens %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Output Tokens</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.output_tokens %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3 border-t border-amber-200 pt-2">
                            <dt class="text-amber-700/80">Total Cost</dt>
                            <dd class="font-semibold text-amber-950">
                              $<%= Float.round(@agent_spend.total_cost, 4) %>
                            </dd>
                          </div>
                        </dl>
                      </div>

                      <div class="rounded-2xl bg-slate-50 p-4">
                        <div class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                          Config Snapshot
                        </div>
                        <pre class="mt-3 overflow-x-auto whitespace-pre-wrap break-all text-[11px] text-slate-700"><%= pretty_config(@selected_agent.config) %></pre>
                      </div>
                    </div>

                    <div class="rounded-2xl bg-slate-50 p-4">
                      <div class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Prompt</div>
                      <p class="mt-3 whitespace-pre-wrap text-sm text-slate-800"><%= agent_prompt(@selected_agent.config) %></p>
                    </div>

                    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div class="border-b border-slate-200 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-900">Effect Queue</h3>
                        <p class="mt-1 text-sm text-slate-500">
                          Inspect pending and historical effects for this agent.
                        </p>
                      </div>
                      <div class="space-y-3 px-4 py-5">
                        <div class="grid grid-cols-3 gap-2 text-xs">
                          <.queue_metric title="Pending" value={@inspection.effect_counts.pending} />
                          <.queue_metric title="Claimed" value={@inspection.effect_counts.claimed} />
                          <.queue_metric
                            title="Failed"
                            value={@inspection.effect_counts.failed}
                            value_class="text-rose-600"
                          />
                        </div>

                        <div class="max-h-80 space-y-2 overflow-y-auto">
                          <%= for effect <- @inspection.recent_effects do %>
                            <div class="rounded-xl border border-slate-200 p-3">
                              <div class="flex items-center justify-between gap-3">
                                <div class="text-sm font-medium text-slate-900"><%= effect.effect_type %></div>
                                <span class={effect_status_class(effect.status)}><%= effect.status %></span>
                              </div>
                              <div class="mt-1 text-xs text-slate-500">
                                attempts <%= effect.attempts %>
                                <span class="mx-1">•</span>
                                updated <%= format_time(effect.updated_at) %>
                              </div>
                              <div class="mt-2 rounded bg-slate-50 px-2 py-1 font-mono text-[11px] text-slate-600">
                                <%= effect_preview(effect) %>
                              </div>
                            </div>
                          <% end %>

                          <%= if @inspection.recent_effects == [] do %>
                            <p class="text-sm text-slate-500">No effects recorded yet.</p>
                          <% end %>
                        </div>
                      </div>
                    </section>

                    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div class="border-b border-slate-200 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-900">Scheduled Jobs</h3>
                        <p class="mt-1 text-sm text-slate-500">
                          Wakeups, heartbeats, and checkpoints queued for this agent.
                        </p>
                      </div>
                      <div class="space-y-3 px-4 py-5">
                        <div class="grid grid-cols-2 gap-2 text-xs">
                          <.queue_metric title="Pending" value={@inspection.job_counts.pending} />
                          <.queue_metric
                            title="Dispatched"
                            value={@inspection.job_counts.dispatched}
                            value_class="text-amber-600"
                          />
                          <.queue_metric title="Delivered" value={@inspection.job_counts.delivered} />
                          <.queue_metric title="Cancelled" value={@inspection.job_counts.cancelled} />
                        </div>

                        <div class="max-h-80 space-y-2 overflow-y-auto">
                          <%= for job <- @inspection.recent_jobs do %>
                            <div class="rounded-xl border border-slate-200 p-3">
                              <div class="flex items-center justify-between gap-3">
                                <div class="text-sm font-medium text-slate-900"><%= job.job_type %></div>
                                <span class={job_status_class(job.status)}><%= job.status %></span>
                              </div>
                              <div class="mt-1 text-xs text-slate-500">
                                fire at <%= format_datetime(job.fire_at) %>
                                <span class="mx-1">•</span>
                                attempts <%= job.attempts %>
                              </div>
                              <div class="mt-2 rounded bg-slate-50 px-2 py-1 font-mono text-[11px] text-slate-600">
                                <%= payload_preview(job.payload) %>
                              </div>
                            </div>
                          <% end %>

                          <%= if @inspection.recent_jobs == [] do %>
                            <p class="text-sm text-slate-500">No scheduled jobs recorded yet.</p>
                          <% end %>
                        </div>
                      </div>
                    </section>
                  </div>

                  <div class="space-y-6">
                    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div class="border-b border-slate-200 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-900">Recent Events</h3>
                      </div>
                      <div class="max-h-96 space-y-2 overflow-y-auto px-4 py-4">
                        <%= for event <- Enum.reverse(@events) do %>
                          <div class="rounded-xl border border-slate-200 p-3 text-sm">
                            <div class="flex items-center justify-between gap-3">
                              <span class="font-medium text-cyan-700"><%= event.event_type %></span>
                              <span class="text-xs text-slate-400">#<%= event.sequence_num %></span>
                            </div>
                            <div class="mt-1 text-xs text-slate-500"><%= format_datetime(event.created_at) %></div>
                            <div class="mt-2 rounded bg-slate-50 px-2 py-1 font-mono text-[11px] text-slate-600">
                              <%= payload_preview(event.payload) %>
                            </div>
                          </div>
                        <% end %>

                        <%= if @events == [] do %>
                          <p class="text-sm text-slate-500">No events yet.</p>
                        <% end %>
                      </div>
                    </section>

                    <section class="overflow-hidden rounded-2xl bg-slate-950 shadow">
                      <div class="border-b border-slate-800 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-100">Agent Logs</h3>
                        <p class="mt-1 text-sm text-slate-400">
                          Raw log lines scoped to this agent's runtime metadata.
                        </p>
                      </div>
                      <div class="max-h-[32rem] overflow-y-auto px-4 py-4 font-mono text-[11px] leading-5">
                        <%= for log <- @inspection.recent_logs do %>
                          <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-slate-900 py-2">
                            <span class="text-slate-500"><%= format_log_timestamp(log.timestamp) %></span>
                            <span class={["font-semibold uppercase tracking-wide", log_level_class(log.level)]}>
                              <%= log.level %>
                            </span>
                            <div class="min-w-0">
                              <%= if metadata = log_metadata_preview(log.metadata) do %>
                                <span class="mr-2 text-slate-500"><%= metadata %></span>
                              <% end %>
                              <span class="break-words whitespace-pre-wrap text-slate-100"><%= log.message %></span>
                            </div>
                          </div>
                        <% end %>

                        <%= if @inspection.recent_logs == [] do %>
                          <p class="text-sm text-slate-500">No agent-scoped logs captured yet.</p>
                        <% end %>
                      </div>
                    </section>
                  </div>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="px-5 py-12">
              <div class="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-6 py-10 text-center">
                <p class="text-base font-semibold text-slate-900">No agent selected.</p>
                <p class="mt-2 text-sm text-slate-600">
                  Pick an agent from the registry above to inspect runtime state or edit the saved definition.
                </p>
              </div>
            </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :string, default: "text-slate-900"

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <dt class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500"><%= @title %></dt>
      <dd class={"mt-2 text-sm font-medium #{@value_class}"}><%= @value %></dd>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: "text-slate-900"

  defp queue_metric(assigns) do
    ~H"""
    <div class="rounded-xl bg-slate-50 p-2">
      <div class="text-slate-500"><%= @title %></div>
      <div class={"text-sm font-semibold #{@value_class}"}><%= @value %></div>
    </div>
    """
  end

  defp apply_selection(socket, nil, _panel, raw_panel) when is_binary(raw_panel) do
    {:sanitize, clear_selection(socket), filters_path(socket), nil}
  end

  defp apply_selection(socket, nil, _panel, _raw_panel) do
    {:ok, clear_selection(socket)}
  end

  defp apply_selection(socket, id, panel, _raw_panel) do
    case Agents.get_agent_for_user(id, current_user_id(socket)) do
      nil ->
        {:sanitize, clear_selection(socket), filters_path(socket), {:error, "Agent not found"}}

      agent ->
        panel = panel || :inspect
        load_selected_snapshot(socket, agent, panel)
    end
  end

  defp load_selected_snapshot(socket, agent, panel) do
    case Admin.safe_agent_snapshot(
           agent.id,
           user_id: current_user_id(socket),
           event_limit: @event_limit,
           log_limit: 80
         ) do
      {:ok, snapshot} ->
        {:ok,
         assign(socket,
           selected_agent_id: agent.id,
           selected_agent: snapshot.agent,
           selected_panel: panel,
           events: snapshot.events,
           agent_spend: snapshot.spend,
           inspection: snapshot.inspection,
           inspection_errors: snapshot.errors,
           launch: launch_for_panel(socket, agent, panel),
           launch_error: nil
         )}

      {:degraded, snapshot} ->
        inspection =
          if socket.assigns.selected_agent_id == agent.id do
            merge_degraded_inspection(socket.assigns.inspection, snapshot.inspection)
          else
            snapshot.inspection
          end

        {:ok,
         assign(socket,
           selected_agent_id: agent.id,
           selected_agent:
             if(socket.assigns.selected_agent_id == agent.id,
               do: socket.assigns.selected_agent || agent,
               else: agent
             ),
           selected_panel: panel,
           events:
             if(socket.assigns.selected_agent_id == agent.id, do: socket.assigns.events, else: []),
           agent_spend:
             if(socket.assigns.selected_agent_id == agent.id,
               do: socket.assigns.agent_spend,
               else: empty_spend()
             ),
           inspection: inspection,
           inspection_errors: snapshot.errors,
           launch: launch_for_panel(socket, agent, panel),
           launch_error: nil
         )}

      {:error, :not_found} ->
        {:sanitize, clear_selection(socket), filters_path(socket), {:error, "Agent not found"}}
    end
  end

  defp refresh_registry(socket) do
    agents = Agents.list_agents(user_id: current_user_id(socket))
    filtered_agents = filter_agents(agents, socket.assigns.filters)

    assign(socket, all_agents: agents, agents: filtered_agents)
  end

  defp refresh_selected_workspace(socket) do
    case socket.assigns.selected_agent_id do
      nil ->
        {:ok, socket}

      id ->
        case Agents.get_agent_for_user(id, current_user_id(socket)) do
          nil ->
            {:sanitize, clear_selection(socket), filters_path(socket),
             {:error, "Agent not found"}}

          agent ->
            load_selected_snapshot(socket, agent, socket.assigns.selected_panel || :inspect)
        end
    end
  end

  defp refresh_selected_workspace_or_clear(socket) do
    case refresh_selected_workspace(socket) do
      {:ok, socket} ->
        socket

      {:sanitize, socket, to, flash} ->
        socket |> maybe_put_flash(flash) |> push_patch(to: to)
    end
  end

  defp clear_missing_selection(socket, id) do
    if socket.assigns.selected_agent_id == id do
      socket
      |> clear_selection()
      |> push_patch(to: filters_path(socket))
    else
      socket
    end
  end

  defp clear_selection(socket) do
    assign(socket,
      selected_agent_id: nil,
      selected_agent: nil,
      selected_panel: nil,
      events: [],
      inspection: empty_inspection(),
      agent_spend: empty_spend(),
      inspection_errors: [],
      launch: default_launch_params(),
      launch_error: nil
    )
  end

  defp maybe_emit_route_telemetry(socket, route_state) do
    previous = socket.assigns.route_state

    if is_nil(previous) do
      :telemetry.execute(
        [:maraithon, :agents, :view, :loaded],
        %{agent_count: length(socket.assigns.all_agents)},
        %{has_selection: not is_nil(route_state.id), panel: route_state.panel}
      )
    end

    if selection_changed?(previous, route_state) and route_state.id do
      :telemetry.execute(
        [:maraithon, :agents, :selection, :changed],
        %{count: 1},
        %{agent_id: route_state.id, panel: route_state.panel || :inspect}
      )
    end

    if filter_changed?(previous, route_state) do
      :telemetry.execute(
        [:maraithon, :agents, :filter, :changed],
        %{count: 1},
        %{status: route_state.status, has_query: route_state.q != ""}
      )
    end

    assign(socket, :route_state, route_state)
  end

  defp emit_action_telemetry(action, surface, agent_id, outcome) do
    :telemetry.execute(
      [:maraithon, :agents, :action],
      %{count: 1},
      %{action: action, surface: surface, agent_id: agent_id, outcome: outcome}
    )
  end

  defp selection_changed?(nil, _route_state), do: false

  defp selection_changed?(previous, current) do
    previous.id != current.id or previous.panel != current.panel
  end

  defp filter_changed?(nil, _route_state), do: false

  defp filter_changed?(previous, current) do
    previous.status != current.status or previous.q != current.q
  end

  defp default_filters do
    %{status: "all", q: ""}
  end

  defp normalize_status(status) when status in @status_options, do: status
  defp normalize_status(_status), do: "all"

  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(_query), do: ""

  defp normalize_panel("inspect"), do: :inspect
  defp normalize_panel("edit"), do: :edit
  defp normalize_panel(_panel), do: nil

  defp normalize_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_id(_id), do: nil

  defp current_path_from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/agents"
      "" -> "/agents"
      path -> path
    end
  rescue
    _ -> "/agents"
  end

  defp filters_path(socket), do: agents_path(socket.assigns.filters)

  defp agents_path_for_socket(socket, filters) do
    agents_path(filters, %{
      id: socket.assigns.selected_agent_id,
      panel: socket.assigns.selected_panel
    })
  end

  defp agents_path(filters) when is_map(filters), do: agents_path(filters, %{})

  defp agents_path(filters, extra) when is_map(filters) and is_map(extra) do
    query =
      []
      |> maybe_put_query("id", Map.get(extra, :id))
      |> maybe_put_query("panel", panel_param(Map.get(extra, :panel)))
      |> maybe_put_query("status", filters.status, filters.status != "all")
      |> maybe_put_query("q", filters.q, filters.q != "")

    case URI.encode_query(query) do
      "" -> "/agents"
      encoded -> "/agents?" <> encoded
    end
  end

  defp maybe_put_query(params, _key, _value, false), do: params
  defp maybe_put_query(params, key, value, true), do: maybe_put_query(params, key, value)
  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, _key, ""), do: params
  defp maybe_put_query(params, key, value), do: params ++ [{key, value}]

  defp panel_param(:inspect), do: nil
  defp panel_param(:edit), do: "edit"
  defp panel_param(_panel), do: nil

  defp filter_agents(agents, %{status: status, q: query}) do
    agents
    |> Enum.filter(fn agent ->
      status == "all" or agent.status == status
    end)
    |> Enum.filter(fn agent ->
      matches_query?(agent, query)
    end)
  end

  defp matches_query?(_agent, ""), do: true

  defp matches_query?(agent, query) do
    query = String.downcase(query)

    [agent_name(agent.config), agent.behavior, agent.id]
    |> Enum.map(fn value -> value |> Kernel.||("") |> to_string() |> String.downcase() end)
    |> Enum.any?(&String.contains?(&1, query))
  end

  defp launch_for_panel(socket, agent, :edit) do
    if socket.assigns.selected_agent_id == agent.id and socket.assigns.selected_panel == :edit do
      socket.assigns.launch
    else
      launch_params_from_agent(agent)
    end
  end

  defp launch_for_panel(_socket, _agent, _panel), do: default_launch_params()

  defp action_surface("workspace"), do: :workspace
  defp action_surface(_surface), do: :row

  defp humanize_status("all"), do: "All statuses"
  defp humanize_status(status), do: status |> String.replace("_", " ") |> String.capitalize()

  defp row_class(selected_agent_id, agent_id) when selected_agent_id == agent_id,
    do: "bg-cyan-50/70"

  defp row_class(_selected_agent_id, _agent_id), do: ""

  defp workspace_tab_class(true),
    do:
      "inline-flex items-center rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white"

  defp workspace_tab_class(false),
    do:
      "inline-flex items-center rounded-full border border-slate-300 px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50"

  defp behaviors do
    AgentBuilder.behavior_specs()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp default_launch_params do
    AgentBuilder.default_launch_params()
  end

  defp launch_params_from_agent(agent), do: AgentBuilder.launch_params_from_agent(agent)

  defp normalize_launch_params(params), do: AgentBuilder.normalize_launch_params(params)

  defp build_agent_start_params(launch, user_id),
    do: AgentBuilder.build_start_params(launch, user_id)

  defp agent_owned_by_current_user?(socket, agent_id) when is_binary(agent_id) do
    not is_nil(Agents.get_agent_for_user(agent_id, current_user_id(socket)))
  end

  defp agent_owned_by_current_user?(_socket, _agent_id), do: false

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

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

  defp maybe_put_flash(socket, nil), do: socket
  defp maybe_put_flash(socket, {kind, message}), do: put_flash(socket, kind, message)

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp agent_name(config), do: config["name"] || "unnamed_agent"

  defp agent_prompt(config),
    do: config["prompt"] || AgentBuilder.default_launch_params()["prompt"]

  defp pretty_config(config) when is_map(config) do
    Jason.encode!(config, pretty: true)
  rescue
    _ -> inspect(config, pretty: true, limit: :infinity)
  end

  defp pretty_config(config), do: inspect(config, pretty: true, limit: :infinity)

  defp subscriptions_preview(config) do
    case config["subscribe"] || [] do
      [] -> "No subscriptions"
      values -> values |> Enum.take(3) |> Enum.join(", ") |> truncate(70)
    end
  end

  defp tools_preview(config) do
    case config["tools"] || [] do
      [] -> "No tools"
      values -> values |> Enum.join(", ") |> truncate(70)
    end
  end

  defp effect_preview(effect) do
    cond do
      is_binary(effect.error) and effect.error != "" ->
        effect.error

      is_map(effect.result) and effect.result != %{} ->
        payload_preview(effect.result)

      true ->
        payload_preview(effect.params)
    end
  end

  defp effect_status_class("failed"),
    do: "rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700"

  defp effect_status_class("completed"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700"

  defp effect_status_class("claimed"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp effect_status_class(_status),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp job_status_class("cancelled"),
    do: "rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700"

  defp job_status_class("delivered"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700"

  defp job_status_class("dispatched"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp job_status_class(_status),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp payload_preview(payload) when is_map(payload) do
    payload
    |> Jason.encode!()
    |> truncate(220)
  rescue
    _ -> inspect(payload, limit: 8)
  end

  defp payload_preview(payload), do: payload |> inspect(limit: 8) |> truncate(220)

  defp truncate(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp format_log_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%H:%M:%S")

      _ ->
        timestamp
    end
  end

  defp format_log_timestamp(_timestamp), do: "n/a"

  defp log_level_class(level) when level in [:error, :critical, :alert, :emergency],
    do: "text-rose-300"

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
      _ -> "text-slate-300"
    end
  end

  defp log_level_class(_level), do: "text-slate-300"

  defp log_metadata_preview(metadata) when metadata in [%{}, nil], do: nil

  defp log_metadata_preview(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
    |> truncate(120)
  end

  defp log_metadata_preview(_metadata), do: nil

  defp format_time(nil), do: "N/A"

  defp format_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_time(dt)
      _ -> datetime
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
