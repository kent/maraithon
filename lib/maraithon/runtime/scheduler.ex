defmodule Maraithon.Runtime.Scheduler do
  @moduledoc """
  Durable scheduler that persists wakeups to Postgres.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config, as: RuntimeConfig
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

    case %ScheduledJob{} |> ScheduledJob.changeset(attrs) |> Repo.insert() do
      {:ok, job} ->
        Logger.debug("Scheduled #{job_type} for #{agent_id} at #{fire_at}")
        {:ok, job.id}

      {:error, reason} ->
        Logger.error("Failed to schedule job: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Cancel all pending jobs of a type for an agent.
  """
  def cancel(agent_id, job_type) do
    from(j in ScheduledJob,
      where: j.agent_id == ^agent_id,
      where: j.job_type == ^job_type,
      where: j.status in ["pending", "dispatched"]
    )
    |> Repo.update_all(
      set: [status: "cancelled", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
    )
  end

  @doc """
  Mark a dispatched job as delivered after an agent acknowledges receipt.
  """
  def ack_delivered(job_id) do
    now = DateTime.utc_now()

    case Repo.update_all(
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
         ) do
      {1, _} ->
        {:ok, :delivered}

      {0, _} ->
        case Repo.get(ScheduledJob, job_id) do
          nil -> {:error, :not_found}
          %ScheduledJob{status: "delivered"} -> {:ok, :already_delivered}
          _ -> {:error, :invalid_state}
        end
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
       dispatch_timeout_ms: dispatch_timeout_ms
     }}
  end

  @impl true
  def handle_info(:recover_overdue, state) do
    reclaim_stale_dispatched_jobs(state.dispatch_timeout_ms)

    overdue_jobs = fetch_overdue_jobs()
    Logger.info("Recovering #{length(overdue_jobs)} overdue jobs")
    Enum.each(overdue_jobs, &deliver_job/1)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
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

    # Schedule in-memory timers for precise delivery
    in_flight =
      Enum.reduce(jobs, state.in_flight, fn job, acc ->
        unless MapSet.member?(acc, job.id) do
          delay = max(0, DateTime.diff(job.fire_at, now, :millisecond))
          Process.send_after(self(), {:fire, job.id}, delay)
          MapSet.put(acc, job.id)
        else
          acc
        end
      end)

    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | in_flight: in_flight}}
  end

  @impl true
  def handle_info({:fire, job_id}, state) do
    case Repo.get(ScheduledJob, job_id) do
      %ScheduledJob{status: "pending"} = job ->
        deliver_job(job)

      _ ->
        :ok
    end

    {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, job_id)}}
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
