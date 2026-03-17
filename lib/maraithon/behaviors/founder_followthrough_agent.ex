defmodule Maraithon.Behaviors.FounderFollowthroughAgent do
  @moduledoc """
  Compatibility wrapper for the focused Chief of Staff operating mode.

  Legacy follow-through behaviors now run on top of the Chief of Staff skill
  stack with only the `followthrough` and `briefing` skills enabled. This keeps
  older agent identities working while moving the actual orchestration into the
  Chief of Staff runtime.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Behaviors.AIChiefOfStaff

  @chief_of_staff_skill_ids ["followthrough", "briefing"]

  @impl true
  def init(config) do
    config
    |> chief_of_staff_config()
    |> AIChiefOfStaff.init()
  end

  @impl true
  def handle_wakeup(state, context), do: AIChiefOfStaff.handle_wakeup(state, context)

  @impl true
  def handle_effect_result(effect_result, state, context),
    do: AIChiefOfStaff.handle_effect_result(effect_result, state, context)

  @impl true
  def next_wakeup(state), do: AIChiefOfStaff.next_wakeup(state)

  defp chief_of_staff_config(config) when is_map(config) do
    config
    |> stringify_keys()
    |> Map.put("enabled_skills", @chief_of_staff_skill_ids)
    |> Map.put("skill_configs", skill_configs(config))
  end

  defp chief_of_staff_config(config), do: chief_of_staff_config(%{config: config})

  defp skill_configs(config) do
    config = stringify_keys(config)

    %{
      "followthrough" =>
        compact_map(%{
          "email_scan_limit" => integer_value(config, "email_scan_limit"),
          "event_scan_limit" => integer_value(config, "event_scan_limit"),
          "prep_window_hours" => integer_value(config, "prep_window_hours"),
          "team_id" => string_value(config, "team_id"),
          "channel_scan_limit" => integer_value(config, "channel_scan_limit"),
          "dm_scan_limit" => integer_value(config, "dm_scan_limit"),
          "lookback_hours" => integer_value(config, "lookback_hours"),
          "max_insights_per_cycle" => integer_value(config, "max_insights_per_cycle"),
          "min_confidence" => float_value(config, "min_confidence"),
          "timezone_offset_hours" => integer_value(config, "timezone_offset_hours"),
          "source_policy" => string_value(config, "source_policy"),
          "source_scope" => map_value(config, "source_scope")
        }),
      "briefing" =>
        compact_map(%{
          "assistant_behavior" => "ai_chief_of_staff",
          "timezone_offset_hours" => integer_value(config, "timezone_offset_hours"),
          "morning_brief_hour_local" => integer_value(config, "morning_brief_hour_local"),
          "end_of_day_brief_hour_local" => integer_value(config, "end_of_day_brief_hour_local"),
          "weekly_review_day_local" => integer_value(config, "weekly_review_day_local"),
          "weekly_review_hour_local" => integer_value(config, "weekly_review_hour_local"),
          "brief_max_items" => integer_value(config, "brief_max_items")
        })
    }
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp integer_value(map, key) do
    value = Map.get(map, key)

    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp float_value(map, key) do
    value = Map.get(map, key)

    cond do
      is_float(value) ->
        value

      is_integer(value) ->
        value / 1

      is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        value
        |> Atom.to_string()
        |> string_value_from_string()

      _ ->
        nil
    end
  end

  defp string_value_from_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp map_value(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end
end
