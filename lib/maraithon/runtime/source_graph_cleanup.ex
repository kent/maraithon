defmodule Maraithon.Runtime.SourceGraphCleanup do
  @moduledoc """
  Cancels unclaimed children of an abandoned, published source graph in short
  transactions. A live sibling task supplies authority; claimed work and its
  outcome evidence are never changed by cleanup.
  """

  import Ecto.Query

  alias Maraithon.{DurablePayload, Repo}
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.{TaskAssignment, TaskClaims}

  require Logger

  @batch_size 64
  @child_types ~w(
    runtime_partition:source_account_discovery_reason
    runtime_partition:source_account_discovery_finalize
    runtime_partition:source_account_closure_reason
    runtime_partition:source_account_closure_finalize
  )

  # Legacy execution can still discard its own job through the normal runner,
  # but it cannot authorize cancellation of siblings without an exact lease.
  def cancel_unclaimed(%BackgroundJob{coordination_task_assignment_id: nil}, _ids),
    do: {:ok, 0}

  def cancel_unclaimed(%BackgroundJob{} = job, published_ids) when is_list(published_ids) do
    started_at = System.monotonic_time(:millisecond)

    result =
      Repo.transaction(fn ->
        # Cleanup is optional for this sibling's failure. Do not delay node
        # renewal while waiting on another writer's User fence.
        Repo.query!("SET LOCAL lock_timeout = '500ms'")
        :ok = DurablePayload.require_current_mutation!()
        TaskClaims.fence_running!(assignment(job))
        _user = WriteFence.lock_user_writable!(job.user_id)

        graph =
          BackgroundJob
          |> where([child], child.user_id == ^job.user_id and child.id in ^published_ids)
          |> where([child], child.job_type in @child_types)

        if Repo.exists?(where(graph, [child], child.status in ["failed", "cancelled"])) do
          ids =
            graph
            |> where([child], child.status == "pending" and is_nil(child.claim_token))
            |> where([child], is_nil(child.claimed_by) and is_nil(child.claimed_at))
            |> where([child], is_nil(child.coordination_task_assignment_id))
            |> order_by([child], asc: child.id)
            |> limit(@batch_size)
            |> lock("FOR UPDATE SKIP LOCKED")
            |> select([child], child.id)
            |> Repo.all()

          now = DateTime.utc_now()

          {count, _} =
            BackgroundJob
            |> where([child], child.id in ^ids)
            |> Repo.update_all(
              set: [
                status: "cancelled",
                cancelled_at: now,
                last_error: "source_graph_abandoned",
                updated_at: now
              ]
            )

          TaskClaims.fence_running!(assignment(job))
          count
        else
          0
        end
      end)

    case result do
      {:ok, count} when count > 0 ->
        Logger.info("Source graph unclaimed children cancelled",
          job_id: job.id,
          count: count,
          duration_ms: System.monotonic_time(:millisecond) - started_at
        )

      _ ->
        :ok
    end

    result
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:ok, 0},
        else: reraise(error, __STACKTRACE__)
  end

  defp assignment(job) do
    %TaskAssignment{
      id: job.coordination_task_assignment_id,
      activation_epoch: job.coordination_activation_epoch,
      work_kind: "background_job",
      work_id: job.id,
      claim_token: job.claim_token,
      partition_id: job.partition_id,
      partition_epoch: job.coordination_partition_epoch,
      node_incarnation_id: job.coordination_node_incarnation_id,
      supervisor_id: job.coordination_task_supervisor_id,
      local_task_id: job.coordination_local_task_id
    }
  end
end
