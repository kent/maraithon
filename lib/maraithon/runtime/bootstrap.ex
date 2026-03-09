defmodule Maraithon.Runtime.Bootstrap do
  @moduledoc """
  One-shot runtime bootstrap worker.

  Resumes persisted running agents after supervision tree startup.
  """

  use GenServer

  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience

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
    Logger.info("Bootstrapping runtime")

    case DbResilience.with_database("runtime bootstrap", fn ->
           Maraithon.Runtime.resume_all_agents()
         end) do
      {:ok, _} ->
        {:stop, :normal, state}

      {:error, _reason} ->
        retry_in_ms = DbResilience.backoff_ms(state.retry_interval_ms, state.retry_attempts)

        Logger.warning("Runtime bootstrap will retry",
          retry_in_ms: retry_in_ms,
          retry_attempt: state.retry_attempts + 1
        )

        Process.send_after(self(), :bootstrap, retry_in_ms)
        {:noreply, %{state | retry_attempts: state.retry_attempts + 1}}
    end
  end
end
