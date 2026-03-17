defmodule Maraithon.Behaviors.FounderFollowthroughAgentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.FounderFollowthroughAgent
  alias Maraithon.Insights

  setup do
    user_id = "founder-followthrough@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: DateTime.utc_now(),
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    %{user_id: user_id, context: context}
  end

  test "records unresolved Slack commitment while running founder followthrough", %{
    user_id: user_id,
    context: context
  } do
    state =
      FounderFollowthroughAgent.init(%{
        "user_id" => user_id,
        "min_confidence" => "0.7",
        "max_insights_per_cycle" => "3"
      })

    payload = %{
      "source" => "slack",
      "data" => %{
        "messages" => [
          %{
            "source" => "slack",
            "team_id" => "T123",
            "channel_id" => "C456",
            "channel_name" => "planning",
            "user_id" => "U_SELF",
            "self_user_id" => "U_SELF",
            "text" => "I'll send the deck to <@U12345> by today",
            "ts" => "1762502400.000001"
          }
        ]
      }
    }

    {:emit, {:insights_recorded, recorded}, _state} =
      FounderFollowthroughAgent.handle_wakeup(state, %{context | event: %{payload: payload}})

    assert (recorded[:count] || recorded["count"]) == 1
    assert (recorded[:user_id] || recorded["user_id"]) == user_id

    [stored | _] = Insights.list_open_for_user(user_id)
    assert stored.source == "slack"
    assert stored.metadata["record"]["status"] == "unresolved"
    assert stored.metadata["record"]["person"] == "U12345"
  end

  test "initializes the chief-of-staff skill stack without travel", %{user_id: user_id} do
    state =
      FounderFollowthroughAgent.init(%{
        "user_id" => user_id,
        "email_scan_limit" => "21",
        "channel_scan_limit" => "45",
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "9"
      })

    assert state.enabled_skill_ids == ["followthrough", "briefing"]
    assert Map.has_key?(state.skill_states, "followthrough")
    assert Map.has_key?(state.skill_states, "briefing")
    refute Map.has_key?(state.skill_states, "travel_logistics")
    assert get_in(state, [:skill_configs, "followthrough", "email_scan_limit"]) == 21
    assert get_in(state, [:skill_configs, "followthrough", "channel_scan_limit"]) == 45

    assert get_in(state, [:skill_configs, "briefing", "assistant_behavior"]) ==
             "ai_chief_of_staff"
  end
end
