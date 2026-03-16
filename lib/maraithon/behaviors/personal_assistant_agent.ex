defmodule Maraithon.Behaviors.PersonalAssistantAgent do
  @moduledoc """
  Proactive personal assistant behavior focused on day-before travel prep.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Travel

  require Logger

  @default_email_scan_limit 25
  @default_event_scan_limit 25
  @default_lookback_hours 24 * 30
  @default_min_confidence 0.8
  @default_wakeup_interval_ms :timer.minutes(30)
  @default_timezone_offset_hours -5

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      email_scan_limit: positive_integer(config["email_scan_limit"], @default_email_scan_limit),
      event_scan_limit: positive_integer(config["event_scan_limit"], @default_event_scan_limit),
      lookback_hours: positive_integer(config["lookback_hours"], @default_lookback_hours),
      min_confidence: float_in_range(config["min_confidence"], @default_min_confidence, 0.0, 1.0),
      wakeup_interval_ms:
        positive_integer(config["wakeup_interval_ms"], @default_wakeup_interval_ms),
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14)
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])

    if is_nil(user_id) do
      Logger.warning("PersonalAssistantAgent skipped wakeup: user_id missing",
        agent_id: context.agent_id
      )

      {:idle, state}
    else
      case Travel.sync_recent_trip_data(user_id, context.agent_id,
             now: context.timestamp || DateTime.utc_now(),
             event: context.event,
             email_scan_limit: state.email_scan_limit,
             event_scan_limit: state.event_scan_limit,
             lookback_hours: state.lookback_hours,
             min_confidence: state.min_confidence,
             timezone_offset_hours: state.timezone_offset_hours
           ) do
        {:ok, %{queued_briefs: []}} ->
          {:idle, %{state | user_id: user_id}}

        {:ok, %{queued_briefs: queued}} ->
          {:emit,
           {:briefs_recorded,
            %{
              count: length(queued),
              user_id: user_id,
              cadences: queued |> Enum.map(& &1.cadence) |> Enum.uniq()
            }}, %{state | user_id: user_id}}

        {:error, reason} ->
          Logger.warning("PersonalAssistantAgent travel sync failed",
            user_id: user_id,
            reason: inspect(reason)
          )

          {:idle, %{state | user_id: user_id}}
      end
    end
  end

  @impl true
  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state), do: {:relative, state.wakeup_interval_ms}

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp integer_in_range(value, _default, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: value

  defp integer_in_range(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= min and parsed <= max -> parsed
      _ -> default
    end
  end

  defp integer_in_range(_value, default, _min, _max), do: default

  defp float_in_range(value, _default, min, max)
       when is_float(value) and value >= min and value <= max,
       do: value

  defp float_in_range(value, default, min, max) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= min and parsed <= max -> parsed
      _ -> default
    end
  end

  defp float_in_range(_value, default, _min, _max), do: default
end
