defmodule Maraithon.Insights.Refresh do
  @moduledoc """
  Queues user-scoped insight rebuilds against currently running advisor agents.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Behaviors.AIChiefOfStaff
  alias Maraithon.Behaviors.FounderFollowthroughAgent
  alias Maraithon.Behaviors.GitHubProductPlanner
  alias Maraithon.Behaviors.InboxCalendarAdvisor
  alias Maraithon.Behaviors.SlackFollowthroughAgent
  alias Maraithon.Insights.Insight
  alias Maraithon.Repo
  alias Maraithon.Runtime

  @refresh_message "refresh_insights"
  @open_statuses ["new", "snoozed"]
  @refreshable_behaviors ~w(
    ai_chief_of_staff
    founder_followthrough_agent
    github_product_planner
    inbox_calendar_advisor
    slack_followthrough_agent
  )
  @refreshable_modules [
    AIChiefOfStaff,
    FounderFollowthroughAgent,
    GitHubProductPlanner,
    InboxCalendarAdvisor,
    SlackFollowthroughAgent
  ]

  @spec queue_for_user(String.t(), keyword()) :: {:ok, map()}
  def queue_for_user(user_id, opts \\ []) when is_binary(user_id) do
    runtime_module = Keyword.get(opts, :runtime_module, runtime_module())
    requested_by = normalize_string(Keyword.get(opts, :requested_by)) || "operator"
    reason = normalize_string(Keyword.get(opts, :reason)) || "operator_requested"
    metadata = refresh_metadata(user_id, requested_by, reason)

    eligible_agents =
      Agents.list_agents(user_id: user_id)
      |> Enum.filter(&refreshable_behavior?(&1.behavior))

    {queued, skipped} =
      Enum.reduce(eligible_agents, {[], []}, fn agent, {queued, skipped} ->
        if agent.status in ["running", "degraded"] do
          case runtime_module.send_message(agent.id, @refresh_message, metadata) do
            {:ok, %{message_id: message_id}} ->
              queued_entry = %{
                agent_id: agent.id,
                behavior: agent.behavior,
                status: agent.status,
                message_id: message_id
              }

              {[queued_entry | queued], skipped}

            {:error, reason} ->
              skipped_entry = %{
                agent_id: agent.id,
                behavior: agent.behavior,
                status: agent.status,
                reason: normalize_reason(reason)
              }

              {queued, [skipped_entry | skipped]}
          end
        else
          skipped_entry = %{
            agent_id: agent.id,
            behavior: agent.behavior,
            status: agent.status,
            reason: "agent_not_running"
          }

          {queued, [skipped_entry | skipped]}
        end
      end)

    queued = Enum.reverse(queued)
    skipped = Enum.reverse(skipped)

    {:ok,
     %{
       user_id: user_id,
       eligible_count: length(eligible_agents),
       queued_count: length(queued),
       queued: queued,
       skipped: skipped,
       message: refresh_message_text(user_id, queued, skipped, eligible_agents)
     }}
  end

  @spec refresh_request?(term(), term()) :: boolean()
  def refresh_request?(message, metadata) when is_binary(message) and is_map(metadata) do
    normalize_string(message) == @refresh_message and
      normalize_string(metadata["action"]) == @refresh_message and
      truthy?(metadata["reset_open_insights"])
  end

  def refresh_request?(_message, _metadata), do: false

  @spec reset_open_insights_for_agent(String.t(), Ecto.UUID.t(), term()) :: non_neg_integer()
  def reset_open_insights_for_agent(user_id, agent_id, behavior)
      when is_binary(user_id) and is_binary(agent_id) do
    if refreshable_behavior?(behavior) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {count, _} =
        Insight
        |> where([insight], insight.user_id == ^user_id and insight.agent_id == ^agent_id)
        |> where([insight], insight.status in ^@open_statuses)
        |> Repo.update_all(set: [status: "dismissed", snoozed_until: nil, updated_at: now])

      count
    else
      0
    end
  end

  def reset_open_insights_for_agent(_user_id, _agent_id, _behavior), do: 0

  def refresh_message, do: @refresh_message

  defp runtime_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:runtime_module, Runtime)
  end

  defp refresh_metadata(user_id, requested_by, reason) do
    %{
      "action" => @refresh_message,
      "reset_open_insights" => true,
      "requested_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "requested_by" => requested_by,
      "reason" => reason,
      "target_user_id" => user_id,
      "source" => "admin_insight_refresh"
    }
  end

  defp refresh_message_text(user_id, [], [], []),
    do: "No insight-producing agents found for #{user_id}."

  defp refresh_message_text(_user_id, queued, skipped, _eligible_agents)
       when queued == [] and skipped != [] do
    "No running insight agents accepted the refresh request."
  end

  defp refresh_message_text(_user_id, queued, skipped, _eligible_agents) do
    "Queued insight refresh for #{length(queued)} agent(s); skipped #{length(skipped)}."
  end

  defp refreshable_behavior?(behavior) when is_binary(behavior),
    do: behavior in @refreshable_behaviors

  defp refreshable_behavior?(behavior) when is_atom(behavior),
    do: behavior in @refreshable_modules

  defp refreshable_behavior?(_behavior), do: false

  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
