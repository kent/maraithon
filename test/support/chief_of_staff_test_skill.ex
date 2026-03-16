defmodule Maraithon.TestSupport.ChiefOfStaffTestSkill do
  @moduledoc false

  @behaviour Maraithon.ChiefOfStaff.Skill

  @impl true
  def id, do: "test_skill"

  @impl true
  def default_config, do: %{}

  @impl true
  def requirements, do: []

  @impl true
  def subscriptions(config, _user_id) do
    case config["subscriptions"] do
      values when is_list(values) -> values
      _ -> []
    end
  end

  @impl true
  def init(config) do
    %{
      wakeup_mode: read_string(config, "wakeup_mode", "idle"),
      wakeup_emit_type: read_string(config, "wakeup_emit_type", nil),
      wakeup_payload: read_map(config, "wakeup_payload"),
      effect_kind: read_string(config, "effect_kind", "llm_call"),
      effect_params: read_map(config, "effect_params"),
      effect_result_mode: read_string(config, "effect_result_mode", "idle"),
      effect_emit_type: read_string(config, "effect_emit_type", nil),
      effect_payload: read_map(config, "effect_payload"),
      next_wakeup:
        case read_integer(config, "next_wakeup_ms") do
          nil -> :none
          ms -> {:relative, ms}
        end
    }
  end

  @impl true
  def handle_wakeup(state, _context) do
    case state.wakeup_mode do
      "emit" ->
        {:emit, {emit_type(state.wakeup_emit_type), state.wakeup_payload}, state}

      "effect" ->
        {:effect, {effect_kind(state.effect_kind), state.effect_params}, state}

      "continue" ->
        {:continue, %{state | wakeup_mode: "idle"}}

      _ ->
        {:idle, state}
    end
  end

  @impl true
  def handle_effect_result(_effect_result, state, _context) do
    case state.effect_result_mode do
      "emit" ->
        {:emit, {emit_type(state.effect_emit_type), state.effect_payload}, state}

      "effect" ->
        {:effect, {effect_kind(state.effect_kind), state.effect_params}, state}

      _ ->
        {:idle, state}
    end
  end

  @impl true
  def next_wakeup(state), do: state.next_wakeup

  defp emit_type("insights_recorded"), do: :insights_recorded
  defp emit_type("briefs_recorded"), do: :briefs_recorded
  defp emit_type("insight_error"), do: :insight_error
  defp emit_type("brief_error"), do: :brief_error
  defp emit_type(_value), do: :insights_recorded

  defp effect_kind("tool_call"), do: :tool_call
  defp effect_kind(_value), do: :llm_call

  defp read_map(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp read_string(payload, key, default) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp read_integer(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
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
end
