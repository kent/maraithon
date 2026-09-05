defmodule MaraithonWeb.RuntimeController do
  @moduledoc """
  Operator endpoints for the exact runtime's coordination lifecycle.

  `drain` asks this node to hand its partitions, Agents, and tasks back to
  PostgreSQL with local proofs before a revision replacement; `status` reports
  what the node still owns so a deploy can wait for a clean handover; `rejoin`
  lets a drained node register a fresh incarnation if the deploy is aborted.
  """
  use MaraithonWeb, :controller

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  alias Maraithon.Runtime.Coordination.{
    Authority,
    NodeIncarnation,
    Partition,
    Session,
    TaskAssignment
  }

  def drain(conn, _params) do
    :ok = Session.request_drain()
    json(conn, Map.put(status_payload(), :drain_requested, true))
  end

  def status(conn, _params), do: json(conn, status_payload())

  def rejoin(conn, _params) do
    case Session.rejoin() do
      :ok -> json(conn, Map.put(status_payload(), :rejoin_requested, true))
      {:error, reason} -> conn |> put_status(409) |> json(%{error: inspect(reason)})
    end
  rescue
    _error -> conn |> put_status(503) |> json(%{error: "coordination_session_unavailable"})
  catch
    :exit, _reason ->
      conn |> put_status(503) |> json(%{error: "coordination_session_unavailable"})
  end

  defp status_payload do
    %{phase: phase, node_incarnation_id: node_id} = Session.status()

    %{
      phase: Atom.to_string(phase),
      node_incarnation_id: node_id,
      process_role: Atom.to_string(RuntimeConfig.process_role()),
      deployment_generation: Authority.deployment_generation(),
      deployment_gate: Authority.deployment_gate_status(),
      # The Session's ETS phase is only an availability hint. Prove the
      # monotone PostgreSQL node fence independently for deploy decisions.
      node_fenced: node_fenced?(node_id),
      # This global count closes the gap where a replacement registration races
      # a local-only drain report. The database deployment gate repeats the
      # same proof while holding the protocol serialization lock.
      admitting_nodes: count_live_nodes(),
      # A drained singleton retains ownership until the successor planner can
      # release these rows. The deploy-safe invariant is that no partition in
      # this non-fleet-ready service can still admit work, not that ownership
      # is already gone.
      admitting_partitions: count_live_partitions(),
      unready_partitions: count_unready_partitions(),
      owned_partitions:
        count_owned(node_id, Partition, :owner_node_incarnation_id, [
          "preparing",
          "ready",
          "draining",
          "blocked"
        ]),
      open_tasks:
        count_owned(node_id, TaskAssignment, :node_incarnation_id, [
          "reserved",
          "running",
          "termination_requested",
          "termination_proven"
        ]),
      # `open_tasks` only describes this serving incarnation. A task reserved
      # by an earlier, lost incarnation can keep its partition draining even
      # when this node is otherwise clean. Surface that global fence so deploy
      # tooling cannot mistake a local drain for a safe handover.
      unproven_tasks: count_unproven_tasks(),
      local_agent_leases: count_leases(node_id),
      # Rejoining creates a fresh node incarnation, so a local-only count can
      # miss a lease left behind by an older incarnation. Any Agent lease is a
      # partition-release barrier and must be gone before singleton replacement.
      agent_leases: count_all(AgentRuntimeLease)
    }
  end

  defp node_fenced?(nil), do: false

  defp node_fenced?(node_id) do
    Repo.exists?(
      from(node in NodeIncarnation,
        where: node.id == ^node_id,
        where: node.state in ["draining", "revoked"],
        where: is_nil(node.ready_at)
      )
    )
  rescue
    _error -> nil
  end

  defp count_owned(nil, _schema, _field, _states), do: 0

  defp count_owned(node_id, schema, field, states) do
    Repo.one(
      from(row in schema,
        where: field(row, ^field) == ^node_id and row.state in ^states,
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_unproven_tasks do
    Repo.one(
      from(task in TaskAssignment,
        where:
          task.state in ["reserved", "running", "termination_requested", "termination_proven"],
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_leases(nil), do: 0

  defp count_leases(node_id) do
    Repo.one(
      from(lease in AgentRuntimeLease,
        where: lease.coordination_node_incarnation_id == ^node_id,
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_all(schema) do
    Repo.one(from(row in schema, select: count()))
  rescue
    _error -> nil
  end

  defp count_live_nodes do
    Repo.one(
      from(node in NodeIncarnation,
        where: node.state in ["joining", "ready"],
        where:
          node.lease_expires_at >
            fragment("timezone('UTC', clock_timestamp())"),
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_unready_partitions do
    Repo.one(
      from(partition in Partition,
        where:
          partition.state != "ready" or is_nil(partition.lease_expires_at) or
            partition.lease_expires_at <=
              fragment("timezone('UTC', clock_timestamp())"),
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_live_partitions do
    Repo.one(
      from(partition in Partition,
        where: partition.state in ["preparing", "ready"],
        where:
          is_nil(partition.lease_expires_at) or
            partition.lease_expires_at >
              fragment("timezone('UTC', clock_timestamp())"),
        select: count()
      )
    )
  rescue
    _error -> nil
  end
end
