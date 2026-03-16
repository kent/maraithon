defmodule Maraithon.Behaviors.AIChiefOfStaff do
  @moduledoc """
  Unified operator-facing assistant that orchestrates internal Chief of Staff skills.

  The first implementation slice composes the existing follow-through, travel,
  and briefing systems behind one behavior and one builder template.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.ChiefOfStaff.Skills

  @impl true
  def init(config) do
    user_id = normalize_string(config["user_id"])
    enabled_skill_ids = Skills.enabled_ids(config)
    skill_configs = build_skill_configs(config, user_id, enabled_skill_ids)

    skill_states =
      Enum.reduce(enabled_skill_ids, %{}, fn skill_id, acc ->
        module = Skills.get!(skill_id)
        Map.put(acc, skill_id, module.init(Map.fetch!(skill_configs, skill_id)))
      end)

    %{
      user_id: user_id,
      enabled_skill_ids: enabled_skill_ids,
      skill_configs: skill_configs,
      skill_states: skill_states,
      pending_emit: nil,
      pending_effect_skill_id: nil,
      resume_index: 0
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state =
      case state.user_id do
        nil -> %{state | user_id: normalize_string(context[:user_id])}
        _ -> state
      end

    run_from_index(state.resume_index || 0, state, context)
  end

  @impl true
  def handle_effect_result(effect_result, state, context) do
    case state.pending_effect_skill_id do
      nil ->
        {:idle, state}

      skill_id ->
        module = Skills.get!(skill_id)
        skill_state = Map.fetch!(state.skill_states, skill_id)

        case module.handle_effect_result(effect_result, skill_state, context) do
          {:effect, effect, next_skill_state} ->
            {:effect, effect, put_skill_state(state, skill_id, next_skill_state)}

          {:emit, emit, next_skill_state} ->
            state =
              state
              |> put_skill_state(skill_id, next_skill_state)
              |> Map.put(:pending_effect_skill_id, nil)
              |> stash_emit(emit)

            run_from_index(state.resume_index || 0, state, context)

          {:idle, next_skill_state} ->
            state =
              state
              |> put_skill_state(skill_id, next_skill_state)
              |> Map.put(:pending_effect_skill_id, nil)

            run_from_index(state.resume_index || 0, state, context)
        end
    end
  end

  @impl true
  def next_wakeup(state) do
    state.enabled_skill_ids
    |> Enum.reduce(:none, fn skill_id, schedule ->
      module = Skills.get!(skill_id)
      skill_state = Map.fetch!(state.skill_states, skill_id)
      merge_wakeup(schedule, module.next_wakeup(skill_state))
    end)
  end

  def default_skill_ids, do: Skills.default_enabled_ids()

  defp run_from_index(index, state, context) when index < 0, do: run_from_index(0, state, context)

  defp run_from_index(index, state, context) do
    if index >= length(state.enabled_skill_ids) do
      finalize_cycle(%{state | resume_index: 0})
    else
      skill_id = Enum.at(state.enabled_skill_ids, index)
      module = Skills.get!(skill_id)
      skill_state = Map.fetch!(state.skill_states, skill_id)

      case module.handle_wakeup(skill_state, context) do
        {:effect, effect, next_skill_state} ->
          {:effect, effect,
           state
           |> put_skill_state(skill_id, next_skill_state)
           |> Map.put(:pending_effect_skill_id, skill_id)
           |> Map.put(:resume_index, index + 1)}

        {:emit, emit, next_skill_state} ->
          state =
            state
            |> put_skill_state(skill_id, next_skill_state)
            |> stash_emit(emit)

          run_from_index(index + 1, state, context)

        {:continue, next_skill_state} ->
          {:continue,
           state
           |> put_skill_state(skill_id, next_skill_state)
           |> Map.put(:resume_index, index)}

        {:idle, next_skill_state} ->
          state =
            state
            |> put_skill_state(skill_id, next_skill_state)

          run_from_index(index + 1, state, context)
      end
    end
  end

  defp finalize_cycle(state) do
    case state.pending_emit do
      nil ->
        {:idle, state}

      emit ->
        {:emit, emit, %{state | pending_emit: nil}}
    end
  end

  defp put_skill_state(state, skill_id, next_skill_state) do
    put_in(state, [:skill_states, skill_id], next_skill_state)
  end

  defp stash_emit(state, emit) do
    %{state | pending_emit: merge_emit(state.pending_emit, emit)}
  end

  defp build_skill_configs(config, user_id, enabled_skill_ids) do
    skill_config_overrides =
      read_map(config, "skill_configs")

    Enum.reduce(enabled_skill_ids, %{}, fn skill_id, acc ->
      module = Skills.get!(skill_id)

      merged =
        module.default_config()
        |> Map.merge(shared_skill_config(config, user_id))
        |> Map.merge(read_map(skill_config_overrides, skill_id))
        |> maybe_put("assistant_behavior", "ai_chief_of_staff")

      Map.put(acc, skill_id, merged)
    end)
  end

  defp shared_skill_config(config, user_id) do
    %{}
    |> maybe_put("user_id", user_id)
    |> maybe_put("source_policy", read_string(config, "source_policy", nil))
    |> maybe_put("source_scope", read_map(config, "source_scope"))
    |> maybe_put_integer("timezone_offset_hours", read_integer(config, "timezone_offset_hours"))
    |> maybe_put_integer(
      "morning_brief_hour_local",
      read_integer(config, "morning_brief_hour_local")
    )
    |> maybe_put_integer(
      "end_of_day_brief_hour_local",
      read_integer(config, "end_of_day_brief_hour_local")
    )
    |> maybe_put_integer(
      "weekly_review_day_local",
      read_integer(config, "weekly_review_day_local")
    )
    |> maybe_put_integer(
      "weekly_review_hour_local",
      read_integer(config, "weekly_review_hour_local")
    )
    |> maybe_put_integer("brief_max_items", read_integer(config, "brief_max_items"))
  end

  defp merge_emit(nil, emit), do: emit
  defp merge_emit(emit, nil), do: emit

  defp merge_emit({:insights_recorded, left}, {:insights_recorded, right}) do
    {:insights_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       categories: Enum.uniq(payload_list(left, :categories) ++ payload_list(right, :categories))
     }}
  end

  defp merge_emit({:insight_error, left}, {:insight_error, right}) do
    {:insight_error,
     %{
       reason:
         [payload_string(left, :reason), payload_string(right, :reason)]
         |> Enum.reject(&blank?/1)
         |> Enum.join(" | "),
       attempted_count:
         payload_int(left, :attempted_count, 0) + payload_int(right, :attempted_count, 0)
     }}
  end

  defp merge_emit({:briefs_recorded, left}, {:briefs_recorded, right}) do
    {:briefs_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       cadences: Enum.uniq(payload_list(left, :cadences) ++ payload_list(right, :cadences))
     }}
  end

  defp merge_emit({:brief_error, left}, {:brief_error, right}) do
    {:brief_error,
     %{
       reason:
         [payload_string(left, :reason), payload_string(right, :reason)]
         |> Enum.reject(&blank?/1)
         |> Enum.join(" | "),
       attempted_count:
         payload_int(left, :attempted_count, 0) + payload_int(right, :attempted_count, 0)
     }}
  end

  defp merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs}) do
    base = stringify_keys(recorded)
    briefs_key = shaped_key(recorded, :briefs)
    count_key = shaped_key(briefs, :count)
    cadences_key = shaped_key(briefs, :cadences)

    {:insights_recorded,
     Map.put(
       base,
       briefs_key,
       payload_list(recorded, :briefs) ++
         [
           %{
             count_key => payload_int(briefs, :count, 0),
             cadences_key => payload_list(briefs, :cadences)
           }
         ]
     )}
  end

  defp merge_emit({:briefs_recorded, briefs}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs})

  defp merge_emit({:insights_recorded, recorded}, {:insight_error, error}) do
    {:insights_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       shaped_key(recorded, :errors),
       payload_list(recorded, :errors) ++
         [
           %{
             shaped_key(error, :reason) => payload_string(error, :reason),
             shaped_key(error, :attempted_count) => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:insight_error, error}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:insight_error, error})

  defp merge_emit({:briefs_recorded, recorded}, {:brief_error, error}) do
    {:briefs_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       shaped_key(recorded, :errors),
       payload_list(recorded, :errors) ++
         [
           %{
             shaped_key(error, :reason) => payload_string(error, :reason),
             shaped_key(error, :attempted_count) => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:brief_error, error}, {:briefs_recorded, recorded}),
    do: merge_emit({:briefs_recorded, recorded}, {:brief_error, error})

  defp merge_emit(left, _right), do: left

  defp merge_wakeup(:none, other), do: other
  defp merge_wakeup(other, :none), do: other

  defp merge_wakeup({:relative, left_ms}, {:relative, right_ms}),
    do: {:relative, min(left_ms, right_ms)}

  defp merge_wakeup({:absolute, %DateTime{} = left}, {:absolute, %DateTime{} = right}) do
    if DateTime.compare(left, right) in [:lt, :eq],
      do: {:absolute, left},
      else: {:absolute, right}
  end

  defp merge_wakeup({:absolute, %DateTime{} = absolute}, {:relative, ms}) do
    relative_absolute = DateTime.add(DateTime.utc_now(), ms, :millisecond)

    if DateTime.compare(absolute, relative_absolute) == :gt,
      do: {:relative, ms},
      else: {:absolute, absolute}
  end

  defp merge_wakeup({:relative, ms}, {:absolute, %DateTime{} = absolute}),
    do: merge_wakeup({:absolute, absolute}, {:relative, ms})

  defp merge_wakeup(_left, right), do: right

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_integer(map, _key, nil), do: map
  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)

  defp read_map(payload, key) when is_map(payload) do
    case map_value(payload, key) do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp read_string(payload, key, default) when is_map(payload) do
    case map_value(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        value
        |> Atom.to_string()
        |> String.trim()
        |> case do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp read_integer(payload, key) when is_map(payload) do
    case map_value(payload, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp map_value(payload, key) when is_map(payload) and is_binary(key) do
    Map.get(payload, key) || Map.get(payload, existing_atom(key))
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_int(payload, key, default) do
    case payload_value(payload, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp payload_string(payload, key) do
    case payload_value(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp payload_list(payload, key) do
    case payload_value(payload, key) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp shaped_key(payload, key) when is_map(payload) do
    cond do
      Map.has_key?(payload, key) -> key
      Map.has_key?(payload, Atom.to_string(key)) -> Atom.to_string(key)
      true -> Atom.to_string(key)
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp stringify_keys(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      Map.put(acc, if(is_atom(key), do: Atom.to_string(key), else: key), value)
    end)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
