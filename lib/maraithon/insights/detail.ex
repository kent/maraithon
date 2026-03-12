defmodule Maraithon.Insights.Detail do
  @moduledoc """
  Normalizes persisted insight metadata and related deliveries into a detail payload
  shared by the dashboard and Telegram explanation surfaces.
  """

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Insight

  @max_summary_evidence 3

  @exact_promise_gap "Exact promise not captured for this insight."
  @requester_gap "Requester not captured for this insight."
  @evidence_gap "No persisted evidence bullets were captured for this insight."
  @delivery_gap "No delivery attempts recorded."
  @reason_gap "Open-loop reason could not be reconstructed from persisted data."

  def build(%Insight{} = insight, deliveries \\ []) when is_list(deliveries) do
    metadata = stringify_keys(insight.metadata || %{})
    detail_metadata = read_map(metadata, "detail")
    record = read_map(metadata, "record")

    promise_text = build_promise_text(insight, metadata, detail_metadata, record)
    requested_by = build_requested_by(metadata, detail_metadata, record)
    evidence_checked = build_evidence_checked(insight, metadata, detail_metadata, record)
    delivery_evidence = build_delivery_evidence(deliveries)

    open_loop_reason =
      build_open_loop_reason(insight, metadata, detail_metadata, record, delivery_evidence)

    %{
      promise_text: promise_text,
      requested_by: requested_by,
      evidence_checked: evidence_checked,
      delivery_evidence: delivery_evidence,
      open_loop_reason: open_loop_reason,
      data_gaps:
        build_data_gaps(
          promise_text,
          requested_by,
          evidence_checked,
          delivery_evidence,
          open_loop_reason
        )
    }
  end

  def summary_text(detail, %Insight{} = insight, opts \\ []) when is_map(detail) do
    reason_text =
      case Map.get(detail, :open_loop_reason) do
        %{text: text} when is_binary(text) and text != "" ->
          text

        _ ->
          "This still appears open based on the persisted evidence I checked."
      end

    evidence_text =
      detail
      |> Map.get(:evidence_checked, [])
      |> Enum.map(&summary_evidence_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_summary_evidence)
      |> case do
        [] -> "I didn't find completion evidence after the original commitment."
        lines -> Enum.map_join(lines, "\n", &"- #{&1}")
      end

    extra_reply =
      opts
      |> Keyword.get(:extra_reply)
      |> normalize_text()
      |> case do
        nil -> ""
        reply -> "\n\n#{reply}"
      end

    """
    I surfaced this because it still looks like an open loop.

    Why now:
    #{reason_text}

    Evidence checked:
    #{evidence_text}

    Recommended action:
    #{insight.recommended_action}#{extra_reply}
    """
    |> String.trim()
  end

  def telemetry_metadata(%Insight{} = insight, detail) when is_map(detail) do
    %{
      category: insight.category,
      reason_origin: reason_origin(detail),
      has_promise_text: not is_nil(Map.get(detail, :promise_text)),
      data_gap_count: length(Map.get(detail, :data_gaps, [])),
      has_delivery_evidence: Map.get(detail, :delivery_evidence, []) != []
    }
  end

  def coverage_measurements(cards) when is_list(cards) do
    %{
      insight_count: length(cards),
      with_promise_text: Enum.count(cards, &has_promise_text?/1),
      with_any_reason: Enum.count(cards, &has_reason?/1),
      with_stored_reason: Enum.count(cards, &has_stored_reason?/1),
      with_delivery_evidence: Enum.count(cards, &has_delivery_evidence?/1)
    }
  end

  defp has_promise_text?(%{detail: %{promise_text: %{} = _promise_text}}), do: true
  defp has_promise_text?(_card), do: false

  defp has_reason?(%{detail: %{open_loop_reason: %{} = _reason}}), do: true
  defp has_reason?(_card), do: false

  defp has_stored_reason?(%{detail: %{open_loop_reason: %{origin: :stored}}}), do: true
  defp has_stored_reason?(_card), do: false

  defp has_delivery_evidence?(%{detail: %{delivery_evidence: delivery_evidence}})
       when is_list(delivery_evidence),
       do: delivery_evidence != []

  defp has_delivery_evidence?(_card), do: false

  defp reason_origin(%{open_loop_reason: %{origin: origin}}) when origin in [:stored, :derived],
    do: Atom.to_string(origin)

  defp reason_origin(_detail), do: "unknown"

  defp build_promise_text(insight, metadata, detail_metadata, record) do
    case first_present([
           read_string(detail_metadata, "promise_text"),
           read_string(record, "commitment"),
           read_string(metadata, "commitment")
         ]) do
      nil ->
        case reconstruct_promise_text(insight) do
          nil -> nil
          text -> %{text: text, origin: :reconstructed}
        end

      text ->
        %{text: text, origin: :stored}
    end
  end

  defp reconstruct_promise_text(%Insight{} = insight) do
    first_present([
      normalize_text(insight.title),
      normalize_text(insight.summary),
      normalize_text(insight.recommended_action)
    ])
  end

  defp build_requested_by(metadata, detail_metadata, record) do
    case first_present([
           read_string(detail_metadata, "requested_by"),
           read_string(record, "person"),
           read_string(metadata, "person")
         ]) do
      nil ->
        case first_present([
               primary_contact(read_string(metadata, "from")),
               primary_contact(read_string(metadata, "organizer")),
               primary_contact(read_string(metadata, "to")),
               normalize_text(read_string(metadata, "attendee_preview"))
             ]) do
          nil -> nil
          text -> %{text: text, origin: :derived}
        end

      text ->
        %{text: text, origin: :stored}
    end
  end

  defp build_evidence_checked(insight, metadata, detail_metadata, record) do
    source_ref = default_source_ref(insight, metadata, record)

    detail_items =
      detail_metadata
      |> read_list("checked_evidence")
      |> Enum.map(&normalize_detail_evidence_item(&1, source_ref))
      |> Enum.reject(&is_nil/1)

    string_evidence =
      case read_string_list(record, "evidence", 10) do
        [] -> read_string_list(metadata, "evidence", 10)
        values -> values
      end

    items =
      detail_items ++
        Enum.map(string_evidence, &string_evidence_item(&1, source_ref)) ++
        supplemental_evidence_items(insight, metadata, record, source_ref)

    dedupe_evidence_items(items)
  end

  defp normalize_detail_evidence_item(item, default_source_ref) when is_map(item) do
    label = read_string(item, "label")
    detail = read_string(item, "detail")

    if is_nil(label) and is_nil(detail) do
      nil
    else
      %{
        kind: normalize_evidence_kind(read_string(item, "kind", "other")),
        label: label || detail,
        detail: if(label, do: detail, else: nil),
        occurred_at: read_datetime(item, "occurred_at"),
        source_ref: read_string(item, "source_ref") || default_source_ref
      }
    end
  end

  defp normalize_detail_evidence_item(_item, _default_source_ref), do: nil

  defp string_evidence_item(line, source_ref) do
    %{
      kind: :source_evidence,
      label: line,
      detail: nil,
      occurred_at: nil,
      source_ref: source_ref
    }
  end

  defp supplemental_evidence_items(insight, metadata, record, source_ref) do
    []
    |> maybe_append(source_timestamp_item(insight, source_ref))
    |> maybe_append(deadline_item(insight, metadata, record))
    |> maybe_append(status_item(metadata, record))
  end

  defp source_timestamp_item(%Insight{source_occurred_at: %DateTime{} = occurred_at}, source_ref) do
    %{
      kind: :source_evidence,
      label: "Source occurrence recorded",
      detail: "Occurred at #{DateTime.to_iso8601(occurred_at)}",
      occurred_at: occurred_at,
      source_ref: source_ref
    }
  end

  defp source_timestamp_item(_insight, _source_ref), do: nil

  defp deadline_item(%Insight{due_at: %DateTime{} = due_at}, _metadata, _record) do
    %{
      kind: :deadline,
      label: "Deadline",
      detail: "Due #{DateTime.to_iso8601(due_at)}",
      occurred_at: due_at,
      source_ref: nil
    }
  end

  defp deadline_item(_insight, metadata, record) do
    deadline =
      first_present([
        read_string(record, "deadline"),
        read_string(metadata, "deadline")
      ])

    case parse_datetime(deadline) do
      %DateTime{} = due_at ->
        %{
          kind: :deadline,
          label: "Deadline",
          detail: "Due #{DateTime.to_iso8601(due_at)}",
          occurred_at: due_at,
          source_ref: nil
        }

      nil when is_binary(deadline) ->
        %{
          kind: :deadline,
          label: "Deadline",
          detail: "Due #{deadline}",
          occurred_at: nil,
          source_ref: nil
        }

      _ ->
        nil
    end
  end

  defp status_item(metadata, record) do
    case first_present([
           read_string(record, "status"),
           read_string(metadata, "status")
         ]) do
      nil ->
        nil

      status ->
        %{
          kind: :record_status,
          label: "Stored status",
          detail: humanize_text(status),
          occurred_at: nil,
          source_ref: nil
        }
    end
  end

  defp dedupe_evidence_items(items) do
    items
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn item ->
      {
        item.kind,
        item.label,
        item.detail,
        item.occurred_at && DateTime.to_iso8601(item.occurred_at),
        item.source_ref
      }
    end)
  end

  defp build_delivery_evidence(deliveries) do
    deliveries
    |> Enum.map(&normalize_delivery/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_delivery(%Delivery{} = delivery) do
    channel = normalize_text(delivery.channel) || "unknown"

    %{
      channel: channel,
      destination_label: safe_destination_label(delivery),
      status: normalize_text(delivery.status) || "unknown",
      sent_at: delivery.sent_at,
      feedback: normalize_text(delivery.feedback),
      feedback_at: delivery.feedback_at,
      error_message: sanitize_error_message(delivery.error_message)
    }
  end

  defp safe_destination_label(%Delivery{} = delivery) do
    metadata = stringify_keys(delivery.metadata || %{})

    first_present([
      read_string(metadata, "destination_label"),
      read_string(metadata, "safe_destination_label"),
      read_string(metadata, "channel_label")
    ]) ||
      case normalize_text(delivery.channel) do
        "telegram" -> "Telegram linked chat"
        nil -> "Channel destination"
        channel -> "#{humanize_text(channel)} destination"
      end
  end

  defp sanitize_error_message(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      message ->
        message
        |> String.replace(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, "[redacted]")
        |> String.replace(~r/\b(?:C|D|G|U|T)[A-Z0-9]{6,}\b/, "[redacted]")
        |> String.replace(~r/\b\d{5,}\b/, "[redacted]")
        |> truncate(140)
    end
  end

  defp sanitize_error_message(_value), do: nil

  defp build_open_loop_reason(insight, metadata, detail_metadata, record, delivery_evidence) do
    case stored_open_loop_reason(detail_metadata) do
      %{} = stored_reason ->
        stored_reason

      nil ->
        case first_present([
               read_string(metadata, "reasoning_summary"),
               read_string(metadata, "why_now"),
               read_string(metadata, "context_brief")
             ]) do
          nil ->
            derived_open_loop_reason(insight, metadata, record, delivery_evidence)

          text ->
            %{
              text: text,
              origin: :stored,
              factors: derive_reason_factors(insight, metadata, record, delivery_evidence),
              evaluated_at: nil
            }
        end
    end
  end

  defp stored_open_loop_reason(detail_metadata) do
    evaluated_at = read_datetime(detail_metadata, "evaluated_at")

    case fetch_attr(detail_metadata, "open_loop_reason") do
      value when is_binary(value) ->
        text = normalize_text(value)

        if is_nil(text) do
          nil
        else
          %{
            text: text,
            origin: :stored,
            factors: read_string_list(detail_metadata, "factors", 10),
            evaluated_at: evaluated_at
          }
        end

      value when is_map(value) ->
        case read_string(value, "text") do
          nil ->
            nil

          text ->
            %{
              text: text,
              origin: :stored,
              factors: read_string_list(value, "factors", 10),
              evaluated_at: read_datetime(value, "evaluated_at") || evaluated_at
            }
        end

      _ ->
        nil
    end
  end

  defp derived_open_loop_reason(insight, metadata, record, delivery_evidence) do
    factors = derive_reason_factors(insight, metadata, record, delivery_evidence)

    case factors do
      [] ->
        nil

      _ ->
        %{
          text: Enum.take(factors, 2) |> Enum.join(" "),
          origin: :derived,
          factors: factors,
          evaluated_at: nil
        }
    end
  end

  defp derive_reason_factors(insight, metadata, record, delivery_evidence) do
    []
    |> maybe_append(
      "The stored record is still marked unresolved.",
      unresolved_status?(metadata, record)
    )
    |> maybe_append(
      "Persisted evidence still does not show completion after the original commitment.",
      missing_completion_evidence?(metadata, record)
    )
    |> maybe_append(deadline_factor(insight, metadata, record))
    |> maybe_append(
      "There is delivery history for this insight, but no persisted completion signal closes the loop.",
      delivery_evidence != []
    )
    |> maybe_append(source_occurrence_factor(insight))
    |> ensure_reason_fallback(insight)
  end

  defp unresolved_status?(metadata, record) do
    case first_present([
           read_string(record, "status"),
           read_string(metadata, "status")
         ]) do
      nil -> false
      status -> String.downcase(status) == "unresolved"
    end
  end

  defp missing_completion_evidence?(metadata, record) do
    read_boolean(metadata, "missing_followthrough_evidence", false) or
      read_string_list(record, "evidence", 1) != [] or
      read_string_list(metadata, "evidence", 1) != []
  end

  defp deadline_factor(%Insight{due_at: %DateTime{} = due_at}, _metadata, _record) do
    today = Date.utc_today()
    due_date = DateTime.to_date(due_at)

    cond do
      Date.compare(due_date, today) == :lt ->
        "The due date has already passed."

      due_date == today ->
        "The due date is today."

      due_date == Date.add(today, 1) ->
        "The due date is tomorrow."

      true ->
        "The due date is #{Date.to_iso8601(due_date)}."
    end
  end

  defp deadline_factor(_insight, metadata, record) do
    case first_present([
           read_string(record, "deadline"),
           read_string(metadata, "deadline")
         ]) do
      nil -> nil
      deadline -> "The stored deadline is #{deadline}."
    end
  end

  defp source_occurrence_factor(%Insight{source_occurred_at: %DateTime{} = occurred_at}) do
    "The source evidence was last recorded at #{DateTime.to_iso8601(occurred_at)}."
  end

  defp source_occurrence_factor(_insight), do: nil

  defp ensure_reason_fallback([], %Insight{}) do
    ["The insight still appears open and no persisted completion signal closes it."]
  end

  defp ensure_reason_fallback(factors, _insight), do: factors

  defp build_data_gaps(
         promise_text,
         requested_by,
         evidence_checked,
         delivery_evidence,
         open_loop_reason
       ) do
    []
    |> maybe_append(@exact_promise_gap, is_nil(promise_text))
    |> maybe_append(@requester_gap, is_nil(requested_by))
    |> maybe_append(@evidence_gap, evidence_checked == [])
    |> maybe_append(@delivery_gap, delivery_evidence == [])
    |> maybe_append(@reason_gap, is_nil(open_loop_reason))
  end

  defp summary_evidence_line(item) when is_map(item) do
    label = normalize_text(item.label)
    detail = normalize_text(item.detail)

    cond do
      label && detail -> "#{label}: #{detail}"
      label -> label
      detail -> detail
      true -> nil
    end
  end

  defp default_source_ref(%Insight{} = insight, metadata, record) do
    first_present([
      read_string(record, "source"),
      read_string(metadata, "source"),
      normalize_text(insight.source_id)
    ])
  end

  defp normalize_evidence_kind(kind)
       when kind in ["source_evidence", "record_status", "deadline", "delivery", "other"] do
    String.to_existing_atom(kind)
  rescue
    _ -> :other
  end

  defp normalize_evidence_kind(_kind), do: :other

  defp maybe_append(list, value, true) when is_list(list), do: list ++ [value]
  defp maybe_append(list, _value, false) when is_list(list), do: list
  defp maybe_append(list, nil) when is_list(list), do: list
  defp maybe_append(list, value) when is_list(list), do: list ++ [value]

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp humanize_text(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.capitalize(text)
    end
  end

  defp humanize_text(_value), do: nil

  defp primary_contact(value) when is_binary(value) do
    case String.split(value, ~r/[;,]/, trim: true) do
      [first | _] ->
        first = String.trim(first)

        case Regex.run(~r/^\s*([^<]+?)\s*<([^>]+)>\s*$/, first, capture: :all_but_first) do
          [name, _email] ->
            normalize_text(name)

          _ ->
            normalize_text(first)
        end

      _ ->
        nil
    end
  end

  defp primary_contact(_value), do: nil

  defp read_boolean(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_boolean(value) ->
        value

      value when is_integer(value) ->
        value != 0

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> true
          "1" -> true
          "yes" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_map(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> stringify_keys(value)
      _ -> %{}
    end
  end

  defp read_list(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp read_string(attrs, key, default \\ nil) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        normalize_text(value) || default

      _ ->
        default
    end
  end

  defp read_string_list(attrs, key, limit) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_text/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      value when is_binary(value) ->
        value
        |> String.split(~r/\r?\n|;/, trim: true)
        |> Enum.map(&normalize_text/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp read_datetime(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        parse_datetime(value)

      _ ->
        nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            date
            |> NaiveDateTime.new(~T[09:00:00])
            |> case do
              {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp first_present(values) when is_list(values) do
    Enum.find(values, &(not is_nil(&1)))
  end

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
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
end
