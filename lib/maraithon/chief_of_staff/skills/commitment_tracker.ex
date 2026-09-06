defmodule Maraithon.ChiefOfStaff.Skills.CommitmentTracker do
  @moduledoc """
  Daily model-backed commitment tracker for the AI Chief of Staff.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  require Logger

  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.{SourceBundle, SourceScope}
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Crm
  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Memory
  alias Maraithon.OpenLoops
  alias Maraithon.PromptBudget
  alias Maraithon.SourceLabels
  alias Maraithon.Timezones
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias Maraithon.Tracing

  @default_timezone_offset_hours -5
  @default_review_hour 7
  @default_email_scan_limit 200
  @default_event_scan_limit 80
  @default_slack_message_scan_limit 180
  @default_local_message_scan_limit 300
  @default_local_chat_scan_limit 120
  @default_local_voice_memo_scan_limit 100
  @default_local_note_scan_limit 120
  @default_local_reminder_scan_limit 120
  @default_local_file_scan_limit 100
  @default_local_browser_visit_scan_limit 200
  @default_lookback_hours 24 * 14
  @default_calendar_forward_days 14
  @default_llm_max_tokens 32_000
  @default_llm_reasoning_effort "high"
  @vague_self_commitment_followup_hour 16
  @explicit_clock_time_pattern ~r/\b(?:[01]?\d|2[0-3])(?::[0-5]\d)?\s*(?:a\.?m\.?|p\.?m\.?)\b|\b(?:[01]?\d|2[0-3]):[0-5]\d\b/i
  @explicit_time_words [
    "this morning",
    "tomorrow morning",
    "morning",
    "noon",
    "lunch",
    "tonight",
    "this evening",
    "tomorrow evening",
    "end of day",
    "eod"
  ]
  @skill_path "priv/agents/skills/chief_of_staff/commitment_tracker.md"
  @tracker_input_fit_budgets [96_000, 80_000, 72_000, 56_000, 48_000, 40_000, 32_000]
  @max_previous_cycle_memo_bytes 4_000

  @impl true
  def id, do: "commitment_tracker"

  @impl true
  def label, do: "Commitment tracker"

  @impl true
  def description do
    "Finds work-related promises and asks, then saves them as open work."
  end

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "commitment_review_hour_local" => @default_review_hour,
      "email_scan_limit" => @default_email_scan_limit,
      "event_scan_limit" => @default_event_scan_limit,
      "slack_message_scan_limit" => @default_slack_message_scan_limit,
      "local_message_scan_limit" => @default_local_message_scan_limit,
      "local_chat_scan_limit" => @default_local_chat_scan_limit,
      "local_voice_memo_scan_limit" => @default_local_voice_memo_scan_limit,
      "local_note_scan_limit" => @default_local_note_scan_limit,
      "local_reminder_scan_limit" => @default_local_reminder_scan_limit,
      "local_file_scan_limit" => @default_local_file_scan_limit,
      "local_browser_visit_scan_limit" => @default_local_browser_visit_scan_limit,
      "lookback_hours" => @default_lookback_hours,
      "calendar_forward_days" => @default_calendar_forward_days,
      "llm_max_tokens" => @default_llm_max_tokens,
      "llm_reasoning_effort" => @default_llm_reasoning_effort
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider_service,
        provider: "google",
        service: "gmail",
        label: "Gmail",
        description: "Required to scan recent sent and received mail for commitments.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Required to scan upcoming events for time-bound commitments.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "slack",
        service: "channels",
        label: "Slack Channels",
        description: "Required to scan channel discussions for actionable commitments.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "slack",
        service: "dms",
        label: "Slack DMs",
        description: "Required to scan direct and group messages for actionable commitments.",
        required?: true
      },
      %{
        kind: :provider,
        provider: "desktop",
        label: "Mac companion",
        description:
          "Optional local context source for iMessage, voice notes, Apple Notes, Reminders, local calendar, files, and browser history.",
        required?: false
      },
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Needed to deliver the commitment tracker summary.",
        required?: false
      }
    ]
  end

  @impl true
  def subscriptions(config, user_id) when is_binary(user_id) do
    SourceScope.subscriptions(Map.get(config, "source_scope", %{}), user_id)
  end

  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    cond do
      force_review_trigger?(context) ->
        true

      true ->
        case get_in(context, [:trigger, :type]) do
          :message -> false
          :pubsub_event -> false
          _ -> true
        end
    end
  end

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      assistant_behavior: normalize_string(config["assistant_behavior"]) || "ai_chief_of_staff",
      timezone: normalize_timezone(config["timezone"] || config["timezone_name"]),
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      review_hour:
        integer_in_range(config["commitment_review_hour_local"], @default_review_hour, 0, 23),
      email_scan_limit:
        integer_in_range(config["email_scan_limit"], @default_email_scan_limit, 1, 200),
      event_scan_limit:
        integer_in_range(config["event_scan_limit"], @default_event_scan_limit, 1, 120),
      slack_message_scan_limit:
        integer_in_range(
          config["slack_message_scan_limit"],
          @default_slack_message_scan_limit,
          1,
          500
        ),
      local_message_scan_limit:
        integer_in_range(
          config["local_message_scan_limit"],
          @default_local_message_scan_limit,
          1,
          500
        ),
      local_chat_scan_limit:
        integer_in_range(
          config["local_chat_scan_limit"],
          @default_local_chat_scan_limit,
          1,
          200
        ),
      local_voice_memo_scan_limit:
        integer_in_range(
          config["local_voice_memo_scan_limit"],
          @default_local_voice_memo_scan_limit,
          1,
          200
        ),
      local_note_scan_limit:
        integer_in_range(
          config["local_note_scan_limit"],
          @default_local_note_scan_limit,
          1,
          200
        ),
      local_reminder_scan_limit:
        integer_in_range(
          config["local_reminder_scan_limit"],
          @default_local_reminder_scan_limit,
          1,
          200
        ),
      local_file_scan_limit:
        integer_in_range(
          config["local_file_scan_limit"],
          @default_local_file_scan_limit,
          1,
          200
        ),
      local_browser_visit_scan_limit:
        integer_in_range(
          config["local_browser_visit_scan_limit"],
          @default_local_browser_visit_scan_limit,
          1,
          250
        ),
      lookback_hours: integer_in_range(config["lookback_hours"], @default_lookback_hours, 1, 336),
      calendar_forward_days:
        integer_in_range(
          config["calendar_forward_days"],
          @default_calendar_forward_days,
          1,
          30
        ),
      llm_model: normalize_string(config["llm_model"]),
      llm_max_tokens:
        integer_in_range(config["llm_max_tokens"], @default_llm_max_tokens, 512, 32_000),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      pending_effect: nil,
      last_run_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()
    period_key = local_period_key(now, timezone_offset_hours_at(now, state))
    force_review? = force_review_trigger?(context)
    dedupe_key = commitment_dedupe_key(period_key, context)

    cond do
      is_nil(user_id) ->
        {:idle, state}

      not scheduled_trigger?(context) ->
        {:idle, %{state | user_id: user_id}}

      not force_review? and Map.get(state.last_run_keys, "daily") == period_key ->
        {:idle, %{state | user_id: user_id}}

      not force_review? and not due_now?(now, state) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        tracker_input = build_tracker_input(user_id, now, state, context)

        pending_state = %{
          state
          | user_id: user_id,
            pending_effect: pending_effect(tracker_input, context, dedupe_key, now)
        }

        case llm_params(tracker_input, state, context) do
          {:ok, params} ->
            {:effect, {:llm_call, params}, pending_state}

          {:error, reason} ->
            handle_effect_result(
              {:llm_call,
               %{
                 content: "",
                 error: Maraithon.Redaction.error_summary(reason),
                 finish_reason: "error"
               }},
              pending_state,
              context
            )
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    Tracing.with_span(
      "chief_of_staff.commitment_tracker",
      %{
        skill: "commitment_tracker",
        user_id: context[:user_id] || state.user_id,
        finish_reason: llm_finish_reason(response) || "ok"
      },
      fn ->
        pending_effect = state.pending_effect || %{}
        tracker_input = tracker_input_for_result(pending_effect, context)
        parsed_report = parse_llm_report(response)

        {report, generation_mode, error_message} =
          report_or_error_notice(parsed_report, response, tracker_input)

        report = cap_report_todos(report)

        if generation_mode == "error" do
          Tracing.record_error(
            "commitment_tracker generation failed: " <>
              String.slice(error_message || "unknown", 0, 300)
          )
        end

        brief_dedupe_key =
          read_string(pending_effect, "dedupe_key", nil) ||
            "commitment_tracker:#{read_string(tracker_input, "date", "unknown")}"

        tracker_input =
          if is_binary(context[:agent_id]) and not admin_open_work_rebuild_context?(context),
            do: Map.put(tracker_input, "todo_target_brief_dedupe_key", brief_dedupe_key),
            else: tracker_input

        todo_result =
          if generation_mode == "llm" or Map.has_key?(report, "linked_todo_ids") do
            persist_model_todos(context[:user_id] || state.user_id, report, tracker_input)
          else
            {:ok, :no_todos}
          end

        report = append_todo_write_summary(report, todo_result)

        attrs = %{
          "cadence" => "commitment_tracker",
          "scheduled_for" =>
            read_string(
              tracker_input,
              "generated_at",
              DateTime.utc_now() |> DateTime.to_iso8601()
            ),
          "dedupe_key" => brief_dedupe_key,
          "status" => "pending",
          "title" =>
            report
            |> read_string(
              "title",
              "Open work review - #{read_string(tracker_input, "date", "today")}"
            )
            |> truncate(180),
          "summary" =>
            report
            |> read_string("summary", "Review new commitments captured from connected sources.")
            |> truncate(500),
          "body" =>
            report
            |> read_string("body", "Open work review did not produce a body.")
            |> truncate(3_900),
          "error_message" => error_message,
          "metadata" => %{
            "agent_behavior" => state.assistant_behavior,
            "assistant_behavior" => state.assistant_behavior,
            "assistant_cycle_id" => context[:assistant_cycle_id],
            "brief_type" => id(),
            "error_message" => error_message,
            "generation_mode" => generation_mode,
            "llm_finish_reason" => llm_finish_reason(response),
            "origin_skill_id" => id(),
            "source_backed" => true,
            "tracker_input" => compact_tracker_input_for_metadata(tracker_input),
            "source_health" => read_map(tracker_input, "source_health"),
            "source_access" => read_map(tracker_input, "source_access"),
            "todo_write" => summarize_todo_result(todo_result)
          }
        }

        if admin_open_work_rebuild_context?(context) do
          period_key = read_string(tracker_input, "date", nil)

          todo_payload =
            todo_result
            |> todo_event_payload()
            |> Map.merge(report_event_payload(report, generation_mode, response, error_message))
            |> Map.put(:linked_todo_ids, [])

          {:emit,
           {:open_work_rebuilt,
            %{
              count: 0,
              error_message: error_message,
              generation_mode: generation_mode,
              user_id: context[:user_id] || state.user_id,
              cadences: ["commitment_tracker"],
              source_backed: true,
              brief_id: nil
            }
            |> Map.merge(todo_payload)},
           %{
             state
             | pending_effect: nil,
               last_run_keys: Map.put(state.last_run_keys, "daily", period_key)
           }}
        else
          case Briefs.record(context[:user_id] || state.user_id, context[:agent_id], attrs) do
            {:ok, brief_record} ->
              period_key = read_string(tracker_input, "date", nil)

              {brief_record, linked_todo_ids, todo_link_error} =
                attach_model_todos_to_brief(brief_record, todo_result)

              event_type =
                if generation_mode in ["llm", "source_fallback"],
                  do: :briefs_recorded,
                  else: :brief_generation_failed

              todo_payload =
                todo_result
                |> todo_event_payload()
                |> Map.merge(
                  report_event_payload(report, generation_mode, response, error_message)
                )
                |> Map.put(:linked_todo_ids, linked_todo_ids)
                |> maybe_put(:todo_link_error, todo_link_error)

              {:emit,
               {event_type,
                %{
                  count: 1,
                  error_message: error_message,
                  generation_mode: generation_mode,
                  user_id: context[:user_id] || state.user_id,
                  cadences: ["commitment_tracker"],
                  source_backed: true,
                  brief_id: brief_record.id
                }
                |> Map.merge(todo_payload)},
               %{
                 state
                 | pending_effect: nil,
                   last_run_keys: Map.put(state.last_run_keys, "daily", period_key)
               }}

            {:error, _reason} ->
              {:idle, %{state | pending_effect: nil}}
          end
        end
      end
    )
  end

  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  @impl true
  def handle_effect_error(:llm_call, reason, state, context) do
    handle_effect_result(
      {:llm_call,
       %{
         content: "",
         error: Maraithon.Redaction.error_summary(reason),
         finish_reason: "error"
       }},
      state,
      context
    )
  end

  def handle_effect_error(_effect_type, _reason, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    now = DateTime.utc_now()
    {:absolute, next_review_occurrence(now, state)}
  end

  def build_tracker_input(user_id, now, state, context) do
    source_bundle = context[:source_bundle] || %{}
    offset_hours = timezone_offset_hours_at(now, state)
    local_date = local_date(now, offset_hours)
    lookback_start = DateTime.add(now, -state.lookback_hours, :hour)
    calendar_end = Date.add(local_date, state.calendar_forward_days)

    inbox_messages =
      source_bundle
      |> SourceBundle.gmail_inbox_messages()
      |> Enum.filter(&recent_gmail_message?(&1, lookback_start))
      |> Enum.sort_by(&gmail_message_sort_key/1, :desc)
      |> SourceBundle.prioritize_gmail_actionable()

    sent_messages =
      source_bundle
      |> SourceBundle.gmail_sent_messages()
      |> Enum.filter(&recent_gmail_message?(&1, lookback_start))
      |> Enum.sort_by(&gmail_message_sort_key/1, :desc)
      |> SourceBundle.prioritize_gmail_actionable()

    calendar_events =
      source_bundle
      |> SourceBundle.calendar_events()
      |> Enum.filter(&event_in_date_window?(&1, local_date, calendar_end, offset_hours))
      |> Enum.sort_by(&event_sort_key/1)

    local_calendar_events =
      source_bundle
      |> SourceBundle.calendar_local_events()
      |> Enum.filter(&event_in_date_window?(&1, local_date, calendar_end, offset_hours))
      |> Enum.sort_by(&event_sort_key/1)

    slack_messages =
      source_bundle
      |> SourceBundle.slack_messages()
      |> Enum.filter(&recent_slack_message?(&1, lookback_start))
      |> Enum.reject(&(read_string(&1, "text", nil) in [nil, ""]))
      |> Enum.sort_by(&slack_message_sort_key/1, :desc)

    slack_self_authored_messages =
      slack_messages
      |> Enum.filter(&slack_self_authored_search_message?/1)
      |> Enum.sort_by(&slack_message_sort_key/1, :desc)

    slack_mentions =
      source_bundle
      |> SourceBundle.slack_mentions()
      |> Enum.reject(&(read_string(&1, "text", nil) in [nil, ""]))
      |> Enum.sort_by(&slack_message_sort_key/1, :desc)

    imessage_messages =
      source_bundle
      |> SourceBundle.imessage_messages()
      |> Enum.filter(&recent_local_message?(&1, lookback_start))
      |> Enum.reject(&(read_string(&1, "text", nil) in [nil, ""]))
      |> Enum.sort_by(&local_message_sort_key/1, :desc)

    imessage_chats =
      source_bundle
      |> SourceBundle.imessage_chats()
      |> Enum.sort_by(&local_chat_sort_key/1, :desc)

    imessage_people_by_handle =
      user_id
      |> Crm.people_by_contact_values(
        imessage_sender_handles(
          Enum.take(imessage_messages, state.local_message_scan_limit),
          Enum.take(imessage_chats, state.local_chat_scan_limit)
        )
      )

    voice_memos =
      source_bundle
      |> SourceBundle.voice_memos()
      |> Enum.sort_by(&voice_memo_sort_key/1, :desc)

    notes =
      source_bundle
      |> SourceBundle.notes()
      |> Enum.sort_by(&note_sort_key/1, :desc)

    reminders =
      source_bundle
      |> SourceBundle.reminders()
      |> Enum.sort_by(&reminder_sort_key/1, :asc)

    files =
      source_bundle
      |> SourceBundle.files()
      |> Enum.sort_by(&file_sort_key/1, :desc)

    browser_visits =
      source_bundle
      |> SourceBundle.browser_visits()
      |> Enum.sort_by(&browser_visit_sort_key/1, :desc)

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "timezone" => timezone_label(state, now),
      "timezone_offset_hours" => offset_hours,
      "lookback_hours" => state.lookback_hours,
      "calendar_forward_days" => state.calendar_forward_days,
      "source_access" => source_access(source_bundle),
      "gmail" => %{
        "recent_inbox" =>
          inbox_messages
          |> Enum.map(&gmail_message_for_prompt/1)
          |> Enum.take(state.email_scan_limit),
        "recent_sent" =>
          sent_messages
          |> Enum.map(&gmail_message_for_prompt/1)
          |> Enum.take(state.email_scan_limit),
        "counts" => %{
          "recent_inbox" => length(inbox_messages),
          "recent_sent" => length(sent_messages)
        }
      },
      "calendar" => %{
        "window_start" => Date.to_iso8601(local_date),
        "window_end" => Date.to_iso8601(calendar_end),
        "upcoming_events" =>
          calendar_events
          |> Enum.map(&calendar_event_for_prompt/1)
          |> Enum.take(state.event_scan_limit),
        "counts" => %{"upcoming_events" => length(calendar_events)}
      },
      "local_calendar" => %{
        "window_start" => Date.to_iso8601(local_date),
        "window_end" => Date.to_iso8601(calendar_end),
        "upcoming_events" =>
          local_calendar_events
          |> Enum.map(&calendar_event_for_prompt/1)
          |> Enum.take(state.event_scan_limit),
        "counts" => %{"upcoming_events" => length(local_calendar_events)}
      },
      "slack" => %{
        "self_authored_recent" =>
          slack_self_authored_messages
          |> Enum.map(&slack_message_for_prompt/1)
          |> Enum.take(80),
        "recent_messages" =>
          slack_messages
          |> Enum.map(&slack_message_for_prompt/1)
          |> Enum.take(state.slack_message_scan_limit),
        "mentions" =>
          slack_mentions
          |> Enum.map(&slack_message_for_prompt/1)
          |> Enum.take(state.slack_message_scan_limit),
        "counts" => %{
          "self_authored_recent" => length(slack_self_authored_messages),
          "recent_messages" => length(slack_messages),
          "mentions" => length(slack_mentions)
        }
      },
      "imessage" => %{
        "recent_messages" =>
          imessage_messages
          |> Enum.take(state.local_message_scan_limit)
          |> Enum.map(&imessage_message_for_prompt(&1, imessage_people_by_handle)),
        "chats" =>
          imessage_chats
          |> Enum.take(state.local_chat_scan_limit)
          |> Enum.map(&imessage_chat_for_prompt(&1, imessage_people_by_handle)),
        "counts" => %{
          "recent_messages" => length(imessage_messages),
          "chats" => length(imessage_chats)
        }
      },
      "voice_memos" => %{
        "items" =>
          voice_memos
          |> Enum.map(&voice_memo_for_prompt/1)
          |> Enum.take(state.local_voice_memo_scan_limit),
        "counts" => %{"items" => length(voice_memos)}
      },
      "notes" => %{
        "items" =>
          notes
          |> Enum.map(&note_for_prompt/1)
          |> Enum.take(state.local_note_scan_limit),
        "counts" => %{"items" => length(notes)}
      },
      "reminders" => %{
        "due_soon" =>
          reminders
          |> Enum.map(&reminder_for_prompt/1)
          |> Enum.take(state.local_reminder_scan_limit),
        "counts" => %{"due_soon" => length(reminders)}
      },
      "files" => %{
        "recent" =>
          files
          |> Enum.map(&file_for_prompt/1)
          |> Enum.take(state.local_file_scan_limit),
        "counts" => %{"recent" => length(files)}
      },
      "browser_history" => %{
        "recent" =>
          browser_visits
          |> Enum.map(&browser_visit_for_prompt/1)
          |> Enum.take(state.local_browser_visit_scan_limit),
        "counts" => %{"recent" => length(browser_visits)}
      },
      "open_work" => %{
        "todos" =>
          user_id
          |> Todos.list_open_for_user(limit: 40)
          |> Enum.map(&todo_for_prompt/1)
      },
      "user_identity" => Maraithon.UserIdentity.prompt_block(user_id),
      "relationships" => Crm.summarize_for_prompt(user_id, 24),
      "deep_memory" =>
        Memory.prompt_context(user_id,
          query:
            "commitment tracker work commitments promises asks pending replies relevance feedback",
          limit: 12
        ),
      "source_health" => SourceBundle.freshness(source_bundle)
    }
  end

  defp pending_effect(tracker_input, context, dedupe_key, now) do
    projected = compact_tracker_sections_for_prompt(tracker_input)

    %{
      effect_kind: :commitment_review,
      cycle_id: context[:assistant_cycle_id],
      candidate_refs: tracker_candidate_refs(projected),
      dedupe_key: dedupe_key,
      window_key: read_string(tracker_input, "date", nil),
      generated_at: read_string(tracker_input, "generated_at", DateTime.to_iso8601(now)),
      timezone: read_string(tracker_input, "timezone", nil),
      timezone_offset_hours: tracker_input_timezone_offset_hours(tracker_input),
      issued_at: DateTime.to_iso8601(now)
    }
  end

  defp tracker_candidate_refs(input) do
    [
      {"gmail", "recent_inbox", :gmail},
      {"gmail", "recent_sent", :gmail},
      {"calendar", "upcoming_events", :calendar},
      {"local_calendar", "upcoming_events", :calendar},
      {"slack", "self_authored_recent", :slack},
      {"slack", "recent_messages", :slack},
      {"slack", "mentions", :slack},
      {"imessage", "recent_messages", :message},
      {"imessage", "chats", :message},
      {"open_work", "todos", :todo},
      {"voice_memos", "items", :local_item},
      {"notes", "items", :local_item},
      {"reminders", "due_soon", :local_item},
      {"files", "recent", :local_item},
      {"browser_history", "recent", :local_item}
    ]
    |> Enum.flat_map(fn {source, bucket, kind} ->
      input
      |> read_map(source)
      |> read_list(bucket)
      |> Enum.map(&tracker_candidate_ref(&1, source, bucket, kind))
    end)
  end

  defp tracker_candidate_ref(item, source, bucket, :gmail) do
    %{
      "source" => source,
      "bucket" => bucket,
      "message_id" => read_string(item, "message_id", nil),
      "thread_id" => read_string(item, "thread_id", nil),
      "source_item_id" => read_string(item, "source_item_id", nil),
      "subject" => read_string(item, "subject", nil),
      "from" => read_string(item, "from", nil),
      "to" => read_string(item, "to", nil),
      "occurred_at" => read_string(item, "date", nil),
      "account" => read_string(item, "account", nil),
      "google_provider" => read_string(item, "google_provider", nil)
    }
    |> compact_map()
  end

  defp tracker_candidate_ref(item, source, bucket, :calendar) do
    %{
      "source" => source,
      "bucket" => bucket,
      "event_id" => read_string(item, "event_id", nil),
      "subject" => read_string(item, "summary", nil),
      "occurred_at" => read_string(item, "start", nil),
      "end" => read_string(item, "end", nil),
      "account" => read_string(item, "account", nil)
    }
    |> compact_map()
  end

  defp tracker_candidate_ref(item, source, bucket, :slack) do
    %{
      "source" => source,
      "bucket" => bucket,
      "team_id" => read_string(item, "team_id", nil),
      "channel_id" => read_string(item, "channel_id", nil),
      "ts" => read_string(item, "ts", nil),
      "thread_ts" => read_string(item, "thread_ts", nil),
      "source_item_id" => read_string(item, "source_item_id", nil),
      "from" => read_string(item, "user_display_name", read_string(item, "user", nil)),
      "occurred_at" => read_string(item, "date", nil)
    }
    |> compact_map()
  end

  defp tracker_candidate_ref(item, source, bucket, :todo) do
    %{
      "source" => source,
      "bucket" => bucket,
      "id" => read_string(item, "id", nil),
      "title" => truncate(read_string(item, "title", nil), 300),
      "summary" => truncate(read_string(item, "summary", nil), 500),
      "next_action" => truncate(read_string(item, "next_action", nil), 500),
      "due_at" => read_string(item, "due_at", nil),
      "todo_source" => read_string(item, "source", nil),
      "source_item_id" => read_string(item, "source_item_id", nil),
      "source_account_label" => read_string(item, "source_account_label", nil)
    }
    |> compact_map()
  end

  defp tracker_candidate_ref(item, source, bucket, _kind) do
    %{
      "source" => source,
      "bucket" => bucket,
      "source_item_id" =>
        read_string(
          item,
          "source_item_id",
          read_string(item, "message_id", read_string(item, "chat_id", nil))
        ),
      "subject" =>
        truncate(
          read_string(item, "title", read_string(item, "filename", nil)),
          300
        ),
      "from" => read_string(item, "sender_display_name", read_string(item, "sender_handle", nil)),
      "occurred_at" =>
        read_string(
          item,
          "source_occurred_at",
          read_string(item, "created_at", read_string(item, "modified_at", nil))
        )
    }
    |> compact_map()
  end

  defp tracker_input_for_result(pending_effect, context) do
    refs = Map.get(pending_effect, :candidate_refs, Map.get(pending_effect, "candidate_refs", []))
    source_bundle = context[:source_bundle] || %{}

    %{
      "date" => read_string(pending_effect, "window_key", nil),
      "generated_at" => read_string(pending_effect, "generated_at", nil),
      "timezone" => read_string(pending_effect, "timezone", nil),
      "timezone_offset_hours" => read_any(pending_effect, "timezone_offset_hours"),
      "source_access" => source_access(source_bundle),
      "source_health" => SourceBundle.freshness(source_bundle),
      "gmail" => %{
        "recent_inbox" => result_refs(refs, "gmail", "recent_inbox"),
        "recent_sent" => result_refs(refs, "gmail", "recent_sent")
      },
      "calendar" => %{
        "upcoming_events" => result_refs(refs, "calendar", "upcoming_events")
      },
      "local_calendar" => %{
        "upcoming_events" => result_refs(refs, "local_calendar", "upcoming_events")
      },
      "slack" => %{
        "self_authored_recent" => result_refs(refs, "slack", "self_authored_recent"),
        "recent_messages" => result_refs(refs, "slack", "recent_messages"),
        "mentions" => result_refs(refs, "slack", "mentions")
      },
      "imessage" => %{
        "recent_messages" => result_refs(refs, "imessage", "recent_messages"),
        "chats" => result_refs(refs, "imessage", "chats")
      },
      "open_work" => %{"todos" => result_todo_refs(refs)},
      "voice_memos" => %{"items" => result_refs(refs, "voice_memos", "items")},
      "notes" => %{"items" => result_refs(refs, "notes", "items")},
      "reminders" => %{"due_soon" => result_refs(refs, "reminders", "due_soon")},
      "files" => %{"recent" => result_refs(refs, "files", "recent")},
      "browser_history" => %{"recent" => result_refs(refs, "browser_history", "recent")}
    }
  end

  defp result_refs(refs, source, bucket) when is_list(refs) do
    refs
    |> Enum.filter(fn ref ->
      read_string(ref, "source", nil) == source and read_string(ref, "bucket", nil) == bucket
    end)
    |> Enum.map(&Map.drop(&1, ["source", "bucket"]))
  end

  defp result_refs(_refs, _source, _bucket), do: []

  defp result_todo_refs(refs) do
    refs
    |> result_refs("open_work", "todos")
    |> Enum.map(fn ref ->
      ref
      |> Map.put("source", read_string(ref, "todo_source", nil))
      |> Map.delete("todo_source")
    end)
  end

  defp llm_params(tracker_input, state, context) do
    Enum.reduce_while(
      @tracker_input_fit_budgets,
      {:error, {:invalid_request, %{reason: "commitment_request_exceeds_budget"}}},
      fn input_bytes, _last_error ->
        case bounded_llm_params(tracker_input, state, context, input_bytes) do
          {:ok, _params} = success -> {:halt, success}
          {:error, _reason} = error -> {:cont, error}
        end
      end
    )
  end

  defp bounded_llm_params(tracker_input, state, context, input_bytes) do
    with {:ok, prompt} <- commitment_prompt(tracker_input, context, input_bytes) do
      %{
        "messages" => [
          %{
            "role" => "user",
            "content" => prompt
          }
        ],
        "max_tokens" => state.llm_max_tokens,
        "temperature" => 0.1,
        "reasoning_effort" => state.llm_reasoning_effort
      }
      |> maybe_put("model", state.llm_model)
      |> RequestBudget.validate()
    end
  end

  defp compact_tracker_input_for_prompt(tracker_input, max_bytes) when is_map(tracker_input) do
    tracker_input = compact_tracker_sections_for_prompt(tracker_input)

    PromptBudget.project_fields(
      tracker_input,
      [
        {"date", 300},
        {"generated_at", 300},
        {"timezone", 300},
        {"timezone_offset_hours", 100},
        {"lookback_hours", 100},
        {"calendar_forward_days", 100},
        {"source_access", 3_000},
        {"source_health", 3_000},
        {"open_work", 7_000},
        {"gmail", 36_000},
        {"slack", 26_000},
        {"calendar", 8_000},
        {"local_calendar", 5_000},
        {"imessage", 8_000},
        {"relationships", 3_000},
        {"deep_memory", 3_000},
        {"user_identity", 1_000},
        {"reminders", 2_000},
        {"notes", 2_000},
        {"voice_memos", 2_000},
        {"files", 2_000},
        {"browser_history", 2_000}
      ],
      max_bytes,
      string_bytes: 6_000,
      list_items: 32,
      map_entries: 100,
      max_depth: 6,
      key_bytes: 255
    ) || %{}
  end

  defp compact_tracker_input_for_prompt(_tracker_input, _max_bytes), do: %{}

  defp compact_tracker_sections_for_prompt(tracker_input) do
    tracker_input
    |> compact_tracker_section("gmail", [
      {"recent_inbox", 16, 1_400, :gmail_obligation},
      {"recent_sent", 16, 1_400, :gmail_obligation}
    ])
    |> compact_tracker_section("slack", [
      {"self_authored_recent", 12, 1_200, :message_obligation},
      {"mentions", 8, 1_200, :message_obligation},
      {"recent_messages", 12, 1_200, :message_obligation}
    ])
    |> compact_tracker_section("calendar", [{"upcoming_events", 12, 900}])
    |> compact_tracker_section("local_calendar", [{"upcoming_events", 12, 900}])
    |> compact_tracker_section("imessage", [
      {"recent_messages", 8, 1_000},
      {"chats", 4, 800}
    ])
    |> compact_tracker_section("open_work", [{"todos", 12, 1_400}])
    |> compact_tracker_section("voice_memos", [{"items", 8, 1_000}])
    |> compact_tracker_section("notes", [{"items", 8, 1_000}])
    |> compact_tracker_section("reminders", [{"due_soon", 8, 1_000}])
    |> compact_tracker_section("files", [{"recent", 8, 1_000}])
    |> compact_tracker_section("browser_history", [{"recent", 8, 800}])
  end

  defp compact_tracker_section(tracker_input, section_key, list_specs) do
    case Map.get(tracker_input, section_key) do
      section when is_map(section) ->
        compacted =
          Enum.reduce(list_specs, Map.drop(section, Enum.map(list_specs, &elem(&1, 0))), fn
            {list_key, limit, item_bytes, priority_mode}, acc ->
              items =
                section
                |> Map.get(list_key, [])
                |> prioritize_tracker_items(priority_mode)
                |> compact_tracker_items(limit, item_bytes)

              Map.put(acc, list_key, items)

            {list_key, limit, item_bytes}, acc ->
              items =
                section
                |> Map.get(list_key, [])
                |> compact_tracker_items(limit, item_bytes)

              Map.put(acc, list_key, items)
          end)

        Map.put(tracker_input, section_key, compacted)

      _other ->
        tracker_input
    end
  end

  defp prioritize_tracker_items(items, mode) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} ->
      priority = if tracker_obligation_evidence?(item, mode), do: 0, else: 1
      {priority, index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp prioritize_tracker_items(_items, _mode), do: []

  defp tracker_obligation_evidence?(item, :gmail_obligation) when is_map(item) do
    truthy_value?(Map.get(item, "body_available")) and
      obligation_evidence_text?(read_string(item, "body", ""))
  end

  defp tracker_obligation_evidence?(item, :message_obligation) when is_map(item) do
    obligation_evidence_text?(read_string(item, "text", ""))
  end

  defp tracker_obligation_evidence?(_item, _mode), do: false

  defp obligation_evidence_text?(text) when is_binary(text) do
    normalized = text |> String.downcase() |> String.trim()

    direct_ask? =
      Regex.match?(~r/\b(can|could|would|will) you\b|\bplease\b|\bneed you to\b/u, normalized)

    self_commitment? =
      Regex.match?(
        ~r/\b(i will|i'll|i’ll|i am going to|i'm going to|i’m going to|let me)\b/u,
        normalized
      )

    deadline_or_wait? =
      Regex.match?(
        ~r/\b(due|deadline|overdue|past due|by (today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|eod|end of day)|blocked|blocking|waiting on you|need your|requires your)\b/u,
        normalized
      )

    material_risk? =
      Enum.any?(
        [
          "payment failed",
          "account restricted",
          "account suspended",
          "access will be removed",
          "unrecognized login",
          "unauthorized login",
          "security incident",
          "complete kyc",
          "compliance required"
        ],
        &String.contains?(normalized, &1)
      )

    direct_ask? or self_commitment? or deadline_or_wait? or material_risk?
  end

  defp obligation_evidence_text?(_text), do: false

  defp compact_tracker_items(items, limit, item_bytes) when is_list(items) do
    items
    |> Enum.take(limit)
    |> Enum.map(
      &PromptBudget.bounded(&1, item_bytes,
        string_bytes: item_bytes,
        list_items: 16,
        map_entries: 32,
        max_depth: 5,
        key_bytes: 255
      )
    )
    |> Enum.reject(&is_nil/1)
  end

  defp compact_tracker_items(_items, _limit, _item_bytes), do: []

  defp commitment_prompt(tracker_input, context, input_bytes) do
    with {:ok, skill} <- MarkdownSkill.load_file(@skill_path),
         {:ok, input_json} <-
           Jason.encode(compact_tracker_input_for_prompt(tracker_input, input_bytes)) do
      {:ok,
       """
       Execute the loaded Markdown skill against the supplied connector context.

       Skill: #{skill.name}
       Skill path: #{@skill_path}

       Response contract:
       Return only valid JSON with this shape. Return at most 12 todo objects,
       chosen as the highest-stakes source-backed open obligations. Never spend
       the response budget on lower-value candidates after the top 12.
       {
         "title": "Open work review - YYYY-MM-DD",
         "summary": "...",
         "body": "Telegram-friendly plain text or simple markdown. No tables.",
         "pending_replies": [],
         "already_tracked": [],
         "missing_sources": [],
         "todos": [
           {
             "source": "gmail | calendar | local_calendar | slack | imessage | voice_memos | notes | reminders | files | browser_history | whatsapp | chief_of_staff_commitment_tracker",
             "title": "concise action title",
             "summary": "actual todo",
             "next_action": "suggested next action",
             "due_at": "ISO-8601 datetime or omitted",
             "status": "open | snoozed",
             "snoozed_until": "ISO-8601 datetime or omitted",
             "notes": "source evidence and metadata",
             "action_plan": "draft or plan of next action",
             "action_draft": {
               "kind": "gmail_reply | slack_reply | next_step",
               "provider": "google:account@example.com for Gmail or slack:<team id>:user:<user id> for Slack; omitted for next_step",
               "text": "exact proposed message or conversational next step",
               "to": "Gmail recipient, Gmail only",
               "subject": "Gmail subject, Gmail only",
               "thread_id": "Gmail thread id, Gmail only",
               "reply_to_message_id": "Gmail message id, Gmail only",
               "google_provider": "google:account@example.com, Gmail only",
               "google_account_email": "account@example.com, Gmail only",
               "channel_id": "Slack channel id, Slack only",
               "thread_ts": "Slack thread timestamp, Slack only",
               "team_id": "Slack workspace id, Slack only",
               "token_preference": "user, Slack only"
             },
             "owner_user_id": null,
             "owner_label": "null for the main user, or named non-user owner",
             "source_account_label": "email/calendar account when known",
             "agent_actionability": "needs_you | can_prepare | can_execute",
             "agent_action_label": "short honest label such as Maraithon can draft a reply",
             "agent_action_requires_approval": true,
             "source_item_id": "canonical thread/event/message id when known (Gmail uses thread id)",
             "source_occurred_at": "ISO-8601 datetime when known",
             "dedupe_key": "stable semantic key",
             "direction": "owed_by_me | owed_to_me | fyi",
             "counterparty_label": "the person or team this is owed to/from, or omitted",
             "next_nudge_at": "ISO-8601 datetime or omitted, owed_to_me only",
             "people": [],
             "memories": [],
             "metadata": {
               "commitment_direction": "i_owe | asked_of_me | pending_reply",
               "follow_up_reasoning": "one line on the chosen follow-up cadence, owed_to_me only",
               "completion_check": {
                 "status": "open | completed_or_closed | unclear",
                 "reasoning": "why later source evidence proves this is still open, closed, or unclear",
                 "latest_source_checked_at": "ISO-8601 datetime or omitted",
                 "later_evidence": []
               },
               "source_ref": "...",
               "source_permalink": "auditable provider URL when available",
               "slack_team_id": "Slack workspace id when the source is Slack",
               "slack_channel_id": "Slack channel id when the source is Slack",
               "slack_message_ts": "Slack message timestamp when the source is Slack",
               "gmail_message_id": "raw Gmail message id when the source is Gmail",
               "gmail_thread_id": "raw Gmail thread id when the source is Gmail",
               "google_provider": "google:<account email> when the source is Gmail",
               "google_account_email": "account email when the source is Gmail",
               "source_tags": ["project","gmail"],
               "quote": "...",
               "project_suggestion": {
                 "name": "best-fit existing or proposed project name",
                 "confidence": 0.0,
                 "evidence": "source-backed reason for the suggestion"
               },
               "company": "company or organization when known",
               "relationship_context": "why this person matters or why they are in the thread",
               "relationship_strength": 0,
               "why_it_matters": "business, project, or relationship reason this deserves attention",
               "life_domain": "personal | family | home | work when known",
               "omni_project": "best-fit OmniFocus project name when known"
             }
           }
         ]
       }

       Do not invent source access. Do not claim iMessage, WhatsApp, OmniFocus, or
       calendar write/delete were scanned or changed unless source_access says they
       are available. Current Maraithon writes commitment work items to built-in
       open work; OmniFocus/calendar mirrors are future integrations unless tools
       are explicitly present in the source_access payload.

       User-facing copy requirements:
       - Frame the report as "Open work review"; do not write "Commitment
         Tracker", skill names, source_behavior values, or automation names in
         title, summary, body, or work-item text.
       - Write directly to the operator as "you"; never write "the user" or
         "User committed".
       - If no new commitments are saved, do not write an all-clear. State
         which context was available, what remains unknown, and end with "Today's move:".
       - Every work item title, summary, next_action, notes, and action_plan must
         answer: who is involved, what the commitment is about, why it matters,
         and the best next step.
       - For iMessage/Messages source rows, when `sender_display_name` or a
         matching People record is present, use that person's name in all
         user-facing work-item copy. Never write that a raw phone number or
         handle "wants", "needs", or "is asking" when the supplied context
         identifies the person.
       - `user_identity` states who the operator is, including their own
         phone numbers and emails. Messages from those handles (or with
         is_from_me true) are the operator speaking. In group conversations,
         only create a work item when the ask is directed AT the operator
         and still open; if the operator already answered, committed, or
         someone else owns it, it is not the operator's open loop.
       - The operator's own Slack thread or channel message can be the source
         evidence. If they say they are going to message, send, follow up,
         decide, schedule, or otherwise act for a named person/project on a
         concrete future date, save that as work even when nobody explicitly
         asked. Examples include "I am going to message Pat tomorrow" and
         "I'll follow up with Sam on Friday."
       - Review slack.self_authored_recent carefully before general Slack
         chatter. Those rows come from Slack search because some private
         channels may not appear in conversation history. Treat the row text,
         timestamp, user, channel, and thread metadata as evidence; do not
         create work from the search query or phrase match alone.
       - For future-dated self-commitments, save the work item now but avoid an
         immediate nag. You MUST set status to "snoozed", not "open", and set
         snoozed_until to a polite follow-up time after the operator had time to act. For
         "tomorrow" with no exact time, use late afternoon in the operator's
         local timezone, around 4 PM local; if the source gives an explicit
         due time, use that time or shortly after it.
       - Local iMessage/Messages family chatter is context, not open work, unless
         the source text explicitly asks the operator to act or records a promise
         the operator made. Do not create work from kid/screen-time notifications,
         reactions, photo/show chatter, or vague reminders like "don't forget your
         painting" / "cool painting" unless a later adult message clearly asks
         the operator to do a concrete pickup, payment, RSVP, form, scheduling,
         reply, or other logistics action.
       - Before returning any work item, reconcile the original ask/promise against
         later evidence in every available supplied source: Gmail inbox and sent,
         Calendar, Slack, iMessage/Messages, voice notes, Notes, Reminders,
         files, browser history, existing open work, People, and memory. If later
         evidence shows the loop was replied to, declined, hired, sent, decided,
         resolved, canceled, or otherwise closed, do not return a work item. Put
         it in already_tracked with the closing evidence. If the available source
         window is not enough to tell whether it is still open, skip it and name
         the source gap; do not create "check if it still matters" work.
       - Every saved work item must include metadata.completion_check.status =
         "open" with source-backed reasoning and latest_source_checked_at. Never
         write "no later reply or delivery is recorded" unless you actually checked
         the later supplied source material for the same person/thread/topic and
         found no closure evidence.
       - For operator self-commitments, set metadata.explicit_user_commitment to
         true, metadata.commitment_direction to "i_owe", include the exact source
         quote, and keep Slack channel/thread identifiers in metadata/source fields.
       - Set the top-level `direction` field on every saved work item, not just
         metadata.commitment_direction: `owed_by_me` when the operator owes the
         counterparty (this covers self-commitments, "i_owe", "asked_of_me"),
         `owed_to_me` when the operator is waiting on someone else ("pending_reply",
         "user_owes", "waiting_on_*"), or `fyi` when nobody is waiting on anything.
         Name the counterparty in `counterparty_label` whenever the source
         identifies them.
       - Whenever you set `direction: "owed_to_me"`, also set `next_nudge_at`:
         the ISO-8601 datetime when Maraithon should propose the first follow-up
         nudge if the counterparty stays quiet. Size the cadence to the
         counterparty and urgency — a customer-blocking or deadline-bound ask
         about 2 days out, a normal work request 3-5 days, a casual intro or
         low-stakes favor 7-10 days. Put a one-line rationale for the chosen
         cadence in `metadata.follow_up_reasoning`. Never set `next_nudge_at`
         for `owed_by_me` or `fyi` items — the runtime drops it for any
         direction other than `owed_to_me`.
       - Set `agent_actionability` explicitly on every work item. Use
         `needs_you` when a human decision or hands-on step is required,
         `can_prepare` when Maraithon can draft or research the next step, and
         `can_execute` only when a currently available provider tool can perform
         the exact operation after confirmation. Never infer executability from
         source alone. Keep `agent_action_requires_approval` true for every
         external side effect, including sending Gmail or posting to Slack.
       - Put project routing only in `metadata.project_suggestion` with name,
         confidence, and evidence. A suggestion is not a confirmed project
         assignment and must never be written as `project_id` by the model.
       - For executable Gmail or Slack drafts, fill only the matching provider
         identifiers in action_draft and copy them from supplied structured
         evidence. Never invent recipients, accounts, workspace/channel IDs,
         message IDs, thread IDs, or timestamps. Use action_draft.kind `next_step`
         when those exact identifiers are unavailable; next_step is not executable.
       - Every saved work item must include action_draft.text. If a reply or
         message makes sense, write concise suggested wording in the operator's
         style. If a full draft does not make sense, write a conversational next
         step the operator can act on, for example: `You should message the
         requester and say: "Thanks, yes that would be great."`
       - If the exact ask is ambiguous, say "open the source thread to confirm
         the exact promise" rather than creating a generic follow-up item.
       - Include company, organization, relationship context, project, source
         quote/body excerpt, and confidence in metadata whenever available.

       Skill instructions:
       #{skill.instructions}

       #{previous_cycle_memo_section(context)}Commitment tracker input JSON:
       #{input_json}
       """}
    end
  end

  # R3 (SPEC 04): render the model's own cross-cycle memo (persisted in
  # behavior_state, injected via skill_context/4) as a clearly-labeled prompt
  # section so the model reasons over deltas against its own prior notes
  # instead of the memo only existing to seed the next memo.
  defp previous_cycle_memo_section(context) do
    memo = context[:previous_cycle_memo]

    if is_binary(memo) and String.trim(memo) != "" do
      """
      PREVIOUS CYCLE MEMO#{memo_meta_suffix(context)}:
      #{memo |> String.trim() |> PromptBudget.truncate_utf8(@max_previous_cycle_memo_bytes)}

      """
    else
      ""
    end
  end

  defp memo_meta_suffix(context) do
    cycle_id = context[:previous_cycle_memo_cycle_id]
    updated_at = context[:previous_cycle_memo_updated_at]

    parts =
      [{"cycle", cycle_id}, {"at", updated_at}]
      |> Enum.reject(fn {_label, value} -> blank?(value) end)
      |> Enum.map(fn {label, value} -> "#{label} #{value}" end)

    case parts do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  defp parse_llm_report(response) do
    error =
      case response do
        %{error: error} -> error
        %{"error" => error} -> error
        _ -> nil
      end

    content =
      case response do
        %{content: content} -> content
        %{"content" => content} -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    if error do
      {:error, to_string(error)}
    else
      with content when is_binary(content) and content != "" <- content,
           {:ok, %{} = data} <- decode_json(content),
           title when is_binary(title) <- read_string(data, "title", nil),
           summary when is_binary(summary) <- read_string(data, "summary", nil),
           body when is_binary(body) <- read_string(data, "body", nil) do
        todos = read_list(data, "todos") |> Enum.filter(&is_map/1)

        {:ok,
         %{
           "title" => title,
           "summary" => summary,
           "body" => body,
           "todos" => todos,
           "pending_replies" => read_list(data, "pending_replies"),
           "already_tracked" => read_list(data, "already_tracked"),
           "missing_sources" => read_list(data, "missing_sources")
         }}
      else
        _ -> {:error, "model_response_invalid_or_missing_required_commitment_json"}
      end
    end
  end

  defp report_or_error_notice({:ok, report}, _response, tracker_input),
    do: {repair_commitment_report(report, tracker_input), "llm", nil}

  defp report_or_error_notice({:error, reason}, response, tracker_input) do
    error_message =
      [
        "Open work review used available-context fallback",
        reason,
        llm_finish_reason(response) && "finish_reason=#{llm_finish_reason(response)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")

    {fallback_commitment_report(tracker_input), "source_fallback", error_message}
  end

  defp repair_commitment_report(report, tracker_input) when is_map(report) do
    report = normalize_report_public_copy(report)
    todos = read_list(report, "todos")

    if todos == [] do
      report
      |> Map.put("summary", repair_empty_commitment_summary(report, tracker_input))
      |> Map.put("body", repair_empty_commitment_body(report, tracker_input))
    else
      report
    end
  end

  defp repair_commitment_report(report, _tracker_input), do: report

  defp normalize_report_public_copy(report) when is_map(report) do
    report
    |> Map.update("title", nil, &normalize_commitment_report_text/1)
    |> Map.update("summary", nil, &normalize_commitment_report_text/1)
    |> Map.update("body", nil, &normalize_commitment_report_text/1)
  end

  defp normalize_commitment_report_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\bCommitment Tracker\b/i, "Open work review")
    |> String.replace(~r/\bCommitment tracker\b/i, "Open work review")
    |> String.replace(~r/\bcommitment tracker\b/i, "open work review")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "open work review")
  end

  defp normalize_commitment_report_text(value), do: value

  defp repair_empty_commitment_summary(report, tracker_input) do
    summary = read_string(report, "summary", "")

    if overconfident_empty_summary?(summary) do
      empty_commitment_fallback_summary(tracker_input)
    else
      summary
    end
  end

  defp repair_empty_commitment_body(report, tracker_input) do
    body = read_string(report, "body", "")
    open_todos = tracker_input |> read_map("open_work") |> read_list("todos")
    gmail = read_map(tracker_input, "gmail")
    calendar = read_map(tracker_input, "calendar")
    inbox_count = gmail |> read_list("recent_inbox") |> length()
    sent_count = gmail |> read_list("recent_sent") |> length()
    calendar_count = calendar |> read_list("upcoming_events") |> length()

    [
      body,
      unless contains_heading?(body, "Context Used") do
        fallback_section(
          "Context Used",
          fallback_checked_lines(open_todos, inbox_count, sent_count, calendar_count)
        )
      end,
      unless contains_heading?(body, "Unknowns") do
        fallback_section(
          "Unknowns",
          fallback_unknown_lines(inbox_count, sent_count, calendar_count)
        )
      end,
      unless String.contains?(String.downcase(body), "today's move:") do
        fallback_commitment_move(open_todos, inbox_count, sent_count, calendar_count)
      end
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp empty_commitment_fallback_summary(tracker_input) when is_map(tracker_input) do
    open_todos = tracker_input |> read_map("open_work") |> read_list("todos")
    gmail = read_map(tracker_input, "gmail")
    calendar = read_map(tracker_input, "calendar")

    fallback_commitment_summary(
      open_todos,
      gmail |> read_list("recent_inbox") |> length(),
      gmail |> read_list("recent_sent") |> length(),
      calendar |> read_list("upcoming_events") |> length()
    )
  end

  defp empty_commitment_fallback_summary(_tracker_input) do
    fallback_commitment_summary([], 0, 0, 0)
  end

  defp overconfident_empty_summary?(summary) when is_binary(summary) do
    normalized = summary |> String.downcase() |> String.trim()

    normalized == "" or
      String.contains?(normalized, "no new commitments were found") or
      String.contains?(normalized, "no new commitments found") or
      String.contains?(normalized, "no new commitments are ready to save") or
      String.contains?(normalized, "nothing new was found") or
      String.contains?(normalized, "nothing is owed") or
      String.contains?(normalized, "all clear")
  end

  defp overconfident_empty_summary?(_summary), do: true

  defp contains_heading?(body, heading) when is_binary(body) and is_binary(heading) do
    Regex.match?(~r/(^|\n)\s{0,3}#{Regex.escape(heading)}\s*:?(\n|$)/i, body) or
      Regex.match?(~r/(^|\n)\s{0,3}#{Regex.escape("## " <> heading)}\s*(\n|$)/i, body)
  end

  defp contains_heading?(_body, _heading), do: false

  defp fallback_commitment_report(tracker_input) when is_map(tracker_input) do
    open_todos = tracker_input |> read_map("open_work") |> read_list("todos")
    gmail = read_map(tracker_input, "gmail")
    calendar = read_map(tracker_input, "calendar")
    inbox_count = gmail |> read_list("recent_inbox") |> length()
    sent_count = gmail |> read_list("recent_sent") |> length()
    calendar_count = calendar |> read_list("upcoming_events") |> length()

    body =
      [
        fallback_section(
          "Needs Your Attention",
          fallback_open_work_lines(open_todos, tracker_input)
        ),
        fallback_section(
          "Context Used",
          fallback_checked_lines(open_todos, inbox_count, sent_count, calendar_count)
        ),
        fallback_section(
          "Unknowns",
          fallback_unknown_lines(inbox_count, sent_count, calendar_count)
        ),
        fallback_commitment_move(open_todos, inbox_count, sent_count, calendar_count)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    %{
      "title" => fallback_commitment_title(open_todos),
      "summary" =>
        fallback_commitment_summary(open_todos, inbox_count, sent_count, calendar_count),
      "body" => body,
      "todos" => [],
      "linked_todo_ids" => fallback_existing_todo_ids(open_todos)
    }
  end

  defp fallback_commitment_report(_tracker_input) do
    fallback_commitment_report(%{})
  end

  defp fallback_commitment_title(open_todos) do
    if length(open_todos) > 0 do
      "Open work review: check existing work"
    else
      "Open work review: fresh context refresh needed"
    end
  end

  defp fallback_commitment_summary(open_todos, inbox_count, sent_count, calendar_count) do
    open_count = length(open_todos)
    checked_count = inbox_count + sent_count + calendar_count

    cond do
      open_count > 0 ->
        "Start with #{count_phrase(open_count, "existing open item", "existing open items")} already in open work; this pass did not add a new commitment."

      checked_count > 0 ->
        "Available context did not show a new commitment clearly enough to save; keep existing open work as the source of truth."

      true ->
        "Maraithon did not complete a fresh context refresh for this review, so it did not clear or create open work."
    end
  end

  defp fallback_open_work_lines(open_todos, tracker_input) do
    case Enum.take(open_todos, 5) do
      [] ->
        [
          "- No open commitment is already saved. Treat this review as incomplete until a fresh context refresh covers the relevant thread."
        ]

      todos ->
        Enum.map(todos, &fallback_todo_line(&1, tracker_input))
    end
  end

  defp fallback_todo_line(todo, tracker_input) when is_map(todo) do
    title = read_string(todo, "title", "Open commitment")

    next_action =
      read_string(
        todo,
        "next_action",
        read_string(todo, "summary", "Open the source thread and decide the next action.")
      )

    due = todo |> read_any("due_at") |> fallback_due_label(tracker_input)
    source = read_string(todo, "source", nil)
    source_account = read_string(todo, "source_account_label", nil)

    [
      "- ",
      title,
      fallback_due_sentence(due),
      " Next: ",
      next_action,
      fallback_source_phrase(source, source_account)
    ]
    |> Enum.join("")
  end

  defp fallback_todo_line(_todo, _tracker_input) do
    "- Open commitment. Next: open the source thread and decide the next action."
  end

  defp fallback_due_sentence(nil), do: "."
  defp fallback_due_sentence(""), do: "."
  defp fallback_due_sentence(due), do: ". Due #{due}."

  defp fallback_due_label(%DateTime{} = value, tracker_input) do
    offset = tracker_input_timezone_offset_hours(tracker_input)
    label = tracker_input_timezone_label(tracker_input, offset)

    value
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp fallback_due_label(%NaiveDateTime{} = value, _tracker_input) do
    Calendar.strftime(value, "%b %-d, %Y at %-I:%M %p")
  end

  defp fallback_due_label(%Date{} = value, _tracker_input),
    do: Calendar.strftime(value, "%b %-d, %Y")

  defp fallback_due_label(value, tracker_input) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        fallback_due_label(datetime, tracker_input)

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        fallback_due_label(date, tracker_input)

      true ->
        value
    end
  end

  defp fallback_due_label(_value, _tracker_input), do: nil

  defp tracker_input_timezone_offset_hours(tracker_input) when is_map(tracker_input) do
    case read_any(tracker_input, "timezone_offset_hours") do
      value when is_integer(value) -> Timezones.normalize_offset(value)
      value when is_float(value) -> value |> trunc() |> Timezones.normalize_offset()
      value when is_binary(value) -> Timezones.normalize_offset(value)
      _ -> @default_timezone_offset_hours
    end
  end

  defp tracker_input_timezone_offset_hours(_tracker_input), do: @default_timezone_offset_hours

  defp tracker_input_timezone_label(tracker_input, offset) when is_map(tracker_input) do
    case read_string(tracker_input, "timezone", nil) do
      nil ->
        Timezones.label(nil, offset)

      value ->
        case Timezones.normalize(value) do
          normalized when is_binary(normalized) -> Timezones.label(normalized, offset)
          _ -> value
        end
    end
  end

  defp tracker_input_timezone_label(_tracker_input, offset), do: Timezones.label(nil, offset)

  defp fallback_source_phrase(source, account) do
    label = fallback_source_label(source)
    account = fallback_account_label(account, label)

    cond do
      blank?(label) and blank?(account) -> "."
      blank?(label) -> " From #{account}."
      blank?(account) -> " From #{label}."
      true -> " From #{label} (#{account})."
    end
  end

  defp fallback_source_label(nil), do: nil
  defp fallback_source_label(""), do: nil
  defp fallback_source_label(source), do: SourceLabels.label(source, fallback: nil)

  defp fallback_account_label(account, source_label) when is_binary(account) do
    account = String.trim(account)

    cond do
      account == "" -> nil
      String.downcase(account) == String.downcase(to_string(source_label || "")) -> nil
      true -> account
    end
  end

  defp fallback_account_label(_account, _source_label), do: nil

  defp fallback_checked_lines(open_todos, inbox_count, sent_count, calendar_count) do
    [
      "- Gmail context: #{count_phrase(inbox_count, "recent inbox message", "recent inbox messages")} and #{count_phrase(sent_count, "recent sent message", "recent sent messages")}.",
      "- Calendar context: #{count_phrase(calendar_count, "upcoming event", "upcoming events")}.",
      "- Existing open work: #{count_phrase(length(open_todos), "open item", "open items")}."
    ]
  end

  defp fallback_unknown_lines(inbox_count, sent_count, calendar_count) do
    checked_count = inbox_count + sent_count + calendar_count

    [
      "- No new commitments were saved because the available context did not clearly show a new promise.",
      if(checked_count > 0,
        do: "- Anything outside Gmail, Calendar, and existing open work still needs review.",
        else: "- Gmail, Calendar, and source threads were unavailable for this review."
      )
    ]
  end

  defp fallback_commitment_move(open_todos, inbox_count, sent_count, calendar_count) do
    cond do
      length(open_todos) > 0 ->
        "Today's move: clear or explicitly keep the first open item before inbox triage."

      inbox_count + sent_count > 0 ->
        "Today's move: inspect the highest-stakes recent thread and decide whether you owe a reply."

      calendar_count > 0 ->
        "Today's move: review the next meeting for promises you owe before the day gets busy."

      true ->
        "Today's move: run a fresh context refresh before clearing open work for the day."
    end
  end

  defp fallback_section(_heading, []), do: nil

  defp fallback_section(heading, lines) when is_list(lines) do
    "## #{heading}\n" <> Enum.join(lines, "\n")
  end

  defp count_phrase(1, singular, _plural), do: "1 #{singular}"
  defp count_phrase(count, _singular, plural), do: "#{count} #{plural}"

  defp fallback_existing_todo_ids(open_todos) when is_list(open_todos) do
    open_todos
    |> Enum.map(&read_string(&1, "id", nil))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp fallback_existing_todo_ids(_open_todos), do: []

  defp persist_model_todos(_user_id, %{"linked_todo_ids" => linked_todo_ids}, _tracker_input) do
    linked_todo_ids =
      linked_todo_ids
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    if linked_todo_ids == [] do
      {:ok, :no_todos}
    else
      {:ok, %{todos: [], linked_todo_ids: linked_todo_ids, skipped_count: 0, usage: %{}}}
    end
  end

  defp persist_model_todos(_user_id, %{"todos" => []}, _tracker_input), do: {:ok, :no_todos}
  defp persist_model_todos(nil, _report, _tracker_input), do: {:ok, :no_todos}

  defp persist_model_todos(user_id, %{"todos" => todos}, tracker_input)
       when is_binary(user_id) and is_list(todos) do
    candidates =
      todos
      |> Enum.filter(&is_map/1)
      |> Enum.map(&commitment_todo_candidate(&1, tracker_input))

    case candidates do
      [] ->
        {:ok, :no_todos}

      candidates ->
        case read_string(tracker_input, "todo_target_brief_dedupe_key", nil) do
          nil ->
            ingest_todos_with_fallback(user_id, candidates,
              source: "chief_of_staff_commitment_tracker",
              now: read_string(tracker_input, "generated_at", nil)
            )

          brief_dedupe_key ->
            Maraithon.Todos.DeferredIngestion.enqueue(user_id, candidates,
              source: "chief_of_staff_commitment_tracker",
              brief_dedupe_key: brief_dedupe_key
            )
        end
    end
  end

  defp persist_model_todos(_user_id, _report, _tracker_input), do: {:ok, :no_todos}

  defp attach_model_todos_to_brief(brief_record, {:ok, %{pending: true}}),
    do: {brief_record, [], nil}

  defp attach_model_todos_to_brief(brief_record, {:ok, result}) when is_map(result) do
    linked_todo_ids =
      result
      |> Map.get(:linked_todo_ids, [])
      |> List.wrap()

    todos = Map.get(result, :todos, [])
    todos_or_ids = todos ++ linked_todo_ids

    case Briefs.attach_linked_todos(brief_record, todos_or_ids) do
      {:ok, updated_brief} ->
        {updated_brief, todos_or_ids |> Enum.map(&todo_id/1) |> Enum.reject(&blank?/1), nil}

      {:error, reason} ->
        {brief_record, [], Maraithon.Redaction.error_summary(reason)}
    end
  end

  defp attach_model_todos_to_brief(brief_record, _todo_result), do: {brief_record, [], nil}

  defp todo_id(%{id: id}) when is_binary(id), do: id
  defp todo_id(%{"id" => id}) when is_binary(id), do: id
  defp todo_id(id) when is_binary(id), do: id
  defp todo_id(_todo), do: nil

  defp ingest_todos_with_fallback(user_id, candidates, opts) do
    case OpenLoops.ingest_todos(user_id, candidates, opts) do
      {:error, reason} ->
        fallback_persist_todos(user_id, candidates, reason)

      result ->
        result
    end
  end

  defp fallback_persist_todos(user_id, candidates, reason) do
    Logger.warning(
      "commitment_tracker todo intelligence failed; using direct checked upsert",
      reason: Maraithon.Redaction.error_summary(reason),
      candidate_count: length(candidates)
    )

    {allowed_candidates, skipped_candidates} =
      Maraithon.Todos.SignalGate.partition_candidates(candidates)

    case Todos.upsert_many(user_id, allowed_candidates, model_selected?: true) do
      {:ok, todos} ->
        {:ok,
         %{
           todos: todos,
           decisions:
             direct_upsert_decisions(todos) ++ signal_gate_skip_decisions(skipped_candidates),
           skipped_count: length(skipped_candidates),
           usage: %{},
           fallback_reason: Maraithon.Redaction.error_summary(reason)
         }}

      {:error, direct_reason} ->
        {:error, {:todo_ingest_failed, reason, direct_reason}}
    end
  end

  defp direct_upsert_decisions(todos) do
    todos
    |> Enum.with_index()
    |> Enum.map(fn {todo, index} ->
      %{persisted_todo_id: todo.id, candidate_index: index, mode: "direct_upsert"}
    end)
  end

  defp signal_gate_skip_decisions(skipped_candidates) do
    skipped_candidates
    |> Enum.with_index()
    |> Enum.map(fn {%{reason: reason}, index} ->
      %{candidate_index: index, mode: "signal_gate_skip", reasoning: reason}
    end)
  end

  defp commitment_todo_candidate(todo, tracker_input) when is_map(todo) do
    metadata =
      todo
      |> read_map("metadata")
      |> Map.merge(%{
        "origin_skill_id" => id(),
        "origin_cadence" => "commitment_tracker",
        "tracker_date" => read_string(tracker_input, "date", nil),
        "tracker_generated_at" => read_string(tracker_input, "generated_at", nil)
      })
      |> compact_map()

    todo
    |> stringify_top_level_keys()
    |> Map.put("metadata", metadata)
    |> Map.put_new("source", "chief_of_staff_commitment_tracker")
    |> Map.put_new("kind", "general")
    |> Map.put_new("source_occurred_at", read_string(tracker_input, "generated_at", nil))
    |> attach_gmail_provenance(tracker_input)
    |> enforce_vague_self_commitment_snooze_floor(tracker_input)
  end

  defp attach_gmail_provenance(attrs, tracker_input)
       when is_map(attrs) and is_map(tracker_input) do
    if read_string(attrs, "source", nil) == "gmail" do
      source_item_id = read_string(attrs, "source_item_id", nil)

      message =
        if is_binary(source_item_id) do
          tracker_input
          |> read_map("gmail")
          |> then(fn gmail ->
            read_list(gmail, "recent_inbox") ++ read_list(gmail, "recent_sent")
          end)
          |> Enum.find(fn item ->
            source_item_id in [
              read_string(item, "message_id", nil),
              read_string(item, "thread_id", nil),
              read_string(item, "source_item_id", nil)
            ]
          end)
        end

      attach_gmail_message_provenance(attrs, message)
    else
      attrs
    end
  end

  defp attach_gmail_provenance(attrs, _tracker_input), do: attrs

  defp attach_gmail_message_provenance(attrs, message) when is_map(message) do
    message_id = message |> read_string("message_id", nil) |> Gmail.normalize_id()
    thread_id = message |> read_string("thread_id", nil) |> Gmail.normalize_id()
    provider = read_string(message, "google_provider", nil)
    account = read_string(message, "account", nil)

    metadata =
      attrs
      |> read_map("metadata")
      |> maybe_put("gmail_message_id", message_id)
      |> maybe_put("gmail_thread_id", thread_id)
      |> maybe_put("google_provider", provider)
      |> maybe_put("google_account_email", account)

    attrs
    |> Map.put("metadata", metadata)
    |> maybe_put("source_item_id", thread_id || message_id)
    |> maybe_put("source_account_label", account)
  end

  defp attach_gmail_message_provenance(attrs, _message), do: attrs

  defp enforce_vague_self_commitment_snooze_floor(attrs, tracker_input) when is_map(attrs) do
    metadata = read_map(attrs, "metadata")

    if read_string(attrs, "status", nil) == "snoozed" and
         explicit_self_commitment?(metadata) and
         vague_next_day_commitment?(attrs, metadata) do
      offset_hours = tracker_input_timezone_offset_hours(tracker_input)

      target =
        read_datetime(attrs, "snoozed_until") ||
          read_datetime(attrs, "due_at") ||
          implied_next_day_floor(tracker_input, offset_hours)

      case target do
        %DateTime{} = target ->
          floor = local_day_floor(target, offset_hours, @vague_self_commitment_followup_hour)

          if DateTime.compare(target, floor) == :lt do
            attrs
            |> Map.put("snoozed_until", DateTime.to_iso8601(floor))
            |> maybe_floor_due_at(floor)
            |> Map.put(
              "metadata",
              metadata
              |> Map.put_new("snooze_timing", "late_afternoon_local")
              |> Map.put("snooze_timing_enforced", true)
            )
          else
            attrs
          end

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  defp enforce_vague_self_commitment_snooze_floor(attrs, _tracker_input), do: attrs

  defp explicit_self_commitment?(metadata) when is_map(metadata) do
    truthy_value?(read_any(metadata, "explicit_user_commitment")) or
      read_string(metadata, "commitment_direction", nil) == "i_owe"
  end

  defp explicit_self_commitment?(_metadata), do: false

  defp truthy_value?(value) when value in [true, 1], do: true

  defp truthy_value?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["true", "yes", "1"]))
  end

  defp truthy_value?(_value), do: false

  defp vague_next_day_commitment?(attrs, metadata) do
    text =
      [
        read_string(metadata, "quote", nil),
        read_string(metadata, "source_evidence", nil),
        read_string(metadata, "source_excerpt", nil),
        read_string(attrs, "title", nil),
        read_string(attrs, "summary", nil),
        read_string(attrs, "next_action", nil)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, "tomorrow") and not explicit_time_text?(text)
  end

  defp explicit_time_text?(text) when is_binary(text) do
    Regex.match?(@explicit_clock_time_pattern, text) or
      Enum.any?(@explicit_time_words, &String.contains?(text, &1))
  end

  defp explicit_time_text?(_text), do: false

  defp implied_next_day_floor(tracker_input, offset_hours) do
    case read_datetime(tracker_input, "generated_at") do
      %DateTime{} = generated_at ->
        generated_at
        |> DateTime.add(offset_hours, :hour)
        |> DateTime.add(1, :day)
        |> local_day_floor(0, @vague_self_commitment_followup_hour)
        |> DateTime.add(-offset_hours, :hour)

      _ ->
        nil
    end
  end

  defp local_day_floor(%DateTime{} = datetime, offset_hours, hour) do
    local_date =
      datetime
      |> DateTime.add(offset_hours, :hour)
      |> DateTime.to_date()

    local_floor = DateTime.new!(local_date, Time.new!(hour, 0, 0), "Etc/UTC")
    DateTime.add(local_floor, -offset_hours, :hour)
  end

  defp maybe_floor_due_at(attrs, %DateTime{} = floor) do
    case read_datetime(attrs, "due_at") do
      %DateTime{} = due_at ->
        if DateTime.compare(due_at, floor) == :lt do
          Map.put(attrs, "due_at", DateTime.to_iso8601(floor))
        else
          attrs
        end

      _ ->
        Map.put(attrs, "due_at", DateTime.to_iso8601(floor))
    end
  end

  defp append_todo_write_summary(report, {:ok, :no_todos}), do: report

  defp append_todo_write_summary(report, {:ok, result}) when is_map(result) do
    todos = Map.get(result, :todos, [])
    skipped_count = Map.get(result, :skipped_count, 0)

    lines =
      todos
      |> Enum.take(10)
      |> Enum.map(fn %Todo{} = todo ->
        "- #{todo_title(todo)}"
      end)

    additional_count = max(length(todos) - length(lines), 0)

    summary_lines =
      []
      |> maybe_append(lines != [], ["", "Added to open work:"] ++ lines)
      |> maybe_append(additional_count > 0, [saved_more_line(additional_count)])
      |> maybe_append(skipped_count > 0, [already_covered_line(skipped_count)])

    if summary_lines == [] do
      report
    else
      append_report_body(report, Enum.join(summary_lines, "\n"))
    end
  end

  defp append_todo_write_summary(report, {:error, _reason}) do
    append_report_body(
      report,
      "\nReviewed follow-ups could not be saved as open work. Review the checked items above before acting."
    )
  end

  defp todo_title(%Todo{title: title}) when is_binary(title) and title != "", do: title
  defp todo_title(%Todo{}), do: "Open commitment"

  defp saved_more_line(1), do: "- 1 more work item saved."
  defp saved_more_line(count), do: "- #{count} more work items saved."

  defp already_covered_line(1), do: "- Already covered in open work: 1 item."

  defp already_covered_line(count),
    do: "- Already covered in open work: #{count} items."

  defp append_report_body(report, addition) do
    body = read_string(report, "body", "")

    Map.put(report, "body", String.trim(body <> "\n" <> addition))
  end

  defp cap_report_todos(report) when is_map(report) do
    Map.update(report, "todos", [], fn
      todos when is_list(todos) -> Enum.take(todos, 12)
      _other -> []
    end)
  end

  defp cap_report_todos(_report), do: %{"todos" => []}

  defp report_event_payload(report, generation_mode, response, error_message) do
    %{
      generation_mode: generation_mode,
      generation_error: is_binary(error_message) and String.trim(error_message) != "",
      llm_finish_reason: llm_finish_reason(response),
      proposed_todo_count: report |> read_list("todos") |> length(),
      pending_reply_count: report |> read_list("pending_replies") |> length(),
      already_tracked_count: report |> read_list("already_tracked") |> length(),
      missing_source_count: report |> read_list("missing_sources") |> length()
    }
  end

  defp todo_event_payload({:ok, :no_todos}) do
    %{todo_count: 0, todo_skipped_count: 0}
  end

  defp todo_event_payload({:ok, result}) when is_map(result) do
    %{
      todo_count: length(Map.get(result, :todos, [])),
      todo_queued_count: Map.get(result, :queued_count, 0),
      todo_skipped_count: Map.get(result, :skipped_count, 0)
    }
  end

  defp todo_event_payload({:error, reason}) do
    %{
      todo_count: 0,
      todo_skipped_count: 0,
      todo_error: Maraithon.Redaction.error_summary(reason)
    }
  end

  defp summarize_todo_result({:ok, :no_todos}) do
    %{"todo_count" => 0, "skipped_count" => 0}
  end

  defp summarize_todo_result({:ok, result}) when is_map(result) do
    %{
      "todo_count" => length(Map.get(result, :todos, [])),
      "queued_count" => Map.get(result, :queued_count, 0),
      "status" => if(Map.get(result, :pending, false), do: "pending", else: "completed"),
      "skipped_count" => Map.get(result, :skipped_count, 0),
      "decisions" => Map.get(result, :decisions, [])
    }
  end

  defp summarize_todo_result({:error, reason}) do
    %{
      "todo_count" => 0,
      "skipped_count" => 0,
      "error" => Maraithon.Redaction.error_summary(reason)
    }
  end

  defp gmail_message_for_prompt(message) when is_map(message) do
    body = gmail_body_for_prompt(message)
    body_available = body != ""

    %{
      "message_id" => read_string(message, "message_id", nil),
      "thread_id" => read_string(message, "thread_id", nil),
      "source_item_id" =>
        read_string(message, "thread_id", read_string(message, "message_id", nil)),
      "google_provider" => read_string(message, "google_provider", nil),
      "account" =>
        read_string(message, "account", read_string(message, "google_account_email", nil)),
      "from" => read_string(message, "from", nil),
      "to" => read_string(message, "to", nil),
      "subject" => read_string(message, "subject", "(no subject)"),
      "date" =>
        prompt_time(read_any(message, "internal_date")) || read_string(message, "date", nil),
      "labels" => read_list(message, "labels"),
      "snippet" => truncate(read_string(message, "snippet", ""), 240),
      "body_available" => body_available,
      "body_status" =>
        read_string(message, "body_status", if(body_available, do: "available", else: "missing")),
      "body" => truncate(body, 6_000)
    }
  end

  defp gmail_body_for_prompt(message) when is_map(message) do
    [
      read_string(message, "body_text", nil),
      read_string(message, "text_body", nil),
      read_string(message, "html_body", nil)
    ]
    |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp calendar_event_for_prompt(event) when is_map(event) do
    %{
      "event_id" => read_string(event, "event_id", nil),
      "summary" => read_string(event, "summary", "Untitled event"),
      "start" => prompt_time(read_any(event, "start")),
      "end" => prompt_time(read_any(event, "end")),
      "location" => read_string(event, "location", nil),
      "attendees" => read_list(event, "attendees") |> Enum.take(16),
      "organizer" => read_string(event, "organizer", nil),
      "html_link" => read_string(event, "html_link", nil),
      "account" => read_string(event, "account", read_string(event, "google_account_email", nil))
    }
  end

  defp slack_message_for_prompt(message) when is_map(message) do
    ts = read_string(message, "ts", nil)
    channel_id = read_string(message, "channel_id", nil)

    %{
      "team_id" => read_string(message, "team_id", nil),
      "team_name" => read_string(message, "team_name", nil),
      "channel_id" => channel_id,
      "channel_name" => read_string(message, "channel_name", nil),
      "conversation_kind" => read_string(message, "conversation_kind", nil),
      "ts" => ts,
      "thread_ts" => read_string(message, "thread_ts", nil),
      "date" => prompt_time(slack_message_datetime(message)),
      "user" => read_string(message, "user", nil),
      "user_display_name" => read_string(message, "user_display_name", nil),
      "mentioned_users" => read_list(message, "mentioned_users"),
      "bot_id" => read_string(message, "bot_id", nil),
      "text" =>
        truncate(
          read_string(message, "text_resolved", read_string(message, "text", "")),
          2_000
        ),
      "raw_text" => truncate(read_string(message, "text", ""), 2_000),
      "reply_count" => read_any(message, "reply_count"),
      "permalink" => read_string(message, "permalink", nil),
      "source_item_id" => slack_source_item_id(channel_id, ts)
    }
  end

  defp imessage_sender_handles(messages, chats) when is_list(messages) and is_list(chats) do
    message_handles = Enum.map(messages, &read_string(&1, "sender_handle", nil))
    chat_handles = Enum.map(chats, &read_string(&1, "latest_sender", nil))

    (message_handles ++ chat_handles)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp imessage_sender_handles(_messages, _chats), do: []

  defp imessage_message_for_prompt(message, people_by_handle)
       when is_map(message) and is_map(people_by_handle) do
    message
    |> imessage_message_for_prompt()
    |> add_resolved_imessage_sender(
      Map.get(people_by_handle, read_string(message, "sender_handle", nil))
    )
  end

  defp imessage_message_for_prompt(message, _people_by_handle),
    do: imessage_message_for_prompt(message)

  defp imessage_message_for_prompt(message) when is_map(message) do
    %{
      "message_id" => read_string(message, "message_id", read_string(message, "guid", nil)),
      "source" => read_string(message, "source", "imessage"),
      "chat_key" => read_string(message, "chat_key", nil),
      "chat_display_name" => read_string(message, "chat_display_name", nil),
      "sender_handle" => read_string(message, "sender_handle", nil),
      "sender_display_name" => read_string(message, "sender_display_name", nil),
      "sender_person_id" => read_string(message, "sender_person_id", nil),
      "sender_relationship" => read_string(message, "sender_relationship", nil),
      "is_from_me" => read_any(message, "is_from_me"),
      "sent_at" => prompt_time(read_any(message, "sent_at")),
      "text" => truncate(read_string(message, "text", ""), 2_000),
      "has_attachments" => read_any(message, "has_attachments"),
      "source_item_id" =>
        read_string(message, "source_item_id", read_string(message, "guid", nil)),
      "source_occurred_at" => read_string(message, "source_occurred_at", nil)
    }
  end

  defp imessage_chat_for_prompt(chat, people_by_handle)
       when is_map(chat) and is_map(people_by_handle) do
    chat
    |> imessage_chat_for_prompt()
    |> add_resolved_imessage_latest_sender(
      Map.get(people_by_handle, read_string(chat, "latest_sender", nil))
    )
  end

  defp imessage_chat_for_prompt(chat, _people_by_handle), do: imessage_chat_for_prompt(chat)

  defp imessage_chat_for_prompt(chat) when is_map(chat) do
    %{
      "chat_key" => read_string(chat, "chat_key", nil),
      "chat_display_name" => read_string(chat, "chat_display_name", nil),
      "message_count_last_7d" => read_any(chat, "message_count_last_7d"),
      "latest_snippet" => truncate(read_string(chat, "latest_snippet", ""), 800),
      "latest_sender" => read_string(chat, "latest_sender", nil),
      "latest_sender_display_name" => read_string(chat, "latest_sender_display_name", nil),
      "latest_sender_person_id" => read_string(chat, "latest_sender_person_id", nil),
      "latest_is_from_me" => read_any(chat, "latest_is_from_me"),
      "latest_sent_at" => read_string(chat, "latest_sent_at", nil)
    }
  end

  defp add_resolved_imessage_sender(message, %Maraithon.Crm.Person{} = person) do
    message
    |> Map.put("sender_display_name", person.display_name)
    |> Map.put("sender_person_id", person.id)
    |> maybe_put("sender_relationship", person.relationship)
  end

  defp add_resolved_imessage_sender(message, _person), do: message

  defp add_resolved_imessage_latest_sender(chat, %Maraithon.Crm.Person{} = person) do
    chat
    |> Map.put("latest_sender_display_name", person.display_name)
    |> Map.put("latest_sender_person_id", person.id)
  end

  defp add_resolved_imessage_latest_sender(chat, _person), do: chat

  defp voice_memo_for_prompt(memo) when is_map(memo) do
    %{
      "memo_id" => read_string(memo, "memo_id", read_string(memo, "guid", nil)),
      "title" => read_string(memo, "title", "(untitled voice memo)"),
      "snippet" => truncate(read_string(memo, "snippet", ""), 800),
      "transcript" => truncate(read_string(memo, "transcript", ""), 3_000),
      "duration_seconds" => read_any(memo, "duration_seconds"),
      "created_at" => read_string(memo, "created_at", nil),
      "has_transcript" => read_any(memo, "has_transcript"),
      "source_item_id" => read_string(memo, "source_item_id", read_string(memo, "guid", nil)),
      "source_occurred_at" => read_string(memo, "source_occurred_at", nil)
    }
  end

  defp note_for_prompt(note) when is_map(note) do
    %{
      "note_id" => read_string(note, "note_id", read_string(note, "guid", nil)),
      "title" => read_string(note, "title", "(untitled note)"),
      "snippet" => truncate(read_string(note, "snippet", ""), 800),
      "body" => truncate(read_string(note, "body", ""), 3_000),
      "folder" => read_string(note, "folder", nil),
      "is_pinned" => read_any(note, "is_pinned"),
      "modified_at" => read_string(note, "modified_at", nil),
      "source_item_id" => read_string(note, "source_item_id", read_string(note, "guid", nil)),
      "source_occurred_at" => read_string(note, "source_occurred_at", nil)
    }
  end

  defp reminder_for_prompt(reminder) when is_map(reminder) do
    %{
      "reminder_id" => read_string(reminder, "reminder_id", read_string(reminder, "guid", nil)),
      "title" => read_string(reminder, "title", "(untitled reminder)"),
      "notes" => truncate(read_string(reminder, "notes", ""), 1_500),
      "list_name" => read_string(reminder, "list_name", nil),
      "priority" => read_any(reminder, "priority"),
      "due_at" => read_string(reminder, "due_at", nil),
      "has_alarm" => read_any(reminder, "has_alarm"),
      "url_attachment" => read_string(reminder, "url_attachment", nil),
      "source_item_id" =>
        read_string(reminder, "source_item_id", read_string(reminder, "guid", nil)),
      "source_occurred_at" => read_string(reminder, "source_occurred_at", nil)
    }
  end

  defp file_for_prompt(file) when is_map(file) do
    %{
      "file_id" => read_string(file, "file_id", read_string(file, "guid", nil)),
      "filename" => read_string(file, "filename", nil),
      "path" => read_string(file, "path", nil),
      "extension" => read_string(file, "extension", nil),
      "mime_type" => read_string(file, "mime_type", nil),
      "text_content" => truncate(read_string(file, "text_content", ""), 2_000),
      "text_truncated" => read_any(file, "text_truncated"),
      "modified_at" => read_string(file, "modified_at", nil),
      "source_item_id" => read_string(file, "source_item_id", read_string(file, "guid", nil)),
      "source_occurred_at" => read_string(file, "source_occurred_at", nil)
    }
  end

  defp browser_visit_for_prompt(visit) when is_map(visit) do
    %{
      "visit_id" => read_string(visit, "visit_id", read_string(visit, "guid", nil)),
      "browser" => read_string(visit, "browser", nil),
      "title" => truncate(read_string(visit, "title", ""), 400),
      "url" => read_string(visit, "url", nil),
      "host" => read_string(visit, "host", nil),
      "last_visited_at" => read_string(visit, "last_visited_at", nil),
      "visit_count" => read_any(visit, "visit_count"),
      "source_item_id" => read_string(visit, "source_item_id", read_string(visit, "guid", nil)),
      "source_occurred_at" => read_string(visit, "source_occurred_at", nil)
    }
  end

  defp todo_for_prompt(todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "kind" => todo.kind,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "due_at" => prompt_time(todo.due_at),
      "notes" => todo.notes,
      "action_plan" => todo.action_plan,
      "owner_user_id" => todo.owner_user_id,
      "owner_label" => todo.owner_label,
      "priority" => todo.priority,
      "source_account_label" => todo.source_account_label,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => prompt_time(todo.source_occurred_at),
      "metadata" => summarize_todo_metadata(todo.metadata)
    }
  end

  defp summarize_todo_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [
      "thread_id",
      "google_account_email",
      "from",
      "to",
      "subject",
      "account_email",
      "source_ref",
      "commitment_direction",
      "origin_skill_id",
      "person",
      "people"
    ])
  end

  defp summarize_todo_metadata(_metadata), do: %{}

  defp source_access(source_bundle) do
    freshness = SourceBundle.freshness(source_bundle)

    %{
      "gmail" => source_status(freshness, "gmail"),
      "google_calendar" => source_status(freshness, "calendar"),
      "local_calendar" => source_status(freshness, "calendar_local"),
      "slack" => source_status(freshness, "slack"),
      "imessage" => source_status(freshness, "imessage"),
      "voice_memos" => source_status(freshness, "voice_memos"),
      "notes" => source_status(freshness, "notes"),
      "reminders" => source_status(freshness, "reminders"),
      "files" => source_status(freshness, "files"),
      "browser_history" => source_status(freshness, "browser_history"),
      "whatsapp" => %{
        "status" => "unavailable",
        "reason" => "whatsapp_connector_not_available_in_runtime"
      },
      "omnifocus" => %{
        "status" => "unavailable",
        "reason" => "omnifocus_write_tool_not_available_in_runtime"
      },
      "google_calendar_write" => %{
        "status" => "unavailable",
        "reason" => "calendar_create_delete_tools_not_available_in_runtime"
      }
    }
  end

  defp source_status(freshness, source) when is_map(freshness) do
    case Map.get(freshness, source) do
      value when is_map(value) -> value
      _ -> %{"status" => "unavailable", "reason" => "#{source}_not_fetched"}
    end
  end

  defp compact_tracker_input_for_metadata(input) do
    %{
      "date" => read_string(input, "date", nil),
      "generated_at" => read_string(input, "generated_at", nil),
      "timezone" => read_string(input, "timezone", nil),
      "timezone_offset_hours" => tracker_input_timezone_offset_hours(input),
      "counts" => %{
        "gmail_recent_inbox" => length(get_in(input, ["gmail", "recent_inbox"]) || []),
        "gmail_recent_sent" => length(get_in(input, ["gmail", "recent_sent"]) || []),
        "calendar_upcoming_events" =>
          length(get_in(input, ["calendar", "upcoming_events"]) || []),
        "local_calendar_upcoming_events" =>
          length(get_in(input, ["local_calendar", "upcoming_events"]) || []),
        "slack_recent_messages" => length(get_in(input, ["slack", "recent_messages"]) || []),
        "slack_mentions" => length(get_in(input, ["slack", "mentions"]) || []),
        "imessage_recent_messages" =>
          length(get_in(input, ["imessage", "recent_messages"]) || []),
        "imessage_chats" => length(get_in(input, ["imessage", "chats"]) || []),
        "voice_memos" => length(get_in(input, ["voice_memos", "items"]) || []),
        "notes" => length(get_in(input, ["notes", "items"]) || []),
        "reminders_due_soon" => length(get_in(input, ["reminders", "due_soon"]) || []),
        "files_recent" => length(get_in(input, ["files", "recent"]) || []),
        "browser_history_recent" => length(get_in(input, ["browser_history", "recent"]) || []),
        "open_todos" => length(get_in(input, ["open_work", "todos"]) || []),
        "relationships" => length(get_in(input, ["relationships"]) || []),
        "deep_memory" => deep_memory_count(input)
      }
    }
  end

  defp deep_memory_count(input) do
    case Map.get(input, "deep_memory") || Map.get(input, :deep_memory) do
      %{count: count} when is_integer(count) -> count
      %{"count" => count} when is_integer(count) -> count
      _other -> 0
    end
  end

  defp recent_gmail_message?(message, lookback_start) when is_map(message) do
    case read_datetime(message, "internal_date") || read_datetime(message, "date") do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_gmail_message?(_message, _lookback_start), do: false

  defp gmail_message_sort_key(message) when is_map(message) do
    {
      datetime_sort_key(
        read_datetime(message, "internal_date") || read_datetime(message, "date"),
        0
      ),
      read_string(message, "thread_id", ""),
      read_string(message, "message_id", "")
    }
  end

  defp gmail_message_sort_key(_message), do: {0, "", ""}

  defp recent_slack_message?(message, lookback_start) when is_map(message) do
    case slack_message_datetime(message) do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_slack_message?(_message, _lookback_start), do: false

  defp slack_self_authored_search_message?(message) when is_map(message) do
    read_string(message, "search_mode", nil) == "self_authored"
  end

  defp slack_self_authored_search_message?(_message), do: false

  defp recent_local_message?(message, lookback_start) when is_map(message) do
    case local_message_datetime(message) do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_local_message?(_message, _lookback_start), do: false

  defp event_in_date_window?(event, start_date, end_date, offset_hours) when is_map(event) do
    case event |> read_any("start") |> local_date_from_value(offset_hours) do
      nil ->
        true

      event_date ->
        Date.compare(event_date, start_date) in [:eq, :gt] and
          Date.compare(event_date, end_date) in [:eq, :lt]
    end
  end

  defp event_in_date_window?(_event, _start_date, _end_date, _offset_hours), do: false

  defp event_sort_key(event) when is_map(event) do
    case read_any(event, "start") do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      %{"date" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> 0
    end
  end

  defp slack_message_sort_key(message) when is_map(message) do
    case slack_message_datetime(message) do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      _ -> 0
    end
  end

  defp slack_message_sort_key(_message), do: 0

  defp local_message_sort_key(message) when is_map(message),
    do: datetime_sort_key(local_message_datetime(message), 0)

  defp local_message_sort_key(_message), do: 0

  defp local_chat_sort_key(chat) when is_map(chat),
    do: datetime_sort_key(read_datetime(chat, "latest_sent_at"), 0)

  defp local_chat_sort_key(_chat), do: 0

  defp voice_memo_sort_key(memo) when is_map(memo),
    do:
      datetime_sort_key(
        read_datetime(memo, "created_at") || read_datetime(memo, "source_occurred_at"),
        0
      )

  defp voice_memo_sort_key(_memo), do: 0

  defp note_sort_key(note) when is_map(note),
    do:
      datetime_sort_key(
        read_datetime(note, "modified_at") ||
          read_datetime(note, "created_at") ||
          read_datetime(note, "source_occurred_at"),
        0
      )

  defp note_sort_key(_note), do: 0

  defp reminder_sort_key(reminder) when is_map(reminder),
    do: datetime_sort_key(read_datetime(reminder, "due_at"), 9_999_999_999_999_999)

  defp reminder_sort_key(_reminder), do: 9_999_999_999_999_999

  defp file_sort_key(file) when is_map(file),
    do:
      datetime_sort_key(
        read_datetime(file, "modified_at") ||
          read_datetime(file, "created_at") ||
          read_datetime(file, "source_occurred_at"),
        0
      )

  defp file_sort_key(_file), do: 0

  defp browser_visit_sort_key(visit) when is_map(visit),
    do:
      datetime_sort_key(
        read_datetime(visit, "last_visited_at") || read_datetime(visit, "source_occurred_at"),
        0
      )

  defp browser_visit_sort_key(_visit), do: 0

  defp datetime_sort_key(%DateTime{} = datetime, _default),
    do: DateTime.to_unix(datetime, :microsecond)

  defp datetime_sort_key(_datetime, default), do: default

  defp local_message_datetime(message) when is_map(message) do
    read_datetime(message, "sent_at") || read_datetime(message, "source_occurred_at")
  end

  defp local_message_datetime(_message), do: nil

  defp slack_message_datetime(message) when is_map(message) do
    read_datetime(message, "date") ||
      read_datetime(message, "created_at") ||
      slack_ts_datetime(read_string(message, "ts", nil))
  end

  defp slack_message_datetime(_message), do: nil

  defp slack_ts_datetime(ts) when is_binary(ts) do
    ts
    |> String.split(".", parts: 2)
    |> List.first()
    |> case do
      seconds when is_binary(seconds) ->
        case Integer.parse(seconds) do
          {value, ""} ->
            case DateTime.from_unix(value, :second) do
              {:ok, datetime} -> datetime
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp slack_ts_datetime(_ts), do: nil

  defp slack_source_item_id(channel_id, ts) when is_binary(channel_id) and is_binary(ts),
    do: "#{channel_id}:#{ts}"

  defp slack_source_item_id(_channel_id, _ts), do: nil

  defp llm_finish_reason(%{finish_reason: reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(%{"finish_reason" => reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(_response), do: nil

  defp due_now?(now, state) do
    local_now = DateTime.add(now, timezone_offset_hours_at(now, state), :hour)
    local_now.hour >= state.review_hour
  end

  defp next_review_occurrence(now, state) do
    offset_hours = timezone_offset_hours_at(now, state)
    local_now = DateTime.add(now, offset_hours, :hour)
    local_date = DateTime.to_date(local_now)

    scheduled_today =
      local_date
      |> DateTime.new!(Time.new!(state.review_hour, 0, 0), "Etc/UTC")

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        Date.add(local_date, 1)
        |> DateTime.new!(Time.new!(state.review_hour, 0, 0), "Etc/UTC")
      end

    DateTime.add(target_local, -local_timezone_offset_hours(target_local, state), :hour)
  end

  defp scheduled_trigger?(context) do
    cond do
      force_review_trigger?(context) ->
        true

      true ->
        case get_in(context, [:trigger, :type]) do
          nil -> is_nil(context[:event]) and is_nil(context[:last_message])
          :wakeup -> true
          _ -> false
        end
    end
  end

  defp admin_open_work_rebuild_context?(context) when is_map(context) do
    trigger = context[:trigger] || %{}

    payload =
      get_in(context, [:trigger, :payload]) || get_in(context, [:trigger, "payload"]) || %{}

    metadata = context[:last_message_metadata] || %{}

    source =
      read_string(trigger, "source", nil) ||
        read_string(payload, "source", nil) ||
        read_string(metadata, "source", nil)

    action =
      read_string(payload, "action", nil) ||
        read_string(metadata, "action", nil)

    source in ["admin_open_work_rebuild", "open_work_rebuild"] or
      action == "rebuild_open_work"
  end

  defp admin_open_work_rebuild_context?(_context), do: false

  defp force_review_trigger?(context) when is_map(context) do
    metadata = read_map(context[:last_message_metadata] || %{}, "metadata")

    metadata =
      if map_size(metadata) == 0, do: context[:last_message_metadata] || %{}, else: metadata

    trigger_payload =
      get_in(context, [:trigger, :payload]) || get_in(context, [:trigger, "payload"])

    action =
      read_string(metadata, "action", nil) ||
        read_string(trigger_payload || %{}, "action", nil) ||
        read_string(context, :action, nil)

    source =
      read_string(metadata, "source", nil) ||
        read_string(trigger_payload || %{}, "source", nil) ||
        read_string(context, :source, nil)

    message = normalize_string(context[:last_message])

    action in ["refresh_open_work", "rebuild_open_work"] or
      source in ["admin_open_work_rebuild", "open_work_rebuild"] or
      message in ["refresh_open_work", "rebuild_open_work"]
  end

  defp force_review_trigger?(_context), do: false

  defp commitment_dedupe_key(period_key, context) do
    if force_review_trigger?(context) do
      suffix =
        [
          context[:last_message_id],
          get_in(context, [:trigger, :job_id]),
          get_in(context, [:trigger, "job_id"]),
          context[:assistant_cycle_id],
          Ecto.UUID.generate()
        ]
        |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

      "commitment_tracker:#{period_key}:#{String.slice(suffix, 0, 48)}"
    else
      "commitment_tracker:#{period_key}"
    end
  end

  defp local_period_key(now, offset_hours) do
    now
    |> local_date(offset_hours)
    |> Date.to_iso8601()
  end

  defp local_date(%DateTime{} = now, offset_hours) do
    now
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_date()
  end

  defp local_date_from_value(%DateTime{} = value, offset_hours),
    do: local_date(value, offset_hours)

  defp local_date_from_value(%{"date" => date}, _offset_hours) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp local_date_from_value(value, offset_hours) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> local_date(datetime, offset_hours)
      _ -> nil
    end
  end

  defp local_date_from_value(_value, _offset_hours), do: nil

  defp timezone_offset_hours_at(%DateTime{} = datetime, state) do
    Timezones.offset_at(Map.get(state, :timezone), datetime, state.timezone_offset_hours)
  end

  defp local_timezone_offset_hours(%DateTime{} = local_datetime, state) do
    Timezones.offset_for_local(
      Map.get(state, :timezone),
      local_datetime,
      state.timezone_offset_hours
    )
  end

  defp timezone_label(state, %DateTime{} = datetime) do
    offset = timezone_offset_hours_at(datetime, state)
    Timezones.label(Map.get(state, :timezone), offset)
  end

  defp decode_json(content) when is_binary(content) do
    content
    |> json_decode_candidates()
    |> Enum.reduce_while({:error, :no_json_candidate}, fn candidate, _error ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp json_decode_candidates(content) do
    trimmed = String.trim(content)

    ([trimmed, strip_markdown_json_fence(trimmed)] ++
       fenced_json_candidates(trimmed) ++ [first_balanced_json_object(trimmed)])
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp strip_markdown_json_fence(content) when is_binary(content) do
    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, content, capture: :all_but_first) do
      [json] -> String.trim(json)
      _ -> content
    end
  end

  defp fenced_json_candidates(content) when is_binary(content) do
    ~r/```(?:json)?\s*(.*?)\s*```/s
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp first_balanced_json_object(content) when is_binary(content) do
    content
    |> String.graphemes()
    |> Enum.reduce_while({:searching, []}, &collect_first_json_object/2)
    |> case do
      {:done, chars} -> chars |> Enum.reverse() |> Enum.join() |> String.trim()
      _ -> nil
    end
  end

  defp collect_first_json_object("{", {:searching, _chars}),
    do: {:cont, {:collecting, 1, false, false, ["{"]}}

  defp collect_first_json_object(_char, {:searching, _chars}), do: {:cont, {:searching, []}}

  defp collect_first_json_object(char, {:collecting, depth, in_string?, escaped?, chars}) do
    chars = [char | chars]

    cond do
      in_string? and escaped? ->
        {:cont, {:collecting, depth, true, false, chars}}

      in_string? and char == "\\" ->
        {:cont, {:collecting, depth, true, true, chars}}

      in_string? and char == "\"" ->
        {:cont, {:collecting, depth, false, false, chars}}

      in_string? ->
        {:cont, {:collecting, depth, true, false, chars}}

      char == "\"" ->
        {:cont, {:collecting, depth, true, false, chars}}

      char == "{" ->
        {:cont, {:collecting, depth + 1, false, false, chars}}

      char == "}" ->
        depth = depth - 1

        if depth == 0 do
          {:halt, {:done, chars}}
        else
          {:cont, {:collecting, depth, false, false, chars}}
        end

      true ->
        {:cont, {:collecting, depth, false, false, chars}}
    end
  end

  defp prompt_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp prompt_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp prompt_time(%{"date" => date}) when is_binary(date), do: date
  defp prompt_time(value) when is_binary(value), do: value
  defp prompt_time(_value), do: nil

  defp read_any(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_existing_atom(key)))

  defp read_any(_map, _key), do: nil

  defp read_map(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_list(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp read_string(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_datetime(map, key) when is_map(map) do
    case read_any(map, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_datetime(_map, _key), do: nil

  defp integer_in_range(value, default, min, max) do
    value
    |> parse_integer(default)
    |> max(min)
    |> min(max)
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp normalize_reasoning_effort(value, _default)
       when value in ["low", "medium", "high", "xhigh"],
       do: value

  defp normalize_reasoning_effort(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_timezone(value) when is_binary(value) do
    case Timezones.normalize(value) do
      normalized when is_binary(normalized) -> normalized
      _ -> nil
    end
  end

  defp normalize_timezone(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append(list, true, values), do: list ++ values
  defp maybe_append(list, false, _values), do: list

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{} = map), do: map_size(map) == 0
  defp blank?(_value), do: false

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp to_existing_atom(_key), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max do
      value
    else
      value
      |> String.slice(0, max - 3)
      |> Kernel.<>("...")
    end
  end

  defp truncate(value, _max), do: value
end
