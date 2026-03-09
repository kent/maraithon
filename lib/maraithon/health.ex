defmodule Maraithon.Health do
  @moduledoc """
  System health checks and monitoring.
  """

  alias Maraithon.Repo
  alias Maraithon.Agents

  require Logger

  @database_timeout_ms 1_500
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
    timeout_ms = Keyword.get(opts, :database_timeout_ms, @database_timeout_ms)
    pool_timeout_ms = Keyword.get(opts, :database_pool_timeout_ms, timeout_ms)

    case Repo.query("SELECT 1", [], timeout: timeout_ms, pool_timeout: pool_timeout_ms) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Database health check failed: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
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
end
