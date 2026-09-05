defmodule Maraithon.Runtime.BackgroundJobRunner do
  @moduledoc """
  Polls and executes app-level background jobs.

  This is intentionally separate from the agent wakeup scheduler and effect
  runner. It handles user-scoped application work that can be retried and
  observed without blocking request-handling processes.

  A claim token fences one execution generation from the next. Fair-lane claims
  additionally take transaction-scoped partition/rate advisory authority, so
  multiple token-aware application nodes can contend safely. Never overlap this
  runner with a legacy revision that mutates jobs by id without claim fencing.

  Orderly shutdown stops tracked handler tasks. An untrappable runner death can
  still leave handler work in flight, so recovery relies on token fencing,
  stale-claim recovery, and idempotent handlers. Claim tokens do not provide
  exactly-once side effects.

  Durable recurring handlers return an internal reschedule instruction. The
  runner atomically moves the exactly claimed row back to `pending` at a
  database-clock deadline instead of completing it and arming a process timer.

  Handlers may return `{:error, {:discard, reason}}` when retrying cannot
  change the outcome. The runner records one terminal failed attempt
  immediately so a dead durable graph cannot block later work until its full
  retry budget expires.

  Fair selection is opt-in for dedicated, homogeneous queues. The generic
  runner intentionally remains non-fair and carries strict Telegram ingress
  ordering; migration 140004 will supply its cross-queue tenant policy.
  Even if fair selection is enabled for ingress, only each bot's active update
  head is eligible and the transactional head check remains authoritative.

  Telegram ordering applies to committed, visible receipt rows. Production also
  enforces Telegram's provider-side `max_connections: 1` contract and a bounded
  ingress grace; a head query alone cannot make claims about an unseen update.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo
  alias Maraithon.DurablePayload
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler
  alias Maraithon.Runtime.BackgroundJobPartition
  alias Maraithon.Runtime.BackgroundJobRateLimit
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.RecurringJobs
  alias Maraithon.Runtime.SourceWatermarkCommit

  alias Maraithon.Runtime.Coordination.{
    Authority,
    FairScheduler,
    Protocol,
    Scope,
    TaskClaims,
    TaskSupervisor
  }

  require Logger

  @default_poll_interval_ms 1_000
  @default_claim_timeout_ms 300_000
  @default_coordination_partition_ttl_ms 30_000
  @default_batch_size 10
  @default_max_concurrency 5
  @default_recurring_reconcile_interval_ms :timer.minutes(1)
  # A `{:retry_after, seconds, reason}` error (e.g. HTTP 429 + Retry-After)
  # reschedules without burning an attempt, so it needs its own ceiling and
  # cap independent of `attempts`/`max_attempts` — otherwise a persistent
  # 429 (or an absurd Retry-After header) reschedules a job forever.
  @max_retry_after_delay_seconds 3_600
  @max_retry_after_reschedules 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def drain_once(server \\ __MODULE__) do
    GenServer.call(server, :drain_once, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    poll_interval_ms =
      Keyword.get(
        opts,
        :poll_interval_ms,
        RuntimeConfig.positive_integer(
          :background_job_poll_interval_ms,
          @default_poll_interval_ms
        )
      )

    claim_timeout_ms =
      Keyword.get(
        opts,
        :claim_timeout_ms,
        RuntimeConfig.positive_integer(
          :background_job_claim_timeout_ms,
          @default_claim_timeout_ms
        )
      )

    batch_size =
      Keyword.get(
        opts,
        :batch_size,
        RuntimeConfig.positive_integer(:background_job_batch_size, @default_batch_size)
      )

    max_concurrency =
      Keyword.get(
        opts,
        :max_concurrency,
        RuntimeConfig.positive_integer(
          :background_job_max_concurrency,
          @default_max_concurrency
        )
      )

    # Coordinated task leases are capped by the owning partition lease, even
    # when the background-job claim timeout is longer. Renew against the
    # shorter authority window so a healthy long-running handler cannot lose
    # its exact task claim before the ordinary job renewal timer fires.
    coordination_partition_ttl_ms =
      RuntimeConfig.positive_integer(
        :coordination_partition_ttl_ms,
        @default_coordination_partition_ttl_ms
      )

    renew_interval_ms =
      claim_timeout_ms
      |> min(coordination_partition_ttl_ms)
      |> renewal_interval_ms()

    default_recurring_reconcile_interval_ms =
      RuntimeConfig.positive_integer(
        :recurring_job_reconcile_interval_ms,
        @default_recurring_reconcile_interval_ms
      )

    recurring_reconcile_interval_ms =
      case Keyword.get(
             opts,
             :recurring_reconcile_interval_ms,
             default_recurring_reconcile_interval_ms
           ) do
        value when is_integer(value) and value > 0 -> value
        _invalid -> default_recurring_reconcile_interval_ms
      end

    queues = normalize_queue_names(Keyword.get(opts, :queues))
    exclude_queues = normalize_queue_names(Keyword.get(opts, :exclude_queues))
    fair? = Keyword.get(opts, :fair?, false) == true

    max_partition_concurrency =
      positive_integer_option(opts, :max_partition_concurrency, 1)

    max_rate_limit_concurrency =
      positive_integer_option(opts, :max_rate_limit_concurrency, max_concurrency)

    schedule_poll(poll_interval_ms)
    renew_timer = schedule_renewal(renew_interval_ms)

    {:ok,
     %{
       running: %{},
       monitors: %{},
       drains: %{},
       poll_interval_ms: poll_interval_ms,
       claim_timeout_ms: claim_timeout_ms,
       renew_interval_ms: renew_interval_ms,
       renew_timer: renew_timer,
       batch_size: batch_size,
       max_concurrency: max_concurrency,
       queues: queues,
       exclude_queues: exclude_queues,
       fair?: fair?,
       max_partition_concurrency: max_partition_concurrency,
       max_rate_limit_concurrency: max_rate_limit_concurrency,
       poll_retry_attempts: 0,
       reconcile_recurring_jobs?:
         Keyword.get(
           opts,
           :reconcile_recurring_jobs?,
           Application.get_env(:maraithon, :start_background_workers, true)
         ),
       recurring_reconcile_interval_ms: recurring_reconcile_interval_ms,
       next_recurring_reconcile_at_ms: nil,
       handler: Keyword.get(opts, :handler, handler_module()),
       renew_job_writer: Keyword.get(opts, :renew_job_writer)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    _ = Process.cancel_timer(state.renew_timer)
    Enum.each(state.running, fn {_key, %{task: task}} -> Process.exit(task.pid, :kill) end)
    Enum.each(state.monitors, fn {ref, _key} -> Process.demonitor(ref, [:flush]) end)
    reply_to_stopped_drains(state.drains)
    :ok
  end

  @impl true
  def handle_info(:poll, state) do
    state = maybe_reconcile_recurring_jobs(state)

    case {Protocol.mode(), EffectProtocol.mode()} do
      {:active, :exact} ->
        poll_coordinated(state)

      {:dark, :legacy} ->
        poll_legacy(state)

      _blocked_or_mismatched ->
        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_info(:renew_claims, state) do
    _ = Process.cancel_timer(state.renew_timer)
    state = renew_running_claims(state)
    renew_timer = schedule_renewal(state.renew_interval_ms)
    {:noreply, %{state | renew_timer: renew_timer}}
  end

  @impl true
  def handle_info({:background_job_done, job_id, claim_token, result}, state) do
    key = {job_id, claim_token}

    case Map.pop(state.running, key) do
      {nil, _running} ->
        {:noreply, state}

      {%{task: %Task{ref: ref}} = entry, running} ->
        Process.demonitor(ref, [:flush])

        state = %{
          state
          | running: running,
            monitors: Map.delete(state.monitors, ref)
        }

        {:noreply, record_drain_result(state, entry, key, result)}
    end
  end

  # Task.Supervisor.async_nolink also sends its ordinary `{ref, result}` reply.
  # The token-keyed completion message or monitor DOWN owns cleanup, so leave
  # monitor bookkeeping intact until one of those arrives.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  # A job task died before reporting back (kill, OOM). Without this, the
  # `running` entry leaked and permanently consumed a concurrency slot or left
  # a deferred drain caller waiting forever.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {key, monitors} ->
        {entry, running} = Map.pop(state.running, key)
        state = %{state | running: running, monitors: monitors}

        if entry do
          {job_id, _claim_token} = key

          result =
            case entry.stop_reason do
              :claim_lost ->
                {:error, :claim_lost}

              nil when reason == :normal ->
                Logger.error("Background job task exited without a result for job #{job_id}")

                if is_nil(entry.coordination),
                  do: release_crashed_job(entry.job, :job_task_result_missing)

                {:error, :job_task_result_missing}

              nil ->
                Logger.error("Background job task crashed for job #{job_id}: #{inspect(reason)}")
                if is_nil(entry.coordination), do: release_crashed_job(entry.job, reason)
                {:error, {:job_task_crashed, reason}}
            end

          {:noreply, record_drain_result(state, entry, key, result)}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("BackgroundJobRunner ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(
        {:background_job_finishing, job_id, claim_token},
        {task_pid, _tag},
        state
      ) do
    key = {job_id, claim_token}

    case Map.get(state.running, key) do
      %{task: %Task{pid: ^task_pid}, stop_reason: nil} = entry ->
        running = Map.put(state.running, key, %{entry | phase: :finishing})
        {:reply, :ok, %{state | running: running}}

      _entry ->
        {:reply, :claim_lost, state}
    end
  end

  @impl true
  def handle_call(:clear_running, _from, state) do
    Enum.each(state.running, fn {_key, %{task: task}} -> Process.exit(task.pid, :kill) end)
    Enum.each(state.monitors, fn {ref, _key} -> Process.demonitor(ref, [:flush]) end)
    reply_to_cleared_drains(state.drains)
    {:reply, :ok, %{state | running: %{}, monitors: %{}, drains: %{}}}
  end

  @impl true
  def handle_call(:drain_once, from, state) do
    available_slots = max(state.max_concurrency - map_size(state.running), 0)

    if available_slots == 0 do
      {:reply, {:ok, []}, state}
    else
      limit = min(max(state.batch_size, 1), available_slots)

      case {Protocol.mode(), EffectProtocol.mode()} do
        {:active, :exact} -> start_coordinated_drain(from, state, limit)
        {:dark, :legacy} -> start_drain(from, state, limit)
        _blocked_or_mismatched -> {:reply, {:error, :runtime_authority_not_ready}, state}
      end
    end
  end

  defp start_coordinated_drain(from, state, limit) do
    with {:ok, session} <- Scope.current(),
         partitions <- Authority.owned_partitions(session, ["ready"]),
         {:ok, reservations} <-
           coordinated_reservations(
             session,
             partitions,
             limit,
             state.claim_timeout_ms,
             state
           ) do
      if reservations == [] do
        {:reply, {:ok, []}, state}
      else
        drain_id = make_ref()

        drain = %{
          from: from,
          order: Enum.map(reservations, fn {job, _, _} -> job.id end),
          pending: MapSet.new(),
          results: %{}
        }

        {state, drain} =
          Enum.reduce(reservations, {state, drain}, fn {job, assignment, identity}, {acc, d} ->
            key = claim_key(job)

            {start_tracked_job(acc, job, drain_id, %{assignment: assignment, identity: identity}),
             %{d | pending: MapSet.put(d.pending, key)}}
          end)

        {:noreply, %{state | drains: Map.put(state.drains, drain_id, drain)}}
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp poll_legacy(state) do
    available_slots = max(state.max_concurrency - map_size(state.running), 0)

    if available_slots == 0 do
      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    else
      limit = min(state.batch_size, available_slots)

      case DbResilience.with_database("background job runner poll", fn ->
             reclaim_stale_jobs(state.claim_timeout_ms, state)
             fetch_pending_jobs(limit, state)
           end) do
        {:ok, jobs} ->
          state =
            Enum.reduce(jobs, state, fn job, acc ->
              case claim_job(job, acc) do
                {:ok, claimed} -> start_tracked_job(acc, claimed, nil)
                :already_claimed -> acc
                {:error, _reason} -> acc
              end
            end)

          schedule_poll(state.poll_interval_ms)
          {:noreply, %{state | poll_retry_attempts: 0}}

        {:error, _reason} ->
          retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
          schedule_poll(retry_in_ms)
          {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
      end
    end
  end

  defp poll_coordinated(state) do
    available_slots = max(state.max_concurrency - map_size(state.running), 0)

    result =
      with true <- available_slots > 0,
           {:ok, session} <- Scope.current() do
        partitions = Authority.owned_partitions(session, ["ready"])

        coordinated_reservations(
          session,
          partitions,
          min(state.batch_size, available_slots),
          state.claim_timeout_ms,
          state
        )
      else
        false -> {:ok, []}
        error -> error
      end

    case result do
      {:ok, reservations} ->
        state =
          Enum.reduce(reservations, state, fn {job, assignment, identity}, acc ->
            start_tracked_job(acc, job, nil, %{assignment: assignment, identity: identity})
          end)

        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | poll_retry_attempts: 0}}

      _ ->
        retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
        schedule_poll(retry_in_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  defp coordinated_reservations(session, partitions, limit, ttl_ms, state) do
    Enum.reduce_while(1..limit, {:ok, []}, fn _, {:ok, acc} ->
      case FairScheduler.reserve_next(session, partitions,
             task_ttl_ms: ttl_ms,
             queues: state.queues,
             exclude_queues: state.exclude_queues
           ) do
        {:ok, nil} -> {:halt, {:ok, Enum.reverse(acc)}}
        {:ok, reservation} -> {:cont, {:ok, [reservation | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp start_drain(from, state, limit) do
    case DbResilience.with_database("background job runner drain once", fn ->
           reclaim_stale_jobs(state.claim_timeout_ms, state)
           fetch_pending_jobs(limit, state)
         end) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, []} ->
        {:reply, {:ok, []}, state}

      {:ok, jobs} ->
        drain_id = make_ref()

        drain = %{
          from: from,
          order: Enum.map(jobs, & &1.id),
          pending: MapSet.new(),
          results: %{}
        }

        {state, drain} =
          Enum.reduce(jobs, {state, drain}, fn job, {acc_state, acc_drain} ->
            case claim_job(job, acc_state) do
              {:ok, claimed} ->
                key = claim_key(claimed)

                {
                  start_tracked_job(acc_state, claimed, drain_id),
                  %{acc_drain | pending: MapSet.put(acc_drain.pending, key)}
                }

              other ->
                {acc_state, put_in(acc_drain.results[job.id], other)}
            end
          end)

        if MapSet.size(drain.pending) == 0 do
          {:reply, drain_reply(drain), state}
        else
          {:noreply, %{state | drains: Map.put(state.drains, drain_id, drain)}}
        end
    end
  end

  defp start_tracked_job(state, %BackgroundJob{} = job, drain_id, coordination \\ nil) do
    task = execute_job_async(job, state.handler, coordination)
    key = claim_key(job)

    entry = %{
      job: job,
      task: task,
      drain_id: drain_id,
      phase: :executing,
      stop_reason: nil,
      coordination: coordination
    }

    %{
      state
      | running: Map.put(state.running, key, entry),
        monitors: Map.put(state.monitors, task.ref, key)
    }
  end

  defp record_drain_result(state, %{drain_id: nil}, _key, _result), do: state

  defp record_drain_result(state, %{drain_id: drain_id}, {job_id, _token} = key, result) do
    case Map.fetch(state.drains, drain_id) do
      :error ->
        state

      {:ok, drain} ->
        drain = %{
          drain
          | pending: MapSet.delete(drain.pending, key),
            results: Map.put(drain.results, job_id, result)
        }

        if MapSet.size(drain.pending) == 0 do
          GenServer.reply(drain.from, drain_reply(drain))
          %{state | drains: Map.delete(state.drains, drain_id)}
        else
          %{state | drains: Map.put(state.drains, drain_id, drain)}
        end
    end
  end

  defp drain_reply(drain) do
    {:ok, Enum.map(drain.order, &{&1, Map.fetch!(drain.results, &1)})}
  end

  defp reply_to_cleared_drains(drains) do
    Enum.each(drains, fn {_drain_id, drain} ->
      results =
        Enum.reduce(drain.pending, drain.results, fn {job_id, _token}, acc ->
          Map.put(acc, job_id, {:error, :runner_cleared})
        end)

      GenServer.reply(drain.from, drain_reply(%{drain | results: results}))
    end)
  end

  defp reply_to_stopped_drains(drains) do
    Enum.each(drains, fn {_drain_id, drain} ->
      GenServer.reply(drain.from, {:error, :runner_stopped})
    end)
  end

  defp renew_running_claims(state) do
    Enum.reduce(state.running, state, fn {key, entry}, acc ->
      if entry.stop_reason == :claim_lost do
        acc
      else
        case renew_claim(
               entry.job,
               entry.coordination,
               state.claim_timeout_ms,
               state.renew_job_writer
             ) do
          :ok ->
            acc

          # A finishing task has no handler side effects left to stop. Its
          # terminal write is token-fenced, and a zero-row renewal can simply
          # mean that write committed before its done message reached us. If
          # ownership was replaced instead, the persistence classifier reports
          # its zero-row terminal CAS as `{:error, :claim_lost}`.
          :lost when entry.phase == :finishing ->
            acc

          :lost ->
            Logger.warning("Stopping background job task after claim ownership loss",
              background_job_id: entry.job.id
            )

            running = Map.put(acc.running, key, %{entry | stop_reason: :claim_lost})
            Process.exit(entry.task.pid, :kill)
            %{acc | running: running}

          {:error, reason} ->
            Logger.warning("Stopping background job task after uncertain claim renewal",
              background_job_id: entry.job.id,
              reason: inspect(reason)
            )

            running = Map.put(acc.running, key, %{entry | stop_reason: :claim_lost})
            Process.exit(entry.task.pid, :kill)
            %{acc | running: running}
        end
      end
    end)
  end

  defp renew_claim(%BackgroundJob{} = job, coordination, ttl_ms, renew_job_writer) do
    result =
      DbResilience.with_database("background job runner renew claim", fn ->
        Repo.transaction(fn ->
          if coordination do
            case TaskClaims.renew(coordination.assignment, ttl_ms) do
              {:ok, _renewed} -> :ok
              _ -> Repo.rollback(:task_authority_lost)
            end
          end

          now = database_now!()

          renewal_result =
            if is_function(renew_job_writer, 2),
              do: renew_job_writer.(job, now),
              else: renew_job_claim(job, now)

          case renewal_result do
            {1, _rows} -> :renewed
            {0, _rows} -> Repo.rollback(:claim_lost)
          end
        end)
      end)

    case result do
      {:ok, {:ok, :renewed}} -> :ok
      {:ok, {:error, :claim_lost}} -> :lost
      {:ok, {:error, :task_authority_lost}} -> :lost
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_job_claim(%BackgroundJob{} = job, now) do
    private_update_all(renewable_claim(job), set: [claimed_at: now, updated_at: now])
  end

  defp fetch_pending_jobs(limit, %{fair?: true} = state) do
    include_queues? = state.queues != []
    exclude_queues? = state.exclude_queues != []

    ids =
      Repo.query!(
        """
        WITH partition_heads AS (
          SELECT job.id,
                 job.queue,
                 job.rate_limit_key,
                 job.scheduled_at,
                 job.inserted_at,
                 partition.last_started_at,
                 row_number() OVER (
                   PARTITION BY job.queue, COALESCE(job.partition_key, job.id::text)
                   ORDER BY job.scheduled_at, job.inserted_at, job.id
                 ) AS partition_rank
          FROM background_jobs AS job
          LEFT JOIN background_job_partitions AS partition
            ON partition.queue = job.queue
           AND partition.partition_key = job.partition_key
          LEFT JOIN background_job_rate_limits AS rate_limit
            ON rate_limit.queue = job.queue
           AND rate_limit.rate_limit_key = job.rate_limit_key
          WHERE job.status = 'pending'
            AND job.scheduled_at <= timezone('UTC', clock_timestamp())
            AND ($1::boolean = false OR job.queue = ANY($2::text[]))
            AND ($3::boolean = false OR NOT (job.queue = ANY($4::text[])))
            AND (
              job.partition_key IS NULL OR NOT EXISTS (
                SELECT 1
                FROM background_jobs AS running
                WHERE running.queue = job.queue
                  AND running.partition_key = job.partition_key
                  AND running.status = 'running'
              )
            )
            AND (
              job.rate_limit_key IS NULL OR
              rate_limit.blocked_until IS NULL OR
              rate_limit.blocked_until <= timezone('UTC', clock_timestamp())
            )
            AND (
              job.job_type != 'telegram_webhook_event' OR
              job.id = (
                SELECT head.id
                FROM background_jobs AS head
                WHERE head.job_type = 'telegram_webhook_event'
                  AND head.telegram_bot_id = job.telegram_bot_id
                  AND head.status IN ('pending', 'running')
                ORDER BY (head.status = 'running') DESC,
                         head.telegram_update_id ASC
                LIMIT 1
              )
            )
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (
                   PARTITION BY queue, COALESCE(rate_limit_key, id::text)
                   ORDER BY last_started_at ASC NULLS FIRST,
                            scheduled_at,
                            inserted_at,
                            id
                 ) AS rate_rank
          FROM partition_heads
          WHERE partition_rank = 1
        )
        SELECT id::text
        FROM ranked
        ORDER BY rate_rank ASC,
                 last_started_at ASC NULLS FIRST,
                 scheduled_at ASC,
                 inserted_at ASC,
                 id ASC
        LIMIT $5
        """,
        [
          include_queues?,
          state.queues,
          exclude_queues?,
          state.exclude_queues,
          limit
        ],
        log: false
      ).rows
      |> Enum.map(fn [id] -> id end)

    jobs_by_id =
      BackgroundJob
      |> where([job], job.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.fetch(jobs_by_id, id) do
        {:ok, job} -> [job]
        :error -> []
      end
    end)
  end

  defp fetch_pending_jobs(limit, state) do
    ordered_head_id =
      from(head in BackgroundJob,
        where: head.job_type == "telegram_webhook_event",
        where: head.telegram_bot_id == parent_as(:candidate).telegram_bot_id,
        where: head.status in ["pending", "running"],
        order_by: [
          desc: fragment("? = 'running'", head.status),
          asc: head.telegram_update_id
        ],
        select: head.id,
        limit: 1
      )

    BackgroundJob
    |> from(as: :candidate)
    |> where([candidate], candidate.status == "pending")
    |> where(
      [candidate],
      candidate.scheduled_at <= fragment("timezone('UTC', clock_timestamp())")
    )
    |> where(
      [candidate],
      candidate.job_type != "telegram_webhook_event" or
        candidate.id == subquery(ordered_head_id)
    )
    |> filter_runner_queues(state)
    |> order_by([candidate], asc: candidate.scheduled_at, asc: candidate.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&BackgroundJob.hydrate_payloads/1)
  end

  defp claim_job(%BackgroundJob{job_type: "telegram_webhook_event"} = job, _state),
    do: claim_ordered_telegram_job(job)

  defp claim_job(%BackgroundJob{} = job, state), do: claim_unordered_job(job, state)

  defp claim_unordered_job(%BackgroundJob{} = job, state) do
    claim_with_transaction("background job runner claim job", fn ->
      with :ok <- take_execution_authority(job),
           :ok <- ensure_partition_capacity(job, state),
           :ok <- ensure_rate_limit_capacity(job, state) do
        claimed = claim_pending_job(job, require_due?: true)
        record_partition_start(claimed)
        claimed
      else
        :unavailable -> Repo.rollback(:already_claimed)
      end
    end)
  end

  defp claim_ordered_telegram_job(%BackgroundJob{telegram_bot_id: bot_id} = job)
       when is_binary(bot_id) and bot_id != "" do
    claim_with_transaction("background job runner claim ordered Telegram job", fn ->
      with true <- take_telegram_order_lock(bot_id),
           %BackgroundJob{id: head_id, status: "pending"} when head_id == job.id <-
             lock_telegram_head(bot_id) do
        claim_pending_job(job, require_due?: true)
      else
        _not_current_claimable_head -> Repo.rollback(:already_claimed)
      end
    end)
  end

  defp claim_ordered_telegram_job(%BackgroundJob{}), do: :already_claimed

  defp claim_with_transaction(operation, transaction_fun) do
    case DbResilience.with_database(operation, fn -> Repo.transaction(transaction_fun) end) do
      {:ok, {:ok, %BackgroundJob{} = claimed}} -> {:ok, claimed}
      {:ok, {:error, :already_claimed}} -> :already_claimed
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_pending_job(%BackgroundJob{} = job, opts) do
    node_id = node() |> to_string()
    claim_token = Ecto.UUID.generate()
    now = database_now!()

    claim_query =
      from(candidate in BackgroundJob,
        where: candidate.id == ^job.id,
        where: candidate.status == "pending"
      )

    claim_query =
      if Keyword.get(opts, :require_due?, false) do
        where(
          claim_query,
          [candidate],
          candidate.scheduled_at <= fragment("timezone('UTC', clock_timestamp())")
        )
      else
        claim_query
      end

    # A pending row can retain a token after a rollback or legacy transition.
    # The status CAS atomically replaces that stale generation with a fresh UUID.
    case private_update_all(claim_query,
           set: [
             status: "running",
             claimed_by: node_id,
             claimed_at: now,
             claim_token: claim_token,
             updated_at: now
           ]
         ) do
      {1, _rows} ->
        Repo.one!(
          from(candidate in BackgroundJob,
            where: candidate.id == ^job.id,
            where: candidate.status == "running",
            where: candidate.claim_token == ^claim_token
          )
        )
        |> BackgroundJob.hydrate_payloads()

      {0, _rows} ->
        Repo.rollback(:already_claimed)
    end
  end

  defp take_execution_authority(%BackgroundJob{} = job) do
    keys =
      [
        execution_lock_key("partition", job.queue, job.partition_key),
        execution_lock_key("rate", job.queue, job.rate_limit_key)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    if Enum.all?(keys, &take_execution_lock/1), do: :ok, else: :unavailable
  end

  defp execution_lock_key(_kind, _queue, nil), do: nil

  defp execution_lock_key(kind, queue, key)
       when is_binary(kind) and is_binary(queue) and is_binary(key),
       do: "maraithon:background-job:#{kind}:#{queue}:#{key}"

  defp take_execution_lock(key) do
    case Repo.query!(
           "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
           [key],
           log: false
         ).rows do
      [[true]] -> true
      _unavailable -> false
    end
  end

  defp ensure_partition_capacity(%BackgroundJob{partition_key: nil}, _state), do: :ok

  defp ensure_partition_capacity(%BackgroundJob{} = job, state) do
    running =
      Repo.aggregate(
        from(candidate in BackgroundJob,
          where: candidate.queue == ^job.queue,
          where: candidate.partition_key == ^job.partition_key,
          where: candidate.status == "running"
        ),
        :count
      )

    if running < state.max_partition_concurrency, do: :ok, else: :unavailable
  end

  defp ensure_rate_limit_capacity(%BackgroundJob{rate_limit_key: nil}, _state), do: :ok

  defp ensure_rate_limit_capacity(%BackgroundJob{} = job, state) do
    now = database_now!()

    blocked? =
      BackgroundJobRateLimit
      |> where([limit], limit.queue == ^job.queue)
      |> where([limit], limit.rate_limit_key == ^job.rate_limit_key)
      |> where([limit], not is_nil(limit.blocked_until) and limit.blocked_until > ^now)
      |> Repo.exists?()

    running =
      Repo.aggregate(
        from(candidate in BackgroundJob,
          where: candidate.queue == ^job.queue,
          where: candidate.rate_limit_key == ^job.rate_limit_key,
          where: candidate.status == "running"
        ),
        :count
      )

    if not blocked? and running < state.max_rate_limit_concurrency,
      do: :ok,
      else: :unavailable
  end

  defp record_partition_start(%BackgroundJob{partition_key: nil}), do: :ok

  defp record_partition_start(%BackgroundJob{} = job) do
    now = database_now!()

    Repo.insert_all(
      BackgroundJobPartition,
      [
        %{
          queue: job.queue,
          partition_key: job.partition_key,
          last_started_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [set: [last_started_at: now, updated_at: now]],
      conflict_target: [:queue, :partition_key]
    )

    :ok
  end

  defp take_telegram_order_lock(bot_id) do
    case Repo.query!(
           """
           SELECT pg_try_advisory_xact_lock(
             hashtextextended('maraithon:telegram-webhook:' || $1, 0)
           )
           """,
           [bot_id],
           log: false
         ).rows do
      [[true]] -> true
      _lock_unavailable -> false
    end
  end

  defp lock_telegram_head(bot_id) do
    BackgroundJob
    |> where([head], head.job_type == "telegram_webhook_event")
    |> where([head], head.telegram_bot_id == ^bot_id)
    |> where([head], head.status in ["pending", "running"])
    |> order_by([head],
      desc: fragment("? = 'running'", head.status),
      asc: head.telegram_update_id
    )
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp execute_job_async(%BackgroundJob{} = job, handler, nil) do
    parent = self()

    Task.Supervisor.async_nolink(Maraithon.Runtime.BackgroundJobTaskSupervisor, fn ->
      finish_executed_job(parent, job, execute_handler(job, handler), nil)
    end)
  end

  defp execute_job_async(%BackgroundJob{} = job, handler, %{
         assignment: assignment,
         identity: identity
       }) do
    parent = self()
    gate = make_ref()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        receive do
          {:activate_background_job, ^gate} -> :ok
        after
          5_000 -> exit(:background_job_bind_timeout)
        end

        :ok = TaskSupervisor.register_current!(identity)

        case FairScheduler.activate_job(job, assignment) do
          {:ok, {active_job, active_assignment}} ->
            case TaskClaims.mark_provider_entered(active_assignment) do
              {:ok, entered_assignment} ->
                finish_executed_job(
                  parent,
                  active_job,
                  execute_handler(active_job, handler),
                  entered_assignment
                )

              {:error, _authority_lost} ->
                report_coordinated_start_loss(parent, job)
            end

          {:error, _authority_lost} ->
            report_coordinated_start_loss(parent, job)
        end
      end)

    case TaskSupervisor.bind_task(identity, task.pid) do
      :ok ->
        send(task.pid, {:activate_background_job, gate})
        task

      {:error, _reason} ->
        _ = Task.Supervisor.terminate_child(TaskSupervisor.task_supervisor(), task.pid)
        task
    end
  end

  defp finish_executed_job(parent, job, result, assignment) do
    case GenServer.call(parent, {:background_job_finishing, job.id, job.claim_token}, :infinity) do
      :ok ->
        outcome =
          if assignment,
            do: persist_coordinated_job_result(job, assignment, result),
            else: persist_job_result(job, result)

        send(parent, {:background_job_done, job.id, job.claim_token, outcome})

      :claim_lost ->
        :ok
    end

    :ok
  end

  defp report_coordinated_start_loss(parent, job) do
    send(parent, {:background_job_done, job.id, job.claim_token, {:error, :claim_lost}})
    :ok
  end

  defp persist_coordinated_job_result(job, assignment, handler_result) do
    outcome = coordinated_outcome(job, handler_result)

    case Repo.transaction(fn ->
           _settled = TaskClaims.settle_in_transaction(assignment, outcome)

           with {:ok, committed_handler_result} <-
                  SourceWatermarkCommit.commit_and_sanitize(job, handler_result) do
             case persist_job_result(job, committed_handler_result) do
               {:error, reason} when reason in [:claim_lost, :persistence_deferred] ->
                 Repo.rollback(reason)

               result ->
                 result
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp coordinated_outcome(_job, {:ok, _, {:reschedule_in, delay_ms}})
       when is_integer(delay_ms) and delay_ms > 0,
       do: "retry_scheduled"

  defp coordinated_outcome(_job, {:ok, _, {:reschedule_at, %DateTime{}}}),
    do: "retry_scheduled"

  defp coordinated_outcome(_job, {:ok, _}), do: "completed"

  defp coordinated_outcome(_job, {:error, {:discard, _reason}}), do: "failed"

  defp coordinated_outcome(job, {:error, {:retry_after, seconds, _}})
       when is_integer(seconds) and seconds >= 0 do
    if retry_after_count(job) + 1 > @max_retry_after_reschedules and
         job.attempts + 1 >= job.max_attempts,
       do: "failed",
       else: "retry_scheduled"
  end

  defp coordinated_outcome(job, {:error, _}) do
    if job.attempts + 1 < job.max_attempts, do: "retry_scheduled", else: "failed"
  end

  defp release_crashed_job(%BackgroundJob{} = job, reason) do
    attempts = job.attempts + 1
    error = {:job_task_crashed, reason}

    if attempts < job.max_attempts do
      mark_pending_retry(job, error, attempts)
    else
      mark_failed(job, error, attempts)
    end
  end

  defp execute_handler(%BackgroundJob{} = job, handler) do
    Logger.info("Executing background job",
      background_job_id: job.id,
      queue: job.queue,
      job_type: job.job_type,
      user_id: job.user_id
    )

    safe_execute(handler, job)
  end

  defp persist_job_result(%BackgroundJob{} = job, handler_result) do
    transition_result =
      if SourceWatermarkCommit.deferred?(handler_result) do
        {:error, :deferred_source_watermark_requires_coordinated_settlement}
      else
        case handler_result do
          {:ok, data, {:reschedule_in, delay_ms}}
          when is_integer(delay_ms) and delay_ms > 0 ->
            mark_rescheduled(job, data, delay_ms)

          {:ok, data, {:reschedule_at, %DateTime{} = scheduled_at}} ->
            mark_rescheduled_at(job, data, scheduled_at)

          {:ok, data} ->
            mark_completed(job, data)

          {:error, {:discard, reason}} ->
            mark_failed(job, reason, job.attempts + 1)

          {:error, {:retry_after, seconds, reason}} when is_integer(seconds) and seconds >= 0 ->
            # Provider-signaled backoff (e.g. HTTP 429 + Retry-After): reschedule
            # at the requested delay without burning an attempt.
            handle_retry_after(job, seconds, reason)

          {:error, reason} ->
            persist_failure(job, reason)
        end
      end

    classify_persistence_result(job, handler_result, transition_result)
  end

  defp classify_persistence_result(_job, handler_result, {:ok, {1, _rows}}),
    do: handler_result

  defp classify_persistence_result(_job, _handler_result, {:ok, {0, _rows}}),
    do: {:error, :claim_lost}

  defp classify_persistence_result(job, _handler_result, {:error, _reason}) do
    Logger.warning("Background job result persistence deferred",
      background_job_id: job.id
    )

    {:error, :persistence_deferred}
  end

  defp classify_persistence_result(job, _handler_result, _unexpected) do
    Logger.error("Background job result persistence returned an unexpected outcome",
      background_job_id: job.id
    )

    {:error, :persistence_deferred}
  end

  defp persist_failure(%BackgroundJob{} = job, reason) do
    attempts = job.attempts + 1

    if attempts < job.max_attempts do
      mark_pending_retry(job, reason, attempts)
    else
      mark_failed(job, reason, attempts)
    end
  end

  defp mark_rescheduled(%BackgroundJob{} = job, result, delay_ms) do
    DbResilience.with_database("background job runner self-reschedule", fn ->
      now = database_now!()
      scheduled_at = DateTime.add(now, delay_ms, :millisecond)
      reschedule_claim(job, result, scheduled_at, now)
    end)
  end

  defp mark_rescheduled_at(%BackgroundJob{} = job, result, %DateTime{} = scheduled_at) do
    DbResilience.with_database("background job runner wall-clock reschedule", fn ->
      now = database_now!()

      if DateTime.compare(scheduled_at, now) == :gt do
        reschedule_claim(job, result, scheduled_at, now)
      else
        reject_non_future_reschedule(job, now)
      end
    end)
  end

  defp reject_non_future_reschedule(%BackgroundJob{} = job, now) do
    attempts = job.attempts + 1
    reason = :reschedule_at_not_future

    Logger.warning("Rejected non-future background job wall-clock deadline",
      background_job_id: job.id,
      job_type: job.job_type
    )

    if attempts < job.max_attempts do
      retry_at = DateTime.add(now, calculate_backoff(attempts), :millisecond)

      Repo.update_all(
        owned_claim(job),
        set: [
          status: "pending",
          attempts: attempts,
          scheduled_at: retry_at,
          claimed_by: nil,
          claimed_at: nil,
          claim_token: nil,
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    else
      Repo.update_all(
        owned_claim(job),
        set: [
          status: "failed",
          attempts: attempts,
          payload: terminal_payload(job),
          failed_at: now,
          claimed_by: nil,
          claimed_at: nil,
          claim_token: nil,
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    end
  end

  defp reschedule_claim(job, result, scheduled_at, now) do
    durable_result = normalize_result(result)

    private_update_all(
      owned_claim(job),
      set:
        [
          status: "pending",
          attempts: 0,
          scheduled_at: scheduled_at,
          claimed_by: nil,
          claimed_at: nil,
          claim_token: nil,
          last_error: nil,
          updated_at: now
        ] ++ result_payload_updates(job, durable_result)
    )
  end

  defp mark_completed(%BackgroundJob{} = job, result) do
    DbResilience.with_database("background job runner mark completed", fn ->
      now = database_now!()

      durable_result = normalize_result(result)
      durable_payload = completed_payload(job)

      private_update_all(
        owned_claim(job),
        set:
          [
            status: "completed",
            completed_at: now,
            claimed_by: nil,
            claimed_at: nil,
            claim_token: nil,
            last_error: nil,
            updated_at: now
          ] ++ payload_and_result_updates(job, durable_payload, durable_result)
      )
    end)
  end

  defp completed_payload(%BackgroundJob{job_type: job_type})
       when job_type in ["telegram_webhook_event", "privacy_erasure"],
       do: %{}

  defp completed_payload(%BackgroundJob{payload: payload}), do: payload || %{}

  # Clamps the provider-requested delay to `@max_retry_after_delay_seconds`
  # and counts the reschedule against `@max_retry_after_reschedules`
  # (tracked in `job.result["retry_after_count"]`, since `attempts` is
  # deliberately not burned for this path). Once a job has rescheduled on
  # `:retry_after` this many times without making progress, fall through to
  # the ordinary attempt/backoff machinery so it eventually fails out rather
  # than rescheduling forever.
  defp handle_retry_after(%BackgroundJob{} = job, seconds, reason) do
    retry_after_count = retry_after_count(job) + 1

    if retry_after_count > @max_retry_after_reschedules do
      attempts = job.attempts + 1

      if attempts < job.max_attempts do
        mark_pending_retry(job, reason, attempts)
      else
        mark_failed(job, reason, attempts)
      end
    else
      clamped_seconds = min(seconds, @max_retry_after_delay_seconds)
      mark_pending_rate_limited_retry(job, reason, clamped_seconds, retry_after_count)
    end
  end

  defp retry_after_count(%BackgroundJob{result: %{"retry_after_count" => count}})
       when is_integer(count) do
    count
  end

  defp retry_after_count(_job), do: 0

  defp mark_pending_rate_limited_retry(
         %BackgroundJob{} = job,
         reason,
         retry_after_seconds,
         retry_after_count
       )
       when is_integer(retry_after_seconds) and retry_after_seconds >= 0 do
    DbResilience.with_database("background job runner mark rate-limited retry", fn ->
      {:ok, transition} =
        Repo.transaction(fn ->
          now = database_now!()
          retry_at = DateTime.add(now, retry_after_seconds, :second)

          durable_result =
            job.result
            |> Kernel.||(%{})
            |> Map.put("retry_after_count", retry_after_count)

          transition =
            private_update_all(
              owned_claim(job),
              set:
                [
                  status: "pending",
                  scheduled_at: retry_at,
                  claimed_by: nil,
                  claimed_at: nil,
                  claim_token: nil,
                  last_error: error_text(reason),
                  updated_at: now
                ] ++ result_payload_updates(job, durable_result)
            )

          case transition do
            {1, _rows} -> block_rate_limit(job, retry_at, now)
            {0, _rows} -> :ok
          end

          transition
        end)

      transition
    end)
  end

  defp block_rate_limit(%BackgroundJob{rate_limit_key: nil}, _retry_at, _now), do: :ok

  defp block_rate_limit(%BackgroundJob{} = job, retry_at, now) do
    Repo.query!(
      """
      INSERT INTO background_job_rate_limits
        (queue, rate_limit_key, blocked_until, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4)
      ON CONFLICT (queue, rate_limit_key) DO UPDATE
      SET blocked_until = GREATEST(
            background_job_rate_limits.blocked_until,
            EXCLUDED.blocked_until
          ),
          updated_at = EXCLUDED.updated_at
      """,
      [job.queue, job.rate_limit_key, retry_at, now],
      log: false
    )

    :ok
  end

  defp mark_pending_retry(%BackgroundJob{} = job, reason, attempts) do
    backoff_ms = calculate_backoff(attempts)

    DbResilience.with_database("background job runner mark retry", fn ->
      now = database_now!()
      retry_at = DateTime.add(now, backoff_ms, :millisecond)

      private_update_all(
        owned_claim(job),
        set: [
          status: "pending",
          attempts: attempts,
          scheduled_at: retry_at,
          claimed_by: nil,
          claimed_at: nil,
          claim_token: nil,
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    end)
  end

  defp mark_failed(%BackgroundJob{} = job, reason, attempts) do
    DbResilience.with_database("background job runner mark failed", fn ->
      now = database_now!()

      durable_payload = terminal_payload(job)

      private_update_all(
        owned_claim(job),
        set:
          [
            status: "failed",
            attempts: attempts,
            failed_at: now,
            claimed_by: nil,
            claimed_at: nil,
            claim_token: nil,
            last_error: error_text(reason),
            updated_at: now
          ] ++ request_payload_updates(job, durable_payload)
      )
    end)
  end

  defp terminal_payload(%BackgroundJob{job_type: "telegram_webhook_event"}), do: %{}
  defp terminal_payload(%BackgroundJob{payload: payload}), do: payload || %{}

  defp reclaim_stale_jobs(claim_timeout_ms, _state) do
    %{rows: [[count]]} =
      private_query!(
        """
        WITH stale_claims AS (
          SELECT id, claim_token, claimed_by, claimed_at
          FROM background_jobs
          WHERE status = 'running'
            AND claimed_at <
              timezone('UTC', clock_timestamp()) - ($1::bigint * interval '1 millisecond')
          FOR UPDATE SKIP LOCKED
        ),
        reclaimed AS (
          UPDATE background_jobs AS job
          SET status = 'pending',
              claimed_by = NULL,
              claimed_at = NULL,
              claim_token = NULL,
              updated_at = timezone('UTC', clock_timestamp())
          FROM stale_claims AS stale
          WHERE job.id = stale.id
            AND job.status = 'running'
            AND job.claim_token IS NOT DISTINCT FROM stale.claim_token
            AND job.claimed_by IS NOT DISTINCT FROM stale.claimed_by
            AND job.claimed_at IS NOT DISTINCT FROM stale.claimed_at
          RETURNING job.id
        )
        SELECT count(*)::bigint FROM reclaimed
        """,
        [claim_timeout_ms]
      )

    if count > 0 do
      Logger.info("Reclaimed stale background jobs", count: count)
    end

    sweep_stale_ingest_windows(database_now!())
  end

  defp sweep_stale_ingest_windows(now) do
    case Maraithon.Crm.Ingest.sweep_stale_windows(now) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Force-flushed stale CRM ingest windows", count: count)
    end
  rescue
    exception ->
      Logger.warning(
        "CRM ingest window sweep failed: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )
  catch
    kind, reason ->
      Logger.warning("CRM ingest window sweep crashed: #{kind} #{inspect(reason)}")
  end

  defp request_payload_updates(%BackgroundJob{} = job, payload) do
    # A legacy row may have been hydrated from its plaintext mirror while the
    # corresponding ciphertext column is still NULL. Persist both authenticated
    # fields whenever either changes so the binding context exactly matches the
    # next raw database load.
    payload_and_result_updates(job, payload, job.result || %{})
  end

  defp result_payload_updates(%BackgroundJob{} = job, result) do
    payload_and_result_updates(job, job.payload || %{}, result)
  end

  defp payload_and_result_updates(%BackgroundJob{} = job, payload, result) do
    updated = %{job | payload: payload, result: result}

    [
      payload: payload,
      legacy_payload: if(DurablePayload.legacy_write?(), do: payload, else: %{}),
      result: result,
      legacy_result: if(DurablePayload.legacy_write?(), do: result, else: %{}),
      payload_encryption_version: 1
    ] ++ binding_updates(updated)
  end

  defp binding_updates(job) do
    job
    |> DurablePayload.binding_attrs!(BackgroundJob.payload_binding_spec())
    |> Map.to_list()
  end

  defp private_update_all(query, updates) do
    private_mutation(fn -> Repo.update_all(query, updates) end)
  end

  defp private_query!(statement, params, opts \\ []) do
    private_mutation(fn -> Repo.query!(statement, params, opts) end)
  end

  defp private_mutation(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      :ok = DurablePayload.require_current_mutation!()
      fun.()
    else
      case Repo.transaction(fn ->
             :ok = DurablePayload.require_current_mutation!()
             fun.()
           end) do
        {:ok, result} -> result
        {:error, reason} -> raise "private BackgroundJob mutation failed: #{inspect(reason)}"
      end
    end
  end

  defp claim_key(%BackgroundJob{id: id, claim_token: claim_token})
       when is_binary(id) and is_binary(claim_token),
       do: {id, claim_token}

  defp renewable_claim(%BackgroundJob{
         id: id,
         claim_token: claim_token,
         coordination_task_assignment_id: assignment_id
       })
       when is_binary(id) and is_binary(claim_token) and is_binary(assignment_id) do
    from(candidate in BackgroundJob,
      where: candidate.id == ^id,
      where: candidate.claim_token == ^claim_token,
      where:
        candidate.status == "running" or
          (candidate.status == "pending" and
             candidate.coordination_task_assignment_id == ^assignment_id)
    )
  end

  defp renewable_claim(%BackgroundJob{} = job), do: owned_claim(job)

  defp owned_claim(%BackgroundJob{id: id, claim_token: claim_token})
       when is_binary(id) and is_binary(claim_token) do
    from(candidate in BackgroundJob,
      where: candidate.id == ^id,
      where: candidate.status == "running",
      where: candidate.claim_token == ^claim_token
    )
  end

  defp database_now! do
    case Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], log: false).rows do
      [[%NaiveDateTime{} = value]] -> DateTime.from_naive!(value, "Etc/UTC")
      [[%DateTime{} = value]] -> value
    end
  end

  defp calculate_backoff(attempts) when is_integer(attempts) and attempts > 0 do
    min(:timer.seconds(30) * round(:math.pow(2, attempts - 1)), :timer.minutes(15))
  end

  defp renewal_interval_ms(claim_timeout_ms)
       when is_integer(claim_timeout_ms) and claim_timeout_ms > 1 do
    claim_timeout_ms
    |> div(3)
    |> max(1)
    |> min(claim_timeout_ms - 1)
  end

  defp renewal_interval_ms(claim_timeout_ms) do
    raise ArgumentError,
          "background job claim timeout must be an integer greater than 1ms, got: #{inspect(claim_timeout_ms)}"
  end

  defp maybe_reconcile_recurring_jobs(%{reconcile_recurring_jobs?: false} = state),
    do: state

  defp maybe_reconcile_recurring_jobs(state) do
    now_ms = System.monotonic_time(:millisecond)

    if is_nil(state.next_recurring_reconcile_at_ms) or
         now_ms >= state.next_recurring_reconcile_at_ms do
      retry_in_ms =
        case reconcile_recurring_jobs_safely() do
          {:ok, _result} ->
            state.recurring_reconcile_interval_ms

          {:error, reason} ->
            Logger.warning("Recurring background job reconcile failed", reason: inspect(reason))
            min(state.recurring_reconcile_interval_ms, :timer.seconds(5))
        end

      %{state | next_recurring_reconcile_at_ms: now_ms + retry_in_ms}
    else
      state
    end
  end

  defp reconcile_recurring_jobs_safely do
    RecurringJobs.reconcile()
  rescue
    error -> {:error, {:reconcile_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:reconcile_exit, kind}}
  end

  defp filter_runner_queues(query, %{queues: queues, exclude_queues: excluded}) do
    query =
      case queues do
        [] -> query
        values -> where(query, [candidate], candidate.queue in ^values)
      end

    case excluded do
      [] -> query
      values -> where(query, [candidate], candidate.queue not in ^values)
    end
  end

  defp normalize_queue_names(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(32)
  end

  defp normalize_queue_names(value) when is_binary(value), do: normalize_queue_names([value])
  defp normalize_queue_names(_value), do: []

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)
  defp schedule_renewal(ms), do: Process.send_after(self(), :renew_claims, ms)

  defp safe_execute(handler, %BackgroundJob{job_type: "privacy_erasure"} = job) do
    handler.execute(job)
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp safe_execute(handler, %BackgroundJob{user_id: user_id} = job)
       when is_binary(user_id) do
    case WriteFence.check_user(user_id) do
      :ok -> handler.execute(job)
      {:error, :privacy_erasure_requested} -> {:ok, %{outcome: "erasure_fenced"}}
      {:error, :user_not_found} -> {:ok, %{outcome: "user_gone"}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp safe_execute(handler, %BackgroundJob{} = job) do
    handler.execute(job)
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp handler_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:handler, BackgroundJobHandler)
  end

  defp normalize_result(value) when is_map(value), do: stringify_keys(value)
  defp normalize_result(value), do: %{"value" => inspect(value)}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} when is_binary(key) -> {key, normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp error_text({:retry_after, seconds, reason}) when is_integer(seconds) do
    "retry_after=#{seconds} failure=#{closed_failure_text(reason)}"
  end

  defp error_text(reason), do: closed_failure_text(reason)

  defp closed_failure_text({:rate_limited, _provider_detail}), do: "rate_limited"
  defp closed_failure_text({:rate_limited, _seconds, _provider_detail}), do: "rate_limited"
  defp closed_failure_text({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp closed_failure_text({kind, _detail, _extra}) when is_atom(kind), do: Atom.to_string(kind)
  defp closed_failure_text(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp closed_failure_text(_reason), do: "background_job_error"
end
