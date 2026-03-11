defmodule Maraithon.Behaviors.InboxCalendarAdvisor do
  @moduledoc """
  Founder follow-through accountability behavior focused on Gmail + Calendar context.

  Produces actionable unresolved commitments such as:
  - explicit promises made in sent email
  - inbox threads that still need a reply
  - post-meeting follow-ups that still need owners and next steps
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.InsightFeedback
  alias Maraithon.Insights
  alias Maraithon.OAuth
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
      google_account: nil,
      pending_candidates: [],
      last_scan_at: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state =
      state
      |> ensure_user_id(context)
      |> hydrate_google_account()

    cond do
      is_nil(state.user_id) ->
        Logger.warning("InboxCalendarAdvisor skipped wakeup: user_id missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      true ->
        feedback_context = InsightFeedback.prompt_context(state.user_id)

        candidates =
          case context[:event] do
            %{payload: payload} ->
              candidates_from_pubsub_payload(payload, state, context)

            _ ->
              candidates_from_periodic_scan(state, context)
          end
          |> dedupe_candidates()
          |> Enum.take(state.max_insights_per_cycle * 2)

        if candidates == [] do
          {:idle, %{state | pending_candidates: [], last_scan_at: context.timestamp}}
        else
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
           %{state | pending_candidates: candidates, last_scan_at: context.timestamp}}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    candidates = state.pending_candidates

    insights =
      parse_llm_response(response.content, candidates, state)
      |> Enum.filter(&high_signal_unresolved?(&1, state))
      |> Enum.take(state.max_insights_per_cycle)

    result = persist_insights(insights, state, context)

    case result do
      {:ok, stored} ->
        {:emit,
         {:insights_recorded,
          %{
            count: length(stored),
            user_id: state.user_id,
            categories: stored |> Enum.map(& &1.category) |> Enum.uniq()
          }}, %{state | pending_candidates: []}}

      {:error, reason} ->
        {:emit, {:insight_error, %{reason: inspect(reason), attempted_count: length(insights)}},
         %{state | pending_candidates: []}}
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

  defp hydrate_google_account(%{user_id: nil} = state), do: state

  defp hydrate_google_account(state) do
    Map.put(state, :google_account, google_account_for_user(state.user_id))
  end

  defp google_account_for_user(user_id) when is_binary(user_id) do
    case OAuth.get_token(user_id, "google") do
      %{metadata: metadata, provider: provider} ->
        metadata = metadata || %{}

        normalize_string(metadata["account_email"]) ||
          normalize_string(metadata[:account_email]) ||
          normalize_string(metadata["email"]) ||
          normalize_string(metadata[:email]) ||
          google_provider_account(provider)

      _ ->
        nil
    end
  end

  defp google_account_for_user(_user_id), do: nil

  defp google_provider_account("google:" <> account) when is_binary(account) do
    account = normalize_string(account)

    if account && String.starts_with?(account, "sub-") do
      nil
    else
      account
    end
  end

  defp google_provider_account(_provider), do: nil

  defp candidates_from_periodic_scan(state, _context) do
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

    incoming_reply_candidates ++ explicit_promise_candidates ++ meeting_follow_up_candidates
  end

  defp candidates_from_pubsub_payload(payload, state, context) when is_map(payload) do
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
        incoming =
          data
          |> extract_email_batch()
          |> Enum.flat_map(&incoming_email_candidates(&1, state, sent_messages))

        outgoing =
          sent_messages
          |> Enum.flat_map(&sent_commitment_candidates(&1, state, sent_messages))

        incoming ++ outgoing

      "google_calendar" ->
        data
        |> extract_calendar_batch()
        |> Enum.flat_map(&meeting_follow_up_candidates(&1, state, sent_messages))

      _ ->
        # Unknown payload format. Fall back to broad periodic scan.
        candidates_from_periodic_scan(state, context)
    end
  end

  defp candidates_from_pubsub_payload(_payload, state, context),
    do: candidates_from_periodic_scan(state, context)

  defp extract_email_batch(%{"messages" => messages}) when is_list(messages), do: messages
  defp extract_email_batch(%{messages: messages}) when is_list(messages), do: messages
  defp extract_email_batch(message) when is_map(message), do: [message]
  defp extract_email_batch(_), do: []

  defp extract_calendar_batch(%{"events" => events}) when is_list(events), do: events
  defp extract_calendar_batch(%{events: events}) when is_list(events), do: events
  defp extract_calendar_batch(event) when is_map(event), do: [event]
  defp extract_calendar_batch(_), do: []

  defp fetch_recent_inbox_messages(state) do
    case Gmail.fetch_recent_emails(state.user_id, state.email_scan_limit) do
      {:ok, value} ->
        value

      {:error, reason} ->
        Logger.warning("InboxCalendarAdvisor failed to fetch inbox email",
          reason: inspect(reason)
        )

        []
    end
  end

  defp fetch_recent_sent_messages(state) do
    sent_limit = max(state.email_scan_limit * 2, 12)
    query = "in:sent newer_than:#{@sent_query_lookback_days}d"

    case GmailHelpers.list_messages(state.user_id,
           max_results: sent_limit,
           query: query,
           label_ids: []
         ) do
      {:ok, value} ->
        value

      {:error, reason} ->
        Logger.warning("InboxCalendarAdvisor failed to fetch sent email", reason: inspect(reason))
        []
    end
  end

  defp fetch_recent_calendar_events(state) do
    case GoogleCalendar.sync_calendar_events(state.user_id) do
      {:ok, value} ->
        value
        |> Enum.take(state.event_scan_limit)

      {:error, reason} ->
        Logger.warning("InboxCalendarAdvisor failed to fetch calendar", reason: inspect(reason))
        []
    end
  end

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
    needs_reply? = reply_matches != [] or "UNREAD" in labels or "IMPORTANT" in labels

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
        person = primary_contact(from) || from
        inferred_deadline = infer_deadline_from_text(body, occurred_at)
        due_at = inferred_deadline || DateTime.add(occurred_at || DateTime.utc_now(), 8, :hour)

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
            dedupe_key: "gmail:thread:#{thread_id}:reply_owed",
            metadata:
              compact_map(%{
                "account" => state.google_account,
                "thread_id" => thread_id,
                "from" => from,
                "to" => to,
                "subject" => subject,
                "labels" => labels,
                "signals" => reply_matches,
                "context_brief" => "Incoming request from #{person}.",
                "record" => record
              })
          }
          |> normalize_candidate(state)
        ]
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
            dedupe_key: "gmail:commitment:#{thread_id}",
            metadata:
              compact_map(%{
                "account" => state.google_account,
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
        ]
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
                "account" => state.google_account,
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

    if is_nil(base) or not actionable_llm_item?(item) do
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
        interrupt_now = read_boolean(item, "interrupt_now", false)
        false_positive_risk = clamp(read_float(item, "false_positive_risk", 1.0), 0.0, 1.0)
        telegram_fit_score = clamp(read_float(item, "telegram_fit_score", confidence), 0.0, 1.0)
        telegram_fit_reason = read_string(item, "telegram_fit_reason", nil)
        why_now = read_string(item, "why_now", nil)
        follow_up_ideas = read_string_list(item, "follow_up_ideas", @max_follow_up_ideas)
        merged_record = resolve_record(item, base)

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
            |> maybe_put_list("follow_up_ideas", follow_up_ideas)
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
        end
      end
    end
  end

  defp merge_llm_item(_item, _by_key, _min_confidence), do: nil

  defp actionable_llm_item?(item) when is_map(item) do
    actionability = read_string(item, "actionability", "") |> String.downcase()
    human_counterparty = read_boolean(item, "human_counterparty", false)
    missing_followthrough = read_boolean(item, "missing_followthrough_evidence", false)
    interrupt_now = read_boolean(item, "interrupt_now", false)
    false_positive_risk = read_float(item, "false_positive_risk", 1.0)

    actionability == "actionable" and
      human_counterparty and
      missing_followthrough and
      interrupt_now and
      false_positive_risk <= 0.35
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
    - Keep only unresolved commitments that should interrupt a founder now.
    - Prioritize explicit promises, missed replies, and post-meeting follow-ups.
    - Apply a reasoning-first decision, not keyword heuristics:
      1. Is there a real human counterparty?
      2. Is there an explicit ask or explicit commitment?
      3. Is completion evidence still missing?
      4. Is interruption justified now?
      5. What is the false positive risk?
    - Drop low-confidence or ambiguous items.
    - Strongly down-rank or exclude automated transactional receipts and notifications
      (payment confirmations, invoices, password resets, marketing/autonotifications)
      unless there is a clear human ask or explicit founder commitment that is still open.
    - If an item is mostly informational/receipt-like, omit it from output instead of rewording it.
    - Respect the durable preference memory above. Explicit remembered preferences outrank generic priors.
    - If the preferences imply after-hours Telegram suppression, reflect that in interrupt_now and telegram_fit_score.
    - If the preferences imply a topic or counterparty class should be urgent, bias toward surfacing it.
    - Examples to exclude:
      1. "Your payment was successful"
      2. "Your Tuesday afternoon order with Uber Eats"
      3. "Receipt / invoice / order confirmation" with no direct ask
    - Every returned item must be truly actionable now.
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
    interrupt_now, false_positive_risk, reasoning_summary
    - Set actionability to exactly "actionable" for every returned item.
    - Set human_counterparty, missing_followthrough_evidence, and interrupt_now to true for every returned item.
    - Keep false_positive_risk <= 0.35 for every returned item.
    """
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
