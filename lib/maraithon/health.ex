defmodule Maraithon.Health do
  @moduledoc """
  System health checks and monitoring.
  """

  alias Maraithon.Repo
  alias Maraithon.Agents

  require Logger

  @doc """
  Perform a comprehensive health check.
  """
  def check do
    db_status = check_database()
    agent_counts = count_agents()
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

  defp check_database do
    case Repo.query("SELECT 1") do
      {:ok, _} -> :ok
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
      _ -> %{running: 0, degraded: 0, stopped: 0}
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
