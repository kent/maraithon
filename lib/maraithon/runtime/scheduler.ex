defmodule Maraithon.Runtime.Scheduler do
  @moduledoc """
  Durable scheduler that persists wakeups to Postgres.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.DurablePayload
  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Runtime.Coordination.{Authority, Protocol, Scope}

  require Logger

  @default_poll_interval_ms 5_000
  @default_dispatch_timeout_ms 60_000
  @runnable_agent_statuses ~w(running degraded)
  # After this many dispatch attempts that were never acknowledged, a job is
  # dead-lettered instead of being reclaimed and re-dispatched forever. With
  # PubSub acknowledging mailbox delivery, a job that keeps going stale is
  # almost always bound for an agent process that no longer exists.
  @max_dispatch_attempts 5

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
  Replace an agent's active job of a type with one that fires after a delay.

  Recurring timers should use this instead of `schedule_in/4`. The advisory
  lock and transaction ensure agent restarts or duplicate wakeups cannot
  multiply heartbeat and checkpoint jobs.
  """
  def schedule_unique_in(agent_id, job_type, delay_ms, payload \\ %{}) do
    fire_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    schedule_unique_at(agent_id, job_type, fire_at, payload)
  end

  @doc """
  Replace active jobs within one payload scope after a delay.

  Unlike `schedule_unique_in/4`, this preserves active jobs of the same type
  whose payloads belong to another scope. The scope marker is injected into
  the new payload so callers cannot accidentally create an unreplaceable job.
  """
  def schedule_scoped_unique_in(
        agent_id,
        job_type,
        delay_ms,
        {scope_key, scope_value} = scope,
        payload \\ %{},
        opts \\ []
      )
      when is_binary(scope_key) and is_binary(scope_value) and is_map(payload) and
             is_list(opts) do
    fire_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    schedule_scoped_unique_at(agent_id, job_type, fire_at, scope, payload, opts)
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
  Atomically replace all active jobs of a type for an agent.
  """
  def schedule_unique_at(agent_id, job_type, fire_at, payload \\ %{}) do
    replace_unique_job(agent_id, job_type, fire_at, payload, :all, [])
  end

  @doc """
  Atomically replace active jobs within one payload scope at a specific time.

  Set `:include_legacy_empty_payload` while migrating an older unscoped timer;
  empty active payloads of the same job type are then cancelled in the same
  transaction. Jobs in other non-empty scopes are preserved.

  Set `:preserve_earlier` for recurring wakeups that must not be postponed by
  intervening activity. An earlier active job is retained, including its
  payload, while duplicate active jobs in that scope are cancelled.
  """
  def schedule_scoped_unique_at(
        agent_id,
        job_type,
        fire_at,
        {scope_key, scope_value} = scope,
        payload \\ %{},
        opts \\ []
      )
      when is_binary(scope_key) and is_binary(scope_value) and is_map(payload) and
             is_list(opts) do
    payload = Map.put(payload, scope_key, scope_value)
    replace_unique_job(agent_id, job_type, fire_at, payload, scope, opts)
  end

  @doc """
  Cancel active jobs within one payload scope without touching sibling scopes.
  """
  def cancel_scoped(
        agent_id,
        job_type,
        {scope_key, scope_value} = scope,
        opts \\ []
      )
      when is_binary(scope_key) and is_binary(scope_value) and is_list(opts) do
    result =
      DbResilience.with_database("scheduler cancel scoped jobs", fn ->
        Repo.transaction(fn ->
          :ok = DurablePayload.require_current_mutation!()
          lock_unique_jobs(agent_id, job_type)

          agent_id
          |> active_jobs_query(job_type, scope, opts)
          |> private_update_all(
            set: [status: "cancelled", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
          )
        end)
      end)

    case result do
      {:ok, {:ok, update_result}} -> update_result
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
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
           |> private_update_all(
             set: [status: "cancelled", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
           )
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancel all pending or dispatched jobs for an agent.
  """
  def cancel_all(agent_id) when is_binary(agent_id) do
    case DbResilience.with_database("scheduler cancel all agent jobs", fn ->
           from(j in ScheduledJob,
             where: j.agent_id == ^agent_id,
             where: j.status in ["pending", "dispatched"]
           )
           |> private_update_all(
             set: [status: "cancelled", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
           )
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def pending_payload?(agent_id, job_type, payload_key, payload_value)
      when is_binary(agent_id) and is_binary(job_type) and is_binary(payload_key) and
             is_binary(payload_value) do
    case DbResilience.with_database("scheduler pending payload lookup", fn ->
           ScheduledJob
           |> where([job], job.agent_id == ^agent_id)
           |> where([job], job.job_type == ^job_type)
           |> where([job], job.status in ["pending", "dispatched"])
           |> pending_payload_filter(payload_key, payload_value)
           |> Repo.exists?()
         end) do
      {:ok, result} -> result
      {:error, _reason} -> false
    end
  end

  defp pending_payload_filter(query, "dedupe_key", value) do
    where(
      query,
      [job],
      job.payload_dedupe_key == ^value or
        (is_nil(job.payload_encryption_version) and
           fragment("?->>? = ?", job.legacy_payload, "dedupe_key", ^value))
    )
  end

  defp pending_payload_filter(query, key, value) do
    where(
      query,
      [job],
      (job.payload_scope_key == ^key and job.payload_scope_value == ^value) or
        (is_nil(job.payload_encryption_version) and
           fragment("?->>? = ?", job.legacy_payload, ^key, ^value))
    )
  end

  @doc """
  Mark a dispatched job as delivered after PubSub confirms mailbox enqueue.
  """
  def ack_delivered(job_id) do
    case {Protocol.mode(), EffectProtocol.mode()} do
      {:dark, :legacy} -> ack_legacy_mailbox_delivery(job_id)
      _blocked_or_exact -> {:error, :legacy_mailbox_ack_forbidden}
    end
  end

  defp ack_legacy_mailbox_delivery(job_id) do
    now = DateTime.utc_now()

    case DbResilience.with_database("scheduler ack delivered", fn ->
           private_update_all(
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
             |> scoped_schedule_query()
             |> Repo.all()
             |> Enum.map(&ScheduledJob.hydrate_payload/1)

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
           case job_id |> then(&Repo.get(ScheduledJob, &1)) |> ScheduledJob.hydrate_payload() do
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
  def handle_info({:scheduled_job_enqueued, job_id}, state) when is_binary(job_id) do
    _ = ack_delivered(job_id)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Scheduler ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_in_flight, _from, state) do
    {:reply, :ok, %{state | in_flight: MapSet.new()}}
  end

  # Private functions

  defp replace_unique_job(agent_id, job_type, fire_at, payload, scope, opts) do
    attrs =
      %{
        agent_id: agent_id,
        job_type: job_type,
        fire_at: fire_at,
        payload: payload,
        status: "pending"
      }
      |> maybe_put_scope(scope)

    result =
      DbResilience.with_database("scheduler replace unique job", fn ->
        Repo.transaction(fn ->
          :ok = DurablePayload.require_current_mutation!()
          lock_schedule_agent(agent_id)
          lock_unique_jobs(agent_id, job_type)

          active_jobs = active_jobs_query(agent_id, job_type, scope, opts)
          earlier_job = earlier_active_job(active_jobs, fire_at, opts)

          jobs_to_cancel =
            case earlier_job do
              nil -> active_jobs
              job -> where(active_jobs, [active], active.id != ^job.id)
            end

          {cancelled_count, _} =
            jobs_to_cancel
            |> private_update_all(
              set: [status: "cancelled", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
            )

          if earlier_job do
            {earlier_job, cancelled_count}
          else
            case %ScheduledJob{} |> ScheduledJob.changeset(attrs) |> Repo.insert() do
              {:ok, job} -> {job, cancelled_count}
              {:error, reason} -> Repo.rollback(reason)
            end
          end
        end)
      end)

    case result do
      {:ok, {:ok, {job, cancelled_count}}} ->
        Logger.debug(
          "Scheduled unique #{job_type} for #{agent_id} at #{job.fire_at}",
          cancelled_jobs: cancelled_count
        )

        {:ok, job.id}

      {:ok, {:error, reason}} ->
        Logger.error("Failed to schedule unique job: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp earlier_active_job(query, %DateTime{} = fire_at, opts) do
    if Keyword.get(opts, :preserve_earlier, false) do
      query
      |> where([job], job.fire_at <= ^fire_at)
      |> order_by([job], asc: job.fire_at, asc: job.id)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> select([job], %{id: job.id, fire_at: job.fire_at})
      |> Repo.one()
    end
  end

  defp earlier_active_job(_query, _fire_at, _opts), do: nil

  defp lock_schedule_agent(agent_id) do
    # Exact delivery owns Agent before ScheduledJob. Take the FK-equivalent
    # Agent lock before cancelling an older job so a replacement INSERT cannot
    # form the inverse ScheduledJob -> Agent dependency.
    Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR KEY SHARE"))
  end

  defp lock_unique_jobs(agent_id, job_type) do
    lock_key = "scheduler:#{agent_id}:#{job_type}"

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      [lock_key]
    )

    :ok
  end

  defp active_jobs_query(agent_id, job_type, :all, _opts) do
    from(j in ScheduledJob,
      where: j.agent_id == ^agent_id,
      where: j.job_type == ^job_type,
      where: j.status in ["pending", "dispatched"]
    )
  end

  defp active_jobs_query(agent_id, job_type, {scope_key, scope_value}, opts) do
    include_legacy_empty_payload? =
      Keyword.get(opts, :include_legacy_empty_payload, false) == true

    base_query =
      from(j in ScheduledJob,
        where: j.agent_id == ^agent_id,
        where: j.job_type == ^job_type,
        where: j.status in ["pending", "dispatched"]
      )

    promoted_scope =
      dynamic(
        [job],
        job.payload_scope_key == ^scope_key and job.payload_scope_value == ^scope_value
      )

    legacy_scope =
      dynamic(
        [job],
        is_nil(job.payload_encryption_version) and
          fragment("?->>? = ?", job.legacy_payload, ^scope_key, ^scope_value)
      )

    scope_filter = dynamic([job], ^promoted_scope or ^legacy_scope)

    scope_filter =
      if include_legacy_empty_payload? do
        dynamic(
          [job],
          ^scope_filter or job.payload_empty == true or
            (is_nil(job.payload_encryption_version) and
               fragment("? = '{}'::jsonb", job.legacy_payload))
        )
      else
        scope_filter
      end

    where(base_query, ^scope_filter)
  end

  defp deliver_job(job) do
    case {Protocol.mode(), EffectProtocol.mode()} do
      {:dark, :legacy} ->
        deliver_job_legacy(job)

      {:active, :exact} ->
        if RuntimeConfig.exact_agent_runtime_ready?() do
          durably_accept_job(job)
        else
          {:error, :exact_runtime_not_ready}
        end

      _blocked_or_mismatched ->
        {:error, :runtime_authority_not_ready}
    end
  end

  defp durably_accept_job(job) do
    user_id =
      Repo.one(from(agent in Agent, where: agent.id == ^job.agent_id, select: agent.user_id))

    result =
      with true <- is_binary(user_id),
           {:ok, session, partition} <- Scope.partition_for_user(user_id) do
        Repo.transaction(fn ->
          # Fair background-job admission holds this partition before its User
          # privacy fence. Scheduled delivery must acquire the same pair in the
          # same order or the two schedulers can deadlock under load.
          Authority.fence_partition!(
            session,
            partition.partition_id,
            partition.ownership_epoch,
            :ready
          )

          :ok = DurablePayload.require_current_mutation!()

          payload = %{
            "job_type" => job.job_type,
            "job_id" => job.id,
            "payload" => job.payload || %{}
          }

          directive =
            case AgentDirectives.enqueue_in_transaction(
                   job.agent_id,
                   user_id,
                   "scheduled_wakeup",
                   payload,
                   "scheduled_job:#{job.id}"
                 ) do
              {:ok, directive} -> directive
              {:error, reason} -> Repo.rollback(reason)
            end

          locked_job =
            ScheduledJob
            |> where([stored], stored.id == ^job.id)
            |> lock("FOR UPDATE")
            |> Repo.one()

          case locked_job do
            %ScheduledJob{status: "pending"} ->
              now = DatabaseClock.now!()
              dispatch_token = Ecto.UUID.generate()

              Repo.query!(
                "SELECT set_config('maraithon.runtime_schedule_action', $1, true)",
                [dispatch_token]
              )

              {1, _rows} =
                private_update_all(
                  from(stored in ScheduledJob,
                    where: stored.id == ^job.id and stored.status == "pending"
                  ),
                  set: [
                    status: "delivered",
                    delivered_at: now,
                    claimed_by: nil,
                    claimed_at: nil,
                    dispatched_at: nil,
                    dispatch_token: dispatch_token,
                    coordination_activation_epoch: session.activation_epoch,
                    coordination_partition_epoch: partition.ownership_epoch,
                    coordination_node_incarnation_id: session.id
                  ],
                  inc: [attempts: 1]
                )

              directive

            %ScheduledJob{status: status}
            when status in ["delivered", "cancelled", "failed"] ->
              Repo.rollback(:scheduled_job_already_terminal)

            nil ->
              Repo.rollback(:scheduled_job_not_found)

            _other ->
              Repo.rollback(:scheduled_job_not_pending)
          end
        end)
      else
        false -> {:error, :scheduled_job_agent_not_found}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, directive} ->
        :ok = AgentDirectives.notify_committed(directive)
        :ok

      {:error, :scheduled_job_already_terminal} ->
        :ok

      {:error, reason} when reason in [:agent_not_runnable, :agent_binding_not_active] ->
        case cancel_if_still_ineligible(job, reason) do
          {:ok, :cancelled} ->
            Logger.info("Cancelled scheduled job for ineligible agent",
              job_reference: Maraithon.Redaction.fingerprint(job.id),
              agent_reference: Maraithon.Redaction.fingerprint(job.agent_id),
              failure_code: Maraithon.Redaction.error_class(reason)
            )

            :ok

          {:ok, :already_terminal} ->
            :ok

          {:error, cancel_reason} ->
            log_deferred_acceptance(job, cancel_reason)
            {:error, cancel_reason}
        end

      {:error, reason} ->
        log_deferred_acceptance(job, reason)
        {:error, reason}
    end
  end

  # Lifecycle operations normally cancel timers while moving an Agent out of
  # service. A crash-loop trip can make the Agent non-runnable without passing
  # through that operation, however, and older timers must not be retried every
  # poll forever. Re-prove the exact partition and re-lock User -> Agent ->
  # Binding -> ScheduledJob before cancelling so a concurrent resume wins
  # cleanly and no stale BEAM observation can persist the decision.
  defp cancel_if_still_ineligible(job, reason) do
    user_id =
      Repo.one(from(agent in Agent, where: agent.id == ^job.agent_id, select: agent.user_id))

    with true <- is_binary(user_id),
         {:ok, session, partition} <- Scope.partition_for_user(user_id) do
      Repo.transaction(fn ->
        Authority.fence_partition!(
          session,
          partition.partition_id,
          partition.ownership_epoch,
          :ready
        )

        :ok = DurablePayload.require_current_mutation!()
        _user = WriteFence.lock_user_writable!(user_id)

        agent =
          Agent
          |> where([stored], stored.id == ^job.agent_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        binding =
          Binding
          |> where([stored], stored.agent_id == ^job.agent_id and stored.user_id == ^user_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        locked_job =
          ScheduledJob
          |> where([stored], stored.id == ^job.id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        cond do
          match?(
            %ScheduledJob{status: status} when status in ["delivered", "cancelled", "failed"],
            locked_job
          ) ->
            :already_terminal

          not match?(%ScheduledJob{status: "pending"}, locked_job) ->
            Repo.rollback(:scheduled_job_not_pending)

          ineligible_for_reason?(agent, binding, user_id, reason) ->
            {1, _rows} =
              private_update_all(
                from(stored in ScheduledJob,
                  where: stored.id == ^job.id and stored.status == "pending"
                ),
                set: [
                  status: "cancelled",
                  claimed_by: nil,
                  claimed_at: nil,
                  dispatched_at: nil
                ]
              )

            :cancelled

          true ->
            Repo.rollback(:scheduled_job_agent_became_eligible)
        end
      end)
    else
      false -> {:error, :scheduled_job_agent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ineligible_for_reason?(%Agent{} = agent, _binding, user_id, :agent_not_runnable) do
    agent.user_id == user_id and
      not (agent.install_status == "enabled" and agent.status in @runnable_agent_statuses)
  end

  defp ineligible_for_reason?(
         %Agent{user_id: user_id, install_status: "enabled", status: status},
         binding,
         user_id,
         :agent_binding_not_active
       )
       when status in @runnable_agent_statuses do
    not match?(%Binding{user_id: ^user_id, status: "active"}, binding)
  end

  defp ineligible_for_reason?(_agent, _binding, _user_id, _reason), do: false

  defp log_deferred_acceptance(job, reason) do
    Logger.warning("Scheduled job durable acceptance deferred",
      job_reference: Maraithon.Redaction.fingerprint(job.id),
      agent_reference: Maraithon.Redaction.fingerprint(job.agent_id),
      failure_code: Maraithon.Redaction.error_class(reason)
    )
  end

  defp deliver_job_legacy(job) do
    # Compatibility path for the stopped-fleet non-rolling cutover. Mailbox
    # receipt is not durable acceptance and is never used by the exact runtime.
    case private_update_all(
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
        send_to_agent(
          job.agent_id,
          {:wakeup, job.job_type, job.id, job.payload},
          job.id
        )

      {0, _} ->
        :ok
    end
  end

  defp send_to_agent(agent_id, message, job_id) do
    :ok =
      Dispatch.dispatch(agent_id, message, receipt: {self(), {:scheduled_job_enqueued, job_id}})
  end

  defp scoped_schedule_query(query) do
    case {Protocol.mode(), EffectProtocol.mode()} do
      {:dark, :legacy} ->
        query

      {:active, :exact} ->
        case Scope.current() do
          {:ok, session} ->
            from(j in query,
              join: partition in "runtime_partitions",
              on: field(partition, :partition_id) == j.partition_id,
              where:
                field(partition, :activation_epoch) == type(^session.activation_epoch, :binary_id),
              where:
                field(partition, :owner_node_incarnation_id) == type(^session.id, :binary_id),
              where: field(partition, :state) == "ready",
              where: fragment("? IS NOT NULL", field(partition, :ready_at)),
              where:
                field(partition, :lease_expires_at) >
                  fragment("timezone('UTC', clock_timestamp())")
            )

          _ ->
            where(query, [j], false)
        end

      _ ->
        where(query, [j], false)
    end
  end

  defp fetch_overdue_jobs do
    # Bounded: after an outage the backlog can be large, and delivering it all
    # in one handle_info floods agent mailboxes. The regular :poll drains the
    # remainder at its own cadence.
    from(j in ScheduledJob,
      where: j.status == "pending",
      where: j.fire_at < ^DateTime.utc_now(),
      order_by: [asc: j.fire_at],
      limit: 200
    )
    |> scoped_schedule_query()
    |> Repo.all()
    |> Enum.map(&ScheduledJob.hydrate_payload/1)
  end

  defp reclaim_stale_dispatched_jobs(timeout_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    # Dead-letter jobs that have gone stale too many times — almost always
    # wakeups for an agent process that is gone. Run this first so the reclaim
    # below only re-queues jobs that still have retries left.
    {failed_count, _} =
      private_update_all(
        from(j in ScheduledJob,
          where: j.status == "dispatched",
          where: j.claimed_at < ^cutoff,
          where: j.attempts >= @max_dispatch_attempts
        ),
        set: [status: "failed", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
      )

    {count, _} =
      private_update_all(
        from(j in ScheduledJob,
          where: j.status == "dispatched",
          where: j.claimed_at < ^cutoff
        ),
        set: [status: "pending", claimed_by: nil, claimed_at: nil, dispatched_at: nil]
      )

    if failed_count > 0 do
      Logger.warning(
        "Dead-lettered #{failed_count} scheduled jobs after #{@max_dispatch_attempts} unacknowledged dispatch attempts"
      )
    end

    if count > 0 do
      Logger.info("Reclaimed #{count} stale scheduled jobs")
    end
  end

  defp maybe_put_scope(attrs, {scope_key, scope_value}),
    do: Map.merge(attrs, %{payload_scope_key: scope_key, payload_scope_value: scope_value})

  defp maybe_put_scope(attrs, _scope), do: attrs

  defp private_update_all(query, updates) do
    private_mutation(fn -> Repo.update_all(query, updates) end)
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
        {:error, reason} -> raise "private ScheduledJob mutation failed: #{inspect(reason)}"
      end
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
