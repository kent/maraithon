defmodule MaraithonWeb.DashboardLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Agents
  alias Maraithon.Runtime
  alias Maraithon.Spend

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    agents = Agents.list_agents()
    total_spend = Spend.get_total_spend()

    {:ok, assign(socket,
      agents: agents,
      selected_agent: nil,
      events: [],
      total_spend: total_spend,
      agent_spend: nil,
      page_title: "Dashboard"
    )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Runtime.get_agent_status(id) do
      {:ok, agent_status} ->
        {:ok, events} = Runtime.get_events(id, limit: 50)
        agent_spend = Spend.get_agent_spend(id)
        {:noreply, assign(socket,
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
    {:noreply, assign(socket, selected_agent: nil, events: [], agent_spend: nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    agents = Agents.list_agents()
    total_spend = Spend.get_total_spend()

    socket = assign(socket, agents: agents, total_spend: total_spend)

    socket =
      if socket.assigns.selected_agent do
        case Runtime.get_agent_status(socket.assigns.selected_agent.id) do
          {:ok, agent_status} ->
            {:ok, events} = Runtime.get_events(socket.assigns.selected_agent.id, limit: 50)
            agent_spend = Spend.get_agent_spend(socket.assigns.selected_agent.id)
            assign(socket, selected_agent: agent_status, events: events, agent_spend: agent_spend)

          {:error, :not_found} ->
            assign(socket, selected_agent: nil, events: [], agent_spend: nil)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Stats overview -->
      <div class="grid grid-cols-1 gap-5 sm:grid-cols-4">
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Total Agents</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-gray-900"><%= length(@agents) %></dd>
        </div>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">Running</dt>
          <dd class="mt-1 text-3xl font-semibold tracking-tight text-green-600">
            <%= Enum.count(@agents, & &1.status == "running") %>
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
      </div>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <!-- Agents list -->
        <div class="overflow-hidden rounded-lg bg-white shadow">
          <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
            <h3 class="text-lg font-medium leading-6 text-gray-900">Agents</h3>
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
                      <div class="flex items-center">
                        <p class="truncate text-sm font-medium text-indigo-600">
                          <%= agent.behavior %>
                        </p>
                        <.status_badge status={agent.status} />
                      </div>
                      <div class="ml-2 flex flex-shrink-0">
                        <p class="text-xs text-gray-500">
                          <%= String.slice(agent.id, 0, 8) %>...
                        </p>
                      </div>
                    </div>
                    <div class="mt-2 sm:flex sm:justify-between">
                      <div class="sm:flex">
                        <p class="flex items-center text-sm text-gray-500">
                          Started <%= format_time(agent.started_at) %>
                        </p>
                      </div>
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

        <!-- Agent detail / Events -->
        <div class="overflow-hidden rounded-lg bg-white shadow">
          <%= if @selected_agent do %>
            <div class="border-b border-gray-200 bg-white px-4 py-5 sm:px-6">
              <div class="flex items-center justify-between">
                <h3 class="text-lg font-medium leading-6 text-gray-900">
                  Agent Details
                </h3>
                <.status_badge status={@selected_agent.status} />
              </div>
            </div>
            <div class="px-4 py-5 sm:px-6">
              <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
                <div>
                  <dt class="text-sm font-medium text-gray-500">ID</dt>
                  <dd class="mt-1 text-sm text-gray-900 font-mono"><%= @selected_agent.id %></dd>
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
                    <dd class="mt-1 text-sm text-gray-900"><%= format_bytes(@selected_agent.runtime.memory_bytes) %></dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-gray-500">Queue Length</dt>
                    <dd class="mt-1 text-sm text-gray-900"><%= @selected_agent.runtime.message_queue_len %></dd>
                  </div>
                <% end %>
              </dl>

              <div class="mt-6">
                <h4 class="text-sm font-medium text-gray-500 mb-2">Budget</h4>
                <div class="flex gap-4">
                  <div class="text-sm">
                    <span class="text-gray-500">LLM Calls:</span>
                    <span class="font-medium"><%= @selected_agent.config["budget"]["llm_calls"] %></span>
                  </div>
                  <div class="text-sm">
                    <span class="text-gray-500">Tool Calls:</span>
                    <span class="font-medium"><%= @selected_agent.config["budget"]["tool_calls"] %></span>
                  </div>
                </div>
              </div>

              <%= if @agent_spend do %>
              <div class="mt-6">
                <h4 class="text-sm font-medium text-gray-500 mb-2">Agent Spend</h4>
                <div class="grid grid-cols-2 gap-4">
                  <div class="text-sm">
                    <span class="text-gray-500">LLM Calls:</span>
                    <span class="font-medium"><%= @agent_spend.llm_calls %></span>
                  </div>
                  <div class="text-sm">
                    <span class="text-gray-500">Total Cost:</span>
                    <span class="font-medium text-amber-600">$<%= Float.round(@agent_spend.total_cost, 4) %></span>
                  </div>
                  <div class="text-sm">
                    <span class="text-gray-500">Input Tokens:</span>
                    <span class="font-medium"><%= @agent_spend.input_tokens %></span>
                  </div>
                  <div class="text-sm">
                    <span class="text-gray-500">Output Tokens:</span>
                    <span class="font-medium"><%= @agent_spend.output_tokens %></span>
                  </div>
                </div>
              </div>
              <% end %>

              <!-- Events -->
              <div class="mt-6">
                <h4 class="text-sm font-medium text-gray-500 mb-2">Recent Events (<%= length(@events) %>)</h4>
                <div class="max-h-64 overflow-y-auto space-y-2">
                  <%= for event <- Enum.reverse(@events) do %>
                    <div class="rounded bg-gray-50 p-2 text-xs">
                      <div class="flex justify-between">
                        <span class="font-medium text-indigo-600"><%= event.event_type %></span>
                        <span class="text-gray-400">#<%= event.sequence_num %></span>
                      </div>
                      <div class="text-gray-500 mt-1"><%= format_time(event.created_at) %></div>
                    </div>
                  <% end %>
                  <%= if @events == [] do %>
                    <p class="text-gray-400 text-sm">No events yet</p>
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
      </div>
    </div>
    """
  end

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
