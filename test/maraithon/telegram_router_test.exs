defmodule Maraithon.TelegramRouterTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_interpreter = Application.get_env(:maraithon, :telegram_interpreter, [])
    original_operator_memory = Application.get_env(:maraithon, :operator_memory, [])
    original_google = Application.get_env(:maraithon, :gmail, [])
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights,
        telegram_module: CapturingTelegram,
        default_sender_name: "Kent"
      )
    )

    Application.put_env(
      :maraithon,
      :operator_memory,
      Keyword.merge(original_operator_memory,
        llm_complete: fn _prompt ->
          {:ok,
           Jason.encode!(%{
             "content" => "Operator prefers signal over noise and concise action drafts."
           })}
        end
      )
    )

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime,
        llm_provider: Maraithon.TestSupport.ActionDraftLLM,
        llm_provider_name: "test-action-draft"
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :telegram_interpreter, original_interpreter)
      Application.put_env(:maraithon, :operator_memory, original_operator_memory)
      Application.put_env(:maraithon, :gmail, original_google)
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    user_id = "telegram-router@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{"timezone_offset_hours" => -5}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "replying to an insight can autosave a durable rule and refresh summaries", %{
    user_id: user_id,
    agent: agent
  } do
    set_interpreter(fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "intent" => "feedback_general",
         "confidence" => 0.96,
         "scope" => "durable",
         "needs_clarification" => false,
         "assistant_reply" =>
           "Understood. I’ll treat receipt-style emails as noise unless they imply follow-up work.",
         "candidate_rules" => [
           %{
             "id" => "ignore_receipts",
             "kind" => "content_filter",
             "label" => "Ignore routine receipts",
             "instruction" =>
               "Downrank routine receipt and transactional confirmation emails unless they imply unresolved follow-up work.",
             "applies_to" => ["gmail", "telegram"],
             "confidence" => 0.96,
             "filters" => %{"topics" => ["receipts", "transactional_receipts"]}
           }
         ],
         "candidate_action" => nil,
         "feedback_target" => %{},
         "memory_summary_updates" => [],
         "explanation" =>
           "The operator is expressing a durable preference about receipt-style emails."
       })}
    end)

    delivery = create_and_dispatch_gmail_delivery(user_id, agent.id)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9001,
          text: "These receipts are noise unless they imply follow-up work.",
          reply_to: %{message_id: delivery.provider_message_id}
        }
      })

    assert [%{"id" => "ignore_receipts", "status" => "active"}] =
             PreferenceMemory.active_rules(user_id)

    assert OperatorMemory.summaries_for_prompt(user_id) != []

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert conversation.linked_delivery_id == delivery.id
    assert conversation.status == "open"

    turns =
      Turn
      |> where([turn], turn.conversation_id == ^conversation.id)
      |> order_by([turn], asc: turn.inserted_at)
      |> Repo.all()

    assert Enum.map(turns, & &1.role) == ["user", "assistant"]
    assert Enum.any?(turns, &String.contains?(&1.text, "receipts are noise"))
    assert Enum.any?(turns, &String.contains?(&1.text, "receipt-style emails"))

    reply = last_telegram_message(:send)
    assert reply.text =~ "receipt-style emails"
    refute button_labels(reply.opts) |> Enum.member?("Remember This")
  end

  test "medium-confidence rules ask for confirmation and a plain-text yes confirms them", %{
    user_id: user_id,
    agent: agent
  } do
    set_interpreter(fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "intent" => "feedback_general",
         "confidence" => 0.79,
         "scope" => "durable",
         "needs_clarification" => false,
         "assistant_reply" =>
           "I think you want me to remember that investor threads are urgent. Should I save that rule?",
         "candidate_rules" => [
           %{
             "id" => "investors_are_urgent",
             "kind" => "urgency_boost",
             "label" => "Treat investors as urgent",
             "instruction" =>
               "Treat investor-related loops as urgent across Gmail, Calendar, Slack, and Telegram.",
             "applies_to" => ["gmail", "calendar", "slack", "telegram"],
             "confidence" => 0.79,
             "filters" => %{"topics" => ["investor"], "priority_bias" => "high"}
           }
         ],
         "candidate_action" => nil,
         "feedback_target" => %{},
         "memory_summary_updates" => [],
         "explanation" => "The operator is expressing a likely durable urgency preference."
       })}
    end)

    delivery =
      create_and_dispatch_gmail_delivery(user_id, agent.id, %{"subject" => "Investor update"})

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9002,
          text: "Anything from investors like this should be urgent.",
          reply_to: %{message_id: delivery.provider_message_id}
        }
      })

    assert [%{"id" => "investors_are_urgent", "status" => "pending_confirmation"}] =
             PreferenceMemory.pending_rules(user_id)

    confirmation_prompt = last_telegram_message(:send)
    assert confirmation_prompt.text =~ "Should I save that rule?"
    assert button_labels(confirmation_prompt.opts) |> Enum.member?("Remember This")

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert conversation.status == "awaiting_confirmation"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9003,
          text: "Yes"
        }
      })

    assert [%{"id" => "investors_are_urgent", "status" => "active"}] =
             PreferenceMemory.active_rules(user_id)

    assert PreferenceMemory.pending_rules(user_id) == []
    assert Repo.get!(Conversation, conversation.id).status == "closed"

    reply = last_telegram_message(:send)
    assert reply.text =~ "saved that as a durable rule"
  end

  test "general Telegram DM can answer from open insights without a linked reply", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the deck to Sarah",
          "summary" => "You promised Sarah the deck and no reply has gone out yet.",
          "recommended_action" => "Reply in the same thread with the deck.",
          "priority" => 96,
          "confidence" => 0.93,
          "dedupe_key" => "telegram-router:open:1",
          "metadata" => %{"account" => "kent@example.com"}
        }
      ])

    set_interpreter(fn prompt ->
      assert prompt =~ "Send the deck to Sarah"

      {:ok,
       Jason.encode!(%{
         "intent" => "general_chat",
         "confidence" => 0.91,
         "scope" => "general",
         "needs_clarification" => false,
         "assistant_reply" =>
           "Right now you owe Sarah the deck in Gmail. That’s the highest-priority open loop I can see.",
         "candidate_rules" => [],
         "candidate_action" => nil,
         "feedback_target" => %{},
         "memory_summary_updates" => [],
         "explanation" => "The operator asked for a general status summary."
       })}
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9004, text: "What do I owe today?"}
      })

    reply = last_telegram_message(:send)
    assert reply.text =~ "owe Sarah the deck"
    assert reply.opts[:reply_to] == "9004"

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert is_nil(conversation.linked_delivery_id)
    assert conversation.status == "open"
  end

  test "question-about-insight replies include why-now and evidence", %{
    user_id: user_id,
    agent: agent
  } do
    set_interpreter(fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "intent" => "question_about_insight",
         "confidence" => 0.93,
         "scope" => "thread_local",
         "needs_clarification" => false,
         "assistant_reply" => "This was a direct promise with no completion evidence.",
         "candidate_rules" => [],
         "candidate_action" => nil,
         "feedback_target" => %{},
         "memory_summary_updates" => [],
         "explanation" => "The operator is asking for rationale."
       })}
    end)

    delivery = create_and_dispatch_gmail_delivery(user_id, agent.id)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 90041,
          text: "Why did you send this?",
          reply_to: %{message_id: delivery.provider_message_id}
        }
      })

    reply = last_telegram_message(:send)
    assert reply.text =~ "Why now:"
    assert reply.text =~ "Evidence checked:"
    assert reply.text =~ "Recommended action:"
    assert reply.text =~ "direct promise"
  end

  test "clarification questions are tracked and cleared when the user answers", %{
    user_id: user_id
  } do
    start_supervised!(%{
      id: :telegram_interpreter_sequence,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_interpreter_sequence]]}
    })

    set_interpreter(fn _prompt ->
      call_number =
        Agent.get_and_update(:telegram_interpreter_sequence, fn current ->
          {current, current + 1}
        end)

      if call_number == 0 do
        {:ok,
         Jason.encode!(%{
           "intent" => "unknown",
           "confidence" => 0.52,
           "scope" => "thread_local",
           "needs_clarification" => true,
           "clarifying_question" =>
             "Do you want me to remember this as a general rule, or only for this one thread?",
           "assistant_reply" => nil,
           "candidate_rules" => [],
           "candidate_action" => nil,
           "feedback_target" => %{},
           "memory_summary_updates" => [],
           "explanation" => "The scope is ambiguous."
         })}
      else
        {:ok,
         Jason.encode!(%{
           "intent" => "feedback_general",
           "confidence" => 0.95,
           "scope" => "durable",
           "needs_clarification" => false,
           "assistant_reply" => "Understood. I’ll treat these as a saved noise preference.",
           "candidate_rules" => [
             %{
               "id" => "downrank_generic_noise",
               "kind" => "content_filter",
               "label" => "Downrank generic noise",
               "instruction" =>
                 "Downrank generic low-signal notifications unless they imply real follow-up work.",
               "applies_to" => ["gmail", "telegram"],
               "confidence" => 0.95,
               "filters" => %{"topics" => ["generic_noise"]}
             }
           ],
           "candidate_action" => nil,
           "feedback_target" => %{},
           "memory_summary_updates" => [],
           "explanation" => "The user clarified that the preference is durable."
         })}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 90042, text: "Make these less noisy"}
      })

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert conversation.metadata["pending_clarification"]
    assert conversation.metadata["clarification_depth"] == 1

    clarification = last_telegram_message(:send)
    assert clarification.text =~ "general rule"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 90043, text: "General rule, not just this thread"}
      })

    updated = Repo.get!(Conversation, conversation.id)
    refute updated.metadata["pending_clarification"]
    assert [%{"id" => "downrank_generic_noise"}] = PreferenceMemory.active_rules(user_id)
  end

  test "freeform action requests can execute a drafted Gmail send from Telegram", %{
    user_id: user_id,
    agent: agent
  } do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "google-access",
        refresh_token: "google-refresh",
        expires_in: 3600
      })

    delivery = create_and_dispatch_gmail_delivery(user_id, agent.id)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-draft",
          chat_id: 12345,
          message_id: delivery.provider_message_id,
          data: "insact:#{delivery.id}:draft"
        }
      })

    set_interpreter(fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "intent" => "action_execute",
         "confidence" => 0.95,
         "scope" => "thread_local",
         "needs_clarification" => false,
         "assistant_reply" => "Sending it now.",
         "candidate_rules" => [],
         "candidate_action" => %{
           "action" => "send",
           "confidence" => 0.95,
           "requires_confirmation" => false,
           "reason" => "The operator explicitly asked to send the existing draft."
         },
         "feedback_target" => %{},
         "memory_summary_updates" => [],
         "explanation" => "The operator wants to execute the already prepared draft."
       })}
    end)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/msg-in-1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "msg-in-1",
          "threadId" => "thread-1",
          "snippet" => "Original message",
          "payload" => %{
            "headers" => [
              %{"name" => "Message-ID", "value" => "<source-message@example.com>"},
              %{"name" => "References", "value" => "<older-message@example.com>"}
            ]
          }
        })
      )
    end)

    Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/messages/send", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      decoded = Base.url_decode64!(payload["raw"], padding: false)
      assert decoded =~ "Following up on this now."

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"id":"gmail-sent-1","threadId":"thread-1","labelIds":["SENT"]}))
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9005,
          text: "Send that now",
          reply_to: %{message_id: delivery.provider_message_id}
        }
      })

    updated_delivery = Repo.get!(Delivery, delivery.id)
    updated_insight = Repo.get!(Maraithon.Insights.Insight, delivery.insight_id)

    assert get_in(updated_delivery.metadata, ["telegram_action", "status"]) == "executed"
    assert updated_insight.status == "acknowledged"

    reply = last_telegram_message(:send)
    assert reply.text =~ "Completed"
    assert reply.text =~ "Sent via Gmail"
  end

  test "draft generation prompt includes long-term memory summaries and style rules", %{
    user_id: user_id,
    agent: agent
  } do
    start_supervised!(%{
      id: :action_draft_prompt_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :action_draft_prompt_recorder]]}
    })

    {:ok, _saved_rules} =
      PreferenceMemory.save_interpreted_rules(
        user_id,
        [
          %{
            "id" => "short_direct_replies",
            "kind" => "style_preference",
            "label" => "Prefer short direct replies",
            "instruction" =>
              "Prefer short, direct, low-apology drafts with a crisp ETA when possible.",
            "applies_to" => ["gmail", "slack", "telegram"],
            "confidence" => 0.97,
            "filters" => %{}
          }
        ],
        "telegram_inferred"
      )

    delivery = create_and_dispatch_gmail_delivery(user_id, agent.id)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-draft-memory",
          chat_id: 12345,
          message_id: delivery.provider_message_id,
          data: "insact:#{delivery.id}:draft"
        }
      })

    [prompt | _] = Agent.get(:action_draft_prompt_recorder, & &1)
    assert prompt =~ "Prefer short, direct, low-apology drafts"
    assert prompt =~ "Operator prefers signal over noise and concise action drafts."
    assert prompt =~ "\"style_preference\""
  end

  test "edited Telegram messages update the stored conversation turn", %{user_id: user_id} do
    set_interpreter(fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "intent" => "general_chat",
         "confidence" => 0.85,
         "scope" => "general",
         "needs_clarification" => false,
         "assistant_reply" => "I’m tracking that request.",
         "candidate_rules" => [],
         "candidate_action" => nil,
         "feedback_target" => %{},
         "memory_summary_updates" => [],
         "explanation" => "Simple general-chat acknowledgement."
       })}
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9006, text: "What do I owe this week?"}
      })

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "edited_message",
        data: %{chat_id: 12345, message_id: 9006, text: "What do I owe right now?"}
      })

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    turn =
      Repo.one!(
        from turn in Turn,
          where: turn.conversation_id == ^conversation.id and turn.telegram_message_id == "9006",
          limit: 1
      )

    assert turn.text == "What do I owe right now?"
  end

  defp create_and_dispatch_gmail_delivery(user_id, agent_id, overrides \\ %{}) do
    defaults = %{
      "source" => "gmail",
      "category" => "commitment_unresolved",
      "title" => "You said you'd send the deck to Sarah today. No reply has gone out yet.",
      "summary" =>
        "The commitment still appears open for Sarah and no completion evidence was found in sent email.",
      "recommended_action" =>
        "Send the promised follow-through now and explicitly confirm delivery in the same thread.",
      "priority" => 96,
      "confidence" => 0.93,
      "source_id" => "msg-in-1",
      "dedupe_key" => "telegram-router:gmail:#{System.unique_integer([:positive])}",
      "metadata" => %{
        "account" => "kent@example.com",
        "thread_id" => "thread-1",
        "to" => "Sarah <sarah@example.com>",
        "subject" => "Investor deck",
        "context_brief" => "Explicit promise made to Sarah.",
        "record" => %{
          "person" => "Sarah",
          "commitment" => "Send the deck to Sarah",
          "evidence" => ["No later reply or delivery was found."],
          "next_action" =>
            "Send the promised follow-through now and explicitly confirm delivery in the same thread."
        }
      }
    }

    {:ok, [insight]} =
      Insights.record_many(user_id, agent_id, [deep_merge(defaults, overrides)])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")
  end

  defp set_interpreter(fun) when is_function(fun, 1) do
    Application.put_env(:maraithon, :telegram_interpreter, llm_complete: fun)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end

  defp button_labels(opts) do
    opts
    |> Keyword.get(:reply_markup, %{})
    |> Map.get("inline_keyboard", [])
    |> List.flatten()
    |> Enum.map(& &1["text"])
  end
end
