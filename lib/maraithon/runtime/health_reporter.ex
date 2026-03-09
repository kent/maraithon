defmodule Maraithon.Runtime.HealthReporter do
  @moduledoc """
  Periodic health reporting and metrics collection.
  """

  use GenServer
  require Logger

  alias Maraithon.Runtime.Config, as: RuntimeConfig

  # Every minute
  @default_report_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    report_interval_ms =
      RuntimeConfig.positive_integer(:health_report_interval_ms, @default_report_interval_ms)

    schedule_report(report_interval_ms)
    {:ok, %{report_interval_ms: report_interval_ms}}
  end

  @impl true
  def handle_info(:report, state) do
    report_health()
    schedule_report(state.report_interval_ms)
    {:noreply, state}
  end

  defp report_health do
    health = Maraithon.Health.check()

    Logger.info("Health report",
      status: health.status,
      agents_running: health.checks.agents.running,
      agents_degraded: health.checks.agents.degraded,
      memory_mb: health.checks.memory_mb,
      uptime_seconds: health.checks.uptime_seconds
    )
  end

  defp schedule_report(interval_ms) do
    Process.send_after(self(), :report, interval_ms)
  end
end
