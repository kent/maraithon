defmodule Maraithon.Admin do
  @moduledoc """
  Admin-facing monitoring queries for the dashboard.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.Effects.Effect
  alias Maraithon.Events.Event
  alias Maraithon.Health
  alias Maraithon.LogBuffer
  alias Maraithon.Repo
  alias Maraithon.Runtime.ScheduledJob

  @default_activity_limit 40
  @default_failure_limit 20
  @default_log_limit 200
  @default_effect_limit 20
  @default_job_limit 20
  @default_agent_log_limit 80
  @stale_dispatch_seconds 300

  @doc """
  Returns a full snapshot of admin dashboard monitoring data.
  """
  def dashboard_snapshot(opts \\ []) do
    activity_limit = Keyword.get(opts, :activity_limit, @default_activity_limit)
    failure_limit = Keyword.get(opts, :failure_limit, @default_failure_limit)
    log_limit = Keyword.get(opts, :log_limit, @default_log_limit)

    %{
      health: Health.check(),
      queue_metrics: queue_metrics(),
      recent_activity: recent_activity(activity_limit),
      recent_failures: recent_failures(failure_limit),
      recent_logs: recent_logs(log_limit)
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

  @doc """
  Returns recent raw runtime logs captured from Logger.
  """
  def recent_logs(limit \\ @default_log_limit)
      when is_integer(limit) and limit > 0 do
    LogBuffer.recent(limit)
  end

  @doc """
  Returns an agent-specific operational snapshot for admin inspection.
  """
  def agent_inspection(agent_id, opts \\ []) when is_binary(agent_id) do
    effect_limit = Keyword.get(opts, :effect_limit, @default_effect_limit)
    job_limit = Keyword.get(opts, :job_limit, @default_job_limit)
    log_limit = Keyword.get(opts, :log_limit, @default_agent_log_limit)

    %{
      event_count: count_events(agent_id),
      effect_counts: effect_counts(agent_id),
      recent_effects: recent_effects(agent_id, effect_limit),
      job_counts: job_counts(agent_id),
      recent_jobs: recent_jobs(agent_id, job_limit),
      recent_logs: recent_agent_logs(agent_id, log_limit)
    }
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

  defp count_events(agent_id) do
    Event
    |> where([event], event.agent_id == ^agent_id)
    |> Repo.aggregate(:count)
  end

  defp effect_counts(agent_id) do
    %{
      pending: count_agent_effects(agent_id, "pending"),
      claimed: count_agent_effects(agent_id, "claimed"),
      completed: count_agent_effects(agent_id, "completed"),
      failed: count_agent_effects(agent_id, "failed"),
      cancelled: count_agent_effects(agent_id, "cancelled")
    }
  end

  defp count_agent_effects(agent_id, status) do
    Effect
    |> where([effect], effect.agent_id == ^agent_id and effect.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp recent_effects(agent_id, limit) do
    Effect
    |> where([effect], effect.agent_id == ^agent_id)
    |> order_by([effect], desc: effect.updated_at, desc: effect.inserted_at)
    |> limit(^limit)
    |> select([effect], %{
      id: effect.id,
      effect_type: effect.effect_type,
      status: effect.status,
      attempts: effect.attempts,
      claimed_by: effect.claimed_by,
      retry_after: effect.retry_after,
      params: effect.params,
      result: effect.result,
      error: effect.error,
      inserted_at: effect.inserted_at,
      updated_at: effect.updated_at
    })
    |> Repo.all()
  end

  defp job_counts(agent_id) do
    %{
      pending: count_agent_jobs(agent_id, "pending"),
      dispatched: count_agent_jobs(agent_id, "dispatched"),
      delivered: count_agent_jobs(agent_id, "delivered"),
      cancelled: count_agent_jobs(agent_id, "cancelled")
    }
  end

  defp count_agent_jobs(agent_id, status) do
    ScheduledJob
    |> where([job], job.agent_id == ^agent_id and job.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp recent_jobs(agent_id, limit) do
    ScheduledJob
    |> where([job], job.agent_id == ^agent_id)
    |> order_by([job], desc: job.inserted_at)
    |> limit(^limit)
    |> select([job], %{
      id: job.id,
      job_type: job.job_type,
      status: job.status,
      attempts: job.attempts,
      fire_at: job.fire_at,
      claimed_at: job.claimed_at,
      delivered_at: job.delivered_at,
      payload: job.payload,
      inserted_at: job.inserted_at
    })
    |> Repo.all()
  end

  defp recent_agent_logs(agent_id, limit) do
    limit
    |> recent_logs()
    |> Enum.filter(fn log ->
      case log.metadata do
        %{"agent_id" => ^agent_id} -> true
        _ -> false
      end
    end)
    |> Enum.take(limit)
  end
end
