defmodule Maraithon.Runtime.Scheduler do
  @moduledoc """
  Durable scheduler that persists wakeups to Postgres.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Runtime.ScheduledJob

  require Logger

  @poll_interval_ms 5_000

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
      where: j.status == "pending"
    )
    |> Repo.update_all(set: [status: "cancelled"])
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Recover overdue jobs on startup
    send(self(), :recover_overdue)
    schedule_poll()
    {:ok, %{in_flight: MapSet.new()}}
  end

  @impl true
  def handle_info(:recover_overdue, state) do
    overdue_jobs = fetch_overdue_jobs()
    Logger.info("Recovering #{length(overdue_jobs)} overdue jobs")
    Enum.each(overdue_jobs, &deliver_job/1)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
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

    schedule_poll()
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
    # Atomically mark as delivered
    case Repo.update_all(
           from(j in ScheduledJob,
             where: j.id == ^job.id,
             where: j.status == "pending"
           ),
           set: [status: "delivered", delivered_at: DateTime.utc_now()]
         ) do
      {1, _} ->
        send_to_agent(job.agent_id, {:wakeup, job.job_type, job.id, job.payload})

      {0, _} ->
        :ok
    end
  end

  defp send_to_agent(agent_id, message) do
    case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent_id) do
      [{pid, _}] ->
        send(pid, message)

      [] ->
        Logger.warning("Agent #{agent_id} not running, job will redeliver on resume")
    end
  end

  defp fetch_overdue_jobs do
    from(j in ScheduledJob,
      where: j.status == "pending",
      where: j.fire_at < ^DateTime.utc_now(),
      order_by: [asc: j.fire_at]
    )
    |> Repo.all()
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
