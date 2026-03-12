defmodule Maraithon.InsightsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights

  setup do
    user_id = "insights-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{}
      })

    %{user_id: user_id, agent: agent}
  end

  describe "record_many/3" do
    test "inserts and upserts by dedupe key", %{user_id: user_id, agent: agent} do
      {:ok, [first]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to contract email",
            "summary" => "The sender asks for a same-day reply.",
            "recommended_action" => "Reply before end of day.",
            "priority" => 72,
            "confidence" => 0.81,
            "dedupe_key" => "email:abc:reply_urgent"
          }
        ])

      assert first.status == "new"
      assert first.priority == 72

      {:ok, _} = Insights.acknowledge(user_id, first.id)

      {:ok, [updated]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to contract email now",
            "summary" => "Escalation risk if ignored.",
            "recommended_action" => "Send acknowledgment and timeline.",
            "priority" => 92,
            "confidence" => 0.93,
            "dedupe_key" => "email:abc:reply_urgent"
          }
        ])

      assert updated.id == first.id
      assert updated.status == "new"
      assert updated.priority == 92
      assert updated.title == "Reply to contract email now"
    end
  end

  describe "list_open_for_user/2" do
    test "hides future-snoozed insights and shows active ones", %{user_id: user_id, agent: agent} do
      {:ok, [snoozed]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "calendar",
            "category" => "event_prep_needed",
            "title" => "Prep for board meeting",
            "summary" => "Board meeting prep needed.",
            "recommended_action" => "Draft key talking points.",
            "dedupe_key" => "calendar:1:event_prep_needed"
          }
        ])

      {:ok, [_active]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to legal",
            "summary" => "Legal requested immediate response.",
            "recommended_action" => "Reply and confirm receipt.",
            "dedupe_key" => "email:2:reply_urgent"
          }
        ])

      {:ok, _} = Insights.snooze(user_id, snoozed.id, DateTime.add(DateTime.utc_now(), 4, :hour))

      open = Insights.list_open_for_user(user_id)
      open_ids = Enum.map(open, & &1.id)

      refute snoozed.id in open_ids
      assert length(open_ids) == 1
    end
  end

  describe "list_open_with_details_for_user/2" do
    test "preserves ordering and loads related delivery detail", %{user_id: user_id, agent: agent} do
      {:ok, [first]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "commitment_unresolved",
            "title" => "Send the pricing doc to Sarah",
            "summary" => "The pricing doc still appears open.",
            "recommended_action" => "Send the pricing doc now.",
            "priority" => 95,
            "confidence" => 0.92,
            "dedupe_key" => "detail:first",
            "metadata" => %{
              "record" => %{
                "commitment" => "Send the pricing doc to Sarah",
                "person" => "Sarah",
                "status" => "unresolved",
                "evidence" => ["No follow-up email was found."],
                "next_action" => "Send the promised follow-through now."
              }
            }
          }
        ])

      {:ok, [second]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "calendar",
            "category" => "meeting_follow_up",
            "title" => "Send the board recap",
            "summary" => "The board recap still appears open.",
            "recommended_action" => "Send owners and next steps.",
            "priority" => 70,
            "confidence" => 0.75,
            "dedupe_key" => "detail:second"
          }
        ])

      {:ok, _delivery} =
        %Delivery{}
        |> Delivery.changeset(%{
          insight_id: first.id,
          user_id: user_id,
          channel: "telegram",
          destination: "12345",
          score: 0.95,
          threshold: 0.8,
          status: "sent",
          sent_at: DateTime.utc_now()
        })
        |> Repo.insert()

      cards = Insights.list_open_with_details_for_user(user_id)

      assert Enum.map(cards, & &1.insight.id) == [first.id, second.id]
      assert hd(cards).detail.promise_text.text == "Send the pricing doc to Sarah"
      assert hd(cards).detail.delivery_evidence != []
      assert List.last(cards).detail.delivery_evidence == []
    end
  end

  describe "status updates" do
    test "returns not_found for unknown insight id", %{user_id: user_id} do
      assert {:error, :not_found} = Insights.acknowledge(user_id, Ecto.UUID.generate())
      assert {:error, :not_found} = Insights.dismiss(user_id, Ecto.UUID.generate())

      assert {:error, :not_found} =
               Insights.snooze(user_id, Ecto.UUID.generate(), DateTime.utc_now())
    end
  end
end
