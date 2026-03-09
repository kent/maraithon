defmodule Maraithon.Admin do
  @moduledoc """
  Admin-facing monitoring queries for the dashboard.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.Effects.Effect
  alias Maraithon.Events.Event
  alias Maraithon.Health
  alias Maraithon.Repo
  alias Maraithon.Runtime.ScheduledJob

  @default_activity_limit 40
  @default_failure_limit 20
  @stale_dispatch_seconds 300

  @doc """
  Returns a full snapshot of admin dashboard monitoring data.
  """
  def dashboard_snapshot(opts \\ []) do
    activity_limit = Keyword.get(opts, :activity_limit, @default_activity_limit)
    failure_limit = Keyword.get(opts, :failure_limit, @default_failure_limit)

    %{
      health: Health.check(),
      queue_metrics: queue_metrics(),
      recent_activity: recent_activity(activity_limit),
      recent_failures: recent_failures(failure_limit)
    }
  end

  @doc """
  Returns queue and delivery counters for effects and scheduled jobs.
  """
  def queue_metrics do
    %{
      effects: %{
        pending: count_effects_by_status("pending"),
        claimed: count_effects_by_status("claimed"),
        completed: count_effects_by_status("completed"),
        failed: count_effects_by_status("failed")
      },
      jobs: %{
        pending: count_jobs_by_status("pending"),
        dispatched: count_jobs_by_status("dispatched"),
        delivered: count_jobs_by_status("delivered"),
        cancelled: count_jobs_by_status("cancelled")
      }
    }
  end

  @doc """
  Returns the most recent agent events across the system.
  """
  def recent_activity(limit \\ @default_activity_limit)
      when is_integer(limit) and limit > 0 do
    Event
    |> join(:inner, [event], agent in Agent, on: agent.id == event.agent_id)
    |> order_by([event, _agent], desc: event.inserted_at)
    |> limit(^limit)
    |> select([event, agent], %{
      id: event.id,
      inserted_at: event.inserted_at,
      agent_id: event.agent_id,
      behavior: agent.behavior,
      event_type: event.event_type,
      payload: event.payload
    })
    |> Repo.all()
  end

  @doc """
  Returns the most recent operational failures, including failed effects and
  stale dispatched jobs.
  """
  def recent_failures(limit \\ @default_failure_limit)
      when is_integer(limit) and limit > 0 do
    failed_effects = Repo.all(failed_effects_query(limit))
    stale_jobs = Repo.all(stale_jobs_query(limit))

    (failed_effects ++ stale_jobs)
    |> Enum.sort_by(&timestamp_or_epoch/1, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp count_effects_by_status(status) do
    Effect
    |> where([effect], effect.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp count_jobs_by_status(status) do
    ScheduledJob
    |> where([job], job.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp failed_effects_query(limit) do
    Effect
    |> join(:inner, [effect], agent in Agent, on: agent.id == effect.agent_id)
    |> where(
      [effect, _agent],
      effect.status == "failed" or (not is_nil(effect.error) and effect.error != "")
    )
    |> order_by([effect, _agent], desc: effect.updated_at)
    |> limit(^limit)
    |> select([effect, agent], %{
      source: "effect",
      id: effect.id,
      inserted_at: effect.updated_at,
      agent_id: effect.agent_id,
      behavior: agent.behavior,
      status: effect.status,
      type: effect.effect_type,
      attempts: effect.attempts,
      details: effect.error
    })
  end

  defp stale_jobs_query(limit) do
    stale_cutoff = DateTime.add(DateTime.utc_now(), -@stale_dispatch_seconds, :second)

    ScheduledJob
    |> join(:inner, [job], agent in Agent, on: agent.id == job.agent_id)
    |> where(
      [job, _agent],
      job.status == "dispatched" and not is_nil(job.claimed_at) and job.claimed_at < ^stale_cutoff
    )
    |> order_by([job, _agent], asc: job.claimed_at)
    |> limit(^limit)
    |> select([job, agent], %{
      source: "job",
      id: job.id,
      inserted_at: job.claimed_at,
      agent_id: job.agent_id,
      behavior: agent.behavior,
      status: job.status,
      type: job.job_type,
      attempts: job.attempts,
      details: "Job has remained dispatched for over 5 minutes"
    })
  end

  defp timestamp_or_epoch(%{inserted_at: %DateTime{} = inserted_at}), do: inserted_at
  defp timestamp_or_epoch(_), do: DateTime.from_unix!(0)
end
