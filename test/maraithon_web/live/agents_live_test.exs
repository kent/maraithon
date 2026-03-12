defmodule MaraithonWeb.AgentsLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.ScheduledJob

  @user_email "agents@example.com"

  setup %{conn: conn} do
    Maraithon.LogBuffer.clear()

    on_exit(fn ->
      Maraithon.LogBuffer.clear()
    end)

    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "highlights the Agents tab on /agents", %{conn: conn} do
    {:ok, view, html} = live(conn, "/agents")

    assert html =~ "Agents Workspace"
    assert has_element?(view, "a[href='/agents'].bg-indigo-700", "Agents")
  end

  test "renders empty registry and empty workspace states", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "No agents exist yet."
    assert html =~ "No agent selected."
  end

  test "selecting an agent opens inspect mode", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "inspect-me"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, "/agents")

    view
    |> element("a[href='/agents?id=#{agent.id}']", "Inspect")
    |> render_click()

    assert_patch(view, "/agents?id=#{agent.id}")

    html = render(view)
    assert html =~ "Selected Agent Workspace"
    assert html =~ "inspect-me"
  end

  test "edit opens edit mode for the selected agent", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "edit-me"},
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents")

    view
    |> element("a[href='/agents?id=#{agent.id}&panel=edit']", "Edit")
    |> render_click()

    assert_patch(view, "/agents?id=#{agent.id}&panel=edit")

    html = render(view)
    assert html =~ "Edit Agent"
    assert html =~ "Save Changes"
  end

  test "start action updates the visible status", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "starter"},
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents")

    view
    |> element("button[phx-click=start_agent][phx-value-id=\"#{agent.id}\"]")
    |> render_click()

    assert Agents.get_agent!(agent.id).status == "running"

    assert has_element?(
             view,
             "button[phx-click=stop_agent][phx-value-id=\"#{agent.id}\"]",
             "Stop"
           )

    assert render(view) =~ "Agent started"

    stop_agent_process(agent.id)
  end

  test "stop action updates the visible status", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "stopper"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, "/agents")

    view
    |> element("button[phx-click=stop_agent][phx-value-id=\"#{agent.id}\"]")
    |> render_click()

    assert Agents.get_agent!(agent.id).status == "stopped"

    assert has_element?(
             view,
             "button[phx-click=start_agent][phx-value-id=\"#{agent.id}\"]",
             "Start"
           )

    assert render(view) =~ "Agent stopped"
  end

  test "delete removes the row and clears selection", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "delete-me"},
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}")

    view
    |> element(
      "button[phx-click=delete_agent][phx-value-id=\"#{agent.id}\"][phx-value-surface=\"workspace\"]"
    )
    |> render_click()

    assert_patch(view, "/agents")
    assert Agents.get_agent(agent.id) == nil

    html = render(view)
    refute html =~ agent.id
    assert html =~ "No agent selected."
  end

  test "selected inspection shows logs, events, queue, spend, and config", %{conn: conn} do
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

    _ = :sys.get_state(Maraithon.LogBuffer)

    {:ok, _view, html} = live(conn, "/agents?id=#{agent.id}")

    assert html =~ "Effect Queue"
    assert html =~ "tool_call"
    assert html =~ "Scheduled Jobs"
    assert html =~ "heartbeat"
    assert html =~ "Recent Events"
    assert html =~ "inspection_ready"
    assert html =~ "Spend Summary"
    assert html =~ "Config Snapshot"
    assert html =~ "agent inspection log"
  end

  test "unauthorized ids clear the selection safely", %{conn: conn} do
    {:ok, other_agent} =
      Agents.create_agent(%{
        user_id: "other@example.com",
        behavior: "prompt_agent",
        config: %{"name" => "not-yours"},
        status: "stopped"
      })

    assert {:error, {:live_redirect, %{to: "/agents", flash: %{"error" => "Agent not found"}}}} =
             live(conn, "/agents?id=#{other_agent.id}")
  end

  test "shows no matches state when filters exclude all agents", %{conn: conn} do
    {:ok, _agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "runner"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, "/agents?status=stopped")

    assert html =~ "No agents match the current filters."
    assert html =~ "Reset filters"
  end

  defp create_agent(attrs) do
    attrs = Map.put_new(attrs, :user_id, @user_email)
    Agents.create_agent(attrs)
  end

  defp stop_agent_process(agent_id) do
    case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent_id) do
      [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
      [] -> :ok
    end
  end
end
