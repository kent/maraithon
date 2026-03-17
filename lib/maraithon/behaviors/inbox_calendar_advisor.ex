defmodule Maraithon.Behaviors.InboxCalendarAdvisor do
  @moduledoc """
  Founder follow-through accountability behavior focused on Gmail + Calendar context.

  Produces actionable unresolved commitments such as:
  - explicit promises made in sent email
  - inbox threads that still need a reply
  - post-meeting follow-ups that still need owners and next steps
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Followthrough.ConversationContext
  alias Maraithon.InsightFeedback
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.Tools.GmailHelpers

  require Logger

  @default_wakeup_interval_ms :timer.minutes(10)
  @default_email_scan_limit 14
  @default_event_scan_limit 12
  @default_follow_up_window_hours 36
  @default_max_insights_per_cycle 5
  @default_min_confidence 0.72
  @sent_query_lookback_days 14
  @max_follow_up_ideas 3
  @max_evidence_points 3
  @max_attendee_preview 4
  @max_watch_rules 4

  @promise_terms [
    "i will",
    "we will",
    "i'll",
    "we'll",
    "i can",
    "we can",
    "i can get this",
    "i can send",
    "will share",
    "will send",
    "follow up",
    "follow-up",
    "circle back"
  ]

  @commitment_action_terms [
    "send",
    "share",
    "forward",
    "deliver",
    "reply",
    "follow up",
    "follow-up",
    "intro",
    "introduction",
    "deck",
    "slides",
    "doc",
    "proposal",
    "contract",
    "notes",
    "owners",
    "next steps"
  ]

  @reply_request_terms [
    "can you",
    "could you",
    "please send",
    "please share",
    "please reply",
    "following up",
    "any update",
    "when can",
    "by today",
    "deadline",
    "urgent",
    "asap"
  ]

  @deadline_terms [
    "today",
    "tomorrow",
    "eod",
    "end of day",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday"
  ]

  @cold_outreach_social_terms [
    "saw your post",
    "saw your tweet",
    "saw your note",
    "saw your article"
  ]

  @cold_outreach_meeting_terms [
    "calendly",
    "book time",
    "book a time",
    "book some time",
    "quick call",
    "quick chat",
    "15-minute",
    "15 minute",
    "demo"
  ]

  @cold_outreach_pitch_terms [
    "outbound sales",
    "sales on autopilot",
    "prospecting",
    "outbound prospecting",
    "automated linkedin",
    "lead gen",
    "lead generation"
  ]

  @cold_outreach_sequence_terms [
    "following up",
    "follow up",
    "follow-up",
    "circling back",
    "checking back",
    "bumping this"
  ]

  @artifact_delivery_terms [
    "attached",
    "attachment",
    "here is",
    "shared",
    "sent over",
    "link",
    "deck",
    "slides",
    "doc",
    "document",
    "proposal",
    "contract",
    "notes",
    "owners",
    "next steps"
  ]

  @follow_up_terms [
    "recap",
    "follow up",
    "follow-up",
    "action items",
    "owners",
    "next steps",
    "summary",
    "decision log",
    "notes"
  ]

  @important_meeting_terms [
    "customer",
    "client",
    "investor",
    "fundraise",
    "hiring",
    "interview",
    "candidate",
    "planning",
    "roadmap",
    "strategy",
    "qbr",
    "board",
    "team planning"
  ]

  @account_risk_terms [
    "ad account blocked",
    "account blocked",
    "account disabled",
    "account suspended",
    "account restricted",
    "business restricted",
    "access suspended",
    "access restricted",
    "verification required"
  ]

  @finance_terms [
    "rrsp",
    "401k",
    "ira",
    "tfsa",
    "hsa",
    "rrsp contribution",
    "retirement contribution",
    "tax slip",
    "tax document",
    "contribution room"
  ]

  @app_store_connect_terms [
    "app store connect",
    "apple connect",
    "apple connect notifications",
    "app review",
    "in review",
    "ready for sale",
    "rejected",
    "metadata rejected",
    "waiting for review"
  ]

  @weekday_numbers %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      email_scan_limit:
        to_positive_integer(config["email_scan_limit"], @default_email_scan_limit),
      event_scan_limit:
        to_positive_integer(config["event_scan_limit"], @default_event_scan_limit),
      follow_up_window_hours:
        to_positive_integer(
          config["follow_up_window_hours"] || config["prep_window_hours"],
          @default_follow_up_window_hours
        ),
      max_insights_per_cycle:
        to_positive_integer(config["max_insights_per_cycle"], @default_max_insights_per_cycle),
      min_confidence: to_float(config["min_confidence"], @default_min_confidence),
      source_scope: SourceScope.normalize(read_map(config, "source_scope")),
      google_account: nil,
      google_accounts: [],
      pending_candidates: [],
      pending_direct_insights: [],
      last_scan_at: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state =
      state
      |> ensure_user_id(context)
      |> hydrate_google_accounts()

    cond do
      is_nil(state.user_id) ->
        Logger.warning("InboxCalendarAdvisor skipped wakeup: user_id missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      true ->
        feedback_context = InsightFeedback.prompt_context(state.user_id)
        watch_rules = gmail_watch_rules(state.user_id)

        scan_result =
          case context[:event] do
            %{payload: payload} ->
              candidates_from_pubsub_payload(payload, state, context, watch_rules)

            _ ->
              candidates_from_periodic_scan(state, context, watch_rules)
          end

        candidates =
          scan_result.llm_candidates
          |> dedupe_candidates()
          |> Enum.take(state.max_insights_per_cycle * 2)

        direct_insights =
          scan_result.direct_insights
          |> dedupe_candidates()
          |> Enum.take(state.max_insights_per_cycle)

        cond do
          candidates == [] and direct_insights == [] ->
            {:idle,
             %{
               state
               | pending_candidates: [],
                 pending_direct_insights: [],
                 last_scan_at: context.timestamp
             }}

          candidates == [] ->
            persist_and_reply(direct_insights, state, context)

          true ->
            params = %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => build_llm_prompt(candidates, context.timestamp, feedback_context)
                }
              ],
              "max_tokens" => 1_800,
              "temperature" => 0.15
            }

            {:effect, {:llm_call, params},
             %{
               state
               | pending_candidates: candidates,
                 pending_direct_insights: direct_insights,
                 last_scan_at: context.timestamp
             }}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    candidates = state.pending_candidates

    insights =
      parse_llm_response(response.content, candidates, state)
      |> Enum.filter(&high_signal_unresolved?(&1, state))
      |> Kernel.++(state.pending_direct_insights)
      |> prioritize_insights(state.max_insights_per_cycle)

    result = persist_insights(insights, state, context)

    case result do
      {:ok, stored} ->
        {:emit,
         {:insights_recorded,
          %{
            count: length(stored),
            user_id: state.user_id,
            categories: stored |> Enum.map(& &1.category) |> Enum.uniq()
          }}, %{state | pending_candidates: [], pending_direct_insights: []}}

      {:error, reason} ->
        {:emit, {:insight_error, %{reason: inspect(reason), attempted_count: length(insights)}},
         %{state | pending_candidates: [], pending_direct_insights: []}}
    end
  end

  def handle_effect_result({:tool_call, _result}, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(_state), do: {:relative, @default_wakeup_interval_ms}

  defp ensure_user_id(state, context) do
    case state.user_id do
      nil -> %{state | user_id: normalize_string(context[:user_id])}
      _ -> state
    end
  end

  defp hydrate_google_accounts(%{user_id: nil} = state), do: state

  defp hydrate_google_accounts(state) do
    google_accounts = google_accounts_for_user(state.user_id, state.source_scope)

    state
    |> Map.put(:google_accounts, google_accounts)
    |> Map.put(:google_account, google_accounts |> List.first() |> account_email())
  end

  defp google_accounts_for_user(user_id, source_scope) when is_binary(user_id) do
    live_scope = SourceScope.resolve(user_id)

    scope =
      case SourceScope.google_accounts(live_scope) do
        [] -> source_scope
        _ -> live_scope
      end

    scope
    |> SourceScope.google_accounts()
    |> Enum.filter(fn account ->
      account_supports_service?(account, "gmail") or
        account_supports_service?(account, "calendar")
    end)
  end

  defp google_accounts_for_user(_user_id, _source_scope), do: []

  defp candidates_from_periodic_scan(state, _context, watch_rules) do
    emails = fetch_recent_inbox_messages(state)
    sent_messages = fetch_recent_sent_messages(state)
    events = fetch_recent_calendar_events(state)

    incoming_reply_candidates =
      emails
      |> Enum.flat_map(&incoming_email_candidates(&1, state, sent_messages))

    explicit_promise_candidates =
      sent_messages
      |> Enum.flat_map(&sent_commitment_candidates(&1, state, sent_messages))

    meeting_follow_up_candidates =
      events
      |> Enum.flat_map(&meeting_follow_up_candidates(&1, state, sent_messages))

    %{
      llm_candidates:
        incoming_reply_candidates ++ explicit_promise_candidates ++ meeting_follow_up_candidates,
      direct_insights: important_fyi_candidates(emails, state, watch_rules)
    }
  end

  defp candidates_from_pubsub_payload(payload, state, context, watch_rules)
       when is_map(payload) do
    source =
      payload["source"] ||
        payload[:source] ||
        get_in(payload, ["payload", "source"]) ||
        get_in(payload, [:payload, :source])

    data =
      payload["data"] ||
        payload[:data] ||
        get_in(payload, ["payload", "data"]) ||
        get_in(payload, [:payload, :data]) ||
        %{}

    sent_messages = fetch_recent_sent_messages(state)

    case source do
      "gmail" ->
        google_source = google_source_from_context(state, context)
        incoming_messages = extract_email_batch(data, google_source)

        incoming =
          incoming_messages
          |> Enum.flat_map(&incoming_email_candidates(&1, state, sent_messages))

        important_fyi = important_fyi_candidates(incoming_messages, state, watch_rules)

        outgoing =
          sent_messages
          |> Enum.flat_map(&sent_commitment_candidates(&1, state, sent_messages))

        %{llm_candidates: incoming ++ outgoing, direct_insights: important_fyi}

      "google_calendar" ->
        %{
          llm_candidates:
            data
            |> extract_calendar_batch()
            |> Enum.flat_map(&meeting_follow_up_candidates(&1, state, sent_messages)),
          direct_insights: []
        }

      _ ->
        # Unknown payload format. Fall back to broad periodic scan.
        candidates_from_periodic_scan(state, context, watch_rules)
    end
  end

  defp candidates_from_pubsub_payload(_payload, state, context, watch_rules),
    do: candidates_from_periodic_scan(state, context, watch_rules)

  defp extract_email_batch(%{"messages" => messages}, google_source) when is_list(messages),
    do: annotate_google_items(messages, google_source)

  defp extract_email_batch(%{messages: messages}, google_source) when is_list(messages),
    do: annotate_google_items(messages, google_source)

  defp extract_email_batch(message, google_source) when is_map(message),
    do: annotate_google_items([message], google_source)

  defp extract_email_batch(_message, _google_source), do: []

  defp extract_calendar_batch(%{"events" => events}) when is_list(events), do: events
  defp extract_calendar_batch(%{events: events}) when is_list(events), do: events
  defp extract_calendar_batch(event) when is_map(event), do: [event]
  defp extract_calendar_batch(_), do: []

  defp fetch_recent_inbox_messages(state) do
    google_accounts_for_service(state, "gmail")
    |> Enum.flat_map(fn account ->
      provider = account_provider(account)

      case Gmail.fetch_recent_emails(state.user_id, state.email_scan_limit, provider: provider) do
        {:ok, value} ->
          annotate_google_items(value, account)

        {:error, reason} ->
          Logger.warning("InboxCalendarAdvisor failed to fetch inbox email",
            provider: provider,
            reason: inspect(reason)
          )

          []
      end
    end)
  end

  defp fetch_recent_sent_messages(state) do
    sent_limit = max(state.email_scan_limit * 2, 12)
    query = "in:sent newer_than:#{@sent_query_lookback_days}d"

    google_accounts_for_service(state, "gmail")
    |> Enum.flat_map(fn account ->
      provider = account_provider(account)

      case GmailHelpers.list_messages(state.user_id,
             max_results: sent_limit,
             query: query,
             label_ids: [],
             provider: provider
           ) do
        {:ok, value} ->
          annotate_google_items(value, account)

        {:error, reason} ->
          Logger.warning("InboxCalendarAdvisor failed to fetch sent email",
            provider: provider,
            reason: inspect(reason)
          )

          []
      end
    end)
  end

  defp fetch_recent_calendar_events(state) do
    google_accounts_for_service(state, "calendar")
    |> Enum.flat_map(fn account ->
      provider = account_provider(account)

      case GoogleCalendar.sync_calendar_events(state.user_id, provider: provider) do
        {:ok, value} ->
          value
          |> annotate_google_items(account)
          |> Enum.take(state.event_scan_limit)

        {:error, reason} ->
          Logger.warning("InboxCalendarAdvisor failed to fetch calendar",
            provider: provider,
            reason: inspect(reason)
          )

          []
      end
    end)
  end

  defp build_gmail_conversation_context(state, thread_id, trigger_message) do
    self_refs = gmail_self_refs(state)
    provider = read_string(trigger_message, "google_provider", nil)

    case Gmail.fetch_thread(state.user_id, thread_id, provider: provider) do
      {:ok, messages} when is_list(messages) and messages != [] ->
        ConversationContext.from_gmail(messages, trigger_message,
          self_refs: self_refs,
          default_owner: "user_owner"
        )

      {:error, reason} ->
        trigger_message
        |> List.wrap()
        |> ConversationContext.from_gmail(trigger_message,
          self_refs: self_refs,
          default_owner: "user_owner"
        )
        |> Map.put("notification_posture", "insufficient_context")
        |> Map.put("insufficient_context_reason", "gmail_thread_fetch_failed: #{inspect(reason)}")

      _ ->
        ConversationContext.from_gmail([trigger_message], trigger_message,
          self_refs: self_refs,
          default_owner: "user_owner"
        )
    end
  end

  defp gmail_self_refs(state) do
    ([state.user_id, state.google_account] ++ Enum.map(state.google_accounts, &account_email/1))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp google_accounts_for_service(state, service) do
    state.google_accounts
    |> Enum.filter(&account_supports_service?(&1, service))
  end

  defp google_source_from_context(state, context) do
    context
    |> Map.get(:event)
    |> case do
      %{topic: "email:" <> account_email} ->
        SourceScope.google_account_for_email(state.source_scope, account_email)

      _ ->
        nil
    end
  end

  defp annotate_google_items(items, google_source) when is_list(items) do
    provider = account_provider(google_source)
    account = account_email(google_source)

    Enum.map(items, fn item ->
      item
      |> stringify_keys()
      |> maybe_put("google_provider", provider)
      |> maybe_put("account", account)
    end)
  end

  defp annotate_google_items(_items, _google_source), do: []

  defp account_provider(account) when is_map(account) do
    normalize_string(Map.get(account, "provider"))
  end

  defp account_provider(_account), do: nil

  defp account_email(account) when is_map(account) do
    normalize_string(Map.get(account, "account_email"))
  end

  defp account_email(_account), do: nil

  defp account_supports_service?(account, service) when is_map(account) and is_binary(service) do
    service in read_list(account, "services")
  end

  defp account_supports_service?(_account, _service), do: false

  defp resolved_conversation?(context) when is_map(context) do
    read_string(context, "notification_posture", nil) == "resolved"
  end

  defp gmail_tracking_key("reply_urgent", thread_id) when is_binary(thread_id) do
    "gmail:thread:#{thread_id}:reply_owed"
  end

  defp gmail_tracking_key("commitment_unresolved", thread_id) when is_binary(thread_id) do
    "gmail:commitment:#{thread_id}"
  end

  defp gmail_tracking_key(_category, thread_id) when is_binary(thread_id) do
    "gmail:thread:#{thread_id}"
  end

  defp apply_gmail_attention_fields(candidate, context, tracking_key)
       when is_map(candidate) and is_map(context) and is_binary(tracking_key) do
    attention_mode = attention_mode_for_context(context)

    source_occurred_at =
      read_datetime(candidate, "source_occurred_at") || read_datetime(candidate, "due_at")

    change_summary = change_summary_for_context(context)
    material_change_kind = material_change_kind_for_context(context, attention_mode)
    ownership_state = read_string(context, "ownership_state", "unknown")
    importance_band = importance_band_for_candidate(candidate)

    revision_key =
      revision_key_for_candidate(
        tracking_key,
        attention_mode,
        ownership_state,
        read_string(context, "latest_activity_at", to_iso8601(source_occurred_at)),
        material_change_kind,
        read_string(candidate, "source_id", nil),
        to_iso8601(read_datetime(candidate, "due_at"))
      )

    metadata =
      candidate
      |> read_map("metadata")
      |> Map.put(
        "attention",
        %{
          "mode" => attention_mode,
          "importance_band" => importance_band,
          "founder_action_required" => attention_mode == "act_now",
          "ownership_state" => ownership_state,
          "material_change_kind" => material_change_kind,
          "change_summary" => change_summary,
          "revision_key" => revision_key,
          "re_notify_eligible" => true
        }
      )

    candidate
    |> Map.put("attention_mode", attention_mode)
    |> Map.put("tracking_key", tracking_key)
    |> Map.put("dedupe_key", "#{tracking_key}:#{revision_key}")
    |> Map.put("metadata", metadata)
  end

  defp apply_gmail_attention_fields(candidate, _context, _tracking_key), do: candidate

  defp attention_mode_for_context(context) when is_map(context) do
    case read_string(context, "notification_posture", nil) do
      "heads_up" -> "monitor"
      "insufficient_context" -> "monitor"
      _ -> "act_now"
    end
  end

  defp material_change_kind_for_context(context, "monitor") when is_map(context) do
    cond do
      read_string(context, "closure_state", nil) == "handoff" ->
        "ownership_shift"

      read_string(context, "notification_posture", nil) == "insufficient_context" ->
        "initial_detection"

      true ->
        "initial_detection"
    end
  end

  defp material_change_kind_for_context(context, "act_now") when is_map(context) do
    cond do
      read_boolean(context, "fresh_ask_after_acknowledgment", false) -> "new_direct_ask"
      true -> "initial_detection"
    end
  end

  defp material_change_kind_for_context(_context, _mode), do: "initial_detection"

  defp change_summary_for_context(context) when is_map(context) do
    ConversationContext.conversation_summary(context)
  end

  defp importance_band_for_candidate(candidate) when is_map(candidate) do
    case candidate |> read_map("metadata") |> read_string("importance_hint", nil) do
      "drop" -> "low"
      "digest" -> "medium"
      _ -> "high"
    end
  end

  defp revision_key_for_candidate(
         tracking_key,
         attention_mode,
         ownership_state,
         latest_activity_at,
         material_change_kind,
         source_id,
         due_at
       ) do
    %{
      tracking_key: tracking_key,
      attention_mode: attention_mode,
      ownership_state: ownership_state,
      latest_activity_at: latest_activity_at,
      material_change_kind: material_change_kind,
      source_id: source_id,
      due_at: due_at
    }
    |> Jason.encode!()
    |> then(fn payload -> :crypto.hash(:sha256, payload) end)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp gmail_watch_rules(user_id) when is_binary(user_id) do
    user_id
    |> PreferenceMemory.active_rules()
    |> Enum.filter(fn rule ->
      read_string(rule, "kind", nil) == "urgency_boost" and
        "gmail" in read_list(rule, "applies_to")
    end)
    |> Enum.take(@max_watch_rules)
  end

  defp gmail_watch_rules(_user_id), do: []

  defp important_fyi_candidates(emails, state, watch_rules) when is_list(emails) do
    Enum.flat_map(emails, &important_fyi_email_candidates(&1, state, watch_rules))
  end

  defp important_fyi_candidates(_emails, _state, _watch_rules), do: []

  defp important_fyi_email_candidates(email, state, watch_rules) when is_map(email) do
    subject = read_string(email, "subject", "(no subject)")
    snippet = read_string(email, "snippet", "")
    from = read_string(email, "from", "unknown sender")
    to = read_string(email, "to", "")
    message_id = read_string(email, "message_id", Ecto.UUID.generate())
    thread_id = read_string(email, "thread_id", message_id)
    labels = read_list(email, "labels") |> Enum.map(&to_string/1)
    occurred_at = message_timestamp(email)

    body =
      String.downcase(
        Enum.join(
          Enum.reject([subject, snippet, from, to, Enum.join(labels, " ")], &blank?/1),
          " "
        )
      )

    builtin = builtin_fyi_profile(body)
    watch_matches = matching_watch_rules(body, from, builtin.topics, watch_rules)

    if builtin.type == nil and watch_matches == [] do
      []
    else
      profile = merge_fyi_profile(builtin, watch_matches, subject, occurred_at)
      person = primary_contact(from) || from
      due_at = important_fyi_due_at(profile, occurred_at)

      evidence =
        profile.evidence
        |> maybe_append("Sender: #{from}.", present?(from))
        |> Enum.take(@max_evidence_points)

      record =
        commitment_record(
          "Review \"#{truncate(subject, 70)}\"",
          person,
          "gmail_thread:#{thread_id}",
          due_at,
          "unresolved",
          evidence,
          profile.recommended_action
        )

      dedupe_key = "gmail:fyi:#{thread_id}:#{profile.type}"

      if suppress_acknowledged_fyi?(state.user_id, dedupe_key, message_id) do
        []
      else
        [
          %{
            source: "gmail",
            source_id: message_id,
            source_occurred_at: occurred_at,
            category: "important_fyi",
            title: important_fyi_title(profile, subject),
            summary: profile.summary,
            recommended_action: profile.recommended_action,
            priority: profile.priority,
            confidence: profile.confidence,
            due_at: due_at,
            dedupe_key: dedupe_key,
            metadata:
              compact_map(%{
                "account" => read_string(email, "account", state.google_account),
                "thread_id" => thread_id,
                "from" => from,
                "to" => to,
                "subject" => subject,
                "labels" => labels,
                "ackable" => profile.ackable,
                "important_fyi" => true,
                "fyi_class" => profile.type,
                "watch_rule_ids" => Enum.map(watch_matches, & &1.rule_id),
                "watch_topics" => Enum.flat_map(watch_matches, & &1.topic_matches) |> Enum.uniq(),
                "matched_keywords" =>
                  Enum.flat_map(watch_matches, & &1.keyword_matches) |> Enum.uniq(),
                "telegram_fit_score" => profile.telegram_fit_score,
                "telegram_fit_reason" => profile.telegram_fit_reason,
                "why_now" => profile.why_now,
                "context_brief" => profile.why_now,
                "record" => record
              })
          }
          |> normalize_candidate(state)
        ]
      end
    end
  end

  defp important_fyi_email_candidates(_email, _state, _watch_rules), do: []

  defp builtin_fyi_profile(body) when is_binary(body) do
    account_risk_matches = matched_terms(body, @account_risk_terms)
    finance_matches = matched_terms(body, @finance_terms)
    app_store_matches = matched_terms(body, @app_store_connect_terms)

    cond do
      account_risk_matches != [] ->
        %{
          type: "account_risk",
          topics: ["account_risk"],
          summary:
            "This looks like an account restriction or access issue that can block work or revenue.",
          recommended_action:
            "Open the notice now, confirm the exact restriction, and coordinate the unblock owner today.",
          priority: 96,
          confidence: 0.94,
          telegram_fit_score: 0.95,
          telegram_fit_reason: "Account restrictions are high-impact and time-sensitive.",
          why_now:
            "A blocked or restricted account can stop important work until someone resolves it.",
          ackable: false,
          evidence:
            Enum.map(account_risk_matches, fn match ->
              "Account-risk signal detected: #{match}."
            end)
        }

      app_store_matches != [] ->
        platform_profile(app_store_matches)

      finance_matches != [] ->
        %{
          type: "finance_important",
          topics: ["finance"],
          summary: "This looks like a finance or tax update that affects money or planning.",
          recommended_action:
            "Review the update and decide whether it changes any filing, transfer, or contribution work.",
          priority: 84,
          confidence: 0.86,
          telegram_fit_score: 0.84,
          telegram_fit_reason:
            "Money and tax-related updates are worth surfacing even without reply debt.",
          why_now:
            "Finance and tax updates can affect deadlines, cash, or contribution planning.",
          ackable: true,
          evidence:
            Enum.map(finance_matches, fn match ->
              "Finance signal detected: #{match}."
            end)
        }

      true ->
        %{
          type: nil,
          topics: [],
          summary: nil,
          recommended_action: nil,
          priority: 0,
          confidence: 0.0,
          telegram_fit_score: 0.0,
          telegram_fit_reason: nil,
          why_now: nil,
          ackable: false,
          evidence: []
        }
    end
  end

  defp builtin_fyi_profile(_body) do
    %{
      type: nil,
      topics: [],
      summary: nil,
      recommended_action: nil,
      priority: 0,
      confidence: 0.0,
      telegram_fit_score: 0.0,
      telegram_fit_reason: nil,
      why_now: nil,
      ackable: false,
      evidence: []
    }
  end

  defp platform_profile(matches) do
    cond do
      "rejected" in matches or "metadata rejected" in matches ->
        %{
          type: "platform_status",
          topics: ["platform_status", "app_store_connect"],
          summary: "App review status changed in a way that likely needs intervention.",
          recommended_action:
            "Review the rejection details and decide the fix or follow-up today.",
          priority: 92,
          confidence: 0.9,
          telegram_fit_score: 0.9,
          telegram_fit_reason:
            "A review rejection can block release timing and needs fast triage.",
          why_now: "App review status changed and may block release unless someone responds.",
          ackable: false,
          evidence:
            Enum.map(matches, fn match ->
              "Platform-status signal detected: #{match}."
            end)
        }

      true ->
        %{
          type: "platform_status",
          topics: ["platform_status", "app_store_connect"],
          summary:
            "App review status changed. This is important FYI because it affects release timing.",
          recommended_action:
            "Acknowledge the status change and monitor it; step in only if the review stalls or changes again.",
          priority: 82,
          confidence: 0.87,
          telegram_fit_score: 0.83,
          telegram_fit_reason:
            "Release-status changes are important FYI even when no reply is owed.",
          why_now: "App review state changed and could affect release planning.",
          ackable: true,
          evidence:
            Enum.map(matches, fn match ->
              "Platform-status signal detected: #{match}."
            end)
        }
    end
  end

  defp matching_watch_rules(body, from, derived_topics, rules)
       when is_binary(body) and is_binary(from) and is_list(derived_topics) and is_list(rules) do
    sender_domains = sender_domains(from)

    rules
    |> Enum.reduce([], fn rule, acc ->
      filters = read_map(rule, "filters")
      topic_matches = intersect_topics(read_list(filters, "topics"), derived_topics)
      keyword_matches = matched_terms(body, read_list(filters, "keywords"))
      domain_matches = intersect_topics(read_list(filters, "sender_domains"), sender_domains)

      if topic_matches != [] or keyword_matches != [] or domain_matches != [] do
        [
          %{
            rule_id: read_string(rule, "id", nil),
            label: read_string(rule, "label", "watch topic"),
            delivery_mode: read_string(filters, "delivery_mode", "important_fyi"),
            ackable: read_boolean(filters, "ackable", false),
            priority_bias: read_string(filters, "priority_bias", "high"),
            topic_matches: topic_matches,
            keyword_matches: keyword_matches,
            domain_matches: domain_matches
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp matching_watch_rules(_body, _from, _derived_topics, _rules), do: []

  defp merge_fyi_profile(builtin, watch_matches, subject, occurred_at) do
    watch_topics = watch_matches |> Enum.flat_map(& &1.topic_matches) |> Enum.uniq()
    keyword_matches = watch_matches |> Enum.flat_map(& &1.keyword_matches) |> Enum.uniq()
    domain_matches = watch_matches |> Enum.flat_map(& &1.domain_matches) |> Enum.uniq()
    watch_label = watch_matches |> Enum.map(& &1.label) |> Enum.find(&present?/1)
    watch_delivery_mode = Enum.find_value(watch_matches, & &1.delivery_mode)
    watch_ackable = Enum.any?(watch_matches, & &1.ackable)
    watch_priority_bonus = if Enum.any?(watch_matches), do: 8, else: 0
    watch_reason = watch_reason_text(watch_matches)

    base_type =
      cond do
        builtin.type != nil -> builtin.type
        watch_matches != [] -> "watch_topic"
        true -> "important_fyi"
      end

    due_at = important_fyi_due_at(%{type: base_type, summary: builtin.summary}, occurred_at)

    %{
      type: base_type,
      summary:
        builtin.summary ||
          "This matches a saved watch topic and looks worth surfacing.",
      recommended_action:
        builtin.recommended_action ||
          default_watch_action(due_at),
      priority:
        builtin.priority
        |> Kernel.+(watch_priority_bonus)
        |> maybe_raise_priority(watch_delivery_mode == "interrupt_now", 90)
        |> clamp(0, 100),
      confidence:
        builtin.confidence
        |> maybe_add_float(0.09, watch_matches != [])
        |> clamp(0.0, 1.0),
      telegram_fit_score:
        builtin.telegram_fit_score
        |> maybe_add_float(0.12, watch_matches != [])
        |> maybe_raise_float(watch_delivery_mode == "interrupt_now", 0.9)
        |> clamp(0.0, 1.0),
      telegram_fit_reason:
        builtin.telegram_fit_reason ||
          "This matches a saved watch topic and should be surfaced in Telegram.",
      why_now:
        first_present_string([
          watch_reason,
          builtin.why_now,
          "This looks important based on your saved watch preferences."
        ]),
      ackable: builtin.ackable or watch_ackable or watch_delivery_mode == "important_fyi",
      watch_label: watch_label,
      evidence:
        builtin.evidence ++
          Enum.map(keyword_matches, &"Matched saved keyword: #{&1}.") ++
          Enum.map(domain_matches, &"Matched saved sender domain: #{&1}.") ++
          Enum.map(watch_topics, &"Matched saved topic: #{&1}."),
      subject: subject
    }
  end

  defp important_fyi_title(profile, subject) do
    prefix =
      case profile.type do
        "account_risk" -> "Account risk"
        "platform_status" -> "Platform status"
        "finance_important" -> "Finance update"
        "watch_topic" -> Map.get(profile, :watch_label) || "Important FYI"
        _ -> "Important FYI"
      end

    "#{prefix}: #{truncate(subject, 90)}"
  end

  defp important_fyi_due_at(profile, occurred_at) do
    base = occurred_at || DateTime.utc_now()

    case profile.type do
      "account_risk" -> DateTime.add(base, 4, :hour)
      "platform_status" -> DateTime.add(base, 12, :hour)
      "finance_important" -> DateTime.add(base, 24, :hour)
      _ -> DateTime.add(base, 24, :hour)
    end
  end

  defp watch_reason_text([]), do: nil

  defp watch_reason_text(watch_matches) do
    labels =
      watch_matches
      |> Enum.map(& &1.label)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    case labels do
      [] -> nil
      [label] -> "This matches your saved watch rule: #{label}."
      values -> "This matches your saved watch rules: #{Enum.join(values, ", ")}."
    end
  end

  defp default_watch_action(due_at),
    do: "Review the update and decide the next step#{watch_due_suffix(due_at)}."

  defp watch_due_suffix(%DateTime{} = due_at) do
    case hours_until(due_at) do
      hours when is_integer(hours) and hours <= 12 -> " today"
      _ -> ""
    end
  end

  defp watch_due_suffix(_), do: ""

  defp sender_domains(value) when is_binary(value) do
    value
    |> parse_email_addresses()
    |> Enum.map(fn email ->
      email
      |> String.split("@", parts: 2)
      |> Enum.at(1)
      |> normalize_string()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp sender_domains(_), do: []

  defp intersect_topics(left, right) when is_list(left) and is_list(right) do
    left_set = MapSet.new(Enum.map(left, &normalize_topic/1))
    right_set = MapSet.new(Enum.map(right, &normalize_topic/1))

    left_set
    |> MapSet.intersection(right_set)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp intersect_topics(_left, _right), do: []

  defp normalize_topic(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_topic(value), do: value |> to_string() |> normalize_topic()

  defp maybe_raise_priority(value, true, minimum), do: max(value, minimum)
  defp maybe_raise_priority(value, false, _minimum), do: value

  defp maybe_raise_float(value, true, minimum), do: max(value, minimum)
  defp maybe_raise_float(value, false, _minimum), do: value

  defp first_present_string(values) when is_list(values) do
    Enum.find_value(values, &normalize_string/1)
  end

  defp suppress_acknowledged_fyi?(user_id, dedupe_key, source_id)
       when is_binary(user_id) and is_binary(dedupe_key) and is_binary(source_id) do
    case Repo.get_by(Insight, user_id: user_id, dedupe_key: dedupe_key) do
      %Insight{status: status, source_id: ^source_id}
      when status in ["acknowledged", "dismissed"] ->
        true

      _ ->
        false
    end
  end

  defp suppress_acknowledged_fyi?(_user_id, _dedupe_key, _source_id), do: false

  defp incoming_email_candidates(email, state, sent_messages) when is_map(email) do
    subject = read_string(email, "subject", "(no subject)")
    snippet = read_string(email, "snippet", "")
    from = read_string(email, "from", "unknown sender")
    to = read_string(email, "to", "")
    message_id = read_string(email, "message_id", Ecto.UUID.generate())
    thread_id = read_string(email, "thread_id", message_id)
    labels = read_list(email, "labels") |> Enum.map(&to_string/1)
    occurred_at = message_timestamp(email)

    body =
      String.downcase(
        Enum.join(
          Enum.reject([subject, snippet, from, to, Enum.join(labels, " ")], &blank?/1),
          " "
        )
      )

    reply_matches = matched_terms(body, @reply_request_terms)
    deadline_matches = matched_terms(body, @deadline_terms)
    needs_reply? = reply_matches != [] or deadline_matches != []

    sender_is_user? = string_contains?(from, state.user_id)

    followthrough_email =
      find_sent_reply_for_thread(sent_messages, thread_id, occurred_at, from, state.user_id)

    unresolved? = is_nil(followthrough_email)

    cond do
      sender_is_user? ->
        []

      not needs_reply? ->
        []

      not unresolved? ->
        []

      true ->
        conversation_context = build_gmail_conversation_context(state, thread_id, email)

        if resolved_conversation?(conversation_context) do
          []
        else
          triage =
            gmail_reply_triage(
              body,
              labels,
              conversation_context,
              thread_id,
              occurred_at,
              sent_messages
            )

          if suppress_cold_outreach?(triage) do
            Logger.info("InboxCalendarAdvisor suppressed cold outreach reply candidate",
              thread_id: thread_id,
              from: from,
              importance_hint: triage["importance_hint"],
              outreach_indicators: triage["outreach_indicators"]
            )

            []
          else
            if suppress_low_signal_reply_candidate?(triage) do
              Logger.info("InboxCalendarAdvisor suppressed low-signal reply candidate",
                thread_id: thread_id,
                from: from,
                importance_hint: triage["importance_hint"],
                reply_obligation_hint: triage["reply_obligation_hint"]
              )

              []
            else
              person = primary_contact(from) || from
              inferred_deadline = infer_deadline_from_text(body, occurred_at)

              due_at =
                inferred_deadline || DateTime.add(occurred_at || DateTime.utc_now(), 8, :hour)

              commitment = "Reply to #{person} on \"#{truncate(subject, 70)}\""

              evidence =
                []
                |> maybe_append("Incoming thread from #{from}.", present?(from))
                |> maybe_append(
                  "Reply request terms: #{Enum.join(reply_matches, ", ")}.",
                  reply_matches != []
                )
                |> maybe_append(
                  "Deadline cues: #{Enum.join(deadline_matches, ", ")}.",
                  deadline_matches != []
                )
                |> maybe_append("No sent reply found after #{format_dt(occurred_at)}.", true)
                |> Enum.take(@max_evidence_points)

              next_action =
                "Reply now with owner, ETA, and the exact artifact or update you committed to."

              confidence =
                0.66
                |> maybe_add_float(0.14, reply_matches != [])
                |> maybe_add_float(0.06, "IMPORTANT" in labels)
                |> maybe_add_float(0.05, "UNREAD" in labels)
                |> maybe_add_float(0.05, deadline_matches != [])
                |> clamp(0.0, 1.0)

              priority = urgency_priority(due_at, 82)

              summary =
                "You still owe #{person} a response #{deadline_phrase(due_at)}. No sent follow-up was detected."

              record =
                commitment_record(
                  commitment,
                  person,
                  "gmail_thread:#{thread_id}",
                  due_at,
                  "unresolved",
                  evidence,
                  next_action
                )

              [
                %{
                  source: "gmail",
                  source_id: message_id,
                  source_occurred_at: occurred_at,
                  category: "reply_urgent",
                  title: "Reply owed: #{truncate(subject, 90)}",
                  summary: summary,
                  recommended_action: next_action,
                  priority: priority,
                  confidence: confidence,
                  due_at: due_at,
                  tracking_key: gmail_tracking_key("reply_urgent", thread_id),
                  metadata:
                    compact_map(%{
                      "account" => read_string(email, "account", state.google_account),
                      "thread_id" => thread_id,
                      "from" => from,
                      "to" => to,
                      "subject" => subject,
                      "labels" => labels,
                      "signals" => reply_matches,
                      "context_brief" => "Incoming request from #{person}.",
                      "record" => record
                    })
                    |> Map.merge(triage)
                }
                |> normalize_candidate(state)
                |> ConversationContext.apply_to_candidate(conversation_context)
                |> apply_gmail_attention_fields(
                  conversation_context,
                  gmail_tracking_key("reply_urgent", thread_id)
                )
              ]
            end
          end
        end
    end
  end

  defp incoming_email_candidates(_email, _state, _sent_messages), do: []

  defp sent_commitment_candidates(sent_email, state, sent_messages) when is_map(sent_email) do
    subject = read_string(sent_email, "subject", "(no subject)")
    snippet = read_string(sent_email, "snippet", "")
    to = read_string(sent_email, "to", "")
    from = read_string(sent_email, "from", "")
    message_id = read_string(sent_email, "message_id", Ecto.UUID.generate())
    thread_id = read_string(sent_email, "thread_id", message_id)
    occurred_at = message_timestamp(sent_email)

    body =
      String.downcase(
        Enum.join(
          Enum.reject([subject, snippet, from, to], &blank?/1),
          " "
        )
      )

    promise_matches = matched_terms(body, @promise_terms)
    action_matches = matched_terms(body, @commitment_action_terms)
    explicit_promise? = promise_matches != [] and action_matches != []

    completion =
      find_sent_followthrough_for_commitment(sent_email, sent_messages, state.user_id)

    unresolved? = is_nil(completion)

    cond do
      not explicit_promise? ->
        []

      not unresolved? ->
        []

      true ->
        conversation_context = build_gmail_conversation_context(state, thread_id, sent_email)

        if resolved_conversation?(conversation_context) do
          []
        else
          person = primary_contact(to) || "the recipient"
          inferred_deadline = infer_deadline_from_text(body, occurred_at)
          due_at = inferred_deadline || DateTime.add(occurred_at || DateTime.utc_now(), 24, :hour)

          commitment = extract_commitment_line(subject, snippet, person)
          artifact_hint = extract_artifact_hint(body)

          nudge_line =
            case artifact_hint do
              nil ->
                "You committed to #{person} and no follow-up has gone out yet."

              artifact ->
                "You said you'd send #{artifact} to #{person} #{deadline_phrase(due_at)}. No reply has gone out yet."
            end

          evidence =
            []
            |> maybe_append("Sent commitment email to #{truncate(to, 80)}.", present?(to))
            |> maybe_append(
              "Promise terms detected: #{Enum.join(promise_matches, ", ")}.",
              promise_matches != []
            )
            |> maybe_append(
              "Action terms detected: #{Enum.join(action_matches, ", ")}.",
              action_matches != []
            )
            |> maybe_append("No later reply, forward, or artifact delivery found.", true)
            |> Enum.take(@max_evidence_points)

          next_action =
            "Send the promised follow-through now and explicitly confirm delivery in the same thread."

          confidence =
            0.74
            |> maybe_add_float(0.08, length(promise_matches) >= 2)
            |> maybe_add_float(0.06, inferred_deadline != nil)
            |> maybe_add_float(0.06, artifact_hint != nil)
            |> maybe_add_float(0.04, present?(to))
            |> clamp(0.0, 1.0)

          priority = urgency_priority(due_at, 86)

          record =
            commitment_record(
              commitment,
              person,
              "gmail_sent_message:#{message_id}",
              due_at,
              "unresolved",
              evidence,
              next_action
            )

          [
            %{
              source: "gmail",
              source_id: message_id,
              source_occurred_at: occurred_at,
              category: "commitment_unresolved",
              title: truncate(nudge_line, 180),
              summary:
                "The commitment still appears open for #{person} #{deadline_phrase(due_at)}. No completion evidence was found in sent email.",
              recommended_action: next_action,
              priority: priority,
              confidence: confidence,
              due_at: due_at,
              tracking_key: gmail_tracking_key("commitment_unresolved", thread_id),
              metadata:
                compact_map(%{
                  "account" => read_string(sent_email, "account", state.google_account),
                  "thread_id" => thread_id,
                  "from" => from,
                  "to" => to,
                  "subject" => subject,
                  "signals" => Enum.uniq(promise_matches ++ action_matches),
                  "context_brief" => "Explicit promise made to #{person}.",
                  "record" => record
                })
            }
            |> normalize_candidate(state)
            |> ConversationContext.apply_to_candidate(conversation_context)
            |> apply_gmail_attention_fields(
              conversation_context,
              gmail_tracking_key("commitment_unresolved", thread_id)
            )
          ]
        end
    end
  end

  defp sent_commitment_candidates(_sent_email, _state, _sent_messages), do: []

  defp meeting_follow_up_candidates(event, state, sent_messages) when is_map(event) do
    summary = read_string(event, "summary", "(untitled meeting)")
    description = read_string(event, "description", "")
    organizer = read_string(event, "organizer", "")
    location = read_string(event, "location", "")
    attendees = read_list(event, "attendees")
    attendee_count = length(attendees)
    attendee_preview = attendee_preview(attendees)
    response_counts = attendee_response_counts(attendees)
    event_id = read_string(event, "event_id", Ecto.UUID.generate())
    end_at = read_datetime(event, "end") || read_datetime(event, "start")

    body =
      String.downcase(
        Enum.join(
          Enum.reject([summary, description, organizer, location, attendee_preview], &blank?/1),
          " "
        )
      )

    importance_matches = matched_terms(body, @important_meeting_terms)

    important_meeting? =
      importance_matches != [] or attendee_count >= 5

    ended_recently? =
      case end_at do
        %DateTime{} ->
          hours = hours_since(end_at)
          is_integer(hours) and hours >= 0 and hours <= state.follow_up_window_hours

        _ ->
          false
      end

    follow_up_email =
      find_meeting_follow_up_email(event, sent_messages, end_at)

    unresolved? = is_nil(follow_up_email)

    cond do
      not important_meeting? ->
        []

      not ended_recently? ->
        []

      not unresolved? ->
        []

      true ->
        person =
          primary_contact(organizer) || primary_contact(attendee_preview) || "the attendees"

        due_at = DateTime.add(end_at, 8, :hour)
        meeting_day = Calendar.strftime(end_at, "%A")

        commitment = "Send owners and next steps after #{summary}"

        evidence =
          []
          |> maybe_append("#{summary} ended #{hours_since(end_at)}h ago.", true)
          |> maybe_append(
            "Meeting importance signals: #{Enum.join(importance_matches, ", ")}.",
            importance_matches != []
          )
          |> maybe_append(
            "No sent recap with owners/next steps found after the meeting.",
            true
          )
          |> Enum.take(@max_evidence_points)

        next_action = "Send a short recap covering owners, next steps, and due dates."

        confidence =
          0.71
          |> maybe_add_float(0.1, importance_matches != [])
          |> maybe_add_float(0.07, attendee_count >= 5)
          |> maybe_add_float(0.05, response_counts != %{})
          |> clamp(0.0, 1.0)

        priority = urgency_priority(due_at, 84)

        record =
          commitment_record(
            commitment,
            person,
            "calendar_event:#{event_id}",
            due_at,
            "unresolved",
            evidence,
            next_action
          )

        [
          %{
            source: "calendar",
            source_id: event_id,
            source_occurred_at: end_at,
            category: "meeting_follow_up",
            title: "Post-meeting follow-up owed: #{truncate(summary, 90)}",
            summary:
              "After the #{meeting_day} planning meeting, you still owe owners and next steps.",
            recommended_action: next_action,
            priority: priority,
            confidence: confidence,
            due_at: due_at,
            dedupe_key: "calendar:follow_up:#{event_id}",
            metadata:
              compact_map(%{
                "account" => read_string(event, "account", state.google_account),
                "summary" => summary,
                "organizer" => organizer,
                "attendee_count" => attendee_count,
                "attendee_preview" => attendee_preview,
                "response_counts" => response_counts,
                "location" => location,
                "description_excerpt" => non_empty_truncated(description, 180),
                "signals" => importance_matches,
                "context_brief" => "Important meeting ended without follow-up evidence.",
                "record" => record
              })
          }
          |> normalize_candidate(state)
        ]
    end
  end

  defp meeting_follow_up_candidates(_event, _state, _sent_messages), do: []

  defp persist_insights([], _state, _context), do: {:ok, []}

  defp persist_insights(insights, state, context) do
    case Insights.record_many(state.user_id, context.agent_id, insights) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("InboxCalendarAdvisor failed to persist insights", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp persist_and_reply(insights, state, context) do
    insights = prioritize_insights(insights, state.max_insights_per_cycle)
    result = persist_insights(insights, state, context)

    case result do
      {:ok, stored} ->
        {:emit,
         {:insights_recorded,
          %{
            count: length(stored),
            user_id: state.user_id,
            categories: stored |> Enum.map(& &1.category) |> Enum.uniq()
          }},
         %{
           state
           | pending_candidates: [],
             pending_direct_insights: [],
             last_scan_at: context.timestamp
         }}

      {:error, reason} ->
        {:emit, {:insight_error, %{reason: inspect(reason), attempted_count: length(insights)}},
         %{
           state
           | pending_candidates: [],
             pending_direct_insights: [],
             last_scan_at: context.timestamp
         }}
    end
  end

  defp prioritize_insights(insights, limit) when is_list(insights) and is_integer(limit) do
    insights
    |> Enum.sort_by(
      fn insight ->
        {read_integer(insight, "priority", 0), read_float(insight, "confidence", 0.0)}
      end,
      :desc
    )
    |> Enum.take(limit)
  end

  defp parse_llm_response(content, candidates, state) when is_binary(content) do
    with {:ok, decoded} <- decode_json_payload(content),
         list when is_list(list) <- extract_llm_list(decoded) do
      by_key = Map.new(candidates, fn candidate -> {candidate["dedupe_key"], candidate} end)

      list
      |> Enum.reduce([], fn item, acc ->
        case merge_llm_item(item, by_key, state.min_confidence) do
          nil -> acc
          merged -> [merged | acc]
        end
      end)
      |> Enum.reverse()
    else
      _ -> []
    end
  end

  defp parse_llm_response(_content, _candidates, _state), do: []

  defp decode_json_payload(content) do
    case Jason.decode(content) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} ->
        case Regex.run(~r/```json\s*(\[.*\]|\{.*\})\s*```/s, content, capture: :all_but_first) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp merge_llm_item(item, by_key, min_confidence) when is_map(item) do
    dedupe_key = read_string(item, "dedupe_key", nil)
    base = if is_binary(dedupe_key), do: Map.get(by_key, dedupe_key), else: nil

    if is_nil(base) or not actionable_llm_item?(item, base) do
      nil
    else
      confidence =
        clamp(read_float(item, "confidence", read_float(base, "confidence", 0.5)), 0.0, 1.0)

      if confidence < min_confidence do
        nil
      else
        obligation_type = read_string(item, "obligation_type", nil)
        reasoning_summary = read_string(item, "reasoning_summary", nil)
        human_counterparty = read_boolean(item, "human_counterparty", false)
        missing_followthrough = read_boolean(item, "missing_followthrough_evidence", false)
        notification_posture = resolve_notification_posture(item, base)
        attention_mode = resolve_attention_mode(item, base, notification_posture)

        interrupt_now =
          read_boolean(item, "interrupt_now", attention_mode == "act_now")

        false_positive_risk = clamp(read_float(item, "false_positive_risk", 1.0), 0.0, 1.0)
        telegram_fit_score = clamp(read_float(item, "telegram_fit_score", confidence), 0.0, 1.0)
        telegram_fit_reason = read_string(item, "telegram_fit_reason", nil)
        why_now = read_string(item, "why_now", nil)
        follow_up_ideas = read_string_list(item, "follow_up_ideas", @max_follow_up_ideas)
        merged_record = resolve_record(item, base)
        base_metadata = read_map(base, "metadata")
        reply_debt_candidate? = gmail_reply_candidate?(base)
        thread_type = resolve_thread_type(item, base_metadata)

        solicited =
          resolve_boolean_flag(item, base_metadata, "solicited", "solicited_hint", false)

        prior_user_engagement =
          resolve_boolean_flag(
            item,
            base_metadata,
            "prior_user_engagement",
            "prior_user_engagement",
            false
          )

        explicit_user_commitment =
          resolve_boolean_flag(
            item,
            base_metadata,
            "explicit_user_commitment",
            "explicit_user_commitment",
            false
          )

        reply_obligation =
          resolve_boolean_flag(
            item,
            base_metadata,
            "reply_obligation",
            "reply_obligation_hint",
            true
          )

        importance = resolve_importance(item, base_metadata)

        evidence_for_reply_owed =
          resolve_string_list_flag(
            item,
            base_metadata,
            "evidence_for_reply_owed",
            "evidence_for_reply_owed",
            @max_evidence_points
          )

        evidence_against_reply_owed =
          resolve_string_list_flag(
            item,
            base_metadata,
            "evidence_against_reply_owed",
            "evidence_against_reply_owed",
            @max_evidence_points
          )

        decision_reason =
          read_string(item, "decision_reason", nil) ||
            read_string(base_metadata, "decision_reason", nil)

        conversation_context =
          base_metadata
          |> read_map("conversation_context")
          |> maybe_put("notification_posture", notification_posture)

        if String.downcase(Map.get(merged_record, "status", "unresolved")) != "unresolved" do
          nil
        else
          base
          |> Map.put("title", read_string(item, "title", base["title"]))
          |> Map.put("summary", read_string(item, "summary", base["summary"]))
          |> Map.put(
            "recommended_action",
            read_string(item, "recommended_action", base["recommended_action"])
          )
          |> Map.put(
            "priority",
            clamp(read_integer(item, "priority", read_integer(base, "priority", 50)), 0, 100)
          )
          |> Map.put("confidence", confidence)
          |> Map.put("attention_mode", attention_mode)
          |> Map.update("metadata", %{}, fn metadata ->
            metadata
            |> stringify_keys()
            |> Map.put("telegram_fit_score", telegram_fit_score)
            |> maybe_put("telegram_fit_reason", telegram_fit_reason)
            |> maybe_put("why_now", why_now)
            |> maybe_put("obligation_type", obligation_type)
            |> maybe_put("reasoning_summary", reasoning_summary)
            |> maybe_put("human_counterparty", human_counterparty)
            |> maybe_put("missing_followthrough_evidence", missing_followthrough)
            |> maybe_put("interrupt_now", interrupt_now)
            |> maybe_put("false_positive_risk", false_positive_risk)
            |> maybe_put("thread_type", if(reply_debt_candidate?, do: thread_type))
            |> maybe_put("solicited", if(reply_debt_candidate?, do: solicited))
            |> maybe_put(
              "prior_user_engagement",
              if(reply_debt_candidate?, do: prior_user_engagement)
            )
            |> maybe_put(
              "explicit_user_commitment",
              if(reply_debt_candidate?, do: explicit_user_commitment)
            )
            |> maybe_put("reply_obligation", if(reply_debt_candidate?, do: reply_obligation))
            |> maybe_put("importance", if(reply_debt_candidate?, do: importance))
            |> maybe_put_list(
              "evidence_for_reply_owed",
              if(reply_debt_candidate?, do: evidence_for_reply_owed, else: [])
            )
            |> maybe_put_list(
              "evidence_against_reply_owed",
              if(reply_debt_candidate?, do: evidence_against_reply_owed, else: [])
            )
            |> maybe_put("decision_reason", if(reply_debt_candidate?, do: decision_reason))
            |> maybe_put_list("follow_up_ideas", follow_up_ideas)
            |> maybe_put_map("conversation_context", conversation_context)
            |> sync_attention_metadata(attention_mode, conversation_context, why_now, base)
            |> Map.put("record", merged_record)
            |> Map.put("commitment", merged_record["commitment"])
            |> Map.put("person", merged_record["person"])
            |> Map.put("source", merged_record["source"])
            |> Map.put("deadline", merged_record["deadline"])
            |> Map.put("status", merged_record["status"])
            |> Map.put("evidence", merged_record["evidence"])
            |> Map.put("next_action", merged_record["next_action"])
            |> Map.put("feedback_tuned", true)
          end)
          |> put_detail_metadata()
        end
      end
    end
  end

  defp merge_llm_item(_item, _by_key, _min_confidence), do: nil

  defp actionable_llm_item?(item, base) when is_map(item) do
    base_metadata = read_map(base, "metadata")
    actionability = read_string(item, "actionability", "") |> String.downcase()
    human_counterparty = read_boolean(item, "human_counterparty", false)
    missing_followthrough = read_boolean(item, "missing_followthrough_evidence", false)
    notification_posture = resolve_notification_posture(item, base)
    attention_mode = resolve_attention_mode(item, base, notification_posture)
    false_positive_risk = read_float(item, "false_positive_risk", 1.0)
    reply_debt_candidate? = gmail_reply_candidate?(base)

    reply_obligation =
      resolve_boolean_flag(item, base_metadata, "reply_obligation", "reply_obligation_hint", true)

    importance = resolve_importance(item, base_metadata)

    evidence_for_reply_owed =
      resolve_string_list_flag(
        item,
        base_metadata,
        "evidence_for_reply_owed",
        "evidence_for_reply_owed",
        @max_evidence_points
      )

    thread_type = resolve_thread_type(item, base_metadata)

    prior_user_engagement =
      resolve_boolean_flag(
        item,
        base_metadata,
        "prior_user_engagement",
        "prior_user_engagement",
        false
      )

    explicit_user_commitment =
      resolve_boolean_flag(
        item,
        base_metadata,
        "explicit_user_commitment",
        "explicit_user_commitment",
        false
      )

    actionability == "actionable" and
      human_counterparty and
      missing_followthrough and
      attention_mode in ["act_now", "monitor"] and
      false_positive_risk <= 0.35 and
      reply_debt_gate_passes?(
        reply_debt_candidate?,
        reply_obligation,
        importance,
        evidence_for_reply_owed,
        thread_type,
        prior_user_engagement,
        explicit_user_commitment
      )
  end

  defp resolve_notification_posture(item, base) do
    item_posture = read_string(item, "notification_posture", nil)

    cond do
      item_posture in ["interrupt_now", "heads_up", "insufficient_context"] ->
        item_posture

      read_boolean(item, "interrupt_now", false) ->
        "interrupt_now"

      true ->
        base
        |> read_map("metadata")
        |> read_map("conversation_context")
        |> read_string("notification_posture", nil)
    end
  end

  defp resolve_attention_mode(item, base, notification_posture) do
    case read_string(item, "attention_mode", nil) do
      "act_now" ->
        "act_now"

      "monitor" ->
        "monitor"

      _ ->
        case read_string(base, "attention_mode", nil) do
          mode when mode in ["act_now", "monitor"] ->
            mode

          _ ->
            if notification_posture in ["heads_up", "insufficient_context"],
              do: "monitor",
              else: "act_now"
        end
    end
  end

  defp sync_attention_metadata(metadata, attention_mode, conversation_context, why_now, base)
       when is_map(metadata) and is_map(base) do
    attention = read_map(metadata, "attention")
    base_attention = base |> read_map("metadata") |> read_map("attention")

    Map.put(metadata, "attention", %{
      "mode" => attention_mode,
      "importance_band" =>
        read_string(
          attention,
          "importance_band",
          read_string(base_attention, "importance_band", "high")
        ),
      "founder_action_required" => attention_mode == "act_now",
      "ownership_state" =>
        read_string(
          attention,
          "ownership_state",
          read_string(
            conversation_context,
            "ownership_state",
            read_string(base_attention, "ownership_state", "unknown")
          )
        ),
      "material_change_kind" =>
        read_string(
          attention,
          "material_change_kind",
          read_string(base_attention, "material_change_kind", "initial_detection")
        ),
      "change_summary" =>
        read_string(
          attention,
          "change_summary",
          why_now || read_string(base_attention, "change_summary", nil)
        ),
      "revision_key" =>
        read_string(attention, "revision_key", read_string(base_attention, "revision_key", nil)),
      "re_notify_eligible" =>
        read_boolean(
          attention,
          "re_notify_eligible",
          read_boolean(base_attention, "re_notify_eligible", true)
        )
    })
  end

  defp resolve_record(item, base) do
    base_metadata = read_map(base, "metadata")
    base_record = read_map(base_metadata, "record")

    commitment =
      read_string(item, "commitment", nil) ||
        read_string(base_record, "commitment", nil) ||
        read_string(base_metadata, "commitment", read_string(base, "title", "Follow through"))

    person =
      read_string(item, "person", nil) ||
        read_string(base_record, "person", nil) ||
        read_string(base_metadata, "person", "unknown")

    source =
      read_string(item, "source", nil) ||
        read_string(base_record, "source", nil) ||
        read_string(base_metadata, "source", read_string(base, "source", "gmail"))

    deadline =
      read_string(item, "deadline", nil) ||
        read_string(base_record, "deadline", nil) ||
        read_string(base_metadata, "deadline", nil) ||
        to_iso8601(read_datetime(base, "due_at"))

    status =
      read_string(item, "status", nil) ||
        read_string(base_record, "status", nil) ||
        read_string(base_metadata, "status", "unresolved")

    evidence =
      case read_string_list(item, "evidence", @max_evidence_points) do
        [] ->
          case read_string_list(base_record, "evidence", @max_evidence_points) do
            [] -> read_string_list(base_metadata, "evidence", @max_evidence_points)
            values -> values
          end

        values ->
          values
      end

    next_action =
      read_string(item, "next_action", nil) ||
        read_string(base_record, "next_action", nil) ||
        read_string(base_metadata, "next_action", read_string(base, "recommended_action", ""))

    compact_map(%{
      "commitment" => commitment,
      "person" => person,
      "source" => source,
      "deadline" => deadline,
      "status" => status,
      "evidence" => evidence,
      "next_action" => next_action
    })
  end

  defp high_signal_unresolved?(candidate, state) do
    confidence = read_float(candidate, "confidence", 0.0)
    priority = read_integer(candidate, "priority", 0)
    min_threshold = max(state.min_confidence, 0.72)
    unresolved? = unresolved_commitment?(candidate)

    unresolved? and confidence >= min_threshold and priority >= 70
  end

  defp unresolved_commitment?(candidate) do
    metadata = read_map(candidate, "metadata")
    record = read_map(metadata, "record")

    status =
      read_string(record, "status", nil) ||
        read_string(metadata, "status", "unresolved")

    String.downcase(status || "unresolved") == "unresolved"
  end

  defp build_llm_prompt(candidates, timestamp, feedback_context) do
    candidates_json = Jason.encode!(candidates)
    feedback_json = Jason.encode!(feedback_context[:recent_feedback] || [])
    threshold_json = Jason.encode!(feedback_context[:threshold_profile] || %{})
    preference_json = Jason.encode!(feedback_context[:preference_profile] || %{})

    """
    You are a founder accountability assistant for Gmail + Calendar follow-through.
    Current time: #{DateTime.to_iso8601(timestamp)}

    Telegram threshold profile JSON:
    #{threshold_json}

    Recent Telegram feedback JSON:
    #{feedback_json}

    Durable preference memory JSON:
    #{preference_json}

    Input candidates JSON:
    #{candidates_json}

    Task:
    - Your first job is disqualification, not escalation.
    - Keep only unresolved commitments that either need direct founder action now or should stay monitored as a high-signal tracked thread.
    - Prioritize explicit promises, missed replies, and post-meeting follow-ups after disqualifying weak candidates.
    - Apply a reasoning-first decision, not keyword heuristics:
      1. Is there a real human counterparty?
      2. Is there an explicit ask or explicit commitment?
      3. Has the user actually engaged, or is this still unsolicited outreach?
      4. Is completion evidence still missing?
      5. Is interruption justified now?
      6. What is the false positive risk?
    - Drop low-confidence or ambiguous items.
    - Strongly down-rank or exclude automated transactional receipts and notifications
      (payment confirmations, invoices, password resets, marketing/autonotifications)
      unless there is a clear human ask or explicit founder commitment that is still open.
    - Strongly down-rank or exclude unsolicited sales outreach, recruiting pitches, and networking pitches.
    - A real human sender does not imply a reply owed.
    - If the only positive evidence is "a real person followed up", Gmail labels, or unread state, omit the item.
    - Require both evidence_for_reply_owed and evidence_against_reply_owed in your reasoning.
    - If evidence_against_reply_owed materially outweighs evidence_for_reply_owed, omit the item.
    - If a candidate has importance_hint = "drop", omit it unless there is strong contrary thread evidence.
    - If a candidate looks like cold outreach and the user has not engaged or committed, it is not actionable.
    - If an item is mostly informational/receipt-like, omit it from output instead of rewording it.
    - Respect the durable preference memory above. Explicit remembered preferences outrank generic priors.
    - Treat content-filter topics such as sales_outreach and cold_outreach as suppression signals unless the user already engaged or made a commitment.
    - If the preferences imply after-hours Telegram suppression, reflect that in interrupt_now and telegram_fit_score.
    - If the preferences imply a topic or counterparty class should be urgent, bias toward surfacing it.
    - Examples to exclude:
      1. "Your payment was successful"
      2. "Your Tuesday afternoon order with Uber Eats"
      3. "Receipt / invoice / order confirmation" with no direct ask
      4. "Saw your post, worth a quick call? Here's my Calendly."
      5. "Following up on my outbound prospecting tool" when the user never replied
    - Every returned item must be high-signal and worth keeping open.
    - Each candidate may include conversation_context.notification_posture.
    - If notification_posture is "heads_up" or "insufficient_context", prefer attention_mode = "monitor".
    - If notification_posture is "heads_up", keep the softer "conversation is moving" framing.
    - Only use unattended-thread language when attention_mode is "act_now" and notification_posture is "interrupt_now".
    - Keep `category` and `dedupe_key` unchanged.
    - Keep confidence between 0 and 1.
    - Estimate telegram_fit_score between 0 and 1, where 1 means "send to Telegram now".
    - Write concise nudge language that is concrete and actionable.
    - Keep or refine each item's structured record fields:
      commitment, person, source, deadline, status, evidence, next_action
    - Status must remain unresolved for every returned item.

    Return ONLY valid JSON array. Each item must include:
    dedupe_key, title, summary, recommended_action, priority, confidence,
    telegram_fit_score, telegram_fit_reason, why_now, follow_up_ideas,
    commitment, person, source, deadline, status, evidence, next_action,
    actionability, obligation_type, human_counterparty, missing_followthrough_evidence,
    interrupt_now, attention_mode, notification_posture, false_positive_risk, reasoning_summary,
    thread_type, solicited, prior_user_engagement, explicit_user_commitment,
    reply_obligation, importance, evidence_for_reply_owed, evidence_against_reply_owed,
    decision_reason
    - Set actionability to exactly "actionable" for every returned item.
    - Set human_counterparty and missing_followthrough_evidence to true for every returned item.
    - Set attention_mode to exactly "act_now" or "monitor".
    - Set interrupt_now to true only when attention_mode is "act_now" and the conversation still clearly needs immediate founder interruption.
    - Keep notification_posture as "interrupt_now", "heads_up", or "insufficient_context".
    - Set reply_obligation to true only when there is a real outstanding obligation.
    - Set importance to "important" only for items that should persist as open insights.
    - Do not return items with importance "digest" or "drop"; omit them from the array instead.
    - Keep false_positive_risk <= 0.35 for every returned item.
    """
  end

  defp gmail_reply_triage(
         body,
         labels,
         conversation_context,
         thread_id,
         occurred_at,
         sent_messages
       ) do
    social_matches = matched_terms(body, @cold_outreach_social_terms)
    meeting_matches = matched_terms(body, @cold_outreach_meeting_terms)
    pitch_matches = matched_terms(body, @cold_outreach_pitch_terms)
    sequence_term_matches = matched_terms(body, @cold_outreach_sequence_terms)
    outreach_indicators = Enum.uniq(social_matches ++ meeting_matches ++ pitch_matches)
    reply_matches = matched_terms(body, @reply_request_terms)
    deadline_matches = matched_terms(body, @deadline_terms)
    prior_user_engagement = read_boolean(conversation_context, "prior_user_participation", false)

    explicit_user_commitment =
      explicit_thread_commitment?(sent_messages, thread_id, occurred_at)

    solicited_hint = prior_user_engagement or explicit_user_commitment
    founder_signal? = solicited_hint or reply_matches != []

    prior_other_message_count = read_integer(conversation_context, "prior_other_message_count", 0)

    sequence_follow_up? =
      prior_other_message_count >= 1 and not prior_user_engagement and sequence_term_matches != []

    clear_cold_outreach? =
      cold_outreach_thread?(
        social_matches,
        meeting_matches,
        pitch_matches,
        sequence_follow_up?,
        solicited_hint,
        explicit_user_commitment
      )

    thread_type_hint =
      cond do
        clear_cold_outreach? -> "cold_sales_outreach"
        outreach_indicators != [] -> "unknown"
        deadline_matches != [] and not founder_signal? -> "passive_update"
        true -> "direct_human_request"
      end

    evidence_for_reply_owed =
      []
      |> maybe_append(
        "Reply request terms: #{Enum.join(reply_matches, ", ")}.",
        reply_matches != []
      )
      |> maybe_append(
        "Deadline cues: #{Enum.join(deadline_matches, ", ")}.",
        deadline_matches != []
      )
      |> maybe_append("Thread is unread in Gmail.", "UNREAD" in labels)
      |> maybe_append("Thread was marked important in Gmail.", "IMPORTANT" in labels)
      |> maybe_append(
        "You previously made an explicit commitment in this thread.",
        explicit_user_commitment
      )
      |> Enum.take(@max_evidence_points)

    evidence_against_reply_owed =
      []
      |> maybe_append(
        "No self-authored message appears earlier in the thread.",
        not prior_user_engagement
      )
      |> maybe_append(
        "Cold outreach indicators: #{Enum.join(outreach_indicators, ", ")}.",
        outreach_indicators != []
      )
      |> maybe_append(
        "Multiple inbound follow-ups arrived without a reply from you.",
        sequence_follow_up?
      )
      |> maybe_append(
        "No explicit user commitment was found for this thread.",
        not explicit_user_commitment
      )
      |> maybe_append(
        "Only generic deadline cues were found without a direct ask or prior founder involvement.",
        deadline_matches != [] and not founder_signal?
      )
      |> Enum.take(@max_evidence_points)

    importance_hint =
      cond do
        clear_cold_outreach? and not solicited_hint and not explicit_user_commitment ->
          "drop"

        outreach_indicators != [] and not solicited_hint and not explicit_user_commitment ->
          "digest"

        deadline_matches != [] and not founder_signal? ->
          "digest"

        true ->
          "important"
      end

    reply_obligation_hint =
      cond do
        importance_hint != "important" -> false
        explicit_user_commitment -> true
        reply_matches != [] -> true
        true -> false
      end

    compact_map(%{
      "thread_type_hint" => thread_type_hint,
      "solicited_hint" => solicited_hint,
      "prior_user_engagement" => prior_user_engagement,
      "explicit_user_commitment" => explicit_user_commitment,
      "importance_hint" => importance_hint,
      "reply_obligation_hint" => reply_obligation_hint,
      "outreach_indicators" => Enum.take(outreach_indicators, @max_evidence_points),
      "evidence_for_reply_owed" => evidence_for_reply_owed,
      "evidence_against_reply_owed" => evidence_against_reply_owed
    })
  end

  defp suppress_cold_outreach?(triage) when is_map(triage) do
    read_string(triage, "importance_hint", nil) == "drop" and
      read_string(triage, "thread_type_hint", nil) == "cold_sales_outreach"
  end

  defp suppress_cold_outreach?(_triage), do: false

  defp suppress_low_signal_reply_candidate?(triage) when is_map(triage) do
    read_string(triage, "importance_hint", nil) == "digest" and
      not read_boolean(triage, "reply_obligation_hint", false)
  end

  defp suppress_low_signal_reply_candidate?(_triage), do: false

  defp cold_outreach_thread?(
         social_matches,
         meeting_matches,
         pitch_matches,
         sequence_follow_up?,
         solicited_hint,
         explicit_user_commitment
       ) do
    strong_signal_count = length(social_matches) + length(meeting_matches) + length(pitch_matches)

    not solicited_hint and not explicit_user_commitment and
      ((social_matches != [] and (meeting_matches != [] or pitch_matches != [])) or
         (meeting_matches != [] and pitch_matches != []) or
         (sequence_follow_up? and strong_signal_count >= 1))
  end

  defp explicit_thread_commitment?(sent_messages, thread_id, occurred_at)
       when is_list(sent_messages) do
    sent_messages
    |> Enum.filter(fn message ->
      read_string(message, "thread_id", nil) == thread_id and
        sent_before_or_at?(message_timestamp(message), occurred_at)
    end)
    |> Enum.any?(fn message ->
      sent_body = message_body(message)

      matched_terms(sent_body, @promise_terms) != [] and
        matched_terms(sent_body, @commitment_action_terms) != []
    end)
  end

  defp explicit_thread_commitment?(_sent_messages, _thread_id, _occurred_at), do: false

  defp gmail_reply_candidate?(candidate) when is_map(candidate) do
    read_string(candidate, "source", nil) == "gmail" and
      read_string(candidate, "category", nil) == "reply_urgent"
  end

  defp gmail_reply_candidate?(_candidate), do: false

  defp sent_before_or_at?(%DateTime{} = message_at, %DateTime{} = occurred_at) do
    DateTime.compare(message_at, occurred_at) in [:lt, :eq]
  end

  defp sent_before_or_at?(_, _), do: false

  defp has_attr?(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, _value} ->
        true

      :error ->
        Enum.any?(attrs, fn
          {map_key, _value} when is_atom(map_key) -> Atom.to_string(map_key) == key
          _ -> false
        end)
    end
  end

  defp has_attr?(_attrs, _key), do: false

  defp resolve_thread_type(item, base_metadata) do
    read_string(item, "thread_type", nil) ||
      read_string(base_metadata, "thread_type", nil) ||
      read_string(base_metadata, "thread_type_hint", "unknown")
  end

  defp resolve_importance(item, base_metadata) do
    read_string(item, "importance", nil) ||
      read_string(base_metadata, "importance", nil) ||
      read_string(base_metadata, "importance_hint", "important")
  end

  defp resolve_boolean_flag(item, base_metadata, item_key, metadata_key, default) do
    cond do
      has_attr?(item, item_key) ->
        read_boolean(item, item_key, default)

      true ->
        read_boolean(base_metadata, metadata_key, default)
    end
  end

  defp resolve_string_list_flag(item, base_metadata, item_key, metadata_key, limit) do
    case read_string_list(item, item_key, limit) do
      [] -> read_string_list(base_metadata, metadata_key, limit)
      values -> values
    end
  end

  defp disqualified_outreach_thread?(thread_type, prior_user_engagement, explicit_user_commitment) do
    thread_type == "cold_sales_outreach" and
      not prior_user_engagement and
      not explicit_user_commitment
  end

  defp reply_debt_gate_passes?(
         false,
         _reply_obligation,
         _importance,
         _evidence_for_reply_owed,
         _thread_type,
         _prior_user_engagement,
         _explicit_user_commitment
       ),
       do: true

  defp reply_debt_gate_passes?(
         true,
         reply_obligation,
         importance,
         evidence_for_reply_owed,
         thread_type,
         prior_user_engagement,
         explicit_user_commitment
       ) do
    reply_obligation and
      importance == "important" and
      evidence_for_reply_owed != [] and
      not disqualified_outreach_thread?(
        thread_type,
        prior_user_engagement,
        explicit_user_commitment
      )
  end

  defp find_sent_reply_for_thread(sent_messages, thread_id, occurred_at, sender, user_id) do
    sender_emails = parse_email_addresses(sender)

    sent_messages
    |> sent_messages_after(occurred_at)
    |> Enum.find(fn message ->
      message_thread_id = read_string(message, "thread_id", nil)
      reply_to_sender? = recipient_overlap?(read_string(message, "to", ""), sender_emails)
      self_sent? = string_contains?(read_string(message, "from", ""), user_id)

      self_sent? and (message_thread_id == thread_id or reply_to_sender?)
    end)
  end

  defp find_sent_followthrough_for_commitment(sent_email, sent_messages, user_id) do
    commitment_at = message_timestamp(sent_email)
    thread_id = read_string(sent_email, "thread_id", nil)
    recipients = parse_email_addresses(read_string(sent_email, "to", ""))

    sent_messages
    |> sent_messages_after(commitment_at)
    |> Enum.find(fn message ->
      self_sent? = string_contains?(read_string(message, "from", ""), user_id)
      message_thread_id = read_string(message, "thread_id", nil)
      same_thread? = present?(thread_id) and message_thread_id == thread_id
      recipient_overlap? = recipient_overlap?(read_string(message, "to", ""), recipients)
      followthrough? = followthrough_action(message, same_thread?) != nil

      self_sent? and followthrough? and (same_thread? or recipient_overlap?)
    end)
  end

  defp find_meeting_follow_up_email(event, sent_messages, end_at) do
    attendees = read_list(event, "attendees")

    attendee_emails =
      attendees
      |> Enum.flat_map(fn attendee ->
        parse_email_addresses(read_string(attendee, "email", ""))
      end)
      |> Enum.uniq()

    organizer_emails = parse_email_addresses(read_string(event, "organizer", ""))
    participant_emails = Enum.uniq(attendee_emails ++ organizer_emails)

    event_text =
      String.downcase(
        Enum.join(
          Enum.reject(
            [read_string(event, "summary", ""), read_string(event, "description", "")],
            &blank?/1
          ),
          " "
        )
      )

    sent_messages
    |> sent_messages_after(end_at)
    |> Enum.find(fn message ->
      recipients = read_string(message, "to", "")
      message_body = message_body(message)
      participant_overlap? = recipient_overlap?(recipients, participant_emails)

      participant_overlap? and
        (contains_any?(message_body, @follow_up_terms) or text_overlap?(message_body, event_text))
    end)
  end

  defp followthrough_action(message, same_thread?) do
    subject = String.downcase(read_string(message, "subject", ""))
    body = message_body(message)

    cond do
      String.starts_with?(subject, "fwd:") or String.starts_with?(subject, "fw:") ->
        "forwarded"

      contains_any?(body, @artifact_delivery_terms) ->
        "sent_artifact"

      same_thread? ->
        "replied"

      String.starts_with?(subject, "re:") ->
        "replied"

      contains_any?(body, @follow_up_terms) ->
        "replied"

      true ->
        nil
    end
  end

  defp message_body(message) do
    String.downcase(
      Enum.join(
        Enum.reject(
          [read_string(message, "subject", ""), read_string(message, "snippet", "")],
          &blank?/1
        ),
        " "
      )
    )
  end

  defp sent_messages_after(messages, nil), do: messages

  defp sent_messages_after(messages, %DateTime{} = occurred_at) do
    Enum.filter(messages, fn message ->
      case message_timestamp(message) do
        %DateTime{} = timestamp -> DateTime.compare(timestamp, occurred_at) == :gt
        _ -> false
      end
    end)
  end

  defp message_timestamp(attrs) when is_map(attrs) do
    read_datetime(attrs, "internal_date") || read_datetime(attrs, "date") || DateTime.utc_now()
  end

  defp extract_commitment_line(subject, snippet, person) do
    snippet =
      snippet
      |> to_string()
      |> String.trim()
      |> truncate(120)

    cond do
      snippet != "" ->
        snippet

      true ->
        "Follow through on \"#{truncate(subject, 70)}\" for #{person}"
    end
  end

  defp extract_artifact_hint(body) when is_binary(body) do
    cond do
      String.contains?(body, "deck") -> "the deck"
      String.contains?(body, "slides") -> "the slides"
      String.contains?(body, "proposal") -> "the proposal"
      String.contains?(body, "contract") -> "the contract"
      String.contains?(body, "doc") -> "the document"
      String.contains?(body, "notes") -> "meeting notes"
      true -> nil
    end
  end

  defp infer_deadline_from_text(text, reference_at) when is_binary(text) do
    base = reference_at || DateTime.utc_now()
    text = String.downcase(text)

    cond do
      String.contains?(text, "today") or
        String.contains?(text, "eod") or
          String.contains?(text, "end of day") ->
        end_of_day(base)

      String.contains?(text, "tomorrow") ->
        base
        |> DateTime.add(1, :day)
        |> end_of_day()

      true ->
        parse_weekday_deadline(text, base) || parse_iso_date_deadline(text)
    end
  end

  defp infer_deadline_from_text(_text, _reference_at), do: nil

  defp parse_weekday_deadline(text, base) do
    case Regex.run(
           ~r/\b(?:by|before|on)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/,
           text
         ) do
      [_, weekday] ->
        target_weekday = Map.get(@weekday_numbers, weekday)
        current_date = DateTime.to_date(base)
        current_weekday = Date.day_of_week(current_date)

        days_ahead =
          case target_weekday - current_weekday do
            diff when diff < 0 -> diff + 7
            0 -> 7
            diff -> diff
          end

        current_date
        |> Date.add(days_ahead)
        |> end_of_day_date()

      _ ->
        nil
    end
  end

  defp parse_iso_date_deadline(text) do
    case Regex.run(~r/\b(\d{4}-\d{2}-\d{2})\b/, text, capture: :all_but_first) do
      [date_string] ->
        case Date.from_iso8601(date_string) do
          {:ok, date} -> end_of_day_date(date)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp end_of_day(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> end_of_day_date()
  end

  defp end_of_day_date(%Date{} = date) do
    with {:ok, naive} <- NaiveDateTime.new(date, ~T[23:00:00]) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp urgency_priority(nil, base), do: base

  defp urgency_priority(%DateTime{} = due_at, base) do
    hours = hours_until(due_at)

    cond do
      is_integer(hours) and hours < 0 -> max(base, 94)
      is_integer(hours) and hours <= 6 -> max(base, 90)
      is_integer(hours) and hours <= 24 -> max(base, 86)
      true -> base
    end
  end

  defp deadline_phrase(nil), do: ""

  defp deadline_phrase(%DateTime{} = due_at) do
    today = Date.utc_today()
    due_date = DateTime.to_date(due_at)

    cond do
      Date.compare(due_date, today) == :lt ->
        "and it is already overdue"

      due_date == today ->
        "and it is due today"

      due_date == Date.add(today, 1) ->
        "and it is due tomorrow"

      true ->
        "and it is due by #{Date.to_iso8601(due_date)}"
    end
  end

  defp commitment_record(commitment, person, source, deadline, status, evidence, next_action) do
    compact_map(%{
      "commitment" => commitment,
      "person" => person,
      "source" => source,
      "deadline" => to_iso8601(deadline),
      "status" => status,
      "evidence" => Enum.take(evidence, @max_evidence_points),
      "next_action" => next_action
    })
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_map(map, _key, value) when value == %{}, do: map
  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value) when is_map(value), do: Map.put(map, key, value)
  defp maybe_put_list(map, _key, []), do: map
  defp maybe_put_list(map, key, value), do: Map.put(map, key, value)

  defp dedupe_candidates(candidates) do
    candidates
    |> Enum.reduce(%{}, fn candidate, acc ->
      key = candidate["dedupe_key"]

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, candidate)

        existing ->
          if read_integer(candidate, "priority", 0) >= read_integer(existing, "priority", 0) do
            Map.put(acc, key, candidate)
          else
            acc
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&read_integer(&1, "priority", 0), :desc)
  end

  defp normalize_candidate(candidate, state) do
    candidate = stringify_keys(candidate)

    candidate
    |> Map.update("confidence", state.min_confidence, &clamp(&1, state.min_confidence, 1.0))
    |> Map.update("metadata", %{}, fn metadata ->
      metadata = stringify_keys(metadata)
      record = read_map(metadata, "record")

      if record == %{} do
        metadata
      else
        metadata
        |> Map.put("commitment", read_string(record, "commitment", metadata["commitment"]))
        |> Map.put("person", read_string(record, "person", metadata["person"]))
        |> Map.put("source", read_string(record, "source", metadata["source"]))
        |> Map.put("deadline", read_string(record, "deadline", metadata["deadline"]))
        |> Map.put("status", read_string(record, "status", metadata["status"]))
        |> Map.put("evidence", read_string_list(record, "evidence", @max_evidence_points))
        |> Map.put("next_action", read_string(record, "next_action", metadata["next_action"]))
      end
    end)
    |> put_detail_metadata()
  end

  defp put_detail_metadata(candidate) when is_map(candidate) do
    metadata = read_map(candidate, "metadata")
    existing_detail = read_map(metadata, "detail")
    record = read_map(metadata, "record")

    detail =
      compact_map(%{
        "promise_text" =>
          read_string(existing_detail, "promise_text", nil) ||
            read_string(record, "commitment", nil) ||
            read_string(metadata, "commitment", nil),
        "requested_by" =>
          read_string(existing_detail, "requested_by", nil) ||
            read_string(record, "person", nil) ||
            read_string(metadata, "person", nil),
        "open_loop_reason" =>
          read_string(existing_detail, "open_loop_reason", nil) ||
            read_string(metadata, "reasoning_summary", nil) ||
            read_string(metadata, "why_now", nil) ||
            read_string(metadata, "context_brief", nil),
        "checked_evidence" =>
          case detail_evidence_items(candidate, metadata, record) do
            [] -> read_list(existing_detail, "checked_evidence")
            items -> items
          end,
        "evaluated_at" =>
          read_string(existing_detail, "evaluated_at", nil) ||
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    if detail == %{} do
      candidate
    else
      put_in(candidate, ["metadata", "detail"], detail)
    end
  end

  defp put_detail_metadata(candidate), do: candidate

  defp detail_evidence_items(candidate, metadata, record) do
    source_ref =
      read_string(record, "source", nil) ||
        read_string(metadata, "source", nil) ||
        read_string(candidate, "source_id", nil)

    evidence =
      case read_string_list(record, "evidence", @max_evidence_points) do
        [] -> read_string_list(metadata, "evidence", @max_evidence_points)
        values -> values
      end

    evidence_items =
      Enum.map(evidence, fn line ->
        compact_map(%{
          "kind" => "source_evidence",
          "label" => line,
          "source_ref" => source_ref
        })
      end)

    deadline_item =
      case read_string(record, "deadline", nil) || to_iso8601(read_datetime(candidate, "due_at")) do
        nil ->
          nil

        deadline ->
          compact_map(%{
            "kind" => "deadline",
            "label" => "Deadline",
            "detail" => "Due #{deadline}"
          })
      end

    compact_list(evidence_items ++ List.wrap(deadline_item))
  end

  defp contains_any?(text, terms) when is_binary(text) do
    text = String.downcase(text)
    Enum.any?(terms, &String.contains?(text, &1))
  end

  defp text_overlap?(left, right) when is_binary(left) and is_binary(right) do
    left_words =
      left
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.reject(&(String.length(&1) < 5))
      |> MapSet.new()

    right_words =
      right
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.reject(&(String.length(&1) < 5))
      |> MapSet.new()

    MapSet.size(MapSet.intersection(left_words, right_words)) >= 2
  end

  defp text_overlap?(_, _), do: false

  defp to_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp to_positive_integer(_value, default), do: default

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value / 1

  defp to_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp to_float(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil

  defp read_string(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)
    normalize_string(value) || default
  end

  defp read_datetime(attrs, key) when is_map(attrs) do
    value = fetch_attr(attrs, key)

    case value do
      %DateTime{} = datetime -> datetime
      %NaiveDateTime{} = naive -> DateTime.from_naive!(naive, "Etc/UTC")
      %{"date" => date} when is_binary(date) -> date_to_datetime(date)
      %{date: date} when is_binary(date) -> date_to_datetime(date)
      value when is_binary(value) -> parse_datetime_string(value)
      _ -> nil
    end
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)

    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_float(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)

    cond do
      is_float(value) ->
        value

      is_integer(value) ->
        value / 1

      is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_boolean(attrs, key, default) when is_map(attrs) do
    value = fetch_attr(attrs, key)

    cond do
      is_boolean(value) ->
        value

      is_integer(value) ->
        value != 0

      is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> true
          "1" -> true
          "yes" -> true
          "y" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          "n" -> false
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_list(attrs, key) when is_map(attrs) do
    value = fetch_attr(attrs, key)
    if is_list(value), do: value, else: []
  end

  defp read_map(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp parse_datetime_string(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date_to_datetime(Date.to_iso8601(date))
          _ -> nil
        end
    end
  end

  defp date_to_datetime(date_string) when is_binary(date_string) do
    with {:ok, date} <- Date.from_iso8601(date_string),
         {:ok, naive} <- NaiveDateTime.new(date, ~T[09:00:00]) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_iso8601(_), do: nil

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp non_empty_truncated(value, max) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: truncate(value, max)
  end

  defp non_empty_truncated(_, _max), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp hours_since(%DateTime{} = datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :hour)
  end

  defp hours_since(_), do: nil

  defp hours_until(%DateTime{} = datetime) do
    DateTime.diff(datetime, DateTime.utc_now(), :hour)
  end

  defp hours_until(_), do: nil

  defp matched_terms(text, terms) when is_binary(text) do
    text = String.downcase(text)

    terms
    |> Enum.filter(&String.contains?(text, &1))
    |> Enum.uniq()
  end

  defp attendee_preview(attendees) when is_list(attendees) do
    attendees
    |> Enum.take(@max_attendee_preview)
    |> Enum.map(fn attendee ->
      read_string(attendee, "display_name", nil) || read_string(attendee, "email", "unknown")
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
  end

  defp attendee_preview(_), do: nil

  defp attendee_response_counts(attendees) when is_list(attendees) do
    counts =
      Enum.reduce(
        attendees,
        %{"accepted" => 0, "tentative" => 0, "declined" => 0, "needs_action" => 0},
        fn attendee, acc ->
          status = read_string(attendee, "response_status", "needs_action")

          if Map.has_key?(acc, status) do
            Map.update!(acc, status, &(&1 + 1))
          else
            acc
          end
        end
      )

    compact_map(counts)
  end

  defp attendee_response_counts(_), do: %{}

  defp read_string_list(attrs, key, limit)
       when is_map(attrs) and is_binary(key) and is_integer(limit) do
    case fetch_attr(attrs, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      value when is_binary(value) ->
        value
        |> String.split(~r/\r?\n|;/, trim: true)
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp maybe_append(list, _value, false), do: list
  defp maybe_append(list, value, true), do: list ++ [value]

  defp maybe_add_float(value, amount, true), do: value + amount
  defp maybe_add_float(value, _amount, false), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, []}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp compact_list(values) when is_list(values) do
    Enum.reject(values, fn
      nil -> true
      %{} = value -> value == %{}
      "" -> true
      _ -> false
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp fetch_attr(attrs, key) when is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp extract_llm_list(list) when is_list(list), do: list

  defp extract_llm_list(map) when is_map(map) do
    case fetch_attr(map, "insights") do
      insights when is_list(insights) -> insights
      _ -> nil
    end
  end

  defp extract_llm_list(_), do: nil

  defp format_dt(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp format_dt(_), do: "unknown time"

  defp parse_email_addresses(value) when is_binary(value) do
    value
    |> String.split(~r/[;,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn part ->
      cond do
        part == "" ->
          []

        Regex.match?(~r/<[^>]+>/, part) ->
          case Regex.run(~r/<([^>]+)>/, part, capture: :all_but_first) do
            [email] -> [String.downcase(String.trim(email))]
            _ -> []
          end

        String.contains?(part, "@") ->
          [String.downcase(part)]

        true ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp parse_email_addresses(_), do: []

  defp primary_contact(value) when is_binary(value) do
    case String.split(value, ~r/[;,]/, trim: true) do
      [first | _] ->
        first = String.trim(first)

        case Regex.run(~r/^\s*([^<]+?)\s*<([^>]+)>\s*$/, first, capture: :all_but_first) do
          [name, _email] ->
            name
            |> String.trim()
            |> case do
              "" -> primary_email(first)
              cleaned -> cleaned
            end

          _ ->
            primary_email(first)
        end

      _ ->
        nil
    end
  end

  defp primary_contact(_), do: nil

  defp primary_email(value) when is_binary(value) do
    case parse_email_addresses(value) do
      [email | _] -> email
      _ -> normalize_string(value)
    end
  end

  defp primary_email(_), do: nil

  defp recipient_overlap?(recipient_value, expected_emails)
       when is_binary(recipient_value) and is_list(expected_emails) do
    recipients = MapSet.new(parse_email_addresses(recipient_value))
    expected = MapSet.new(Enum.map(expected_emails, &String.downcase/1))

    MapSet.size(MapSet.intersection(recipients, expected)) > 0
  end

  defp recipient_overlap?(_recipient_value, _expected_emails), do: false

  defp string_contains?(value, target) when is_binary(value) and is_binary(target) do
    String.contains?(String.downcase(value), String.downcase(target))
  end

  defp string_contains?(_, _), do: false
end
