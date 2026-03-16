defmodule Maraithon.PreferenceMemoryTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Insights.Insight
  alias Maraithon.PreferenceMemory

  setup do
    user_id = "preference-memory@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{"timezone_offset_hours" => -5}
      })

    %{user_id: user_id}
  end

  test "stores explicit preference rules and renders a summary", %{user_id: user_id} do
    llm_complete = fn _prompt ->
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
               "topics" => ["receipts", "invoices", "payment_confirmations"],
               "require_human_ask_to_override" => true
             }
           }
         ]
       })}
    end

    assert {:ok, %{reply: reply, learned: [rule]}} =
             PreferenceMemory.apply_explicit_instruction(
               user_id,
               "ignore receipts",
               llm_complete: llm_complete
             )

    assert reply =~ "receipt-style noise"
    assert rule["id"] == "ignore_receipts"
    assert [%{"id" => "ignore_receipts"}] = PreferenceMemory.active_rules(user_id)
    assert PreferenceMemory.render_summary(user_id) =~ "`ignore_receipts`"
  end

  test "stores sales outreach content filters as durable preference rules", %{user_id: user_id} do
    llm_complete = fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "reply" => "Understood. I'll ignore sales outreach unless you've engaged first.",
         "rules" => [
           %{
             "id" => "ignore_sales_outreach_unless_engaged",
             "kind" => "content_filter",
             "label" => "Ignore sales outreach unless engaged",
             "instruction" =>
               "Suppress unsolicited sales outreach unless I already engaged or explicitly asked for the information.",
             "applies_to" => ["gmail", "telegram"],
             "confidence" => 0.96,
             "filters" => %{
               "topics" => ["sales_outreach", "cold_outreach"],
               "require_human_ask_to_override" => true
             }
           }
         ]
       })}
    end

    assert {:ok, %{reply: reply, learned: [rule]}} =
             PreferenceMemory.apply_explicit_instruction(
               user_id,
               "ignore sales outreach unless I've engaged",
               llm_complete: llm_complete
             )

    assert reply =~ "ignore sales outreach"
    assert rule["kind"] == "content_filter"
    assert rule["filters"]["topics"] == ["sales_outreach", "cold_outreach"]
  end

  test "falls back to dynamic watch-style urgency rules for arbitrary topics", %{
    user_id: user_id
  } do
    invalid_llm = fn _prompt -> {:ok, "not-json"} end

    assert {:ok, %{learned: [rule]}} =
             PreferenceMemory.apply_explicit_instruction(
               user_id,
               "board game meetup notifications should appear as FYI",
               llm_complete: invalid_llm
             )

    assert rule["id"] == "watch_board_game_meetup"
    assert rule["kind"] == "urgency_boost"
    assert rule["filters"]["topics"] == ["board_game_meetup"]
    assert rule["filters"]["delivery_mode"] == "important_fyi"
    assert rule["filters"]["ackable"] == true
    assert "board game meetup" in rule["filters"]["keywords"]
  end

  test "quiet hours suppress internal telegram interruptions but allow external ones", %{
    user_id: user_id
  } do
    llm_complete = fn _prompt ->
      {:ok,
       Jason.encode!(%{
         "reply" => "After hours, I'll only interrupt for external loops.",
         "rules" => [
           %{
             "id" => "after_hours_external_only",
             "kind" => "quiet_hours",
             "label" => "After-hours Telegram only for external loops",
             "instruction" =>
               "After 8pm local time, suppress Telegram interruptions unless the counterparty is external.",
             "applies_to" => ["telegram"],
             "confidence" => 0.94,
             "filters" => %{
               "start_hour_local" => 20,
               "end_hour_local" => 8,
               "allow_if_external" => true
             }
           }
         ]
       })}
    end

    assert {:ok, _result} =
             PreferenceMemory.apply_explicit_instruction(
               user_id,
               "don't interrupt after 8pm unless external",
               llm_complete: llm_complete
             )

    quiet_time = DateTime.from_naive!(~N[2026-03-12 02:30:00], "Etc/UTC")

    internal_insight = %Insight{
      user_id: user_id,
      source: "gmail",
      category: "reply_urgent",
      title: "Internal billing thread",
      summary: "An internal receipt thread.",
      recommended_action: "Ignore it.",
      metadata: %{
        "account" => "kent@runner.now",
        "from" => "ops@runner.now",
        "to" => "kent@runner.now"
      }
    }

    external_insight = %Insight{
      user_id: user_id,
      source: "gmail",
      category: "reply_urgent",
      title: "Investor follow-up",
      summary: "External follow-up still open.",
      recommended_action: "Reply now.",
      metadata: %{
        "account" => "kent@runner.now",
        "from" => "partner@sequoiacap.com",
        "to" => "kent@runner.now"
      }
    }

    refute PreferenceMemory.allow_telegram_interrupt?(user_id, internal_insight, quiet_time)
    assert PreferenceMemory.allow_telegram_interrupt?(user_id, external_insight, quiet_time)
  end

  test "conflicting inferred rules require confirmation when a stronger explicit rule exists", %{
    user_id: user_id
  } do
    {:ok, [_saved]} =
      PreferenceMemory.save_interpreted_rules(
        user_id,
        [
          %{
            "id" => "ignore_receipts_strict",
            "kind" => "content_filter",
            "label" => "Ignore routine receipts",
            "instruction" => "Ignore routine receipts unless they imply real follow-up work.",
            "applies_to" => ["gmail", "telegram"],
            "confidence" => 0.98,
            "filters" => %{"topics" => ["receipts"]}
          }
        ],
        "explicit_telegram",
        explicit?: true
      )

    {:ok, [pending]} =
      PreferenceMemory.save_interpreted_rules(
        user_id,
        [
          %{
            "id" => "ignore_receipts_broader",
            "kind" => "content_filter",
            "label" => "Downrank receipt-style emails",
            "instruction" => "Downrank receipt-like emails more broadly.",
            "applies_to" => ["gmail", "telegram"],
            "confidence" => 0.97,
            "filters" => %{"topics" => ["receipts", "transactional_receipts"]}
          }
        ],
        "telegram_inferred"
      )

    assert pending["status"] == "pending_confirmation"
    assert [%{"id" => "ignore_receipts_strict"}] = PreferenceMemory.active_rules(user_id)
  end
end
