defmodule Maraithon.Runtime.NudgeSweepTest do
  # async: false — NudgeSweep runs the injected llm_complete inside a bounded
  # Task (a separate process), which needs the shared-mode DB sandbox.
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Repo
  alias Maraithon.Runtime.NudgeSweep
  alias Maraithon.Runtime.RecurringJobs
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.Todos

  setup do
    user_id = "nudge-sweep-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "nudge cadence and work are owned by the durable recurring and fair model lanes" do
    original = Application.get_env(:maraithon, :start_background_workers, true)
    Application.put_env(:maraithon, :start_background_workers, true)

    try do
      {:ok, {_flags, children}} = Maraithon.Runtime.Supervisor.init(:ok)
      ids = Enum.map(children, &child_id/1)

      assert Maraithon.Runtime.ModelBackgroundJobRunner in ids
      refute NudgeSweep in ids
    after
      Application.put_env(:maraithon, :start_background_workers, original)
    end

    spec = Enum.find(RecurringJobs.specs(), &(&1.name == "nudge_sweep"))
    assert {:interval, interval_ms} = spec.schedule
    assert interval_ms > 0
  end

  defp child_id(module) when is_atom(module), do: module
  defp child_id({module, _opts}), do: module
  defp child_id(%{id: id}), do: id

  test "a past next_nudge_at produces exactly one nudge candidate; a rerun does not duplicate it",
       %{user_id: user_id} do
    todo = owed_to_me_todo(user_id, "pricing-doc", next_nudge_at: hours_ago(2))

    llm_complete = fn prompt ->
      assert prompt =~ "follow_up_due"
      assert prompt =~ "Waiting on Elena"
      # Timestamps shown to the model are local-time-labeled, never bare UTC.
      assert prompt =~ "local (UTC"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decisions" => [
               %{
                 "todo_id" => todo.id,
                 "surface" => true,
                 "title" => "Nudge Elena about the pricing doc",
                 "body" =>
                   "You've been waiting on Elena since the 1st — want me to send a nudge?",
                 "urgency" => 0.7,
                 "why_now" => "The scheduled follow-up moment arrived and no reply is recorded.",
                 "draft_text" =>
                   "Hi Elena — checking in on the pricing doc when you get a chance."
               }
             ]
           })
       }}
    end

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: llm_complete)
    assert summary.proposed == 1
    assert summary.checked == 1
    assert summary.errors == 0

    assert [candidate] = candidates_for(user_id)
    assert candidate.source == "nudge"
    assert candidate.source_id == todo.id
    assert candidate.dedupe_key == "nudge:#{todo.id}:nudge_due:0"
    assert candidate.title == "Nudge Elena about the pricing doc"
    assert candidate.structured_data["todo_ids"] == [todo.id]
    assert candidate.structured_data["message_class"] == "todo_digest"
    assert candidate.structured_data["nudge_reason"] == "follow_up_due"

    # Overlapping/retried tick: same due todo re-selected, live dedupe wins.
    rerun = NudgeSweep.run_once(user_ids: [user_id], llm_complete: llm_complete)
    assert rerun.errors == 0
    assert [rerun_candidate] = candidates_for(user_id)
    assert rerun_candidate.id == candidate.id

    # The surfaced follow-up refreshed the todo's generic draft so the card
    # can offer Send, not just Draft — NudgeSweep never sends anything itself.
    refreshed = Todos.get_for_user(user_id, todo.id)
    assert refreshed.action_draft["text"] =~ "checking in on the pricing doc"
    assert refreshed.action_draft["source"] == "nudge_sweep"
    # And it never records a nudge as sent (that is the user's Send confirm).
    assert refreshed.nudge_count == 0
    assert refreshed.last_nudged_at == nil
  end

  test "a held follow_up_due item gets its cadence re-armed instead of a candidate",
       %{user_id: user_id} do
    todo = owed_to_me_todo(user_id, "intro-favor", next_nudge_at: hours_ago(1))
    next_check = DateTime.utc_now() |> DateTime.add(3 * 86_400, :second)

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decisions" => [
               %{
                 "todo_id" => todo.id,
                 "surface" => false,
                 "next_nudge_at" => DateTime.to_iso8601(next_check)
               }
             ]
           })
       }}
    end

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: llm_complete)
    assert summary.proposed == 0
    assert summary.cadence_updates == 1
    assert candidates_for(user_id) == []

    reloaded = Todos.get_for_user(user_id, todo.id)
    assert reloaded.next_nudge_at == DateTime.truncate(next_check, :second)
  end

  test "degraded mode without SPEC 05: a plain hold leaves the cadence untouched and the item stays selectable",
       %{user_id: user_id} do
    cadence = hours_ago(1)
    todo = owed_to_me_todo(user_id, "quiet-hold", next_nudge_at: cadence)

    hold_everything = fn _prompt -> {:ok, %{content: Jason.encode!(%{"decisions" => []})}} end

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: hold_everything)
    assert summary.proposed == 0
    assert summary.held == 1
    assert summary.errors == 0
    assert candidates_for(user_id) == []

    # No "acknowledged_only" outcome was ever produced, so nothing cleared
    # the cadence (clear_nudge_cadence has no caller) and the next tick
    # re-selects the same due todo — no crash, no silent partial state.
    reloaded = Todos.get_for_user(user_id, todo.id)
    assert DateTime.compare(reloaded.next_nudge_at, DateTime.truncate(cadence, :second)) == :eq

    second = NudgeSweep.run_once(user_ids: [user_id], llm_complete: hold_everything)
    assert second.checked == 1
  end

  test "the nudge cap turns the Nth follow-up into a one-time keep-chasing decision",
       %{user_id: user_id} do
    todo = owed_to_me_todo(user_id, "capped", next_nudge_at: hours_ago(3))

    for _send <- 1..4 do
      {:ok, _todo} =
        Todos.record_nudge_sent(user_id, todo.id,
          channel: "gmail_send",
          next_nudge_at: hours_ago(3)
        )
    end

    llm_complete = fn prompt ->
      assert prompt =~ "follow_up_limit_reached"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decisions" => [
               %{
                 "todo_id" => todo.id,
                 "surface" => true,
                 "title" => "No reply after 4 nudges — keep chasing, snooze, or drop it?",
                 "body" => "Four nudges went out with no reply. Decide whether to keep chasing.",
                 "urgency" => 0.6
               }
             ]
           })
       }}
    end

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: llm_complete)
    assert summary.proposed == 1

    assert [candidate] = candidates_for(user_id)
    assert candidate.dedupe_key == "nudge:#{todo.id}:nudge_limit:4"
  end

  test "overdue and snooze-expiry fire with date-bucketed dedupe keys; closed todos are never resurrected",
       %{user_id: user_id} do
    now = DateTime.utc_now()

    {:ok, [overdue]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "title" => "File the quarterly report",
          "summary" => "The quarterly report deadline has passed.",
          "next_action" => "File the report today.",
          "dedupe_key" => "nudge-sweep-overdue",
          "due_at" => DateTime.add(now, -3600, :second)
        }
      ])

    {:ok, [snoozed]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "title" => "Revisit the vendor quote",
          "summary" => "You snoozed the vendor quote until this morning.",
          "next_action" => "Reopen the quote and decide.",
          "dedupe_key" => "nudge-sweep-snoozed",
          "status" => "snoozed",
          "snoozed_until" => DateTime.add(now, -1800, :second)
        }
      ])

    # Closed in the interim (simulates a completion sweep racing the tick):
    # the status re-check at enqueue time must drop it, even if the model
    # said surface.
    {:ok, [closed]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "title" => "Pay the invoice",
          "summary" => "The invoice is overdue.",
          "next_action" => "Pay it.",
          "dedupe_key" => "nudge-sweep-closed",
          "due_at" => DateTime.add(now, -3600, :second)
        }
      ])

    llm_complete = fn prompt ->
      assert prompt =~ "overdue"
      assert prompt =~ "snooze_expired"

      decisions =
        [overdue, snoozed, closed]
        |> Enum.map(fn todo ->
          %{
            "todo_id" => todo.id,
            "surface" => true,
            "title" => todo.title,
            "body" => "Due now: #{todo.title}",
            "urgency" => 0.7
          }
        end)

      # Close the racing todo only after selection already saw it as open.
      {:ok, _closed} = Todos.mark_done(user_id, closed.id, note: "Handled elsewhere.")

      {:ok, %{content: Jason.encode!(%{"decisions" => decisions})}}
    end

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: llm_complete)
    assert summary.proposed == 2

    candidates = candidates_for(user_id)
    dedupe_keys = candidates |> Enum.map(& &1.dedupe_key) |> Enum.sort()
    local_day = Date.to_iso8601(DateTime.to_date(now))

    assert dedupe_keys ==
             Enum.sort([
               "nudge:#{overdue.id}:overdue:#{local_day}",
               "nudge:#{snoozed.id}:snooze_expiry:#{local_day}"
             ])

    refute Enum.any?(candidates, fn candidate -> candidate.source_id == closed.id end)
  end

  test "due todos waiting on the same counterparty bundle into one candidate", %{user_id: user_id} do
    first = owed_to_me_todo(user_id, "bundle-a", next_nudge_at: hours_ago(2), label: "Elena Ruiz")

    second =
      owed_to_me_todo(user_id, "bundle-b", next_nudge_at: hours_ago(4), label: "elena ruiz")

    llm_complete = fn _prompt ->
      decisions =
        Enum.map([first, second], fn todo ->
          %{
            "todo_id" => todo.id,
            "surface" => true,
            "title" => "Nudge Elena",
            "body" => "Elena owes you an update.",
            "urgency" => 0.6
          }
        end)

      {:ok, %{content: Jason.encode!(%{"decisions" => decisions})}}
    end

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: llm_complete)
    assert summary.proposed == 1

    assert [candidate] = candidates_for(user_id)

    assert Enum.sort(candidate.structured_data["todo_ids"]) == Enum.sort([first.id, second.id])
    assert candidate.body =~ "Also due with the same person"
  end

  test "an LLM failure for one user is contained and reported, never raised", %{user_id: user_id} do
    _todo = owed_to_me_todo(user_id, "llm-down", next_nudge_at: hours_ago(1))

    failing = fn _prompt -> {:error, {:llm_busy, 5_000}} end

    assert {:error, {:llm_busy, 5_000}} = NudgeSweep.run_for_user(user_id, llm_complete: failing)

    summary = NudgeSweep.run_once(user_ids: [user_id], llm_complete: failing)
    assert summary.errors == 1
    assert summary.proposed == 0
    assert candidates_for(user_id) == []
  end

  test "a transient decision failure retries before any nudge state is applied", %{
    user_id: user_id
  } do
    todo = owed_to_me_todo(user_id, "llm-transient", next_nudge_at: hours_ago(1))

    state =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:error, {:provider_error, :redacted}},
             {:ok,
              %{
                content:
                  Jason.encode!(%{
                    "decisions" => [
                      %{
                        "todo_id" => todo.id,
                        "surface" => true,
                        "title" => "Follow up now",
                        "body" => "The scheduled follow-up is due.",
                        "urgency" => 0.6
                      }
                    ]
                  })
              }}
           ]
         end}
      )

    complete = fn _prompt ->
      Agent.get_and_update(state, fn [response | rest] -> {response, rest} end)
    end

    assert %{errors: 0, proposed: 1} =
             NudgeSweep.run_once(user_ids: [user_id], llm_complete: complete)

    assert Agent.get(state, & &1) == []
    assert [candidate] = candidates_for(user_id)
    assert candidate.source_id == todo.id

    refreshed = Todos.get_for_user(user_id, todo.id)
    assert refreshed.nudge_count == 0
    assert refreshed.last_nudged_at == nil
  end

  test "the default decision request budgets enough output for a full tenant page" do
    assert %{"max_tokens" => 4_096} = NudgeSweep.decision_request_params("bounded prompt")

    assert %{"max_tokens" => 4_096} =
             NudgeSweep.decision_request_params("bounded prompt", max_tokens: 32_000)
  end

  test "provider-controlled LLM failures collapse to a closed class", %{user_id: user_id} do
    _todo = owed_to_me_todo(user_id, "llm-unsafe-detail", next_nudge_at: hours_ago(1))
    failing = fn _prompt -> {:error, "provider supplied arbitrary detail"} end

    assert {:error, :llm_call_failed} =
             NudgeSweep.run_for_user(user_id, llm_complete: failing)
  end

  test "run_once selects due users itself when none are supplied", %{user_id: user_id} do
    todo = owed_to_me_todo(user_id, "auto-select", next_nudge_at: hours_ago(1))

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decisions" => [
               %{
                 "todo_id" => todo.id,
                 "surface" => true,
                 "title" => "Nudge Elena",
                 "body" => "Elena owes you an update.",
                 "urgency" => 0.6
               }
             ]
           })
       }}
    end

    summary = NudgeSweep.run_once(llm_complete: llm_complete)
    assert summary.users >= 1
    assert Enum.any?(candidates_for(user_id), &(&1.source_id == todo.id))
  end

  defp owed_to_me_todo(user_id, key, opts) do
    label = Keyword.get(opts, :label, "Elena")

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "title" => "Waiting on Elena for the pricing doc",
          "summary" => "Elena owes you the pricing doc for the renewal.",
          "next_action" => "Nudge Elena if she stays quiet.",
          "dedupe_key" => "nudge-sweep-#{key}",
          "direction" => "owed_to_me",
          "counterparty_label" => label,
          "next_nudge_at" => Keyword.fetch!(opts, :next_nudge_at)
        }
      ])

    todo
  end

  defp hours_ago(hours) do
    DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
  end

  defp candidates_for(user_id) do
    Repo.all(from(c in ProactiveCandidate, where: c.user_id == ^user_id))
  end
end
