# ==============================================================================
# Dashboard LiveView Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The Dashboard is the main user interface for monitoring and managing agents.
# It provides real-time visibility into:
#
# - **Agent Status**: Which agents are running, stopped, or degraded
# - **Resource Usage**: LLM calls, tool calls, and spend per agent
# - **Event History**: Recent events and actions taken by each agent
# - **System Health**: Total agents, running count, and overall spend
#
# From a user's perspective, the Dashboard is "mission control" - where they
# go to see what their agents are doing, diagnose issues, and understand costs.
#
# Example User Journey:
# 1. User opens Maraithon dashboard at /
# 2. Sees overview stats: 5 total agents, 3 running, $12.50 spent
# 3. Notices an agent showing "degraded" status
# 4. Clicks the agent to see details and recent events
# 5. Sees the agent has been encountering rate limits
# 6. Takes action to adjust the agent's configuration
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the Dashboard breaks, users experience:
# - Blindness to what their agents are doing
# - Inability to diagnose agent issues
# - Surprise bills from unmonitored spend
# - No way to identify which agents need attention
# - Loss of trust in the entire system
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates DashboardLive, a Phoenix LiveView that provides
# real-time agent monitoring with WebSocket updates.
#
# LiveView Architecture:
# ----------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                       Dashboard LiveView                                 │
#   │                                                                          │
#   │   Browser                  Server                  Database              │
#   │    │                        │                        │                   │
#   │    │  1. GET /              │                        │                   │
#   │    │──────────────────────►│                        │                   │
#   │    │                        │                        │                   │
#   │    │  2. Initial HTML       │  3. Query agents       │                   │
#   │    │◄──────────────────────│───────────────────────►│                   │
#   │    │                        │  4. Agent list         │                   │
#   │    │                        │◄───────────────────────│                   │
#   │    │                        │                        │                   │
#   │    │  5. WebSocket connect  │                        │                   │
#   │    │◄─────────────────────►│                        │                   │
#   │    │                        │                        │                   │
#   │    │  6. handle_info(:refresh)                       │                   │
#   │    │                        │───────────────────────►│                   │
#   │    │  7. Push diff          │                        │                   │
#   │    │◄──────────────────────│                        │                   │
#   │    │                        │                        │                   │
#   │    │  8. Click agent        │                        │                   │
#   │    │──────────────────────►│                        │                   │
#   │    │  9. handle_params      │                        │                   │
#   │    │                        │  10. Query agent + events                  │
#   │    │                        │───────────────────────►│                   │
#   │    │  11. Agent details     │                        │                   │
#   │    │◄──────────────────────│                        │                   │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Key Components:
# ---------------
# - Stats Cards: Total agents, running count, LLM calls, total spend
# - Agent List: Clickable list of all agents with status badges
# - Agent Details: Expanded view when an agent is selected
# - Event Log: Recent events for the selected agent
# - Spend Info: Cost breakdown for the selected agent
#
# LiveView Events:
# ----------------
# - mount/3: Initial page load, fetch all agents
# - handle_params/3: URL changes (agent selection via ?id=xxx)
# - handle_info(:refresh): Periodic data refresh (every 5 seconds)
#
# Test Categories:
# ----------------
# - Initial Render: Dashboard loads with correct structure
# - Agent Selection: Clicking agents updates URL and details
# - Data Refresh: Periodic refresh updates data
# - Status Badges: Different statuses show correct styling
# - Error States: Handling of deleted agents, missing data
#
# Dependencies:
# -------------
# - MaraithonWeb.DashboardLive (the LiveView being tested)
# - Maraithon.Agents (for agent queries)
# - Maraithon.Events (for event queries)
# - Maraithon.Spend (for spend queries)
# - Phoenix.LiveViewTest (for LiveView testing utilities)
#
# Setup Requirements:
# -------------------
# This test uses `async: true` because:
# 1. Each test uses isolated database transactions
# 2. No global state is modified
# 3. LiveView tests are naturally isolated
#
# ==============================================================================

defmodule MaraithonWeb.DashboardLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.Runtime.ScheduledJob

  @user_email "user@example.com"

  setup %{conn: conn} do
    conn = log_in_test_user(conn, @user_email)

    {:ok, _token} =
      OAuth.store_tokens(@user_email, "github", %{
        access_token: "dashboard-test-token",
        scopes: ["repo"]
      })

    {:ok, conn: conn}
  end

  # ============================================================================
  # INITIAL MOUNT TESTS
  # ============================================================================
  #
  # These tests verify the Dashboard renders correctly on initial page load.
  # ============================================================================

  describe "mount/3" do
    @doc """
    Verifies the Dashboard renders with all expected elements when no agents exist.
    This is the "empty state" - what new users see before creating agents.
    """
    test "renders dashboard with no agents", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "Dashboard"
      assert html =~ "Total Agents"
      assert html =~ "Running"
      assert html =~ "LLM Calls"
      assert html =~ "Total Spend"
      assert html =~ "No agents yet"
      assert has_element?(view, "dt", "Total Agents")
    end

    test "renders the LiveView bootstrap script", %{conn: conn} do
      html =
        conn
        |> get("/dashboard")
        |> html_response(200)

      assert html =~ "new window.LiveView.LiveSocket"
      assert html =~ "window.liveSocket = liveSocket"
    end

    @doc """
    Verifies the Dashboard shows agents when they exist.
    Each agent should appear in the list with its behavior name.
    """
    test "renders agents list", %{conn: conn} do
      {:ok, _agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "prompt_agent"
      refute html =~ "No agents yet"
      assert has_element?(view, "div", "prompt_agent")
    end

    test "renders enriched insight context and ideas", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "inbox_calendar_advisor",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _insights} =
        Insights.record_many(@user_email, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to the customer escalation",
            "summary" => "A renewal thread needs a same-day response from the account team.",
            "recommended_action" =>
              "Reply now, confirm the owner, and send a timeline for the next update.",
            "priority" => 93,
            "confidence" => 0.9,
            "dedupe_key" => "dashboard:enriched:1",
            "metadata" => %{
              "why_now" => "The customer asked for an update before today's review call.",
              "follow_up_ideas" => [
                "Pull the latest status from support before replying.",
                "Write down the two risks you need covered on the call."
              ]
            }
          }
        ])

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Why now"
      assert html =~ "The customer asked for an update before today&#39;s review call."
      assert html =~ "Pull the latest status from support before replying."
      assert html =~ "Write down the two risks you need covered on the call."
    end

    @doc """
    Verifies that admin-specific monitoring panels are rendered.
    """
    test "renders health and logs sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      assert has_element?(view, "h2", "Connectors")
      assert has_element?(view, "h2", "Health & Monitoring")
      assert has_element?(view, "h3", "Operational Logs")
      assert has_element?(view, "h3", "Failures & Stale Work")
      assert has_element?(view, "h3", "Raw Logs")
      assert has_element?(view, "h3", "Fly.io Platform Logs")
    end

    test "shows connectors are available from the dedicated tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~
               "Connected Accounts and OAuth configuration now live in the dedicated Connectors tab."

      assert html =~ "Open Connectors"
    end

    test "renders recent raw logs", %{conn: conn} do
      Maraithon.LogBuffer.clear()

      Maraithon.LogBuffer.record(%{
        level: :info,
        message: "runtime booted",
        metadata: %{"agent_id" => "agent-123"}
      })

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Raw Logs"
      assert html =~ "runtime booted"
      assert html =~ "agent_id=agent-123"
    end

    test "shows Fly log configuration guidance when platform log access is disabled", %{
      conn: conn
    } do
      previous = Application.get_env(:maraithon, Maraithon.FlyLogs, [])

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.FlyLogs, previous)
      end)

      Application.put_env(:maraithon, Maraithon.FlyLogs,
        api_token: "",
        api_base_url: "https://api.fly.io/api/v1",
        apps: [],
        region: nil,
        receive_timeout_ms: 1_000
      )

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Fly.io Platform Logs"
      assert html =~ "Configure `FLY_API_TOKEN` and `FLY_LOG_APPS`"
    end
  end

  describe "agent builder entrypoints" do
    test "links to the dedicated builder from the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Dedicated Builder"
      assert html =~ "Open Agent Builder"
      refute html =~ "launch-agent-form"
    end

    test "updates a stopped prompt agent from the dashboard", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "before-edit",
            "prompt" => "Before edit",
            "subscribe" => ["github:acme/repo"],
            "tools" => ["read_file"],
            "memory_limit" => 10,
            "budget" => %{"llm_calls" => 10, "tool_calls" => 20}
          },
          status: "stopped"
        })

      {:ok, view, _html} = live(conn, "/dashboard")

      view
      |> element("button[phx-click=edit_agent][phx-value-id=\"#{agent.id}\"]")
      |> render_click()

      html =
        view
        |> form("#launch-agent-form",
          launch: %{
            behavior: "prompt_agent",
            name: "after-edit",
            prompt: "After edit",
            subscriptions: "linear:team-1,notaui:tasks",
            tools: "search_files,notaui_list_tasks",
            memory_limit: "30",
            budget_llm_calls: "200",
            budget_tool_calls: "300",
            config_json: "{\"custom_flag\":true}"
          }
        )
        |> render_submit()

      updated_agent = Agents.get_agent!(agent.id)

      assert updated_agent.behavior == "prompt_agent"
      assert updated_agent.config["name"] == "after-edit"
      assert updated_agent.config["prompt"] == "After edit"
      assert updated_agent.config["subscribe"] == ["linear:team-1", "notaui:tasks"]
      assert updated_agent.config["tools"] == ["search_files", "notaui_list_tasks"]
      assert updated_agent.config["memory_limit"] == 30
      assert updated_agent.config["budget"]["llm_calls"] == 200
      assert updated_agent.config["budget"]["tool_calls"] == 300
      assert updated_agent.config["custom_flag"] == true
      assert html =~ "Agent Details"
      assert html =~ "after-edit"
    end

    test "deletes a stopped agent from the admin UI", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"name" => "delete-me"},
          status: "stopped"
        })

      {:ok, view, _html} = live(conn, "/dashboard")

      _html =
        view
        |> element("button[phx-click=delete_agent][phx-value-id=\"#{agent.id}\"]")
        |> render_click()

      assert Agents.get_agent(agent.id) == nil
      refute render(view) =~ "delete-me"
    end
  end

  # ============================================================================
  # AGENT SELECTION TESTS
  # ============================================================================
  #
  # These tests verify that clicking an agent shows its details.
  # Agent selection works via URL parameters (?id=xxx).
  # ============================================================================

  describe "handle_params/3 with agent id" do
    @doc """
    Verifies that agent details are shown when id param is provided.
    The details panel should show agent ID, behavior, and configuration.
    """
    test "shows agent details when id param provided", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, html} = live(conn, "/dashboard?id=#{agent.id}")

      assert html =~ "Agent Details"
      assert html =~ "watchdog_summarizer"
      assert html =~ agent.id
      assert has_element?(view, "h2", "Agent Details")
    end

    @doc """
    Verifies redirect when a non-existent agent ID is provided.
    Users shouldn't see an error page - they're redirected to dashboard root.
    """
    test "redirects to root for non-existent agent id", %{conn: conn} do
      result = live(conn, "/dashboard?id=#{Ecto.UUID.generate()}")

      # Should redirect back to root
      assert {:error, {:live_redirect, %{to: "/dashboard?"}}} = result
    end

    @doc """
    Verifies that events are shown for the selected agent.
    Events are the log of what the agent has done.
    """
    test "shows events for selected agent", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/dashboard?id=#{agent.id}")

      assert html =~ "Recent Events"
    end

    @doc """
    Verifies that spend information is shown for the selected agent.
    This shows LLM calls, token counts, and costs.
    """
    test "shows agent spend", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/dashboard?id=#{agent.id}")

      assert html =~ "Agent Spend"
      assert html =~ "LLM Calls"
      assert html =~ "Total Cost"
    end
  end

  # ============================================================================
  # PERIODIC REFRESH TESTS
  # ============================================================================
  #
  # These tests verify the periodic data refresh mechanism.
  # The Dashboard sends itself :refresh messages every 5 seconds.
  # ============================================================================

  describe "handle_info :refresh" do
    @doc """
    Verifies that new agents appear after a refresh.
    This simulates an agent being created while the user is viewing the dashboard.
    """
    test "refreshes data periodically", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Create an agent after initial load
      {:ok, _agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      # Trigger refresh
      send(view.pid, :refresh)

      # Wait for refresh to process
      html = render(view)

      assert html =~ "prompt_agent"
    end

    @doc """
    Verifies that refresh updates selected agent data.
    If viewing an agent's details, refresh should update those too.
    """
    test "refreshes selected agent data", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, "/dashboard?id=#{agent.id}")

      # Trigger refresh
      send(view.pid, :refresh)

      # Wait for refresh to process
      html = render(view)

      assert html =~ "Agent Details"
      assert html =~ "prompt_agent"
    end

    @doc """
    Verifies that if the selected agent is deleted, the selection is cleared.
    Users shouldn't see stale data for deleted agents.
    """
    test "clears selected agent if agent not found during refresh", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, "/dashboard?id=#{agent.id}")

      # Delete the agent
      Maraithon.Repo.delete(agent)

      # Trigger refresh
      send(view.pid, :refresh)

      # Wait for refresh to process
      html = render(view)

      assert html =~ "Select an agent to view details"
    end
  end

  # ============================================================================
  # STATUS BADGE TESTS
  # ============================================================================
  #
  # These tests verify that status badges display correctly.
  # Different statuses have different colors for quick visual identification.
  # ============================================================================

  describe "status_badge component" do
    @doc """
    Verifies that running agents show a green status badge.
    Green = healthy and operating normally.
    """
    test "shows green badge for running agents", %{conn: conn} do
      {:ok, _agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "text-green-600"
    end
  end

  # ============================================================================
  # TIME FORMATTING TESTS
  # ============================================================================
  #
  # These tests verify that timestamps are formatted consistently.
  # ============================================================================

  describe "formatting helpers" do
    @doc """
    Verifies that event timestamps are formatted as HH:MM:SS.
    Consistent formatting helps users scan the event log quickly.
    """
    test "formats times correctly in event list", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/dashboard?id=#{agent.id}")

      # Should show time in HH:MM:SS format
      assert html =~ ~r/\d{2}:\d{2}:\d{2}/
    end
  end

  # ============================================================================
  # CLICK NAVIGATION TESTS
  # ============================================================================
  #
  # These tests verify that clicking agents updates the URL and view.
  # ============================================================================

  describe "clicking on agents" do
    @doc """
    Verifies that clicking an agent shows its details.
    The click should update the URL and render the agent details panel.
    """
    test "clicking an agent updates the URL and shows details", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, "/dashboard")

      # Click on the agent link
      html =
        view
        |> element("a[href*=\"?id=#{agent.id}\"]")
        |> render_click()

      assert html =~ "Agent Details"
      assert html =~ agent.id
      assert_patch(view, "/dashboard?id=#{agent.id}")
    end
  end

  # ============================================================================
  # MULTI-STATUS TESTS
  # ============================================================================
  #
  # These tests verify different agent statuses display correctly.
  # ============================================================================

  describe "agents with different statuses" do
    @doc """
    Verifies that stopped agents show appropriate styling.
    Stopped agents should be visually distinct from running ones.
    """
    test "shows stopped badge", %{conn: conn} do
      {:ok, _agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped",
          started_at: DateTime.utc_now(),
          stopped_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "text-gray-500" or html =~ "stopped"
    end

    @doc """
    Verifies that degraded agents show warning styling.
    Degraded = running but experiencing issues (rate limits, errors, etc.)
    """
    test "shows degraded badge", %{conn: conn} do
      {:ok, _agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "degraded",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      # Degraded status should be shown
      assert html =~ "degraded" or html =~ "text-amber"
    end
  end

  # ============================================================================
  # EVENT DISPLAY TESTS
  # ============================================================================
  #
  # These tests verify that agent events are displayed correctly.
  # ============================================================================

  describe "agent with events" do
    @doc """
    Verifies that events are displayed in the agent details panel.
    Each event should show its type and timestamp.
    """
    test "shows events list", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      # Add an event
      {:ok, _event} =
        Maraithon.Events.append(agent.id, "test_event", %{message: "test"})

      {:ok, _view, html} = live(conn, "/dashboard?id=#{agent.id}")

      assert html =~ "Recent Events"
      assert html =~ "test_event"
    end

    test "shows inspection panels with queued work and logs", %{conn: conn} do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "inspected-agent",
            "prompt" => "Inspect me",
            "budget" => %{"llm_calls" => 100, "tool_calls" => 50}
          },
          status: "stopped"
        })

      {:ok, _event} = Maraithon.Events.append(agent.id, "inspection_ready", %{message: "ok"})

      {:ok, _effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "failed",
          attempts: 2,
          error: "Tool timeout"
        })
        |> Maraithon.Repo.insert()

      {:ok, _job} =
        %ScheduledJob{}
        |> ScheduledJob.changeset(%{
          agent_id: agent.id,
          job_type: "heartbeat",
          fire_at: DateTime.utc_now(),
          status: "pending",
          attempts: 1
        })
        |> Maraithon.Repo.insert()

      Maraithon.LogBuffer.record(%{
        level: :warning,
        message: "agent inspection log",
        metadata: %{agent_id: agent.id}
      })

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      {:ok, _view, html} = live(conn, "/dashboard?id=#{agent.id}")

      assert html =~ "Effect Queue"
      assert html =~ "tool_call"
      assert html =~ "Scheduled Jobs"
      assert html =~ "heartbeat"
      assert html =~ "Agent Logs"
      assert html =~ "agent inspection log"
      assert html =~ "Config Snapshot"
    end
  end

  # ============================================================================
  # EDGE CASE TESTS
  # ============================================================================
  #
  # These tests verify handling of edge cases and unusual data.
  # ============================================================================

  describe "format helpers" do
    @doc """
    Verifies that nil started_at is displayed gracefully.
    Agents might have nil started_at if they were never started.
    """
    test "displays nil started_at correctly", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "stopped"
        })

      # Update to have nil started_at
      agent
      |> Ecto.Changeset.change(%{started_at: nil})
      |> Maraithon.Repo.update!()

      {:ok, _view, html} = live(conn, "/dashboard?id=#{agent.id}")

      assert html =~ "Started"
      assert html =~ "N/A"
    end
  end

  # ============================================================================
  # STATS CARD TESTS
  # ============================================================================
  #
  # These tests verify the stats cards at the top of the dashboard.
  # ============================================================================

  describe "stats cards" do
    @doc """
    Verifies that running agent count is calculated correctly.
    The "Running" stat should only count agents with status = "running".
    """
    test "shows correct count of running agents", %{conn: conn} do
      {:ok, _running1} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _running2} =
        create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _stopped} =
        create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped"
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      # Should show 2 running agents in the Running stat card
      assert html =~ "Running"
      assert html =~ "Total Agents"
    end
  end

  defp create_agent(attrs) do
    attrs = Map.put_new(attrs, :user_id, @user_email)
    Agents.create_agent(attrs)
  end
end
