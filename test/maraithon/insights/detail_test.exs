defmodule Maraithon.Insights.DetailTest do
  use ExUnit.Case, async: true

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Detail
  alias Maraithon.Insights.Insight

  test "prefers metadata.detail and redacts delivery destinations" do
    now = ~U[2026-03-12 14:00:00Z]

    insight =
      build_insight(%{
        metadata: %{
          "detail" => %{
            "promise_text" => "Send the revised pricing doc to Sarah by Friday.",
            "requested_by" => "Sarah Chen",
            "open_loop_reason" => "No sent artifact confirms delivery.",
            "checked_evidence" => [
              %{
                "kind" => "source_evidence",
                "label" => "Promise stated in email thread",
                "detail" => "Send the revised pricing doc by Friday.",
                "source_ref" => "gmail:thread:abc123",
                "occurred_at" => DateTime.to_iso8601(now)
              }
            ],
            "evaluated_at" => DateTime.to_iso8601(now)
          },
          "record" => %{"status" => "unresolved"}
        }
      })

    delivery = %Delivery{
      channel: "telegram",
      destination: "123456789",
      status: "sent",
      sent_at: now,
      error_message: "send failed for 123456789 and sarah@example.com"
    }

    detail = Detail.build(insight, [delivery])

    assert detail.promise_text == %{
             text: "Send the revised pricing doc to Sarah by Friday.",
             origin: :stored
           }

    assert detail.requested_by == %{text: "Sarah Chen", origin: :stored}
    assert detail.open_loop_reason.origin == :stored
    assert detail.open_loop_reason.text == "No sent artifact confirms delivery."
    assert hd(detail.evidence_checked).label == "Promise stated in email thread"
    assert hd(detail.delivery_evidence).destination_label == "Telegram linked chat"
    assert hd(detail.delivery_evidence).error_message =~ "[redacted]"
    assert detail.data_gaps == []
  end

  test "falls back to record metadata and derives the open loop reason" do
    now = ~U[2026-03-12 09:30:00Z]
    due_at = ~U[2026-03-13 17:00:00Z]

    insight =
      build_insight(%{
        source_id: "msg-42",
        source_occurred_at: now,
        due_at: due_at,
        metadata: %{
          "missing_followthrough_evidence" => true,
          "record" => %{
            "commitment" => "Send the revised pricing doc to Sarah",
            "person" => "Sarah",
            "status" => "unresolved",
            "source" => "gmail:thread:thread-42",
            "deadline" => DateTime.to_iso8601(due_at),
            "evidence" => ["No follow-up reply or attachment was found."],
            "next_action" => "Send the promised follow-through now."
          }
        }
      })

    detail = Detail.build(insight, [])

    assert detail.promise_text == %{
             text: "Send the revised pricing doc to Sarah",
             origin: :stored
           }

    assert detail.requested_by == %{text: "Sarah", origin: :stored}
    assert Enum.any?(detail.evidence_checked, &(&1.kind == :deadline))
    assert detail.open_loop_reason.origin == :derived
    assert detail.open_loop_reason.text =~ "unresolved"
    assert "No delivery attempts recorded." in detail.data_gaps
  end

  test "reports explicit data gaps for sparse insights" do
    insight =
      build_insight(%{
        title: "Reply owed: Board deck",
        summary: "You still owe an update.",
        recommended_action: "Reply now with the promised update.",
        metadata: %{}
      })

    detail = Detail.build(insight, [])

    assert detail.promise_text == %{text: "Reply owed: Board deck", origin: :reconstructed}
    assert detail.requested_by == nil
    assert detail.open_loop_reason.origin == :derived
    assert "Requester not captured for this insight." in detail.data_gaps
    assert "No persisted evidence bullets were captured for this insight." in detail.data_gaps
    assert "No delivery attempts recorded." in detail.data_gaps
  end

  defp build_insight(attrs) do
    struct(Insight, Map.merge(default_insight_attrs(), attrs))
  end

  defp default_insight_attrs do
    %{
      id: Ecto.UUID.generate(),
      user_id: "detail-user@example.com",
      agent_id: Ecto.UUID.generate(),
      source: "gmail",
      category: "commitment_unresolved",
      title: "Follow up on pricing doc",
      summary: "The pricing doc still appears open.",
      recommended_action: "Send the pricing doc now.",
      priority: 90,
      confidence: 0.83,
      status: "new",
      metadata: %{}
    }
  end
end
