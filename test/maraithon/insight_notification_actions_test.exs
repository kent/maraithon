defmodule Maraithon.InsightNotificationActionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.Repo

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_google = Application.get_env(:maraithon, :gmail, [])
    original_slack = Application.get_env(:maraithon, :slack, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights,
        telegram_module: Maraithon.TestSupport.CapturingTelegram,
        default_sender_name: "Kent"
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
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      Application.put_env(:maraithon, :gmail, original_google)
      Application.put_env(:maraithon, :slack, original_slack)
    end)

    user_id = "telegram-actions@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{agent: agent, user_id: user_id}
  end

  test "drafts and sends a Gmail follow-up directly from Telegram", %{
    agent: agent,
    user_id: user_id
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

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
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
          "dedupe_key" => "telegram-actions:gmail:1",
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
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert sent.text =~ "Maraithon Insight"
    assert button_labels(sent.opts) |> Enum.member?("Draft Email")
    assert button_labels(sent.opts) |> Enum.member?("Mark Done")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-draft",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:draft"
        }
      })

    drafted_delivery = Repo.get!(Delivery, delivery.id)
    assert get_in(drafted_delivery.metadata, ["telegram_action", "status"]) == "drafted"

    drafted = last_telegram_message(:edit)
    assert drafted.text =~ "Email draft ready"
    assert drafted.text =~ "Re: Quick follow-up"
    assert button_labels(drafted.opts) |> Enum.member?("Send Now")

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/msg-in-1", fn conn ->
      assert conn.query_string =~ "format=metadata"
      assert conn.query_string =~ "metadataHeaders=Message-ID"

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
      assert payload["threadId"] == "thread-1"

      decoded = Base.url_decode64!(payload["raw"], padding: false)
      assert decoded =~ "To: Sarah <sarah@example.com>"
      assert decoded =~ "Subject: Re: Quick follow-up"
      assert decoded =~ "In-Reply-To: <source-message@example.com>"
      assert decoded =~ "Following up on this now."

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"id":"gmail-sent-1","threadId":"thread-1","labelIds":["SENT"]}))
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-send",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:send"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    updated_delivery = Repo.get!(Delivery, delivery.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert get_in(updated_delivery.metadata, ["telegram_action", "status"]) == "executed"
    assert completed.text =~ "Completed"
    assert completed.text =~ "Sent via Gmail"
  end

  test "drafts and sends a Slack reply directly from Telegram", %{agent: agent, user_id: user_id} do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:T123", %{
        access_token: "slack-access",
        refresh_token: "slack-refresh",
        expires_in: 3600
      })

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "slack",
          "category" => "reply_urgent",
          "title" => "Slack reply owed to Sarah",
          "summary" => "You still owe Sarah a Slack response and no reply was detected.",
          "recommended_action" =>
            "Send a Slack reply now with owner, next step, and a concrete timing commitment.",
          "priority" => 91,
          "confidence" => 0.89,
          "source_id" => "slack:T123:C999:171234.000100",
          "dedupe_key" => "telegram-actions:slack:1",
          "metadata" => %{
            "team_id" => "T123",
            "channel_id" => "C999",
            "channel_name" => "customer-thread",
            "thread_ts" => "171234.000100",
            "record" => %{
              "person" => "Sarah",
              "commitment" => "Reply to Sarah in Slack",
              "evidence" => ["No reply from you was found afterward in this conversation."],
              "next_action" =>
                "Send a Slack reply now with owner, next step, and a concrete timing commitment."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert button_labels(sent.opts) |> Enum.member?("Draft Slack")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-slack-draft",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:draft"
        }
      })

    drafted = last_telegram_message(:edit)
    assert drafted.text =~ "Slack draft ready"
    assert drafted.text =~ "Owner is me"

    Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["channel"] == "C999"
      assert payload["thread_ts"] == "171234.000100"
      assert payload["text"] =~ "Owner is me"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":true,"ts":"171235.000200"}))
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-slack-send",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:send"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    updated_delivery = Repo.get!(Delivery, delivery.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert get_in(updated_delivery.metadata, ["telegram_action", "status"]) == "executed"
    assert completed.text =~ "Sent in Slack"
  end

  test "marks an insight complete directly from Telegram", %{agent: agent, user_id: user_id} do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "calendar",
          "category" => "meeting_follow_up",
          "title" => "Post-meeting follow-up owed: Monday planning",
          "summary" => "After the Monday planning meeting, you still owe owners and next steps.",
          "recommended_action" =>
            "Send a short recap covering owners, next steps, and due dates.",
          "priority" => 88,
          "confidence" => 0.84,
          "dedupe_key" => "telegram-actions:calendar:1"
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert button_labels(sent.opts) |> Enum.member?("Mark Done")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-done",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:done"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert completed.text =~ "Marked complete from Telegram"
  end

  test "acknowledges important FYI insights directly from Telegram", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "important_fyi",
          "title" => "Platform status: App Store Connect In Review",
          "summary" =>
            "App review status changed. This is important FYI because it affects release timing.",
          "recommended_action" =>
            "Acknowledge the status change and monitor it; step in only if the review stalls or changes again.",
          "priority" => 83,
          "confidence" => 0.88,
          "dedupe_key" => "telegram-actions:fyi:1",
          "metadata" => %{
            "ackable" => true,
            "why_now" => "App review state changed and could affect release planning."
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert button_labels(sent.opts) |> Enum.member?("Ack")
    refute button_labels(sent.opts) |> Enum.member?("Draft Email")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-ack",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:ack"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert completed.text =~ "Acknowledged from Telegram"
  end

  test "renders conversation-progress language for heads_up insights in Telegram", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Gmail thread moving with Charlie",
          "summary" =>
            "Charlie has already responded and the conversation is moving. You may still need to close the final loop.",
          "recommended_action" =>
            "Monitor the thread and close the final loop if the owner, artifact, or ETA is still yours.",
          "priority" => 88,
          "confidence" => 0.9,
          "dedupe_key" => "telegram-actions:gmail:heads-up",
          "metadata" => %{
            "why_now" =>
              "Charlie has already responded and the conversation is moving. The final follow-through may still be yours.",
            "conversation_context" => %{
              "notification_posture" => "heads_up",
              "latest_actor" => "Charlie"
            },
            "record" => %{
              "person" => "David",
              "commitment" => "Reply to David on Cowrie Agora Update",
              "evidence" => ["Charlie replied later in the conversation."],
              "next_action" =>
                "Monitor the thread and close the final loop if the owner, artifact, or ETA is still yours."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)
    assert sent.text =~ "Charlie has already responded"
    assert sent.text =~ "conversation is moving"
    assert sent.text =~ "Monitor the thread"
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
