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
  alias Maraithon.Insights

  require Logger

  @default_wakeup_interval_ms :timer.minutes(10)
  @default_email_scan_limit 12
  @default_event_scan_limit 12
  @default_prep_window_hours 24
  @default_max_insights_per_cycle 6
  @default_min_confidence 0.55

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
                "content" => build_llm_prompt(candidates, context.timestamp)
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
    body = String.downcase("#{subject} #{snippet}")
    message_id = read_string(email, "message_id", Ecto.UUID.generate())
    occurred_at = read_datetime(email, "internal_date")

    []
    |> maybe_add(contains_any?(body, @urgent_terms), fn ->
      %{
        source: "gmail",
        source_id: message_id,
        source_occurred_at: occurred_at,
        category: "reply_urgent",
        title: "Reply soon: #{truncate(subject, 90)}",
        summary: "Email from #{from} appears time-sensitive.",
        recommended_action: "Reply today and acknowledge the request.",
        priority: 88,
        confidence: 0.82,
        due_at: DateTime.add(DateTime.utc_now(), 4, :hour),
        dedupe_key: "email:#{message_id}:reply_urgent",
        metadata: %{"from" => from, "subject" => subject, "snippet" => snippet}
      }
    end)
    |> maybe_add(contains_any?(body, @angry_terms), fn ->
      %{
        source: "gmail",
        source_id: message_id,
        source_occurred_at: occurred_at,
        category: "tone_risk",
        title: "Tone risk in email: #{truncate(subject, 80)}",
        summary: "Message language suggests potential frustration or escalation risk.",
        recommended_action: "Respond calmly, confirm understanding, and propose next steps.",
        priority: 80,
        confidence: 0.74,
        due_at: DateTime.add(DateTime.utc_now(), 6, :hour),
        dedupe_key: "email:#{message_id}:tone_risk",
        metadata: %{"from" => from, "subject" => subject, "snippet" => snippet}
      }
    end)
    |> Enum.map(&normalize_candidate(&1, state))
  end

  defp email_candidates(_email, _state), do: []

  defp calendar_candidates(event, state) when is_map(event) do
    summary = read_string(event, "summary", "(untitled event)")
    event_id = read_string(event, "event_id", Ecto.UUID.generate())
    start_at = read_datetime(event, "start")
    attendees = read_list(event, "attendees")
    body = String.downcase(summary)
    attendee_count = length(attendees)

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
        summary: "This event looks high-impact based on content and attendee profile.",
        recommended_action: "Review agenda and align on desired outcomes.",
        priority: 78,
        confidence: if(attendee_count >= 5, do: 0.8, else: 0.7),
        due_at: due_at_before(start_at, 2),
        dedupe_key: "calendar:#{event_id}:event_important",
        metadata: %{"summary" => summary, "attendee_count" => attendee_count}
      }
    end)
    |> maybe_add(prep_soon?, fn ->
      %{
        source: "calendar",
        source_id: event_id,
        source_occurred_at: start_at,
        category: "event_prep_needed",
        title: "Prep needed: #{truncate(summary, 90)}",
        summary: "This upcoming event likely needs preparation.",
        recommended_action: "Set prep time and gather notes/docs before the meeting.",
        priority: 84,
        confidence: 0.79,
        due_at: due_at_before(start_at, 3),
        dedupe_key: "calendar:#{event_id}:event_prep_needed",
        metadata: %{"summary" => summary, "start" => to_iso8601(start_at)}
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
      end
    end
  end

  defp merge_llm_item(_item, _by_key, _min_confidence), do: nil

  defp build_llm_prompt(candidates, timestamp) do
    candidates_json = Jason.encode!(candidates)

    """
    You are an executive assistant analyzing inbox and calendar signals.
    Current time: #{DateTime.to_iso8601(timestamp)}

    Input candidates JSON:
    #{candidates_json}

    Task:
    - Improve clarity and actionability for each candidate.
    - Keep category and dedupe_key unchanged.
    - Keep confidence between 0 and 1.
    - Drop low-value candidates by omitting them.

    Return ONLY valid JSON array. Each item must include:
    dedupe_key, title, summary, recommended_action, priority, confidence
    """
  end

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

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

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
