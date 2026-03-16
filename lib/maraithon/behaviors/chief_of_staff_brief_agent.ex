defmodule Maraithon.Behaviors.ChiefOfStaffBriefAgent do
  @moduledoc """
  Generates recurring chief-of-staff briefs from the current insight stream.

  It does not rescan connectors directly. Instead, it turns the user's existing
  Gmail, Calendar, and Slack insights into morning briefs, end-of-day debt
  rollups, and weekly reviews for Telegram delivery.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Briefs
  alias Maraithon.Insights

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_end_of_day_hour 18
  @default_weekly_day 5
  @default_weekly_hour 16
  @default_max_items 3

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      assistant_behavior:
        normalize_string(config["assistant_behavior"]) || "founder_followthrough_agent",
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      morning_hour:
        integer_in_range(config["morning_brief_hour_local"], @default_morning_hour, 0, 23),
      end_of_day_hour:
        integer_in_range(config["end_of_day_brief_hour_local"], @default_end_of_day_hour, 0, 23),
      weekly_day: integer_in_range(config["weekly_review_day_local"], @default_weekly_day, 1, 7),
      weekly_hour:
        integer_in_range(config["weekly_review_hour_local"], @default_weekly_hour, 0, 23),
      max_items: integer_in_range(config["brief_max_items"], @default_max_items, 1, 5),
      last_generated_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context.timestamp || DateTime.utc_now()

    due =
      state
      |> due_cadences(now)
      |> Enum.reject(fn %{cadence: cadence, period_key: period_key} ->
        Map.get(state.last_generated_keys, cadence) == period_key
      end)

    if due == [] or is_nil(user_id) do
      {:idle, %{state | user_id: user_id}}
    else
      case build_briefs(user_id, context.agent_id, state, due, now) do
        {:ok, []} ->
          {:idle,
           %{state | user_id: user_id, last_generated_keys: update_generated_keys(state, due)}}

        {:ok, briefs} ->
          {:emit,
           {:briefs_recorded,
            %{
              count: length(briefs),
              user_id: user_id,
              cadences: Enum.map(briefs, & &1.cadence)
            }},
           %{state | user_id: user_id, last_generated_keys: update_generated_keys(state, due)}}

        {:error, reason} ->
          {:emit, {:brief_error, %{reason: inspect(reason), attempted_count: length(due)}},
           %{state | user_id: user_id}}
      end
    end
  end

  @impl true
  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    now = DateTime.utc_now()

    [
      next_occurrence("morning", state, now),
      next_occurrence("end_of_day", state, now),
      next_occurrence("weekly_review", state, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :second), fn ->
      DateTime.add(now, :timer.hours(12), :millisecond)
    end)
    |> then(&{:absolute, &1})
  end

  defp build_briefs(user_id, agent_id, state, due, now) do
    open_insights = Insights.list_open_for_user(user_id, limit: 30)
    recent_insights = Insights.list_recent_for_user(user_id, limit: 60)

    due
    |> Enum.map(&build_brief_attrs(&1, state, open_insights, recent_insights, now))
    |> then(&Briefs.record_many(user_id, agent_id, &1))
  end

  defp build_brief_attrs(
         %{cadence: "morning"} = plan,
         state,
         open_insights,
         _recent_insights,
         now
       ) do
    due_today = Enum.filter(open_insights, &due_today?(&1, state.timezone_offset_hours, now))
    top_items = Enum.take(open_insights, state.max_items)

    {title, summary} =
      case length(top_items) do
        0 ->
          {"Morning brief: clean slate",
           "No urgent open items are surfacing right now across Gmail, Calendar, or Slack."}

        count ->
          {"Morning brief: #{count} items worth watching",
           "#{length(due_today)} due today, #{overdue_count(open_insights, state.timezone_offset_hours, now)} overdue, and #{count_by_source(open_insights, "slack")} from Slack."}
      end

    %{
      "cadence" => "morning",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("morning", plan.period_key),
      "title" => title,
      "summary" => summary,
      "body" => morning_body(top_items, open_insights, state.timezone_offset_hours, now),
      "metadata" => metadata_for(plan, state.assistant_behavior, open_insights)
    }
  end

  defp build_brief_attrs(
         %{cadence: "end_of_day"} = plan,
         state,
         open_insights,
         _recent_insights,
         _now
       ) do
    debt_items =
      open_insights
      |> Enum.filter(
        &(due_today?(&1, state.timezone_offset_hours, plan.scheduled_for) or
            overdue?(&1, state.timezone_offset_hours, plan.scheduled_for))
      )
      |> Enum.take(state.max_items)

    {title, summary} =
      case length(debt_items) do
        0 ->
          {"End-of-day debt: all clear",
           "Nothing high-confidence still looks open at the end of the day."}

        count ->
          {"End-of-day debt: #{count} items still open",
           "#{overdue_count(debt_items, state.timezone_offset_hours, plan.scheduled_for)} overdue and #{due_today_count(debt_items, state.timezone_offset_hours, plan.scheduled_for)} still due today."}
      end

    %{
      "cadence" => "end_of_day",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("end_of_day", plan.period_key),
      "title" => title,
      "summary" => summary,
      "body" =>
        end_of_day_body(
          debt_items,
          open_insights,
          state.timezone_offset_hours,
          plan.scheduled_for
        ),
      "metadata" => metadata_for(plan, state.assistant_behavior, debt_items)
    }
  end

  defp build_brief_attrs(
         %{cadence: "weekly_review"} = plan,
         state,
         open_insights,
         recent_insights,
         _now
       ) do
    week_cutoff = DateTime.add(plan.scheduled_for, -7, :day)

    weekly_items =
      recent_insights
      |> Enum.filter(fn insight ->
        DateTime.compare(insight.inserted_at, week_cutoff) in [:eq, :gt]
      end)

    top_open = Enum.take(open_insights, state.max_items)
    open_count = Enum.count(open_insights)
    closed_count = Enum.count(weekly_items, &(&1.status in ["acknowledged", "dismissed"]))

    %{
      "cadence" => "weekly_review",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("weekly_review", plan.period_key),
      "title" => "Weekly review: #{open_count} items still open",
      "summary" =>
        "#{length(weekly_items)} items surfaced this week, #{closed_count} were resolved or triaged, and #{open_count} remain open.",
      "body" =>
        weekly_body(top_open, weekly_items, state.timezone_offset_hours, plan.scheduled_for),
      "metadata" => metadata_for(plan, state.assistant_behavior, weekly_items)
    }
  end

  defp due_cadences(state, now) do
    local_now = shift_local(now, state.timezone_offset_hours)

    [
      due_plan("morning", state, now, local_now),
      due_plan("end_of_day", state, now, local_now),
      due_plan("weekly_review", state, now, local_now)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp due_plan("morning", state, utc_now, local_now) do
    scheduled_local = local_datetime(DateTime.to_date(local_now), state.morning_hour)
    scheduled_utc = shift_utc(scheduled_local, state.timezone_offset_hours)

    if DateTime.compare(utc_now, scheduled_utc) != :lt do
      %{
        cadence: "morning",
        period_key: Date.to_iso8601(DateTime.to_date(local_now)),
        scheduled_for: scheduled_utc
      }
    end
  end

  defp due_plan("end_of_day", state, utc_now, local_now) do
    scheduled_local = local_datetime(DateTime.to_date(local_now), state.end_of_day_hour)
    scheduled_utc = shift_utc(scheduled_local, state.timezone_offset_hours)

    if DateTime.compare(utc_now, scheduled_utc) != :lt do
      %{
        cadence: "end_of_day",
        period_key: Date.to_iso8601(DateTime.to_date(local_now)),
        scheduled_for: scheduled_utc
      }
    end
  end

  defp due_plan("weekly_review", state, utc_now, local_now) do
    local_date = DateTime.to_date(local_now)

    if Date.day_of_week(local_date) == state.weekly_day do
      scheduled_local = local_datetime(local_date, state.weekly_hour)
      scheduled_utc = shift_utc(scheduled_local, state.timezone_offset_hours)

      if DateTime.compare(utc_now, scheduled_utc) != :lt do
        %{
          cadence: "weekly_review",
          period_key: "#{Date.to_iso8601(local_date)}:#{state.weekly_day}",
          scheduled_for: scheduled_utc
        }
      end
    end
  end

  defp next_occurrence("morning", state, now) do
    next_daily_occurrence(now, state.timezone_offset_hours, state.morning_hour)
  end

  defp next_occurrence("end_of_day", state, now) do
    next_daily_occurrence(now, state.timezone_offset_hours, state.end_of_day_hour)
  end

  defp next_occurrence("weekly_review", state, now) do
    local_now = shift_local(now, state.timezone_offset_hours)
    local_date = DateTime.to_date(local_now)
    current_weekday = Date.day_of_week(local_date)

    days_ahead =
      case state.weekly_day - current_weekday do
        diff when diff < 0 ->
          diff + 7

        0 ->
          scheduled_today = local_datetime(local_date, state.weekly_hour)
          if DateTime.compare(local_now, scheduled_today) == :lt, do: 0, else: 7

        diff ->
          diff
      end

    target_date = Date.add(local_date, days_ahead)
    target_local = local_datetime(target_date, state.weekly_hour)
    shift_utc(target_local, state.timezone_offset_hours)
  end

  defp next_daily_occurrence(now, offset_hours, target_hour) do
    local_now = shift_local(now, offset_hours)
    local_date = DateTime.to_date(local_now)
    scheduled_today = local_datetime(local_date, target_hour)

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        local_datetime(Date.add(local_date, 1), target_hour)
      end

    shift_utc(target_local, offset_hours)
  end

  defp morning_body(top_items, open_insights, offset_hours, now) do
    """
    Focus today:
    #{format_items(top_items, offset_hours, now)}

    Snapshot:
    - #{length(open_insights)} open items across Gmail, Calendar, and Slack
    - #{overdue_count(open_insights, offset_hours, now)} already overdue
    - #{due_today_count(open_insights, offset_hours, now)} due today
    """
    |> String.trim()
  end

  defp end_of_day_body(debt_items, open_insights, offset_hours, now) do
    """
    Tonight's top actions:
    #{format_items(debt_items, offset_hours, now)}

    Why it matters:
    - #{overdue_count(open_insights, offset_hours, now)} items are already overdue
    - #{due_today_count(open_insights, offset_hours, now)} were due today and still unresolved
    """
    |> String.trim()
  end

  defp weekly_body(top_open, weekly_items, offset_hours, reference_at) do
    """
    Weekly scorecard:
    - #{count_by_source(weekly_items, "gmail")} Gmail items
    - #{count_by_source(weekly_items, "calendar")} Calendar follow-ups
    - #{count_by_source(weekly_items, "slack")} Slack loops

    Most important open items:
    #{format_items(top_open, offset_hours, reference_at)}
    """
    |> String.trim()
  end

  defp format_items([], _offset_hours, _reference_at), do: "1. Nothing high-signal is open."

  defp format_items(items, offset_hours, reference_at) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn insight ->
      format_item_block(insight, offset_hours, reference_at)
    end)
    |> Enum.join("\n")
  end

  defp format_item_block({insight, index}, offset_hours, reference_at) do
    source = source_label(insight.source)
    why_now = item_why_now(insight, offset_hours, reference_at)

    """
    #{index}. [#{source}] #{insight.title}
    Next: #{insight.recommended_action}
    Why now: #{why_now}
    """
    |> String.trim()
  end

  defp item_why_now(insight, offset_hours, reference_at) do
    metadata = insight.metadata || %{}

    case read_string(metadata, "why_now") do
      nil ->
        due_context(insight, offset_hours, reference_at) || insight.summary

      why_now ->
        due_context(insight, offset_hours, reference_at) || why_now
    end
  end

  defp due_context(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local = shift_local(due_at, offset_hours)
        now_local = shift_local(reference_at, offset_hours)
        due_date = DateTime.to_date(due_local)
        today = DateTime.to_date(now_local)

        cond do
          DateTime.compare(due_local, now_local) == :lt ->
            "Overdue since #{Calendar.strftime(due_local, "%a %-m/%-d %-I:%M %p")}."

          due_date == today ->
            "Due today by #{Calendar.strftime(due_local, "%-I:%M %p")}."

          due_date == Date.add(today, 1) ->
            "Due tomorrow by #{Calendar.strftime(due_local, "%-I:%M %p")}."

          true ->
            "Due #{Calendar.strftime(due_local, "%a %-m/%-d %-I:%M %p")}."
        end

      _ ->
        nil
    end
  end

  defp metadata_for(plan, behavior, insights) do
    %{
      "period_key" => plan.period_key,
      "agent_behavior" => behavior,
      "insight_count" => length(insights),
      "sources" => insights |> Enum.map(& &1.source) |> Enum.uniq()
    }
  end

  defp update_generated_keys(state, due) do
    Enum.reduce(due, state.last_generated_keys, fn %{cadence: cadence, period_key: period_key},
                                                   acc ->
      Map.put(acc, cadence, period_key)
    end)
  end

  defp dedupe_key(cadence, period_key), do: "brief:#{cadence}:#{period_key}"

  defp overdue_count(insights, offset_hours, reference_at),
    do: Enum.count(insights, &overdue?(&1, offset_hours, reference_at))

  defp due_today_count(insights, offset_hours, reference_at),
    do: Enum.count(insights, &due_today?(&1, offset_hours, reference_at))

  defp count_by_source(insights, source) do
    Enum.count(insights, fn insight -> normalize_source(insight.source) == source end)
  end

  defp due_today?(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local_date = due_at |> shift_local(offset_hours) |> DateTime.to_date()
        now_local_date = reference_at |> shift_local(offset_hours) |> DateTime.to_date()
        Date.compare(due_local_date, now_local_date) == :eq

      _ ->
        false
    end
  end

  defp overdue?(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local = shift_local(due_at, offset_hours)
        now_local = shift_local(reference_at, offset_hours)
        DateTime.compare(due_local, now_local) == :lt

      _ ->
        false
    end
  end

  defp source_label(source),
    do: source |> normalize_source() |> to_string() |> String.capitalize()

  defp normalize_source("google_calendar"), do: "calendar"
  defp normalize_source(other), do: other

  defp shift_local(datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * 3600, :second)
  end

  defp shift_utc(datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * -3600, :second)
  end

  defp local_datetime(date, hour) do
    {:ok, dt} = DateTime.new(date, Time.new!(hour, 0, 0), "Etc/UTC")
    dt
  end

  defp integer_in_range(value, default, min, max) do
    case value do
      int when is_integer(int) and int >= min and int <= max ->
        int

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {int, ""} when int >= min and int <= max -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp read_string(attrs, key) when is_map(attrs) and is_binary(key) do
    attrs
    |> Map.get(key)
    |> normalize_string()
  end

  defp read_string(_attrs, _key), do: nil
end
