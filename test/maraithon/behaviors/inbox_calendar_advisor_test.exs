defmodule Maraithon.Behaviors.InboxCalendarAdvisorTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Behaviors.InboxCalendarAdvisor
  alias Maraithon.Insights

  setup do
    user_id = "advisor-user@example.com"

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
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
    test "produces llm effect from gmail pubsub payload", %{context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => context.user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-1",
              "subject" => "Urgent: customer escalation",
              "snippet" => "Need response ASAP",
              "from" => "ceo@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      context = %{context | event: %{payload: payload}}

      {:effect, {:llm_call, params}, new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, context)

      assert is_map(params)
      assert params["temperature"] == 0.2
      assert length(new_state.pending_candidates) >= 1
    end

    test "returns idle when user id missing", %{context: context} do
      state = InboxCalendarAdvisor.init(%{})
      context = %{context | user_id: nil, event: nil}

      assert {:idle, _state} = InboxCalendarAdvisor.handle_wakeup(state, context)
    end
  end

  describe "handle_effect_result/3" do
    test "persists refined insights", %{user_id: user_id, context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-2",
              "subject" => "Urgent follow-up needed",
              "snippet" => "Please respond today",
              "from" => "ops@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      {:effect, {:llm_call, _params}, state_after_wakeup} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      dedupe_key = hd(state_after_wakeup.pending_candidates)["dedupe_key"]

      llm_response = %{
        content:
          Jason.encode!([
            %{
              "dedupe_key" => dedupe_key,
              "title" => "Reply to ops today",
              "summary" => "This looks time-sensitive and should be acknowledged quickly.",
              "recommended_action" => "Reply now and confirm next steps.",
              "priority" => 95,
              "confidence" => 0.91
            }
          ])
      }

      {:emit, {:insights_recorded, payload}, final_state} =
        InboxCalendarAdvisor.handle_effect_result(
          {:llm_call, llm_response},
          state_after_wakeup,
          context
        )

      assert payload.count == 1
      assert payload.user_id == user_id
      assert final_state.pending_candidates == []

      [stored | _] = Insights.list_open_for_user(user_id)
      assert stored.title == "Reply to ops today"
      assert stored.priority == 95
      assert stored.category in ["reply_urgent", "tone_risk"]
    end
  end
end
