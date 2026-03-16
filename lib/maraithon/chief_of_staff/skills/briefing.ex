defmodule Maraithon.ChiefOfStaff.Skills.Briefing do
  @moduledoc """
  Chief of Staff skill adapter for recurring assistant briefs.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Behaviors.ChiefOfStaffBriefAgent

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_end_of_day_hour 18
  @default_weekly_day 5
  @default_weekly_hour 16
  @default_brief_max_items 3

  @impl true
  def id, do: "briefing"

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "morning_brief_hour_local" => @default_morning_hour,
      "end_of_day_brief_hour_local" => @default_end_of_day_hour,
      "weekly_review_day_local" => @default_weekly_day,
      "weekly_review_hour_local" => @default_weekly_hour,
      "brief_max_items" => @default_brief_max_items
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Required to deliver recurring Chief of Staff briefs.",
        required?: true
      }
    ]
  end

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def init(config), do: ChiefOfStaffBriefAgent.init(config)

  @impl true
  def handle_wakeup(state, context), do: ChiefOfStaffBriefAgent.handle_wakeup(state, context)

  @impl true
  def handle_effect_result(effect_result, state, context),
    do: ChiefOfStaffBriefAgent.handle_effect_result(effect_result, state, context)

  @impl true
  def next_wakeup(state), do: ChiefOfStaffBriefAgent.next_wakeup(state)
end
