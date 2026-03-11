defmodule Maraithon.InsightNotificationPreferencesTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_preferences = Application.get_env(:maraithon, :preference_memory, [])

    Application.put_env(:maraithon, :insights, telegram_module: CapturingTelegram)

    Application.put_env(:maraithon, :preference_memory,
      llm_complete: fn prompt ->
        cond do
          String.contains?(prompt, "Instruction:\nignore receipts") ->
            {:ok,
             Jason.encode!(%{
               "reply" =>
                 "Understood. I'll stop surfacing receipt-style noise unless there's a real ask.",
               "rules" => [
                 %{
                   "id" => "ignore_receipts",
                   "kind" => "content_filter",
                   "label" => "Ignore receipt-style notifications",
                   "instruction" =>
                     "Suppress receipts, invoices, payment confirmations, and order confirmations unless there is a clear human ask or unresolved commitment.",
                   "applies_to" => ["gmail", "calendar", "slack", "telegram"],
                   "confidence" => 0.97,
                   "filters" => %{
                     "topics" => ["receipts", "payment_confirmations"],
                     "require_human_ask_to_override" => true
                   }
                 }
               ]
             })}

          String.contains?(prompt, "Feedback:\nnot_helpful") ->
            {:ok,
             Jason.encode!(%{
               "reply" => "Learned that receipt-style notifications are usually noise for you.",
               "rules" => [
                 %{
                   "id" => "ignore_receipts",
                   "kind" => "content_filter",
                   "label" => "Ignore receipt-style notifications",
                   "instruction" =>
                     "Suppress receipts, invoices, payment confirmations, and order confirmations unless there is a clear human ask or unresolved commitment.",
                   "applies_to" => ["gmail", "calendar", "slack", "telegram"],
                   "confidence" => 0.9,
                   "filters" => %{
                     "topics" => ["receipts", "payment_confirmations"],
                     "require_human_ask_to_override" => true
                   }
                 }
               ]
             })}

          true ->
            {:ok, Jason.encode!(%{"reply" => "No durable rule.", "rules" => []})}
        end
      end
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :preference_memory, original_preferences)
    end)

    user_id = "notify-preferences@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "telegram /prefer stores a durable rule and replies in chat", %{user_id: user_id} do
    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, text: "/prefer ignore receipts"}
      })

    assert [%{"id" => "ignore_receipts"}] = PreferenceMemory.active_rules(user_id)

    message = last_telegram_message(:send)
    assert message.chat_id == "12345"
    assert message.text =~ "receipt-style noise"
  end

  test "telegram callback feedback can learn a durable preference", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Your payment was successful",
          "summary" => "A payment confirmation with no human ask.",
          "recommended_action" => "No reply needed.",
          "priority" => 88,
          "confidence" => 0.84,
          "dedupe_key" => "preferences:receipt:1",
          "metadata" => %{
            "account" => "kent@runner.now",
            "from" => "billing@vendor.com",
            "subject" => "Receipt"
          }
        }
      ])

    _ = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb_pref_1",
          chat_id: 12345,
          data: "insfb:#{delivery.id}:n"
        }
      })

    assert [%{"id" => "ignore_receipts"}] = PreferenceMemory.active_rules(user_id)

    callback = last_telegram_message(:callback)
    assert callback.opts[:text] =~ "Learned"
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.find(&1, fn message -> message.type == type end))
  end
end
