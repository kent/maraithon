defmodule Maraithon.ChiefOfStaff.Skills.Followthrough do
  @moduledoc """
  Chief of Staff skill that unifies Gmail/Calendar and Slack follow-through.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Behaviors.InboxCalendarAdvisor
  alias Maraithon.Behaviors.SlackFollowthroughAgent
  alias Maraithon.ChiefOfStaff.SourceScope

  @default_email_scan_limit 14
  @default_event_scan_limit 12
  @default_prep_window_hours 36
  @default_channel_scan_limit 80
  @default_dm_scan_limit 50
  @default_lookback_hours 48
  @default_max_insights_per_cycle 5
  @default_min_confidence 0.72

  @impl true
  def id, do: "followthrough"

  @impl true
  def default_config do
    %{
      "email_scan_limit" => @default_email_scan_limit,
      "event_scan_limit" => @default_event_scan_limit,
      "prep_window_hours" => @default_prep_window_hours,
      "channel_scan_limit" => @default_channel_scan_limit,
      "dm_scan_limit" => @default_dm_scan_limit,
      "lookback_hours" => @default_lookback_hours,
      "max_insights_per_cycle" => @default_max_insights_per_cycle,
      "min_confidence" => @default_min_confidence
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider_service,
        provider: "google",
        service: "gmail",
        label: "Google Gmail",
        description: "Needed to inspect recent inbox activity.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Needed to inspect important meetings and infer missing follow-ups.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "slack",
        service: "channels",
        label: "Slack Channels",
        description: "Needed to detect explicit promises and open loops in channel context.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "slack",
        service: "dms",
        label: "Slack Personal DMs",
        description:
          "Needed to detect private reply debt and unresolved commitments in direct messages.",
        required?: true
      },
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Needed for the highest-signal follow-through nudges and summaries.",
        required?: true
      }
    ]
  end

  @impl true
  def subscriptions(config, user_id) when is_binary(user_id) do
    SourceScope.subscriptions(Map.get(config, "source_scope", %{}), user_id)
  end

  def subscriptions(_config, _user_id), do: []

  @impl true
  def init(config) do
    %{
      inbox_state: InboxCalendarAdvisor.init(config),
      slack_state: SlackFollowthroughAgent.init(config),
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
      InboxCalendarAdvisor.next_wakeup(state.inbox_state),
      SlackFollowthroughAgent.next_wakeup(state.slack_state)
    )
  end

  defp continue_with_inbox(state, context) do
    {inbox_outcome, inbox_state} = run_wakeup(InboxCalendarAdvisor, state.inbox_state, context)
    state = %{state | inbox_state: inbox_state}
    finalize_outcome(inbox_outcome, state)
  end

  defp finalize_outcome({:effect, effect}, state), do: {:effect, effect, state}
  defp finalize_outcome(:continue, state), do: {:continue, state}

  defp finalize_outcome(:idle, state) do
    case state.pending_emit do
      nil -> {:idle, state}
      emit -> {:emit, emit, %{state | pending_emit: nil}}
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

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp stringify_keys(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      Map.put(acc, if(is_atom(key), do: Atom.to_string(key), else: key), value)
    end)
  end
end
