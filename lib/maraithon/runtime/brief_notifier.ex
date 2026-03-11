defmodule Maraithon.Runtime.BriefNotifier do
  @moduledoc """
  Periodically dispatches Telegram chief-of-staff briefs.
  """

  use GenServer

  alias Maraithon.Briefs
  alias Maraithon.Runtime.Config

  require Logger

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    state = %{
      interval_ms: Config.positive_integer(:brief_notify_interval_ms, 60_000),
      batch_size: Config.positive_integer(:brief_notify_batch_size, 10)
    }

    schedule_tick(2_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = Briefs.dispatch_telegram_batch(batch_size: state.batch_size)

    if result.sent > 0 or result.failed > 0 do
      Logger.info("Brief notifier cycle",
        sent: result.sent,
        failed: result.failed,
        skipped: result.skipped
      )
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Brief notifier cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
