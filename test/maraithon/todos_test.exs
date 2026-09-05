defmodule Maraithon.TodosTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Memory
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.{OutcomeLearner, Todo, TodoLearningEvent}

  test "fallback todo copy gives a direct saved-work decision frame" do
    user_id = unique_user_email("todos-fallback-copy")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "kind" => "general",
          "title" => "",
          "summary" => "",
          "next_action" => "",
          "dedupe_key" => "todos-fallback-copy"
        }
      ])

    assert todo.title == "Review open work"
    assert todo.summary == "This saved open work needs a keep, delegate, or dismiss decision."

    assert todo.next_action ==
             "Open the source context, confirm the request, then keep, delegate, or dismiss it."

    rendered = inspect(todo)
    refute rendered =~ "surfaced"
    refute rendered =~ "real ask"
    refute rendered =~ "Review this item"
  end

  test "done todos stay closed when the same work is upserted again" do
    user_id = unique_user_email("todos-closed")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-billing", "Billing account past due", %{
          "summary" => "The billing account is overdue and needs a user decision."
        })
      ])

    assert {:ok, done_todo} = Todos.mark_done(user_id, todo.id, note: "Handled in console.")
    assert done_todo.status == "done"
    assert done_todo.summary == "The billing account is overdue and needs your decision."
    refute done_todo.summary =~ "user decision"

    {:ok, [reupserted]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-billing", "Billing account past due",
          summary: "A refreshed Gmail scan still sees the billing thread."
        )
      ])

    assert reupserted.id == todo.id
    assert reupserted.status == "done"
    assert Todos.list_open_for_user(user_id, kind: "gmail_triage") == []
  end

  test "upsert_many reuses a source item when the model emits a fresh dedupe key" do
    user_id = unique_user_email("todos-source-item-dedupe")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "imessage",
          "kind" => "general",
          "title" => "Confirm Emma pickup and painting with Christina",
          "summary" => "Christina asked if you can get Emma and reminded you about the painting.",
          "next_action" => "Reply to Christina confirming you will pick up Emma.",
          "priority" => 80,
          "source_item_id" => "imessage-source-1",
          "dedupe_key" => "commitment:imessage:imessage-source-1:original"
        }
      ])

    assert {:ok, dismissed} = Todos.dismiss(user_id, todo.id, note: "Not needed anymore.")
    assert dismissed.status == "dismissed"

    {:ok, [reupserted]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "imessage",
          "kind" => "general",
          "title" => "Confirm you have the painting for Emma's pickup",
          "summary" => "The same iMessage source still needs painting confirmation.",
          "next_action" => "Reply to Christina confirming you have the painting.",
          "priority" => 82,
          "source_item_id" => "imessage-source-1",
          "dedupe_key" => "commitment:imessage:imessage-source-1:model-fresh-key"
        }
      ])

    assert reupserted.id == todo.id
    assert reupserted.dedupe_key == todo.dedupe_key
    assert reupserted.status == "dismissed"

    assert [persisted] = Todos.list_recent_for_user(user_id, limit: 10)
    assert persisted.id == todo.id
    assert persisted.title == "Confirm you have the painting for Emma's pickup"
    assert persisted.dedupe_key == todo.dedupe_key
  end

  test "upserting an update without a direction preserves the existing owed_to_me direction" do
    user_id = unique_user_email("todos-direction-preserve")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-direction", "Waiting on vendor reply",
          direction: "owed_to_me",
          counterparty_label: "Acme Vendor"
        )
      ])

    assert todo.direction == "owed_to_me"
    assert todo.counterparty_label == "Acme Vendor"

    {:ok, [reupserted]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-direction", "Waiting on vendor reply",
          summary: "Still waiting on the vendor to reply."
        )
      ])

    assert reupserted.id == todo.id
    assert reupserted.direction == "owed_to_me"
    assert reupserted.counterparty_label == "Acme Vendor"
  end

  test "upserting an update with an explicit direction still overrides it" do
    user_id = unique_user_email("todos-direction-override")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-direction-override", "Waiting on vendor reply",
          direction: "owed_to_me"
        )
      ])

    assert todo.direction == "owed_to_me"

    {:ok, [reupserted]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-direction-override", "Waiting on vendor reply",
          summary: "You now owe the vendor a reply.",
          direction: "owed_by_me"
        )
      ])

    assert reupserted.id == todo.id
    assert reupserted.direction == "owed_by_me"
  end

  test "record_nudge_sent atomically increments nudge_count and stamps nudge state" do
    user_id = unique_user_email("todos-nudge")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-nudge", "Follow up with vendor", direction: "owed_to_me")
      ])

    assert todo.nudge_count == 0

    assert {:ok, nudged_once} =
             Todos.record_nudge_sent(user_id, todo.id, channel: "gmail")

    assert nudged_once.nudge_count == 1
    assert nudged_once.follow_up_channel == "gmail"
    assert %DateTime{} = nudged_once.last_nudged_at

    assert {:ok, nudged_twice} = Todos.record_nudge_sent(user_id, todo.id, channel: "slack")
    assert nudged_twice.nudge_count == 2
    assert nudged_twice.follow_up_channel == "slack"

    assert {:error, :not_found} =
             Todos.record_nudge_sent(user_id, Ecto.UUID.generate(), channel: "gmail")
  end

  test "dismissing a todo records a low-signal not-important learning marker" do
    user_id = unique_user_email("todos-dismiss-signal")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-newsletter", "Skim vendor newsletter")
      ])

    assert {:ok, dismissed} =
             Todos.dismiss(user_id, todo.id, note: "Not worth my time.", source: "mobile")

    assert dismissed.status == "dismissed"
    assert get_in(dismissed.metadata, ["assistant_feedback", "value"]) == "not_important"
    assert get_in(dismissed.metadata, ["assistant_feedback", "signal_strength"]) == "low"
    assert get_in(dismissed.metadata, ["assistant_feedback", "source"]) == "mobile"
    assert get_in(dismissed.metadata, ["resolution_note"]) == "Not worth my time."
  end

  test "todo activity records creates, completions, and deletes with actors" do
    user_id = unique_user_email("todos-activity")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    attrs = gmail_todo_attrs("thread-activity", "Reply to activity thread")

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [attrs],
        actor_type: "user",
        actor_id: user_id,
        actor_label: "User"
      )

    {:ok, [same_todo]} = Todos.upsert_many(user_id, [attrs])
    assert same_todo.id == todo.id

    {:ok, _done_todo} =
      Todos.mark_done(user_id, todo.id,
        actor_type: "agent",
        actor_id: "completion_sweep",
        actor_label: "Maraithon",
        note: "Detected completion from source."
      )

    {:ok, [delete_todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-delete-activity", "Dismiss stale activity thread")
      ])

    {:ok, _dismissed_todo} =
      Todos.dismiss(user_id, delete_todo.id,
        actor_type: "user",
        actor_id: user_id,
        actor_label: "User",
        note: "No longer needed."
      )

    events = Todos.list_activity_for_user(user_id, limit: 10)

    assert Enum.count(events, &(&1.event_type == "created")) == 2

    assert %{
             event_type: "created",
             actor_type: "user",
             actor_id: ^user_id,
             todo_id: created_todo_id
           } = Enum.find(events, &(&1.todo_id == todo.id and &1.event_type == "created"))

    assert created_todo_id == todo.id

    assert %{
             event_type: "marked_done",
             actor_type: "agent",
             actor_id: "completion_sweep",
             metadata: %{"note" => "Detected completion from source.", "todo_status" => "done"}
           } = Enum.find(events, &(&1.event_type == "marked_done"))

    assert %{
             event_type: "deleted",
             actor_type: "user",
             actor_id: ^user_id,
             metadata: %{"note" => "No longer needed.", "todo_status" => "dismissed"}
           } = Enum.find(events, &(&1.event_type == "deleted"))
  end

  test "todos can be searched by query and filtered by status" do
    user_id = unique_user_email("todos-search")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [billing, oauth]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-billing", "Billing account past due"),
        gmail_todo_attrs("thread-oauth", "OAuth verification reply owed",
          summary: "Google needs acknowledgement and an ETA."
        )
      ])

    assert {:ok, _done_todo} = Todos.mark_done(user_id, billing.id, note: "Paid and confirmed.")

    [open_todo] = Todos.list_open_for_user(user_id, kind: "gmail_triage")
    assert open_todo.id == oauth.id

    [done_todo] =
      Todos.list_for_user(user_id,
        statuses: ["done"],
        query: "billing",
        kind: "gmail_triage"
      )

    assert done_todo.id == billing.id
    assert done_todo.status == "done"
  end

  test "open lists exclude todos explicitly scored not surfaceable" do
    user_id = unique_user_email("todos-surface-quality")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    metadata = %{
      "surface_quality" => %{
        "surfaceable" => false,
        "missing" => ["human_context", "specific_context"]
      }
    }

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-unsurfaceable", "Approve vague invoice reminder",
          metadata: metadata
        )
      ])

    assert Todos.list_open_for_user(user_id) == []
    assert [unfiltered] = Todos.list_open_for_user(user_id, exclude_unsurfaceable?: false)
    assert unfiltered.id == todo.id
  end

  test "source filters distinguish local Calendar from Google Calendar" do
    user_id = unique_user_email("todos-source")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [local_calendar, google_calendar]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "calendar",
          "kind" => "local_calendar",
          "title" => "Prepare for the local calendar review",
          "summary" => "A local Calendar.app event needs prep.",
          "next_action" => "Review the local calendar event.",
          "priority" => 80,
          "dedupe_key" => "todos-source-filter:local-calendar"
        },
        %{
          "source" => "google_calendar",
          "kind" => "google_calendar",
          "title" => "Prepare for the Google calendar review",
          "summary" => "A Google Calendar event needs prep.",
          "next_action" => "Review the Google Calendar event.",
          "priority" => 79,
          "dedupe_key" => "todos-source-filter:google-calendar"
        }
      ])

    assert [local_calendar.id] ==
             user_id
             |> Todos.list_for_user(source: "calendar", limit: 10)
             |> Enum.map(& &1.id)

    assert [google_calendar.id] ==
             user_id
             |> Todos.list_for_user(source: "google_calendar", limit: 10)
             |> Enum.map(& &1.id)
  end

  test "decision-only filter returns calls waiting on the operator" do
    user_id = unique_user_email("todos-decisions")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [decision, _reference]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Approve investor reply",
          "summary" => "The investor asked whether the revised terms are approved.",
          "next_action" => "Send the revised terms and confirm the review window.",
          "priority" => 88,
          "dedupe_key" => "todos-decisions:investor",
          "metadata" => %{
            "person" => "Jordan Lee",
            "why_now" => "Jordan is waiting on your decision.",
            "source_quote" => "Can you approve the revised terms?"
          }
        },
        %{
          "source" => "manual",
          "kind" => "general",
          "title" => "Read strategy note",
          "summary" => "Background context for planning.",
          "next_action" => "Review when planning next week.",
          "priority" => 50,
          "dedupe_key" => "todos-decisions:reference"
        }
      ])

    assert [decision.id] ==
             user_id
             |> Todos.list_for_user(decision_only?: true, limit: 10)
             |> Enum.map(& &1.id)

    assert Todos.count_for_user(user_id, decision_only?: true) == 1
  end

  test "decision-only pagination slices after exact decision filtering" do
    user_id = unique_user_email("todos-decision-pagination")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    attrs = [
      decision_pagination_attrs("alpha", "Alpha background note", "owed_by_me"),
      decision_pagination_attrs("bravo", "Bravo follow-up", "owed_to_me"),
      decision_pagination_attrs("charlie", "Charlie background note", "owed_by_me"),
      decision_pagination_attrs("delta", "Delta follow-up", "owed_to_me")
    ]

    assert {:ok, [_alpha, first_decision, _charlie, second_decision]} =
             Todos.upsert_many(user_id, attrs)

    opts = [decision_only?: true, sort_by: "title", sort_dir: "asc", limit: 1]

    assert [first_decision.id] ==
             user_id |> Todos.list_for_user(Keyword.put(opts, :offset, 0)) |> Enum.map(& &1.id)

    assert [second_decision.id] ==
             user_id |> Todos.list_for_user(Keyword.put(opts, :offset, 1)) |> Enum.map(& &1.id)

    assert Todos.list_for_user(user_id, Keyword.put(opts, :offset, 2)) == []
    assert Todos.count_for_user(user_id, decision_only?: true) == 2

    assert Todos.list_ids_for_user(user_id,
             decision_only?: true,
             sort_by: "title",
             sort_dir: "asc"
           ) == [first_decision.id, second_decision.id]
  end

  test "todo sorts use ids as deterministic final tie-breakers" do
    user_id = unique_user_email("todos-sort-tie-breaker")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    [low_id, high_id] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()])
    tied_at = ~U[2026-09-04 12:00:00.000000Z]

    for {id, suffix} <- [{high_id, "high"}, {low_id, "low"}] do
      Repo.insert!(%Todo{
        id: id,
        user_id: user_id,
        owner_user_id: user_id,
        source: "manual",
        kind: "general",
        attention_mode: "act_now",
        direction: "owed_by_me",
        title: "Shared sort values",
        summary: "Background material for quarterly planning.",
        next_action: "Read the material next week.",
        priority: 50,
        status: "open",
        dedupe_key: "todos-sort-tie-breaker:#{suffix}",
        inserted_at: tied_at,
        updated_at: tied_at
      })
    end

    for sort_by <- ~w(rank title source status attention priority due updated),
        sort_dir <- ~w(asc desc) do
      actual_ids =
        user_id
        |> Todos.list_for_user(sort_by: sort_by, sort_dir: sort_dir, limit: 10)
        |> Enum.map(& &1.id)

      assert actual_ids == [low_id, high_id],
             "expected #{sort_by} #{sort_dir} ties to be ordered by todo id"
    end
  end

  test "todos persist durable source, owner, due date, notes, and action draft details" do
    user_id = unique_user_email("todos-detail")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:todos@example.com", %{
        metadata: %{"account_email" => "todos@example.com"}
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to renewal thread",
          "todo" => "A renewal thread needs a committed owner and ETA.",
          "next_action" => "Reply in-thread with the owner and timing.",
          "due_date" => "2026-05-14",
          "notes" => "Customer is waiting on procurement details.",
          "action_plan" => "Draft in your voice, then confirm the exact ETA before sending.",
          "action_draft" => %{kind: "gmail_reply", body: "I will confirm the ETA today."},
          "source_account_id" => account.id,
          "metadata" => %{"google_account_email" => "todos@example.com"},
          "dedupe_key" => "gmail:renewal-thread"
        }
      ])

    assert todo.owner_user_id == user_id
    assert todo.owner_label == nil
    assert todo.source_account_id == account.id
    assert todo.source_account_label == "todos@example.com"
    assert DateTime.to_date(todo.due_at) == ~D[2026-05-14]
    assert todo.summary == "A renewal thread needs a committed owner and ETA."
    assert todo.notes == "Customer is waiting on procurement details."
    assert todo.action_plan == "Draft in your voice, then confirm the exact ETA before sending."

    assert todo.action_draft == %{
             "kind" => "gmail_reply",
             "body" => "I will confirm the ETA today."
           }

    assert [todo.id] ==
             Todos.list_for_user(user_id,
               source_account_id: account.id,
               due_before: "2026-05-15",
               query: "procurement"
             )
             |> Enum.map(& &1.id)
  end

  test "see less queues durable outcome learning and dismisses immediately" do
    user_id = unique_user_email("todos-see-less")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(
        user_id,
        [
          gmail_todo_attrs("thread-newsletter", "Skim vendor newsletter",
            summary: "A broad vendor newsletter has no direct ask for Kent.",
            priority: 45
          )
        ],
        model_selected?: true
      )

    assert {:ok, %{todo: dismissed, memory: nil, training: %{"queued" => true}}} =
             Todos.see_less_like(user_id, todo.id,
               source: "test",
               actor_type: "user",
               actor_id: user_id
             )

    assert dismissed.status == "dismissed"
    assert get_in(dismissed.metadata, ["assistant_feedback", "value"]) == "see_less"
    assert get_in(dismissed.metadata, ["see_less_feedback", "learning"]) == "queued"
    assert Todos.list_open_for_user(user_id) == []

    event = Repo.get_by!(TodoLearningEvent, todo_id: todo.id)
    assert event.outcome == "bad"
    assert event.status == "pending"

    llm_complete = fn prompt ->
      assert prompt =~ OutcomeLearner.sentinel()
      assert prompt =~ "Skim vendor newsletter"
      assert prompt =~ "admission and ranking"

      {:ok,
       Jason.encode!(%{
         "action" => "upsert",
         "target_memory_id" => nil,
         "retire_memory_ids" => [],
         "pattern" => %{
           "title" => "See less: vendor newsletters",
           "summary" => "Vendor newsletters without a direct ask should not become todos.",
           "content" =>
             "Skip informational vendor newsletters without a direct ask, and rank exceptions with concrete deadlines or customer impact higher.",
           "pattern_key" => "vendor_newsletters_without_direct_ask",
           "categories" => ["vendor_newsletter", "no_direct_ask"],
           "positive_signals" => [],
           "negative_signals" => ["broadcast update", "no explicit ask"],
           "exceptions" => ["explicit deadline", "customer impact"],
           "polarity" => "negative",
           "confidence" => 0.91,
           "reasoning" => "The selected todo is informational rather than actionable."
         }
       })}
    end

    assert {:ok, %{memory_id: memory_id, operation: "created"}} =
             OutcomeLearner.learn(event, llm_complete: llm_complete)

    memory = Memory.get_item_for_user(user_id, memory_id)
    assert memory.kind == "relevance_feedback"
    assert memory.polarity == "negative"
    assert memory.source == "todo_outcome_learning"
    assert memory.source_ref_type == "todo_learning_event"
    assert memory.source_ref_id == event.id
    assert "todo_relevance" in memory.tags
    assert memory.metadata["trainer"] == OutcomeLearner.sentinel()

    assert Repo.get!(TodoLearningEvent, event.id).status == "processed"
  end

  describe "SPEC 06 bucket_for_brief direction option" do
    # One overdue owed_to_me, one due-today owed_by_me, one no-deadline fyi —
    # enough to see each direction scope a different subset.
    defp seed_directional_todos(user_id, now) do
      yesterday = now |> DateTime.add(-24 * 3600, :second) |> DateTime.to_iso8601()
      later_today = now |> DateTime.add(2 * 3600, :second) |> DateTime.to_iso8601()

      {:ok, todos} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "gmail",
            "title" => "Waiting on Elena for the pricing doc",
            "summary" => "Elena owes the pricing doc for the renewal.",
            "next_action" => "Nudge Elena if she stays quiet.",
            "dedupe_key" => "bucket-direction-owed-to-me",
            "direction" => "owed_to_me",
            "counterparty_label" => "Elena",
            "due_at" => yesterday
          },
          %{
            "source" => "gmail",
            "title" => "Send Alex the revised enterprise pricing",
            "summary" => "You owe Alex the revised pricing.",
            "next_action" => "Send the revised pricing today.",
            "dedupe_key" => "bucket-direction-owed-by-me",
            "direction" => "owed_by_me",
            "counterparty_label" => "Alex",
            "due_at" => later_today
          },
          %{
            "source" => "slack",
            "title" => "Team offsite notes shared",
            "summary" => "FYI notes from the offsite.",
            "next_action" => "Skim when convenient.",
            "dedupe_key" => "bucket-direction-fyi",
            "direction" => "fyi"
          }
        ])

      todos
    end

    test "default call is unchanged: owed_by_me scope and label" do
      user_id = unique_user_email("bucket-direction-default")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      now = ~U[2026-05-13 15:00:00Z]
      seed_directional_todos(user_id, now)

      bucket = Todos.bucket_for_brief(user_id, now: now, timezone_offset_hours: -5)

      assert bucket["source"] == "todos_owed_by_me"

      assert Map.keys(bucket) |> Enum.sort() ==
               ~w(active_count coming_up due_today no_deadline overdue source)

      assert bucket["active_count"] == 1
      assert [%{"title" => "Send Alex the revised enterprise pricing"}] = bucket["due_today"]
      assert bucket["overdue"] == []
    end

    test "direction: \"owed_to_me\" buckets what others owe the operator" do
      user_id = unique_user_email("bucket-direction-owed-to-me")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      now = ~U[2026-05-13 15:00:00Z]
      seed_directional_todos(user_id, now)

      bucket =
        Todos.bucket_for_brief(user_id,
          direction: "owed_to_me",
          now: now,
          timezone_offset_hours: -5
        )

      assert bucket["source"] == "todos_owed_to_me"
      assert bucket["active_count"] == 1
      assert [%{"title" => "Waiting on Elena for the pricing doc"}] = bucket["overdue"]
      assert bucket["due_today"] == []
    end

    test "direction: :all buckets every open todo with no direction filter" do
      user_id = unique_user_email("bucket-direction-all")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      now = ~U[2026-05-13 15:00:00Z]
      seed_directional_todos(user_id, now)

      bucket =
        Todos.bucket_for_brief(user_id, direction: :all, now: now, timezone_offset_hours: -5)

      assert bucket["source"] == "todos_open_all"
      assert bucket["active_count"] == 3
      assert [%{"title" => "Waiting on Elena for the pricing doc"}] = bucket["overdue"]
      assert [%{"title" => "Send Alex the revised enterprise pricing"}] = bucket["due_today"]
      assert [%{"title" => "Team offsite notes shared"}] = bucket["no_deadline"]
    end
  end

  describe "SPEC 01 follow-up engine write boundary" do
    test "owed_to_me todos persist next_nudge_at truncated to the second" do
      user_id = unique_user_email("todos-next-nudge")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "gmail",
            "title" => "Waiting on Elena for the pricing doc",
            "summary" => "Elena owes you the pricing doc for the renewal.",
            "next_action" => "Nudge Elena if she stays quiet.",
            "dedupe_key" => "todos-next-nudge-owed",
            "direction" => "owed_to_me",
            "counterparty_label" => "Elena",
            "next_nudge_at" => "2099-07-09T15:30:00.123456Z",
            "metadata" => %{"follow_up_reasoning" => "Customer-blocking ask, chase in 2 days."}
          }
        ])

      assert todo.direction == "owed_to_me"
      assert todo.next_nudge_at == ~U[2099-07-09 15:30:00Z]
      assert todo.metadata["follow_up_reasoning"] =~ "chase in 2 days"
    end

    test "any non-owed_to_me direction forces next_nudge_at to nil even when attrs carry one" do
      user_id = unique_user_email("todos-next-nudge-drop")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      for {direction, key} <- [{"owed_by_me", "a"}, {"fyi", "b"}] do
        {:ok, [todo]} =
          Todos.upsert_many(user_id, [
            %{
              "source" => "gmail",
              "title" => "Send the launch summary note",
              "summary" => "You owe the team the launch summary.",
              "next_action" => "Write and send the launch summary.",
              "dedupe_key" => "todos-next-nudge-drop-#{key}",
              "direction" => direction,
              "next_nudge_at" => "2099-07-09T15:30:00Z"
            }
          ])

        assert todo.direction == direction
        assert todo.next_nudge_at == nil
      end
    end

    test "re-upserting without next_nudge_at preserves an existing cadence" do
      user_id = unique_user_email("todos-next-nudge-preserve")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      base = %{
        "source" => "gmail",
        "title" => "Waiting on Elena for the pricing doc",
        "summary" => "Elena owes you the pricing doc for the renewal.",
        "next_action" => "Nudge Elena if she stays quiet.",
        "dedupe_key" => "todos-next-nudge-preserve",
        "direction" => "owed_to_me",
        "counterparty_label" => "Elena"
      }

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [Map.put(base, "next_nudge_at", "2099-07-09T15:30:00Z")])

      assert todo.next_nudge_at == ~U[2099-07-09 15:30:00Z]

      {:ok, [reupserted]} = Todos.upsert_many(user_id, [base])
      assert reupserted.id == todo.id
      assert reupserted.next_nudge_at == ~U[2099-07-09 15:30:00Z]
    end

    test "bare dates resolve to local end-of-day for a timezone-configured user, DST-correct per date" do
      user_id = unique_user_email("todos-local-due")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "ai_chief_of_staff",
          config: %{
            "name" => "Chief of Staff",
            "timezone" => "America/Toronto",
            "timezone_name" => "America/Toronto",
            "timezone_offset_hours" => -5
          }
        })

      # 2026-03-08 is the US DST-start Sunday: 20:00 local that evening is
      # already daylight time (-4), while the evening before is standard (-5).
      cases = [
        {"2026-03-08", ~U[2026-03-09 00:00:00Z]},
        {"2026-03-07", ~U[2026-03-08 01:00:00Z]},
        {"2026-07-10", ~U[2026-07-11 00:00:00Z]}
      ]

      for {{date, expected}, index} <- Enum.with_index(cases) do
        {:ok, [todo]} =
          Todos.upsert_many(user_id, [
            %{
              "source" => "manual",
              "title" => "Send the board deck draft",
              "summary" => "The board deck draft is due.",
              "next_action" => "Finish and send the draft.",
              "dedupe_key" => "todos-local-due-#{index}",
              "due_at" => date
            }
          ])

        assert DateTime.compare(todo.due_at, expected) == :eq,
               "expected #{date} -> #{inspect(expected)}, got #{inspect(todo.due_at)}"
      end

      # A bare-date snooze resolves the same way through the same boundary.
      {:ok, [snoozed]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "manual",
            "title" => "Revisit the vendor renewal quote",
            "summary" => "The vendor renewal quote can wait until Friday.",
            "next_action" => "Reopen the quote and decide.",
            "dedupe_key" => "todos-local-snooze",
            "status" => "snoozed",
            "snoozed_until" => "2026-07-10"
          }
        ])

      assert DateTime.compare(snoozed.snoozed_until, ~U[2026-07-11 00:00:00Z]) == :eq
    end

    test "bare dates fall back to UTC end-of-day, never midnight, when no timezone resolves" do
      user_id = unique_user_email("todos-utc-due")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "manual",
            "title" => "Send the board deck draft",
            "summary" => "The board deck draft is due.",
            "next_action" => "Finish and send the draft.",
            "dedupe_key" => "todos-utc-due",
            "due_at" => "2026-07-10"
          }
        ])

      assert DateTime.compare(todo.due_at, ~U[2026-07-10 23:59:59Z]) == :eq
    end

    test "instant timestamps keep instant semantics: source_occurred_at bare date stays midnight UTC" do
      user_id = unique_user_email("todos-instant")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "manual",
            "title" => "Send the board deck draft",
            "summary" => "The board deck draft is due.",
            "next_action" => "Finish and send the draft.",
            "dedupe_key" => "todos-instant",
            "source_occurred_at" => "2026-07-10"
          }
        ])

      assert DateTime.compare(todo.source_occurred_at, ~U[2026-07-10 00:00:00Z]) == :eq
    end

    test "parse_flexible_datetime reads naive datetimes as local wall time and keeps offsets" do
      user_id = unique_user_email("todos-flexible-parse")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "ai_chief_of_staff",
          config: %{
            "name" => "Chief of Staff",
            "timezone" => "America/Toronto",
            "timezone_name" => "America/Toronto",
            "timezone_offset_hours" => -5
          }
        })

      # Naive datetime = local wall clock (July -> DST -4).
      assert Todos.parse_flexible_datetime("2026-07-06T09:00:00", user_id) ==
               ~U[2026-07-06 13:00:00Z]

      # Explicit offsets pass through untouched.
      assert Todos.parse_flexible_datetime("2026-07-06T09:00:00Z", user_id) ==
               ~U[2026-07-06 09:00:00Z]

      # Bare date = local end-of-day.
      assert Todos.parse_flexible_datetime("2026-07-06", user_id) == ~U[2026-07-07 00:00:00Z]

      assert Todos.parse_flexible_datetime("not a datetime", user_id) == nil
      assert Todos.parse_flexible_datetime("", user_id) == nil
    end

    test "clear_nudge_cadence clears next_nudge_at atomically, appends the note, keeps the todo open" do
      user_id = unique_user_email("todos-clear-cadence")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "gmail",
            "title" => "Waiting on Elena for the pricing doc",
            "summary" => "Elena owes you the pricing doc for the renewal.",
            "next_action" => "Nudge Elena if she stays quiet.",
            "dedupe_key" => "todos-clear-cadence",
            "direction" => "owed_to_me",
            "counterparty_label" => "Elena",
            "next_nudge_at" => "2099-07-09T15:30:00Z",
            "metadata" => %{"project" => "renewal"}
          }
        ])

      assert %DateTime{} = todo.next_nudge_at

      assert {:ok, cleared} = Todos.clear_nudge_cadence(user_id, todo.id)
      assert cleared.next_nudge_at == nil
      assert cleared.status == "open"
      assert cleared.metadata["resolution_note"] =~ "cadence cleared"
      # Atomic jsonb merge preserves the rest of metadata.
      assert cleared.metadata["project"] == "renewal"

      assert Todos.clear_nudge_cadence(user_id, Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  defp gmail_todo_attrs(thread_id, title, overrides \\ []) do
    defaults = %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "This Gmail thread still needs a user response.",
      "next_action" => "Reply in-thread and close the loop.",
      "priority" => 90,
      "source_item_id" => thread_id,
      "source_occurred_at" => "2026-04-02T04:19:00Z",
      "dedupe_key" => "gmail:gmail_triage:#{thread_id}",
      "metadata" => %{
        "thread_id" => thread_id,
        "subject" => title,
        "from" => "ops@example.com",
        "google_account_email" => "kent@voteagora.com"
      }
    }

    overrides
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.into(defaults)
  end

  defp decision_pagination_attrs(suffix, title, direction) do
    %{
      "source" => "manual",
      "kind" => "general",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "Background material for quarterly planning.",
      "next_action" => "Read the material next week.",
      "priority" => 50,
      "direction" => direction,
      "dedupe_key" => "todos-decision-pagination:#{suffix}"
    }
  end

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
