defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefing do
  @moduledoc """
  Source-backed daily Chief of Staff morning brief.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.ActionLedger
  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Acquisition
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ChiefOfStaff.MeetingEnrichment
  alias Maraithon.Companion
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm
  alias Maraithon.EmailDelivery
  alias Maraithon.Insights
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Memory
  alias Maraithon.OperatorEvents
  alias Maraithon.AssistantHarness.PromptStability
  alias Maraithon.PromptBudget
  alias Maraithon.Spend
  alias Maraithon.OpenLoops
  alias Maraithon.SourceFreshness
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos
  alias Maraithon.Tracing

  require Logger

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_morning_minute 0
  @default_email_scan_limit 100
  @default_slack_channel_scan_limit 16
  @default_slack_message_scan_limit 100
  @default_news_limit 25
  @default_lookback_hours 18
  # Tuned for the per-minute token bucket on the reasoning-tier primary
  # model. "xhigh" reasoning + a large output budget reliably exhausts the
  # TPM cap on a single call and the next attempt gets a 429 — the brief was
  # failing because it asked for more headroom than the account had. "high" +
  # 16k is still plenty for a thorough executive brief and leaves room for
  # retries/fallbacks.
  @default_llm_max_tokens 16_000
  @default_llm_reasoning_effort "high"
  @default_llm_timeout_ms 1_200_000
  @commercial_thread_lookback_hours 24 * 7
  @skill_path "priv/agents/skills/chief_of_staff/morning_briefing.md"
  @prompt_string_limit 12_000
  @prompt_default_list_limit 500
  @prompt_gmail_list_limit 12
  @prompt_gmail_body_limit 1_500
  # Hard caps on list sections embedded in the briefing prompt. Fetch limits
  # bound the database reads; these bound the context window — without them
  # sections like slack mentions and local files shipped wholesale.
  @prompt_section_limit 60
  @prompt_mentions_limit 40
  @prompt_voice_memos_limit 25
  @prompt_gmail_snippet_limit 400
  @prompt_meeting_list_limit 60
  @prompt_meeting_string_limit 6_000
  @prompt_web_context_limit 5
  @prompt_web_page_context_limit 3
  @prompt_relationship_limit 80
  @prompt_section_build_timeout_ms 30_000
  @max_prompt_section_bytes 64_000
  # This JSON is embedded inside a JSON message string. Keeping its stable
  # encoding at 32 KB reserves worst-case outer escaping plus skill text.
  @max_compact_brief_input_bytes 32_000
  @max_morning_request_bytes 128_000
  @commercial_thread_terms [
    "availability",
    "connect",
    "customer",
    "discount",
    "enterprise",
    "intro",
    "introduction",
    "pricing",
    "prospect",
    "team plan",
    "ultra plan"
  ]
  @commercial_counterparty_domain_markers []
  @commercial_teammate_domains []
  @local_imessage_chat_limit 100
  @local_notes_limit 100
  @local_voice_memo_limit 100
  @local_calendar_limit 500
  @local_reminders_days_ahead 7
  @local_reminders_limit 100
  @local_files_limit 100
  @local_browser_visits_limit 500
  @local_browser_top_hosts 25
  @local_files_allowed_extensions ~w(pdf md txt rtf rtfd docx pages key keynote ppt pptx xls xlsx csv numbers doc)
  @device_stale_seconds 2 * 60 * 60
  @telegram_chunk_limit 3_300
  @personal_calendar_terms ~w(appointment birthday camp child children dad dentist doctor daughter emma family home jack kid kids medical mom parent personal practice rsvp school soccer son spouse wife husband)
  @triage_action_terms [
    "action required",
    "approval",
    "approve",
    "blocked",
    "bug",
    "confirm",
    "contract",
    "customer",
    "deadline",
    "decision",
    "due",
    "enterprise",
    "escalation",
    "follow up",
    "follow-up",
    "invoice",
    "intro",
    "login",
    "need",
    "needs",
    "outage",
    "payment",
    "pricing",
    "prospect",
    "question",
    "reply",
    "request",
    "requested",
    "respond",
    "review",
    "security",
    "sign",
    "signature",
    "urgent",
    "waiting"
  ]
  @meeting_prep_terms [
    "ask",
    "before the call",
    "before the meeting",
    "bring",
    "carry",
    "check",
    "confirm",
    "context",
    "decide",
    "decision",
    "fit",
    "follow up",
    "follow-up",
    "prep",
    "prepare",
    "review",
    "risk",
    "test",
    "why it matters"
  ]
  @todo_ingest_retry_delays_ms [1_500, 5_000, 12_000]

  @impl true
  def id, do: "morning_briefing"

  @impl true
  def label, do: "Morning briefing"

  @impl true
  def description, do: "Builds the daily Chief of Staff briefing and sends it through Telegram."

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "morning_brief_hour_local" => @default_morning_hour,
      "morning_brief_minute_local" => @default_morning_minute,
      "email_scan_limit" => @default_email_scan_limit,
      "slack_channel_scan_limit" => @default_slack_channel_scan_limit,
      "slack_message_scan_limit" => @default_slack_message_scan_limit,
      "news_enabled" => true,
      "news_limit" => @default_news_limit,
      "news_feeds" => [
        %{
          "name" => "Techmeme",
          "url" => "https://www.techmeme.com/feed.xml"
        },
        %{
          "name" => "Hacker News",
          "url" => "https://hnrss.org/frontpage"
        },
        %{
          "name" => "BBC News",
          "url" => "https://feeds.bbci.co.uk/news/rss.xml"
        },
        %{
          "name" => "NYT Top Stories",
          "url" => "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"
        }
      ],
      "weather_enabled" => true,
      "lookback_hours" => @default_lookback_hours,
      "llm_max_tokens" => @default_llm_max_tokens,
      "llm_reasoning_effort" => @default_llm_reasoning_effort,
      "llm_timeout_ms" => @default_llm_timeout_ms,
      "slack_key_channels" => [],
      "commercial_counterparty_domain_markers" => [],
      "commercial_teammate_domains" => [],
      "commercial_gmail_queries" => []
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Required to deliver morning briefs.",
        required?: true
      },
      %{
        kind: :service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Needed for schedule, conflicts, prep notes, and tomorrow's first event.",
        required?: false
      },
      %{
        kind: :service,
        provider: "google",
        service: "gmail",
        label: "Gmail",
        description: "Needed for inbox triage and unanswered-reply signals.",
        required?: false
      },
      %{
        kind: :provider,
        provider: "slack",
        label: "Slack",
        description: "Needed for mentions, key channels, and thread follow-through.",
        required?: false
      }
    ]
  end

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    case get_in(context, [:trigger, :type]) do
      :message -> false
      :pubsub_event -> false
      _ -> true
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
      morning_hour:
        integer_in_range(config["morning_brief_hour_local"], @default_morning_hour, 0, 23),
      morning_minute:
        integer_in_range(config["morning_brief_minute_local"], @default_morning_minute, 0, 59),
      email_scan_limit:
        integer_in_range(config["email_scan_limit"], @default_email_scan_limit, 1, 500),
      slack_message_scan_limit:
        integer_in_range(
          config["slack_message_scan_limit"],
          @default_slack_message_scan_limit,
          1,
          500
        ),
      lookback_hours: integer_in_range(config["lookback_hours"], @default_lookback_hours, 1, 168),
      llm_model: normalize_string(config["llm_model"]),
      llm_max_tokens:
        integer_in_range(
          config["llm_max_tokens"],
          @default_llm_max_tokens,
          256,
          @default_llm_max_tokens
        ),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      llm_timeout_ms:
        integer_in_range(config["llm_timeout_ms"], @default_llm_timeout_ms, 30_000, 1_200_000),
      commercial_thread_terms:
        configured_string_list(config, "commercial_thread_terms", @commercial_thread_terms),
      commercial_counterparty_domain_markers:
        configured_string_list(
          config,
          "commercial_counterparty_domain_markers",
          @commercial_counterparty_domain_markers
        ),
      commercial_teammate_domains:
        configured_string_list(
          config,
          "commercial_teammate_domains",
          @commercial_teammate_domains
        ),
      pending_effect: nil,
      last_generated_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()
    period_key = local_period_key(now, state)
    dedupe_key = "morning_briefing:#{period_key}"

    cond do
      is_nil(user_id) ->
        {:idle, state}

      # Generation must never be gated on any single delivery channel being
      # healthy (a false-stale Telegram flag silently killed every morning
      # brief for days — prod 2026-07-16). Email always works because user
      # ids are email addresses, so this only blocks when there is truly
      # nowhere to deliver — and then it says so instead of idling silently.
      not deliverable?(user_id) ->
        record_generation_blocked(user_id, dedupe_key)
        {:idle, %{state | user_id: user_id}}

      Map.get(state.last_generated_keys, "morning") == period_key ->
        {:idle, %{state | user_id: user_id}}

      Briefs.exists?(user_id, dedupe_key) ->
        {:idle,
         %{
           state
           | user_id: user_id,
             pending_effect: nil,
             last_generated_keys: Map.put(state.last_generated_keys, "morning", period_key)
         }}

      not due_now?(now, state) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        brief_input = build_brief_input(user_id, now, state, context)

        pending_state = %{
          state
          | user_id: user_id,
            pending_effect: %{
              effect_kind: :morning_briefing,
              cycle_id: context[:assistant_cycle_id],
              dedupe_key: dedupe_key,
              issued_at: now
            }
        }

        case llm_params(brief_input, state) do
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

  # A brief is deliverable when any channel can carry it. Email is the
  # baseline channel (user ids are email addresses); Telegram is a bonus.
  defp deliverable?(user_id) do
    email_deliverable?(user_id) or ConnectedAccounts.telegram_destination(user_id) != nil
  end

  defp email_deliverable?(user_id) do
    String.contains?(user_id, "@") and email_module().configured?()
  end

  defp email_module do
    Application.get_env(:maraithon, :morning_briefing, [])
    |> Keyword.get(:email_module, EmailDelivery)
  end

  # Once per briefing day, not per wakeup — the cron retries every 30
  # minutes and a blocked day must not turn into a log/event flood.
  defp record_generation_blocked(user_id, dedupe_key) do
    Logger.warning("Morning briefing generation blocked: no deliverable channel",
      user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
      dedupe_reference: Maraithon.Redaction.fingerprint(dedupe_key)
    )

    _ =
      OperatorEvents.record_once(%{
        # Operator events are user-scoped business records; the raw identifier
        # is required only for the foreign key/routing column and never enters
        # the event payload, telemetry, or logs.
        user_id: user_id,
        source: "chief_of_staff",
        event_type: "morning_briefing.generation_blocked",
        source_item_id: dedupe_key,
        dedupe_key: "morning_briefing:generation_blocked:#{dedupe_key}",
        occurred_at: DateTime.utc_now(),
        payload: %{"reason" => "no_deliverable_channel"}
      })

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    Tracing.with_span(
      "chief_of_staff.morning_briefing",
      %{
        skill: "morning_briefing",
        user_id: context[:user_id] || state.user_id,
        llm_model: state.llm_model || Maraithon.LLM.model() || "unknown",
        llm_max_tokens: effective_llm_max_tokens(state),
        llm_reasoning_effort: state.llm_reasoning_effort,
        finish_reason: llm_finish_reason(response) || "ok"
      },
      fn ->
        pending_effect = state.pending_effect || %{}
        input_timestamp = pending_effect_timestamp(pending_effect, context[:timestamp])

        brief_input =
          build_brief_input(
            context[:user_id] || state.user_id,
            input_timestamp,
            state,
            context
          )

        parsed_brief = parse_llm_brief(response)

        {brief, generation_mode, error_message} =
          brief_or_error_notice(parsed_brief, response, brief_input)

        {brief, quality_verification} =
          verify_and_revise_morning_brief(brief, brief_input, generation_mode)

        if generation_mode == "error" do
          Tracing.record_error(
            "morning_briefing generation failed: " <>
              String.slice(error_message || "unknown", 0, 300)
          )
        end

        cost_summary = briefing_cost_summary(response, brief_input)

        attrs = %{
          "cadence" => "morning",
          "scheduled_for" =>
            read_string(brief_input, "generated_at", DateTime.utc_now() |> DateTime.to_iso8601()),
          "dedupe_key" =>
            read_string(pending_effect, "dedupe_key", nil) ||
              "morning_briefing:#{read_string(brief_input, "date", "unknown")}",
          "status" => "pending",
          "title" => read_string(brief, "title", "Morning briefing"),
          "summary" =>
            read_string(
              brief,
              "summary",
              "Review today's schedule, inbox, Slack, and commitments."
            ),
          "body" => read_string(brief, "body", "No briefing body was generated."),
          "error_message" => error_message,
          "metadata" => %{
            "agent_behavior" => state.assistant_behavior,
            "assistant_behavior" => state.assistant_behavior,
            "assistant_cycle_id" => context[:assistant_cycle_id],
            "error_message" => error_message,
            "generation_mode" => generation_mode,
            "llm_finish_reason" => llm_finish_reason(response),
            "llm_request" => llm_request_metadata(state),
            "max_tokens_used" => effective_llm_max_tokens(state),
            "reasoning_effort_used" => state.llm_reasoning_effort,
            "llm_usage" => json_metadata(response_usage(response)),
            "estimated_cost" => json_metadata(cost_summary),
            "quality_verification" => quality_verification,
            "origin_skill_id" => id(),
            "source_backed" => true,
            "brief_input" => compact_brief_input_for_metadata(brief_input),
            "source_health" => read_map(brief_input, "source_health"),
            "held_interruption_ids" => held_interruption_ids(brief_input)
          }
        }

        case Briefs.record(context[:user_id] || state.user_id, context[:agent_id], attrs) do
          {:ok, brief_record} ->
            period_key = read_string(brief_input, "date", nil)

            {todo_result, todo_elapsed_ms} =
              timed(fn ->
                queued_input =
                  Map.put(brief_input, "todo_target_brief_dedupe_key", brief_record.dedupe_key)

                persist_model_todos(context[:user_id] || state.user_id, brief, queued_input)
              end)

            {brief_record, linked_todo_ids, todo_link_error} =
              attach_model_todos_to_brief(brief_record, todo_result)

            event_type =
              if generation_mode in ["llm", "source_fallback"],
                do: :briefs_recorded,
                else: :brief_generation_failed

            todo_payload =
              todo_result
              |> todo_event_payload()
              |> Map.put(:todo_persistence_elapsed_ms, todo_elapsed_ms)
              |> Map.put(:linked_todo_ids, linked_todo_ids)
              |> maybe_put(:todo_link_error, todo_link_error)

            {:emit,
             {event_type,
              %{
                count: 1,
                error_message: error_message,
                generation_mode: generation_mode,
                user_id: context[:user_id] || state.user_id,
                cadences: ["morning"],
                source_backed: true,
                brief_id: brief_record.id
              }
              |> Map.merge(todo_payload)},
             %{
               state
               | pending_effect: nil,
                 last_generated_keys: Map.put(state.last_generated_keys, "morning", period_key)
             }}

          {:error, reason} ->
            # Never fail this silently again: a lost record means a lost
            # briefing day.
            Tracing.record_error(
              "morning_briefing record failed: " <> Maraithon.Redaction.error_summary(reason)
            )

            Logger.warning("Morning briefing record failed",
              user_fingerprint:
                Maraithon.Redaction.fingerprint(context[:user_id] || state.user_id),
              dedupe_reference:
                Maraithon.Redaction.fingerprint(read_string(pending_effect, "dedupe_key", nil)),
              failure_code: Maraithon.Redaction.error_class(reason)
            )

            {:idle, %{state | pending_effect: nil}}
        end
      end
    )
  end

  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  defp pending_effect_timestamp(pending_effect, fallback) do
    pending_effect
    |> Map.get(:issued_at, Map.get(pending_effect, "issued_at"))
    |> parse_event_datetime()
    |> case do
      %DateTime{} = timestamp -> timestamp
      _ -> fallback || DateTime.utc_now()
    end
  end

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
    {:absolute, next_morning_occurrence(now, state)}
  end

  def build_brief_input(user_id, now, state, context) do
    source_bundle = context[:source_bundle] || %{}
    offset_hours = timezone_offset_hours_at(now, state)
    local_date = local_date(now, state)
    local_day_start = local_day_start_utc(local_date, state)
    tomorrow = Date.add(local_date, 1)
    lookback_start = DateTime.add(now, -state.lookback_hours, :hour)
    commercial_lookback_start = DateTime.add(now, -@commercial_thread_lookback_hours, :hour)

    # Merge the local Calendar.app mirror with Google Calendar. The local
    # mirror can be stale or unavailable on remote runs, while Google may
    # omit non-Google accounts; neither source should suppress the other.
    google_calendar_events = SourceBundle.calendar_events(source_bundle)
    bundle_local_calendar = SourceBundle.calendar_local_events(source_bundle)

    {local_calendar_events, local_calendar_error} =
      fetch_local_source(user_id, :calendar_local, bundle_local_calendar, fn id ->
        LocalCalendar.events_around(id,
          since: local_day_start,
          until: DateTime.add(local_day_start, 72 * 3_600, :second),
          limit: @local_calendar_limit
        )
      end)

    local_calendar_events =
      local_calendar_events
      |> Enum.map(&local_event_to_prompt/1)
      |> Enum.reject(&is_nil/1)

    calendar_events =
      (local_calendar_events ++ google_calendar_events)
      |> dedupe_calendar_events()
      |> Enum.sort_by(&event_sort_key/1)

    calendar_source =
      cond do
        local_calendar_events != [] and google_calendar_events != [] -> "local+google"
        local_calendar_events != [] -> "local"
        google_calendar_events != [] -> "google"
        true -> "none"
      end

    gmail_messages = SourceBundle.gmail_messages(source_bundle)
    gmail_inbox_messages = SourceBundle.gmail_inbox_messages(source_bundle)
    slack_messages = SourceBundle.slack_messages(source_bundle)
    news_items = SourceBundle.news_items(source_bundle)

    recent_slack_messages =
      Enum.filter(slack_messages, &recent_slack_message?(&1, lookback_start))

    bundle_imessage_chats = SourceBundle.imessage_chats(source_bundle)

    {imessage_chats, imessage_error} =
      fetch_local_source(user_id, :imessage, bundle_imessage_chats, fn id ->
        LocalMessages.chats_recent(id, limit: @local_imessage_chat_limit, now: now)
      end)

    bundle_notes = SourceBundle.notes(source_bundle)

    {notes, notes_error} =
      fetch_local_source(user_id, :notes, bundle_notes, fn id ->
        LocalNotes.recent_for_user(id, limit: @local_notes_limit)
      end)

    bundle_memos = SourceBundle.voice_memos(source_bundle)

    {voice_memos, voice_memos_error} =
      fetch_local_source(user_id, :voice_memos, bundle_memos, fn id ->
        LocalVoiceMemos.recent_for_user(id, limit: @local_voice_memo_limit)
      end)

    bundle_reminders = SourceBundle.reminders(source_bundle)

    {reminders, reminders_error} =
      fetch_local_source(user_id, :reminders, bundle_reminders, fn id ->
        LocalReminders.due_soon(id,
          days_ahead: @local_reminders_days_ahead,
          limit: @local_reminders_limit
        )
      end)

    bundle_files = SourceBundle.files(source_bundle)

    {files, files_error} =
      fetch_local_source(user_id, :files, bundle_files, fn id ->
        id
        |> LocalFiles.recent_for_user(limit: @local_files_limit * 6)
        |> Enum.filter(&allowed_file_extension?/1)
      end)

    bundle_visits = SourceBundle.browser_visits(source_bundle)

    {visits, browser_history_error} =
      fetch_local_source(user_id, :browser_history, bundle_visits, fn id ->
        LocalBrowserHistory.recent_visits(id, limit: @local_browser_visits_limit)
      end)

    top_hosts = top_browser_hosts(visits, now, @local_browser_top_hosts)

    commercial_thread_messages =
      gmail_messages
      |> Enum.filter(&recent_gmail_message?(&1, commercial_lookback_start))
      |> Enum.filter(&commercial_thread_candidate?(&1, state))
      |> Enum.uniq_by(&commercial_thread_key/1)
      |> Enum.sort_by(&commercial_thread_sort_key/1, :desc)

    commercial_threads =
      commercial_thread_messages
      |> Enum.map(&gmail_message_for_prompt/1)

    local_source_errors =
      [
        calendar_local: local_calendar_error,
        imessage: imessage_error,
        notes: notes_error,
        voice_memos: voice_memos_error,
        reminders: reminders_error,
        files: files_error,
        browser_history: browser_history_error
      ]
      |> Enum.reject(fn {_source, error} -> is_nil(error) end)
      |> Map.new()

    today_events =
      calendar_events
      |> Enum.filter(&event_on_date?(&1, local_date, state))
      |> Enum.map(&calendar_event_for_prompt(&1, state))
      |> Enum.reject(&is_nil/1)

    tomorrow_first_event =
      calendar_events
      |> Enum.filter(&event_on_date?(&1, tomorrow, state))
      |> Enum.sort_by(&event_sort_key/1)
      |> List.first()
      |> calendar_event_for_prompt(state)

    meeting_prep =
      MeetingEnrichment.enrich(user_id, today_events,
        now: now,
        max_web_queries: 100,
        internal_email_domains: Map.get(state, :commercial_teammate_domains, [])
      )

    schedule_coverage = schedule_coverage_contract(meeting_prep)

    # SPEC 07 R1: briefing-shaped query — today's date plus the concrete
    # calendar/commercial-thread subjects in this brief, instead of a static
    # "morning briefing chief of staff relevance" string with no signal.
    briefing_memory_query =
      briefing_memory_query(local_date, today_events, commercial_threads)

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "timezone_offset_hours" => offset_hours,
      "timezone" => timezone_label(state, now),
      "calendar" => %{
        "preferred_source" => calendar_source,
        "today_events" => today_events,
        "tomorrow_first_event" => tomorrow_first_event,
        "upcoming_local" =>
          local_calendar_events
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&calendar_event_for_prompt(&1, state))
      },
      "meeting_prep" => meeting_prep,
      "schedule_coverage" => schedule_coverage,
      "commercial_coverage" => commercial_coverage_contract(commercial_threads),
      "imessage" => %{
        "chats" =>
          imessage_chats
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&imessage_chat_for_prompt/1),
        "counts" => %{"chats" => length(imessage_chats)}
      },
      "notes" => %{
        "items" =>
          notes
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&note_for_prompt/1),
        "counts" => %{"count" => length(notes)}
      },
      "voice_memos" => %{
        "items" =>
          voice_memos
          |> Enum.take(@prompt_voice_memos_limit)
          |> Enum.map(&voice_memo_for_prompt/1),
        "counts" => %{"count" => length(voice_memos)}
      },
      "reminders" => %{
        "due_soon" =>
          reminders
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&reminder_for_prompt/1),
        "counts" => %{
          "open" => length(reminders),
          "due_today" => Enum.count(reminders, &reminder_due_today?(&1, now))
        }
      },
      "files" => %{
        "items" =>
          files
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&file_for_prompt/1),
        "counts" => %{"recent_count" => length(files)}
      },
      "browser_history" => %{
        "top_hosts" => top_hosts,
        "counts" => %{
          "visits_last_24h" =>
            Enum.count(visits, fn visit ->
              within_last_24h?(visit_last_visited_at(visit), now)
            end)
        }
      },
      "gmail" => %{
        "commercial_threads" => commercial_threads,
        "recent_inbox" =>
          gmail_inbox_messages
          |> Enum.filter(&recent_gmail_message?(&1, lookback_start))
          |> SourceBundle.prioritize_gmail_actionable()
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&gmail_message_for_prompt/1),
        "recent_unread" =>
          gmail_inbox_messages
          |> Enum.filter(&recent_unread_message?(&1, lookback_start))
          |> SourceBundle.prioritize_gmail_actionable()
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&gmail_message_for_prompt/1),
        "counts" => %{
          "messages" => length(gmail_messages),
          "inbox" => length(gmail_inbox_messages),
          "commercial_threads" => length(commercial_thread_messages),
          "recent_inbox" =>
            Enum.count(gmail_inbox_messages, &recent_gmail_message?(&1, lookback_start)),
          "recent_unread" =>
            Enum.count(gmail_inbox_messages, &recent_unread_message?(&1, lookback_start))
        }
      },
      "slack" => %{
        "key_threads" =>
          slack_messages
          |> Enum.filter(&recent_slack_message?(&1, lookback_start))
          |> Enum.reject(&blank?(read_string(&1, "text", nil)))
          |> Enum.take(@prompt_section_limit)
          |> Enum.map(&slack_message_for_prompt/1),
        "mentions" =>
          source_bundle
          |> SourceBundle.slack_mentions()
          |> Enum.take(@prompt_mentions_limit),
        "counts" => %{
          "messages" => length(slack_messages),
          "recent_messages" => length(recent_slack_messages),
          "mentions" => length(SourceBundle.slack_mentions(source_bundle))
        }
      },
      "news" => %{
        "items" =>
          news_items
          |> Enum.map(&news_item_for_prompt/1),
        "counts" => %{
          "items" => length(news_items),
          "feeds" => length(SourceBundle.news_feeds(source_bundle))
        }
      },
      "weather" => SourceBundle.weather(source_bundle),
      # SPEC 05 R6: sourced from the direction-aware todo queries
      # (Todos.list_owed_by_me/2) instead of the retired Commitment schema,
      # which nothing ever wrote to.
      "commitments" =>
        Todos.bucket_for_brief(user_id,
          now: now,
          timezone_offset_hours: offset_hours,
          timezone_label: timezone_label(state, now),
          limit: 50
        ),
      "open_work" => %{
        "insights" =>
          user_id
          |> Insights.list_open_act_now_for_user(limit: 100)
          |> Enum.map(&insight_for_prompt/1),
        "todos" =>
          user_id
          |> Todos.list_open_for_user(limit: 100)
          |> Enum.map(&todo_for_prompt/1),
        "held_interruptions" => held_interruptions_for_prompt(user_id),
        "system_notices" => self_heal_notices_for_prompt(user_id)
      },
      "user_identity" => Maraithon.UserIdentity.prompt_block(user_id),
      "relationships" =>
        user_id
        |> Crm.summarize_for_prompt(100),
      "deep_memory" =>
        user_id
        |> Memory.prompt_context(query: briefing_memory_query, limit: 100),
      "source_health" =>
        source_bundle
        |> SourceBundle.freshness()
        |> merge_local_source_health(
          user_id,
          now,
          [
            imessage: imessage_chats,
            notes: notes,
            voice_memos: voice_memos,
            calendar_local: local_calendar_events,
            reminders: reminders,
            files: files,
            browser_history: visits
          ],
          local_source_errors
        ),
      # R6: `source_health` above is this cycle's per-fetch status (ready/
      # partial/unavailable) and can read "partial" for an ordinary quiet
      # day. `connector_health` is the durable account-level signal
      # (`Maraithon.SourceFreshness`) so the brief can say plainly when a
      # source used in this run has an active reconnect issue, not just a
      # quiet one.
      "connector_health" => broken_connector_health(user_id, now)
    }
  end

  defp broken_connector_health(user_id, now) do
    user_id
    |> SourceFreshness.compact_for_prompt(now: now)
    |> Enum.reject(&(Map.get(&1, :status) == "fresh"))
  end

  @doc """
  Smoke-test the morning briefing pipeline end-to-end without an agent
  process. Loads the named agent's morning_briefing config, builds the
  prompt against current connector state, calls the LLM, validates the
  response, and returns `{:ok, brief}` or `{:error, reason, diagnostics}`.

  When `send: true` is passed in opts, the validated brief is delivered
  to the user's Telegram destination so we can confirm end-to-end.
  """
  def smoke_test(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    agent = Maraithon.Repo.get!(Maraithon.Agents.Agent, agent_id)
    user_id = smoke_test_user_id(agent)

    if is_nil(user_id) do
      {:error, :no_user_id, %{}}
    else
      skill_config = smoke_test_skill_config(agent, user_id)
      state = init(skill_config)
      now = Keyword.get(opts, :now, DateTime.utc_now())
      total_started_ms = System.monotonic_time(:millisecond)

      {context, source_context_elapsed_ms} =
        timed(fn -> smoke_test_context(agent, user_id, skill_config, now, opts) end)

      {brief_input, input_build_elapsed_ms} =
        timed(fn -> build_brief_input(user_id, now, state, context) end)

      case llm_params(brief_input, state) do
        {:ok, params} ->
          started_ms = System.monotonic_time(:millisecond)

          # Go through LLMCallCommand so smoke_test keeps the same bounded fast
          # retry/fallback policy for in-budget failures. This synthetic direct
          # call is not a durable claim: a full provider timeout returns once and
          # retains the existing direct-call ceiling instead of pretending it can
          # use persisted timeout provenance.
          effect = %Maraithon.Effects.Effect{
            id: Ecto.UUID.generate(),
            agent_id: agent.id,
            params: params
          }

          case Maraithon.Runtime.Effects.LLMCallCommand.execute(effect) do
            {:ok, response} ->
              elapsed_ms = System.monotonic_time(:millisecond) - started_ms
              parsed = parse_llm_brief(response)

              diagnostics = %{
                model: response.model,
                tokens_in: response.tokens_in,
                tokens_out: response.tokens_out,
                finish_reason: response.finish_reason,
                elapsed_ms: elapsed_ms,
                briefing_llm_elapsed_ms: elapsed_ms,
                source_context_elapsed_ms: source_context_elapsed_ms,
                input_build_elapsed_ms: input_build_elapsed_ms,
                max_tokens_used: effective_llm_max_tokens(state),
                reasoning_effort_used: state.llm_reasoning_effort,
                llm_usage: response_usage(response),
                estimated_cost: briefing_cost_summary(response, brief_input),
                calendar_today_events:
                  length(get_in(brief_input, ["calendar", "today_events"]) || []),
                commercial_coverage_required_threads:
                  get_in(brief_input, ["commercial_coverage", "counts", "required_threads"]) || 0,
                meeting_prep_counts: get_in(brief_input, ["meeting_prep", "counts"]),
                source_acquisition:
                  if(Map.has_key?(context, :assistant_fetch_telemetry),
                    do: "acquired",
                    else: "provided"
                  )
              }

              case parsed do
                {:ok, brief} ->
                  finalize_smoke_brief(
                    agent.id,
                    user_id,
                    brief,
                    brief_input,
                    "llm",
                    diagnostics,
                    opts,
                    total_started_ms
                  )

                {:error, reason} ->
                  diagnostics =
                    diagnostics
                    |> Map.put(:error_message, reason)
                    |> Map.put(:generation_mode, "source_fallback")

                  {brief, generation_mode, error_message} =
                    brief_or_error_notice({:error, reason}, response, brief_input)

                  finalize_smoke_brief(
                    agent.id,
                    user_id,
                    brief,
                    brief_input,
                    generation_mode,
                    Map.put(diagnostics, :error_message, error_message),
                    opts,
                    total_started_ms
                  )
              end

            {:error, reason} ->
              elapsed_ms = System.monotonic_time(:millisecond) - started_ms

              error_summary = "llm_call_failed: #{Maraithon.Redaction.error_summary(reason)}"

              response = %{
                content: "",
                error: error_summary,
                finish_reason: "error"
              }

              {brief, generation_mode, error_message} =
                brief_or_error_notice(
                  {:error, error_summary},
                  response,
                  brief_input
                )

              finalize_smoke_brief(
                agent.id,
                user_id,
                brief,
                brief_input,
                generation_mode,
                %{
                  elapsed_ms: elapsed_ms,
                  briefing_llm_elapsed_ms: elapsed_ms,
                  source_context_elapsed_ms: source_context_elapsed_ms,
                  input_build_elapsed_ms: input_build_elapsed_ms,
                  max_tokens_used: effective_llm_max_tokens(state),
                  reasoning_effort_used: state.llm_reasoning_effort,
                  error_message: error_message,
                  generation_mode: generation_mode
                },
                opts,
                total_started_ms
              )
          end

        {:error, reason} ->
          {:error, {:llm_params_failed, reason}, %{}}
      end
    end
  end

  defp finalize_smoke_brief(
         agent_id,
         user_id,
         brief,
         brief_input,
         generation_mode,
         diagnostics,
         opts,
         total_started_ms
       ) do
    {brief, quality_verification} =
      verify_and_revise_morning_brief(brief, brief_input, generation_mode)

    {todo_result, todo_elapsed_ms} =
      if Keyword.get(opts, :persist_todos, Keyword.get(opts, :send, false)) do
        timed(fn -> persist_model_todos(user_id, brief, brief_input) end)
      else
        {{:ok, :no_todos}, 0}
      end

    diagnostics =
      diagnostics
      |> Map.put(:generation_mode, generation_mode)
      |> Map.put(:quality_verification, quality_verification)
      |> Map.put(:todo_persistence, todo_event_payload(todo_result))
      |> Map.put(:todo_persistence_elapsed_ms, todo_elapsed_ms)

    {delivery_result, delivery_elapsed_ms} =
      if Keyword.get(opts, :send, false) do
        timed(fn -> deliver_smoke_brief(agent_id, user_id, brief, diagnostics, todo_result) end)
      else
        {{:ok, :not_sent}, 0}
      end

    diagnostics =
      diagnostics
      |> Map.put(:telegram_delivery, delivery_event_payload(delivery_result))
      |> Map.put(:telegram_delivery_elapsed_ms, delivery_elapsed_ms)
      |> Map.put(:total_elapsed_ms, elapsed_since_ms(total_started_ms))

    {:ok, brief, diagnostics}
  end

  defp smoke_test_user_id(agent) do
    agent_config = agent.config || %{}
    skill_config = get_in(agent_config, ["skill_configs", "morning_briefing"]) || %{}

    normalize_string(Map.get(skill_config, "user_id")) ||
      normalize_string(agent.user_id) ||
      normalize_string(Map.get(agent_config, "user_id"))
  end

  defp smoke_test_skill_config(agent, user_id) do
    agent_config = agent.config || %{}
    skill_config = get_in(agent_config, ["skill_configs", "morning_briefing"]) || %{}

    default_config()
    |> Map.merge(
      Map.take(agent_config, [
        "source_policy",
        "source_scope",
        "timezone_offset_hours",
        "morning_brief_hour_local",
        "morning_brief_minute_local",
        "email_scan_limit",
        "slack_channel_scan_limit",
        "slack_message_scan_limit",
        "news_enabled",
        "news_limit",
        "news_feeds",
        "lookback_hours",
        "timezone",
        "timezone_name",
        "llm_model",
        "llm_max_tokens",
        "llm_reasoning_effort",
        "slack_key_channels"
      ])
    )
    |> Map.merge(skill_config)
    |> Map.put("user_id", user_id)
  end

  defp smoke_test_context(agent, user_id, skill_config, now, opts) do
    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      budget: %{},
      recent_events: [],
      trigger: %{type: :manual, source: "morning_briefing_smoke_test"},
      event: nil
    }

    case Keyword.get(opts, :source_bundle, :acquire) do
      %{} = source_bundle ->
        Map.put(context, :source_bundle, source_bundle)

      false ->
        context

      _ ->
        {source_bundle, telemetry, _proposed_watermarks} =
          Acquisition.build(
            user_id,
            [id()],
            %{id() => skill_config},
            context
          )

        context
        |> Map.put(:source_bundle, source_bundle)
        |> Map.put(:assistant_fetch_telemetry, telemetry)
    end
  end

  defp deliver_smoke_brief(agent_id, user_id, brief, _diagnostics, todo_result) do
    case ConnectedAccounts.telegram_destination(user_id) do
      nil ->
        {:error, :no_telegram_destination}

      destination ->
        chat_id =
          case destination do
            %{chat_id: id} -> id
            %{"chat_id" => id} -> id
            id when is_binary(id) -> id
            other -> to_string(other)
          end

        {review_brief, reply_markup} = smoke_review_brief(agent_id, user_id, brief, todo_result)

        with {:ok, result} <-
               brief
               |> smoke_brief_telegram_chunks()
               |> send_telegram_html_chunks(chat_id, reply_markup) do
          _ = mark_smoke_review_brief_sent(review_brief, result)
          {:ok, Map.put(result, "todo_review_brief_id", review_brief_id(review_brief))}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp smoke_brief_telegram_chunks(brief) do
    title = read_string(brief, "title", "Morning briefing")
    summary = read_string(brief, "summary", "")
    body = read_string(brief, "body", "")

    [title, summary, body]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Maraithon.TelegramChunking.chunks(@telegram_chunk_limit)
    |> Maraithon.TelegramChunking.label_parts()
    |> Enum.map(&Maraithon.TelegramMarkdown.to_html/1)
  end

  defp send_telegram_html_chunks(chunks, chat_id, reply_markup) do
    last_index = max(length(chunks) - 1, 0)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, message_ids} ->
      opts =
        [parse_mode: "HTML"]
        |> maybe_put_keyword(:reply_markup, if(index == last_index, do: reply_markup, else: nil))

      case Maraithon.TelegramResponder.send(chat_id, chunk, opts) do
        {:ok, result} ->
          {:cont, {:ok, [read_message_id(result) | message_ids]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, message_ids} ->
        {:ok, %{"message_ids" => Enum.reverse(message_ids), "chunks" => length(message_ids)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp smoke_review_brief(agent_id, user_id, brief, {:ok, result})
       when is_binary(agent_id) and is_binary(user_id) and is_map(result) do
    todos_or_ids =
      Map.get(result, :todos, []) ++
        (result |> Map.get(:linked_todo_ids, []) |> List.wrap())

    if todos_or_ids == [] do
      {nil, nil}
    else
      attrs = %{
        "cadence" => "morning",
        "title" => brief |> read_string("title", "Morning briefing") |> truncate_text(180),
        "summary" =>
          brief
          |> read_string("summary", "Review the morning briefing work items.")
          |> truncate_text(500),
        "body" => brief |> read_string("body", "") |> truncate_text(3_900),
        "scheduled_for" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "dedupe_key" => "morning_briefing:manual:#{Ecto.UUID.generate()}",
        "status" => "sent",
        "metadata" => %{
          "origin_skill_id" => id(),
          "manual_smoke_test" => true,
          "source_backed" => true
        }
      }

      with {:ok, brief_record} <- Briefs.record(user_id, agent_id, attrs),
           {:ok, linked_brief} <- Briefs.attach_linked_todos(brief_record, todos_or_ids) do
        payload = Briefs.telegram_payload(linked_brief)
        {linked_brief, payload.reply_markup}
      else
        _ -> {nil, nil}
      end
    end
  end

  defp smoke_review_brief(_agent_id, _user_id, _brief, _todo_result), do: {nil, nil}

  defp mark_smoke_review_brief_sent(nil, _result), do: :ok

  defp mark_smoke_review_brief_sent(brief, %{"message_ids" => [message_id | _]}) do
    _ = Briefs.mark_sent(brief, message_id)
    :ok
  end

  defp mark_smoke_review_brief_sent(brief, result) when is_map(result) do
    _ = Briefs.mark_sent(brief, read_message_id(result))
    :ok
  end

  defp review_brief_id(nil), do: nil
  defp review_brief_id(%Maraithon.Briefs.Brief{id: id}), do: id

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp truncate_text(value, max_length) when is_binary(value) and is_integer(max_length) do
    if String.length(value) > max_length do
      value
      |> String.slice(0, max_length)
      |> String.trim()
    else
      value
    end
  end

  defp truncate_text(value, _max_length), do: value

  defp read_message_id(%{"message_id" => message_id}), do: normalize_message_id(message_id)
  defp read_message_id(%{message_id: message_id}), do: normalize_message_id(message_id)
  defp read_message_id(_result), do: nil

  defp normalize_message_id(message_id) when is_integer(message_id),
    do: Integer.to_string(message_id)

  defp normalize_message_id(message_id) when is_binary(message_id), do: message_id
  defp normalize_message_id(_message_id), do: nil

  defp llm_params(brief_input, state) do
    with {:ok, prompt} <- morning_prompt(brief_input) do
      params =
        %{
          "messages" => [
            %{
              "role" => "user",
              "content" => prompt
            }
          ],
          "max_tokens" => effective_llm_max_tokens(state),
          "temperature" => 0.2,
          "reasoning_effort" => state.llm_reasoning_effort,
          "timeout_ms" => state.llm_timeout_ms
        }
        |> maybe_put("model", state.llm_model || Maraithon.LLM.model())

      {:ok, params}
    end
  end

  defp morning_prompt(brief_input) do
    with {:ok, skill} <- MarkdownSkill.load_file(@skill_path),
         {:ok, input_json} <- Jason.encode(compact_brief_input_for_prompt(brief_input)) do
      prompt =
        """
        Execute the loaded Markdown skill against the supplied connector context.

        Skill: #{skill.name}
        Skill path: #{@skill_path}

        Skill instructions:
        #{skill.instructions}

        Email review rule:
        Every Gmail item includes body_available, body_status, and body. Use body for relevance
        and obligation judgments. Do not classify an email from sender, subject, or snippet alone.
        If body_status is available_truncated, treat body as the selected bounded source excerpt
        for that message and keep uncertainty visible when the excerpt is insufficient. If
        body_available is false, treat that email as unreviewable source degradation and do not
        surface it as finance, school, marketing, urgent, or actionable unless another message-backed
        source supports that conclusion.

        Local source rule:
        When the connector context includes iMessage chats, calendar events, reminders, notes, voice memos, files, or browser history, cite the most relevant items by short name. Prefer first-party local sources over scraped equivalents.

        Held interruptions rule:
        open_work.held_interruptions lists proactive Telegram pushes that were held instead of
        interrupting (quiet hours, the hourly interruption budget, or a model hold decision) and
        are now due for review in this brief. Do not silently drop them: fold any that still need
        a decision into Needs Your Attention, Open Commitments, or another appropriate section
        using hold_reason and why_now for context, and skip any that are already fully covered by
        another item in this brief.

        System notices rule:
        open_work.system_notices lists things the agent itself noticed were stuck and fixed since
        the last brief (self-heals). Mention one only if it is genuinely noteworthy — a real gap
        the operator would want to know was closed, not routine bookkeeping. When you do, keep it
        to one brief, matter-of-fact line without alarm. Otherwise say nothing about it; an empty
        or unremarkable list should leave no trace in the brief.

        Source digest rule:
        The morning briefing payload is assembled from independently bounded source digests for
        Gmail, Slack, calendar, People records, open work, memory, and local sources. Treat
        included rows as the selected high-signal evidence set, not a full raw export. Review all
        included rows before deciding what belongs in the executive brief, and use
        source_health/counts to call out connector gaps or truncation risk when it affects
        confidence.

        Connector health rule:
        connector_health lists connected sources with an active reconnect issue (stale, never
        synced, an error, or needing reauth) - fresh sources are omitted, so any entry there is a
        real coverage gap. If a source in that list is one this brief draws on (Gmail, Calendar,
        Slack), add one short line near the top noting the gap, e.g. "This run only covers Gmail;
        Calendar needs reconnect." Do not invent detail beyond account_label/status/stale_reason,
        and do not repeat the note for every section - state it once.

        Inbox and Slack triage contract:
        If gmail.recent_inbox, gmail.recent_unread, slack.key_threads, or slack.mentions contain
        body/text-backed items that change action, include scoped Inbox Triage and/or Slack Triage
        sections. Do not list promotional email, sender-only guesses, or email with missing body
        evidence. Name account or channel counts only when those counts change what the operator
        should do.

        Meeting enrichment rule:
        The brief input includes meeting_prep, which is prepared relationship-first. Use saved
        relationship context before public web context. Use web snippets only as fallback evidence
        for attendees or companies missing from People records, and keep uncertainty visible when
        the evidence is thin.
        When meeting_prep.web_context includes page_contexts, treat those source pages as the
        meeting dossier. For each required external meeting, synthesize the executive read:
        who the person is, what the company or practice does, why the meeting likely matters
        to the operator's work, what fit or risk they should test, and the concrete pre/post-call
        next step. Do not collapse a verified external meeting into a generic "creative
        vendor" or "intro chat" label when the page context supports a richer prep note.
        When a source page gives concrete facts such as services, pricing, operating model,
        work history, background, customer profile, or partnership angle, include the most
        decision-useful specifics in the meeting note. If an internal teammate owns or hosts
        the meeting, state what the operator should ask that teammate before or after the call.
        A busy executive should be able to read the schedule item and know the dossier,
        fit hypothesis, and next move without asking for a second briefing.

        Commercial thread rule:
        Fresh external commercial threads from close teammates are not inbox noise. Use model
        judgment to scan gmail.commercial_threads, gmail.recent_inbox, commitments, open work, and
        relationship context for teammate-led customer, prospect, intro, plan, pricing, discount,
        availability, or launch-video threads.
        Treat gmail.commercial_threads as a coverage list: include every live non-duplicative
        external commercial thread from that list that a busy executive would want to know about,
        especially teammate-led prospect/customer threads such as Enterprise/Team plan, discount,
        intro, or availability discussions. If a close teammate has looped the operator
        into an external commercial thread, include a concise readiness note even when no immediate
        decision is forced. Say who or which organization is involved, the live ask, and what
        guidance the operator should have ready.

        Commercial coverage contract:
        commercial_coverage.required_threads is a hard coverage contract, not a ranking hint.
        If required_threads is non-empty, Decisions / Follow-ups or Today's Schedule must include
        every item in that list unless it is clearly duplicated by another named item. Use model
        judgment for the executive read, but do not drop a teammate-led customer, prospect, intro,
        Enterprise/Team plan, pricing, discount, or availability thread just because there are
        other risk items. Before returning JSON, verify that each required commercial thread appears
        by organization or counterparty name with the live ask and the guidance the operator should have ready.

        Schedule coverage contract:
        Required external meetings are a hard coverage contract, not a ranking hint. If
        schedule_coverage.required_meetings is non-empty, Today's Schedule must include
        every item in that list. Use model judgment for what the meeting means and how the operator
        should prepare; do not write a heuristic digest. Do not say the calendar is open
        when calendar.today_events or schedule_coverage.required_meetings is non-empty.
        Use display_start and display_end exactly when present for schedule times; do not
        recompute local clock times from UTC fields. If a display time is absent, cite UTC
        rather than guessing a local time.
        Before returning JSON, perform a final model review that the body includes every
        required external meeting with time, attendee or organization, why it matters, and
        the prep point, decision, or risk the operator should carry into it.

        Reference briefing eval:
        Treat this as the acceptance shape for a packed day, not a loose style hint:
        a specific weekday/date headline; Needs Your Attention with the top 4-6 ranked moves;
        Today's Schedule with every material meeting, explicit conflicts, and what to move,
        leave early, decline, or choose; scoped Inbox and Slack triage with account/channel
        counts only when they change action; Open Commitments with active/overdue/due-today/
        coming-up buckets; draft IDs, action-card IDs, OmniFocus IDs, Gmail thread IDs, and
        Slack channel/ts handles kept in metadata or source references, not the user-facing body;
        a separate Manual Decisions / Admin line for dashboard, payment, review, signature,
        investigation, or judgment work;
        and a Look Ahead that names tomorrow/week risks plus one final Today's move directive.
        Before returning JSON, privately score the draft against this reference contract and
        revise until packed-day operational coverage is complete without turning into inventory.

        Response budget rule:
        Return compact executive JSON that can finish well under the token budget. The body should
        be concise and scannable: quiet days can be short, while packed days can run up to roughly
        2,200 words when conflicts, commitments, and pending actions justify it. Include every
        required meeting and required commercial thread, but compress lower-priority context instead
        of expanding it. Emit todos only for durable work worth a separate Done/Dismiss decision.
        Each todo must be one concrete action with source_item_id or dedupe_key when available,
        person/company/why-now/evidence context in metadata, and work_type when it is draftable,
        dashboard, payment, review, decision, prep, or personal_logistic work.

        Source honesty / anti-hallucination rule:
        Never invent facts that are not present in the brief input JSON. In particular:
        - Do not invent dollar amounts, wire totals, account numbers, passwords, security answers,
          PINs, form filenames, email addresses, phone numbers, or people who are not in the input.
        - Do not invent schedule conflicts. Only call out overlaps that exist between
          calendar.today_events, meeting_prep.meetings, or schedule_coverage.required_meetings
          using their display_start/display_end or start/end times.
        - For Next Actions and todos, copy amounts, filenames, addresses, and credentials only when
          they appear verbatim in source evidence. Otherwise describe the action without fabricated
          specifics (prefer "confirm the pending Mercury wire amount" over inventing "$38,200").
        - Prefer visible uncertainty over confident invention. If a source body is truncated or
          missing, say so instead of filling gaps.
        - Do not recycle stale open_work as if it were confirmed live evidence for today unless the
          same fact also appears in today's calendar, Gmail, Slack, or local source rows.

        Brief input JSON:
        #{input_json}
        """

      if prompt_request_bytes(prompt) <= @max_morning_request_bytes do
        {:ok, prompt}
      else
        {:error, :morning_prompt_exceeds_budget}
      end
    end
  end

  defp prompt_request_bytes(prompt) when is_binary(prompt) do
    [%{"role" => "user", "content" => prompt}]
    |> PromptStability.encode!()
    |> byte_size()
  end

  defp parse_llm_brief(response) do
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

        {:ok, %{"title" => title, "summary" => summary, "body" => body, "todos" => todos}}
      else
        _ -> {:error, "model_response_invalid_or_missing_required_brief_json"}
      end
    end
  end

  defp brief_or_error_notice({:ok, brief}, _response, _brief_input), do: {brief, "llm", nil}

  defp brief_or_error_notice({:error, reason}, response, brief_input) do
    error_message =
      [
        "Morning briefing used available-context fallback",
        reason,
        llm_finish_reason(response) && "finish_reason=#{llm_finish_reason(response)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")

    {build_compact_fallback_brief(brief_input, error_message), "source_fallback", error_message}
  end

  @doc """
  Builds a compact context-backed brief when generated output cannot produce a
  valid JSON briefing.
  """
  def build_compact_fallback_brief(brief_input, error_message \\ "brief generation unavailable")

  def build_compact_fallback_brief(brief_input, error_message) when is_map(brief_input) do
    source_backed_fallback_brief(brief_input, error_message)
  end

  def build_compact_fallback_brief(_brief_input, error_message) do
    source_backed_fallback_brief(:no_source_input, error_message)
  end

  defp source_backed_fallback_brief(brief_input, _error_message) when is_map(brief_input) do
    date = read_string(brief_input, "date", "today")
    calendar = read_map(brief_input, "calendar")
    today_events = read_list(calendar, "today_events")
    personal_events = personal_calendar_events(brief_input)
    tomorrow = read_map(calendar, "tomorrow_first_event")
    required_meetings = read_list(read_map(brief_input, "schedule_coverage"), "required_meetings")
    required_threads = read_list(read_map(brief_input, "commercial_coverage"), "required_threads")
    open_todos = fallback_ranked_todos(brief_input)
    commitment_lines = commitment_bucket_lines(brief_input)
    commitment_count = fallback_commitment_count(brief_input, commitment_lines)
    temperature_read = temperature_read_directive(brief_input)

    body =
      [
        temperature_read,
        fallback_needs_attention_section(
          brief_input,
          open_todos,
          personal_events,
          today_events,
          required_threads
        ),
        fallback_section(
          "Personal / Family First",
          personal_events
          |> Enum.take(6)
          |> Enum.map(&calendar_event_brief_line/1)
        ),
        fallback_section(
          "Today's Schedule",
          fallback_schedule_lines(required_meetings, today_events)
        ),
        fallback_section(
          "Active Follow-Ups",
          open_todos
          |> Enum.take(8)
          |> Enum.map(&fallback_todo_line/1)
        ),
        fallback_section("Open Commitments", commitment_lines),
        fallback_section(
          "Commercial Threads",
          required_threads
          |> Enum.take(8)
          |> Enum.map(&fallback_commercial_thread_line/1)
        ),
        fallback_lookahead_section(tomorrow, brief_input),
        fallback_section(
          "Source Gaps",
          brief_input
          |> source_gap_items()
          |> Enum.take(6)
          |> Enum.map(&source_gap_line/1)
        ),
        fallback_unknowns_note(),
        fallback_todays_move(
          open_todos,
          personal_events,
          today_events,
          commitment_lines,
          required_threads,
          brief_input
        )
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    %{
      "title" =>
        fallback_title(
          date,
          open_todos,
          personal_events,
          today_events,
          commitment_count,
          required_threads,
          brief_input
        ),
      "summary" =>
        fallback_summary(
          open_todos,
          personal_events,
          today_events,
          commitment_count,
          required_threads,
          brief_input
        ),
      "body" => body,
      "todos" => fallback_existing_todo_cards(open_todos),
      "linked_todo_ids" => fallback_existing_todo_ids(open_todos)
    }
  end

  defp source_backed_fallback_brief(_brief_input, error_message) do
    %{
      "title" => "Morning briefing",
      "summary" => "Core sources need a fresh pass before ranking the day.",
      "body" => fallback_no_source_body(error_message),
      "todos" => []
    }
  end

  defp fallback_summary(
         open_todos,
         personal_events,
         today_events,
         commitment_count,
         required_threads,
         brief_input
       ) do
    focus =
      [
        count_phrase(length(personal_events), "personal/family item", "personal/family items"),
        count_phrase(length(today_events), "calendar item", "calendar items"),
        count_phrase(commitment_count, "open commitment", "open commitments"),
        count_phrase(length(required_threads), "commercial thread", "commercial threads"),
        count_phrase(length(open_todos), "open follow-up", "open follow-ups")
      ]
      |> Enum.reject(&blank?/1)
      |> human_join()

    cond do
      not blank?(focus) ->
        "Start with #{focus}; anything absent here is unknown, not clear."

      weekend_brief?(brief_input) ->
        "Use today to check next week's meetings, family logistics, and unresolved decisions."

      true ->
        "No priority is ready to review; check calendar and open work before committing the day."
    end
  end

  defp fallback_title(
         date,
         open_todos,
         personal_events,
         today_events,
         commitment_count,
         required_threads,
         brief_input
       ) do
    day = fallback_day_label(date)

    read =
      cond do
        personal_events != [] ->
          "Personal logistics first, then work triage"

        calendar_conflicts(brief_input) != [] ->
          "Resolve the calendar conflict before work triage"

        commitment_count > 0 ->
          "Clear open commitments before inbox triage"

        required_threads != [] ->
          "Commercial threads need a decision"

        open_todos != [] ->
          "Clear checked follow-ups"

        today_events != [] ->
          "Prep the next calendar item before inbox"

        weekend_brief?(brief_input) ->
          "Prep the week before Monday starts"

        true ->
          "Verify the day before committing it"
      end

    "#{day} - #{read}"
  end

  defp fallback_day_label(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Calendar.strftime(parsed, "%A, %B %-d")
      _ -> "Morning briefing"
    end
  end

  defp fallback_day_label(_date), do: "Morning briefing"

  defp fallback_section(_title, []), do: nil

  defp fallback_section(title, lines) when is_binary(title) and is_list(lines) do
    lines =
      lines
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    if lines == [] do
      nil
    else
      "## #{title}\n" <> Enum.join(lines, "\n")
    end
  end

  defp fallback_needs_attention_section(
         brief_input,
         open_todos,
         personal_events,
         today_events,
         required_threads
       ) do
    lines =
      [
        personal_events
        |> Enum.take(1)
        |> Enum.map(&fallback_personal_attention_line/1),
        calendar_conflicts(brief_input)
        |> Enum.take(2)
        |> Enum.map(fn {left, right} ->
          "- **Schedule conflict**: #{calendar_event_short_label(left)} overlaps #{calendar_event_short_label(right)}. Pick one, move one, or leave the first early."
        end),
        commitment_attention_lines(brief_input, 2),
        action_stack_items(brief_input)
        |> Enum.take(1)
        |> Enum.map(fn item ->
          "- **Prepared action**: #{action_stack_item_label(item)}. Review or send it before inbox triage."
        end),
        required_threads
        |> Enum.take(1)
        |> Enum.map(&fallback_commercial_attention_line/1),
        open_todos
        |> Enum.take(2)
        |> Enum.map(&fallback_open_work_attention_line/1),
        today_events
        |> Enum.reject(&personal_calendar_event?/1)
        |> Enum.take(1)
        |> Enum.map(&fallback_schedule_attention_line/1)
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.take(6)

    lines =
      case lines do
        [] ->
          [
            "- **Start with checked priorities**: this brief only uses sources Maraithon could verify; review calendar and open work before inbox triage."
          ]

        lines ->
          lines
      end

    fallback_section("Needs Your Attention", lines)
  end

  defp fallback_personal_attention_line(event) when is_map(event) do
    "- **Personal / family first**: #{calendar_event_inline_label(event)}. Protect this before work triage."
  end

  defp fallback_personal_attention_line(_event), do: nil

  defp fallback_commercial_attention_line(thread) when is_map(thread) do
    subject = read_string(thread, "subject", "Commercial thread")
    from = read_string(thread, "from", nil)
    ask = read_string(thread, "body", nil) || read_string(thread, "snippet", nil)

    [
      "- **Commercial thread**: #{subject}",
      from && "from #{from}",
      ask && "- have guidance ready on #{truncate_prompt_string(ask, 180)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp fallback_commercial_attention_line(_thread), do: nil

  defp fallback_open_work_attention_line(todo) when is_map(todo) do
    title = read_string(todo, "title", "Open work item")
    action = read_string(todo, "next_action", nil) || read_string(todo, "summary", nil)

    [
      "- **Open follow-up**: #{title}",
      action && "- #{truncate_prompt_string(action, 180)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp fallback_open_work_attention_line(_todo), do: nil

  defp fallback_schedule_attention_line(event) when is_map(event) do
    "- **Next calendar item**: #{calendar_event_inline_label(event)}. Prep the decision or ask before joining."
  end

  defp fallback_schedule_attention_line(_event), do: nil

  defp calendar_event_inline_label(event) when is_map(event) do
    event
    |> calendar_event_brief_line()
    |> case do
      line when is_binary(line) ->
        line
        |> String.replace_prefix("- ", "")
        |> String.replace(~r/\*\*/, "")

      _ ->
        "Calendar event"
    end
  end

  defp calendar_event_inline_label(_event), do: "Calendar event"

  defp fallback_schedule_lines(required_meetings, today_events) do
    required_ids =
      required_meetings
      |> Enum.map(&calendar_event_identity/1)
      |> MapSet.new()

    required_lines =
      required_meetings
      |> Enum.map(&fallback_meeting_line/1)

    other_lines =
      today_events
      |> Enum.reject(&(calendar_event_identity(&1) in required_ids))
      |> Enum.take(10)
      |> Enum.map(&calendar_event_brief_line/1)

    required_lines ++ other_lines
  end

  defp fallback_meeting_line(meeting) when is_map(meeting) do
    summary = read_string(meeting, "summary", "Meeting")
    time = fallback_meeting_time(meeting)
    context = fallback_meeting_context(meeting)
    source_note = fallback_meeting_source_note(meeting)

    [
      "- **#{summary}**",
      time,
      context && "- Prep: #{context}",
      "Carry one decision: confirm the live ask, risk, owner, and next step before the call ends.",
      source_note && "Source: #{source_note}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp fallback_meeting_line(_meeting), do: nil

  defp fallback_meeting_time(meeting) do
    start = read_string(meeting, "display_start", nil)
    finish = read_string(meeting, "display_end", nil)

    cond do
      not blank?(start) and not blank?(finish) ->
        "at #{start} (ends #{finish})"

      not blank?(start) ->
        "at #{start}"

      true ->
        nil
    end
  end

  defp fallback_meeting_context(meeting) do
    crm_context =
      meeting
      |> read_list("crm_context")
      |> List.first()

    person = read_map(crm_context || %{}, "person")
    person_name = read_string(person, "display_name", nil)

    relationship =
      read_string(person, "relationship", nil) ||
        read_string(person, "notes", nil) ||
        read_string(meeting, "briefing_reason", nil)

    cond do
      not blank?(person_name) and not blank?(relationship) ->
        "#{person_name}: #{truncate_prompt_string(relationship, 180)}."

      not blank?(relationship) ->
        "#{truncate_prompt_string(relationship, 180)}."

      true ->
        meeting
        |> read_list("external_attendees")
        |> Enum.map(&fallback_attendee_label/1)
        |> Enum.reject(&blank?/1)
        |> Enum.take(3)
        |> case do
          [] ->
            "Prep context is thin; check relationship context and source notes before the call."

          attendees ->
            "External attendees: #{Enum.join(attendees, ", ")}."
        end
    end
  end

  defp fallback_meeting_source_note(meeting) do
    cond do
      read_list(meeting, "crm_context") != [] ->
        "saved relationship context."

      meeting_has_web_page_context?(meeting) ->
        "public source pages only; use cautiously."

      read_list(meeting, "web_context") != [] ->
        "public search snippets only; use cautiously."

      data_gap = first_meeting_data_gap(meeting) ->
        truncate_prompt_string(data_gap, 180)

      read_list(meeting, "external_attendees") != [] ->
        "calendar attendees only; avoid inventing background."

      true ->
        nil
    end
  end

  defp meeting_has_web_page_context?(meeting) do
    meeting
    |> read_list("web_context")
    |> Enum.any?(fn context ->
      context
      |> read_list("page_contexts")
      |> Enum.any?()
    end)
  end

  defp first_meeting_data_gap(meeting) do
    meeting
    |> read_list("data_gaps")
    |> Enum.find(&is_binary/1)
  end

  defp fallback_attendee_label(attendee) when is_map(attendee) do
    read_string(attendee, "display_name", nil) ||
      read_string(attendee, "name", nil) ||
      read_string(attendee, "email", nil)
  end

  defp fallback_attendee_label(value) when is_binary(value), do: value
  defp fallback_attendee_label(_value), do: nil

  defp fallback_ranked_todos(brief_input) do
    open_work = read_map(brief_input, "open_work")

    open_work
    |> read_list("todos")
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&fallback_todo_sort_key/1)
  end

  defp fallback_todo_sort_key(todo) when is_map(todo) do
    personal_rank = if fallback_personal_todo?(todo), do: 0, else: 1
    priority = read_integer(todo, "priority", 0)
    {personal_rank, -priority, read_string(todo, "title", "")}
  end

  defp fallback_personal_todo?(todo) when is_map(todo) do
    text =
      [
        read_string(todo, "kind", nil),
        read_string(todo, "title", nil),
        read_string(todo, "summary", nil),
        read_string(todo, "next_action", nil)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(@personal_calendar_terms, &String.contains?(text, &1))
  end

  defp fallback_todo_line(todo) when is_map(todo) do
    title = read_string(todo, "title", "Open work item")
    summary = read_string(todo, "summary", nil) || read_string(todo, "next_action", nil)

    if blank?(summary) do
      "- **#{title}**"
    else
      "- **#{title}**: #{truncate_prompt_string(summary, 220)}"
    end
  end

  defp fallback_todo_line(_todo), do: nil

  defp fallback_commercial_thread_line(thread) when is_map(thread) do
    subject = read_string(thread, "subject", "Commercial thread")
    from = read_string(thread, "from", nil)
    snippet = read_string(thread, "body", nil) || read_string(thread, "snippet", nil)

    [
      "- **#{subject}**",
      from && "from #{from}",
      snippet && ": #{truncate_prompt_string(snippet, 220)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp fallback_commercial_thread_line(_thread), do: nil

  defp fallback_lookahead_section(tomorrow, brief_input) do
    line =
      cond do
        is_map(tomorrow) and map_size(tomorrow) > 0 ->
          "Tomorrow's first calendar item: " <>
            (tomorrow
             |> calendar_event_brief_line()
             |> String.replace_prefix("- ", ""))

        weekend_brief?(brief_input) ->
          "Use today to prep next week's meetings, family logistics, and open decisions before Monday starts."

        true ->
          nil
      end

    fallback_section("Look Ahead", [line])
  end

  defp fallback_unknowns_note do
    fallback_section("Unknowns", [
      "Only checked data is included here. If a section is missing, treat it as unverified, not clear."
    ])
  end

  defp fallback_no_source_body(_error_message) do
    """
    Core sources were not verified for this briefing. Do not assume the day is clear.

    ## Needs Your Attention
    - Verify calendar, open work, inbox, Slack, and local sources before ranking the day.

    ## Unknowns
    Calendar, open work, inbox, Slack, and local sources still need a fresh pass before this can be treated as a real daily read.

    Today's move: verify the day before committing to lower-priority work.
    """
    |> String.trim()
  end

  defp fallback_todays_move(
         open_todos,
         personal_events,
         today_events,
         commitment_lines,
         required_threads,
         brief_input
       ) do
    line =
      cond do
        personal_events != [] ->
          "Today's move: handle the first personal/family item before work triage."

        commitment_lines != [] ->
          "Today's move: clear or explicitly keep the first open commitment before inbox triage."

        required_threads != [] ->
          "Today's move: decide which commercial thread needs your reply before inbox triage."

        open_todos != [] ->
          "Today's move: clear or explicitly keep the first open follow-up before inbox triage."

        today_events != [] ->
          "Today's move: review the next calendar item and prep the decision or ask before the meeting."

        weekend_brief?(brief_input) ->
          "Today's move: prep next week's meetings and family logistics before Monday starts."

        true ->
          "Today's move: verify calendar and open work before committing the day."
      end

    line
  end

  defp fallback_commitment_count(brief_input, commitment_lines) do
    commitments = read_map(brief_input, "commitments")

    case read_integer(commitments, "active_count", 0) do
      count when count > 0 -> count
      _ -> Enum.count(commitment_lines, &String.starts_with?(&1, "- "))
    end
  end

  defp count_phrase(0, _singular, _plural), do: nil
  defp count_phrase(1, singular, _plural), do: "1 #{singular}"
  defp count_phrase(count, _singular, plural), do: "#{count} #{plural}"

  defp human_join([]), do: nil
  defp human_join([item]), do: item
  defp human_join([first, second]), do: "#{first} and #{second}"

  defp human_join(items) do
    {last, rest} = List.pop_at(items, -1)
    Enum.join(rest, ", ") <> ", and " <> last
  end

  defp fallback_existing_todo_ids(open_todos) when is_list(open_todos) do
    open_todos
    |> Enum.map(&read_string(&1, "id", nil))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp fallback_existing_todo_ids(_open_todos), do: []

  defp fallback_existing_todo_cards(open_todos) when is_list(open_todos) do
    open_todos
    |> Enum.map(&fallback_existing_todo_card/1)
    |> Enum.reject(&map_empty?/1)
    |> Enum.take(10)
  end

  defp fallback_existing_todo_cards(_open_todos), do: []

  defp fallback_existing_todo_card(todo) when is_map(todo) do
    %{}
    |> maybe_put_public_todo_field("id", read_string(todo, "id", nil))
    |> maybe_put_public_todo_field("source", read_string(todo, "source", nil))
    |> maybe_put_public_todo_field("kind", read_string(todo, "kind", nil))
    |> maybe_put_public_todo_field("attention_mode", read_string(todo, "attention_mode", nil))
    |> maybe_put_public_todo_field("title", read_string(todo, "title", nil))
    |> maybe_put_public_todo_field("summary", read_string(todo, "summary", nil))
    |> maybe_put_public_todo_field("next_action", read_string(todo, "next_action", nil))
    |> maybe_put_public_todo_field("source_item_id", read_string(todo, "source_item_id", nil))
    |> maybe_put_public_todo_field("dedupe_key", read_string(todo, "dedupe_key", nil))
    |> maybe_put_public_todo_field("priority", read_integer(todo, "priority", 0))
    |> maybe_put_public_todo_field("due_at", read_string(todo, "due_at", nil))
    |> maybe_put_public_todo_field(
      "source_occurred_at",
      read_string(todo, "source_occurred_at", nil)
    )
  end

  defp fallback_existing_todo_card(_todo), do: %{}

  defp maybe_put_public_todo_field(map, _key, nil), do: map
  defp maybe_put_public_todo_field(map, _key, ""), do: map
  defp maybe_put_public_todo_field(map, _key, 0), do: map
  defp maybe_put_public_todo_field(map, key, value), do: Map.put(map, key, value)

  defp map_empty?(map) when is_map(map), do: map_size(map) == 0
  defp map_empty?(_value), do: true

  @doc """
  Scores and revises a model-produced morning brief against the Chief of Staff
  quality contract used in production delivery.
  """
  def verify_quality(brief, brief_input, generation_mode \\ "llm")
      when is_map(brief) and is_map(brief_input) do
    initial_findings = morning_brief_findings(brief, brief_input, generation_mode)

    revised_brief =
      brief
      |> revise_morning_brief(brief_input, initial_findings)
      |> scrub_morning_brief_internal_handles()

    final_findings = morning_brief_findings(revised_brief, brief_input, generation_mode)
    score = morning_brief_score(final_findings)

    verification = %{
      "status" => if(score == 10, do: "10/10", else: "needs_review"),
      "score" => score,
      "initial_findings" => Enum.map(initial_findings, &Atom.to_string/1),
      "final_findings" => Enum.map(final_findings, &Atom.to_string/1),
      "criteria" => [
        "body_opens_with_temperature_read",
        "personal_and_family_first",
        "newest_and_highest_priority_first",
        "active_waiting_business_objectives_before_intros_and_meetings",
        "stale_work_framed_as_decision_not_urgent_dump",
        "person_company_relationship_context_for_non-obvious_people",
        "required_external_meetings_are_covered",
        "required_commercial_threads_are_covered",
        "scoped_inbox_triage_covers_body_backed_actionable_email",
        "scoped_slack_triage_covers_actionable_threads",
        "brief_uses_executive_voice_without_first_person_assistant_framing",
        "schedule_conflicts_called_out_with_recommendations",
        "open_commitments_bucketed_by_overdue_due_today_and_coming_up",
        "prepared_actions_are_named_without_internal_handles",
        "model_todo_next_actions_visible_in_primary_brief",
        "non_draft_dashboard_payment_review_and_decision_jobs_separated",
        "source_gaps_are_visible_when_connectors_are_stale_or_unavailable",
        "weather_for_operator_location_present_when_available",
        "top_headlines_selected_for_operator_when_news_available",
        "brief_ends_with_today_move_directive",
        "structured_open_work_available_behind_review_button_and_sent_one_at_a_time"
      ]
    }

    {revised_brief, verification}
  end

  defp verify_and_revise_morning_brief(brief, brief_input, generation_mode) do
    verify_quality(brief, brief_input, generation_mode)
  end

  defp morning_brief_findings(brief, brief_input, generation_mode) do
    body = read_string(brief, "body", "")
    todos = read_list(brief, "todos")
    personal_events = personal_calendar_events(brief_input)
    calendar_conflicts = calendar_conflicts(brief_input)
    action_stack_items = action_stack_items(brief_input)
    non_draft_items = non_draft_job_items(brief_input)
    inbox_triage_items = inbox_triage_items(brief_input)
    slack_triage_items = slack_triage_items(brief_input)
    source_gap_items = source_gap_items(brief_input)
    missing_required_meetings = missing_required_schedule_meetings(body, brief_input)
    missing_required_threads = missing_required_commercial_threads(body, brief_input)

    []
    |> maybe_finding(blank?(body), :missing_body)
    |> maybe_finding(
      generation_mode == "llm" and not body_temperature_read_present?(body),
      :missing_temperature_read
    )
    |> maybe_finding(
      generation_mode == "llm" and not needs_attention_present?(body),
      :missing_needs_attention
    )
    |> maybe_finding(
      generation_mode == "llm" and personal_events != [] and
        not body_mentions_any_event?(body, personal_events),
      :missing_personal_calendar_context
    )
    |> maybe_finding(
      generation_mode == "llm" and weekend_brief?(brief_input) and
        not week_prep_present?(body),
      :missing_week_prep
    )
    |> maybe_finding(
      generation_mode == "llm" and missing_required_meetings != [],
      :missing_required_meetings
    )
    |> maybe_finding(
      generation_mode == "llm" and missing_required_threads != [],
      :missing_required_commercial_threads
    )
    |> maybe_finding(
      generation_mode == "llm" and inbox_triage_items != [] and
        not inbox_triage_present?(body, inbox_triage_items),
      :missing_inbox_triage
    )
    |> maybe_finding(
      generation_mode == "llm" and slack_triage_items != [] and
        not slack_triage_present?(body, slack_triage_items),
      :missing_slack_triage
    )
    |> maybe_finding(
      generation_mode == "llm" and assistant_first_person_copy_present?(body),
      :assistant_first_person_copy
    )
    |> maybe_finding(
      generation_mode == "llm" and calendar_conflicts != [] and
        not schedule_conflict_present?(body),
      :missing_schedule_conflicts
    )
    |> maybe_finding(
      generation_mode == "llm" and commitments_present?(brief_input) and
        not open_commitments_present?(body),
      :missing_open_commitments
    )
    |> maybe_finding(
      generation_mode == "llm" and action_stack_items != [] and
        not action_stack_present?(body),
      :missing_action_stack
    )
    |> maybe_finding(
      generation_mode == "llm" and model_todo_next_action_lines(brief, body) != [],
      :missing_model_todo_next_actions
    )
    |> maybe_finding(
      generation_mode == "llm" and non_draft_items != [] and
        not non_draft_jobs_present?(body),
      :missing_non_draft_jobs
    )
    |> maybe_finding(
      generation_mode == "llm" and source_gap_items != [] and
        not source_gaps_present?(body, source_gap_items),
      :missing_source_gaps
    )
    |> maybe_finding(
      generation_mode == "llm" and weather_data_present?(brief_input) and
        not weather_present_in_body?(body),
      :missing_weather
    )
    |> maybe_finding(
      generation_mode == "llm" and brief_input_news_items(brief_input) != [] and
        not top_headlines_present?(body),
      :missing_top_headlines
    )
    |> maybe_finding(
      generation_mode == "llm" and not todays_move_final_directive_present?(body),
      :missing_today_move
    )
    |> maybe_finding(
      generation_mode == "llm" and Enum.any?(todos, &sparse_person_todo?/1),
      :sparse_person_todo_context
    )
    |> Enum.reverse()
  end

  defp revise_morning_brief(brief, brief_input, findings) do
    brief
    |> maybe_drop_sparse_person_todos(findings)
    |> maybe_prepend_model_todo_next_actions(findings)
    |> maybe_append_needs_attention(brief_input, findings)
    |> maybe_append_personal_calendar_context(brief_input, findings)
    |> maybe_append_week_prep(brief_input, findings)
    |> maybe_append_required_meetings(brief_input, findings)
    |> maybe_append_required_commercial_threads(brief_input, findings)
    |> maybe_append_inbox_triage(brief_input, findings)
    |> maybe_append_slack_triage(brief_input, findings)
    |> maybe_append_schedule_conflicts(brief_input, findings)
    |> maybe_append_open_commitments(brief_input, findings)
    |> maybe_append_action_stack(brief_input, findings)
    |> maybe_append_non_draft_jobs(brief_input, findings)
    |> maybe_append_top_headlines(brief_input, findings)
    |> maybe_append_source_gaps(brief_input, findings)
    |> maybe_append_todays_move(brief_input, findings)
    |> maybe_scrub_assistant_first_person_copy(findings)
    |> maybe_prepend_weather(brief_input, findings)
    |> maybe_prepend_temperature_read(brief_input, findings)
  end

  defp maybe_prepend_weather(brief, brief_input, findings) do
    if :missing_weather in findings and
         not weather_present_in_body?(read_string(brief, "body", "")) do
      case weather_brief_line(brief_input) do
        nil -> brief
        line -> prepend_body_section(brief, line)
      end
    else
      brief
    end
  end

  defp maybe_append_top_headlines(brief, brief_input, findings) do
    if :missing_top_headlines in findings and
         not top_headlines_present?(read_string(brief, "body", "")) do
      lines =
        brief_input
        |> brief_input_news_items()
        |> Enum.take(3)
        |> Enum.map(&fallback_headline_line/1)
        |> Enum.reject(&blank?/1)

      case lines do
        [] ->
          brief

        lines ->
          append_body_section_before_today_move(
            brief,
            "## Top Headlines\n" <> Enum.join(lines, "\n")
          )
      end
    else
      brief
    end
  end

  defp fallback_headline_line(item) when is_map(item) do
    title = read_string(item, "title", nil)
    source = read_string(item, "source", nil)

    cond do
      blank?(title) -> nil
      blank?(source) -> "- **#{title}**"
      true -> "- **#{title}** (#{source})"
    end
  end

  defp fallback_headline_line(_item), do: nil

  defp weather_data_present?(brief_input) do
    weather = read_map(brief_input, "weather")

    not map_empty?(read_map(weather, "current")) or not map_empty?(read_map(weather, "today"))
  end

  defp weather_present_in_body?(body) when is_binary(body) do
    body =~ ~r/°|\bweather\b|\bdegrees\b/iu
  end

  defp weather_present_in_body?(_body), do: false

  defp weather_brief_line(brief_input) do
    weather = read_map(brief_input, "weather")
    current = read_map(weather, "current")
    today = read_map(weather, "today")
    location = read_string(weather, "location", nil)

    parts =
      [
        read_string(today, "conditions", nil) || read_string(current, "conditions", nil),
        format_temperature(Map.get(current, "temperature_c"), " now"),
        format_temperature_range(Map.get(today, "high_c"), Map.get(today, "low_c")),
        format_precipitation_chance(Map.get(today, "precipitation_chance_pct"))
      ]
      |> Enum.reject(&blank?/1)

    cond do
      parts == [] -> nil
      blank?(location) -> "Weather: #{Enum.join(parts, ", ")}."
      true -> "Weather (#{location}): #{Enum.join(parts, ", ")}."
    end
  end

  defp format_temperature(value, suffix) when is_number(value),
    do: "#{round(value)}°C#{suffix}"

  defp format_temperature(_value, _suffix), do: nil

  defp format_temperature_range(high, low) when is_number(high) and is_number(low),
    do: "high #{round(high)}° / low #{round(low)}°"

  defp format_temperature_range(high, _low) when is_number(high), do: "high #{round(high)}°"
  defp format_temperature_range(_high, low) when is_number(low), do: "low #{round(low)}°"
  defp format_temperature_range(_high, _low), do: nil

  defp format_precipitation_chance(value) when is_number(value) and value > 0,
    do: "#{round(value)}% chance of precipitation"

  defp format_precipitation_chance(_value), do: nil

  defp brief_input_news_items(brief_input) do
    brief_input
    |> read_map("news")
    |> read_list("items")
  end

  defp top_headlines_present?(body) when is_binary(body) do
    body =~ ~r/headline/i
  end

  defp top_headlines_present?(_body), do: false

  defp maybe_prepend_temperature_read(brief, brief_input, findings) do
    if :missing_temperature_read in findings and
         not body_temperature_read_present?(read_string(brief, "body", "")) do
      prepend_body_section(brief, temperature_read_directive(brief_input))
    else
      brief
    end
  end

  defp maybe_prepend_model_todo_next_actions(brief, findings) do
    if :missing_model_todo_next_actions in findings do
      body = read_string(brief, "body", "")
      lines = model_todo_next_action_lines(brief, body)

      if lines == [] do
        brief
      else
        heading =
          if needs_attention_present?(body),
            do: "## Next Actions",
            else: "## Needs Your Attention"

        prepend_body_section(brief, heading <> "\n" <> Enum.join(lines, "\n"))
      end
    else
      brief
    end
  end

  defp maybe_append_needs_attention(brief, brief_input, findings) do
    if :missing_needs_attention in findings and
         not needs_attention_present?(read_string(brief, "body", "")) do
      lines =
        [
          calendar_conflicts(brief_input)
          |> Enum.take(2)
          |> Enum.map(fn {left, right} ->
            "- **Schedule conflict**: #{calendar_event_short_label(left)} overlaps #{calendar_event_short_label(right)}. Pick one, move one, or leave the first early."
          end),
          commitment_attention_lines(brief_input, 2),
          action_stack_items(brief_input)
          |> Enum.take(2)
          |> Enum.map(fn item ->
            "- **Prepared action**: #{action_stack_item_label(item)}. Review or send it before inbox triage."
          end)
        ]
        |> List.flatten()
        |> Enum.reject(&blank?/1)

      lines =
        case lines do
          [] ->
            [
              "- **Start with checked priorities**: review the sections below before inbox triage."
            ]

          lines ->
            lines
        end

      append_body_section(brief, "## Needs Your Attention\n" <> Enum.join(lines, "\n"))
    else
      brief
    end
  end

  defp maybe_append_personal_calendar_context(brief, brief_input, findings) do
    if :missing_personal_calendar_context in findings do
      events =
        brief_input
        |> personal_calendar_events()
        |> Enum.take(3)
        |> Enum.map(&calendar_event_brief_line/1)
        |> Enum.reject(&blank?/1)

      append_body_section(brief, "## Personal / Family\n" <> Enum.join(events, "\n"))
    else
      brief
    end
  end

  defp maybe_append_week_prep(brief, brief_input, findings) do
    if :missing_week_prep in findings do
      tomorrow =
        brief_input
        |> get_in(["calendar", "tomorrow_first_event"])
        |> calendar_event_brief_line()

      line =
        if blank?(tomorrow) do
          "## Look Ahead\nUse the next prep block to review next week's meetings, family logistics, and open decisions before Monday starts."
        else
          "## Look Ahead\nTomorrow's first calendar item: #{tomorrow} Prep any family logistics and meeting notes before the week starts."
        end

      append_body_section(brief, line)
    else
      brief
    end
  end

  defp maybe_append_required_meetings(brief, brief_input, findings) do
    if :missing_required_meetings in findings do
      body = read_string(brief, "body", "")

      lines =
        body
        |> missing_required_schedule_meetings(brief_input)
        |> Enum.take(8)
        |> Enum.map(&fallback_meeting_line/1)
        |> Enum.reject(&blank?/1)

      if lines == [] do
        brief
      else
        append_body_section(brief, "## Required Schedule Prep\n" <> Enum.join(lines, "\n"))
      end
    else
      brief
    end
  end

  defp maybe_append_required_commercial_threads(brief, brief_input, findings) do
    if :missing_required_commercial_threads in findings do
      body = read_string(brief, "body", "")

      lines =
        body
        |> missing_required_commercial_threads(brief_input)
        |> Enum.take(8)
        |> Enum.map(&required_commercial_thread_line/1)
        |> Enum.reject(&blank?/1)

      if lines == [] do
        brief
      else
        append_body_section(brief, "## Decisions / Follow-ups\n" <> Enum.join(lines, "\n"))
      end
    else
      brief
    end
  end

  defp maybe_append_inbox_triage(brief, brief_input, findings) do
    if :missing_inbox_triage in findings do
      items = inbox_triage_items(brief_input)
      include_account? = inbox_triage_account_count(items) > 1

      lines =
        [
          inbox_triage_count_line(brief_input, items),
          items
          |> Enum.take(6)
          |> Enum.map(&inbox_triage_line(&1, include_account?))
        ]
        |> List.flatten()
        |> Enum.reject(&blank?/1)

      if lines == [] do
        brief
      else
        append_body_section(brief, "## Inbox Triage\n" <> Enum.join(lines, "\n"))
      end
    else
      brief
    end
  end

  defp maybe_append_slack_triage(brief, brief_input, findings) do
    if :missing_slack_triage in findings do
      items = slack_triage_items(brief_input)

      lines =
        [
          slack_triage_count_line(brief_input, items),
          items
          |> Enum.take(6)
          |> Enum.map(&slack_triage_line/1)
        ]
        |> List.flatten()
        |> Enum.reject(&blank?/1)

      if lines == [] do
        brief
      else
        append_body_section(brief, "## Slack Triage\n" <> Enum.join(lines, "\n"))
      end
    else
      brief
    end
  end

  defp maybe_append_schedule_conflicts(brief, brief_input, findings) do
    if :missing_schedule_conflicts in findings do
      conflicts =
        brief_input
        |> calendar_conflicts()
        |> Enum.take(5)
        |> Enum.map(fn {left, right} ->
          "- #{calendar_event_short_label(left)} overlaps #{calendar_event_short_label(right)}. Decide which to attend, move, or leave early."
        end)
        |> Enum.reject(&blank?/1)

      append_body_section(brief, "## Schedule Conflicts\n" <> Enum.join(conflicts, "\n"))
    else
      brief
    end
  end

  defp maybe_append_open_commitments(brief, brief_input, findings) do
    if :missing_open_commitments in findings do
      lines = commitment_bucket_lines(brief_input)

      if lines == [] do
        brief
      else
        append_body_section(brief, "## Open Commitments\n" <> Enum.join(lines, "\n"))
      end
    else
      brief
    end
  end

  defp maybe_append_action_stack(brief, brief_input, findings) do
    if :missing_action_stack in findings do
      lines =
        brief_input
        |> action_stack_items()
        |> Enum.take(8)
        |> Enum.map(fn item -> "- #{action_stack_item_label(item)}" end)
        |> Enum.reject(&blank?/1)

      append_body_section(brief, "## Prepared Actions\n" <> Enum.join(lines, "\n"))
    else
      brief
    end
  end

  defp maybe_append_non_draft_jobs(brief, brief_input, findings) do
    if :missing_non_draft_jobs in findings do
      lines =
        brief_input
        |> non_draft_job_items()
        |> Enum.take(8)
        |> Enum.map(fn item -> "- #{non_draft_job_label(item)}" end)
        |> Enum.reject(&blank?/1)

      append_body_section(brief, "## Manual Decisions / Admin\n" <> Enum.join(lines, "\n"))
    else
      brief
    end
  end

  defp maybe_append_source_gaps(brief, brief_input, findings) do
    if :missing_source_gaps in findings do
      lines =
        brief_input
        |> source_gap_items()
        |> Enum.take(6)
        |> Enum.map(&source_gap_line/1)
        |> Enum.reject(&blank?/1)

      if lines == [] do
        brief
      else
        append_body_section_before_today_move(
          brief,
          "## Source Gaps\n" <> Enum.join(lines, "\n")
        )
      end
    else
      brief
    end
  end

  defp maybe_append_todays_move(brief, brief_input, findings) do
    if :missing_today_move in findings and
         not todays_move_final_directive_present?(read_string(brief, "body", "")) do
      append_body_section(brief, todays_move_directive(brief_input))
    else
      brief
    end
  end

  defp maybe_scrub_assistant_first_person_copy(brief, findings) do
    if :assistant_first_person_copy in findings do
      Map.update(brief, "body", "", &scrub_assistant_first_person_copy/1)
    else
      brief
    end
  end

  defp todays_move_directive(brief_input) do
    cond do
      personal_calendar_events(brief_input) != [] ->
        "Today's move: protect the first personal/family commitment, then use the first desk block for checked work."

      calendar_conflicts(brief_input) != [] ->
        "Today's move: resolve the first calendar conflict before inbox triage."

      action_stack_items(brief_input) != [] ->
        "Today's move: review or send the prepared actions before inbox triage."

      commitments_present?(brief_input) ->
        "Today's move: clear or explicitly keep the first open commitment before inbox triage."

      inbox_triage_items(brief_input) != [] ->
        "Today's move: answer the most important email with a specific request before opening the rest of inbox."

      slack_triage_items(brief_input) != [] ->
        "Today's move: resolve the most important Slack request before passive channel scanning."

      weekend_brief?(brief_input) ->
        "Today's move: prep next week's meetings and family logistics before Monday starts."

      true ->
        "Today's move: use the first focused block to clear the most important checked item above before inbox triage."
    end
  end

  defp temperature_read_directive(brief_input) do
    cond do
      personal_calendar_events(brief_input) != [] ->
        "This is a personal-first day: protect the first family commitment, then clear checked work before inbox drift."

      calendar_conflicts(brief_input) != [] ->
        "This day has a calendar conflict: resolve the overlap before routine work."

      action_stack_items(brief_input) != [] ->
        "This is an execution-focused morning: clear the prepared actions before passive inbox triage."

      commitments_present?(brief_input) ->
        "The risk is follow-through: clear or explicitly keep the oldest open commitment before new work."

      inbox_triage_items(brief_input) != [] ->
        "The inbox has a specific request: answer the most important thread before clearing routine mail."

      slack_triage_items(brief_input) != [] ->
        "Slack has an active request: name the owner, decision, or next unblock step before passive channel scanning."

      source_gap_items(brief_input) != [] ->
        "Coverage is incomplete: use checked items, but treat missing source rows as unknown."

      weekend_brief?(brief_input) ->
        "This is a week-prep day: check meetings, family logistics, and unresolved decisions before Monday starts."

      true ->
        "This is a verification-first morning: scan calendar and open work before committing the day."
    end
  end

  defp maybe_drop_sparse_person_todos(brief, findings) do
    if :sparse_person_todo_context in findings do
      todos =
        brief
        |> read_list("todos")
        |> Enum.reject(&sparse_person_todo?/1)

      Map.put(brief, "todos", todos)
    else
      brief
    end
  end

  defp model_todo_next_action_lines(brief, body) when is_map(brief) and is_binary(body) do
    normalized_body = normalize_match_text(body)

    brief
    |> read_list("todos")
    |> Enum.filter(&is_map/1)
    |> Enum.map(&model_todo_next_action_line(&1, normalized_body))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&normalize_match_text/1)
    |> Enum.take(4)
  end

  defp model_todo_next_action_lines(_brief, _body), do: []

  defp model_todo_next_action_line(todo, normalized_body) when is_map(todo) do
    title =
      todo
      |> read_string("title", nil)
      |> scrub_internal_action_handles()
      |> truncate_text(120)

    next_action =
      todo
      |> read_string("next_action", nil)
      |> scrub_internal_action_handles()
      |> truncate_text(220)

    cond do
      blank?(title) or blank?(next_action) ->
        nil

      String.contains?(normalized_body, normalize_match_text(next_action)) ->
        nil

      true ->
        "- **#{title}**: #{next_action}"
    end
  end

  defp model_todo_next_action_line(_todo, _normalized_body), do: nil

  defp append_body_section(brief, section) when is_map(brief) and is_binary(section) do
    body = read_string(brief, "body", "")

    cond do
      blank?(section) or String.contains?(body, section) ->
        brief

      todays_move_final_directive_present?(body) and
          not todays_move_final_directive_present?(section) ->
        {before, today_move} = split_final_today_move(body)

        Map.put(
          brief,
          "body",
          [before, section, today_move]
          |> Enum.reject(&blank?/1)
          |> Enum.join("\n\n")
        )

      true ->
        Map.put(brief, "body", [body, section] |> Enum.reject(&blank?/1) |> Enum.join("\n\n"))
    end
  end

  defp append_body_section_before_today_move(brief, section)
       when is_map(brief) and is_binary(section) do
    body = read_string(brief, "body", "")

    cond do
      blank?(section) or String.contains?(body, section) ->
        brief

      todays_move_final_directive_present?(body) ->
        {before, today_move} = split_final_today_move(body)

        Map.put(
          brief,
          "body",
          [before, section, today_move]
          |> Enum.reject(&blank?/1)
          |> Enum.join("\n\n")
        )

      true ->
        append_body_section(brief, section)
    end
  end

  defp prepend_body_section(brief, section) when is_map(brief) and is_binary(section) do
    body = read_string(brief, "body", "")

    if blank?(section) or String.contains?(body, section) do
      brief
    else
      Map.put(brief, "body", [section, body] |> Enum.reject(&blank?/1) |> Enum.join("\n\n"))
    end
  end

  defp split_final_today_move(body) when is_binary(body) do
    lines = String.split(body, ~r/\R/u, trim: false)

    final_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, index} ->
        if blank?(line), do: nil, else: index
      end)

    if is_integer(final_index) do
      before =
        lines
        |> Enum.take(final_index)
        |> Enum.join("\n")
        |> String.trim()

      today_move =
        lines
        |> Enum.at(final_index, "")
        |> String.trim()

      {before, today_move}
    else
      {String.trim(body), ""}
    end
  end

  defp morning_brief_score([]), do: 10

  defp morning_brief_score(findings) do
    max(1, 10 - length(findings) * 2)
  end

  defp maybe_finding(findings, true, finding), do: [finding | findings]
  defp maybe_finding(findings, _condition, _finding), do: findings

  defp needs_attention_present?(body) when is_binary(body) do
    body
    |> normalize_match_text()
    |> String.contains?("needs your attention")
  end

  defp needs_attention_present?(_body), do: false

  defp body_temperature_read_present?(body) when is_binary(body) do
    body
    |> String.split(~r/\R/u, trim: true)
    |> Enum.find(&(not blank?(&1)))
    |> case do
      nil ->
        false

      first_line ->
        line = String.trim(first_line)

        not String.starts_with?(line, ["#", "-", "*", "•"]) and
          String.contains?(line, [".", ":", "—", "-"])
    end
  end

  defp body_temperature_read_present?(_body), do: false

  defp assistant_first_person_copy_present?(body) when is_binary(body) do
    body
    |> String.split(~r/\R/u)
    |> Enum.any?(&assistant_first_person_line?/1)
  end

  defp assistant_first_person_copy_present?(_body), do: false

  defp assistant_first_person_line?(line) when is_binary(line) do
    line = String.trim(line)

    not blank?(line) and narrative_brief_line?(line) and
      Regex.match?(
        ~r/\bI\s+(?:found|noticed|saw|think|recommend|would|can|can't|cannot|could not|couldn't|will|am|don't see|do not see)\b|\bI'm\s+seeing\b/i,
        line
      )
  end

  defp narrative_brief_line?(line) when is_binary(line) do
    not String.starts_with?(line, ["#", "-", "*", ">", "`", "\"", "'"])
  end

  defp scrub_assistant_first_person_copy(body) when is_binary(body) do
    body
    |> String.split(~r/\R/u, trim: false)
    |> Enum.map(&scrub_assistant_first_person_line/1)
    |> Enum.join("\n")
  end

  defp scrub_assistant_first_person_copy(body), do: body

  defp scrub_assistant_first_person_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    if narrative_brief_line?(trimmed) do
      line
      |> String.replace(~r/\bI\s+would\s+start\s+with\b/i, "Start with")
      |> String.replace(~r/\bI\s+(?:found|noticed|saw)\b/i, "The briefing shows")
      |> String.replace(~r/\bI\s+(?:think|recommend)\b/i, "Recommendation:")
      |> String.replace(~r/\bI\s+would\b/i, "Recommended move:")
      |> String.replace(
        ~r/\bI\s+(?:can't|cannot|could not|couldn't)\s+verify\b/i,
        "Could not verify"
      )
      |> String.replace(~r/\bI\s+(?:can't|cannot|could not|couldn't)\b/i, "Could not")
      |> String.replace(
        ~r/\bI\s+(?:don't|do not)\s+see\b/i,
        "Available context does not show"
      )
      |> String.replace(~r/\b(?:I\s+am|I'm)\s+seeing\b/i, "The briefing shows")
      |> String.replace(~r/\bI\s+am\b/i, "The read is")
      |> String.replace(~r/\bI\s+can\s+/i, "Available action: ")
      |> String.replace(~r/\bI\s+will\s+/i, "Maraithon will ")
    else
      line
    end
  end

  defp todays_move_final_directive_present?(body) when is_binary(body) do
    normalized =
      body
      |> String.split(~r/\R/u, trim: true)
      |> List.last()
      |> normalize_match_text()

    String.starts_with?(normalized, "today s move") or
      String.starts_with?(normalized, "todays move")
  end

  defp todays_move_final_directive_present?(_body), do: false

  defp source_gap_items(brief_input) when is_map(brief_input) do
    brief_input
    |> read_map("source_health")
    |> Enum.flat_map(fn {source_key, health} -> source_gap_item(source_key, health) end)
    |> Enum.uniq_by(& &1.source)
    |> Enum.sort_by(fn item -> {source_gap_priority(item.source), item.label} end)
  end

  defp source_gap_items(_brief_input), do: []

  defp source_gap_item(source_key, health) when is_map(health) do
    source =
      health
      |> read_string("source", nil)
      |> default_if_blank(to_string(source_key))

    status =
      health
      |> read_string("status", "")
      |> String.downcase()
      |> String.trim()

    if source_gap_status?(status) do
      [
        %{
          source: source,
          status: status,
          label: source_gap_label(source)
        }
      ]
    else
      []
    end
  end

  defp source_gap_item(_source_key, _health), do: []

  defp source_gap_status?(status)
       when status in ["stale", "error", "unavailable", "partial", "degraded"],
       do: true

  defp source_gap_status?(_status), do: false

  defp source_gaps_present?(body, items) when is_binary(body) and is_list(items) do
    normalized_body = normalize_match_text(body)

    caveat_present? =
      Enum.any?(
        [
          "source gap",
          "source gaps",
          "unknown",
          "unavailable",
          "not available",
          "stale",
          "could not be checked",
          "incomplete",
          "needs reconnection",
          "permission"
        ],
        &String.contains?(normalized_body, normalize_match_text(&1))
      )

    listed_sources_present? =
      items
      |> Enum.take(6)
      |> Enum.all?(fn item ->
        label = normalize_match_text(item.label)
        source = normalize_match_text(item.source)

        (label != "" and String.contains?(normalized_body, label)) or
          (source != "" and String.contains?(normalized_body, source))
      end)

    caveat_present? and listed_sources_present?
  end

  defp source_gaps_present?(_body, _items), do: false

  defp source_gap_line(%{label: label, source: source, status: status}) do
    subject = source_gap_subject(source)

    case status do
      "stale" ->
        "- **#{label}**: last check is stale, so #{subject} may be incomplete until the source syncs again."

      "error" ->
        "- **#{label}**: could not be checked for this brief; treat missing #{subject} as unknown."

      "unavailable" ->
        "- **#{label}**: needs reconnection or permission before it can be checked."

      "partial" ->
        "- **#{label}**: partially checked; use included #{subject}, but do not treat absent items as clear."

      "degraded" ->
        "- **#{label}**: partially checked; use included #{subject}, but do not treat absent items as clear."

      _ ->
        nil
    end
  end

  defp source_gap_line(_item), do: nil

  defp source_gap_label(source) do
    case normalize_match_text(source) do
      "imessage" ->
        "iMessage"

      "messages" ->
        "iMessage"

      "voice memos" ->
        "Voice Memos"

      "notes" ->
        "Notes"

      "calendar local" ->
        "Mac Calendar"

      "local calendar" ->
        "Mac Calendar"

      "calendar" ->
        "Google Calendar"

      "gmail" ->
        "Gmail"

      "google mail" ->
        "Gmail"

      "slack" ->
        "Slack"

      "files" ->
        "Files"

      "browser history" ->
        "Browser History"

      "reminders" ->
        "Reminders"

      normalized ->
        normalized |> String.split(" ", trim: true) |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp source_gap_subject(source) do
    case normalize_match_text(source) do
      "imessage" -> "messages"
      "messages" -> "messages"
      "voice memos" -> "voice memos"
      "notes" -> "notes"
      "calendar local" -> "calendar items"
      "local calendar" -> "calendar items"
      "calendar" -> "calendar items"
      "gmail" -> "email threads"
      "google mail" -> "email threads"
      "slack" -> "Slack threads"
      "files" -> "files"
      "browser history" -> "browser history"
      "reminders" -> "reminders"
      _ -> "items"
    end
  end

  defp source_gap_priority(source) do
    case normalize_match_text(source) do
      "imessage" -> 0
      "messages" -> 0
      "notes" -> 1
      "voice memos" -> 2
      "calendar local" -> 3
      "local calendar" -> 3
      "calendar" -> 4
      "gmail" -> 5
      "slack" -> 6
      "reminders" -> 7
      "files" -> 8
      "browser history" -> 9
      _ -> 99
    end
  end

  defp schedule_conflict_present?(body) when is_binary(body) do
    normalized = normalize_match_text(body)

    conflict_named? =
      Enum.any?(
        [
          "conflict",
          "conflicts",
          "overlap",
          "overlaps",
          "double booked"
        ],
        &String.contains?(normalized, &1)
      )

    recommendation_present? =
      Enum.any?(
        [
          "choose",
          "decide which",
          "decline",
          "drop",
          "leave early",
          "move one",
          "move the",
          "move this",
          "pick one",
          "push",
          "reschedule"
        ],
        &String.contains?(normalized, &1)
      )

    conflict_named? and recommendation_present?
  end

  defp schedule_conflict_present?(_body), do: false

  defp open_commitments_present?(body) when is_binary(body) do
    normalized = normalize_match_text(body)

    Enum.any?(
      ["open commitments", "overdue", "due today", "coming up", "omnifocus", "of id"],
      &String.contains?(normalized, &1)
    )
  end

  defp open_commitments_present?(_body), do: false

  defp action_stack_present?(body) when is_binary(body) do
    normalized = normalize_match_text(body)

    Enum.any?(
      [
        "prepared action",
        "prepared actions",
        "pending action",
        "pending actions",
        "action card",
        "card stack",
        "draft",
        "draft id",
        "queued"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp action_stack_present?(_body), do: false

  defp non_draft_jobs_present?(body) when is_binary(body) do
    normalized = normalize_match_text(body)

    Enum.any?(
      [
        "manual decisions",
        "manual decision",
        "manual admin",
        "admin work",
        "not a draft job",
        "non draft"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp non_draft_jobs_present?(_body), do: false

  defp inbox_triage_present?(body, items) when is_binary(body) and is_list(items) do
    normalized = normalize_match_text(body)

    section_present? =
      Enum.any?(["inbox triage", "gmail", "inbox", "email"], &String.contains?(normalized, &1))

    section_present? and
      Enum.any?(items, &body_mentions_coverage_item?(body, inbox_triage_labels(&1)))
  end

  defp inbox_triage_present?(_body, _items), do: false

  defp slack_triage_present?(body, items) when is_binary(body) and is_list(items) do
    normalized = normalize_match_text(body)

    section_present? =
      Enum.any?(["slack triage", "slack", "channel"], &String.contains?(normalized, &1)) or
        String.contains?(body, "#")

    section_present? and
      Enum.any?(items, &body_mentions_coverage_item?(body, slack_triage_labels(&1)))
  end

  defp slack_triage_present?(_body, _items), do: false

  defp inbox_triage_items(brief_input) when is_map(brief_input) do
    gmail = read_map(brief_input, "gmail")

    [
      read_list(gmail, "recent_unread"),
      read_list(gmail, "recent_inbox")
    ]
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&inbox_triage_item?/1)
    |> Enum.uniq_by(&inbox_triage_identity/1)
  end

  defp inbox_triage_items(_brief_input), do: []

  defp inbox_triage_item?(item) when is_map(item) do
    gmail_message_body_backed?(item) and
      triage_actionable_text?(gmail_triage_text(item))
  end

  defp inbox_triage_item?(_item), do: false

  defp gmail_message_body_backed?(item) when is_map(item) do
    body = read_string(item, "body", nil)
    body_status = read_string(item, "body_status", nil)

    body_available? =
      truthy?(read_any(item, "body_available")) or
        is_nil(body_status) or body_status in ["available", "available_truncated"]

    body_available? and not blank?(body)
  end

  defp gmail_message_body_backed?(_item), do: false

  defp gmail_triage_text(item) when is_map(item) do
    [
      read_string(item, "subject", nil),
      read_string(item, "body", nil),
      read_string(item, "snippet", nil)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp gmail_triage_text(_item), do: ""

  defp inbox_triage_identity(item) when is_map(item) do
    read_string(item, "thread_id", nil) ||
      read_string(item, "message_id", nil) ||
      [
        read_string(item, "subject", nil),
        read_string(item, "from", nil)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(":")
      |> normalize_match_text()
  end

  defp inbox_triage_identity(item), do: inspect(item)

  defp inbox_triage_labels(item) when is_map(item) do
    [
      read_string(item, "subject", nil),
      email_identity_labels(read_string(item, "from", nil)),
      read_string(item, "account", nil)
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
  end

  defp inbox_triage_labels(_item), do: []

  defp inbox_triage_account_count(items) when is_list(items) do
    items
    |> Enum.map(&read_string(&1, "account", nil))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&normalize_match_text/1)
    |> length()
  end

  defp inbox_triage_account_count(_items), do: 0

  defp inbox_triage_count_line(brief_input, items) do
    counts =
      brief_input
      |> read_map("gmail")
      |> read_map("counts")

    unread = read_integer(counts, "recent_unread", 0)
    accounts = inbox_triage_account_count(items)

    facts =
      [
        count_phrase(unread, "recent unread", "recent unread"),
        if(accounts > 1, do: count_phrase(accounts, "mailbox", "mailboxes"), else: nil)
      ]
      |> Enum.reject(&blank?/1)

    if facts == [] do
      nil
    else
      "- Scope: #{Enum.join(facts, " · ")}. Review the specific email items below before clearing routine email."
    end
  end

  defp inbox_triage_line(item, include_account?) when is_map(item) do
    subject = read_string(item, "subject", "Email thread") |> scrub_internal_action_handles()
    from = item |> read_string("from", nil) |> email_display_label()
    account = read_string(item, "account", nil)
    account_label = if include_account? and not blank?(account), do: "(#{account})"
    evidence = item |> message_evidence_text() |> scrub_internal_action_handles()
    action = triage_next_move(gmail_triage_text(item), :gmail)

    [
      "- **#{subject}**",
      from && "from #{from}",
      account_label,
      "- #{action}.",
      evidence && "Evidence: #{evidence}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp inbox_triage_line(_item, _include_account?), do: nil

  defp slack_triage_items(brief_input) when is_map(brief_input) do
    slack = read_map(brief_input, "slack")

    mention_items =
      slack
      |> read_list("mentions")
      |> Enum.filter(&slack_message_text_present?/1)

    thread_items =
      slack
      |> read_list("key_threads")
      |> Enum.filter(&slack_triage_thread_item?/1)

    (mention_items ++ thread_items)
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&slack_triage_identity/1)
  end

  defp slack_triage_items(_brief_input), do: []

  defp slack_message_text_present?(item) when is_map(item) do
    not blank?(slack_message_text(item))
  end

  defp slack_message_text_present?(_item), do: false

  defp slack_triage_thread_item?(item) when is_map(item) do
    slack_message_text_present?(item) and triage_actionable_text?(slack_message_text(item))
  end

  defp slack_triage_thread_item?(_item), do: false

  defp slack_message_text(item) when is_map(item) do
    [
      read_string(item, "text", nil),
      read_string(item, "summary", nil),
      read_string(item, "body", nil)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp slack_message_text(_item), do: ""

  defp slack_triage_identity(item) when is_map(item) do
    [
      read_string(item, "team_name", nil),
      read_string(item, "channel_id", nil) || read_string(item, "channel_name", nil),
      read_string(item, "thread_ts", nil) || read_string(item, "ts", nil),
      slack_message_text(item)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
    |> normalize_match_text()
  end

  defp slack_triage_identity(item), do: inspect(item)

  defp slack_triage_labels(item) when is_map(item) do
    [
      read_string(item, "channel_name", nil),
      read_string(item, "channel", nil),
      read_string(item, "team_name", nil),
      slack_message_text(item)
    ]
    |> Enum.reject(&blank?/1)
  end

  defp slack_triage_labels(_item), do: []

  defp slack_triage_count_line(brief_input, items) do
    counts =
      brief_input
      |> read_map("slack")
      |> read_map("counts")

    mentions = read_integer(counts, "mentions", 0)
    channel_count = slack_triage_channel_count(items)

    facts =
      [
        count_phrase(mentions, "mention", "mentions"),
        if(channel_count > 1, do: count_phrase(channel_count, "channel", "channels"), else: nil)
      ]
      |> Enum.reject(&blank?/1)

    if facts == [] do
      nil
    else
      "- Scope: #{Enum.join(facts, " · ")}. Items below need a reply, decision, or delegation."
    end
  end

  defp slack_triage_channel_count(items) when is_list(items) do
    items
    |> Enum.map(&(read_string(&1, "channel_name", nil) || read_string(&1, "channel", nil)))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&normalize_match_text/1)
    |> length()
  end

  defp slack_triage_channel_count(_items), do: 0

  defp slack_triage_line(item) when is_map(item) do
    channel = slack_channel_label(item)
    user = read_string(item, "user", nil)
    source_ref = slack_source_ref(item)
    evidence = item |> slack_message_text() |> truncate_prompt_string(180)
    action = triage_next_move(slack_message_text(item), :slack)

    [
      "- **#{channel}**",
      user && "from #{user}",
      source_ref && "(#{source_ref})",
      "- #{action}.",
      "Evidence: #{scrub_internal_action_handles(evidence)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp slack_triage_line(_item), do: nil

  defp slack_channel_label(item) when is_map(item) do
    channel =
      read_string(item, "channel_name", nil) ||
        read_string(item, "channel", nil) ||
        read_string(item, "channel_id", nil) ||
        "Slack thread"

    if String.starts_with?(channel, "#"), do: channel, else: "##{channel}"
  end

  defp slack_channel_label(_item), do: "#Slack thread"

  defp slack_source_ref(item) when is_map(item) do
    ts = read_string(item, "thread_ts", nil) || read_string(item, "ts", nil)
    if blank?(ts), do: nil, else: "ts #{ts}"
  end

  defp slack_source_ref(_item), do: nil

  defp triage_actionable_text?(text) when is_binary(text) do
    normalized = normalize_match_text(text)
    words = String.split(normalized, " ", trim: true)

    Enum.any?(@triage_action_terms, fn term ->
      normalized_term = normalize_match_text(term)

      cond do
        blank?(normalized_term) -> false
        String.contains?(normalized_term, " ") -> String.contains?(normalized, normalized_term)
        true -> normalized_term in words
      end
    end)
  end

  defp triage_actionable_text?(_text), do: false

  defp triage_next_move(text, :gmail) do
    normalized = normalize_match_text(text)

    cond do
      triage_any_term?(normalized, ["security", "login"]) ->
        "Confirm whether the security notice is expected, then secure the account or dismiss it"

      triage_any_term?(normalized, ["payment", "invoice"]) ->
        "Pay, update the card, or delegate the owner"

      triage_any_term?(normalized, ["pricing", "enterprise", "customer", "prospect", "contract"]) ->
        "Decide the commercial answer or owner before the thread goes stale"

      triage_any_term?(normalized, ["approval", "approve", "review", "sign", "signature"]) ->
        "Review and answer with approval, edits, or a clear owner"

      true ->
        "Decide whether to reply, delegate, or dismiss"
    end
  end

  defp triage_next_move(text, :slack) do
    normalized = normalize_match_text(text)

    cond do
      triage_any_term?(normalized, ["blocked", "bug", "outage"]) ->
        "Name the owner and the next unblock step"

      triage_any_term?(normalized, ["approval", "approve", "review", "decision"]) ->
        "Give the decision, approval, or edit path"

      triage_any_term?(normalized, ["customer", "prospect", "enterprise", "pricing"]) ->
        "Give guidance before the commercial thread drifts"

      true ->
        "Reply, delegate, or send the follow-through"
    end
  end

  defp triage_next_move(_text, _source),
    do: "Reply, delegate, or dismiss if this still needs attention"

  defp triage_any_term?(normalized, terms) when is_binary(normalized) and is_list(terms) do
    words = String.split(normalized, " ", trim: true)

    Enum.any?(terms, fn term ->
      normalized_term = normalize_match_text(term)

      if String.contains?(normalized_term, " ") do
        String.contains?(normalized, normalized_term)
      else
        normalized_term in words
      end
    end)
  end

  defp triage_any_term?(_normalized, _terms), do: false

  defp message_evidence_text(item) when is_map(item) do
    [
      read_string(item, "body", nil),
      read_string(item, "snippet", nil)
    ]
    |> Enum.find(&(not blank?(&1)))
    |> case do
      nil -> nil
      text -> truncate_prompt_string(text, 180)
    end
  end

  defp message_evidence_text(_item), do: nil

  defp email_display_label(value) when is_binary(value) do
    value
    |> email_identity_labels()
    |> List.first()
    |> case do
      nil ->
        value
        |> String.replace(~r/<[^>]+>/, "")
        |> String.trim()
        |> default_if_blank(nil)

      label ->
        label
    end
  end

  defp email_display_label(_value), do: nil

  defp calendar_conflicts(brief_input) when is_map(brief_input) do
    events =
      brief_input
      |> briefing_calendar_events()
      |> Enum.map(fn event -> {event, calendar_event_interval(event)} end)
      |> Enum.filter(fn {_event, interval} -> match?({%DateTime{}, %DateTime{}}, interval) end)
      |> Enum.sort_by(fn {_event, {start_at, _end_at}} -> DateTime.to_unix(start_at) end)

    for {{left, {left_start, left_end}}, left_index} <- Enum.with_index(events),
        {{right, {right_start, right_end}}, right_index} <- Enum.with_index(events),
        left_index < right_index,
        intervals_overlap?(left_start, left_end, right_start, right_end) do
      {left, right}
    end
  end

  defp calendar_conflicts(_brief_input), do: []

  defp briefing_calendar_events(brief_input) do
    calendar = read_map(brief_input, "calendar")
    schedule_coverage = read_map(brief_input, "schedule_coverage")
    meeting_prep = read_map(brief_input, "meeting_prep")

    [
      read_list(calendar, "today_events"),
      read_list(schedule_coverage, "required_meetings"),
      read_list(meeting_prep, "meetings")
    ]
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&calendar_event_identity/1)
  end

  defp calendar_event_interval(event) when is_map(event) do
    start_at = event_datetime(event, ["start", "start_at", "starts_at", "start_time"])
    end_at = event_datetime(event, ["end", "end_at", "ends_at", "end_time", "finish"])

    if match?(%DateTime{}, start_at) and match?(%DateTime{}, end_at) and
         DateTime.compare(start_at, end_at) == :lt do
      {start_at, end_at}
    else
      nil
    end
  end

  defp calendar_event_interval(_event), do: nil

  defp event_datetime(event, keys) when is_map(event) and is_list(keys) do
    keys
    |> Enum.map(&read_any(event, &1))
    |> Enum.find_value(&parse_event_datetime/1)
  end

  defp event_datetime(_event, _keys), do: nil

  defp parse_event_datetime(%DateTime{} = value), do: value

  defp parse_event_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp parse_event_datetime(%{"dateTime" => value}), do: parse_event_datetime(value)
  defp parse_event_datetime(%{"datetime" => value}), do: parse_event_datetime(value)
  defp parse_event_datetime(%{"value" => value}), do: parse_event_datetime(value)

  defp parse_event_datetime(value) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        datetime

      match?({:ok, _}, NaiveDateTime.from_iso8601(value)) ->
        {:ok, datetime} = NaiveDateTime.from_iso8601(value)
        DateTime.from_naive!(datetime, "Etc/UTC")

      true ->
        nil
    end
  end

  defp parse_event_datetime(_value), do: nil

  defp intervals_overlap?(left_start, left_end, right_start, right_end) do
    DateTime.compare(left_start, right_end) == :lt and
      DateTime.compare(left_end, right_start) == :gt
  end

  defp calendar_event_short_label(event) when is_map(event) do
    summary = read_string(event, "summary", nil) || read_string(event, "title", "Calendar event")
    start = read_string(event, "display_start", nil) || event_datetime_label(event, "start")
    finish = read_string(event, "display_end", nil) || event_datetime_label(event, "end")

    time =
      [start, finish]
      |> Enum.reject(&blank?/1)
      |> Enum.join("-")

    if blank?(time), do: summary, else: "#{time} #{summary}"
  end

  defp calendar_event_short_label(_event), do: "Calendar event"

  defp event_datetime_label(event, key) do
    event
    |> event_datetime([key])
    |> case do
      %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp commitments_present?(brief_input) when is_map(brief_input) do
    commitments = read_map(brief_input, "commitments")

    read_integer(commitments, "active_count", 0) > 0 or
      ["overdue", "due_today", "coming_up", "this_week", "no_deadline"]
      |> Enum.any?(&(read_list(commitments, &1) != []))
  end

  defp commitments_present?(_brief_input), do: false

  defp commitment_attention_lines(brief_input, limit) do
    commitments = read_map(brief_input, "commitments")

    ["overdue", "due_today"]
    |> Enum.flat_map(&(read_list(commitments, &1) |> Enum.take(limit)))
    |> Enum.take(limit)
    |> Enum.map(fn commitment ->
      "- **#{commitment_title(commitment)}**: #{commitment_context(commitment, brief_input)}"
    end)
  end

  defp commitment_bucket_lines(brief_input) do
    commitments = read_map(brief_input, "commitments")

    count_line =
      case read_integer(commitments, "active_count", 0) do
        active when active > 0 ->
          due_today = commitments |> read_list("due_today") |> length()
          overdue = commitments |> read_list("overdue") |> length()
          ["#{active} active", "#{due_today} due today", "#{overdue} overdue"] |> Enum.join(" · ")

        _ ->
          nil
      end

    bucket_lines =
      [
        {"Overdue", "overdue"},
        {"Due Today", "due_today"},
        {"Coming Up This Week", "coming_up"},
        {"Coming Up This Week", "this_week"},
        {"No Deadline", "no_deadline"}
      ]
      |> Enum.flat_map(fn {label, key} ->
        case read_list(commitments, key) do
          [] ->
            []

          items ->
            [
              "**#{label}**"
              | Enum.map(Enum.take(items, 8), &("- " <> commitment_line(&1, brief_input)))
            ]
        end
      end)

    [count_line | bucket_lines]
    |> Enum.reject(&blank?/1)
  end

  defp commitment_line(commitment, brief_input)

  defp commitment_line(commitment, brief_input) when is_map(commitment) do
    title = commitment_title(commitment)
    context = commitment_context(commitment, brief_input)

    [title, context]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp commitment_line(_commitment, _brief_input), do: nil

  defp commitment_title(commitment) when is_map(commitment) do
    read_string(commitment, "title", nil) ||
      read_string(commitment, "name", nil) ||
      "Open commitment"
  end

  defp commitment_title(_commitment), do: "Open commitment"

  defp commitment_context(commitment, brief_input \\ %{})

  defp commitment_context(commitment, brief_input) when is_map(commitment) do
    owed_to = read_string(commitment, "owed_to", nil) || read_string(commitment, "person", nil)
    project = read_string(commitment, "project", nil)
    due = commitment_due_label(commitment, brief_input)

    [owed_to && "for #{owed_to}", project && project, due]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp commitment_context(_commitment, _brief_input), do: nil

  defp commitment_due_label(commitment, brief_input)

  defp commitment_due_label(commitment, brief_input) when is_map(commitment) do
    display_due =
      read_string(commitment, "display_due", nil) ||
        read_string(commitment, "display_due_at", nil) ||
        read_string(commitment, "due_label", nil)

    due_value = read_any(commitment, "due_at") || read_any(commitment, "due")

    cond do
      not blank?(display_due) ->
        "due #{display_due}"

      is_nil(due_value) ->
        nil

      true ->
        due_value
        |> format_commitment_due(brief_input)
        |> then(fn due -> due && "due #{due}" end)
    end
  end

  defp commitment_due_label(_commitment, _brief_input), do: nil

  defp format_commitment_due(value, brief_input)

  defp format_commitment_due(%DateTime{} = value, brief_input) do
    offset = brief_input_timezone_offset_hours(brief_input)
    label = brief_input_timezone_label(brief_input, offset)

    value
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp format_commitment_due(%NaiveDateTime{} = value, _brief_input) do
    Calendar.strftime(value, "%b %d, %Y at %-I:%M %p")
  end

  defp format_commitment_due(%Date{} = value, _brief_input),
    do: Calendar.strftime(value, "%b %d, %Y")

  defp format_commitment_due(value, brief_input) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        format_commitment_due(datetime, brief_input)

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        format_commitment_due(date, brief_input)

      true ->
        value
    end
  end

  defp format_commitment_due(_value, _brief_input), do: nil

  defp brief_input_timezone_offset_hours(brief_input) when is_map(brief_input) do
    case read_any(brief_input, "timezone_offset_hours") do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _rest} -> parsed
          :error -> @default_timezone_offset_hours
        end

      _ ->
        @default_timezone_offset_hours
    end
  end

  defp brief_input_timezone_offset_hours(_brief_input), do: @default_timezone_offset_hours

  defp brief_input_timezone_label(brief_input, offset) when is_map(brief_input) do
    read_string(brief_input, "timezone", nil) || timezone_offset_label(offset)
  end

  defp brief_input_timezone_label(_brief_input, offset), do: timezone_offset_label(offset)

  defp action_stack_items(brief_input) when is_map(brief_input) do
    brief_input
    |> candidate_action_sources()
    |> Enum.filter(&action_stack_item?/1)
    |> Enum.uniq_by(&action_stack_item_identity/1)
  end

  defp action_stack_items(_brief_input), do: []

  defp candidate_action_sources(brief_input) do
    open_work = read_map(brief_input, "open_work")
    commitments = read_map(brief_input, "commitments")
    gmail = read_map(brief_input, "gmail")
    slack = read_map(brief_input, "slack")

    [
      read_list(open_work, "todos"),
      read_list(open_work, "insights"),
      read_list(commitments, "overdue"),
      read_list(commitments, "due_today"),
      read_list(commitments, "coming_up"),
      read_list(gmail, "recent_inbox"),
      read_list(gmail, "commercial_threads"),
      read_list(slack, "key_threads"),
      read_list(slack, "mentions")
    ]
    |> List.flatten()
    |> Enum.filter(&is_map/1)
  end

  defp action_stack_item?(item) when is_map(item) do
    text = inspect(item)

    Regex.match?(~r/\bactc_[A-Za-z0-9_-]+\b/i, text) or
      Regex.match?(~r/\bdraft[_ -]?(id)?\b/i, text) or
      Regex.match?(~r/\baction[_ -]?card\b/i, text) or
      has_any_key?(item, ["draft_id", "draftId", "action_card_id", "actionCardId"])
  end

  defp action_stack_item?(_item), do: false

  defp action_stack_item_identity(item) when is_map(item) do
    action_handle(item) ||
      read_string(item, "source_item_id", nil) ||
      read_string(item, "source_id", nil) ||
      read_string(item, "id", nil) ||
      normalize_match_text(action_stack_item_label(item))
  end

  defp action_stack_item_label(item) when is_map(item) do
    label =
      read_string(item, "title", nil) ||
        read_string(item, "name", nil) ||
        read_string(item, "subject", nil) ||
        read_string(item, "summary", nil) ||
        read_string(item, "text", nil) ||
        "Prepared action"

    context =
      read_string(item, "next_action", nil) ||
        read_string(item, "summary", nil) ||
        read_string(item, "notes", nil) ||
        read_string(read_map(item, "metadata"), "why_it_matters", nil) ||
        commitment_context(item)

    [label, context]
    |> Enum.map(&scrub_internal_action_handles/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&normalize_match_text/1)
    |> Enum.join(": ")
    |> default_if_blank("Prepared action")
    |> truncate_text(220)
  end

  defp action_stack_item_label(_item), do: "Prepared action"

  defp action_handle(item) when is_map(item) do
    metadata = read_map(item, "metadata")

    direct =
      ["action_card_id", "actionCardId", "draft_id", "draftId", "source_item_id"]
      |> Enum.find_value(fn key ->
        read_string(item, key, nil) || read_string(metadata, key, nil)
      end)

    direct || action_handle_from_text(inspect(item))
  end

  defp action_handle(_item), do: nil

  defp action_handle_from_text(text) when is_binary(text) do
    with [handle | _] <- Regex.run(~r/\bactc_[A-Za-z0-9_-]+\b/i, text) do
      handle
    else
      _ -> nil
    end
  end

  defp action_handle_from_text(_text), do: nil

  defp scrub_morning_brief_internal_handles(brief) when is_map(brief) do
    brief
    |> Map.update("body", "", &scrub_internal_action_handles/1)
    |> Map.update("body", "", &scrub_sensitive_brief_secrets/1)
    |> Map.update("summary", "", &scrub_sensitive_brief_secrets/1)
    |> Map.update("todos", [], &scrub_sensitive_brief_todos/1)
  end

  defp scrub_morning_brief_internal_handles(brief), do: brief

  defp scrub_internal_action_handles(value) when is_binary(value) do
    value
    |> String.replace(~r/^[ \t]*(?:[-*]\s*)?\bactc_[A-Za-z0-9_-]+\b[ \t]*$/im, "")
    |> String.replace(~r/[ \t]*->[ \t]*\bactc_[A-Za-z0-9_-]+\b/i, "")
    |> String.replace(~r/\bactc_[A-Za-z0-9_-]+\b/i, "")
    |> String.replace(~r/[ \t]+([.,;:])/, "\\1")
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp scrub_internal_action_handles(value), do: value

  # Never leave passwords / security answers / PINs in a user-facing brief,
  # even when the model copied them from source evidence.
  defp scrub_sensitive_brief_secrets(value) when is_binary(value) do
    value
    |> String.replace(
      ~r/\b(?:security\s+answer|password|passcode|pin)\s*(?:is|=|:)?\s*[`'\"]?[^`'\",.\n]+[`'\"]?/iu,
      "[credential removed — confirm in the source system]"
    )
    |> String.replace(
      ~r/\be-?transfer with the security answer\b[^.?\n]*/iu,
      "e-transfer (confirm security answer in the source system)"
    )
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.trim()
  end

  defp scrub_sensitive_brief_secrets(value), do: value

  defp scrub_sensitive_brief_todos(todos) when is_list(todos) do
    Enum.map(todos, fn
      todo when is_map(todo) ->
        todo
        |> Map.new(fn {key, value} -> {key, value} end)
        |> then(fn map ->
          Enum.reduce(["summary", "next_action", "notes", "action_plan", "title"], map, fn key,
                                                                                           acc ->
            case Map.get(acc, key) do
              value when is_binary(value) ->
                Map.put(acc, key, scrub_sensitive_brief_secrets(value))

              _ ->
                acc
            end
          end)
        end)

      other ->
        other
    end)
  end

  defp scrub_sensitive_brief_todos(todos), do: todos

  defp non_draft_job_items(brief_input) when is_map(brief_input) do
    brief_input
    |> candidate_non_draft_sources()
    |> Enum.filter(&non_draft_job_item?/1)
    |> Enum.uniq_by(&non_draft_job_identity/1)
  end

  defp non_draft_job_items(_brief_input), do: []

  defp candidate_non_draft_sources(brief_input) do
    open_work = read_map(brief_input, "open_work")
    commitments = read_map(brief_input, "commitments")

    [
      read_list(open_work, "todos"),
      read_list(open_work, "insights"),
      read_list(commitments, "overdue"),
      read_list(commitments, "due_today"),
      read_list(commitments, "coming_up")
    ]
    |> List.flatten()
    |> Enum.filter(&is_map/1)
  end

  defp non_draft_job_item?(item) when is_map(item) do
    metadata = read_map(item, "metadata")
    work_type = read_string(item, "work_type", nil) || read_string(metadata, "work_type", nil)

    work_type in ["dashboard", "payment", "review", "decision", "signature", "investigation"] or
      (not action_stack_item?(item) and non_draft_text?(item))
  end

  defp non_draft_job_item?(_item), do: false

  defp non_draft_text?(item) do
    text =
      item
      |> inspect()
      |> normalize_match_text()

    Enum.any?(
      [
        "payment",
        "pay ",
        "dashboard",
        "approve",
        "approval",
        "signature",
        "sign ",
        "review",
        "debug",
        "validate",
        "investigation",
        "decision",
        "stripe",
        "ramp"
      ],
      &String.contains?(text, &1)
    )
  end

  defp non_draft_job_identity(item) when is_map(item) do
    read_string(item, "source_item_id", nil) ||
      read_string(item, "source_id", nil) ||
      read_string(item, "id", nil) ||
      normalize_match_text(non_draft_job_label(item))
  end

  defp non_draft_job_label(item) when is_map(item) do
    label =
      read_string(item, "title", nil) ||
        read_string(item, "name", nil) ||
        read_string(item, "subject", nil) ||
        read_string(item, "summary", nil) ||
        "Manual decision or admin work"

    context =
      read_string(item, "next_action", nil) ||
        read_string(item, "notes", nil) ||
        read_string(read_map(item, "metadata"), "why_it_matters", nil)

    [label, context]
    |> Enum.reject(&blank?/1)
    |> Enum.join(": ")
    |> truncate_text(220)
  end

  defp non_draft_job_label(_item), do: "Manual decision or admin work"

  defp missing_required_schedule_meetings(body, brief_input)
       when is_binary(body) and is_map(brief_input) do
    brief_input
    |> required_schedule_meetings()
    |> Enum.reject(&required_schedule_meeting_covered?(body, &1))
  end

  defp missing_required_schedule_meetings(_body, _brief_input), do: []

  defp missing_required_commercial_threads(body, brief_input)
       when is_binary(body) and is_map(brief_input) do
    brief_input
    |> required_commercial_threads()
    |> Enum.reject(&body_mentions_coverage_item?(body, required_commercial_thread_labels(&1)))
  end

  defp missing_required_commercial_threads(_body, _brief_input), do: []

  defp required_schedule_meetings(brief_input) when is_map(brief_input) do
    brief_input
    |> read_map("schedule_coverage")
    |> read_list("required_meetings")
    |> Enum.filter(&is_map/1)
  end

  defp required_schedule_meetings(_brief_input), do: []

  defp required_commercial_threads(brief_input) when is_map(brief_input) do
    brief_input
    |> read_map("commercial_coverage")
    |> read_list("required_threads")
    |> Enum.filter(&is_map/1)
  end

  defp required_commercial_threads(_brief_input), do: []

  defp required_schedule_meeting_covered?(body, meeting)
       when is_binary(body) and is_map(meeting) do
    meeting_units = required_meeting_body_units(body, meeting)

    meeting_units != [] and
      required_meeting_time_covered?(meeting_units, meeting) and
      required_meeting_context_covered?(meeting_units, meeting)
  end

  defp required_schedule_meeting_covered?(_body, _meeting), do: false

  defp required_meeting_body_units(body, meeting) when is_binary(body) and is_map(meeting) do
    identity_labels = required_meeting_identity_labels(meeting)

    body
    |> String.split(~r/\R/u, trim: false)
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      if body_mentions_coverage_item?(line, identity_labels) do
        [meeting_line_window(body, index)]
      else
        []
      end
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp required_meeting_body_units(_body, _meeting), do: []

  defp meeting_line_window(body, index) when is_binary(body) and is_integer(index) do
    lines = String.split(body, ~r/\R/u, trim: false)
    start = max(index - 1, 0)

    lines
    |> Enum.slice(start, 3)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp required_meeting_identity_labels(meeting) when is_map(meeting) do
    [
      read_string(meeting, "summary", nil),
      meeting |> read_list("external_attendees") |> Enum.flat_map(&coverage_label_values/1),
      meeting
      |> read_list("candidate_people_and_orgs")
      |> Enum.flat_map(&coverage_label_values/1)
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
  end

  defp required_meeting_identity_labels(_meeting), do: []

  defp required_meeting_time_covered?(meeting_units, meeting)
       when is_list(meeting_units) and is_map(meeting) do
    labels =
      [
        read_string(meeting, "display_start", nil),
        read_string(meeting, "display_end", nil),
        read_string(meeting, "start", nil),
        read_string(meeting, "end", nil)
      ]
      |> Enum.reject(&blank?/1)

    labels == [] or Enum.any?(meeting_units, &body_mentions_coverage_item?(&1, labels))
  end

  defp required_meeting_time_covered?(_meeting_units, _meeting), do: false

  defp required_meeting_context_covered?(meeting_units, meeting)
       when is_list(meeting_units) and is_map(meeting) do
    context_labels = required_meeting_context_labels(meeting)

    Enum.any?(meeting_units, fn unit ->
      if context_labels == [] do
        unit
        |> normalize_match_text()
        |> meeting_prep_language_present?()
      else
        body_mentions_coverage_item?(unit, context_labels)
      end
    end)
  end

  defp required_meeting_context_covered?(_meeting_units, _meeting), do: false

  defp meeting_prep_language_present?(normalized_body) when is_binary(normalized_body) do
    words =
      normalized_body
      |> String.split(" ", trim: true)
      |> MapSet.new()

    Enum.any?(@meeting_prep_terms, fn term ->
      normalized_term = normalize_match_text(term)

      if String.contains?(normalized_term, " ") do
        String.contains?(normalized_body, normalized_term)
      else
        MapSet.member?(words, normalized_term)
      end
    end)
  end

  defp meeting_prep_language_present?(_normalized_body), do: false

  defp required_meeting_context_labels(meeting) when is_map(meeting) do
    [
      read_string(meeting, "briefing_reason", nil),
      read_string(meeting, "briefing_priority", nil),
      meeting |> read_list("crm_context") |> Enum.flat_map(&meeting_context_label_values/1),
      meeting |> read_list("web_context") |> Enum.flat_map(&meeting_context_label_values/1),
      meeting |> read_list("data_gaps") |> Enum.flat_map(&meeting_context_label_values/1)
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
  end

  defp required_meeting_context_labels(_meeting), do: []

  defp meeting_context_label_values(value) when is_binary(value), do: [value]

  defp meeting_context_label_values(value) when is_map(value) do
    nested =
      ["person", "organization", "company", "account", "profile"]
      |> Enum.flat_map(fn key -> meeting_context_label_values(read_any(value, key)) end)

    direct =
      [
        "relationship",
        "notes",
        "summary",
        "description",
        "snippet",
        "title",
        "company",
        "organization",
        "domain"
      ]
      |> Enum.map(&read_string(value, &1, nil))

    direct ++ nested
  end

  defp meeting_context_label_values(value) when is_list(value),
    do: Enum.flat_map(value, &meeting_context_label_values/1)

  defp meeting_context_label_values(_value), do: []

  defp required_commercial_thread_labels(thread) when is_map(thread) do
    [
      read_string(thread, "subject", nil),
      email_identity_labels(read_string(thread, "from", nil)),
      email_identity_labels(read_string(thread, "to", nil))
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
  end

  defp required_commercial_thread_labels(_thread), do: []

  defp body_mentions_coverage_item?(body, labels) when is_binary(body) and is_list(labels) do
    normalized_body = normalize_match_text(body)

    labels
    |> Enum.uniq()
    |> Enum.any?(&coverage_label_present?(normalized_body, &1))
  end

  defp body_mentions_coverage_item?(_body, _labels), do: false

  defp coverage_label_present?(normalized_body, label)
       when is_binary(normalized_body) and is_binary(label) do
    normalized_label = normalize_match_text(label)
    words = important_words(label)

    cond do
      blank?(normalized_label) ->
        false

      String.length(normalized_label) >= 6 and String.contains?(normalized_body, normalized_label) ->
        true

      length(words) >= 2 ->
        Enum.count(words, &String.contains?(normalized_body, &1)) >= 2

      match?([_word], words) ->
        [word] = words
        String.contains?(normalized_body, word)

      true ->
        false
    end
  end

  defp coverage_label_present?(_normalized_body, _label), do: false

  defp coverage_label_values(value) when is_binary(value), do: [value]

  defp coverage_label_values(value) when is_map(value) do
    nested =
      ["person", "organization", "company", "account", "profile"]
      |> Enum.flat_map(fn key -> coverage_label_values(read_any(value, key)) end)

    direct =
      [
        "display_name",
        "name",
        "email",
        "company",
        "organization",
        "domain",
        "title",
        "summary",
        "relationship",
        "notes"
      ]
      |> Enum.map(&read_string(value, &1, nil))

    direct ++ nested
  end

  defp coverage_label_values(value) when is_list(value),
    do: Enum.flat_map(value, &coverage_label_values/1)

  defp coverage_label_values(_value), do: []

  defp email_identity_labels(nil), do: []

  defp email_identity_labels(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      display =
        part
        |> String.replace(~r/<[^>]+>/, "")
        |> String.trim()

      cond do
        display != "" and not String.contains?(display, "@") ->
          [display]

        true ->
          ~r/@([A-Za-z0-9.-]+)/
          |> Regex.scan(part)
          |> Enum.map(fn [_match, domain] -> domain_label(domain) end)
      end
    end)
  end

  defp email_identity_labels(_value), do: []

  defp domain_label(domain) when is_binary(domain) do
    domain
    |> String.split(".")
    |> Enum.reject(&(&1 in ["com", "co", "io", "ai", "net", "org"]))
    |> Enum.join(" ")
  end

  defp required_commercial_thread_line(thread) when is_map(thread) do
    subject = read_string(thread, "subject", "Commercial thread")
    from = read_string(thread, "from", nil)
    ask = read_string(thread, "body", nil) || read_string(thread, "snippet", nil)

    [
      "- **#{subject}**",
      from && "from #{from}",
      ask && "- have guidance ready on: #{truncate_prompt_string(ask, 220)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp required_commercial_thread_line(_thread), do: nil

  defp has_any_key?(map, keys) when is_map(map) and is_list(keys) do
    Enum.any?(keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, to_existing_atom(key))
    end)
  end

  defp has_any_key?(_map, _keys), do: false

  defp personal_calendar_events(brief_input) when is_map(brief_input) do
    calendar = read_map(brief_input, "calendar")

    [
      read_list(calendar, "today_events"),
      read_list(calendar, "upcoming_local"),
      case read_map(calendar, "tomorrow_first_event") do
        event when event == %{} -> []
        event -> [event]
      end
    ]
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&calendar_event_identity/1)
    |> Enum.filter(&personal_calendar_event?/1)
  end

  defp personal_calendar_events(_brief_input), do: []

  defp personal_calendar_event?(event) when is_map(event) do
    text =
      [
        read_string(event, "summary", nil),
        read_string(event, "calendar_name", nil),
        read_string(event, "location", nil),
        event
        |> read_list("attendees")
        |> Enum.map(&attendee_match_text/1)
        |> Enum.reject(&blank?/1)
        |> Enum.join(" ")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(@personal_calendar_terms, &String.contains?(text, &1))
  end

  defp personal_calendar_event?(_event), do: false

  defp attendee_match_text(%{} = attendee) do
    [
      read_string(attendee, "display_name", nil),
      read_string(attendee, "email", nil)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp attendee_match_text(value) when is_binary(value), do: value
  defp attendee_match_text(_value), do: nil

  defp body_mentions_any_event?(body, events) when is_binary(body) and is_list(events) do
    normalized_body = normalize_match_text(body)

    Enum.any?(events, fn event ->
      event
      |> read_string("summary", "")
      |> normalize_match_text()
      |> important_words()
      |> Enum.any?(&String.contains?(normalized_body, &1))
    end)
  end

  defp week_prep_present?(body) when is_binary(body) do
    normalized = String.downcase(body)

    String.contains?(normalized, "look ahead") or
      String.contains?(normalized, "next week") or
      String.contains?(normalized, "week prep") or
      String.contains?(normalized, "monday") or
      String.contains?(normalized, "tomorrow")
  end

  defp week_prep_present?(_body), do: false

  defp weekend_brief?(brief_input) do
    with date when is_binary(date) <- read_string(brief_input, "date", nil),
         {:ok, parsed} <- Date.from_iso8601(date) do
      Date.day_of_week(parsed) in [6, 7]
    else
      _ -> false
    end
  end

  defp sparse_person_todo?(todo) when is_map(todo) do
    title = read_string(todo, "title", "")
    summary = read_string(todo, "summary", "")
    next_action = read_string(todo, "next_action", "")
    metadata = read_map(todo, "metadata")

    person_like? =
      Regex.match?(
        ~r/\b[A-Z][a-z]+ [A-Z][A-Za-z'-]+\b/u,
        [title, summary, next_action] |> Enum.join(" ")
      )

    context_text =
      [
        title,
        summary,
        next_action,
        read_string(metadata, "company", nil),
        read_string(metadata, "organization", nil),
        read_string(metadata, "relationship_context", nil),
        read_string(metadata, "why_it_matters", nil),
        read_string(metadata, "context", nil)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")

    person_like? and length(important_words(context_text)) < 8
  end

  defp sparse_person_todo?(_todo), do: false

  defp calendar_event_brief_line(event) when is_map(event) and map_size(event) > 0 do
    summary = read_string(event, "summary", "Calendar event")
    start = read_string(event, "display_start", nil) || read_string(event, "start", nil)
    date = read_string(event, "display_date", nil)
    calendar_name = read_string(event, "calendar_name", nil)

    [
      "- **#{summary}**",
      start && "at #{start}",
      date && "on #{date}",
      calendar_name && "(#{calendar_name})"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp calendar_event_brief_line(_event), do: nil

  defp calendar_event_identity(event) when is_map(event) do
    {
      normalize_match_text(read_string(event, "summary", "")),
      read_string(event, "start", nil) || read_string(event, "display_start", nil)
    }
  end

  defp normalize_match_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp normalize_match_text(_value), do: ""

  defp important_words(value) when is_binary(value) do
    value
    |> normalize_match_text()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(String.length(&1) < 4))
  end

  defp important_words(_value), do: []

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

  defp persist_model_todos(_user_id, %{"linked_todo_ids" => linked_todo_ids}, _brief_input) do
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

  defp persist_model_todos(_user_id, %{"todos" => []}, _brief_input), do: {:ok, :no_todos}
  defp persist_model_todos(nil, _brief, _brief_input), do: {:ok, :no_todos}

  defp persist_model_todos(user_id, %{"todos" => todos}, brief_input)
       when is_binary(user_id) and is_list(todos) do
    candidates =
      todos
      |> Enum.filter(&is_map/1)
      |> Enum.map(&morning_todo_candidate(&1, brief_input))

    case candidates do
      [] ->
        {:ok, :no_todos}

      candidates ->
        case read_string(brief_input, "todo_target_brief_dedupe_key", nil) do
          nil ->
            ingest_todos_with_retry(user_id, candidates,
              source: "chief_of_staff_morning_briefing",
              max_tokens: @default_llm_max_tokens,
              timeout_ms: 1_200_000,
              reasoning_effort: @default_llm_reasoning_effort
            )

          brief_dedupe_key ->
            Maraithon.Todos.DeferredIngestion.enqueue(user_id, candidates,
              source: "chief_of_staff_morning_briefing",
              brief_dedupe_key: brief_dedupe_key
            )
        end
    end
  end

  defp persist_model_todos(_user_id, _brief, _brief_input), do: {:ok, :no_todos}

  defp ingest_todos_with_retry(user_id, candidates, opts) do
    do_ingest_todos_with_retry(user_id, candidates, opts, [0 | @todo_ingest_retry_delays_ms], 1)
  end

  defp do_ingest_todos_with_retry(user_id, candidates, opts, [delay | remaining], attempt) do
    if delay > 0, do: Process.sleep(delay)

    case OpenLoops.ingest_todos(user_id, candidates, opts) do
      {:error, {:llm_busy, _retry_after_ms} = reason} when remaining != [] ->
        Logger.warning("morning_briefing todo persistence busy; retrying",
          attempt: attempt,
          failure_code: Maraithon.Redaction.error_class(reason),
          next_delay_ms: hd(remaining)
        )

        do_ingest_todos_with_retry(user_id, candidates, opts, remaining, attempt + 1)

      other ->
        case other do
          {:error, reason} ->
            fallback_persist_todos(user_id, candidates, reason)

          result ->
            result
        end
    end
  end

  defp fallback_persist_todos(user_id, candidates, reason) do
    Logger.warning(
      "morning_briefing todo LLM persistence failed; using direct checked upsert",
      failure_code: Maraithon.Redaction.error_class(reason),
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

  defp morning_todo_candidate(todo, brief_input) when is_map(todo) do
    metadata =
      todo
      |> read_map("metadata")
      |> Map.merge(%{
        "origin_skill_id" => id(),
        "origin_cadence" => "morning",
        "brief_date" => read_string(brief_input, "date", nil),
        "brief_generated_at" => read_string(brief_input, "generated_at", nil)
      })
      |> compact_map()

    todo
    |> stringify_top_level_keys()
    |> Map.put("metadata", metadata)
    |> Map.put_new("source_occurred_at", read_string(brief_input, "generated_at", nil))
  end

  defp todo_event_payload({:ok, :no_todos}) do
    %{todo_count: 0, todo_skipped_count: 0}
  end

  defp todo_event_payload({:ok, result}) when is_map(result) do
    todos = Map.get(result, :todos, [])

    %{
      todo_count: length(todos),
      todo_queued_count: Map.get(result, :queued_count, 0),
      todo_skipped_count: Map.get(result, :skipped_count, 0),
      todo_usage: Map.get(result, :usage, %{})
    }
  end

  defp todo_event_payload({:error, reason}) do
    %{
      todo_count: 0,
      todo_skipped_count: 0,
      todo_error: Maraithon.Redaction.error_summary(reason)
    }
  end

  defp delivery_event_payload({:ok, result}) when is_map(result) do
    %{
      status: "sent",
      chunks: Map.get(result, "chunks", 0),
      message_ids: Map.get(result, "message_ids", [])
    }
    |> maybe_put(:todo_review_brief_id, Map.get(result, "todo_review_brief_id"))
  end

  defp delivery_event_payload({:ok, :not_sent}), do: %{status: "not_sent"}

  defp delivery_event_payload({:error, reason}) do
    %{status: "error", error: Maraithon.Redaction.error_summary(reason)}
  end

  defp briefing_cost_summary(response, brief_input) do
    llm_usage = response_usage(response)
    web_searches = get_in(brief_input, ["meeting_prep", "counts", "web_searches"]) || 0
    web_search_cost = Spend.web_search_cost(web_searches)
    llm_cost = read_number(llm_usage, "total_cost", 0.0)
    total_cost = llm_cost + web_search_cost.total_cost

    %{
      pricing_source: "openai_api_pricing_2026_05_12",
      llm: llm_usage,
      web_search: web_search_cost,
      estimated_total_cost: Float.round(total_cost, 6)
    }
  end

  defp response_usage(response) do
    case read_map(response, "usage") do
      usage when map_size(usage) > 0 ->
        usage

      _empty ->
        model = read_string(response, "model", "unknown")
        tokens_in = read_integer(response, "tokens_in", 0)
        tokens_out = read_integer(response, "tokens_out", 0)
        Spend.calculate_cost(model, tokens_in, tokens_out)
    end
  end

  # SPEC 07 R1: builds the deep_memory recall query for the morning briefing
  # from the concrete content of this brief (date, today's calendar events,
  # commercial thread subjects) instead of a static relevance string.
  defp briefing_memory_query(local_date, today_events, commercial_threads) do
    [
      "morning briefing #{Date.to_iso8601(local_date)}",
      today_events
      |> Enum.map(&Map.get(&1, "summary"))
      |> Enum.reject(&blank?/1)
      |> Enum.take(6)
      |> Enum.join(" "),
      commercial_threads
      |> Enum.map(&Map.get(&1, "subject"))
      |> Enum.reject(&blank?/1)
      |> Enum.take(6)
      |> Enum.join(" ")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp json_metadata(value), do: Maraithon.Normalization.normalize_json_value(value)

  defp timed(fun) when is_function(fun, 0) do
    started_ms = System.monotonic_time(:millisecond)
    {fun.(), elapsed_since_ms(started_ms)}
  end

  defp elapsed_since_ms(started_ms) do
    System.monotonic_time(:millisecond) - started_ms
  end

  defp calendar_event_for_prompt(nil, _state), do: nil

  defp calendar_event_for_prompt(event, state) when is_map(event) do
    start_value = read_any(event, "start")
    end_value = read_any(event, "end")

    %{
      "event_id" => read_string(event, "event_id", nil),
      "summary" => read_string(event, "summary", "Untitled event"),
      "start" => prompt_time(start_value),
      "end" => prompt_time(end_value),
      "display_start" => display_time(start_value, state),
      "display_end" => display_time(end_value, state),
      "display_date" => display_date(start_value, state),
      "display_timezone" => timezone_label(state, datetime_from_value(start_value)),
      "location" => read_string(event, "location", nil),
      "attendees" => read_list(event, "attendees"),
      "organizer" => read_string(event, "organizer", nil),
      "html_link" => read_string(event, "html_link", nil),
      "calendar_name" => read_string(event, "calendar_name", nil),
      "is_all_day" => read_any(event, "is_all_day"),
      "source" => read_string(event, "source", nil)
    }
  end

  defp gmail_message_for_prompt(message) when is_map(message) do
    body =
      message
      |> gmail_body_for_prompt()
      |> truncate_prompt_string(@prompt_gmail_body_limit)

    body_available = body != ""

    %{
      "message_id" => read_string(message, "message_id", nil),
      "thread_id" => read_string(message, "thread_id", nil),
      "account" =>
        read_string(message, "account", read_string(message, "google_account_email", nil)),
      "from" => read_string(message, "from", nil),
      "to" => read_string(message, "to", nil),
      "subject" => read_string(message, "subject", "(no subject)"),
      "date" =>
        prompt_time(read_any(message, "internal_date")) || read_string(message, "date", nil),
      "labels" => read_list(message, "labels"),
      "snippet" =>
        message
        |> read_string("snippet", "")
        |> truncate_prompt_string(@prompt_gmail_snippet_limit),
      "body_available" => body_available,
      "body_status" => gmail_body_status_for_prompt(message, body, body_available),
      "body" => body
    }
  end

  defp gmail_body_status_for_prompt(message, body, true) do
    source_status = read_string(message, "body_status", "available")

    if String.contains?(body, "[truncated") do
      "available_truncated"
    else
      source_status
    end
  end

  defp gmail_body_status_for_prompt(message, _body, false),
    do: read_string(message, "body_status", "missing")

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

  defp slack_message_for_prompt(message) when is_map(message) do
    %{
      "team_name" => read_string(message, "team_name", nil),
      "channel_id" => read_string(message, "channel_id", nil),
      "channel_name" => read_string(message, "channel_name", nil),
      "conversation_kind" => read_string(message, "conversation_kind", nil),
      "user" => read_string(message, "user", nil),
      "ts" => read_string(message, "ts", nil),
      "thread_ts" => read_string(message, "thread_ts", nil),
      "text" => read_string(message, "text", ""),
      "reply_count" => read_integer(message, "reply_count", 0)
    }
  end

  defp local_event_to_prompt(%Maraithon.LocalCalendar.LocalEvent{} = event) do
    %{
      "event_id" => event.guid,
      "summary" => event.title || "Untitled event",
      "start" => event.start_at,
      "end" => event.end_at,
      "location" => event.location,
      "attendees" => event.attendee_emails || [],
      "organizer" => event.organizer_email,
      "calendar_name" => event.calendar_name,
      "is_all_day" => event.is_all_day,
      "source" => "local_calendar"
    }
  end

  defp local_event_to_prompt(event) when is_map(event), do: event
  defp local_event_to_prompt(_), do: nil

  defp imessage_chat_for_prompt(%{chat_key: chat_key} = chat) do
    latest = Map.get(chat, :latest_message)

    %{
      "chat_key" => chat_key,
      "chat_display_name" => Map.get(chat, :chat_display_name),
      "message_count_last_7d" => Map.get(chat, :message_count_last_7d, 0),
      "latest_snippet" => latest && (latest.text || ""),
      "latest_sender" => latest && latest.sender_handle,
      "latest_is_from_me" => latest && latest.is_from_me,
      "latest_sent_at" => latest && prompt_time(latest.sent_at)
    }
  end

  defp imessage_chat_for_prompt(chat) when is_map(chat) do
    %{
      "chat_key" => Map.get(chat, "chat_key"),
      "chat_display_name" => Map.get(chat, "chat_display_name"),
      "message_count_last_7d" => Map.get(chat, "message_count_last_7d", 0),
      "latest_snippet" => Map.get(chat, "latest_snippet"),
      "latest_sender" => Map.get(chat, "latest_sender"),
      "latest_is_from_me" => Map.get(chat, "latest_is_from_me"),
      "latest_sent_at" => Map.get(chat, "latest_sent_at")
    }
  end

  defp note_for_prompt(%Maraithon.LocalNotes.LocalNote{} = note) do
    %{
      "note_id" => note.guid,
      "title" => note.title || "(untitled note)",
      "snippet" => note.snippet || "",
      "folder" => note.folder,
      "is_pinned" => note.is_pinned,
      "modified_at" => prompt_time(note.modified_at)
    }
  end

  defp note_for_prompt(note) when is_map(note), do: note

  defp voice_memo_for_prompt(%Maraithon.LocalVoiceMemos.LocalVoiceMemo{} = memo) do
    %{
      "memo_id" => memo.guid,
      "title" => memo.title || "(untitled memo)",
      "snippet" => memo.snippet || "",
      "duration_seconds" => memo.duration_seconds,
      "created_at" => prompt_time(memo.created_at),
      "has_transcript" => is_binary(memo.transcript) and memo.transcript != ""
    }
  end

  defp voice_memo_for_prompt(memo) when is_map(memo), do: memo

  defp reminder_for_prompt(%Maraithon.LocalReminders.LocalReminder{} = reminder) do
    %{
      "reminder_id" => reminder.guid,
      "title" => reminder.title || "(untitled reminder)",
      "list_name" => reminder.list_name,
      "due_at" => prompt_time(reminder.due_at),
      "priority" => reminder.priority,
      "is_completed" => reminder.is_completed,
      "has_alarm" => reminder.has_alarm,
      "url_attachment" => reminder.url_attachment
    }
  end

  defp reminder_for_prompt(reminder) when is_map(reminder), do: reminder

  defp file_for_prompt(%Maraithon.LocalFiles.LocalFile{} = file) do
    %{
      "file_id" => file.guid,
      "filename" => file.filename,
      "extension" => file.extension,
      "path" => file.path,
      "byte_size" => file.byte_size,
      "modified_at" => prompt_time(file.modified_at)
    }
  end

  defp file_for_prompt(file) when is_map(file), do: file

  defp allowed_file_extension?(%Maraithon.LocalFiles.LocalFile{extension: ext})
       when is_binary(ext) do
    String.downcase(ext) in @local_files_allowed_extensions
  end

  defp allowed_file_extension?(_file), do: false

  defp top_browser_hosts(visits, now, limit) do
    cutoff = DateTime.add(now, -24 * 3_600, :second)

    visits
    |> Enum.filter(fn visit ->
      host = visit_host(visit)
      last = visit_last_visited_at(visit)
      is_binary(host) and host != "" and (is_nil(last) or DateTime.compare(last, cutoff) != :lt)
    end)
    |> Enum.group_by(&visit_host/1)
    |> Enum.map(fn {host, host_visits} ->
      %{
        "host" => host,
        "visits" => length(host_visits),
        "last_visited_at" =>
          host_visits
          |> Enum.map(&visit_last_visited_at/1)
          |> Enum.filter(& &1)
          |> Enum.max(DateTime, fn -> nil end)
          |> prompt_time()
      }
    end)
    |> Enum.sort_by(& &1["visits"], :desc)
    |> Enum.take(limit)
  end

  defp visit_host(%Maraithon.LocalBrowserHistory.LocalVisit{host: host}), do: host
  defp visit_host(visit) when is_map(visit), do: Map.get(visit, "host") || Map.get(visit, :host)
  defp visit_host(_), do: nil

  defp visit_last_visited_at(%Maraithon.LocalBrowserHistory.LocalVisit{
         last_visited_at: last_visited_at
       }),
       do: last_visited_at

  defp visit_last_visited_at(%{last_visited_at: last_visited_at}), do: last_visited_at

  defp visit_last_visited_at(%{"last_visited_at" => last_visited_at})
       when is_binary(last_visited_at) do
    case DateTime.from_iso8601(last_visited_at) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp visit_last_visited_at(%{"last_visited_at" => %DateTime{} = dt}), do: dt
  defp visit_last_visited_at(_visit), do: nil

  defp within_last_24h?(nil, _now), do: false

  defp within_last_24h?(%DateTime{} = dt, %DateTime{} = now) do
    DateTime.diff(now, dt, :second) <= 24 * 3_600
  end

  defp within_last_24h?(_dt, _now), do: false

  defp reminder_due_today?(
         %Maraithon.LocalReminders.LocalReminder{due_at: %DateTime{} = due},
         now
       ) do
    DateTime.compare(due, now) != :gt or
      DateTime.diff(due, now, :second) <= 24 * 3_600
  end

  defp reminder_due_today?(reminder, now) when is_map(reminder) do
    due = Map.get(reminder, "due_at") || Map.get(reminder, :due_at)

    case due do
      %DateTime{} = dt ->
        reminder_due_today?(%Maraithon.LocalReminders.LocalReminder{due_at: dt}, now)

      _ ->
        false
    end
  end

  defp reminder_due_today?(_reminder, _now), do: false

  defp fetch_local_source(user_id, source, bundle_items, fetch_fun)
       when is_binary(user_id) and is_list(bundle_items) and is_function(fetch_fun, 1) do
    try do
      items =
        case bundle_items do
          [] -> fetch_fun.(user_id)
          items -> items
        end

      {items, nil}
    rescue
      exception ->
        error = Maraithon.Redaction.error_summary(exception)

        Logger.warning("morning_briefing local source fetch failed",
          source: to_string(source),
          error: error,
          exception: inspect(exception.__struct__)
        )

        {[], error}
    catch
      kind, reason ->
        error = "#{kind}: #{Maraithon.Redaction.error_summary(reason)}"

        Logger.warning("morning_briefing local source fetch failed",
          source: to_string(source),
          error: error
        )

        {[], error}
    end
  end

  defp fetch_local_source(_user_id, _source, _bundle_items, _fetch_fun), do: {[], "invalid_user"}

  defp merge_local_source_health(freshness, user_id, now, sources, errors)
       when is_map(freshness) do
    devices_last_seen = latest_device_seen_at(user_id)

    Enum.reduce(sources, freshness, fn {source, items}, acc ->
      error = Map.get(errors, source)

      status =
        if is_nil(error), do: local_source_status(items, devices_last_seen, now), else: "error"

      health =
        Map.get(acc, to_string(source), %{})
        |> Map.merge(%{
          "source" => to_string(source),
          "status" => status,
          "device_last_seen_at" => prompt_time(devices_last_seen),
          "item_count" => length(items)
        })
        |> maybe_put("fetch_error", error)

      Map.put(acc, to_string(source), health)
    end)
  end

  defp merge_local_source_health(freshness, _user_id, _now, _sources, _errors), do: freshness

  defp local_source_status(items, %DateTime{} = devices_last_seen, %DateTime{} = now)
       when is_list(items) do
    cond do
      items != [] -> "connected"
      DateTime.diff(now, devices_last_seen, :second) > @device_stale_seconds -> "stale"
      true -> "connected"
    end
  end

  defp local_source_status([], nil, _now), do: "error"
  defp local_source_status([_ | _], nil, _now), do: "connected"
  defp local_source_status(_items, _last_seen, _now), do: "error"

  defp latest_device_seen_at(user_id) when is_binary(user_id) do
    try do
      user_id
      |> Companion.Devices.list_for_user()
      |> Enum.map(& &1.last_seen_at)
      |> Enum.filter(& &1)
      |> case do
        [] -> nil
        timestamps -> Enum.max(timestamps, DateTime)
      end
    rescue
      _ -> nil
    end
  end

  defp latest_device_seen_at(_user_id), do: nil

  defp news_item_for_prompt(item) when is_map(item) do
    %{
      "source" => read_string(item, "source", nil),
      "title" => read_string(item, "title", nil),
      "summary" => read_string(item, "summary", ""),
      "url" => read_string(item, "url", nil),
      "published_at" => read_string(item, "published_at", nil)
    }
  end

  defp insight_for_prompt(insight) do
    %{
      "id" => insight.id,
      "source" => insight.source,
      "category" => insight.category,
      "title" => insight.title,
      "summary" => insight.summary,
      "recommended_action" => insight.recommended_action,
      "priority" => insight.priority,
      "due_at" => prompt_time(insight.due_at)
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
      "source_account_id" => todo.source_account_id,
      "source_account_label" => todo.source_account_label,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => prompt_time(todo.source_occurred_at)
    }
  end

  # SPEC 08 R2: interruptions held for quiet hours, the interruption
  # budget, or the model's own hold disposition must still reach the
  # operator instead of vanishing. Fold them into the brief input here, but
  # do NOT mark them delivered yet — that flip is irreversible, and at this
  # point the LLM hasn't generated the brief and the push hasn't been
  # confirmed sent. Their ids are carried through brief.metadata and only
  # marked "delivered" once PushBroker confirms the brief actually reached
  # the operator (see mark_held_interruptions_delivered/1 in push_broker.ex).
  # If generation errors or the brief stays held/failed, they remain
  # "held" so the next brief re-fetches them via list_held_for_user/2.
  # Field mapping shared with CalendarCheckIn via
  # ProactiveQueue.held_interruptions_for_prompt/2 (SPEC 02 R8).
  defp held_interruptions_for_prompt(user_id) do
    ProactiveQueue.held_interruptions_for_prompt(user_id, limit: 25)
  end

  # SPEC 02 R14: durable "the agent noticed something was stuck and cleared
  # it" facts from the last 24 hours, surfaced to the model as
  # open_work.system_notices. Model-gated: the runtime only supplies the
  # facts; the prompt rule leaves whether/how to mention one to the model.
  defp self_heal_notices_for_prompt(user_id) do
    since = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    user_id
    |> ActionLedger.list_recent(event_type: "runtime.self_healed", since: since, limit: 10)
    |> Enum.map(fn action ->
      %{
        "summary" => action.model_summary,
        "at" => prompt_time(action.inserted_at)
      }
    end)
  rescue
    _error -> []
  end

  defp held_interruption_ids(brief_input) when is_map(brief_input) do
    brief_input
    |> get_in(["open_work", "held_interruptions"])
    |> Kernel.||([])
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.filter(&is_binary/1)
  end

  defp held_interruption_ids(_brief_input), do: []

  defp recent_unread_message?(message, lookback_start) when is_map(message) do
    labels = read_list(message, "labels") |> Enum.map(&to_string/1)
    internal_date = read_datetime(message, "internal_date")

    "UNREAD" in labels and
      (is_nil(internal_date) or DateTime.compare(internal_date, lookback_start) != :lt)
  end

  defp recent_gmail_message?(message, lookback_start) when is_map(message) do
    case read_datetime(message, "internal_date") do
      nil -> true
      internal_date -> DateTime.compare(internal_date, lookback_start) != :lt
    end
  end

  defp recent_gmail_message?(_message, _lookback_start), do: false

  defp commercial_thread_candidate?(message, state) when is_map(message) do
    from = read_string(message, "from", "") |> String.downcase()
    recipients = commercial_thread_recipients(message)

    text =
      [
        from,
        recipients,
        read_string(message, "subject", ""),
        read_string(message, "snippet", ""),
        gmail_body_for_prompt(message)
      ]
      |> Enum.join("\n")
      |> String.downcase()

    terms = Map.get(state, :commercial_thread_terms, @commercial_thread_terms)

    commercial_thread_counterparty?(from, recipients, state) and
      Enum.any?(terms, &String.contains?(text, &1))
  end

  defp commercial_thread_candidate?(_message, _state), do: false

  defp commercial_thread_counterparty?(from, recipients, state)
       when is_binary(from) and is_binary(recipients) do
    from_domains = email_domains(from)
    recipient_domains = email_domains(recipients)
    teammate_domains = Map.get(state, :commercial_teammate_domains, @commercial_teammate_domains)

    counterparty_domain_markers =
      Map.get(
        state,
        :commercial_counterparty_domain_markers,
        @commercial_counterparty_domain_markers
      )

    from_teammate? = Enum.any?(from_domains, &commercial_teammate_domain?(&1, teammate_domains))

    from_counterparty? =
      Enum.any?(
        from_domains,
        &commercial_counterparty_domain?(&1, counterparty_domain_markers)
      )

    external_recipient? =
      Enum.any?(recipient_domains, &(not commercial_teammate_domain?(&1, teammate_domains)))

    from_counterparty? or (from_teammate? and external_recipient?)
  end

  defp commercial_thread_counterparty?(_from, _recipients, _state), do: false

  defp email_domains(text) when is_binary(text) do
    ~r/@([a-z0-9][a-z0-9.-]*\.[a-z]{2,})/i
    |> Regex.scan(text)
    |> Enum.map(fn [_match, domain] -> String.downcase(domain) end)
    |> Enum.uniq()
  end

  defp email_domains(_text), do: []

  defp commercial_teammate_domain?(domain, teammate_domains) when is_binary(domain) do
    Enum.any?(teammate_domains, fn teammate_domain ->
      domain == teammate_domain or String.ends_with?(domain, "." <> teammate_domain)
    end)
  end

  defp commercial_teammate_domain?(_domain, _teammate_domains), do: false

  defp commercial_counterparty_domain?(domain, markers) when is_binary(domain) do
    Enum.any?(markers, &String.contains?(domain, &1))
  end

  defp commercial_counterparty_domain?(_domain, _markers), do: false

  defp commercial_thread_recipients(message) when is_map(message) do
    [
      read_string(message, "to", ""),
      read_string(message, "cc", ""),
      read_string(message, "bcc", "")
    ]
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp commercial_thread_recipients(_message), do: ""

  defp commercial_thread_key(message) when is_map(message) do
    subject_key =
      [
        normalize_commercial_text(read_string(message, "subject", "")),
        normalize_commercial_text(read_string(message, "from", "")),
        normalize_commercial_text(read_string(message, "snippet", ""))
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("|")

    if subject_key == "" do
      read_string(message, "thread_id", nil) || inspect(message)
    else
      subject_key
    end
  end

  defp commercial_thread_key(message), do: inspect(message)

  defp commercial_thread_sort_key(message) when is_map(message) do
    case read_datetime(message, "internal_date") do
      nil -> 0
      datetime -> DateTime.to_unix(datetime, :second)
    end
  end

  defp commercial_thread_sort_key(_message), do: 0

  defp normalize_commercial_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_commercial_text(_value), do: ""

  defp recent_slack_message?(message, lookback_start) when is_map(message) do
    case read_slack_datetime(message, "ts") do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_slack_message?(_message, _lookback_start), do: false

  defp event_on_date?(event, date, state) when is_map(event) do
    event
    |> read_any("start")
    |> local_date_from_value(state)
    |> case do
      ^date -> true
      _ -> false
    end
  end

  defp event_on_date?(_event, _date, _state), do: false

  defp schedule_coverage_contract(meeting_prep) when is_map(meeting_prep) do
    required_meetings =
      meeting_prep
      |> read_list("meetings")
      |> Enum.filter(&truthy?(read_any(&1, "schedule_required")))
      |> Enum.map(&required_schedule_meeting_for_prompt/1)

    %{
      "policy" =>
        "Every required_meetings item must appear in Today's Schedule. The model still decides the executive read, prep, risk, and wording.",
      "required_meetings" => required_meetings,
      "counts" => %{"required_meetings" => length(required_meetings)}
    }
  end

  defp schedule_coverage_contract(_meeting_prep) do
    %{
      "policy" =>
        "Every required_meetings item must appear in Today's Schedule. The model still decides the executive read, prep, risk, and wording.",
      "required_meetings" => [],
      "counts" => %{"required_meetings" => 0}
    }
  end

  defp commercial_coverage_contract(threads) when is_list(threads) do
    required_threads =
      threads
      |> Enum.map(&required_commercial_thread_for_prompt/1)
      |> Enum.reject(&(&1 == %{}))

    %{
      "policy" =>
        "Every required_threads item must appear in Decisions / Follow-ups or Today's Schedule unless it is clearly duplicated by another named item. The model still decides the executive read, prep, risk, and wording.",
      "required_threads" => required_threads,
      "counts" => %{"required_threads" => length(required_threads)}
    }
  end

  defp commercial_coverage_contract(_threads) do
    %{
      "policy" =>
        "Every required_threads item must appear in Decisions / Follow-ups or Today's Schedule unless it is clearly duplicated by another named item. The model still decides the executive read, prep, risk, and wording.",
      "required_threads" => [],
      "counts" => %{"required_threads" => 0}
    }
  end

  defp required_commercial_thread_for_prompt(thread) when is_map(thread) do
    %{
      "commercial_required" => true,
      "message_id" => read_string(thread, "message_id", nil),
      "thread_id" => read_string(thread, "thread_id", nil),
      "from" => read_string(thread, "from", nil),
      "to" => read_string(thread, "to", nil),
      "subject" => read_string(thread, "subject", nil),
      "date" => read_string(thread, "date", nil),
      "snippet" => read_string(thread, "snippet", nil),
      "body" => read_string(thread, "body", nil),
      "coverage_reason" =>
        "Teammate-led or known-counterparty commercial thread that needs executive readiness."
    }
    |> compact_map()
  end

  defp required_commercial_thread_for_prompt(_thread), do: %{}

  defp required_schedule_meeting_for_prompt(meeting) when is_map(meeting) do
    %{
      "event_id" => read_string(meeting, "event_id", nil),
      "summary" => read_string(meeting, "summary", nil),
      "start" => read_any(meeting, "start"),
      "end" => read_any(meeting, "end"),
      "display_start" => read_string(meeting, "display_start", nil),
      "display_end" => read_string(meeting, "display_end", nil),
      "display_date" => read_string(meeting, "display_date", nil),
      "display_timezone" => read_string(meeting, "display_timezone", nil),
      "external_attendees" => read_list(meeting, "external_attendees"),
      "candidate_people_and_orgs" => read_list(meeting, "candidate_people_and_orgs"),
      "crm_context" => read_list(meeting, "crm_context"),
      "web_context" => read_list(meeting, "web_context"),
      "data_gaps" => read_list(meeting, "data_gaps"),
      "briefing_reason" => read_string(meeting, "briefing_reason", nil)
    }
    |> compact_map()
  end

  defp dedupe_calendar_events(events) when is_list(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&calendar_event_dedupe_key/1)
  end

  defp calendar_event_dedupe_key(event) when is_map(event) do
    summary = normalize_calendar_dedupe_text(read_string(event, "summary", ""))
    start = prompt_time(read_any(event, "start"))
    end_time = prompt_time(read_any(event, "end"))
    organizer = normalize_calendar_dedupe_text(read_string(event, "organizer", ""))

    cond do
      summary != "" and is_binary(start) ->
        {:time, summary, start, end_time, organizer}

      event_id = read_string(event, "event_id", nil) ->
        {:id, event_id}

      true ->
        {:raw, inspect(event)}
    end
  end

  defp calendar_event_dedupe_key(event), do: {:raw, inspect(event)}

  defp normalize_calendar_dedupe_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_calendar_dedupe_text(_value), do: ""

  defp event_sort_key(event) when is_map(event) do
    case read_any(event, "start") do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      %{"date" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> 0
    end
  end

  defp compact_brief_input_for_prompt(input) when is_map(input) do
    compacted = compact_prompt_sections(input)

    PromptBudget.project_fields(
      compacted,
      [
        {"date", 300},
        {"generated_at", 300},
        {"timezone_offset_hours", 100},
        {"timezone", 300},
        {"schedule_coverage", 5_500},
        {"meeting_prep", 5_500},
        {"commercial_coverage", 5_500},
        {"open_work", 4_000},
        {"calendar", 3_500},
        {"commitments", 2_500},
        {"gmail", 8_000},
        {"slack", 4_000},
        {"relationships", 3_000},
        {"source_health", 2_000},
        {"connector_health", 1_500},
        {"deep_memory", 2_000},
        {"imessage", 2_000},
        {"reminders", 1_500},
        {"notes", 1_500},
        {"voice_memos", 1_500},
        {"files", 1_500},
        {"browser_history", 1_500},
        {"news", 1_500},
        {"weather", 1_000},
        {"user_identity", 500}
      ],
      @max_compact_brief_input_bytes,
      string_bytes: 6_000,
      list_items: 100,
      map_entries: 100,
      max_depth: 6,
      key_bytes: 255
    ) || %{}
  end

  defp compact_brief_input_for_prompt(input), do: input

  defp compact_prompt_sections(input) do
    base =
      input
      |> Map.take(["date", "generated_at", "timezone_offset_hours", "timezone"])
      |> compact_prompt_value()

    section_inputs =
      Enum.map(prompt_section_compactors(), fn {key, default, compact_fun} ->
        value = Map.get(input, key, default)

        bounded_value =
          PromptBudget.bounded(value, @max_prompt_section_bytes,
            string_bytes: 6_000,
            list_items: 100,
            map_entries: 100,
            max_depth: 6,
            key_bytes: 255
          ) || default

        {key, compact_fun, bounded_value}
      end)

    Task.Supervisor.async_stream_nolink(
      Maraithon.Runtime.ToolCallSupervisor,
      section_inputs,
      fn section_input ->
        try do
          {:ok, compact_prompt_section(section_input)}
        rescue
          exception -> {:error, Maraithon.Redaction.error_class(exception)}
        catch
          kind, _reason -> {:error, to_string(kind)}
        end
      end,
      max_concurrency: prompt_section_concurrency(),
      timeout: @prompt_section_build_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(base, fn
      {:ok, {:ok, {key, value}}}, acc ->
        Map.put(acc, key, value)

      _failed, acc ->
        Logger.warning("morning_briefing prompt section compaction task failed",
          failure_code: "section_compaction_failed"
        )

        acc
    end)
  end

  defp prompt_section_compactors do
    [
      {"calendar", %{}, &compact_calendar_for_prompt/1},
      {"meeting_prep", %{}, &compact_meeting_prep_for_prompt/1},
      {"schedule_coverage", %{}, &compact_schedule_coverage_for_prompt/1},
      {"commercial_coverage", %{}, &compact_commercial_coverage_for_prompt/1},
      {"gmail", %{}, &compact_gmail_for_prompt/1},
      {"slack", %{}, &compact_slack_for_prompt/1},
      {"news", %{}, &compact_news_for_prompt/1},
      {"weather", %{}, &compact_prompt_value/1},
      {"user_identity", "", &compact_prompt_value/1},
      {"commitments", %{}, &compact_prompt_value/1},
      {"open_work", %{}, &compact_prompt_value/1},
      {"relationships", [], &compact_relationships_for_prompt/1},
      {"deep_memory", %{}, &compact_prompt_value/1},
      {"imessage", %{}, &compact_prompt_value/1},
      {"notes", %{}, &compact_prompt_value/1},
      {"voice_memos", %{}, &compact_prompt_value/1},
      {"reminders", %{}, &compact_prompt_value/1},
      {"files", %{}, &compact_prompt_value/1},
      {"browser_history", %{}, &compact_prompt_value/1},
      {"source_health", %{}, &compact_prompt_value/1},
      {"connector_health", [], &compact_prompt_value/1}
    ]
  end

  defp compact_prompt_section({key, compact_fun, value}) do
    compacted = compact_fun.(value)

    bounded =
      PromptBudget.bounded(compacted, @max_prompt_section_bytes,
        string_bytes: 6_000,
        list_items: 100,
        map_entries: 100,
        max_depth: 6,
        key_bytes: 255
      )

    {key, bounded}
  rescue
    exception ->
      Logger.warning("morning_briefing prompt section compaction failed",
        section: key,
        failure_code: Maraithon.Redaction.error_class(exception)
      )

      {key, nil}
  catch
    kind, _reason ->
      Logger.warning("morning_briefing prompt section compaction failed",
        section: key,
        failure_code: to_string(kind)
      )

      {key, nil}
  end

  defp prompt_section_concurrency do
    System.schedulers_online()
    |> min(length(prompt_section_compactors()))
    |> max(1)
  end

  defp compact_calendar_for_prompt(calendar) when is_map(calendar) do
    calendar
    |> Map.update("today_events", [], fn events ->
      events
      |> read_list()
      |> Enum.map(&compact_calendar_event_for_prompt/1)
    end)
    |> Map.update("upcoming_local", [], fn events ->
      events
      |> read_list()
      |> Enum.map(&compact_calendar_event_for_prompt/1)
    end)
    |> Map.update("tomorrow_first_event", nil, &compact_calendar_event_for_prompt/1)
    |> compact_prompt_value()
  end

  defp compact_calendar_for_prompt(calendar), do: compact_prompt_value(calendar)

  defp compact_calendar_event_for_prompt(event) when is_map(event) do
    event
    |> Map.update("attendees", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_calendar_event_for_prompt(event), do: compact_prompt_value(event)

  defp compact_meeting_prep_for_prompt(meeting_prep) when is_map(meeting_prep) do
    meeting_prep
    |> Map.update("meetings", [], fn meetings ->
      meetings
      |> read_list()
      |> prioritize_required_prompt_items()
      |> Enum.take(@prompt_meeting_list_limit)
      |> Enum.map(&compact_meeting_for_prompt/1)
    end)
    |> compact_prompt_value(@prompt_meeting_list_limit, @prompt_meeting_string_limit)
  end

  defp compact_meeting_prep_for_prompt(meeting_prep), do: compact_prompt_value(meeting_prep)

  defp compact_schedule_coverage_for_prompt(schedule_coverage) when is_map(schedule_coverage) do
    schedule_coverage
    |> Map.update("required_meetings", [], fn meetings ->
      meetings
      |> read_list()
      |> Enum.take(@prompt_meeting_list_limit)
      |> Enum.map(&compact_meeting_for_prompt/1)
    end)
    |> compact_prompt_value(@prompt_meeting_list_limit, @prompt_meeting_string_limit)
  end

  defp compact_schedule_coverage_for_prompt(schedule_coverage),
    do: compact_prompt_value(schedule_coverage)

  defp compact_commercial_coverage_for_prompt(commercial_coverage)
       when is_map(commercial_coverage) do
    commercial_coverage
    |> Map.update("required_threads", [], fn threads ->
      threads
      |> read_list()
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> compact_prompt_value()
  end

  defp compact_commercial_coverage_for_prompt(commercial_coverage),
    do: compact_prompt_value(commercial_coverage)

  defp compact_meeting_for_prompt(meeting) when is_map(meeting) do
    meeting
    |> Map.update("attendees", [], &read_list/1)
    |> Map.update("external_attendees", [], &read_list/1)
    |> Map.update("candidate_people_and_orgs", [], &read_list/1)
    |> Map.update("crm_context", [], &(read_list(&1) |> compact_prompt_value(10, 3_000)))
    |> Map.update("web_context", [], &compact_web_context_for_prompt/1)
    |> Map.update("data_gaps", [], &read_list/1)
    |> compact_prompt_value(@prompt_meeting_list_limit, @prompt_meeting_string_limit)
  end

  defp compact_meeting_for_prompt(meeting), do: compact_prompt_value(meeting)

  defp compact_gmail_for_prompt(gmail) when is_map(gmail) do
    gmail
    |> Map.update("commercial_threads", [], fn messages ->
      messages
      |> read_list()
      |> Enum.take(@prompt_gmail_list_limit)
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> Map.update("recent_inbox", [], fn messages ->
      messages
      |> read_list()
      |> Enum.take(@prompt_gmail_list_limit)
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> Map.update("recent_unread", [], fn messages ->
      messages
      |> read_list()
      |> Enum.take(@prompt_gmail_list_limit)
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> compact_prompt_value()
  end

  defp compact_gmail_for_prompt(gmail), do: compact_prompt_value(gmail)

  defp compact_gmail_message_for_prompt(message) when is_map(message) do
    message =
      message
      |> Map.update(
        "snippet",
        "",
        &(to_string(&1) |> truncate_prompt_string(@prompt_gmail_snippet_limit))
      )
      |> Map.update(
        "body",
        "",
        &(to_string(&1) |> truncate_prompt_string(@prompt_gmail_body_limit))
      )

    PromptBudget.project_fields(
      message,
      ~w(message_id thread_id from subject snippet internal_date body),
      600,
      string_bytes: 240,
      list_items: 4,
      map_entries: 8,
      max_depth: 2,
      key_bytes: 64
    ) || %{}
  end

  defp compact_gmail_message_for_prompt(message), do: compact_prompt_value(message)

  defp compact_web_context_for_prompt(web_context) do
    web_context
    |> read_list()
    |> Enum.take(@prompt_web_context_limit)
    |> Enum.map(fn context ->
      context
      |> compact_prompt_value(@prompt_web_page_context_limit, @prompt_meeting_string_limit)
      |> maybe_compact_page_contexts()
    end)
  end

  defp maybe_compact_page_contexts(%{} = context) do
    Map.update(context, "page_contexts", [], fn page_contexts ->
      page_contexts
      |> read_list()
      |> Enum.take(@prompt_web_page_context_limit)
      |> compact_prompt_value(@prompt_web_page_context_limit, @prompt_meeting_string_limit)
    end)
  end

  defp maybe_compact_page_contexts(context), do: context

  defp compact_slack_for_prompt(slack) when is_map(slack) do
    slack
    |> Map.update("key_threads", [], fn messages ->
      messages
      |> read_list()
      |> Enum.map(&compact_prompt_value/1)
    end)
    |> Map.update("mentions", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_slack_for_prompt(slack), do: compact_prompt_value(slack)

  defp compact_news_for_prompt(news) when is_map(news) do
    news
    |> Map.update("items", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_news_for_prompt(news), do: compact_prompt_value(news)

  defp compact_relationships_for_prompt(relationships) do
    relationships
    |> read_list()
    |> Enum.take(@prompt_relationship_limit)
    |> compact_prompt_value()
  end

  defp compact_prompt_value(value) do
    compact_prompt_value(value, @prompt_default_list_limit, @prompt_string_limit)
  end

  defp compact_prompt_value(%DateTime{} = value, _list_limit, _string_limit),
    do: DateTime.to_iso8601(value)

  defp compact_prompt_value(%NaiveDateTime{} = value, _list_limit, _string_limit),
    do: NaiveDateTime.to_iso8601(value)

  defp compact_prompt_value(%Date{} = value, _list_limit, _string_limit),
    do: Date.to_iso8601(value)

  defp compact_prompt_value(%Time{} = value, _list_limit, _string_limit),
    do: Time.to_iso8601(value)

  defp compact_prompt_value(%{__struct__: _struct} = value, _list_limit, _string_limit),
    do: inspect(value)

  defp compact_prompt_value(value, list_limit, string_limit) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {compact_prompt_key(key), compact_prompt_value(item, list_limit, string_limit)}
    end)
  end

  defp compact_prompt_value(value, list_limit, string_limit) when is_list(value) do
    value
    |> Enum.take(list_limit)
    |> Enum.map(&compact_prompt_value(&1, list_limit, string_limit))
  end

  defp compact_prompt_value(value, _list_limit, string_limit) when is_binary(value),
    do: truncate_prompt_string(value, string_limit)

  defp compact_prompt_value(value, _list_limit, _string_limit), do: value

  defp compact_prompt_key(key) when is_binary(key), do: prompt_safe_string(key)
  defp compact_prompt_key(key), do: key

  defp truncate_prompt_string(value, limit) when is_binary(value) and is_integer(limit) do
    value = prompt_safe_string(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "\n[truncated #{String.length(value) - limit} chars]"
    else
      value
    end
  end

  defp truncate_prompt_string(value, _limit), do: value

  defp prompt_safe_string(value) when is_binary(value) do
    value
    |> utf8_or_latin1_string()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, " ")
  end

  defp utf8_or_latin1_string(value) when is_binary(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      converted when is_binary(converted) ->
        converted

      {:error, valid, rest} ->
        valid <> latin1_head(rest) <> utf8_or_latin1_string(drop_binary_head(rest))

      {:incomplete, valid, rest} ->
        valid <> latin1_binary(rest)
    end
  end

  defp latin1_head(<<byte, _rest::binary>>), do: latin1_binary(<<byte>>)
  defp latin1_head(_rest), do: ""

  defp latin1_binary(value) when is_binary(value) do
    case :unicode.characters_to_binary(value, :latin1, :utf8) do
      converted when is_binary(converted) -> converted
      _other -> ""
    end
  end

  defp drop_binary_head(<<_byte, rest::binary>>), do: rest
  defp drop_binary_head(_rest), do: ""

  defp prioritize_required_prompt_items(items) do
    {required, rest} =
      Enum.split_with(items, fn
        %{"schedule_required" => true} -> true
        %{schedule_required: true} -> true
        _item -> false
      end)

    required ++ rest
  end

  defp compact_brief_input_for_metadata(input) do
    %{
      "date" => read_string(input, "date", nil),
      "generated_at" => read_string(input, "generated_at", nil),
      "counts" => %{
        "gmail_commercial_threads" =>
          length(get_in(input, ["gmail", "commercial_threads"]) || []),
        "gmail_recent_inbox" => length(get_in(input, ["gmail", "recent_inbox"]) || []),
        "gmail_recent_unread" => length(get_in(input, ["gmail", "recent_unread"]) || []),
        "slack_key_threads" => length(get_in(input, ["slack", "key_threads"]) || []),
        "news_items" => length(get_in(input, ["news", "items"]) || []),
        "commitments_active" => get_in(input, ["commitments", "active_count"]) || 0,
        "insights" => length(get_in(input, ["open_work", "insights"]) || []),
        "todos" => length(get_in(input, ["open_work", "todos"]) || []),
        "relationships" => length(get_in(input, ["relationships"]) || []),
        "deep_memory" => deep_memory_count(input),
        "imessage_chats" => length(get_in(input, ["imessage", "chats"]) || []),
        "notes" => length(get_in(input, ["notes", "items"]) || []),
        "voice_memos" => length(get_in(input, ["voice_memos", "items"]) || []),
        "reminders_due_soon" => length(get_in(input, ["reminders", "due_soon"]) || []),
        "files_recent" => length(get_in(input, ["files", "items"]) || []),
        "browser_top_hosts" => length(get_in(input, ["browser_history", "top_hosts"]) || []),
        "calendar_local_upcoming" => length(get_in(input, ["calendar", "upcoming_local"]) || []),
        "meeting_prep_meetings" => get_in(input, ["meeting_prep", "counts", "meetings"]) || 0,
        "meeting_prep_required_schedule_meetings" =>
          get_in(input, ["meeting_prep", "counts", "required_schedule_meetings"]) || 0,
        "schedule_coverage_required_meetings" =>
          get_in(input, ["schedule_coverage", "counts", "required_meetings"]) || 0,
        "commercial_coverage_required_threads" =>
          get_in(input, ["commercial_coverage", "counts", "required_threads"]) || 0,
        "meeting_prep_crm_contexts" =>
          get_in(input, ["meeting_prep", "counts", "crm_contexts"]) || 0,
        "meeting_prep_web_searches" =>
          get_in(input, ["meeting_prep", "counts", "web_searches"]) || 0
      },
      "calendar_preferred_source" => get_in(input, ["calendar", "preferred_source"])
    }
  end

  defp deep_memory_count(input) do
    case Map.get(input, "deep_memory") || Map.get(input, :deep_memory) do
      %{count: count} when is_integer(count) -> count
      %{"count" => count} when is_integer(count) -> count
      _other -> 0
    end
  end

  defp llm_finish_reason(%{finish_reason: reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(%{"finish_reason" => reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(_response), do: nil

  defp due_now?(now, state) do
    local_now = local_datetime(now, state)

    local_now.hour > state.morning_hour or
      (local_now.hour == state.morning_hour and local_now.minute >= state.morning_minute)
  end

  defp next_morning_occurrence(now, state) do
    local_now = local_datetime(now, state)
    local_date = DateTime.to_date(local_now)

    scheduled_today =
      local_date
      |> DateTime.new!(Time.new!(state.morning_hour, state.morning_minute, 0), "Etc/UTC")

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        Date.add(local_date, 1)
        |> DateTime.new!(Time.new!(state.morning_hour, state.morning_minute, 0), "Etc/UTC")
      end

    DateTime.add(target_local, -local_timezone_offset_hours(target_local, state), :hour)
  end

  defp local_period_key(now, state) do
    now
    |> local_date(state)
    |> Date.to_iso8601()
  end

  defp local_date(%DateTime{} = now, state) do
    now
    |> local_datetime(state)
    |> DateTime.to_date()
  end

  defp local_day_start_utc(%Date{} = date, state) do
    local_midnight = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    DateTime.add(local_midnight, -local_timezone_offset_hours(local_midnight, state), :hour)
  end

  defp local_date_from_value(%DateTime{} = value, state),
    do: local_date(value, state)

  defp local_date_from_value(%{"date" => date}, _state) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp local_date_from_value(value, state) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> local_date(datetime, state)
      _ -> nil
    end
  end

  defp local_date_from_value(_value, _state), do: nil

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

  defp display_date(value, state) do
    case local_date_from_value(value, state) do
      %Date{} = date -> Date.to_iso8601(date)
      _ -> nil
    end
  end

  defp display_time(%{"date" => date}, _state) when is_binary(date), do: date

  defp display_time(%DateTime{} = value, state) do
    local = local_datetime(value, state)
    "#{format_clock(local)} #{timezone_label(state, value)}"
  end

  defp display_time(value, state) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> display_time(datetime, state)
      _ -> value
    end
  end

  defp display_time(_value, _state), do: nil

  defp datetime_from_value(%DateTime{} = value), do: value

  defp datetime_from_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_from_value(_value), do: nil

  defp local_datetime(%DateTime{} = datetime, state) do
    DateTime.add(datetime, timezone_offset_hours_at(datetime, state), :hour)
  end

  defp timezone_offset_hours_at(%DateTime{} = datetime, state) do
    case timezone_config(state) do
      {:us, standard, daylight, _label} ->
        if us_dst_active_utc?(datetime, standard, daylight), do: daylight, else: standard

      {:fixed, offset, _label} ->
        offset

      :unknown ->
        state.timezone_offset_hours
    end
  end

  defp local_timezone_offset_hours(%DateTime{} = local_datetime, state) do
    case timezone_config(state) do
      {:us, standard, daylight, _label} ->
        if us_dst_active_local?(local_datetime), do: daylight, else: standard

      {:fixed, offset, _label} ->
        offset

      :unknown ->
        state.timezone_offset_hours
    end
  end

  defp timezone_label(state, nil), do: timezone_label(state, DateTime.utc_now())

  defp timezone_label(state, %DateTime{} = _datetime) do
    case timezone_config(state) do
      {:us, _standard, _daylight, label} -> label
      {:fixed, _offset, label} -> label
      :unknown -> timezone_offset_label(state.timezone_offset_hours)
    end
  end

  defp timezone_config(%{timezone: timezone}) when is_binary(timezone) do
    case String.downcase(String.trim(timezone)) do
      value
      when value in ["america/los_angeles", "us/pacific", "pacific", "pacific time", "pt"] ->
        {:us, -8, -7, "PT"}

      value when value in ["america/denver", "us/mountain", "mountain", "mountain time", "mt"] ->
        {:us, -7, -6, "MT"}

      value when value in ["america/chicago", "us/central", "central", "central time", "ct"] ->
        {:us, -6, -5, "CT"}

      value
      when value in [
             "america/new_york",
             "america/toronto",
             "us/eastern",
             "eastern",
             "eastern time",
             "et"
           ] ->
        {:us, -5, -4, "ET"}

      value when value in ["utc", "etc/utc", "z"] ->
        {:fixed, 0, "UTC"}

      _ ->
        :unknown
    end
  end

  defp timezone_config(_state), do: :unknown

  defp normalize_timezone(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      timezone -> timezone
    end
  end

  defp normalize_timezone(_value), do: nil

  defp us_dst_active_utc?(%DateTime{} = utc_datetime, standard_offset, daylight_offset) do
    year = utc_datetime.year
    starts_at = us_dst_boundary_utc(year, 3, :second, standard_offset)
    ends_at = us_dst_boundary_utc(year, 11, :first, daylight_offset)

    DateTime.compare(utc_datetime, starts_at) != :lt and
      DateTime.compare(utc_datetime, ends_at) == :lt
  end

  defp us_dst_active_local?(%DateTime{} = local_datetime) do
    year = local_datetime.year
    starts_at = us_dst_boundary_local(year, 3, :second)
    ends_at = us_dst_boundary_local(year, 11, :first)

    DateTime.compare(local_datetime, starts_at) != :lt and
      DateTime.compare(local_datetime, ends_at) == :lt
  end

  defp us_dst_boundary_utc(year, month, ordinal, offset_hours) do
    year
    |> us_dst_boundary_local(month, ordinal)
    |> DateTime.add(-offset_hours, :hour)
  end

  defp us_dst_boundary_local(year, month, ordinal) do
    year
    |> nth_sunday(month, ordinal)
    |> DateTime.new!(~T[02:00:00], "Etc/UTC")
  end

  defp nth_sunday(year, month, ordinal) do
    first = Date.new!(year, month, 1)
    days_until_sunday = rem(7 - Date.day_of_week(first), 7)
    first_sunday = Date.add(first, days_until_sunday)

    case ordinal do
      :first -> first_sunday
      :second -> Date.add(first_sunday, 7)
    end
  end

  defp format_clock(%DateTime{} = datetime) do
    hour =
      case rem(datetime.hour, 12) do
        0 -> 12
        value -> value
      end

    minute = datetime.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    meridiem = if datetime.hour < 12, do: "AM", else: "PM"

    "#{hour}:#{minute} #{meridiem}"
  end

  defp timezone_offset_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC#{sign}#{hours}:00"
  end

  defp timezone_offset_label(_offset), do: "UTC"

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
  defp read_list(list) when is_list(list), do: list
  defp read_list(_value), do: []

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

  defp read_integer(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_integer(_map, _key, default), do: default

  defp read_number(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_number(value) -> value
      value when is_binary(value) -> parse_float(value, default)
      _ -> default
    end
  end

  defp read_number(_map, _key, default), do: default

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> default
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

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

  defp read_slack_datetime(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) ->
        value
        |> Float.parse()
        |> case do
          {seconds, _rest} -> DateTime.from_unix(trunc(seconds), :second)
          :error -> {:error, :invalid_timestamp}
        end
        |> case do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      value when is_integer(value) ->
        case DateTime.from_unix(value, :second) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_slack_datetime(_map, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp default_if_blank(value, default) when is_binary(value) do
    if blank?(value), do: default, else: value
  end

  defp default_if_blank(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp configured_string_list(config, key, defaults) when is_map(config) do
    configured =
      [
        Map.get(config, key),
        get_in(config, ["org", key])
      ]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)

    (defaults ++ configured)
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp configured_string_list(_config, _key, defaults), do: defaults

  defp normalize_reasoning_effort(value, default) do
    case normalize_string(value) do
      effort when is_binary(effort) ->
        normalized = String.downcase(effort)

        case normalized do
          "high" -> "high"
          "xhigh" -> default
          effort when effort in ["low", "medium"] -> default
          _other -> default
        end

      _ ->
        default
    end
  end

  defp effective_llm_max_tokens(state) do
    state
    |> Map.get(:llm_max_tokens)
    |> integer_in_range(@default_llm_max_tokens, 256, @default_llm_max_tokens)
  end

  defp llm_request_metadata(state) do
    %{
      "model" => state.llm_model || Maraithon.LLM.model() || "unknown",
      "max_tokens" => effective_llm_max_tokens(state),
      "reasoning_effort" => state.llm_reasoning_effort,
      "timeout_ms" => state.llm_timeout_ms
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

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

  defp to_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp to_existing_atom(key), do: key
end
