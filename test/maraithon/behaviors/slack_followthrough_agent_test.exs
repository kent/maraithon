defmodule Maraithon.Behaviors.SlackFollowthroughAgentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.SlackFollowthroughAgent
  alias Maraithon.Insights

  setup do
    user_id = "slack-advisor@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "slack_followthrough_agent",
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

    %{user_id: user_id, agent: agent, context: context}
  end

  describe "handle_wakeup/2" do
    test "records unresolved slack commitment from pubsub payload", %{
      user_id: user_id,
      context: context
    } do
      state =
        SlackFollowthroughAgent.init(%{
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
        SlackFollowthroughAgent.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert recorded.count == 1
      assert recorded.user_id == user_id

      [stored | _] = Insights.list_open_for_user(user_id)

      assert stored.source == "slack"
      assert stored.category in ["commitment_unresolved", "meeting_follow_up"]
      assert stored.metadata["record"]["status"] == "unresolved"
      assert stored.metadata["record"]["person"] == "U12345"
      assert stored.metadata["record"]["next_action"] =~ "Reply in the same Slack thread"
    end

    test "ignores closed loops when follow-through already happened", %{
      user_id: user_id,
      context: context
    } do
      state =
        SlackFollowthroughAgent.init(%{
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
              "text" => "I will send the notes to <@U_TEAM> today",
              "ts" => "1762502400.000001"
            },
            %{
              "source" => "slack",
              "team_id" => "T123",
              "channel_id" => "C456",
              "channel_name" => "planning",
              "user_id" => "U_SELF",
              "self_user_id" => "U_SELF",
              "text" => "Sent the notes here",
              "ts" => "1762503000.000001"
            }
          ]
        }
      }

      {:idle, _state} =
        SlackFollowthroughAgent.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert Insights.list_open_for_user(user_id) == []
    end

    test "downgrades Slack follow-through when another participant already replied", %{
      user_id: user_id,
      context: context
    } do
      state =
        SlackFollowthroughAgent.init(%{
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
            },
            %{
              "source" => "slack",
              "team_id" => "T123",
              "channel_id" => "C456",
              "channel_name" => "planning",
              "user_id" => "U_TEAM",
              "text" => "I'll handle this and send the update by today",
              "thread_ts" => "1762502400.000001",
              "ts" => "1762503000.000001"
            }
          ]
        }
      }

      {:emit, {:insights_recorded, recorded}, _state} =
        SlackFollowthroughAgent.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert recorded.count == 1

      [stored | _] = Insights.list_open_for_user(user_id)

      assert stored.metadata["conversation_context"]["notification_posture"] == "heads_up"
      assert stored.summary =~ "conversation is moving"
      assert stored.recommended_action =~ "Monitor the thread"
      assert stored.metadata["why_now"] =~ "already responded"
    end
  end
end
