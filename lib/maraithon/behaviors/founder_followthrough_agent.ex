defmodule Maraithon.Behaviors.FounderFollowthroughAgent do
  @moduledoc """
  Unified founder follow-through behavior across Gmail, Calendar, and Slack.

  This behavior composes InboxCalendarAdvisor and SlackFollowthroughAgent so one
  agent can track unresolved commitments across all three sources.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Behaviors.ChiefOfStaffBriefAgent
  alias Maraithon.Behaviors.InboxCalendarAdvisor
  alias Maraithon.Behaviors.SlackFollowthroughAgent

  @impl true
  def init(config) do
    %{
      inbox_state: InboxCalendarAdvisor.init(config),
      slack_state: SlackFollowthroughAgent.init(config),
      brief_state: ChiefOfStaffBriefAgent.init(config),
      pending_emit: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    {slack_outcome, slack_state} = run_wakeup(SlackFollowthroughAgent, state.slack_state, context)

    state =
      %{state | slack_state: slack_state}
      |> stash_emit_from(slack_outcome)

    case slack_outcome do
      {:effect, effect} ->
        {:effect, effect, state}

      :continue ->
        {:continue, state}

      _ ->
        continue_with_inbox(state, context)
    end
  end

  @impl true
  def handle_effect_result(effect_result, state, context) do
    {inbox_outcome, inbox_state} =
      run_effect_result(InboxCalendarAdvisor, effect_result, state.inbox_state, context)

    state = %{state | inbox_state: inbox_state}
    finalize_outcome(inbox_outcome, state)
  end

  @impl true
  def next_wakeup(state) do
    merge_wakeup(
      merge_wakeup(
        InboxCalendarAdvisor.next_wakeup(state.inbox_state),
        SlackFollowthroughAgent.next_wakeup(state.slack_state)
      ),
      ChiefOfStaffBriefAgent.next_wakeup(state.brief_state)
    )
  end

  defp continue_with_inbox(state, context) do
    {inbox_outcome, inbox_state} = run_wakeup(InboxCalendarAdvisor, state.inbox_state, context)
    state = %{state | inbox_state: inbox_state}
    continue_with_brief(inbox_outcome, state, context)
  end

  defp continue_with_brief({:effect, effect}, state, _context), do: {:effect, effect, state}
  defp continue_with_brief(:continue, state, _context), do: {:continue, state}

  defp continue_with_brief(outcome, state, context) do
    state = stash_emit_from(state, outcome)
    {brief_outcome, brief_state} = run_wakeup(ChiefOfStaffBriefAgent, state.brief_state, context)
    state = %{state | brief_state: brief_state}
    finalize_outcome(brief_outcome, state)
  end

  defp finalize_outcome({:effect, effect}, state), do: {:effect, effect, state}
  defp finalize_outcome(:continue, state), do: {:continue, state}

  defp finalize_outcome(:idle, state) do
    case state.pending_emit do
      nil ->
        {:idle, state}

      emit ->
        {:emit, emit, %{state | pending_emit: nil}}
    end
  end

  defp finalize_outcome({:emit, emit}, state) do
    merged_emit = merge_emit(state.pending_emit, emit)
    {:emit, merged_emit, %{state | pending_emit: nil}}
  end

  defp stash_emit_from(state, {:emit, emit}) do
    %{state | pending_emit: merge_emit(state.pending_emit, emit)}
  end

  defp stash_emit_from(state, _outcome), do: state

  defp run_wakeup(module, sub_state, context) do
    case module.handle_wakeup(sub_state, context) do
      {:effect, effect, next_state} -> {{:effect, effect}, next_state}
      {:emit, emit, next_state} -> {{:emit, emit}, next_state}
      {:continue, next_state} -> {:continue, next_state}
      {:idle, next_state} -> {:idle, next_state}
    end
  end

  defp run_effect_result(module, effect_result, sub_state, context) do
    case module.handle_effect_result(effect_result, sub_state, context) do
      {:effect, effect, next_state} -> {{:effect, effect}, next_state}
      {:emit, emit, next_state} -> {{:emit, emit}, next_state}
      {:continue, next_state} -> {:continue, next_state}
      {:idle, next_state} -> {:idle, next_state}
    end
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

  defp merge_emit({:insights_recorded, recorded}, {:insight_error, error}) do
    {:insights_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       "errors",
       payload_list(recorded, :errors) ++
         [
           %{
             "reason" => payload_string(error, :reason),
             "attempted_count" => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:insight_error, error}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:insight_error, error})

  defp merge_emit({:briefs_recorded, left}, {:briefs_recorded, right}) do
    {:briefs_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       cadences: Enum.uniq(payload_list(left, :cadences) ++ payload_list(right, :cadences))
     }}
  end

  defp merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs}) do
    base = preserve_payload_shape(recorded)
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

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_payload, _key), do: nil

  defp payload_int(payload, key, default) do
    case payload_value(payload, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp payload_string(payload, key) do
    case payload_value(payload, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp payload_list(payload, key) do
    case payload_value(payload, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp preserve_payload_shape(map) when is_map(map) do
    if Enum.any?(Map.keys(map), &is_atom/1), do: map, else: stringify_keys(map)
  end

  defp shaped_key(map, key) when is_map(map) do
    if Enum.any?(Map.keys(map), &is_atom/1), do: key, else: Atom.to_string(key)
  end
end
