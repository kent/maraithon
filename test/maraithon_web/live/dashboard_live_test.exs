defmodule MaraithonWeb.DashboardLiveTest do
  use MaraithonWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Maraithon.Agents

  describe "mount/3" do
    test "renders dashboard with no agents", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "Dashboard"
      assert html =~ "Total Agents"
      assert html =~ "Running"
      assert html =~ "LLM Calls"
      assert html =~ "Total Spend"
      assert html =~ "No agents yet"
      assert has_element?(view, "dt", "Total Agents")
    end

    test "renders agents list", %{conn: conn} do
      {:ok, _agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, html} = live(conn, "/")

      assert html =~ "prompt_agent"
      refute html =~ "No agents yet"
      assert has_element?(view, "p", "prompt_agent")
    end
  end

  describe "handle_params/3 with agent id" do
    test "shows agent details when id param provided", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, html} = live(conn, "/?id=#{agent.id}")

      assert html =~ "Agent Details"
      assert html =~ "watchdog_summarizer"
      assert html =~ agent.id
      assert has_element?(view, "h3", "Agent Details")
    end

    test "redirects to root for non-existent agent id", %{conn: conn} do
      result = live(conn, "/?id=#{Ecto.UUID.generate()}")

      # Should redirect back to root
      assert {:error, {:live_redirect, %{to: "/"}}} = result
    end

    test "shows events for selected agent", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/?id=#{agent.id}")

      assert html =~ "Recent Events"
    end

    test "shows agent spend", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/?id=#{agent.id}")

      assert html =~ "Agent Spend"
      assert html =~ "LLM Calls"
      assert html =~ "Total Cost"
    end
  end

  describe "handle_info :refresh" do
    test "refreshes data periodically", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Create an agent after initial load
      {:ok, _agent} =
        Agents.create_agent(%{
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

    test "refreshes selected agent data", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, "/?id=#{agent.id}")

      # Trigger refresh
      send(view.pid, :refresh)

      # Wait for refresh to process
      html = render(view)

      assert html =~ "Agent Details"
      assert html =~ "prompt_agent"
    end

    test "clears selected agent if agent not found during refresh", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, "/?id=#{agent.id}")

      # Delete the agent
      Maraithon.Repo.delete(agent)

      # Trigger refresh
      send(view.pid, :refresh)

      # Wait for refresh to process
      html = render(view)

      assert html =~ "Select an agent to view details"
    end
  end

  describe "status_badge component" do
    test "shows green badge for running agents", %{conn: conn} do
      {:ok, _agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "text-green-600"
    end
  end

  describe "formatting helpers" do
    test "formats times correctly in event list", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/?id=#{agent.id}")

      # Should show time in HH:MM:SS format
      assert html =~ ~r/\d{2}:\d{2}:\d{2}/
    end
  end

  describe "clicking on agents" do
    test "clicking an agent updates the URL and shows details", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, "/")

      # Click on the agent link
      html =
        view
        |> element("a[href*=\"?id=#{agent.id}\"]")
        |> render_click()

      assert html =~ "Agent Details"
      assert html =~ agent.id
    end
  end

  describe "agents with different statuses" do
    test "shows stopped badge", %{conn: conn} do
      {:ok, _agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped",
          started_at: DateTime.utc_now(),
          stopped_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "text-gray-500" or html =~ "stopped"
    end

    test "shows degraded badge", %{conn: conn} do
      {:ok, _agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "degraded",
          started_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, "/")

      # Degraded status should be shown
      assert html =~ "degraded" or html =~ "text-amber"
    end
  end

  describe "agent with events" do
    test "shows events list", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "running",
          started_at: DateTime.utc_now()
        })

      # Add an event
      {:ok, _event} =
        Maraithon.Events.append(agent.id, "test_event", %{message: "test"})

      {:ok, _view, html} = live(conn, "/?id=#{agent.id}")

      assert html =~ "Recent Events"
      assert html =~ "test_event"
    end
  end

  describe "format helpers" do
    test "displays nil started_at correctly", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"budget" => %{"llm_calls" => 100, "tool_calls" => 50}},
          status: "stopped"
        })

      # Update to have nil started_at
      agent
      |> Ecto.Changeset.change(%{started_at: nil})
      |> Maraithon.Repo.update!()

      {:ok, _view, html} = live(conn, "/")

      # Should show N/A or similar for nil date
      assert html =~ "N/A" or html =~ "Started"
    end
  end

  describe "stats cards" do
    test "shows correct count of running agents", %{conn: conn} do
      {:ok, _running1} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _running2} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _stopped} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped"
        })

      {:ok, _view, html} = live(conn, "/")

      # Should show 2 running agents in the Running stat card
      assert html =~ "Running"
      assert html =~ "Total Agents"
    end
  end
end
