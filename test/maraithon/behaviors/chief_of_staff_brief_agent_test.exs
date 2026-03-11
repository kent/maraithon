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
end
