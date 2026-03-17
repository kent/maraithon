defmodule Maraithon.Behaviors.ChiefOfStaffBriefAgentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.ChiefOfStaffBriefAgent
  alias Maraithon.Briefs
  alias Maraithon.Insights

  setup do
    user_id = "chief-of-staff@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    %{user_id: user_id, agent: agent}
  end

  test "records a morning brief from open insights when the schedule is due", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 13:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the investor deck",
          "summary" =>
            "You promised Sarah the updated deck and no sent follow-up has been found.",
          "recommended_action" => "Reply in the same thread with the deck or a firm ETA.",
          "priority" => 94,
          "confidence" => 0.91,
          "dedupe_key" => "brief-test:deck",
          "due_at" => scheduled_at,
          "metadata" => %{"account" => user_id}
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.count == 1
    assert payload.user_id == user_id
    assert payload.cadences == ["morning"]
    assert next_state.last_generated_keys["morning"] == "2026-03-11"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "morning"
    assert brief.title =~ "Morning brief"
    assert brief.body =~ "Send the investor deck"
  end

  test "renders end-of-day briefs as concrete next actions with why-now context", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 23:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "important_fyi",
          "title" => "Account risk: Meta Ad Account Blocked",
          "summary" =>
            "This looks like an account restriction or access issue that can block work or revenue.",
          "recommended_action" =>
            "Open the notice now, confirm the exact restriction, and coordinate the unblock owner today.",
          "priority" => 96,
          "confidence" => 0.94,
          "dedupe_key" => "brief-test:meta-blocked",
          "due_at" => DateTime.add(scheduled_at, -2, :hour),
          "metadata" => %{
            "why_now" =>
              "A blocked or restricted account can stop important work until someone resolves it."
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert "end_of_day" in payload.cadences

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "end_of_day"
    assert brief.body =~ "Tonight's top actions"
    assert brief.body =~ "Next: Open the notice now"
    assert brief.body =~ "Why now: Overdue since"
  end

  test "keeps monitor items out of top actions and includes them in Watching", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 23:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the investor deck",
          "summary" => "You still owe the investor deck today.",
          "recommended_action" => "Reply in the same thread with the deck or a firm ETA.",
          "priority" => 94,
          "confidence" => 0.91,
          "dedupe_key" => "brief-test:act-now",
          "due_at" => DateTime.add(scheduled_at, -2, :hour),
          "metadata" => %{"why_now" => "Overdue since the promised send time."}
        },
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Monitoring: Meta Ad Account thread",
          "summary" => "The thread is active and being handled, but it still matters.",
          "recommended_action" =>
            "Watch for a blocker, a direct ask back to you, or a stall in progress.",
          "priority" => 88,
          "confidence" => 0.87,
          "attention_mode" => "monitor",
          "dedupe_key" => "brief-test:monitor",
          "tracking_key" => "brief-test:monitor",
          "due_at" => DateTime.add(scheduled_at, -1, :hour),
          "metadata" => %{
            "why_now" => "Breck acknowledged the thread and is checking his side."
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, _payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)

    assert brief.body =~ "Tonight's top actions:"
    assert brief.body =~ "[Gmail] Send the investor deck"
    assert brief.body =~ "Watching:"
    assert brief.body =~ "[Gmail] Monitoring: Meta Ad Account thread"
    assert brief.body =~ "important threads are being watched"
  end
end
