defmodule MaraithonWeb.DashboardLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Admin
  alias Maraithon.Agents
  alias Maraithon.Behaviors
  alias Maraithon.Runtime
  alias Maraithon.Spend

  @refresh_interval 5_000
  @event_limit 50
  @activity_limit 40
  @failure_limit 20

  @default_prompt "You are a helpful assistant that watches for events and responds thoughtfully."
  @default_tools "read_file,search_files,http_get"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    socket =
      socket
      |> assign(
        page_title: "Dashboard",
        behaviors: Behaviors.list() |> Enum.sort(),
        launch: default_launch_params(),
        launch_error: nil,
        agents: [],
        selected_agent: nil,
        events: [],
        total_spend: empty_spend(),
        agent_spend: nil,
        health: %{status: :unknown, checks: %{agents: %{running: 0, degraded: 0, stopped: 0}}},
        queue_metrics: %{
          effects: %{pending: 0, claimed: 0, completed: 0, failed: 0},
          jobs: %{pending: 0, dispatched: 0, delivered: 0, cancelled: 0}
        },
        recent_activity: [],
        recent_failures: []
      )
      |> refresh_dashboard()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Runtime.get_agent_status(id) do
      {:ok, agent_status} ->
        {:ok, events} = Runtime.get_events(id, limit: @event_limit)
        agent_spend = Spend.get_agent_spend(id)

        {:noreply,
         assign(socket,
           selected_agent: agent_status,
           events: events,
           agent_spend: agent_spend,
           page_title: "Agent #{String.slice(id, 0, 8)}"
         )}

      {:error, :not_found} ->
        {:noreply, push_navigate(socket, to: "/")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       selected_agent: nil,
       events: [],
       agent_spend: nil,
       page_title: "Dashboard"
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_dashboard(socket)}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    {:noreply, socket |> refresh_dashboard() |> put_flash(:info, "Dashboard refreshed")}
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    case Runtime.stop_agent(id, "stopped_from_admin") do
      {:ok, _} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:info, "Agent stopped")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("launch_agent", %{"launch" => params}, socket) do
    launch = normalize_launch_params(params)

    with {:ok, start_params} <- build_agent_start_params(launch),
         {:ok, agent} <- Runtime.start_agent(start_params) do
      {:noreply,
       socket
       |> assign(launch: default_launch_params(), launch_error: nil)
       |> refresh_dashboard()
       |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} launched")
       |> push_patch(to: "/?id=#{agent.id}")}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, launch: launch, launch_error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to launch agent: #{changeset_errors(changeset)}"
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to launch agent: #{inspect(reason)}"
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <section class="flex flex-wrap items-center justify-between gap-4 rounded-lg bg-white p-4 shadow">
        <div>
          <h1 class="text-2xl font-semibold text-gray-900">Dashboard</h1>
          <p class="text-sm text-gray-500">
            Launch agents, monitor runtime behavior, and track operational health.
          </p>
        </div>
        <button
          type="button"
          phx-click="refresh_now"
          class="inline-flex items-center rounded-md border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
        >
          Refresh Now
        </button>
      </section>

      <section class="grid grid-cols-1 gap-5 sm:grid-cols-2 xl:grid-cols-6">
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Total Agents</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-gray-900"><%= length(@agents) %></dd>
        </div>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Running</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-green-600">
            <%= Enum.count(@agents, &(&1.status == "running")) %>
          </dd>
        </div>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Degraded</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-amber-600">
            <%= Enum.count(@agents, &(&1.status == "degraded")) %>
          </dd>
        </div>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">LLM Calls</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-indigo-600">
            <%= @total_spend.llm_calls %>
          </dd>
        </div>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Total Spend</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-amber-600">
            $<%= Float.round(@total_spend.total_cost, 4) %>
          </dd>
        </div>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Pending Effects</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-gray-900">
            <%= @queue_metrics.effects.pending %>
          </dd>
        </div>
      </section>

      <section class="grid grid-cols-1 gap-6 xl:grid-cols-5">
        <div class="overflow-hidden rounded-lg bg-white shadow xl:col-span-3">
          <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
            <h2 class="text-lg font-medium text-gray-900">Launch Agent</h2>
            <p class="mt-1 text-sm text-gray-500">
              Create a new long-running agent process directly from the admin UI.
            </p>
          </div>
          <div class="px-4 py-5 sm:px-6">
            <%= if @launch_error do %>
              <div class="mb-4 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                <%= @launch_error %>
              </div>
            <% end %>

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
                  rows="3"
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
                    placeholder="github:owner/repo,email:user@example.com"
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
                  Advanced Config JSON (optional)
                </label>
                <textarea
                  id="launch_config_json"
                  name="launch[config_json]"
                  rows="3"
                  class="mt-1 block w-full rounded-md border-gray-300 text-sm font-mono shadow-sm"
                  placeholder={"{\"custom_key\":\"value\"}"}
                ><%= @launch["config_json"] %></textarea>
              </div>

              <div class="flex justify-end">
                <button
                  type="submit"
                  class="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500"
                >
                  Launch Agent
                </button>
              </div>
            </form>
          </div>
        </div>

        <div class="overflow-hidden rounded-lg bg-white shadow xl:col-span-2">
          <div class="border-b border-gray-200 px-4 py-4 sm:px-6">
            <h2 class="text-lg font-medium text-gray-900">Health & Monitoring</h2>
          </div>
          <div class="space-y-6 px-4 py-5 sm:px-6">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-500">System Status</span>
              <span class={"inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium #{health_badge_class(@health.status)}"}>
                <%= @health.status %>
              </span>
            </div>

            <dl class="space-y-2 text-sm">
              <div class="flex items-center justify-between">
                <dt class="text-gray-500">Database</dt>
                <dd class={if @health.checks.database == :ok, do: "text-green-600 font-medium", else: "text-red-600 font-medium"}>
                  <%= @health.checks.database %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-gray-500">Memory</dt>
                <dd class="font-medium text-gray-900"><%= @health.checks.memory_mb %> MB</dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-gray-500">Uptime</dt>
                <dd class="font-medium text-gray-900"><%= format_uptime(@health.checks.uptime_seconds) %></dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-gray-500">Version</dt>
                <dd class="font-mono text-xs text-gray-900"><%= @health.version %></dd>
              </div>
            </dl>

            <div>
              <h3 class="text-sm font-medium text-gray-700">Queue Metrics</h3>
              <div class="mt-2 grid grid-cols-2 gap-2 text-xs">
                <div class="rounded bg-gray-50 p-2">
                  <div class="text-gray-500">Effects Pending</div>
                  <div class="text-sm font-semibold text-gray-900"><%= @queue_metrics.effects.pending %></div>
                </div>
                <div class="rounded bg-gray-50 p-2">
                  <div class="text-gray-500">Effects Failed</div>
                  <div class="text-sm font-semibold text-red-600"><%= @queue_metrics.effects.failed %></div>
                </div>
                <div class="rounded bg-gray-50 p-2">
                  <div class="text-gray-500">Jobs Pending</div>
                  <div class="text-sm font-semibold text-gray-900"><%= @queue_metrics.jobs.pending %></div>
                </div>
                <div class="rounded bg-gray-50 p-2">
                  <div class="text-gray-500">Jobs Dispatched</div>
                  <div class="text-sm font-semibold text-amber-600"><%= @queue_metrics.jobs.dispatched %></div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div class="overflow-hidden rounded-lg bg-white shadow">
          <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
            <h2 class="text-lg font-medium text-gray-900">Agents</h2>
          </div>
          <ul role="list" class="divide-y divide-gray-200">
            <%= for agent <- @agents do %>
              <li>
                <.link
                  patch={"/?id=#{agent.id}"}
                  class={"block hover:bg-gray-50 #{if @selected_agent && @selected_agent.id == agent.id, do: "bg-indigo-50", else: ""}"}
                >
                  <div class="px-4 py-4 sm:px-6">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <p class="truncate text-sm font-medium text-indigo-600">
                          <%= agent.behavior %>
                        </p>
                        <.status_badge status={agent.status} />
                      </div>
                      <div class="text-xs text-gray-500 font-mono">
                        <%= short_id(agent.id) %>
                      </div>
                    </div>
                    <div class="mt-2 text-sm text-gray-500">
                      Started <%= format_time(agent.started_at) %>
                    </div>
                  </div>
                </.link>
              </li>
            <% end %>
            <%= if @agents == [] do %>
              <li class="px-4 py-8 text-center text-gray-500">
                No agents yet. Create one via the API.
              </li>
            <% end %>
          </ul>
        </div>

        <div class="overflow-hidden rounded-lg bg-white shadow">
          <%= if @selected_agent do %>
            <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
              <div class="flex items-center justify-between gap-3">
                <h3 class="text-lg font-medium leading-6 text-gray-900">Agent Details</h3>
                <div class="flex items-center gap-2">
                  <.status_badge status={@selected_agent.status} />
                  <button
                    type="button"
                    phx-click="stop_agent"
                    phx-value-id={@selected_agent.id}
                    disabled={@selected_agent.status not in ["running", "degraded"]}
                    class="inline-flex items-center rounded-md border border-red-200 bg-red-50 px-3 py-1.5 text-xs font-medium text-red-700 hover:bg-red-100 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    Stop
                  </button>
                </div>
              </div>
            </div>
            <div class="space-y-6 px-4 py-5 sm:px-6">
              <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
                <div>
                  <dt class="text-sm font-medium text-gray-500">ID</dt>
                  <dd class="mt-1 font-mono text-xs text-gray-900 break-all"><%= @selected_agent.id %></dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-gray-500">Behavior</dt>
                  <dd class="mt-1 text-sm text-gray-900"><%= @selected_agent.behavior %></dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-gray-500">Started</dt>
                  <dd class="mt-1 text-sm text-gray-900"><%= format_datetime(@selected_agent.started_at) %></dd>
                </div>
                <%= if @selected_agent[:runtime] do %>
                  <div>
                    <dt class="text-sm font-medium text-gray-500">Memory</dt>
                    <dd class="mt-1 text-sm text-gray-900">
                      <%= format_bytes(@selected_agent.runtime.memory_bytes) %>
                    </dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-gray-500">Queue Length</dt>
                    <dd class="mt-1 text-sm text-gray-900">
                      <%= @selected_agent.runtime.message_queue_len %>
                    </dd>
                  </div>
                <% end %>
              </dl>

              <div>
                <h4 class="text-sm font-medium text-gray-500">Budget</h4>
                <% budget = @selected_agent.config["budget"] || %{} %>
                <div class="mt-2 flex gap-4 text-sm">
                  <div>
                    <span class="text-gray-500">LLM Calls:</span>
                    <span class="font-medium"><%= budget["llm_calls"] || "n/a" %></span>
                  </div>
                  <div>
                    <span class="text-gray-500">Tool Calls:</span>
                    <span class="font-medium"><%= budget["tool_calls"] || "n/a" %></span>
                  </div>
                </div>
              </div>

              <%= if @agent_spend do %>
                <div>
                  <h4 class="text-sm font-medium text-gray-500">Agent Spend</h4>
                  <div class="mt-2 grid grid-cols-2 gap-4 text-sm">
                    <div>
                      <span class="text-gray-500">LLM Calls:</span>
                      <span class="font-medium"><%= @agent_spend.llm_calls %></span>
                    </div>
                    <div>
                      <span class="text-gray-500">Total Cost:</span>
                      <span class="font-medium text-amber-600">
                        $<%= Float.round(@agent_spend.total_cost, 4) %>
                      </span>
                    </div>
                    <div>
                      <span class="text-gray-500">Input Tokens:</span>
                      <span class="font-medium"><%= @agent_spend.input_tokens %></span>
                    </div>
                    <div>
                      <span class="text-gray-500">Output Tokens:</span>
                      <span class="font-medium"><%= @agent_spend.output_tokens %></span>
                    </div>
                  </div>
                </div>
              <% end %>

              <div>
                <h4 class="mb-2 text-sm font-medium text-gray-500">
                  Recent Events (<%= length(@events) %>)
                </h4>
                <div class="max-h-64 space-y-2 overflow-y-auto">
                  <%= for event <- Enum.reverse(@events) do %>
                    <div class="rounded bg-gray-50 p-2 text-xs">
                      <div class="flex items-center justify-between">
                        <span class="font-medium text-indigo-600"><%= event.event_type %></span>
                        <span class="text-gray-400">#<%= event.sequence_num %></span>
                      </div>
                      <div class="mt-1 text-gray-500"><%= format_time(event.created_at) %></div>
                    </div>
                  <% end %>
                  <%= if @events == [] do %>
                    <p class="text-sm text-gray-400">No events yet</p>
                  <% end %>
                </div>
              </div>
            </div>
          <% else %>
            <div class="px-4 py-12 text-center text-gray-500">
              Select an agent to view details
            </div>
          <% end %>
        </div>
      </section>

      <section class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <div class="overflow-hidden rounded-lg bg-white shadow">
          <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
            <h3 class="text-lg font-medium leading-6 text-gray-900">Operational Logs</h3>
            <p class="mt-1 text-sm text-gray-500">Most recent events across all agents.</p>
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

        <div class="overflow-hidden rounded-lg bg-white shadow">
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
    </div>
    """
  end

  defp refresh_dashboard(socket) do
    agents = Agents.list_agents()
    total_spend = Spend.get_total_spend()

    snapshot =
      Admin.dashboard_snapshot(activity_limit: @activity_limit, failure_limit: @failure_limit)

    socket =
      assign(socket,
        agents: agents,
        total_spend: total_spend,
        health: snapshot.health,
        queue_metrics: snapshot.queue_metrics,
        recent_activity: snapshot.recent_activity,
        recent_failures: snapshot.recent_failures
      )

    if socket.assigns.selected_agent do
      refresh_selected_agent(socket, socket.assigns.selected_agent.id)
    else
      socket
    end
  end

  defp refresh_selected_agent(socket, id) do
    case Runtime.get_agent_status(id) do
      {:ok, agent_status} ->
        {:ok, events} = Runtime.get_events(id, limit: @event_limit)
        agent_spend = Spend.get_agent_spend(id)
        assign(socket, selected_agent: agent_status, events: events, agent_spend: agent_spend)

      {:error, :not_found} ->
        assign(socket, selected_agent: nil, events: [], agent_spend: nil, page_title: "Dashboard")
    end
  end

  defp default_launch_params do
    %{
      "behavior" => "prompt_agent",
      "name" => "",
      "prompt" => @default_prompt,
      "subscriptions" => "",
      "tools" => @default_tools,
      "memory_limit" => "50",
      "budget_llm_calls" => "500",
      "budget_tool_calls" => "1000",
      "config_json" => ""
    }
  end

  defp normalize_launch_params(params) do
    defaults = default_launch_params()

    Enum.reduce(defaults, %{}, fn {key, default}, acc ->
      value =
        case Map.get(params, key, default) do
          nil -> default
          value -> to_string(value)
        end

      Map.put(acc, key, String.trim(value))
    end)
  end

  defp build_agent_start_params(launch) do
    behavior = launch["behavior"]

    cond do
      behavior == "" ->
        {:error, "Behavior is required"}

      not Behaviors.exists?(behavior) ->
        {:error, "Unknown behavior: #{behavior}"}

      true ->
        with {:ok, memory_limit} <-
               parse_positive_integer(launch["memory_limit"], "Memory limit"),
             {:ok, llm_calls} <-
               parse_positive_integer(launch["budget_llm_calls"], "LLM call budget"),
             {:ok, tool_calls} <-
               parse_positive_integer(launch["budget_tool_calls"], "Tool call budget"),
             {:ok, extra_config} <- parse_optional_config_json(launch["config_json"]) do
          name =
            if launch["name"] == "",
              do: "#{behavior}-#{System.unique_integer([:positive])}",
              else: launch["name"]

          config =
            %{
              "name" => name,
              "prompt" => launch["prompt"],
              "subscribe" => parse_csv(launch["subscriptions"]),
              "tools" => parse_csv(launch["tools"]),
              "memory_limit" => memory_limit
            }
            |> Map.merge(extra_config)

          {:ok,
           %{
             "behavior" => behavior,
             "config" => config,
             "budget" => %{"llm_calls" => llm_calls, "tool_calls" => tool_calls}
           }}
        end
    end
  end

  defp parse_positive_integer(value, field_name) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be a positive integer"}
    end
  end

  defp parse_optional_config_json(""), do: {:ok, %{}}

  defp parse_optional_config_json(json) do
    case Jason.decode(json) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      {:ok, _} ->
        {:error, "Advanced config JSON must decode to an object"}

      {:error, _} ->
        {:error, "Advanced config JSON is invalid"}
    end
  end

  defp parse_csv(""), do: []

  defp parse_csv(values) when is_binary(values) do
    values
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

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

  defp health_badge_class(:healthy), do: "bg-green-100 text-green-800"
  defp health_badge_class(:unhealthy), do: "bg-red-100 text-red-800"
  defp health_badge_class(_), do: "bg-gray-100 text-gray-700"

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

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_bytes(nil), do: "N/A"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
end
