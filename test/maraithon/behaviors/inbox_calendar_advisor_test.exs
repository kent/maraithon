defmodule Maraithon.Behaviors.InboxCalendarAdvisorTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.InboxCalendarAdvisor
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Repo

  setup do
    user_id = "advisor-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

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
              "thread_id" => "thread-1",
              "subject" => "Urgent: customer escalation",
              "snippet" => "Need response ASAP",
              "from" => "ceo@example.com",
              "to" => "ops@example.com, success@example.com",
              "labels" => ["INBOX", "IMPORTANT", "UNREAD"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      context = %{context | event: %{payload: payload}}

      {:effect, {:llm_call, params}, new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, context)

      assert is_map(params)
      assert params["temperature"] == 0.15
      assert length(new_state.pending_candidates) >= 1
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "thread-1"
      assert prompt =~ "IMPORTANT"
      assert prompt =~ "ops@example.com"
      assert prompt =~ "automated transactional receipts"
      assert prompt =~ "Uber Eats"
      assert prompt =~ "false_positive_risk"
    end

    test "includes Telegram feedback context in the llm prompt", %{
      user_id: user_id,
      agent: agent,
      context: context
    } do
      {:ok, [prior_insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Customer escalation follow-up",
            "summary" => "The user previously wanted fast escalation notices.",
            "recommended_action" => "Reply with a same-day update.",
            "priority" => 92,
            "confidence" => 0.9,
            "dedupe_key" => "feedback:prior:1"
          }
        ])

      Repo.insert!(
        Delivery.changeset(%Delivery{}, %{
          insight_id: prior_insight.id,
          user_id: user_id,
          channel: "telegram",
          destination: "12345",
          score: 0.91,
          threshold: 0.78,
          status: "feedback_helpful",
          feedback: "helpful",
          feedback_at: DateTime.utc_now()
        })
      )

      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-feedback",
              "subject" => "Urgent: board prep",
              "snippet" => "Need an agenda today",
              "from" => "ceo@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      {:effect, {:llm_call, params}, _new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert prompt =~ "Recent Telegram feedback JSON"
      assert prompt =~ "Customer escalation follow-up"
      assert prompt =~ "telegram_fit_score"
    end

    test "includes calendar context in the llm prompt", %{context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => context.user_id})

      payload = %{
        "source" => "google_calendar",
        "data" => %{
          "events" => [
            %{
              "event_id" => "evt-1",
              "summary" => "Customer QBR",
              "description" => "Discuss renewals, risks, and open escalations.",
              "location" => "Zoom",
              "organizer" => "vp@example.com",
              "start" => DateTime.add(DateTime.utc_now(), -2, :hour),
              "end" => DateTime.add(DateTime.utc_now(), -1, :hour),
              "attendees" => [
                %{
                  "email" => "vp@example.com",
                  "display_name" => "VP",
                  "response_status" => "accepted"
                },
                %{
                  "email" => "ae@example.com",
                  "display_name" => "AE",
                  "response_status" => "tentative"
                }
              ]
            }
          ]
        }
      }

      {:effect, {:llm_call, params}, _new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert prompt =~ "Zoom"
      assert prompt =~ "vp@example.com"
      assert prompt =~ "response_counts"
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
              "recommended_action" =>
                "Reply now, confirm next steps, and suggest a same-day checkpoint if needed.",
              "priority" => 95,
              "confidence" => 0.91,
              "actionability" => "actionable",
              "obligation_type" => "direct_human_request",
              "human_counterparty" => true,
              "missing_followthrough_evidence" => true,
              "interrupt_now" => true,
              "false_positive_risk" => 0.12,
              "reasoning_summary" =>
                "Human sender requested a same-day response and no reply evidence exists.",
              "telegram_fit_score" => 0.93,
              "telegram_fit_reason" => "User tends to value urgent email follow-ups in Telegram.",
              "why_now" => "The sender is asking for a same-day response on an active thread.",
              "follow_up_ideas" => [
                "Draft the reply with a clear owner and ETA.",
                "Flag any blockers before the next customer touchpoint."
              ]
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
      assert stored.category in ["reply_urgent", "commitment_unresolved", "meeting_follow_up"]
      assert stored.metadata["telegram_fit_score"] == 0.93
      assert stored.metadata["telegram_fit_reason"] =~ "urgent email"
      assert stored.metadata["feedback_tuned"] == true
      assert stored.metadata["why_now"] =~ "same-day response"
      assert stored.metadata["obligation_type"] == "direct_human_request"
      assert stored.metadata["human_counterparty"] == true
      assert stored.metadata["missing_followthrough_evidence"] == true
      assert stored.metadata["interrupt_now"] == true
      assert stored.metadata["false_positive_risk"] == 0.12
      assert stored.metadata["reasoning_summary"] =~ "no reply evidence"
      assert stored.metadata["record"]["status"] == "unresolved"
      assert is_binary(stored.metadata["record"]["commitment"])
      assert stored.metadata["record"]["next_action"] =~ "Reply"

      assert stored.metadata["follow_up_ideas"] == [
               "Draft the reply with a clear owner and ETA.",
               "Flag any blockers before the next customer touchpoint."
             ]
    end

    test "does not fall back to heuristic candidates when llm output is invalid", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-heuristic-fallback",
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

      assert state_after_wakeup.pending_candidates != []

      {:emit, {:insights_recorded, result}, final_state} =
        InboxCalendarAdvisor.handle_effect_result(
          {:llm_call, %{content: "not-json"}},
          state_after_wakeup,
          context
        )

      assert result.count == 0
      assert final_state.pending_candidates == []
      assert Insights.list_open_for_user(user_id) == []
    end

    test "drops llm items marked non-actionable", %{user_id: user_id, context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-receipt-no-action",
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
              "actionability" => "non_actionable",
              "confidence" => 0.95
            }
          ])
      }

      {:emit, {:insights_recorded, result}, final_state} =
        InboxCalendarAdvisor.handle_effect_result(
          {:llm_call, llm_response},
          state_after_wakeup,
          context
        )

      assert result.count == 0
      assert final_state.pending_candidates == []
      assert Insights.list_open_for_user(user_id) == []
    end
  end
end
