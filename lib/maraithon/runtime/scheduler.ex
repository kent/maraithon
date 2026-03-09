defmodule Maraithon.Runtime.Scheduler do
  @moduledoc """
  Durable scheduler that persists wakeups to Postgres.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.ScheduledJob

  require Logger

  @default_poll_interval_ms 5_000
  @default_dispatch_timeout_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedule a job to fire after a delay.
  """
  def schedule_in(agent_id, job_type, delay_ms, payload \\ %{}) do
    fire_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    schedule_at(agent_id, job_type, fire_at, payload)
  end

  @doc """
  Schedule a job to fire at a specific time.
  """
  def schedule_at(agent_id, job_type, fire_at, payload \\ %{}) do
    attrs = %{
      agent_id: agent_id,
      job_type: job_type,
      fire_at: fire_at,
      payload: payload,
      status: "pending"
    }

    case DbResilience.with_database("scheduler schedule job", fn ->
           %ScheduledJob{} |> ScheduledJob.changeset(attrs) |> Repo.insert()
         end) do
      {:ok, {:ok, job}} ->
        Logger.debug("Scheduled #{job_type} for #{agent_id} at #{fire_at}")
        {:ok, job.id}

      {:ok, {:error, reason}} ->
        Logger.error("Failed to schedule job: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancel all pending jobs of a type for an agent.
  """
  def cancel(agent_id, job_type) do
    case DbResilience.with_database("scheduler cancel job", fn ->
           from(j in ScheduledJob,
             where: j.agent_id == ^agent_id,
             where: j.job_type == ^job_type,
             where: j.status in ["pending", "dispatched"]
           )
           |> Repo.update_all(
             set: [status: "cancelled", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
           )
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mark a dispatched job as delivered after an agent acknowledges receipt.
  """
  def ack_delivered(job_id) do
    now = DateTime.utc_now()

    case DbResilience.with_database("scheduler ack delivered", fn ->
           Repo.update_all(
             from(j in ScheduledJob,
               where: j.id == ^job_id,
               where: j.status in ["pending", "dispatched"]
             ),
             set: [
               status: "delivered",
               delivered_at: now,
               claimed_by: nil,
               claimed_at: nil,
               dispatched_at: nil
             ]
           )
         end) do
      {:ok, {1, _}} ->
        {:ok, :delivered}

      {:ok, {0, _}} ->
        case DbResilience.with_database("scheduler lookup delivered job", fn ->
               Repo.get(ScheduledJob, job_id)
             end) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, %ScheduledJob{status: "delivered"}} -> {:ok, :already_delivered}
          {:ok, _job} -> {:error, :invalid_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    poll_interval_ms =
      RuntimeConfig.positive_integer(:scheduler_poll_interval_ms, @default_poll_interval_ms)

    dispatch_timeout_ms =
      RuntimeConfig.positive_integer(:scheduler_dispatch_timeout_ms, @default_dispatch_timeout_ms)

    # Recover overdue jobs on startup
    send(self(), :recover_overdue)
    schedule_poll(poll_interval_ms)

    {:ok,
     %{
       in_flight: MapSet.new(),
       poll_interval_ms: poll_interval_ms,
       dispatch_timeout_ms: dispatch_timeout_ms,
       poll_retry_attempts: 0,
       recover_retry_attempts: 0
     }}
  end

  @impl true
  def handle_info(:recover_overdue, state) do
    case DbResilience.with_database("scheduler overdue recovery", fn ->
           reclaim_stale_dispatched_jobs(state.dispatch_timeout_ms)

           overdue_jobs = fetch_overdue_jobs()
           Logger.info("Recovering #{length(overdue_jobs)} overdue jobs")
           Enum.each(overdue_jobs, &deliver_job/1)
         end) do
      {:ok, _} ->
        {:noreply, %{state | recover_retry_attempts: 0}}

      {:error, _reason} ->
        retry_in_ms =
          DbResilience.backoff_ms(state.poll_interval_ms, state.recover_retry_attempts)

        Process.send_after(self(), :recover_overdue, retry_in_ms)
        {:noreply, %{state | recover_retry_attempts: state.recover_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case DbResilience.with_database("scheduler poll", fn ->
           reclaim_stale_dispatched_jobs(state.dispatch_timeout_ms)

           now = DateTime.utc_now()
           horizon = DateTime.add(now, 10_000, :millisecond)

           jobs =
             from(j in ScheduledJob,
               where: j.status == "pending",
               where: j.fire_at <= ^horizon,
               order_by: [asc: j.fire_at],
               limit: 50
             )
             |> Repo.all()

           Enum.reduce(jobs, state.in_flight, fn job, acc ->
             unless MapSet.member?(acc, job.id) do
               delay = max(0, DateTime.diff(job.fire_at, now, :millisecond))
               Process.send_after(self(), {:fire, job.id}, delay)
               MapSet.put(acc, job.id)
             else
               acc
             end
           end)
         end) do
      {:ok, in_flight} ->
        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | in_flight: in_flight, poll_retry_attempts: 0}}

      {:error, _reason} ->
        retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
        schedule_poll(retry_in_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_info({:fire, job_id}, state) do
    case DbResilience.with_database("scheduler fire job", fn ->
           case Repo.get(ScheduledJob, job_id) do
             %ScheduledJob{status: "pending"} = job ->
               deliver_job(job)

             _ ->
               :ok
           end
         end) do
      {:ok, _} ->
        {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, job_id)}}

      {:error, _reason} ->
        Process.send_after(self(), {:fire, job_id}, state.poll_interval_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:clear_in_flight, _from, state) do
    {:reply, :ok, %{state | in_flight: MapSet.new()}}
  end

  # Private functions

  defp deliver_job(job) do
    # Atomically claim for dispatch. Delivery is acknowledged by the agent.
    case Repo.update_all(
           from(j in ScheduledJob,
             where: j.id == ^job.id,
             where: j.status == "pending"
           ),
           set: [
             status: "dispatched",
             claimed_by: to_string(node()),
             claimed_at: DateTime.utc_now(),
             dispatched_at: DateTime.utc_now()
           ],
           inc: [attempts: 1]
         ) do
      {1, _} ->
        send_to_agent(job.agent_id, {:wakeup, job.job_type, job.id, job.payload})

      {0, _} ->
        :ok
    end
  end

  defp send_to_agent(agent_id, message) do
    :ok = Dispatch.dispatch(agent_id, message)
  end

  defp fetch_overdue_jobs do
    from(j in ScheduledJob,
      where: j.status == "pending",
      where: j.fire_at < ^DateTime.utc_now(),
      order_by: [asc: j.fire_at]
    )
    |> Repo.all()
  end

  defp reclaim_stale_dispatched_jobs(timeout_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    {count, _} =
      Repo.update_all(
        from(j in ScheduledJob,
          where: j.status == "dispatched",
          where: j.claimed_at < ^cutoff
        ),
        set: [status: "pending", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
      )

    if count > 0 do
      Logger.info("Reclaimed #{count} stale scheduled jobs")
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
