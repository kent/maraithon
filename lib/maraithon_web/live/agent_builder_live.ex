defmodule MaraithonWeb.AgentBuilderLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AgentBuilder
  alias Maraithon.Connections
  alias Maraithon.Runtime
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @tool_provider_requirements %{
    "gmail_get_message" => %{provider: "google", service: "gmail", label: "Google Gmail"},
    "gmail_list_recent" => %{provider: "google", service: "gmail", label: "Google Gmail"},
    "gmail_search" => %{provider: "google", service: "gmail", label: "Google Gmail"},
    "google_calendar_list_events" => %{
      provider: "google",
      service: "calendar",
      label: "Google Calendar"
    },
    "github_create_issue_comment" => %{provider: "github", label: "GitHub"},
    "slack_post_message" => %{provider: "slack", service: "channels", label: "Slack Channels"},
    "slack_list_conversations" => %{
      provider: "slack",
      service: "channels",
      label: "Slack Channels"
    },
    "slack_list_messages" => %{provider: "slack", service: "channels", label: "Slack Channels"},
    "slack_get_thread_replies" => %{
      provider: "slack",
      service: "channels",
      label: "Slack Channels"
    },
    "slack_search_messages" => %{provider: "slack", service: "dms", label: "Slack DMs"},
    "linear_create_comment" => %{provider: "linear", label: "Linear"},
    "linear_create_issue" => %{provider: "linear", label: "Linear"},
    "linear_update_issue_state" => %{provider: "linear", label: "Linear"}
  }

  @path_tools MapSet.new(["file_tree", "list_files", "read_file", "search_files"])

  @impl true
  def mount(_params, _session, socket) do
    user_id = current_user_id(socket)
    {providers, connection_errors} = load_providers(user_id)
    launch = AgentBuilder.default_launch_params()

    socket =
      socket
      |> assign(
        page_title: "Build Agent",
        current_path: "/agents/new",
        behavior_specs: AgentBuilder.behavior_specs(),
        provider_map: providers,
        connection_errors: connection_errors,
        tool_allowed_paths: RuntimeConfig.tool_allowed_paths(),
        builder_error: nil
      )
      |> assign_builder_state(launch)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    behavior = Map.get(params, "behavior")
    current_behavior = socket.assigns.launch["behavior"]

    launch =
      cond do
        is_binary(behavior) and behavior != current_behavior ->
          AgentBuilder.launch_params_for_behavior(behavior)

        true ->
          socket.assigns.launch
      end

    {:noreply,
     socket
     |> assign(:current_path, current_path_from_uri(uri))
     |> assign(:builder_error, nil)
     |> assign_builder_state(launch)}
  end

  @impl true
  def handle_event("choose_behavior", %{"behavior" => behavior}, socket) do
    {:noreply, push_patch(socket, to: ~p"/agents/new?behavior=#{behavior}")}
  end

  def handle_event("update_launch", %{"launch" => params}, socket) do
    launch = AgentBuilder.normalize_launch_params(params)
    {:noreply, socket |> assign(:builder_error, nil) |> assign_builder_state(launch)}
  end

  def handle_event("create_agent", %{"launch" => params}, socket) do
    launch = AgentBuilder.normalize_launch_params(params)
    blockers = launch_blockers(launch, socket)

    with [] <- blockers,
         {:ok, start_params} <- AgentBuilder.build_start_params(launch, current_user_id(socket)),
         {:ok, agent} <- Runtime.start_agent(start_params) do
      {:noreply,
       socket
       |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} created")
       |> push_navigate(to: "/dashboard?id=#{agent.id}")}
    else
      [_ | _] = blocking_items ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, blocker_message(blocking_items))}

      {:error, message} when is_binary(message) ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, "Failed to create agent: #{changeset_errors(changeset)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, "Failed to create agent: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <section class="overflow-hidden rounded-[2rem] bg-[radial-gradient(circle_at_top_left,_rgba(129,140,248,0.22),_transparent_30%),linear-gradient(135deg,_#0f172a,_#172554_58%,_#1d4ed8)] px-6 py-7 text-white shadow-xl">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="max-w-3xl">
              <p class="text-xs font-semibold uppercase tracking-[0.3em] text-indigo-200">
                Agent Builder
              </p>
              <h1 class="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">Create an agent with a clear contract</h1>
              <p class="mt-3 max-w-2xl text-sm text-slate-200 sm:text-base">
                Pick a template, review exactly what goes in and what comes out, confirm the required permissions, then launch it. New agents start running immediately after creation.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <a
                href={~p"/connectors"}
                class="inline-flex items-center rounded-full border border-white/20 bg-white/10 px-4 py-2 text-sm font-medium text-white hover:bg-white/15"
              >
                Review connectors
              </a>
              <a
                href={~p"/dashboard"}
                class="inline-flex items-center rounded-full bg-white px-4 py-2 text-sm font-medium text-slate-900 hover:bg-slate-100"
              >
                Back to dashboard
              </a>
            </div>
          </div>
        </section>

        <%= if @builder_error do %>
          <section class="rounded-2xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800 shadow-sm">
            <%= @builder_error %>
          </section>
        <% end %>

        <%= if @connection_errors != [] do %>
          <section class="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 shadow-sm">
            <p class="font-medium">Permission readiness could not be fully verified.</p>
            <p class="mt-1 text-amber-800">
              Connector status is temporarily degraded, so the builder is showing best-effort guidance.
            </p>
          </section>
        <% end %>

        <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.65fr)_minmax(320px,1fr)]">
          <div class="space-y-6">
            <section class="rounded-2xl bg-white shadow">
              <div class="border-b border-slate-200 px-5 py-5">
                <h2 class="text-lg font-semibold text-slate-900">Choose a template</h2>
                <p class="mt-1 text-sm text-slate-500">
                  The template controls which inputs matter, what the agent produces, and which permissions need to be ready.
                </p>
              </div>

              <div class="grid grid-cols-1 gap-4 p-5 md:grid-cols-2">
                <button
                  :for={spec <- @behavior_specs}
                  type="button"
                  phx-click="choose_behavior"
                  phx-value-behavior={spec.id}
                  class={behavior_card_class(@selected_spec.id == spec.id)}
                >
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <p class="text-base font-semibold text-slate-900"><%= spec.label %></p>
                      <p class="mt-1 text-xs font-semibold uppercase tracking-[0.24em] text-indigo-600"><%= spec.category %></p>
                    </div>
                    <span class={behavior_chip_class(@selected_spec.id == spec.id)}>
                      <%= if @selected_spec.id == spec.id, do: "Selected", else: "Template" %>
                    </span>
                  </div>
                  <p class="mt-3 text-sm leading-6 text-slate-600"><%= spec.summary %></p>
                </button>
              </div>
            </section>

            <section class="rounded-2xl bg-white shadow">
              <div class="border-b border-slate-200 px-5 py-5">
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <h2 class="text-lg font-semibold text-slate-900">Configure this agent</h2>
                    <p class="mt-1 text-sm text-slate-500">
                      The form only shows inputs that matter for the selected template. Advanced overrides can still go in JSON.
                    </p>
                  </div>
                  <span class="rounded-full bg-indigo-50 px-3 py-1 text-xs font-semibold uppercase tracking-[0.2em] text-indigo-700">
                    Starts immediately
                  </span>
                </div>
              </div>

              <form id="agent-builder-form" phx-change="update_launch" phx-submit="create_agent" class="space-y-6 px-5 py-5">
                <input type="hidden" name="launch[behavior]" value={@launch["behavior"]} />

                <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                  <div>
                    <label for="launch_name" class="block text-sm font-medium text-slate-700">
                      Agent name
                    </label>
                    <input
                      id="launch_name"
                      type="text"
                      name="launch[name]"
                      value={@launch["name"]}
                      placeholder="optional display name"
                      class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                    />
                    <p class="mt-2 text-xs text-slate-500">
                      This is the name operators will see in the dashboard. If blank, Maraithon generates one.
                    </p>
                  </div>

                  <div class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3">
                    <p class="text-xs font-semibold uppercase tracking-[0.2em] text-slate-500">Selected template</p>
                    <p class="mt-2 text-base font-semibold text-slate-900"><%= @selected_spec.label %></p>
                    <p class="mt-1 text-sm text-slate-600"><%= @selected_spec.summary %></p>
                  </div>
                </div>

                <%= if field_visible?(@selected_spec, "prompt") do %>
                  <div>
                    <label for="launch_prompt" class="block text-sm font-medium text-slate-700">
                      Prompt
                    </label>
                    <textarea
                      id="launch_prompt"
                      name="launch[prompt]"
                      rows="5"
                      class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                    ><%= @launch["prompt"] %></textarea>
                    <p class="mt-2 text-xs text-slate-500">
                      Define how the agent should reason, what tone it should use, and which actions it should avoid.
                    </p>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "subscriptions") or field_visible?(@selected_spec, "tools") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "subscriptions") do %>
                      <div>
                        <label for="launch_subscriptions" class="block text-sm font-medium text-slate-700">
                          Input subscriptions
                        </label>
                        <input
                          id="launch_subscriptions"
                          type="text"
                          name="launch[subscriptions]"
                          value={@launch["subscriptions"]}
                          placeholder="github:owner/repo,email:kent"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">
                          Comma-separated topics. Leave blank if the agent should only react to direct operator messages.
                        </p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "tools") do %>
                      <div>
                        <label for="launch_tools" class="block text-sm font-medium text-slate-700">
                          Allowed tools
                        </label>
                        <input
                          id="launch_tools"
                          type="text"
                          name="launch[tools]"
                          value={@launch["tools"]}
                          placeholder="read_file,search_files,http_get"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">
                          Comma-separated tool allowlist. Any tool not listed here is off-limits to the agent.
                        </p>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "memory_limit") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                    <div>
                      <label for="launch_memory_limit" class="block text-sm font-medium text-slate-700">
                        Memory limit
                      </label>
                      <input
                        id="launch_memory_limit"
                        type="number"
                        min="1"
                        name="launch[memory_limit]"
                        value={@launch["memory_limit"]}
                        class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                      />
                      <p class="mt-2 text-xs text-slate-500">How many recent events the prompt agent keeps in rolling memory.</p>
                    </div>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "codebase_path") or field_visible?(@selected_spec, "output_path") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "codebase_path") do %>
                      <div>
                        <label for="launch_codebase_path" class="block text-sm font-medium text-slate-700">
                          Codebase path
                        </label>
                        <input
                          id="launch_codebase_path"
                          type="text"
                          name="launch[codebase_path]"
                          value={@launch["codebase_path"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">Absolute or relative directory that Maraithon should inspect.</p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "output_path") do %>
                      <div>
                        <label for="launch_output_path" class="block text-sm font-medium text-slate-700">
                          Output path
                        </label>
                        <input
                          id="launch_output_path"
                          type="text"
                          name="launch[output_path]"
                          value={@launch["output_path"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">Where the report or generated plan files should be written.</p>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "file_patterns") or field_visible?(@selected_spec, "ignore_patterns") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "file_patterns") do %>
                      <div>
                        <label for="launch_file_patterns" class="block text-sm font-medium text-slate-700">
                          Include patterns
                        </label>
                        <input
                          id="launch_file_patterns"
                          type="text"
                          name="launch[file_patterns]"
                          value={@launch["file_patterns"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">Comma-separated glob patterns that define the files the agent may inspect.</p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "ignore_patterns") do %>
                      <div>
                        <label for="launch_ignore_patterns" class="block text-sm font-medium text-slate-700">
                          Ignore patterns
                        </label>
                        <input
                          id="launch_ignore_patterns"
                          type="text"
                          name="launch[ignore_patterns]"
                          value={@launch["ignore_patterns"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">Comma-separated globs to exclude generated, vendored, or irrelevant files.</p>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "check_url") do %>
                  <div>
                    <label for="launch_check_url" class="block text-sm font-medium text-slate-700">
                      Optional URL to check
                    </label>
                    <input
                      id="launch_check_url"
                      type="text"
                      name="launch[check_url]"
                      value={@launch["check_url"]}
                      placeholder="https://status.example.com/health"
                      class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                    />
                    <p class="mt-2 text-xs text-slate-500">If set, the watchdog will periodically issue `http_get` checks against this URL.</p>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "repo_full_name") or field_visible?(@selected_spec, "base_branch") or field_visible?(@selected_spec, "feature_limit") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "repo_full_name") do %>
                      <div>
                        <label for="launch_repo_full_name" class="block text-sm font-medium text-slate-700">
                          GitHub repository
                        </label>
                        <input
                          id="launch_repo_full_name"
                          type="text"
                          name="launch[repo_full_name]"
                          value={@launch["repo_full_name"]}
                          placeholder="owner/repo"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">The exact GitHub repository the planner should review every day.</p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "base_branch") do %>
                      <div>
                        <label for="launch_base_branch" class="block text-sm font-medium text-slate-700">
                          Base branch
                        </label>
                        <input
                          id="launch_base_branch"
                          type="text"
                          name="launch[base_branch]"
                          value={@launch["base_branch"]}
                          placeholder="main"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">Usually `main`. This is the branch snapshot the planner treats as the current product baseline.</p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "feature_limit") do %>
                      <div>
                        <label for="launch_feature_limit" class="block text-sm font-medium text-slate-700">
                          Daily feature limit
                        </label>
                        <select
                          id="launch_feature_limit"
                          name="launch[feature_limit]"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        >
                          <option value="2" selected={@launch["feature_limit"] == "2"}>2</option>
                          <option value="3" selected={@launch["feature_limit"] == "3"}>3</option>
                        </select>
                        <p class="mt-2 text-xs text-slate-500">How many roadmap opportunities the planner should surface in each daily batch.</p>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "email_scan_limit") or field_visible?(@selected_spec, "event_scan_limit") or field_visible?(@selected_spec, "prep_window_hours") or field_visible?(@selected_spec, "max_insights_per_cycle") or field_visible?(@selected_spec, "min_confidence") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "email_scan_limit") do %>
                      <div>
                        <label for="launch_email_scan_limit" class="block text-sm font-medium text-slate-700">
                          Email scan limit
                        </label>
                        <input
                          id="launch_email_scan_limit"
                          type="number"
                          min="1"
                          name="launch[email_scan_limit]"
                          value={@launch["email_scan_limit"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "event_scan_limit") do %>
                      <div>
                        <label for="launch_event_scan_limit" class="block text-sm font-medium text-slate-700">
                          Event scan limit
                        </label>
                        <input
                          id="launch_event_scan_limit"
                          type="number"
                          min="1"
                          name="launch[event_scan_limit]"
                          value={@launch["event_scan_limit"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "prep_window_hours") do %>
                      <div>
                        <label for="launch_prep_window_hours" class="block text-sm font-medium text-slate-700">
                          Meeting follow-up window (hours)
                        </label>
                        <input
                          id="launch_prep_window_hours"
                          type="number"
                          min="1"
                          name="launch[prep_window_hours]"
                          value={@launch["prep_window_hours"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "max_insights_per_cycle") do %>
                      <div>
                        <label for="launch_max_insights_per_cycle" class="block text-sm font-medium text-slate-700">
                          Max insights per cycle
                        </label>
                        <input
                          id="launch_max_insights_per_cycle"
                          type="number"
                          min="1"
                          name="launch[max_insights_per_cycle]"
                          value={@launch["max_insights_per_cycle"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "min_confidence") do %>
                      <div>
                        <label for="launch_min_confidence" class="block text-sm font-medium text-slate-700">
                          Minimum confidence
                        </label>
                        <input
                          id="launch_min_confidence"
                          type="text"
                          name="launch[min_confidence]"
                          value={@launch["min_confidence"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "team_id") or field_visible?(@selected_spec, "channel_scan_limit") or field_visible?(@selected_spec, "dm_scan_limit") or field_visible?(@selected_spec, "lookback_hours") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "team_id") do %>
                      <div>
                        <label for="launch_team_id" class="block text-sm font-medium text-slate-700">
                          Slack team ID (optional)
                        </label>
                        <input
                          id="launch_team_id"
                          type="text"
                          name="launch[team_id]"
                          value={@launch["team_id"]}
                          placeholder="T01234567"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">
                          Leave blank to scan every connected workspace; set this to pin the agent to one team.
                        </p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "channel_scan_limit") do %>
                      <div>
                        <label for="launch_channel_scan_limit" class="block text-sm font-medium text-slate-700">
                          Channel message scan limit
                        </label>
                        <input
                          id="launch_channel_scan_limit"
                          type="number"
                          min="1"
                          name="launch[channel_scan_limit]"
                          value={@launch["channel_scan_limit"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "dm_scan_limit") do %>
                      <div>
                        <label for="launch_dm_scan_limit" class="block text-sm font-medium text-slate-700">
                          DM message scan limit
                        </label>
                        <input
                          id="launch_dm_scan_limit"
                          type="number"
                          min="1"
                          name="launch[dm_scan_limit]"
                          value={@launch["dm_scan_limit"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "lookback_hours") do %>
                      <div>
                        <label for="launch_lookback_hours" class="block text-sm font-medium text-slate-700">
                          Lookback window (hours)
                        </label>
                        <input
                          id="launch_lookback_hours"
                          type="number"
                          min="1"
                          name="launch[lookback_hours]"
                          value={@launch["lookback_hours"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "wakeup_interval_ms") or field_visible?(@selected_spec, "write_plan_files") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "wakeup_interval_ms") do %>
                      <div>
                        <label for="launch_wakeup_interval_ms" class="block text-sm font-medium text-slate-700">
                          Wakeup interval (ms)
                        </label>
                        <input
                          id="launch_wakeup_interval_ms"
                          type="number"
                          min="1"
                          name="launch[wakeup_interval_ms]"
                          value={@launch["wakeup_interval_ms"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <p class="mt-2 text-xs text-slate-500">How frequently the behavior wakes up to continue work or check for new tasks.</p>
                      </div>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "write_plan_files") do %>
                      <div>
                        <label for="launch_write_plan_files" class="block text-sm font-medium text-slate-700">
                          Write plan files
                        </label>
                        <select
                          id="launch_write_plan_files"
                          name="launch[write_plan_files]"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        >
                          <option value="true" selected={@launch["write_plan_files"] == "true"}>Yes</option>
                          <option value="false" selected={@launch["write_plan_files"] == "false"}>No</option>
                        </select>
                        <p class="mt-2 text-xs text-slate-500">When enabled, generated plans are written to disk in addition to runtime notes.</p>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "timezone_offset_hours") or field_visible?(@selected_spec, "morning_brief_hour_local") or field_visible?(@selected_spec, "end_of_day_brief_hour_local") or field_visible?(@selected_spec, "weekly_review_day_local") or field_visible?(@selected_spec, "weekly_review_hour_local") or field_visible?(@selected_spec, "brief_max_items") do %>
                  <div class="space-y-4 rounded-2xl border border-emerald-100 bg-emerald-50/50 p-4">
                    <div>
                      <p class="text-sm font-medium text-emerald-950">Chief-of-Staff Briefing</p>
                      <p class="mt-1 text-xs text-emerald-900/80">
                        Configure the daily and weekly summary cadence that lands in Telegram in addition to interrupt-driven nudges.
                      </p>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                      <%= if field_visible?(@selected_spec, "timezone_offset_hours") do %>
                        <div>
                          <label for="launch_timezone_offset_hours" class="block text-sm font-medium text-slate-700">
                            Timezone offset from UTC
                          </label>
                          <input
                            id="launch_timezone_offset_hours"
                            type="number"
                            min="-12"
                            max="14"
                            name="launch[timezone_offset_hours]"
                            value={@launch["timezone_offset_hours"]}
                            class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                          />
                          <p class="mt-2 text-xs text-slate-500">Use `-5` for Eastern Standard Time, `-4` for Eastern Daylight Time, `0` for UTC.</p>
                        </div>
                      <% end %>

                      <%= if field_visible?(@selected_spec, "morning_brief_hour_local") do %>
                        <div>
                          <label for="launch_morning_brief_hour_local" class="block text-sm font-medium text-slate-700">
                            Morning brief hour
                          </label>
                          <input
                            id="launch_morning_brief_hour_local"
                            type="number"
                            min="0"
                            max="23"
                            name="launch[morning_brief_hour_local]"
                            value={@launch["morning_brief_hour_local"]}
                            class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                          />
                        </div>
                      <% end %>

                      <%= if field_visible?(@selected_spec, "end_of_day_brief_hour_local") do %>
                        <div>
                          <label for="launch_end_of_day_brief_hour_local" class="block text-sm font-medium text-slate-700">
                            End-of-day brief hour
                          </label>
                          <input
                            id="launch_end_of_day_brief_hour_local"
                            type="number"
                            min="0"
                            max="23"
                            name="launch[end_of_day_brief_hour_local]"
                            value={@launch["end_of_day_brief_hour_local"]}
                            class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                          />
                        </div>
                      <% end %>

                      <%= if field_visible?(@selected_spec, "weekly_review_day_local") do %>
                        <div>
                          <label for="launch_weekly_review_day_local" class="block text-sm font-medium text-slate-700">
                            Weekly review day
                          </label>
                          <input
                            id="launch_weekly_review_day_local"
                            type="number"
                            min="1"
                            max="7"
                            name="launch[weekly_review_day_local]"
                            value={@launch["weekly_review_day_local"]}
                            class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                          />
                          <p class="mt-2 text-xs text-slate-500">Use `1` for Monday through `7` for Sunday.</p>
                        </div>
                      <% end %>

                      <%= if field_visible?(@selected_spec, "weekly_review_hour_local") do %>
                        <div>
                          <label for="launch_weekly_review_hour_local" class="block text-sm font-medium text-slate-700">
                            Weekly review hour
                          </label>
                          <input
                            id="launch_weekly_review_hour_local"
                            type="number"
                            min="0"
                            max="23"
                            name="launch[weekly_review_hour_local]"
                            value={@launch["weekly_review_hour_local"]}
                            class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                          />
                        </div>
                      <% end %>

                      <%= if field_visible?(@selected_spec, "brief_max_items") do %>
                        <div>
                          <label for="launch_brief_max_items" class="block text-sm font-medium text-slate-700">
                            Items per brief
                          </label>
                          <input
                            id="launch_brief_max_items"
                            type="number"
                            min="1"
                            max="5"
                            name="launch[brief_max_items]"
                            value={@launch["brief_max_items"]}
                            class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                          />
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                  <div>
                    <label for="launch_budget_llm_calls" class="block text-sm font-medium text-slate-700">
                      LLM call budget
                    </label>
                    <input
                      id="launch_budget_llm_calls"
                      type="number"
                      min="1"
                      name="launch[budget_llm_calls]"
                      value={@launch["budget_llm_calls"]}
                      class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                    />
                  </div>

                  <div>
                    <label for="launch_budget_tool_calls" class="block text-sm font-medium text-slate-700">
                      Tool call budget
                    </label>
                    <input
                      id="launch_budget_tool_calls"
                      type="number"
                      min="1"
                      name="launch[budget_tool_calls]"
                      value={@launch["budget_tool_calls"]}
                      class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                    />
                  </div>
                </div>

                <div>
                  <label for="launch_config_json" class="block text-sm font-medium text-slate-700">
                    Advanced JSON overrides
                  </label>
                  <textarea
                    id="launch_config_json"
                    name="launch[config_json]"
                    rows="6"
                    class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 font-mono text-sm text-slate-900 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                  ><%= @launch["config_json"] %></textarea>
                  <p class="mt-2 text-xs text-slate-500">
                    Optional object merged into the final config after the form values above. Use this for advanced behavior-specific keys.
                  </p>
                </div>

                <div class="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 pt-5">
                  <div class="text-sm text-slate-500">
                    <%= if @blockers == [] do %>
                      Ready to create. Maraithon will persist the agent and start it right away.
                    <% else %>
                      Resolve the highlighted blockers before launch.
                    <% end %>
                  </div>

                  <button
                    type="submit"
                    phx-disable-with="Creating..."
                    disabled={@blockers != []}
                    class={submit_button_class(@blockers == [])}
                  >
                    Create Agent
                  </button>
                </div>
              </form>
            </section>
          </div>

          <aside class="space-y-6">
            <section class="rounded-2xl bg-white p-5 shadow">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-slate-500">What goes in</p>
              <div class="mt-4 space-y-3">
                <div :for={item <- @input_preview} class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3">
                  <p class="text-sm font-medium text-slate-900"><%= item.title %></p>
                  <p class="mt-1 text-sm text-slate-600"><%= item.body %></p>
                </div>
              </div>
            </section>

            <section class="rounded-2xl bg-white p-5 shadow">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-slate-500">What comes out</p>
              <div class="mt-4 space-y-3">
                <div :for={item <- @output_preview} class="rounded-2xl border border-slate-200 px-4 py-3">
                  <p class="text-sm font-medium text-slate-900"><%= item.title %></p>
                  <p class="mt-1 text-sm text-slate-600"><%= item.body %></p>
                </div>
              </div>
            </section>

            <section class="rounded-2xl bg-white p-5 shadow">
              <div class="flex items-center justify-between gap-3">
                <p class="text-xs font-semibold uppercase tracking-[0.2em] text-slate-500">Permission readiness</p>
                <a href={~p"/connectors"} class="text-xs font-medium text-indigo-600 hover:text-indigo-500">Open connectors</a>
              </div>
              <div class="mt-4 space-y-3">
                <div :for={item <- @readiness_items} class="rounded-2xl border border-slate-200 px-4 py-3">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <p class="text-sm font-medium text-slate-900"><%= item.label %></p>
                      <p class="mt-1 text-sm text-slate-600"><%= item.description %></p>
                    </div>
                    <span class={readiness_badge_class(item)}>
                      <%= readiness_badge_text(item) %>
                    </span>
                  </div>
                  <p class="mt-2 text-xs text-slate-500"><%= item.details %></p>
                </div>
              </div>
            </section>

            <section class="rounded-2xl bg-white p-5 shadow">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-slate-500">Suggested starting point</p>
              <div class="mt-4 space-y-3">
                <div :for={item <- @starter_values} class="flex items-start justify-between gap-3 rounded-2xl bg-slate-50 px-4 py-3">
                  <div class="text-sm font-medium text-slate-900"><%= item.label %></div>
                  <div class="max-w-[55%] text-right text-sm text-slate-600"><%= item.value %></div>
                </div>
                <div :for={tip <- @selected_spec.suggestions} class="rounded-2xl border border-dashed border-slate-200 px-4 py-3 text-sm text-slate-600">
                  <%= tip %>
                </div>
              </div>
            </section>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_builder_state(socket, launch) do
    selected_spec = AgentBuilder.behavior_spec(launch["behavior"])

    readiness_items =
      readiness_items(
        selected_spec,
        launch,
        socket.assigns.provider_map,
        socket.assigns.tool_allowed_paths
      )

    assign(socket,
      launch: launch,
      selected_spec: selected_spec,
      readiness_items: readiness_items,
      blockers: Enum.filter(readiness_items, &(&1.required? and not &1.ready?)),
      input_preview: input_preview(selected_spec, launch),
      output_preview: output_preview(selected_spec, launch),
      starter_values: starter_values(selected_spec, launch)
    )
  end

  defp load_providers(user_id) do
    case Connections.safe_dashboard_snapshot(user_id, return_to: "/agents/new") do
      {:ok, snapshot} ->
        {Map.new(snapshot.providers, &{&1.provider, &1}), []}

      {:degraded, snapshot} ->
        {Map.new(snapshot.providers, &{&1.provider, &1}), snapshot.errors}
    end
  end

  defp readiness_items(spec, launch, provider_map, tool_allowed_paths) do
    spec_items =
      Enum.map(spec.requirements, &readiness_item(&1, launch, provider_map))

    dynamic_items =
      case spec.id do
        "prompt_agent" -> prompt_agent_readiness(launch, provider_map, tool_allowed_paths)
        "watchdog_summarizer" -> watchdog_readiness(launch)
        _ -> []
      end

    case spec_items ++ dynamic_items do
      [] ->
        [
          %{
            label: "No external permissions required",
            description: "This template can run without OAuth grants or special setup.",
            details:
              "You can create it immediately and add more permissions later if the behavior evolves.",
            ready?: true,
            required?: false
          }
        ]

      items ->
        items
    end
  end

  defp prompt_agent_readiness(launch, provider_map, tool_allowed_paths) do
    tools = parse_csv(launch["tools"])

    provider_items =
      tools
      |> Enum.map(&Map.get(@tool_provider_requirements, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn requirement ->
        readiness_item(
          Map.merge(requirement, %{
            kind: (Map.get(requirement, :service, nil) && :provider_service) || :provider,
            description: "Required because one of the selected tools depends on this connector.",
            required?: true
          }),
          launch,
          provider_map
        )
      end)

    path_item =
      if Enum.any?(tools, &MapSet.member?(@path_tools, &1)) do
        [
          %{
            label: "Local file access",
            description: "Needed because the selected tool list includes file-reading tools.",
            details:
              "Allowed roots: " <>
                (tool_allowed_paths |> Enum.map(&Path.expand/1) |> Enum.join(", ")),
            ready?: tool_allowed_paths != [],
            required?: true
          }
        ]
      else
        []
      end

    provider_items ++ path_item
  end

  defp watchdog_readiness(%{"check_url" => ""}), do: []

  defp watchdog_readiness(%{"check_url" => url}) do
    [
      %{
        label: "Optional URL check",
        description: "The watchdog will probe the configured endpoint every sixth wakeup.",
        details: "Configured URL: #{url}",
        ready?: true,
        required?: false
      }
    ]
  end

  defp readiness_item(%{kind: :provider_service} = requirement, _launch, provider_map) do
    provider = Map.get(provider_map, requirement.provider)

    service =
      provider &&
        Enum.find(provider.services, fn service ->
          service.id == requirement.service
        end)

    ready? = service && service.status == :connected

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. The required service is connected.",
          else: "Missing. Connect #{requirement.label} before launch."
        ),
      ready?: !!ready?,
      required?: requirement.required?
    }
  end

  defp readiness_item(%{kind: :provider} = requirement, _launch, provider_map) do
    provider = Map.get(provider_map, requirement.provider)
    ready? = provider && provider.status in [:connected, :partial]

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. The connector is available for this user.",
          else: "Missing. Connect #{requirement.label} before launch."
        ),
      ready?: !!ready?,
      required?: requirement.required?
    }
  end

  defp readiness_item(%{kind: :directory} = requirement, launch, _provider_map) do
    value = Map.get(launch, requirement.field, "")
    ready? = value != "" and File.dir?(value)

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. #{value} exists on the runtime host.",
          else: "Missing. Point this field at an existing directory."
        ),
      ready?: ready?,
      required?: requirement.required?
    }
  end

  defp readiness_item(%{kind: :parent_directory} = requirement, launch, _provider_map) do
    value = Map.get(launch, requirement.field, "")
    ready? = value != "" and File.dir?(Path.dirname(value))

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. #{Path.dirname(value)} exists and can receive output files.",
          else: "Missing. The parent directory for this output path must already exist."
        ),
      ready?: ready?,
      required?: requirement.required?
    }
  end

  defp launch_blockers(launch, socket) do
    spec = AgentBuilder.behavior_spec(launch["behavior"])

    readiness_items(spec, launch, socket.assigns.provider_map, socket.assigns.tool_allowed_paths)
    |> Enum.filter(&(&1.required? and not &1.ready?))
  end

  defp blocker_message(blockers) do
    labels = Enum.map_join(blockers, ", ", & &1.label)
    "Resolve these blockers before launch: #{labels}."
  end

  defp input_preview(spec, launch) do
    base =
      spec.inputs
      |> Enum.with_index(1)
      |> Enum.map(fn {line, index} ->
        %{title: "Input #{index}", body: line}
      end)

    base ++ dynamic_input_preview(spec.id, launch)
  end

  defp dynamic_input_preview("prompt_agent", launch) do
    subscriptions =
      case launch["subscriptions"] do
        "" ->
          "No subscriptions yet. This agent will only react to direct operator messages until you add topics."

        value ->
          "Subscribed topics: #{value}"
      end

    tools =
      case launch["tools"] do
        "" -> "No tools enabled. The agent will stay text-only."
        value -> "Allowed tools: #{value}"
      end

    [
      %{title: "Current subscriptions", body: subscriptions},
      %{title: "Current tool allowlist", body: tools}
    ]
  end

  defp dynamic_input_preview("codebase_advisor", launch) do
    [
      %{title: "Repository scope", body: "Reviewing files under #{launch["codebase_path"]}"},
      %{title: "Output target", body: "Writing recommendations to #{launch["output_path"]}"}
    ]
  end

  defp dynamic_input_preview("repo_planner", launch) do
    [
      %{title: "Repository scope", body: "Indexing files under #{launch["codebase_path"]}"},
      %{
        title: "Plan persistence",
        body:
          if(launch["write_plan_files"] == "true",
            do: "Plans will also be written to #{launch["output_path"]}",
            else: "Plans will stay in runtime state unless you enable plan files."
          )
      }
    ]
  end

  defp dynamic_input_preview("watchdog_summarizer", launch) do
    [
      %{
        title: "Heartbeat cadence",
        body: "Wakes up every #{launch["wakeup_interval_ms"]} ms to emit summaries."
      },
      %{
        title: "URL check",
        body:
          if(launch["check_url"] == "",
            do: "No URL configured. The watchdog will only emit internal summaries.",
            else: "Configured endpoint: #{launch["check_url"]}"
          )
      }
    ]
  end

  defp dynamic_input_preview("inbox_calendar_advisor", launch) do
    [
      %{
        title: "Scan coverage",
        body:
          "Checks up to #{launch["email_scan_limit"]} inbox emails, #{launch["event_scan_limit"]} calendar events, #{launch["channel_scan_limit"]} Slack channel messages, and #{launch["dm_scan_limit"]} Slack DM messages each cycle."
      },
      %{
        title: "Workspace scope",
        body:
          if(launch["team_id"] == "",
            do: "Scanning all connected Slack teams for unresolved commitments.",
            else: "Scoped to Slack team #{launch["team_id"]}."
          )
      },
      %{
        title: "Insight tuning",
        body:
          "Email/calendar follow-up window: #{launch["prep_window_hours"]}h. Slack lookback: #{launch["lookback_hours"]}h. Max insights: #{launch["max_insights_per_cycle"]}, minimum confidence: #{launch["min_confidence"]}."
      }
    ]
  end

  defp dynamic_input_preview("slack_followthrough_agent", launch) do
    [
      %{
        title: "Workspace scope",
        body:
          if(launch["team_id"] == "",
            do: "Scanning all connected Slack teams.",
            else: "Scoped to Slack team #{launch["team_id"]}."
          )
      },
      %{
        title: "Scan coverage",
        body:
          "Checks up to #{launch["channel_scan_limit"]} channel messages and #{launch["dm_scan_limit"]} DM messages over the last #{launch["lookback_hours"]} hours each cycle."
      },
      %{
        title: "Escalation tuning",
        body:
          "Max insights: #{launch["max_insights_per_cycle"]}, minimum confidence: #{launch["min_confidence"]}."
      }
    ]
  end

  defp dynamic_input_preview("github_product_planner", launch) do
    [
      %{
        title: "Repository review target",
        body:
          if(launch["repo_full_name"] == "",
            do: "No repository selected yet. Add one in `owner/repo` format.",
            else:
              "Reviewing #{launch["repo_full_name"]} on branch #{blank_fallback(launch["base_branch"], "main")}."
          )
      },
      %{
        title: "Daily planning scope",
        body:
          "The planner will shortlist #{blank_fallback(launch["feature_limit"], "3")} feature opportunities per cycle."
      }
    ]
  end

  defp dynamic_input_preview(_behavior, _launch), do: []

  defp output_preview(spec, launch) do
    (spec.outputs
     |> Enum.with_index(1)
     |> Enum.map(fn {line, index} ->
       %{title: "Output #{index}", body: line}
     end)) ++ dynamic_output_preview(spec.id, launch)
  end

  defp dynamic_output_preview("prompt_agent", launch) do
    [
      %{
        title: "Launch effect",
        body:
          "The agent is created in running state with LLM budget #{launch["budget_llm_calls"]} and tool budget #{launch["budget_tool_calls"]}."
      }
    ]
  end

  defp dynamic_output_preview("inbox_calendar_advisor", _launch) do
    [
      %{
        title: "Stored records",
        body:
          "Each insight stores a structured commitment record with evidence and next action, unified across Gmail, Calendar, and Slack sources."
      }
    ]
  end

  defp dynamic_output_preview("slack_followthrough_agent", _launch) do
    [
      %{
        title: "Stored records",
        body:
          "Each unresolved Slack commitment persists a structured record with commitment, person, source, deadline, status, evidence, and next_action."
      }
    ]
  end

  defp dynamic_output_preview("codebase_advisor", launch) do
    [
      %{title: "Primary artifact", body: "Recommendation report path: #{launch["output_path"]}"}
    ]
  end

  defp dynamic_output_preview("repo_planner", launch) do
    [
      %{
        title: "Primary artifact",
        body:
          if(launch["write_plan_files"] == "true",
            do:
              "Plans are written into #{launch["output_path"]} and also emitted as runtime notes.",
            else: "Plans remain in runtime notes unless you enable plan file writing."
          )
      }
    ]
  end

  defp dynamic_output_preview("github_product_planner", launch) do
    [
      %{
        title: "Telegram push behavior",
        body:
          "High-signal roadmap suggestions for #{blank_fallback(launch["repo_full_name"], "the selected repository")} are stored as insights and sent through the Telegram notification pipeline."
      }
    ]
  end

  defp dynamic_output_preview(_behavior, _launch), do: []

  defp starter_values(spec, launch) do
    case spec.id do
      "prompt_agent" ->
        [
          %{label: "Memory limit", value: launch["memory_limit"] <> " events"},
          %{label: "LLM call budget", value: launch["budget_llm_calls"]},
          %{label: "Tool call budget", value: launch["budget_tool_calls"]}
        ]

      "inbox_calendar_advisor" ->
        [
          %{label: "Email scan limit", value: launch["email_scan_limit"]},
          %{label: "Event scan limit", value: launch["event_scan_limit"]},
          %{
            label: "Slack team",
            value: if(launch["team_id"] == "", do: "All connected teams", else: launch["team_id"])
          },
          %{label: "Slack DM scan", value: launch["dm_scan_limit"]}
        ]

      "slack_followthrough_agent" ->
        [
          %{
            label: "Slack team",
            value: if(launch["team_id"] == "", do: "All connected teams", else: launch["team_id"])
          },
          %{label: "Channel scan limit", value: launch["channel_scan_limit"]},
          %{label: "DM scan limit", value: launch["dm_scan_limit"]}
        ]

      "codebase_advisor" ->
        [
          %{label: "Codebase path", value: launch["codebase_path"]},
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"},
          %{label: "Output path", value: launch["output_path"]}
        ]

      "repo_planner" ->
        [
          %{label: "Codebase path", value: launch["codebase_path"]},
          %{
            label: "Write plan files",
            value: if(launch["write_plan_files"] == "true", do: "Yes", else: "No")
          },
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"}
        ]

      "watchdog_summarizer" ->
        [
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"},
          %{
            label: "Optional URL",
            value: if(launch["check_url"] == "", do: "None", else: launch["check_url"])
          },
          %{label: "Tool budget", value: launch["budget_tool_calls"]}
        ]

      "github_product_planner" ->
        [
          %{
            label: "Repository",
            value: blank_fallback(launch["repo_full_name"], "Set `owner/repo`")
          },
          %{
            label: "Daily shortlist",
            value: blank_fallback(launch["feature_limit"], "3") <> " features"
          },
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"}
        ]

      _ ->
        [
          %{label: "LLM call budget", value: launch["budget_llm_calls"]},
          %{label: "Tool call budget", value: launch["budget_tool_calls"]}
        ]
    end
  end

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp field_visible?(spec, field), do: field in spec.fields

  defp parse_csv(""), do: []

  defp parse_csv(values) when is_binary(values) do
    values
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_csv(_values), do: []

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> normalized
    end
  end

  defp blank_fallback(_value, fallback), do: fallback

  defp behavior_card_class(true),
    do:
      "rounded-2xl border border-indigo-300 bg-indigo-50 px-4 py-4 text-left shadow-sm transition hover:border-indigo-400 hover:bg-indigo-50"

  defp behavior_card_class(false),
    do:
      "rounded-2xl border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-indigo-200 hover:bg-slate-50"

  defp behavior_chip_class(true),
    do:
      "rounded-full bg-indigo-600 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-white"

  defp behavior_chip_class(false),
    do:
      "rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-slate-600"

  defp readiness_badge_class(%{required?: true, ready?: true}),
    do:
      "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-800"

  defp readiness_badge_class(%{required?: true, ready?: false}),
    do:
      "rounded-full bg-rose-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-800"

  defp readiness_badge_class(_item),
    do:
      "rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-slate-600"

  defp readiness_badge_text(%{required?: true, ready?: true}), do: "Ready"
  defp readiness_badge_text(%{required?: true, ready?: false}), do: "Blocked"
  defp readiness_badge_text(_item), do: "Optional"

  defp submit_button_class(true),
    do:
      "inline-flex items-center rounded-full bg-indigo-600 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500"

  defp submit_button_class(false),
    do:
      "inline-flex cursor-not-allowed items-center rounded-full bg-slate-300 px-5 py-2.5 text-sm font-semibold text-slate-600"

  defp current_path_from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/agents/new"
      "" -> "/agents/new"
      path -> path
    end
  end

  defp current_path_from_uri(_uri), do: "/agents/new"

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
end
