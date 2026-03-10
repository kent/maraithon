defmodule Maraithon.InsightFeedback do
  @moduledoc """
  Builds LLM-friendly feedback context for personalizing future insights.
  """

  import Ecto.Query

  alias Maraithon.InsightNotifications.{Delivery, ThresholdProfile}
  alias Maraithon.Repo

  @default_recent_limit 8

  def prompt_context(user_id, opts \\ [])

  def prompt_context(user_id, opts) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, @default_recent_limit)

    %{
      threshold_profile: threshold_profile(user_id),
      recent_feedback: recent_feedback(user_id, limit: limit)
    }
  end

  def prompt_context(_user_id, _opts) do
    %{threshold_profile: nil, recent_feedback: []}
  end

  defp threshold_profile(user_id) do
    case Repo.get_by(ThresholdProfile, user_id: user_id) do
      %ThresholdProfile{} = profile ->
        %{
          user_id: profile.user_id,
          score_threshold: profile.score_threshold,
          helpful_count: profile.helpful_count,
          not_helpful_count: profile.not_helpful_count,
          last_feedback_at: profile.last_feedback_at
        }

      nil ->
        nil
    end
  end

  defp recent_feedback(user_id, opts) do
    limit = Keyword.get(opts, :limit, @default_recent_limit)

    Delivery
    |> join(:inner, [d], i in assoc(d, :insight))
    |> where([d, _i], d.user_id == ^user_id and not is_nil(d.feedback))
    |> order_by([d, _i], desc: d.feedback_at, desc: d.updated_at)
    |> limit(^limit)
    |> select([d, i], %{
      feedback: d.feedback,
      feedback_at: d.feedback_at,
      category: i.category,
      source: i.source,
      title: i.title,
      summary: i.summary,
      recommended_action: i.recommended_action,
      priority: i.priority,
      confidence: i.confidence
    })
    |> Repo.all()
  end
end
