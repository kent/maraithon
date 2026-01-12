defmodule Maraithon.Runtime.HealthReporter do
  @moduledoc """
  Periodic health reporting and metrics collection.
  """

  use GenServer
  require Logger

  @report_interval_ms 60_000  # Every minute

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_report()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:report, state) do
    report_health()
    schedule_report()
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

  defp schedule_report do
    Process.send_after(self(), :report, @report_interval_ms)
  end
end
