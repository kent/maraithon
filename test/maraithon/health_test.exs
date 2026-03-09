defmodule Maraithon.HealthTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Health
  alias Maraithon.Agents

  describe "check/0" do
    test "returns healthy status when database is connected" do
      result = Health.check()

      assert result.status == :healthy
      assert result.checks.database == :ok
      assert Map.has_key?(result.checks, :agents)
      assert Map.has_key?(result.checks, :memory_mb)
      assert Map.has_key?(result.checks, :uptime_seconds)
      assert is_binary(result.timestamp)
      assert is_binary(result.version)
    end

    test "returns agent counts" do
      # Create some agents
      {:ok, _running} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _stopped} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped",
          started_at: DateTime.utc_now(),
          stopped_at: DateTime.utc_now()
        })

      result = Health.check()

      assert result.checks.agents.running >= 1
      assert result.checks.agents.stopped >= 1
      assert is_integer(result.checks.agents.degraded)
    end

    test "returns memory usage in MB" do
      result = Health.check()

      assert is_integer(result.checks.memory_mb)
      assert result.checks.memory_mb > 0
    end

    test "returns uptime in seconds" do
      result = Health.check()

      assert is_integer(result.checks.uptime_seconds)
      assert result.checks.uptime_seconds >= 0
    end

    test "skips agent counting when the database check fails" do
      result =
        Health.check(
          database_checker: fn -> :error end,
          agent_counter: fn ->
            flunk("agent counts should not run when database is unavailable")
          end
        )

      assert result.status == :unhealthy
      assert result.checks.database == :error
      assert result.checks.agents == %{running: 0, degraded: 0, stopped: 0}
    end
  end
end
