defmodule Maraithon.Runtime.Coordination.FairScheduler do
  @moduledoc "Deterministic PostgreSQL tenant fairness and bounded rate admission."

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  alias Maraithon.Runtime.Coordination.{
    Authority,
    NodeIncarnation,
    Partitioning,
    TaskClaims,
    TaskSupervisor
  }

  require Logger

  @microunits 1_000_000
  @pending_physical_key {__MODULE__, :pending_physical_reservation}
  # Keep model-workload service history separate from execution partition keys.
  # Hash each component independently so arbitrary keys stay within varchar(255).
  @model_workload_key_sql "'fair-workload:' || md5(job.tenant_key) || ':' || md5(job.job_type)"

  def reserve_next(%NodeIncarnation{} = session, partitions, opts \\ [])
      when is_list(partitions) do
    max_attempts = Keyword.get(opts, :conflict_attempts, 8) |> min(32) |> max(1)
    task_ttl_ms = Keyword.get(opts, :task_ttl_ms, 30_000)
    queues = queue_names(Keyword.get(opts, :queues, []))
    exclude_queues = queue_names(Keyword.get(opts, :exclude_queues, []))

    do_reserve(
      session,
      partitions,
      task_ttl_ms,
      max_attempts,
      queues,
      exclude_queues
    )
  end

  def activate_job(%BackgroundJob{} = job, assignment) do
    Repo.transaction(fn ->
      assignment = unwrap!(TaskClaims.activate(assignment))
      set_effect_writer_protocol!()
      set_task_action!(assignment.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.background_jobs
          SET status = 'running', updated_at = timezone('UTC', clock_timestamp())
          WHERE id = $1::uuid AND status = 'pending' AND claim_token = $2::uuid
            AND coordination_task_assignment_id = $3::uuid
          RETURNING id, user_id, queue, job_type,
                    payload_ciphertext, payload, payload_encryption_version,
                    payload_binding_version, payload_binding_key_tag, payload_binding_mac,
                    payload_purged_at, status, dedupe_key, partition_key, rate_limit_key,
                    telegram_bot_id, telegram_update_id, attempts, max_attempts,
                    scheduled_at, claimed_by, claimed_at, claim_token, completed_at,
                    failed_at, cancelled_at, result_ciphertext, result, last_error,
                    tenant_key, partition_id, coordination_activation_epoch,
                    coordination_partition_epoch, coordination_node_incarnation_id,
                    coordination_task_assignment_id, coordination_task_supervisor_id,
                    coordination_local_task_id, inserted_at, updated_at
          """,
          [
            Ecto.UUID.dump!(job.id),
            Ecto.UUID.dump!(assignment.claim_token),
            Ecto.UUID.dump!(assignment.id)
          ]
        )

      {load_job!(result), assignment}
    end)
  end

  def configure_tenant(tenant_key, opts) when is_binary(tenant_key) and is_list(opts) do
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)
    rate = Keyword.fetch!(opts, :rate_per_minute)
    burst = Keyword.fetch!(opts, :burst)

    if max_concurrency in 1..64 and rate in 1..100_000 and burst in 1..10_000 do
      SQL.query(
        Repo,
        """
        UPDATE public.runtime_tenant_fairness
        SET max_concurrency = $2, rate_per_minute = $3, burst = $4,
            available_microunits = LEAST(available_microunits, $4::bigint * #{@microunits}),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_key = $1
        """,
        [tenant_key, max_concurrency, rate, burst]
      )
    else
      {:error, :invalid_tenant_quota}
    end
  end

  @doc """
  Raises a tenant's durable fair-admission ceiling without lowering an
  operator-set ceiling. Source-account graphs use this before enqueueing so
  independently ordered accounts can progress together while work for one
  account remains partitioned.
  """
  def ensure_min_tenant_concurrency(tenant_key, minimum)
      when is_binary(tenant_key) and minimum in 1..64 do
    partition_id = Partitioning.partition_for(tenant_key)

    case SQL.query(
           Repo,
           """
           INSERT INTO public.runtime_tenant_fairness
             (tenant_key, partition_id, max_concurrency, rate_per_minute, burst,
              available_microunits, refilled_at, last_served_sequence, served_count,
              inserted_at, updated_at)
           VALUES ($1, $2, $3, 60, 10, 10000000,
                   timezone('UTC', clock_timestamp()), 0, 0,
                   timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
           ON CONFLICT (tenant_key) DO UPDATE
           SET partition_id = EXCLUDED.partition_id,
               max_concurrency = GREATEST(
                 public.runtime_tenant_fairness.max_concurrency,
                 EXCLUDED.max_concurrency
               ),
               updated_at = timezone('UTC', clock_timestamp())
           """,
           [tenant_key, partition_id, minimum]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_min_tenant_concurrency(_tenant_key, _minimum), do: {:error, :invalid_tenant_quota}

  defp do_reserve(_session, [], _ttl, _attempts, _queues, _exclude_queues), do: {:ok, nil}

  defp do_reserve(_session, _partitions, _ttl, 0, _queues, _exclude_queues),
    do: {:error, :fair_claim_conflict_limit}

  defp do_reserve(session, partitions, task_ttl_ms, attempts, queues, exclude_queues) do
    Process.delete(@pending_physical_key)

    result =
      try do
        Repo.transaction(fn ->
          reserve_locked(session, partitions, task_ttl_ms, queues, exclude_queues)
        end)
      rescue
        error in Postgrex.Error ->
          # PostgreSQL may pick this transaction as the victim when a fair
          # claim races an Agent checkpoint that holds the same tenant's User
          # fence. The database transaction is already rolled back, but the
          # exact physical reservation lives outside PostgreSQL and must be
          # released before the claim can be retried.
          release_pending_physical!()

          if retryable_claim_conflict?(error) do
            Logger.warning("Fair Scheduler database conflict retried",
              database_code: database_error_code(error),
              attempts_remaining: attempts - 1
            )

            {:error, :fair_claim_conflict}
          else
            reraise error, __STACKTRACE__
          end

        error ->
          release_pending_physical!()
          reraise error, __STACKTRACE__
      end

    case result do
      {:ok, value} ->
        Process.delete(@pending_physical_key)
        {:ok, value}

      {:error, :fair_claim_conflict} ->
        Process.delete(@pending_physical_key)

        do_reserve(
          session,
          partitions,
          task_ttl_ms,
          attempts - 1,
          queues,
          exclude_queues
        )

      {:error, :fair_scheduler_busy} ->
        Process.delete(@pending_physical_key)
        {:ok, nil}

      other ->
        case Process.delete(@pending_physical_key) do
          nil -> :ok
          identity -> handoff_commit_unknown_reservation!(identity)
        end

        other
    end
  end

  defp reserve_locked(session, partitions, task_ttl_ms, queues, exclude_queues) do
    lock_session_reservations!(session)
    Authority.fence_partitions!(session, Enum.sort_by(partitions, & &1.partition_id), :ready)

    partition_ids = Enum.map(partitions, & &1.partition_id)
    partition_epochs = Enum.map(partitions, & &1.ownership_epoch)
    ensure_tenants!(session, partition_ids, partition_epochs, queues, exclude_queues)

    case candidate(session, partition_ids, partition_epochs, queues, exclude_queues) do
      nil -> nil
      candidate -> reserve_candidate!(session, candidate, task_ttl_ms)
    end
  end

  defp candidate(session, ids, epochs, queues, exclude_queues) do
    include_queues? = queues != []
    exclude_queues? = exclude_queues != []

    result =
      SQL.query!(
        Repo,
        """
        WITH owned(partition_id, partition_epoch) AS (
          SELECT * FROM unnest($1::smallint[], $2::bigint[])
        ), active_tenants AS MATERIALIZED (
          SELECT job.tenant_key, count(*)::integer AS active_count
          FROM public.runtime_task_assignments AS assignment
          JOIN public.background_jobs AS job ON job.id = assignment.work_id
          WHERE assignment.work_kind = 'background_job'
            AND assignment.state IN ('reserved', 'running', 'termination_requested', 'termination_proven')
            AND ($5::boolean = false OR job.queue = ANY($6::text[]))
            AND ($7::boolean = false OR NOT (job.queue = ANY($8::text[])))
          GROUP BY job.tenant_key
        ), candidates AS MATERIALIZED (
          SELECT job.id, job.tenant_key, job.partition_id, owned.partition_epoch,
                 tenant.max_concurrency, tenant.rate_per_minute, tenant.burst,
                 LEAST(tenant.burst::bigint * #{@microunits},
                   tenant.available_microunits + GREATEST(
                     floor(EXTRACT(EPOCH FROM
                       (timezone('UTC', clock_timestamp()) - tenant.refilled_at)) *
                       tenant.rate_per_minute * #{@microunits} / 60)::bigint, 0
                   )) AS refilled_tokens,
                 tenant.last_served_sequence, job.scheduled_at, job.inserted_at
          FROM public.background_jobs AS job
          JOIN owned ON owned.partition_id = job.partition_id
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = owned.partition_id
           AND partition.ownership_epoch = owned.partition_epoch
           AND partition.owner_node_incarnation_id = $3::uuid
           AND partition.activation_epoch = $4::uuid
           AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_tenant_fairness AS tenant ON tenant.tenant_key = job.tenant_key
          LEFT JOIN active_tenants AS active ON active.tenant_key = job.tenant_key
          LEFT JOIN public.background_job_partitions AS workload
            ON job.queue = 'runtime_model_user'
           AND workload.queue = job.queue
           AND workload.partition_key = (#{@model_workload_key_sql})
          WHERE job.status = 'pending'
            AND job.scheduled_at <= timezone('UTC', clock_timestamp())
            AND job.claim_token IS NULL
            AND ($5::boolean = false OR job.queue = ANY($6::text[]))
            AND ($7::boolean = false OR NOT (job.queue = ANY($8::text[])))
            AND NOT EXISTS (
              SELECT 1 FROM public.runtime_task_assignments AS existing
              WHERE existing.work_kind = 'background_job' AND existing.work_id = job.id
                AND existing.state IN ('reserved', 'running', 'termination_requested', 'termination_proven')
            )
            AND (job.partition_key IS NULL OR NOT EXISTS (
              SELECT 1
              FROM public.runtime_task_assignments AS active_assignment
              JOIN public.background_jobs AS active_job
                ON active_job.id = active_assignment.work_id
              WHERE active_assignment.work_kind = 'background_job'
                AND active_assignment.state IN (
                  'reserved', 'running', 'termination_requested', 'termination_proven'
                )
                AND active_job.queue = job.queue
                AND active_job.partition_key = job.partition_key
            ))
            AND COALESCE(active.active_count, 0) < tenant.max_concurrency
            AND LEAST(tenant.burst::bigint * #{@microunits},
                  tenant.available_microunits + GREATEST(
                    floor(EXTRACT(EPOCH FROM
                      (timezone('UTC', clock_timestamp()) - tenant.refilled_at)) *
                      tenant.rate_per_minute * #{@microunits} / 60)::bigint, 0
                  )) >= #{@microunits}
            AND (job.job_type <> 'telegram_webhook_event' OR job.id = (
              SELECT head.id FROM public.background_jobs AS head
              WHERE head.job_type = 'telegram_webhook_event'
                AND head.telegram_bot_id = job.telegram_bot_id
                AND head.status IN ('pending', 'running')
              ORDER BY (head.status = 'running') DESC, head.telegram_update_id, head.id
              LIMIT 1
            ))
          ORDER BY tenant.last_served_sequence, tenant.tenant_key,
                   -- A bounded, infrequent due-time decision must not wait
                   -- behind an entire account's source-discovery fan-out.
                   -- Tenant fairness and every admission fence still apply.
                   CASE WHEN job.job_type IN (
                     'runtime_partition:nudge', 'runtime_partition:critical_todo_push'
                   ) THEN 0 ELSE 1 END,
                   -- Rotate model workloads within a tenant so a large closure
                   -- graph cannot postpone discovery or todo ingestion forever.
                   -- Keep FIFO order within each workload and tenant admission.
                   workload.last_started_at ASC NULLS FIRST,
                   job.scheduled_at, job.inserted_at, job.id
          LIMIT 1
        )
        SELECT candidate.id, candidate.tenant_key, candidate.partition_id,
               candidate.partition_epoch, candidate.refilled_tokens
        FROM candidates AS candidate
        JOIN public.runtime_tenant_fairness AS tenant ON tenant.tenant_key = candidate.tenant_key
        JOIN public.background_jobs AS job ON job.id = candidate.id
        FOR UPDATE OF tenant, job SKIP LOCKED
        """,
        [
          ids,
          epochs,
          Ecto.UUID.dump!(session.id),
          Ecto.UUID.dump!(session.activation_epoch),
          include_queues?,
          queues,
          exclude_queues?,
          exclude_queues
        ]
      )

    case result.rows do
      [[id, tenant_key, partition_id, epoch, tokens]] ->
        %{
          id: Ecto.UUID.load!(id),
          tenant_key: tenant_key,
          partition_id: partition_id,
          ownership_epoch: epoch,
          refilled_tokens: tokens
        }

      [] ->
        nil
    end
  end

  defp reserve_candidate!(session, candidate, task_ttl_ms) do
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()

    case TaskSupervisor.reserve("background_job", candidate.id, claim_token, assignment_id) do
      {:ok, physical} ->
        Process.put(@pending_physical_key, physical)

        partition = %{
          partition_id: candidate.partition_id,
          ownership_epoch: candidate.ownership_epoch
        }

        identity =
          Map.merge(physical, %{
            work_kind: "background_job",
            work_id: candidate.id,
            claim_token: claim_token,
            assignment_id: assignment_id
          })

        try do
          assignment =
            unwrap!(TaskClaims.reserve(session, partition, identity, ttl_ms: task_ttl_ms))

          # Claim the partition's write lock before the background-job privacy
          # trigger takes its User lock. Agent fencing uses the same
          # partition-before-User order; reversing these two locks deadlocks.
          [[sequence]] =
            SQL.query!(
              Repo,
              """
              UPDATE public.runtime_partitions
              SET fair_sequence = fair_sequence + 1,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = $1 AND ownership_epoch = $2
              RETURNING fair_sequence
              """,
              [candidate.partition_id, candidate.ownership_epoch]
            ).rows

          set_effect_writer_protocol!()
          set_task_action!(assignment.id)

          result =
            SQL.query!(
              Repo,
              """
              UPDATE public.background_jobs
              SET claimed_by = $2, claimed_at = timezone('UTC', clock_timestamp()),
                  claim_token = $3::uuid, coordination_activation_epoch = $4::uuid,
                  coordination_partition_epoch = $5,
                  coordination_node_incarnation_id = $6::uuid,
                  coordination_task_assignment_id = $7::uuid,
                  coordination_task_supervisor_id = $8::uuid,
                  coordination_local_task_id = $9::uuid,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE id = $1::uuid AND status = 'pending' AND claim_token IS NULL
              RETURNING id, user_id, queue, job_type,
                        payload_ciphertext, payload, payload_encryption_version,
                        payload_binding_version, payload_binding_key_tag, payload_binding_mac,
                        payload_purged_at, status, dedupe_key, partition_key, rate_limit_key,
                        telegram_bot_id, telegram_update_id, attempts, max_attempts,
                        scheduled_at, claimed_by, claimed_at, claim_token, completed_at,
                        failed_at, cancelled_at, result_ciphertext, result, last_error,
                        tenant_key, partition_id, coordination_activation_epoch,
                        coordination_partition_epoch, coordination_node_incarnation_id,
                        coordination_task_assignment_id, coordination_task_supervisor_id,
                        coordination_local_task_id, inserted_at, updated_at
              """,
              [
                Ecto.UUID.dump!(candidate.id),
                Atom.to_string(node()),
                Ecto.UUID.dump!(claim_token),
                Ecto.UUID.dump!(session.activation_epoch),
                candidate.ownership_epoch,
                Ecto.UUID.dump!(session.id),
                Ecto.UUID.dump!(assignment.id),
                Ecto.UUID.dump!(physical.supervisor_id),
                Ecto.UUID.dump!(physical.local_task_id)
              ]
            )

          if result.num_rows != 1, do: Repo.rollback(:fair_claim_conflict)

          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_tenant_fairness
            SET available_microunits = $2 - #{@microunits},
                refilled_at = timezone('UTC', clock_timestamp()),
                last_served_sequence = $3, served_count = served_count + 1,
                updated_at = timezone('UTC', clock_timestamp())
            WHERE tenant_key = $1
            """,
            [candidate.tenant_key, candidate.refilled_tokens, sequence]
          )

          job = load_job!(result)
          record_model_workload_start!(job)

          {job, assignment, identity}
        catch
          kind, reason ->
            release_pending_physical!()

            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        Repo.rollback({:task_supervisor_reservation_failed, reason})
    end
  end

  defp record_model_workload_start!(%BackgroundJob{queue: "runtime_model_user", id: job_id}) do
    # This commits with the exact reservation under the existing tenant lock.
    # A failed reservation therefore never consumes a workload's turn.
    SQL.query!(
      Repo,
      """
      INSERT INTO public.background_job_partitions
        (queue, partition_key, last_started_at, inserted_at, updated_at)
      SELECT job.queue, #{@model_workload_key_sql},
             timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
             timezone('UTC', clock_timestamp())
      FROM public.background_jobs AS job
      WHERE job.id = $1::uuid AND job.queue = 'runtime_model_user'
      ON CONFLICT (queue, partition_key) DO UPDATE
      SET last_started_at = EXCLUDED.last_started_at, updated_at = EXCLUDED.updated_at
      """,
      [Ecto.UUID.dump!(job_id)]
    )
  end

  defp record_model_workload_start!(_job), do: :ok

  defp safe_release_physical(identity) do
    case TaskSupervisor.release(identity) do
      :ok -> :ok
      _not_released -> {:error, :task_release_failed}
    end
  rescue
    _error -> {:error, :task_release_failed}
  catch
    :exit, _reason -> {:error, :task_release_failed}
  end

  defp release_pending_physical! do
    case Process.delete(@pending_physical_key) do
      nil ->
        :ok

      identity ->
        case safe_release_physical(identity) do
          :ok -> :ok
          {:error, _release_failed} -> handoff_commit_unknown_reservation!(identity)
        end
    end
  end

  defp retryable_claim_conflict?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:deadlock_detected, :serialization_failure, "40P01", "40001"]

  defp retryable_claim_conflict?(_error), do: false

  defp database_error_code(%Postgrex.Error{postgres: %{code: code}}), do: to_string(code)
  defp database_error_code(_error), do: "unknown"

  defp handoff_commit_unknown_reservation!(identity) do
    case TaskSupervisor.terminate_exact(identity) do
      {:ok, _disposition} -> :ok
      {:unknown, _retry_owned} -> :ok
      {:error, :task_reservation_lost} -> :ok
      _unexpected -> exit(:background_job_commit_unknown_handoff_failed)
    end
  rescue
    _error -> exit(:background_job_commit_unknown_handoff_failed)
  catch
    :exit, reason -> exit({:background_job_commit_unknown_handoff_failed, reason})
  end

  # Each fair runner fences the full owned partition set with `FOR SHARE`, then
  # upgrades one selected partition through the fair-sequence UPDATE. Concurrent
  # runners on the same node can otherwise hold share locks that each other must
  # upgrade, including through the tenant `ON CONFLICT` path. Serialize before
  # taking any canonical row lock; partitions owned by other nodes remain fully
  # independent.
  # A runner that finds another fair runner mid-reservation yields this poll
  # instead of queueing on the lock with an idle-in-transaction connection.
  defp lock_session_reservations!(session) do
    lock_key = "maraithon.fair_scheduler:#{session.id}"

    case SQL.query!(
           Repo,
           "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
           [lock_key],
           log: false
         ).rows do
      [[true]] -> :ok
      _busy -> Repo.rollback(:fair_scheduler_busy)
    end
  end

  defp ensure_tenants!(session, ids, epochs, queues, exclude_queues) do
    include_queues? = queues != []
    exclude_queues? = exclude_queues != []

    SQL.query!(
      Repo,
      """
      WITH owned(partition_id, partition_epoch) AS (
        SELECT * FROM unnest($1::smallint[], $2::bigint[])
      )
      INSERT INTO public.runtime_tenant_fairness
        (tenant_key, partition_id, max_concurrency, rate_per_minute, burst,
         available_microunits, refilled_at, last_served_sequence, served_count,
         inserted_at, updated_at)
      SELECT DISTINCT job.tenant_key, job.partition_id, 1, 60, 10, 10000000,
             timezone('UTC', clock_timestamp()), 0, 0,
             timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      FROM public.background_jobs AS job
      JOIN owned ON owned.partition_id = job.partition_id
      JOIN public.runtime_partitions AS partition
        ON partition.partition_id = owned.partition_id
       AND partition.ownership_epoch = owned.partition_epoch
       AND partition.owner_node_incarnation_id = $3::uuid
       AND partition.activation_epoch = $4::uuid
       AND partition.state = 'ready'
       AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
      WHERE job.status = 'pending'
        AND ($5::boolean = false OR job.queue = ANY($6::text[]))
        AND ($7::boolean = false OR NOT (job.queue = ANY($8::text[])))
      ON CONFLICT (tenant_key) DO NOTHING
      """,
      [
        ids,
        epochs,
        Ecto.UUID.dump!(session.id),
        Ecto.UUID.dump!(session.activation_epoch),
        include_queues?,
        queues,
        exclude_queues?,
        exclude_queues
      ]
    )
  end

  defp queue_names(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp queue_names(_values), do: []

  defp load_job!(%{columns: columns, rows: [row]}) do
    BackgroundJob
    |> Repo.load({columns, decode_payload(columns, row)})
    |> BackgroundJob.hydrate_payloads()
  end

  defp load_job!(_), do: Repo.rollback(:fair_claim_conflict)

  defp decode_payload(columns, row) do
    Enum.reduce(["payload", "result"], row, fn field, acc ->
      case Enum.find_index(columns, &(&1 == field)) do
        nil ->
          acc

        index ->
          case Enum.at(acc, index) do
            value when is_binary(value) -> List.replace_at(acc, index, Jason.decode!(value))
            _ -> acc
          end
      end
    end)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp unwrap!(value), do: value

  defp set_effect_writer_protocol! do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
      []
    )
  end

  defp set_task_action!(id),
    do: SQL.query!(Repo, "SELECT set_config('maraithon.runtime_task_action', $1, true)", [id])
end
