defmodule Maraithon.Runtime.InsightNotifier do
  @moduledoc """
  Periodically dispatches Telegram insight notifications.
  """

  use GenServer

  alias Maraithon.InsightNotifications
  alias Maraithon.Runtime.Config

  require Logger

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    state = %{
      interval_ms: Config.positive_integer(:insight_notify_interval_ms, 60_000),
      batch_size: Config.positive_integer(:insight_notify_batch_size, 20)
    }

    schedule_tick(1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = InsightNotifications.dispatch_telegram_batch(batch_size: state.batch_size)

    if result.staged > 0 or result.sent > 0 or result.failed > 0 do
      Logger.info("Insight notifier cycle",
        staged: result.staged,
        sent: result.sent,
        failed: result.failed
      )
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Insight notifier cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
