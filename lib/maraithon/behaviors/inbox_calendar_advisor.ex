defmodule Maraithon.Behaviors.InboxCalendarAdvisor do
  @moduledoc """
  Advisor behavior focused on Gmail + Calendar context.

  Produces actionable insights such as:
  - reply urgency
  - tone risk
  - event importance
  - event prep reminders
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.InsightFeedback
  alias Maraithon.Insights

  require Logger

  @default_wakeup_interval_ms :timer.minutes(10)
  @default_email_scan_limit 12
  @default_event_scan_limit 12
  @default_prep_window_hours 24
  @default_max_insights_per_cycle 6
  @default_min_confidence 0.55
  @max_follow_up_ideas 3
  @max_attendee_preview 4

  @urgent_terms [
    "urgent",
    "asap",
    "action required",
    "follow up",
    "follow-up",
    "deadline",
    "today",
    "overdue"
  ]

  @angry_terms [
    "frustrated",
    "disappointed",
    "angry",
    "upset",
    "unacceptable",
    "escalate",
    "concerned"
  ]

  @important_event_terms [
    "interview",
    "deadline",
    "board",
    "customer",
    "client",
    "incident",
    "launch",
    "exec",
    "review",
    "qbr",
    "planning"
  ]

  @prep_event_terms [
    "meeting",
    "interview",
    "presentation",
    "review",
    "demo",
    "planning",
    "kickoff",
    "prep"
  ]

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      email_scan_limit:
        to_positive_integer(config["email_scan_limit"], @default_email_scan_limit),
      event_scan_limit:
        to_positive_integer(config["event_scan_limit"], @default_event_scan_limit),
      prep_window_hours:
        to_positive_integer(config["prep_window_hours"], @default_prep_window_hours),
      max_insights_per_cycle:
        to_positive_integer(config["max_insights_per_cycle"], @default_max_insights_per_cycle),
      min_confidence: to_float(config["min_confidence"], @default_min_confidence),
      pending_candidates: [],
      last_scan_at: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = ensure_user_id(state, context)

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
          |> Enum.take(state.max_insights_per_cycle)

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
            "max_tokens" => 1_600,
            "temperature" => 0.2
          }

          {:effect, {:llm_call, params},
           %{state | pending_candidates: candidates, last_scan_at: context.timestamp}}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    candidates = state.pending_candidates
    fallback = fallback_insights(candidates, state)

    insights =
      parse_llm_response(response.content, candidates, state)
      |> case do
        [] -> fallback
        parsed -> parsed
      end
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

  defp candidates_from_periodic_scan(state, _context) do
    emails =
      case Gmail.fetch_recent_emails(state.user_id, state.email_scan_limit) do
        {:ok, value} ->
          value

        {:error, reason} ->
          Logger.warning("InboxCalendarAdvisor failed to fetch emails", reason: inspect(reason))
          []
      end

    events =
      case GoogleCalendar.fetch_upcoming_events(state.user_id, state.event_scan_limit) do
        {:ok, value} ->
          value

        {:error, reason} ->
          Logger.warning("InboxCalendarAdvisor failed to fetch calendar", reason: inspect(reason))
          []
      end

    email_candidates = Enum.flat_map(emails, &email_candidates(&1, state))
    event_candidates = Enum.flat_map(events, &calendar_candidates(&1, state))

    email_candidates ++ event_candidates
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

    case source do
      "gmail" ->
        data
        |> extract_email_batch()
        |> Enum.flat_map(&email_candidates(&1, state))

      "google_calendar" ->
        data
        |> extract_calendar_batch()
        |> Enum.flat_map(&calendar_candidates(&1, state))

      _ ->
        # Unknown event payload. We still attempt periodic scan to stay useful.
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

  defp email_candidates(email, state) when is_map(email) do
    subject = read_string(email, "subject", "(no subject)")
    snippet = read_string(email, "snippet", "")
    from = read_string(email, "from", "unknown sender")
    to = read_string(email, "to", "")
    thread_id = read_string(email, "thread_id", nil)
    labels = read_list(email, "labels") |> Enum.map(&to_string/1)

    body =
      String.downcase(
        Enum.join(
          Enum.reject([subject, snippet, from, to, Enum.join(labels, " ")], &blank?/1),
          " "
        )
      )

    message_id = read_string(email, "message_id", Ecto.UUID.generate())
    occurred_at = read_datetime(email, "internal_date")
    age_hours = hours_since(occurred_at)
    recipient_count = recipient_count(to)
    urgent_matches = matched_terms(body, @urgent_terms)
    angry_matches = matched_terms(body, @angry_terms)
    context_brief = email_context_brief(from, to, labels, age_hours, recipient_count)

    base_metadata =
      compact_map(%{
        "from" => from,
        "to" => to,
        "subject" => subject,
        "snippet" => snippet,
        "labels" => labels,
        "thread_id" => thread_id,
        "age_hours" => age_hours,
        "recipient_count" => recipient_count,
        "context_brief" => context_brief,
        "signals" =>
          email_signals(labels, age_hours, recipient_count, urgent_matches, angry_matches)
      })

    []
    |> maybe_add(urgent_matches != [], fn ->
      %{
        source: "gmail",
        source_id: message_id,
        source_occurred_at: occurred_at,
        category: "reply_urgent",
        title: "Reply soon: #{truncate(subject, 90)}",
        summary: "Email from #{from} appears time-sensitive. #{context_brief}",
        recommended_action:
          "Reply today, acknowledge the request, and propose a concrete next step or timeline.",
        priority: 88,
        confidence: 0.82,
        due_at: DateTime.add(DateTime.utc_now(), 4, :hour),
        dedupe_key: "email:#{message_id}:reply_urgent",
        metadata: base_metadata
      }
    end)
    |> maybe_add(angry_matches != [], fn ->
      %{
        source: "gmail",
        source_id: message_id,
        source_occurred_at: occurred_at,
        category: "tone_risk",
        title: "Tone risk in email: #{truncate(subject, 80)}",
        summary: "Message language suggests frustration or escalation risk. #{context_brief}",
        recommended_action:
          "Respond calmly, confirm the concern, and offer one specific next step with timing.",
        priority: 80,
        confidence: 0.74,
        due_at: DateTime.add(DateTime.utc_now(), 6, :hour),
        dedupe_key: "email:#{message_id}:tone_risk",
        metadata: base_metadata
      }
    end)
    |> Enum.map(&normalize_candidate(&1, state))
  end

  defp email_candidates(_email, _state), do: []

  defp calendar_candidates(event, state) when is_map(event) do
    summary = read_string(event, "summary", "(untitled event)")
    description = read_string(event, "description", "")
    location = read_string(event, "location", "")
    organizer = read_string(event, "organizer", "")
    event_id = read_string(event, "event_id", Ecto.UUID.generate())
    start_at = read_datetime(event, "start")
    attendees = read_list(event, "attendees")
    attendee_preview = attendee_preview(attendees)
    response_counts = attendee_response_counts(attendees)
    hours_until_start = hours_until(start_at)

    body =
      String.downcase(
        Enum.join(
          Enum.reject([summary, description, location, organizer, attendee_preview], &blank?/1),
          " "
        )
      )

    attendee_count = length(attendees)

    context_brief =
      calendar_context_brief(
        organizer,
        location,
        attendee_count,
        response_counts,
        hours_until_start,
        description
      )

    base_metadata =
      compact_map(%{
        "summary" => summary,
        "description_excerpt" => non_empty_truncated(description, 180),
        "location" => location,
        "organizer" => organizer,
        "attendee_count" => attendee_count,
        "attendee_preview" => attendee_preview,
        "response_counts" => response_counts,
        "hours_until_start" => hours_until_start,
        "start" => to_iso8601(start_at),
        "context_brief" => context_brief,
        "signals" =>
          calendar_signals(
            location,
            organizer,
            attendee_count,
            response_counts,
            hours_until_start
          )
      })

    important? = contains_any?(body, @important_event_terms) or attendee_count >= 5
    prep_soon? = needs_prep?(start_at, body, state.prep_window_hours)

    []
    |> maybe_add(important?, fn ->
      %{
        source: "calendar",
        source_id: event_id,
        source_occurred_at: start_at,
        category: "event_important",
        title: "Important event: #{truncate(summary, 90)}",
        summary: "This event looks high-impact. #{context_brief}",
        recommended_action:
          "Review the agenda, decision owner, and unresolved questions before the meeting.",
        priority: 78,
        confidence: if(attendee_count >= 5, do: 0.8, else: 0.7),
        due_at: due_at_before(start_at, 2),
        dedupe_key: "calendar:#{event_id}:event_important",
        metadata: base_metadata
      }
    end)
    |> maybe_add(prep_soon?, fn ->
      %{
        source: "calendar",
        source_id: event_id,
        source_occurred_at: start_at,
        category: "event_prep_needed",
        title: "Prep needed: #{truncate(summary, 90)}",
        summary: "This upcoming event likely needs preparation. #{context_brief}",
        recommended_action:
          "Block prep time, gather the relevant docs, and draft the top outcomes to drive.",
        priority: 84,
        confidence: 0.79,
        due_at: due_at_before(start_at, 3),
        dedupe_key: "calendar:#{event_id}:event_prep_needed",
        metadata: base_metadata
      }
    end)
    |> Enum.map(&normalize_candidate(&1, state))
  end

  defp calendar_candidates(_event, _state), do: []

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

  defp fallback_insights(candidates, state) do
    candidates
    |> Enum.map(fn candidate ->
      candidate
      |> Map.put(
        "confidence",
        max(read_float(candidate, "confidence", 0.5), state.min_confidence)
      )
      |> Map.put_new("source_occurred_at", read_datetime(candidate, "source_occurred_at"))
    end)
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

    if is_nil(base) do
      nil
    else
      confidence =
        clamp(read_float(item, "confidence", read_float(base, "confidence", 0.5)), 0.0, 1.0)

      if confidence < min_confidence do
        nil
      else
        telegram_fit_score = clamp(read_float(item, "telegram_fit_score", confidence), 0.0, 1.0)
        telegram_fit_reason = read_string(item, "telegram_fit_reason", nil)
        why_now = read_string(item, "why_now", nil)
        follow_up_ideas = read_string_list(item, "follow_up_ideas", @max_follow_up_ideas)

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
          |> maybe_put_list("follow_up_ideas", follow_up_ideas)
          |> Map.put("feedback_tuned", true)
        end)
      end
    end
  end

  defp merge_llm_item(_item, _by_key, _min_confidence), do: nil

  defp build_llm_prompt(candidates, timestamp, feedback_context) do
    candidates_json = Jason.encode!(candidates)
    feedback_json = Jason.encode!(feedback_context[:recent_feedback] || [])
    threshold_json = Jason.encode!(feedback_context[:threshold_profile] || %{})

    """
    You are an executive assistant analyzing inbox and calendar signals for Telegram delivery.
    Current time: #{DateTime.to_iso8601(timestamp)}

    Telegram threshold profile JSON:
    #{threshold_json}

    Recent Telegram feedback JSON:
    #{feedback_json}

    Input candidates JSON:
    #{candidates_json}

    Task:
    - Improve clarity and actionability for each candidate.
    - Learn the user's interruption preferences from the Helpful / Not Helpful history above.
    - Prefer candidates that resemble helpful examples and avoid candidates that resemble not_helpful examples.
    - Use metadata.context_brief, metadata.signals, sender/recipient details, organizer, location, description_excerpt, attendee response counts, and timing hints to make the output concrete.
    - Keep category and dedupe_key unchanged.
    - Keep confidence between 0 and 1.
    - Estimate telegram_fit_score between 0 and 1, where 1 means "this user should definitely get this in Telegram now".
    - Make summary specific in 1 to 2 sentences: explain the stake, who is involved, and timing.
    - Make recommended_action specific: include the immediate next step and, when useful, one or two supporting ideas in plain language.
    - Return a short why_now string and a short follow_up_ideas list with concrete suggestions.
    - Drop low-value candidates by omitting them.

    Return ONLY valid JSON array. Each item must include:
    dedupe_key, title, summary, recommended_action, priority, confidence, telegram_fit_score, telegram_fit_reason, why_now, follow_up_ideas
    """
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
    |> Map.put_new("metadata", %{})
  end

  defp contains_any?(text, terms) when is_binary(text) do
    text = String.downcase(text)
    Enum.any?(terms, &String.contains?(text, &1))
  end

  defp needs_prep?(nil, _summary, _window_hours), do: false

  defp needs_prep?(start_at, summary, window_hours) do
    within_window? =
      DateTime.diff(start_at, DateTime.utc_now(), :hour) >= 0 and
        DateTime.diff(start_at, DateTime.utc_now(), :hour) <= window_hours

    within_window? and contains_any?(summary, @prep_event_terms)
  end

  defp due_at_before(nil, _hours), do: nil

  defp due_at_before(start_at, hours) when is_integer(hours) and hours > 0 do
    DateTime.add(start_at, -hours, :hour)
  end

  defp maybe_add(list, true, builder), do: [builder.() | list]
  defp maybe_add(list, false, _builder), do: list

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

  defp read_list(attrs, key) when is_map(attrs) do
    value = fetch_attr(attrs, key)
    if is_list(value), do: value, else: []
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

  defp recipient_count(value) when is_binary(value) do
    value
    |> String.split(~r/[;,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> length()
  end

  defp recipient_count(_), do: 0

  defp matched_terms(text, terms) when is_binary(text) do
    text = String.downcase(text)

    terms
    |> Enum.filter(&String.contains?(text, &1))
    |> Enum.uniq()
  end

  defp email_context_brief(from, to, labels, age_hours, recipient_count) do
    []
    |> maybe_append("Sent by #{from}", present?(from))
    |> maybe_append("to #{truncate(to, 80)}", present?(to))
    |> maybe_append("labels #{Enum.join(labels, ", ")}", labels != [])
    |> maybe_append("#{age_hours}h old", is_integer(age_hours) and age_hours >= 0)
    |> maybe_append("#{recipient_count} recipients", recipient_count > 1)
    |> Enum.join(". ")
    |> suffix_period()
  end

  defp email_signals(labels, age_hours, recipient_count, urgent_matches, angry_matches) do
    []
    |> maybe_append("Unread inbox item", "UNREAD" in labels)
    |> maybe_append("Marked important", "IMPORTANT" in labels)
    |> maybe_append("Has urgent terms: #{Enum.join(urgent_matches, ", ")}", urgent_matches != [])
    |> maybe_append("Has tone-risk terms: #{Enum.join(angry_matches, ", ")}", angry_matches != [])
    |> maybe_append("Aging thread at #{age_hours}h", is_integer(age_hours) and age_hours >= 12)
    |> maybe_append("Multiple recipients: #{recipient_count}", recipient_count > 2)
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

  defp calendar_context_brief(
         organizer,
         location,
         attendee_count,
         response_counts,
         hours_until_start,
         description
       ) do
    accepted = Map.get(response_counts, "accepted", 0)
    tentative = Map.get(response_counts, "tentative", 0)
    declined = Map.get(response_counts, "declined", 0)

    []
    |> maybe_append("Organized by #{organizer}", present?(organizer))
    |> maybe_append("Location #{location}", present?(location))
    |> maybe_append("#{attendee_count} attendees", attendee_count > 0)
    |> maybe_append(
      "#{accepted} accepted / #{tentative} tentative / #{declined} declined",
      response_counts != %{}
    )
    |> maybe_append(
      "Starts in #{hours_until_start}h",
      is_integer(hours_until_start) and hours_until_start >= 0
    )
    |> maybe_append("Description: #{truncate(description, 120)}", present?(description))
    |> Enum.join(". ")
    |> suffix_period()
  end

  defp calendar_signals(location, organizer, attendee_count, response_counts, hours_until_start) do
    []
    |> maybe_append("High-attendee meeting", attendee_count >= 5)
    |> maybe_append("Organizer #{organizer}", present?(organizer))
    |> maybe_append("Location #{location}", present?(location))
    |> maybe_append("Response mix #{inspect(response_counts)}", response_counts != %{})
    |> maybe_append(
      "Starts soon in #{hours_until_start}h",
      is_integer(hours_until_start) and hours_until_start in 0..6
    )
  end

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp suffix_period(""), do: ""

  defp suffix_period(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> ""
      String.ends_with?(value, ".") -> value
      true -> value <> "."
    end
  end

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
end
