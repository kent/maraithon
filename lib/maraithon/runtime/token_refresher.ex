defmodule Maraithon.Runtime.TokenRefresher do
  @moduledoc """
  Periodically refreshes OAuth tokens before they expire.
  """

  use GenServer

  alias Maraithon.OAuth
  alias Maraithon.Runtime.Config

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(5)
  @default_lookahead_seconds 15 * 60
  @default_batch_size 100
  @default_initial_delay_ms :timer.seconds(5)

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        positive_integer_opt(
          opts,
          :interval_ms,
          Config.positive_integer(:oauth_refresh_interval_ms, @default_interval_ms)
        ),
      lookahead_seconds:
        positive_integer_opt(
          opts,
          :lookahead_seconds,
          Config.positive_integer(:oauth_refresh_lookahead_seconds, @default_lookahead_seconds)
        ),
      batch_size:
        positive_integer_opt(
          opts,
          :batch_size,
          Config.positive_integer(:oauth_refresh_batch_size, @default_batch_size)
        ),
      observer: Keyword.get(opts, :observer)
    }

    initial_delay_ms = positive_integer_opt(opts, :initial_delay_ms, @default_initial_delay_ms)
    schedule_tick(initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = run_cycle(state)

    if result.attempted > 0 do
      Logger.info("OAuth token refresh cycle",
        attempted: result.attempted,
        refreshed: result.refreshed,
        failed: result.failed
      )
    end

    if is_pid(state.observer) do
      send(state.observer, {:oauth_refresh_cycle, result})
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("OAuth token refresh cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp run_cycle(state) do
    state.lookahead_seconds
    |> OAuth.list_expiring_tokens()
    |> Enum.take(state.batch_size)
    |> Enum.reduce(%{attempted: 0, refreshed: 0, failed: 0}, fn token, acc ->
      if refresh_supported_provider?(token.provider) do
        case OAuth.refresh_if_expiring(token.user_id, token.provider, state.lookahead_seconds) do
          {:ok, _updated} ->
            %{acc | attempted: acc.attempted + 1, refreshed: acc.refreshed + 1}

          {:error, reason} ->
            Logger.warning("OAuth token refresh failed",
              user_id: token.user_id,
              provider: token.provider,
              reason: inspect(reason)
            )

            %{acc | attempted: acc.attempted + 1, failed: acc.failed + 1}
        end
      else
        acc
      end
    end)
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end

  defp positive_integer_opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp refresh_supported_provider?("google"), do: true

  defp refresh_supported_provider?("notion"), do: true

  defp refresh_supported_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "google:") or String.starts_with?(provider, "slack:")
  end

  defp refresh_supported_provider?(_provider), do: false
end
