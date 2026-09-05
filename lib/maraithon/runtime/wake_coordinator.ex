defmodule Maraithon.Runtime.WakeCoordinator do
  @moduledoc """
  Bounded exact-ownership convergence for resident Agents.

  This lifecycle slice deliberately does not wake ordinary pending directives
  or idle Agents. It only reconciles expired lease generations, closes the
  guard/directive commit gap, and admits exact due recoveries.
  """

  use GenServer

  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.Coordination.Scope

  require Logger

  @default_interval_ms 2_000
  @default_batch_size 50
  @max_batch_size 500
  @allowed_reconcile_options [
    :admit_recoveries,
    :guard_opts,
    :limit,
    :supervisor,
    :watcher
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Requests an immediate best-effort convergence pass when the coordinator is local."
  def nudge(server \\ __MODULE__)

  def nudge(server) when is_atom(server) do
    if pid = Process.whereis(server), do: send(pid, :reconcile_now)
    :ok
  end

  def nudge(server) when is_pid(server) do
    send(server, :reconcile_now)
    :ok
  end

  def nudge(_server), do: :ok

  @doc "Runs one bounded exact-ownership convergence pass."
  def reconcile_once(opts \\ [])

  def reconcile_once(opts) when is_list(opts) do
    if Config.exact_agent_runtime_ready?() and match?({:ok, _session}, Scope.current()) do
      do_reconcile_once(opts)
    else
      no_work_summary()
    end
  end

  def reconcile_once(_opts), do: {:error, :invalid_reconciliation_options}

  defp do_reconcile_once(opts) do
    with :ok <- validate_options(opts),
         {:ok, limit} <- reconciliation_limit(opts),
         ownership when is_list(ownership) <-
           AgentDirectives.reconcile_expired_ownership(
             limit,
             Keyword.get(opts, :guard_opts, configured_guard_opts())
           ),
         :ok <- validate_ownership(ownership),
         recorded when is_list(recorded) <-
           AgentDirectives.reconcile_recorded_generations(limit),
         :ok <- validate_recorded(recorded),
         {:ok, tripped_effects} <- AgentRestartGuards.reconcile_tripped_pending(limit) do
      admission_open? = Keyword.get(opts, :admit_recoveries, BootGate.open?())
      lifecycle = reconcile_lifecycle_operations(limit, admission_open?)

      {recoveries, admissions} =
        if admission_open? do
          {start_due_recoveries(limit, opts), start_unowned_agents(limit, opts)}
        else
          {[], []}
        end

      {:ok,
       %{
         ownership: ownership,
         recorded: recorded,
         tripped_effects: tripped_effects,
         lifecycle: lifecycle,
         recoveries: recoveries,
         admissions: admissions,
         gate: if(admission_open?, do: :open, else: :closed)
       }}
    else
      {:error, reason} -> {:error, reason}
      unexpected -> {:error, {:unexpected_ownership_reconciliation, unexpected}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(opts, :interval_ms) ||
        Config.positive_integer(:agent_ownership_reconcile_interval_ms, @default_interval_ms)

    limit = Keyword.get(opts, :limit, configured_batch_size()) |> min(@max_batch_size) |> max(1)
    send(self(), :reconcile)
    {:ok, %{interval_ms: interval_ms, limit: limit}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    run_reconciliation(state)
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:reconcile_now, state) do
    run_reconciliation(state)
    {:noreply, state}
  end

  defp run_reconciliation(state) do
    case reconcile_once(limit: state.limit) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("Exact Agent ownership convergence deferred",
          failure_code: Maraithon.Redaction.error_class(reason)
        )
    end
  end

  defp reconcile_lifecycle_operations(limit, admission_open?) do
    limit
    |> AgentLifecycleOperations.list_pending_ids()
    |> Enum.map(fn agent_id ->
      result =
        case AgentLifecycleOperations.get(agent_id) do
          %{operation_token: operation_token} ->
            result =
              AgentLifecycleOperations.finalize_for_reconciliation(agent_id, operation_token)

            nudge_lifecycle_owner(agent_id, operation_token, result)
            result

          nil ->
            {:error, :lifecycle_operation_not_found}
        end

      start_result =
        case result do
          {:ok, %{status: :finalized, resume_after: true}} when admission_open? ->
            Maraithon.Runtime.resume_finalized_lifecycle(agent_id, admission: :recovery)

          {:ok, %{status: :finalized, resume_after: true}} ->
            :boot_gate_closed

          _pending_or_failed ->
            :not_started
        end

      {agent_id, result, start_result}
    end)
  end

  defp nudge_lifecycle_owner(
         agent_id,
         operation_token,
         {:ok, %{status: :reconciliation_pending, reason: :runtime_lease_owned}}
       ) do
    case AgentLifecycleOperations.get(agent_id) do
      %{operation_token: ^operation_token, expected_owner_token: owner_token}
      when is_binary(owner_token) ->
        case Registry.lookup(AgentRegistry, agent_id) do
          [{pid, ^owner_token}] when is_pid(pid) ->
            send(
              pid,
              {:agent_dispatch, {:control, :stop, "agent_lifecycle_reconciliation", owner_token}}
            )

            :ok

          _not_local_owner ->
            :not_local
        end

      _stale_operation ->
        :stale
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp nudge_lifecycle_owner(_agent_id, _operation_token, _result), do: :not_needed

  defp start_unowned_agents(limit, opts) do
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)
    watcher = Keyword.get(opts, :watcher, AgentWatcher)

    limit
    |> AgentLeases.list_unowned_runnable_ids()
    |> Enum.map(fn agent_id ->
      result =
        case Agents.get_agent(agent_id, include_removed: true) do
          %{status: status, install_status: "enabled"} = agent
          when status in ["running", "degraded"] ->
            AgentSupervisor.start_agent(agent,
              admission: :recovery,
              supervisor: supervisor,
              watcher: watcher
            )

          _stale_or_inactive ->
            {:error, :stale_unowned_agent}
        end

      {agent_id, result}
    end)
  end

  defp start_due_recoveries(limit, opts) do
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)
    watcher = Keyword.get(opts, :watcher, AgentWatcher)

    limit
    |> AgentDirectives.list_recovery_agent_ids()
    |> Enum.map(fn agent_id ->
      case {AgentRestartGuards.get(agent_id), Agents.get_agent(agent_id, include_removed: true)} do
        {%{generation: generation, needs_recovery: true, tripped: false},
         %{status: status, install_status: "enabled"} = agent}
        when status in ["running", "degraded"] ->
          result =
            AgentSupervisor.start_agent(agent,
              admission: :recovery,
              recovery_generation: generation,
              supervisor: supervisor,
              watcher: watcher
            )

          {agent_id, generation, result}

        _stale_or_inactive_hint ->
          {agent_id, nil, {:error, :stale_recovery_generation}}
      end
    end)
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in @allowed_reconcile_options)),
       do: :ok,
       else: {:error, :invalid_reconciliation_options}
  end

  defp reconciliation_limit(opts) do
    limit = Keyword.get(opts, :limit, configured_batch_size())

    if is_integer(limit) and limit in 1..@max_batch_size,
      do: {:ok, limit},
      else: {:error, :invalid_reconciliation_limit}
  end

  defp validate_ownership(results) do
    case Enum.find(results, &ownership_failure?/1) do
      nil -> :ok
      failure -> {:error, {:ownership_reconciliation_failed, failure}}
    end
  end

  defp ownership_failure?({_agent_id, _owner_token, guard_result, recovery_result}) do
    match?({:error, _reason}, guard_result) or match?({:error, _reason}, recovery_result)
  end

  defp validate_recorded(results) do
    case Enum.find(results, fn
           {_agent_id, {:error, _reason}} -> true
           _success -> false
         end) do
      nil -> :ok
      failure -> {:error, {:recorded_generation_reconciliation_failed, failure}}
    end
  end

  defp no_work_summary do
    {:ok,
     %{
       ownership: [],
       recorded: [],
       tripped_effects: 0,
       lifecycle: [],
       recoveries: [],
       admissions: [],
       gate: :closed
     }}
  end

  defp configured_batch_size do
    Config.positive_integer(:agent_ownership_reconcile_batch_size, @default_batch_size)
    |> min(@max_batch_size)
  end

  defp configured_guard_opts do
    [
      window_ms:
        Config.positive_integer(:agent_crash_loop_window_ms, 600_000)
        |> max(1_000)
        |> min(86_400_000),
      max_crashes: Config.positive_integer(:agent_crash_loop_max, 3) |> min(100),
      backoffs_ms: configured_backoffs()
    ]
  end

  defp configured_backoffs do
    case Config.get(:agent_reresume_backoffs, [5_000, 15_000, 30_000]) do
      values when is_list(values) ->
        values
        |> Enum.filter(&(is_integer(&1) and &1 >= 0))
        |> Enum.map(&min(&1, 3_600_000))
        |> case do
          [] -> [5_000, 15_000, 30_000]
          valid -> valid
        end

      _other ->
        [5_000, 15_000, 30_000]
    end
  end
end
