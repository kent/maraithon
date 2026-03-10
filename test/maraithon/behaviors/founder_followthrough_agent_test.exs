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

    assert recorded.count == 1
    assert recorded.user_id == user_id

    [stored | _] = Insights.list_open_for_user(user_id)
    assert stored.source == "slack"
    assert stored.metadata["record"]["status"] == "unresolved"
    assert stored.metadata["record"]["person"] == "U12345"
  end
end
