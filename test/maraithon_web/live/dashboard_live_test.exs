defmodule MaraithonWeb.DashboardLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.Insights

  @user_email "dashboard@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders control center sections without the old agent management panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")
    html = render(view)

    assert has_element?(view, "h1", "Agent Fleet Operations")
    assert has_element?(view, "h2", "Actionable Insights")
    assert has_element?(view, "h2", "Health & Monitoring")
    assert has_element?(view, "h3", "Operational Logs")
    assert has_element?(view, "h3", "Failures & Stale Work")
    assert has_element?(view, "h3", "Raw Logs")
    assert has_element?(view, "h3", "Fly.io Platform Logs")
    assert has_element?(view, "h2", "Agents moved into their own workspace")
    assert has_element?(view, "a[href='/agents']", "Manage Agents")
    assert has_element?(view, "a[href='/agents/new']", "New Agent")
    refute html =~ "Agent Registry"
    refute html =~ "Agent Details"
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
            "account" => @user_email,
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
    assert html =~ "from Gmail · account dashboard@example.com"
    assert html =~ "The customer asked for an update before today&#39;s review call."
    assert html =~ "Pull the latest status from support before replying."
    assert html =~ "Write down the two risks you need covered on the call."
  end

  test "shows dashboard metrics when agents exist", %{conn: conn} do
    {:ok, _running} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _degraded} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{},
        status: "degraded",
        started_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Total Agents"
    assert html =~ "Running"
    assert html =~ "Degraded"
    assert html =~ "LLM Calls"
    assert html =~ "Total Spend"
  end

  test "redirects legacy selected-agent dashboard URLs to the agents workspace", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "legacy-link"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} =
             live(conn, "/dashboard?id=#{agent.id}")

    assert redirect_id == agent.id
  end

  defp create_agent(attrs) do
    attrs = Map.put_new(attrs, :user_id, @user_email)
    Agents.create_agent(attrs)
  end
end
