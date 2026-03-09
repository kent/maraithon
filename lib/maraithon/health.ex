defmodule Maraithon.Health do
  @moduledoc """
  System health checks and monitoring.
  """

  alias Maraithon.Repo
  alias Maraithon.Agents

  require Logger

  @database_timeout_ms 750
  @database_wall_timeout_ms 750
  @database_failure_cooldown_ms 10_000
  @database_failure_cache_key {__MODULE__, :database_failure_at_ms}
  @empty_agent_counts %{running: 0, degraded: 0, stopped: 0}

  @doc """
  Perform a comprehensive health check.
  """
  def check(opts \\ []) do
    db_status =
      case Keyword.get(opts, :database_checker) do
        fun when is_function(fun, 0) -> fun.()
        nil -> check_database(opts)
      end

    agent_counts =
      if db_status == :ok do
        case Keyword.get(opts, :agent_counter) do
          fun when is_function(fun, 0) -> fun.()
          nil -> count_agents()
        end
      else
        @empty_agent_counts
      end

    memory = get_memory_usage()
    uptime = get_uptime()

    status =
      cond do
        db_status != :ok -> :unhealthy
        true -> :healthy
      end

    %{
      status: status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: %{
        database: db_status,
        agents: agent_counts,
        memory_mb: memory,
        uptime_seconds: uptime
      },
      version: Application.spec(:maraithon, :vsn) |> to_string()
    }
  end

  defp check_database(opts) do
    wall_timeout_ms = Keyword.get(opts, :database_wall_timeout_ms, @database_wall_timeout_ms)
    timeout_ms = Keyword.get(opts, :database_timeout_ms, @database_timeout_ms)
    pool_timeout_ms = Keyword.get(opts, :database_pool_timeout_ms, timeout_ms)

    failure_cooldown_ms =
      Keyword.get(opts, :database_failure_cooldown_ms, @database_failure_cooldown_ms)

    if recent_database_failure?(failure_cooldown_ms) do
      :error
    else
      caller = self()

      task =
        Task.async(fn ->
          Repo.query("SELECT 1", [],
            timeout: timeout_ms,
            pool_timeout: pool_timeout_ms,
            caller: caller
          )
        end)

      case Task.yield(task, wall_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, _}} ->
          clear_database_failure()
          :ok

        {:ok, {:error, reason}} ->
          mark_database_failure()
          Logger.error("Database health check failed: #{inspect(reason)}")
          :error

        nil ->
          mark_database_failure()
          Logger.error("Database health check timed out after #{wall_timeout_ms}ms")
          :error
      end
    end
  rescue
    e ->
      mark_database_failure()
      Logger.error("Database health check exception: #{inspect(e)}")
      :error
  end

  defp count_agents do
    try do
      %{
        running: Agents.count_by_status("running"),
        degraded: Agents.count_by_status("degraded"),
        stopped: Agents.count_by_status("stopped")
      }
    rescue
      _ -> @empty_agent_counts
    end
  end

  defp get_memory_usage do
    :erlang.memory(:total) |> div(1_024 * 1_024)
  end

  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp recent_database_failure?(cooldown_ms) when cooldown_ms > 0 do
    case :persistent_term.get(@database_failure_cache_key, nil) do
      failure_at_ms when is_integer(failure_at_ms) ->
        System.monotonic_time(:millisecond) - failure_at_ms < cooldown_ms

      _ ->
        false
    end
  end

  defp recent_database_failure?(_cooldown_ms), do: false

  defp mark_database_failure do
    :persistent_term.put(@database_failure_cache_key, System.monotonic_time(:millisecond))
  end

  defp clear_database_failure do
    :persistent_term.erase(@database_failure_cache_key)
  rescue
    ArgumentError -> :ok
  end
end
