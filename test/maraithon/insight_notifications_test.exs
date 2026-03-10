defmodule Maraithon.InsightNotificationsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.{Delivery, ThresholdProfile}
  alias Maraithon.Insights
  alias Maraithon.Repo

  setup do
    Application.put_env(:maraithon, :insights,
      telegram_module: Maraithon.TestSupport.FakeTelegram
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :insights)
    end)

    user_id = "notify-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply to customer escalation",
          "summary" => "The thread is urgent and needs a same-day response.",
          "recommended_action" => "Reply immediately with resolution steps.",
          "priority" => 96,
          "confidence" => 0.94,
          "dedupe_key" => "email:notify:reply_urgent"
        }
      ])

    %{user_id: user_id, insight: insight}
  end

  describe "dispatch_telegram_batch/1" do
    test "stages and sends eligible insights", %{user_id: user_id, insight: insight} do
      result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

      assert result.staged >= 1
      assert result.sent == 1

      delivery =
        Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

      assert delivery.status == "sent"
      assert delivery.provider_message_id == "123"
      assert delivery.score >= delivery.threshold
    end
  end

  describe "handle_telegram_event/1" do
    test "links telegram chat from start command" do
      user_id = "link-user@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      event = %{
        type: "message",
        data: %{
          chat_id: 998_877,
          text: "/start #{user_id}",
          from: %{id: 1001, username: "linker"}
        }
      }

      :ok = InsightNotifications.handle_telegram_event(event)

      account = ConnectedAccounts.get(user_id, "telegram")
      assert account.status == "connected"
      assert account.external_account_id == "998877"
    end

    test "links telegram chat from start command with bot mention" do
      user_id = "link-bot-mention@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      event = %{
        type: "message",
        data: %{
          chat_id: 445_566,
          text: "/start@maraithon_bot #{user_id}",
          from: %{id: 1002, username: "linker2"}
        }
      }

      :ok = InsightNotifications.handle_telegram_event(event)

      account = ConnectedAccounts.get(user_id, "telegram")
      assert account.status == "connected"
      assert account.external_account_id == "445566"
    end

    test "records callback feedback and tunes threshold", %{user_id: user_id, insight: insight} do
      _ = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

      delivery =
        Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

      {:ok, profile_before} = InsightNotifications.get_or_create_profile(user_id)

      :ok =
        InsightNotifications.handle_telegram_event(%{
          type: "callback_query",
          data: %{
            callback_id: "cb_1",
            chat_id: 12345,
            data: "insfb:#{delivery.id}:n"
          }
        })

      updated_delivery = Repo.get!(Delivery, delivery.id)
      updated_profile = Repo.get_by!(ThresholdProfile, user_id: user_id)
      dismissed = Repo.get!(Maraithon.Insights.Insight, insight.id)

      assert updated_delivery.feedback == "not_helpful"
      assert updated_delivery.status == "feedback_not_helpful"
      assert updated_profile.score_threshold > profile_before.score_threshold
      assert dismissed.status == "dismissed"
    end

    test "uses ai-derived telegram fit score when deciding whether to send", %{
      user_id: user_id,
      insight: insight
    } do
      insight
      |> Ecto.Changeset.change(metadata: %{"telegram_fit_score" => 0.41})
      |> Repo.update!()

      result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

      assert result.staged == 0
      assert result.sent == 0

      assert Repo.get_by(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram") ==
               nil
    end
  end
end
