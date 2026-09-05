defmodule Maraithon.Runtime.Bootstrap do
  @moduledoc """
  One-shot runtime bootstrap worker.

  Resumes persisted running agents after supervision tree startup.
  """

  use GenServer

  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.Runtime.WakeCoordinator
  alias Maraithon.Runtime.Coordination.{Protocol, Scope}

  require Logger

  @default_retry_interval_ms 5_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :bootstrap)

    retry_interval_ms =
      RuntimeConfig.positive_integer(:bootstrap_retry_interval_ms, @default_retry_interval_ms)

    {:ok, %{retry_attempts: 0, retry_interval_ms: retry_interval_ms}}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    case Protocol.mode() do
      :dark ->
        case EffectProtocol.mode() do
          :legacy ->
            Logger.info("Bootstrapping the single-node legacy Agent runtime")
            do_bootstrap(state)

          :exact ->
            Logger.warning("Exact Agent runtime coordination is dark; bootstrap remains closed")
            {:stop, :normal, state}

          blocked ->
            retry_bootstrap({:effect_protocol_blocked, blocked}, state)
        end

      :active ->
        if RuntimeConfig.exact_agent_runtime_ready?() and
             Scope.ensure_ready_or_legacy() == :ok do
          do_bootstrap(state)
        else
          # Session is supervised last and publishes PostgreSQL readiness last.
          retry_bootstrap(:runtime_coordination_not_ready, state)
        end

      blocked ->
        retry_bootstrap({:runtime_coordination_blocked, blocked}, state)
    end
  end

  defp do_bootstrap(state) do
    Logger.info("Bootstrapping runtime")

    case DbResilience.with_database("runtime bootstrap", fn ->
           IncidentLog.record(%{
             kind: :node_boot,
             metadata: %{
               "source" => "runtime_bootstrap",
               "baseline" => IncidentLog.backlog_snapshot()
             }
           })

           with {:ok, _installations} <-
                  Maraithon.AgentMarketplace.ensure_default_installations(),
                {:ok, _reconciliation} <- WakeCoordinator.reconcile_once(),
                # BootGate remains closed until expired/staged ownership evidence is
                # reconciled and every resident desired Agent selected by this exact
                # ready partition scope has taken the preclaim path.
                :ok <- Maraithon.Runtime.resume_all_agents(),
                :ok <- Scope.ensure_ready_or_legacy() do
             :ok
           end
         end) do
      {:ok, {:error, reason}} ->
        retry_bootstrap(reason, state)

      {:ok, :ok} ->
        :ok = BootGate.open()
        {:stop, :normal, state}

      {:ok, other} ->
        retry_bootstrap({:unexpected_bootstrap_result, other}, state)

      {:error, reason} ->
        retry_bootstrap(reason, state)
    end
  end

  defp retry_bootstrap(reason, state) do
    Logger.warning("Runtime bootstrap did not complete",
      reason: inspect(reason),
      failure_code: Maraithon.Redaction.error_class(reason),
      retry_attempt: state.retry_attempts + 1
    )

    retry_in_ms = DbResilience.backoff_ms(state.retry_interval_ms, state.retry_attempts)

    Logger.warning("Runtime bootstrap will retry",
      retry_in_ms: retry_in_ms,
      retry_attempt: state.retry_attempts + 1
    )

    Process.send_after(self(), :bootstrap, retry_in_ms)
    {:noreply, %{state | retry_attempts: state.retry_attempts + 1}}
  end
end
