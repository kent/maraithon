defmodule Maraithon.ChiefOfStaff.Skills.TravelLogistics do
  @moduledoc """
  Chief of Staff skill adapter for the existing travel logistics workflow.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Behaviors.PersonalAssistantAgent
  alias Maraithon.ChiefOfStaff.SourceScope

  @default_email_scan_limit 25
  @default_event_scan_limit 25
  @default_lookback_hours 24 * 30
  @default_min_confidence 0.8
  @default_wakeup_interval_ms :timer.minutes(30)

  @impl true
  def id, do: "travel_logistics"

  @impl true
  def default_config do
    %{
      "email_scan_limit" => @default_email_scan_limit,
      "event_scan_limit" => @default_event_scan_limit,
      "lookback_hours" => @default_lookback_hours,
      "min_confidence" => @default_min_confidence,
      "wakeup_interval_ms" => @default_wakeup_interval_ms
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
        description: "Required to find flight and hotel confirmations.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Required to corroborate trip timing and destination context.",
        required?: true
      },
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Required so Maraithon can deliver the travel brief and any later updates.",
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
  def init(config), do: PersonalAssistantAgent.init(config)

  @impl true
  def handle_wakeup(state, context), do: PersonalAssistantAgent.handle_wakeup(state, context)

  @impl true
  def handle_effect_result(effect_result, state, context),
    do: PersonalAssistantAgent.handle_effect_result(effect_result, state, context)

  @impl true
  def next_wakeup(state), do: PersonalAssistantAgent.next_wakeup(state)
end
