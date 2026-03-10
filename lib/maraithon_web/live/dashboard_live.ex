defmodule MaraithonWeb.DashboardLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AgentBuilder
  alias Maraithon.Admin
  alias Maraithon.Agents
  alias Maraithon.Behaviors
  alias Maraithon.Connections
  alias Maraithon.Insights
  alias Maraithon.Runtime

  @refresh_interval 5_000
  @event_limit 50
  @activity_limit 40
  @failure_limit 20

  @impl true
  def mount(_params, _session, socket) do
    user_id = current_user_id(socket)

    socket =
      socket
      |> assign(
        page_title: "Control Center",
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
        connections: [],
        raw_connections: [],
        connection_errors: [],
        dashboard_errors: [],
        inspection_errors: [],
        insights: []
      )

    socket =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, self(), :refresh)
        send(self(), :load_fly_logs)
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

    case Map.get(params, "id") do
      id when is_binary(id) ->
        case refresh_selected_agent(socket, id) do
          {:ok, socket} ->
            {:noreply, assign(socket, page_title: "Agent #{String.slice(id, 0, 8)}")}

          {:not_found, socket} ->
            {:noreply,
             socket
             |> assign(
               selected_agent: nil,
               events: [],
               agent_spend: nil,
               inspection: empty_inspection(),
               inspection_errors: []
             )
             |> push_navigate(to: connection_home_path(socket, socket.assigns.connection_user_id))}
        end

      _ ->
        {:noreply,
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

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_dashboard(socket)}
  end

  def handle_info(:load_fly_logs, socket) do
    {:noreply, refresh_fly_logs(socket)}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    send(self(), :load_fly_logs)

    {:noreply,
     socket
     |> refresh_dashboard()
     |> put_flash(:info, "Dashboard refreshed")}
  end

  def handle_event("refresh_fly_logs", _params, socket) do
    send(self(), :load_fly_logs)
    {:noreply, put_flash(socket, :info, "Fly logs refresh started")}
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
        {:noreply, put_flash(socket, :error, "Unsupported provider")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(
           :error,
           "Failed to disconnect #{provider_label(provider)}: #{inspect(reason)}"
         )}
    end
  end

  def handle_event("ack_insight", %{"id" => insight_id}, socket) do
    case Insights.acknowledge(current_user_id(socket), insight_id) do
      {:ok, _insight} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:info, "Insight acknowledged")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to acknowledge insight: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_insight", %{"id" => insight_id}, socket) do
    case Insights.dismiss(current_user_id(socket), insight_id) do
      {:ok, _insight} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:info, "Insight dismissed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dismiss insight: #{inspect(reason)}")}
    end
  end

  def handle_event("snooze_insight", %{"id" => insight_id}, socket) do
    snooze_until = DateTime.add(DateTime.utc_now(), 4, :hour)

    case Insights.snooze(current_user_id(socket), insight_id, snooze_until) do
      {:ok, _insight} ->
        {:noreply,
         socket
         |> refresh_insights()
         |> put_flash(:info, "Insight snoozed for 4 hours")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to snooze insight: #{inspect(reason)}")}
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
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

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
           launch_error: "Failed to save agent: #{changeset_errors(changeset)}"
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to save agent: #{inspect(reason)}"
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
           |> put_flash(:info, "Agent started")}

        {:error, :already_running} ->
          {:noreply,
           socket |> refresh_dashboard() |> put_flash(:info, "Agent is already running")}

        {:error, :not_found} ->
          {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
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
           |> put_flash(:info, "Agent stopped")}

        {:error, :not_found} ->
          {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
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
            |> put_flash(:info, "Agent deleted")

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
          {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> put_flash(:error, "Failed to delete agent: #{inspect(reason)}")}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("send_message", %{"command" => %{"message" => raw_message}}, socket) do
    message = String.trim(raw_message || "")

    cond do
      socket.assigns.selected_agent == nil ->
        {:noreply, put_flash(socket, :error, "Select an agent first")}

      not agent_owned_by_current_user?(socket, socket.assigns.selected_agent.id) ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

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
      <div class="space-y-6">
      <section class="rounded-2xl bg-gradient-to-r from-slate-900 via-slate-800 to-indigo-900 px-6 py-6 text-white shadow">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-3xl">
            <p class="text-xs font-semibold uppercase tracking-[0.28em] text-indigo-200">
              Admin Control Center
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight">Agent Fleet Operations</h1>
            <p class="mt-2 text-sm text-slate-200">
              Create, edit, start, stop, delete, and inspect agents from one surface.
              Drill into live runtime behavior, queued work, raw logs, and direct operator commands.
            </p>
          </div>

          <div class="flex gap-2">
            <a
              href={~p"/agents/new"}
              class="inline-flex items-center rounded-md border border-white/20 bg-white/10 px-3 py-2 text-sm font-medium text-white hover:bg-white/15"
            >
              Build Agent
            </a>
            <button
              type="button"
              phx-click="refresh_now"
              class="inline-flex items-center rounded-md border border-white/20 bg-white px-3 py-2 text-sm font-medium text-slate-900 hover:bg-slate-100"
            >
              Refresh
            </button>
          </div>
        </div>
      </section>

      <%= if @dashboard_errors != [] do %>
        <section class="rounded-xl border border-amber-200 bg-amber-50 px-4 py-4 shadow-sm">
          <div class="space-y-2">
            <%= for error <- @dashboard_errors do %>
              <div>
                <p class="text-sm font-medium text-amber-900"><%= error.message %></p>
                <p class="mt-1 text-xs text-amber-800"><%= error.details %></p>
              </div>
            <% end %>
          </div>
        </section>
      <% end %>

      <section class="grid grid-cols-1 gap-5 sm:grid-cols-2 xl:grid-cols-6">
        <.stat_card title="Total Agents" value={length(@agents)} />
        <.stat_card
          title="Running"
          value={Enum.count(@agents, &(&1.status == "running"))}
          value_class="text-green-600"
        />
        <.stat_card
          title="Degraded"
          value={Enum.count(@agents, &(&1.status == "degraded"))}
          value_class="text-amber-600"
        />
        <.stat_card title="LLM Calls" value={@total_spend.llm_calls} value_class="text-indigo-600" />
        <.stat_card
          title="Total Spend"
          value={"$#{Float.round(@total_spend.total_cost, 4)}"}
          value_class="text-amber-600"
        />
        <.stat_card title="Pending Effects" value={@queue_metrics.effects.pending} />
      </section>

      <section class="rounded-xl border border-indigo-100 bg-indigo-50/50 px-4 py-4 shadow-sm sm:px-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 class="text-lg font-medium text-indigo-950">Connectors</h2>
            <p class="mt-1 text-sm text-indigo-900/80">
              Connected Accounts and OAuth configuration now live in the dedicated Connectors tab.
            </p>
          </div>
          <.link
            navigate={"/connectors"}
            class="inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-medium text-white hover:bg-indigo-500"
          >
            Open Connectors
          </.link>
        </div>
      </section>

      <section class="overflow-hidden rounded-xl bg-white shadow">
        <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium text-gray-900">Actionable Insights</h2>
              <p class="mt-1 text-sm text-gray-500">
                Email and calendar recommendations from long-running advisor agents.
              </p>
            </div>
            <span class="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700">
              <%= length(@insights) %> open
            </span>
          </div>
        </div>

        <div class="divide-y divide-slate-200">
          <%= for insight <- @insights do %>
            <div class="px-4 py-4 sm:px-6">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={insight_category_class(insight.category)}>
                      <%= insight_category_label(insight.category) %>
                    </span>
                    <span class={insight_priority_class(insight.priority)}>
                      P<%= insight.priority %>
                    </span>
                    <span class="text-xs text-slate-500">
                      confidence <%= format_confidence(insight.confidence) %>
                    </span>
                    <span :if={insight.due_at} class="text-xs text-amber-700">
                      due <%= format_datetime(insight.due_at) %>
                    </span>
                  </div>
                  <p class="mt-2 text-sm font-semibold text-slate-900"><%= insight.title %></p>
                  <p class="mt-1 text-sm text-slate-600"><%= insight.summary %></p>
                  <p class="mt-2 text-sm text-indigo-700">
                    <span class="font-medium">Action:</span> <%= insight.recommended_action %>
                  </p>
                  <% why_now = insight_why_now(insight) %>
                  <%= if why_now do %>
                    <p class="mt-2 text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                      Why now
                    </p>
                    <p class="mt-1 text-sm text-slate-600"><%= why_now %></p>
                  <% end %>
                  <% ideas = insight_follow_up_ideas(insight) %>
                  <%= if ideas != [] do %>
                    <p class="mt-2 text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                      Ideas
                    </p>
                    <ul class="mt-1 space-y-1 text-sm text-slate-600">
                      <%= for idea <- ideas do %>
                        <li>- <%= idea %></li>
                      <% end %>
                    </ul>
                  <% end %>
                </div>
                <div class="flex flex-wrap gap-2">
                  <button
                    type="button"
                    phx-click="ack_insight"
                    phx-value-id={insight.id}
                    class="inline-flex items-center rounded-md border border-emerald-200 bg-emerald-50 px-2.5 py-1.5 text-xs font-medium text-emerald-800 hover:bg-emerald-100"
                  >
                    Acknowledge
                  </button>
                  <button
                    type="button"
                    phx-click="snooze_insight"
                    phx-value-id={insight.id}
                    class="inline-flex items-center rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800 hover:bg-amber-100"
                  >
                    Snooze 4h
                  </button>
                  <button
                    type="button"
                    phx-click="dismiss_insight"
                    phx-value-id={insight.id}
                    class="inline-flex items-center rounded-md border border-rose-200 bg-rose-50 px-2.5 py-1.5 text-xs font-medium text-rose-700 hover:bg-rose-100"
                  >
                    Dismiss
                  </button>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @insights == [] do %>
            <div class="px-4 py-10 text-center text-sm text-slate-500 sm:px-6">
              No actionable insights yet. Start a <span class="font-medium">founder_followthrough_agent</span>, <span class="font-medium">inbox_calendar_advisor</span>, or <span class="font-medium">slack_followthrough_agent</span> and connect the required services.
            </div>
          <% end %>
        </div>
      </section>

      <section class="grid grid-cols-1 gap-6 xl:grid-cols-5">
        <div class="overflow-hidden rounded-xl bg-white shadow xl:col-span-3">
          <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-medium text-gray-900">Agent Registry</h2>
                <p class="mt-1 text-sm text-gray-500">
                  Full CRUD and control actions for every agent in the fleet.
                </p>
              </div>
              <span class="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700">
                <%= length(@agents) %> total
              </span>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200 text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-3 text-left font-medium text-gray-500">Agent</th>
                  <th class="px-4 py-3 text-left font-medium text-gray-500">Status</th>
                  <th class="px-4 py-3 text-left font-medium text-gray-500">Subscriptions</th>
                  <th class="px-4 py-3 text-left font-medium text-gray-500">Updated</th>
                  <th class="px-4 py-3 text-right font-medium text-gray-500">Actions</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for agent <- @agents do %>
                  <tr class={if @selected_agent && @selected_agent.id == agent.id, do: "bg-indigo-50/70", else: ""}>
                    <td class="px-4 py-4 align-top">
                      <div class="font-medium text-gray-900"><%= agent_name(agent.config) %></div>
                      <div class="text-xs text-gray-500"><%= agent.behavior %></div>
                      <div class="mt-1 font-mono text-[11px] text-gray-400"><%= agent.id %></div>
                    </td>
                    <td class="px-4 py-4 align-top">
                      <.status_badge status={agent.status} />
                    </td>
                    <td class="px-4 py-4 align-top text-xs text-gray-600">
                      <%= subscriptions_preview(agent.config) %>
                    </td>
                    <td class="px-4 py-4 align-top text-xs text-gray-500">
                      <%= format_datetime(agent.updated_at) %>
                    </td>
                    <td class="px-4 py-4 align-top">
                      <div class="flex flex-wrap justify-end gap-2">
                        <.link
                          patch={"/dashboard?id=#{agent.id}"}
                          class="inline-flex items-center rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50"
                        >
                          Inspect
                        </.link>
                        <button
                          type="button"
                          phx-click="edit_agent"
                          phx-value-id={agent.id}
                          class="inline-flex items-center rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50"
                        >
                          Edit
                        </button>
                        <%= if agent.status in ["running", "degraded"] do %>
                          <button
                            type="button"
                            phx-click="stop_agent"
                            phx-value-id={agent.id}
                            class="inline-flex items-center rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800 hover:bg-amber-100"
                          >
                            Stop
                          </button>
                        <% else %>
                          <button
                            type="button"
                            phx-click="start_agent"
                            phx-value-id={agent.id}
                            class="inline-flex items-center rounded-md border border-emerald-200 bg-emerald-50 px-2.5 py-1.5 text-xs font-medium text-emerald-800 hover:bg-emerald-100"
                          >
                            Start
                          </button>
                        <% end %>
                        <button
                          type="button"
                          phx-click="delete_agent"
                          phx-value-id={agent.id}
                          data-confirm="Delete this agent and all dependent records?"
                          class="inline-flex items-center rounded-md border border-red-200 bg-red-50 px-2.5 py-1.5 text-xs font-medium text-red-700 hover:bg-red-100"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <%= if @agents == [] do %>
                  <tr>
                    <td colspan="5" class="px-4 py-12 text-center text-gray-500">
                      No agents yet. Build one from the dedicated builder.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <div class="overflow-hidden rounded-xl bg-white shadow xl:col-span-2">
          <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-medium text-gray-900"><%= launch_title(@launch_mode) %></h2>
                <p class="mt-1 text-sm text-gray-500"><%= launch_subtitle(@launch_mode) %></p>
              </div>
              <%= if @launch_mode == :edit do %>
                <button
                  type="button"
                  phx-click="new_agent"
                  class="inline-flex items-center rounded-md border border-gray-300 px-3 py-2 text-xs font-medium text-gray-700 hover:bg-gray-50"
                >
                  Cancel Edit
                </button>
              <% end %>
            </div>
          </div>
          <div class="px-4 py-5 sm:px-6">
            <%= if @launch_error do %>
              <div class="mb-4 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                <%= @launch_error %>
              </div>
            <% end %>

            <%= if @launch_mode == :edit do %>
              <form id="launch-agent-form" phx-submit="launch_agent" class="space-y-4">
                <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                  <div>
                    <label for="launch_behavior" class="block text-sm font-medium text-gray-700">
                      Behavior
                    </label>
                    <select
                      id="launch_behavior"
                      name="launch[behavior]"
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    >
                      <%= for behavior <- @behaviors do %>
                        <option value={behavior} selected={behavior == @launch["behavior"]}>
                          <%= behavior %>
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div>
                    <label for="launch_name" class="block text-sm font-medium text-gray-700">
                      Name
                    </label>
                    <input
                      id="launch_name"
                      type="text"
                      name="launch[name]"
                      value={@launch["name"]}
                      placeholder="optional display name"
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    />
                  </div>
                </div>

                <div>
                  <label for="launch_prompt" class="block text-sm font-medium text-gray-700">
                    Prompt
                  </label>
                  <textarea
                    id="launch_prompt"
                    name="launch[prompt]"
                    rows="4"
                    class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                  ><%= @launch["prompt"] %></textarea>
                </div>

                <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                  <div>
                    <label for="launch_subscriptions" class="block text-sm font-medium text-gray-700">
                      Subscriptions
                    </label>
                    <input
                      id="launch_subscriptions"
                      type="text"
                      name="launch[subscriptions]"
                      value={@launch["subscriptions"]}
                      placeholder="github:owner/repo,email:kent"
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    />
                  </div>
                  <div>
                    <label for="launch_tools" class="block text-sm font-medium text-gray-700">
                      Tools
                    </label>
                    <input
                      id="launch_tools"
                      type="text"
                      name="launch[tools]"
                      value={@launch["tools"]}
                      placeholder="read_file,search_files,http_get"
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    />
                  </div>
                </div>

                <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                  <div>
                    <label for="launch_memory_limit" class="block text-sm font-medium text-gray-700">
                      Memory Limit
                    </label>
                    <input
                      id="launch_memory_limit"
                      type="number"
                      min="1"
                      name="launch[memory_limit]"
                      value={@launch["memory_limit"]}
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    />
                  </div>
                  <div>
                    <label for="launch_budget_llm_calls" class="block text-sm font-medium text-gray-700">
                      LLM Call Budget
                    </label>
                    <input
                      id="launch_budget_llm_calls"
                      type="number"
                      min="1"
                      name="launch[budget_llm_calls]"
                      value={@launch["budget_llm_calls"]}
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    />
                  </div>
                  <div>
                    <label for="launch_budget_tool_calls" class="block text-sm font-medium text-gray-700">
                      Tool Call Budget
                    </label>
                    <input
                      id="launch_budget_tool_calls"
                      type="number"
                      min="1"
                      name="launch[budget_tool_calls]"
                      value={@launch["budget_tool_calls"]}
                      class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    />
                  </div>
                </div>

                <div>
                  <label for="launch_config_json" class="block text-sm font-medium text-gray-700">
                    Additional Config JSON
                  </label>
                  <textarea
                    id="launch_config_json"
                    name="launch[config_json]"
                    rows="5"
                    class="mt-1 block w-full rounded-md border-gray-300 text-sm font-mono shadow-sm"
                    placeholder={"{\"custom_key\":\"value\"}"}
                  ><%= @launch["config_json"] %></textarea>
                </div>

                <div class="flex justify-end">
                  <button
                    type="submit"
                    class="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500"
                  >
                    <%= launch_submit_label(@launch_mode) %>
                  </button>
                </div>
              </form>
            <% else %>
              <div class="rounded-xl border border-indigo-200 bg-indigo-50/60 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.24em] text-indigo-700">
                  Dedicated Builder
                </p>
                <h3 class="mt-3 text-xl font-semibold text-slate-900">Create agents on a focused page</h3>
                <p class="mt-2 max-w-2xl text-sm text-slate-600">
                  Use the dedicated builder to choose the right template, understand the exact inputs and outputs, confirm permissions, and start the agent with sensible defaults.
                </p>
                <div class="mt-4 flex flex-wrap gap-3">
                  <a
                    href={~p"/agents/new"}
                    class="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500"
                  >
                    Open Agent Builder
                  </a>
                  <p class="text-sm text-slate-500">
                    The builder starts new agents immediately after creation and sends you back here to inspect them.
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </section>

      <section class="grid grid-cols-1 gap-6 xl:grid-cols-5">
        <div class="overflow-hidden rounded-xl bg-white shadow xl:col-span-3">
          <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
            <h2 class="text-lg font-medium text-gray-900">Health & Monitoring</h2>
          </div>
          <div class="grid grid-cols-1 gap-6 px-4 py-5 sm:px-6 md:grid-cols-2">
            <div class="space-y-4">
              <div class="flex items-center justify-between">
                <span class="text-sm font-medium text-gray-500">System Status</span>
                <span class={"inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium #{health_badge_class(@health.status)}"}>
                  <%= @health.status %>
                </span>
              </div>

              <dl class="space-y-2 text-sm">
                <.health_row
                  label="Database"
                  value={to_string(@health.checks.database)}
                  value_class={
                    if @health.checks.database == :ok,
                      do: "text-green-600 font-medium",
                      else: "text-red-600 font-medium"
                  }
                />
                <.health_row label="Memory" value={"#{@health.checks.memory_mb} MB"} />
                <.health_row label="Uptime" value={format_uptime(@health.checks.uptime_seconds)} />
                <.health_row
                  label="Version"
                  value={@health.version || "n/a"}
                  value_class="font-mono text-xs text-gray-900"
                />
              </dl>
            </div>

            <div class="space-y-4">
              <div>
                <h3 class="text-sm font-medium text-gray-700">Effects Queue</h3>
                <div class="mt-2 grid grid-cols-2 gap-2 text-xs">
                  <.queue_metric title="Pending" value={@queue_metrics.effects.pending} />
                  <.queue_metric
                    title="Failed"
                    value={@queue_metrics.effects.failed}
                    value_class="text-red-600"
                  />
                  <.queue_metric title="Claimed" value={@queue_metrics.effects.claimed} />
                  <.queue_metric title="Completed" value={@queue_metrics.effects.completed} />
                </div>
              </div>
              <div>
                <h3 class="text-sm font-medium text-gray-700">Scheduled Jobs</h3>
                <div class="mt-2 grid grid-cols-2 gap-2 text-xs">
                  <.queue_metric title="Pending" value={@queue_metrics.jobs.pending} />
                  <.queue_metric
                    title="Dispatched"
                    value={@queue_metrics.jobs.dispatched}
                    value_class="text-amber-600"
                  />
                  <.queue_metric title="Delivered" value={@queue_metrics.jobs.delivered} />
                  <.queue_metric title="Cancelled" value={@queue_metrics.jobs.cancelled} />
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="overflow-hidden rounded-xl bg-white shadow xl:col-span-2">
          <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
            <h2 class="text-lg font-medium text-gray-900">Agent Details</h2>
            <p class="mt-1 text-sm text-gray-500">
              Selected agent inspection across runtime, spend, and configuration.
            </p>
          </div>
          <%= if @inspection_errors != [] do %>
            <div class="border-b border-amber-200 bg-amber-50 px-4 py-3 sm:px-6">
              <%= for error <- @inspection_errors do %>
                <div class="text-sm text-amber-900">
                  <p class="font-medium"><%= error.message %></p>
                  <p class="mt-1 text-xs text-amber-800"><%= error.details %></p>
                </div>
              <% end %>
            </div>
          <% end %>
          <%= if @selected_agent do %>
            <div class="space-y-4 px-4 py-5 sm:px-6">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <div class="text-lg font-medium text-gray-900">
                    <%= agent_name(@selected_agent.config) %>
                  </div>
                  <div class="text-sm text-gray-500"><%= @selected_agent.behavior %></div>
                </div>
                <.status_badge status={@selected_agent.status} />
              </div>

              <dl class="grid grid-cols-1 gap-4 text-sm sm:grid-cols-2">
                <div>
                  <dt class="text-gray-500">Started</dt>
                  <dd class="mt-1 text-gray-900"><%= format_datetime(@selected_agent.started_at) %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">Stopped</dt>
                  <dd class="mt-1 text-gray-900"><%= format_datetime(@selected_agent.stopped_at) %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">Subscriptions</dt>
                  <dd class="mt-1 text-gray-900"><%= subscriptions_preview(@selected_agent.config) %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">Tools</dt>
                  <dd class="mt-1 text-gray-900"><%= tools_preview(@selected_agent.config) %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">Event Count</dt>
                  <dd class="mt-1 text-gray-900"><%= @inspection.event_count %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">Agent Spend</dt>
                  <dd class="mt-1 text-amber-700">
                    $<%= Float.round(@agent_spend.total_cost, 4) %>
                  </dd>
                </div>
                <%= if @selected_agent[:runtime] do %>
                  <div>
                    <dt class="text-gray-500">Process Memory</dt>
                    <dd class="mt-1 text-gray-900"><%= format_bytes(@selected_agent.runtime.memory_bytes) %></dd>
                  </div>
                  <div>
                    <dt class="text-gray-500">Mailbox</dt>
                    <dd class="mt-1 text-gray-900"><%= @selected_agent.runtime.message_queue_len %></dd>
                  </div>
                <% end %>
              </dl>

              <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                <div class="rounded-lg bg-amber-50 p-3">
                  <div class="text-xs font-medium uppercase tracking-wide text-amber-700">
                    Agent Spend
                  </div>
                  <dl class="mt-2 space-y-2 text-sm">
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

                <div class="rounded-lg bg-gray-50 p-3">
                  <div class="text-xs font-medium uppercase tracking-wide text-gray-500">
                    Config Snapshot
                  </div>
                  <pre class="mt-2 overflow-x-auto whitespace-pre-wrap break-all text-[11px] text-gray-700"><%= pretty_config(@selected_agent.config) %></pre>
                </div>
              </div>

              <div class="rounded-lg bg-gray-50 p-3">
                <div class="text-xs font-medium uppercase tracking-wide text-gray-500">Prompt</div>
                <p class="mt-2 whitespace-pre-wrap text-sm text-gray-800"><%= agent_prompt(@selected_agent.config) %></p>
              </div>

              <div class="flex flex-wrap gap-2">
                <button
                  type="button"
                  phx-click="edit_agent"
                  phx-value-id={@selected_agent.id}
                  class="inline-flex items-center rounded-md border border-gray-300 px-3 py-2 text-xs font-medium text-gray-700 hover:bg-gray-50"
                >
                  Edit Definition
                </button>
                <%= if @selected_agent.status in ["running", "degraded"] do %>
                  <button
                    type="button"
                    phx-click="stop_agent"
                    phx-value-id={@selected_agent.id}
                    class="inline-flex items-center rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs font-medium text-amber-800 hover:bg-amber-100"
                  >
                    Stop Agent
                  </button>
                <% else %>
                  <button
                    type="button"
                    phx-click="start_agent"
                    phx-value-id={@selected_agent.id}
                    class="inline-flex items-center rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs font-medium text-emerald-800 hover:bg-emerald-100"
                  >
                    Start Agent
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click="delete_agent"
                  phx-value-id={@selected_agent.id}
                  data-confirm="Delete this agent and all dependent records?"
                  class="inline-flex items-center rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs font-medium text-red-700 hover:bg-red-100"
                >
                  Delete Agent
                </button>
              </div>
            </div>
          <% else %>
            <div class="px-4 py-12 text-center text-gray-500">
              Select an agent to view details, inspect state, queued work, and logs.
            </div>
          <% end %>
        </div>
      </section>

      <%= if @selected_agent do %>
        <section class="grid grid-cols-1 gap-6 xl:grid-cols-3">
          <div class="overflow-hidden rounded-xl bg-white shadow">
            <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
              <h3 class="text-lg font-medium text-gray-900">Operator Console</h3>
              <p class="mt-1 text-sm text-gray-500">
                Send a direct message into the selected agent's runtime.
              </p>
            </div>
            <div class="px-4 py-5 sm:px-6">
              <form phx-submit="send_message" class="space-y-4">
                <div>
                  <label for="command_message" class="block text-sm font-medium text-gray-700">
                    Message
                  </label>
                  <textarea
                    id="command_message"
                    name="command[message]"
                    rows="4"
                    class="mt-1 block w-full rounded-md border-gray-300 text-sm shadow-sm"
                    placeholder="Summarize the last few events and tell me what needs attention."
                  ><%= @command["message"] %></textarea>
                </div>
                <div class="flex justify-end">
                  <button
                    type="submit"
                    disabled={@selected_agent.status not in ["running", "degraded"]}
                    class="inline-flex items-center rounded-md bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    Send Instruction
                  </button>
                </div>
              </form>
            </div>
          </div>

          <div class="overflow-hidden rounded-xl bg-white shadow">
            <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
              <h3 class="text-lg font-medium text-gray-900">Effect Queue</h3>
              <p class="mt-1 text-sm text-gray-500">
                Inspect pending and historical effects for this agent.
              </p>
            </div>
            <div class="space-y-3 px-4 py-5 sm:px-6">
              <div class="grid grid-cols-3 gap-2 text-xs">
                <.queue_metric title="Pending" value={@inspection.effect_counts.pending} />
                <.queue_metric title="Claimed" value={@inspection.effect_counts.claimed} />
                <.queue_metric
                  title="Failed"
                  value={@inspection.effect_counts.failed}
                  value_class="text-red-600"
                />
              </div>

              <div class="max-h-80 space-y-2 overflow-y-auto">
                <%= for effect <- @inspection.recent_effects do %>
                  <div class="rounded-lg border border-gray-200 p-3">
                    <div class="flex items-center justify-between gap-3">
                      <div class="text-sm font-medium text-gray-900"><%= effect.effect_type %></div>
                      <span class={effect_status_class(effect.status)}><%= effect.status %></span>
                    </div>
                    <div class="mt-1 text-xs text-gray-500">
                      attempts <%= effect.attempts %>
                      <span class="mx-1">•</span>
                      updated <%= format_time(effect.updated_at) %>
                    </div>
                    <div class="mt-2 rounded bg-gray-50 px-2 py-1 font-mono text-[11px] text-gray-600">
                      <%= effect_preview(effect) %>
                    </div>
                  </div>
                <% end %>
                <%= if @inspection.recent_effects == [] do %>
                  <p class="text-sm text-gray-500">No effects recorded yet.</p>
                <% end %>
              </div>
            </div>
          </div>

          <div class="overflow-hidden rounded-xl bg-white shadow">
            <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
              <h3 class="text-lg font-medium text-gray-900">Scheduled Jobs</h3>
              <p class="mt-1 text-sm text-gray-500">
                Wakeups, heartbeats, and checkpoints queued for this agent.
              </p>
            </div>
            <div class="space-y-3 px-4 py-5 sm:px-6">
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
                  <div class="rounded-lg border border-gray-200 p-3">
                    <div class="flex items-center justify-between gap-3">
                      <div class="text-sm font-medium text-gray-900"><%= job.job_type %></div>
                      <span class={job_status_class(job.status)}><%= job.status %></span>
                    </div>
                    <div class="mt-1 text-xs text-gray-500">
                      fire at <%= format_datetime(job.fire_at) %>
                      <span class="mx-1">•</span>
                      attempts <%= job.attempts %>
                    </div>
                    <div class="mt-2 rounded bg-gray-50 px-2 py-1 font-mono text-[11px] text-gray-600">
                      <%= payload_preview(job.payload) %>
                    </div>
                  </div>
                <% end %>
                <%= if @inspection.recent_jobs == [] do %>
                  <p class="text-sm text-gray-500">No scheduled jobs recorded yet.</p>
                <% end %>
              </div>
            </div>
          </div>
        </section>

        <section class="grid grid-cols-1 gap-6 xl:grid-cols-2">
          <div class="overflow-hidden rounded-xl bg-white shadow">
            <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
              <h3 class="text-lg font-medium text-gray-900">Recent Events</h3>
            </div>
            <div class="max-h-96 space-y-2 overflow-y-auto px-4 py-4 sm:px-6">
              <%= for event <- Enum.reverse(@events) do %>
                <div class="rounded border border-gray-200 p-3 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-medium text-indigo-600"><%= event.event_type %></span>
                    <span class="text-xs text-gray-400">#<%= event.sequence_num %></span>
                  </div>
                  <div class="mt-1 text-xs text-gray-500"><%= format_datetime(event.created_at) %></div>
                  <div class="mt-2 rounded bg-gray-50 px-2 py-1 font-mono text-[11px] text-gray-600">
                    <%= payload_preview(event.payload) %>
                  </div>
                </div>
              <% end %>
              <%= if @events == [] do %>
                <p class="text-sm text-gray-500">No events yet.</p>
              <% end %>
            </div>
          </div>

          <div class="overflow-hidden rounded-xl bg-slate-950 shadow">
            <div class="border-b border-slate-800 px-4 py-4 sm:px-6">
              <h3 class="text-lg font-medium text-slate-100">Agent Logs</h3>
              <p class="mt-1 text-sm text-slate-400">
                Raw log lines scoped to the selected agent's runtime metadata.
              </p>
            </div>
            <div class="max-h-96 overflow-y-auto px-4 py-4 font-mono text-[11px] leading-5 sm:px-6">
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
          </div>
        </section>
      <% end %>

      <section class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <div class="overflow-hidden rounded-xl bg-white shadow">
          <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
            <h3 class="text-lg font-medium leading-6 text-gray-900">Operational Logs</h3>
            <p class="mt-1 text-sm text-gray-500">
              Structured event activity across all agents.
            </p>
          </div>
          <div class="max-h-96 space-y-2 overflow-y-auto px-4 py-4 sm:px-6">
            <%= for activity <- @recent_activity do %>
              <div class="rounded border border-gray-100 p-3">
                <div class="flex items-center justify-between gap-3">
                  <div class="truncate text-sm font-medium text-indigo-600"><%= activity.event_type %></div>
                  <div class="text-xs text-gray-400"><%= format_time(activity.inserted_at) %></div>
                </div>
                <div class="mt-1 text-xs text-gray-500">
                  <span class="font-medium"><%= activity.behavior %></span>
                  <span class="mx-1">•</span>
                  <span class="font-mono"><%= short_id(activity.agent_id) %></span>
                </div>
                <div class="mt-2 break-all rounded bg-gray-50 px-2 py-1 font-mono text-[11px] text-gray-600">
                  <%= payload_preview(activity.payload) %>
                </div>
              </div>
            <% end %>
            <%= if @recent_activity == [] do %>
              <p class="text-sm text-gray-500">No activity yet.</p>
            <% end %>
          </div>
        </div>

        <div class="overflow-hidden rounded-xl bg-white shadow">
          <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
            <h3 class="text-lg font-medium leading-6 text-gray-900">Failures & Stale Work</h3>
            <p class="mt-1 text-sm text-gray-500">
              Failed effects and jobs that are dispatched for too long.
            </p>
          </div>
          <div class="max-h-96 space-y-2 overflow-y-auto px-4 py-4 sm:px-6">
            <%= for failure <- @recent_failures do %>
              <div class="rounded border border-red-100 bg-red-50/30 p-3">
                <div class="flex items-center justify-between gap-3">
                  <div class="truncate text-sm font-medium text-red-700">
                    <%= failure.type %> (<%= failure.source %>)
                  </div>
                  <div class="text-xs text-gray-500"><%= format_time(failure.inserted_at) %></div>
                </div>
                <div class="mt-1 text-xs text-gray-500">
                  <span class="font-medium"><%= failure.behavior %></span>
                  <span class="mx-1">•</span>
                  <span class="font-mono"><%= short_id(failure.agent_id) %></span>
                  <span class="mx-1">•</span>
                  <span class="font-medium"><%= failure.status %></span>
                  <span class="mx-1">•</span>
                  <span>attempts <%= failure.attempts %></span>
                </div>
                <div class="mt-2 break-all rounded bg-white px-2 py-1 font-mono text-[11px] text-gray-700">
                  <%= failure.details %>
                </div>
              </div>
            <% end %>
            <%= if @recent_failures == [] do %>
              <p class="text-sm text-gray-500">No failures detected.</p>
            <% end %>
          </div>
        </div>
      </section>

      <section class="overflow-hidden rounded-xl bg-slate-950 shadow">
        <div class="border-b border-slate-800 px-4 py-5 sm:px-6">
          <h3 class="text-lg font-medium leading-6 text-slate-100">Raw Logs</h3>
          <p class="mt-1 text-sm text-slate-400">
            Recent runtime logs captured in-app for live debugging and fleet-wide inspection.
          </p>
        </div>
        <div class="max-h-[32rem] overflow-y-auto px-4 py-4 font-mono text-[11px] leading-5 sm:px-6">
          <%= for log <- @recent_logs do %>
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
          <%= if @recent_logs == [] do %>
            <p class="text-sm text-slate-500">No logs captured yet.</p>
          <% end %>
        </div>
      </section>

      <section class="overflow-hidden rounded-xl bg-slate-950 shadow">
        <div class="border-b border-slate-800 px-4 py-5 sm:px-6">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 class="text-lg font-medium leading-6 text-slate-100">Fly.io Platform Logs</h3>
              <p class="mt-1 text-sm text-slate-400">
                App, machine, and runner logs fetched from Fly for full production troubleshooting.
              </p>
            </div>
            <button
              type="button"
              phx-click="refresh_fly_logs"
              class="inline-flex items-center rounded-md border border-slate-700 bg-slate-900 px-3 py-2 text-xs font-medium text-slate-100 hover:bg-slate-800"
            >
              Refresh Fly Logs
            </button>
          </div>
          <%= if @fly_logs.apps != [] do %>
            <div class="mt-3 flex flex-wrap gap-2">
              <%= for app <- @fly_logs.apps do %>
                <span class="rounded-full bg-slate-800 px-2.5 py-1 text-[11px] font-medium text-slate-300">
                  <%= app %>
                </span>
              <% end %>
            </div>
          <% end %>
        </div>
        <div class="max-h-[32rem] overflow-y-auto px-4 py-4 font-mono text-[11px] leading-5 sm:px-6">
          <%= for error <- @fly_logs.errors do %>
            <div class="mb-3 rounded-md border border-red-900 bg-red-950/50 px-3 py-2 text-red-200">
              <%= if error[:app] do %>
                <span class="mr-2 font-semibold"><%= error.app %></span>
              <% end %>
              <span><%= error.message %></span>
            </div>
          <% end %>

          <%= if not @fly_logs.available and @fly_logs.apps == [] do %>
            <p class="text-sm text-slate-500">
              Configure `FLY_API_TOKEN` and `FLY_LOG_APPS` to load Fly platform logs in-app.
            </p>
          <% else %>
            <%= if @fly_logs.logs == [] do %>
              <p class="text-sm text-slate-500">No Fly logs returned yet.</p>
            <% else %>
              <%= for log <- @fly_logs.logs do %>
                <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-slate-900 py-2">
                  <span class="text-slate-500"><%= format_log_timestamp(log.timestamp) %></span>
                  <span class={["font-semibold uppercase tracking-wide", log_level_class(log.level)]}>
                    <%= log.level %>
                  </span>
                  <div class="min-w-0">
                    <%= if metadata = fly_log_metadata_preview(log) do %>
                      <span class="mr-2 text-slate-500"><%= metadata %></span>
                    <% end %>
                    <span class="break-words whitespace-pre-wrap text-slate-100"><%= log.message %></span>
                  </div>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
      </section>
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
             |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} created")
             |> push_patch(to: "/dashboard?id=#{agent.id}")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, launch: launch, launch_error: message)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to create agent: #{changeset_errors(changeset)}"
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to create agent: #{inspect(reason)}"
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
             |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} updated")
             |> push_patch(to: "/dashboard?id=#{agent.id}")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, launch: launch, launch_error: message)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to update agent: #{changeset_errors(changeset)}"
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to update agent: #{inspect(reason)}"
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
         |> put_flash(:info, "Message accepted by agent")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

      {:error, :agent_stopped} ->
        {:noreply, put_flash(socket, :error, "Agent is not running")}

      {:error, :mailbox_full} ->
        {:noreply, put_flash(socket, :error, "Agent mailbox is full")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send message: #{inspect(reason)}")}
    end
  end

  defp refresh_dashboard(socket, opts \\ []) do
    socket =
      socket
      |> refresh_connections()
      |> refresh_insights()

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
  end

  defp refresh_insights(socket) do
    assign(socket, :insights, Insights.list_open_for_user(current_user_id(socket), limit: 20))
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

  defp launch_params_from_agent(agent), do: AgentBuilder.launch_params_from_agent(agent)

  defp normalize_launch_params(params), do: AgentBuilder.normalize_launch_params(params)

  defp build_agent_start_params(launch, user_id),
    do: AgentBuilder.build_start_params(launch, user_id)

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

  defp launch_title(:edit), do: "Edit Agent"
  defp launch_title(_), do: "Build Agent"

  defp launch_subtitle(:edit),
    do: "Update a definition. Running agents are restarted with the new config."

  defp launch_subtitle(_),
    do:
      "Use the dedicated builder for clearer inputs, outputs, permissions, and suggested defaults."

  defp launch_submit_label(:edit), do: "Save Changes"
  defp launch_submit_label(_), do: "Create Agent"

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
        assign(socket, fly_logs: snapshot)

      {:error, reason} ->
        assign(socket,
          fly_logs: %{
            available: false,
            apps: [],
            logs: [],
            next_tokens: %{},
            errors: [%{app: nil, message: "Failed to fetch Fly logs: #{inspect(reason)}"}]
          }
        )
    end
  end

  defp refresh_connections(socket) do
    case Connections.safe_dashboard_snapshot(
           socket.assigns.connection_user_id,
           return_to: connection_return_to(socket)
         ) do
      {:ok, snapshot} ->
        assign(socket,
          connections: snapshot.providers,
          raw_connections: snapshot.raw_tokens,
          connection_errors: snapshot.errors
        )

      {:degraded, snapshot} ->
        assign(socket,
          connections: snapshot.providers,
          raw_connections: snapshot.raw_tokens,
          connection_errors: snapshot.errors
        )
    end
  end

  defp apply_dashboard_params(socket, params, uri) do
    user_id = current_user_id(socket)

    socket =
      assign(socket,
        connection_user_id: user_id,
        connection_return_to: connection_return_to_from_uri(uri)
      )

    socket
    |> refresh_connections()
    |> maybe_put_oauth_flash(params)
  end

  defp maybe_put_oauth_flash(socket, %{"oauth_status" => "connected", "oauth_message" => message})
       when is_binary(message) do
    put_flash(socket, :info, message)
  end

  defp maybe_put_oauth_flash(socket, %{"oauth_status" => "error", "oauth_message" => message})
       when is_binary(message) do
    put_flash(socket, :error, message)
  end

  defp maybe_put_oauth_flash(socket, _params), do: socket

  defp connection_return_to(socket) do
    socket.assigns.connection_return_to || "/dashboard"
  end

  defp connection_home_path(socket, _user_id) do
    socket.assigns.connection_return_to
    |> URI.parse()
    |> then(fn uri -> %URI{uri | query: home_query(uri.query)} end)
    |> URI.to_string()
  rescue
    _ -> "/dashboard"
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

  defp home_query(query) do
    (query || "")
    |> URI.decode_query()
    |> Map.drop(["id"])
    |> URI.encode_query()
  end

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp agent_owned_by_current_user?(socket, agent_id) when is_binary(agent_id) do
    not is_nil(Agents.get_agent_for_user(agent_id, current_user_id(socket)))
  end

  defp agent_owned_by_current_user?(_socket, _agent_id), do: false

  defp provider_label("google"), do: "Google"
  defp provider_label("github"), do: "GitHub"
  defp provider_label("slack"), do: "Slack"
  defp provider_label("telegram"), do: "Telegram"
  defp provider_label("linear"), do: "Linear"
  defp provider_label("notion"), do: "Notion"
  defp provider_label(provider), do: provider

  defp insight_category_label("reply_urgent"), do: "Reply Needed"
  defp insight_category_label("tone_risk"), do: "Tone Risk"
  defp insight_category_label("event_important"), do: "Important Event"
  defp insight_category_label("event_prep_needed"), do: "Prep Needed"
  defp insight_category_label("commitment_unresolved"), do: "Commitment Due"
  defp insight_category_label("meeting_follow_up"), do: "Meeting Follow-Up"
  defp insight_category_label("product_opportunity"), do: "Roadmap"
  defp insight_category_label(_), do: "Insight"

  defp insight_category_class("reply_urgent"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-800"

  defp insight_category_class("tone_risk"),
    do: "rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700"

  defp insight_category_class("event_important"),
    do: "rounded-full bg-indigo-100 px-2 py-0.5 text-xs font-medium text-indigo-700"

  defp insight_category_class("event_prep_needed"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp insight_category_class("commitment_unresolved"),
    do: "rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700"

  defp insight_category_class("meeting_follow_up"),
    do: "rounded-full bg-sky-100 px-2 py-0.5 text-xs font-medium text-sky-700"

  defp insight_category_class("product_opportunity"),
    do: "rounded-full bg-cyan-100 px-2 py-0.5 text-xs font-medium text-cyan-800"

  defp insight_category_class(_),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp insight_priority_class(priority) when is_integer(priority) and priority >= 80,
    do: "rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700"

  defp insight_priority_class(priority) when is_integer(priority) and priority >= 60,
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp insight_priority_class(_),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp format_confidence(value) when is_float(value), do: "#{Float.round(value * 100, 0)}%"
  defp format_confidence(value) when is_integer(value), do: "#{value}%"
  defp format_confidence(_), do: "n/a"

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
    do: "rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700"

  defp effect_status_class("completed"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700"

  defp effect_status_class("claimed"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp effect_status_class(_),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp job_status_class("cancelled"),
    do: "rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700"

  defp job_status_class("delivered"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700"

  defp job_status_class("dispatched"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp job_status_class(_),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp health_badge_class(:healthy), do: "bg-green-100 text-green-800"
  defp health_badge_class(:unhealthy), do: "bg-red-100 text-red-800"
  defp health_badge_class(_), do: "bg-gray-100 text-gray-700"

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: "text-gray-900"

  defp stat_card(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
      <dt class="truncate text-sm font-medium text-gray-500"><%= @title %></dt>
      <dd class={"mt-1 text-3xl font-semibold tracking-tight #{@value_class}"}><%= @value %></dd>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: "text-gray-900"

  defp queue_metric(assigns) do
    ~H"""
    <div class="rounded bg-gray-50 p-2">
      <div class="text-gray-500"><%= @title %></div>
      <div class={"text-sm font-semibold #{@value_class}"}><%= @value %></div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :string, default: "font-medium text-gray-900"

  defp health_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <dt class="text-gray-500"><%= @label %></dt>
      <dd class={@value_class}><%= @value %></dd>
    </div>
    """
  end

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
      _ -> "text-slate-300"
    end
  end

  defp log_level_class(_), do: "text-slate-300"

  defp log_metadata_preview(metadata) when metadata in [%{}, nil], do: nil

  defp log_metadata_preview(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
    |> truncate(120)
  end

  defp log_metadata_preview(_), do: nil

  defp fly_log_metadata_preview(%{app: app, metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.put_new("app", app)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
    |> truncate(140)
  end

  defp fly_log_metadata_preview(_), do: nil

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

  defp format_uptime(_), do: "n/a"

  defp format_time(nil), do: "N/A"

  defp format_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_time(dt)
      _ -> datetime
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_bytes(nil), do: "N/A"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
end
