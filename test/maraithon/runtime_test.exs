defmodule Maraithon.RuntimeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime
  alias Maraithon.Agents

  setup do
    # Stop any existing scheduler
    case Process.whereis(Maraithon.Runtime.Scheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    {:ok, scheduler_pid} = Maraithon.Runtime.Scheduler.start_link([])
    Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), scheduler_pid)

    on_exit(fn ->
      case Process.whereis(Maraithon.Runtime.Scheduler) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end
    end)

    %{scheduler_pid: scheduler_pid}
  end

  describe "get_agent_status/1" do
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.get_agent_status(Ecto.UUID.generate())
    end

    test "returns status for existing agent" do
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

      {:ok, status} = Runtime.get_agent_status(agent.id)

      assert status.id == agent.id
      assert status.status == "running"
      assert status.behavior == "watchdog_summarizer"
    end
  end

  describe "get_events/2" do
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.get_events(Ecto.UUID.generate())
    end

    test "returns events for existing agent" do
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

      {:ok, events} = Runtime.get_events(agent.id)

      assert is_list(events)
      assert events == []
    end
  end

  describe "send_message/3" do
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.send_message(Ecto.UUID.generate(), "hello")
    end

    test "returns agent_stopped for stopped agent" do
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "stopped",
        started_at: DateTime.utc_now(),
        stopped_at: DateTime.utc_now()
      })

      assert {:error, :agent_stopped} = Runtime.send_message(agent.id, "hello")
    end
  end

  describe "stop_agent/2" do
    test "returns not_found for non-existent agent" do
      assert {:error, :not_found} = Runtime.stop_agent(Ecto.UUID.generate())
    end

    test "stops existing agent and updates database" do
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

      {:ok, result} = Runtime.stop_agent(agent.id)

      assert result.stopped_at != nil

      # Verify database was updated
      updated_agent = Agents.get_agent(agent.id)
      assert updated_agent.status == "stopped"
      assert updated_agent.stopped_at != nil
    end

    test "accepts custom reason" do
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

      {:ok, _result} = Runtime.stop_agent(agent.id, "test_reason")

      # Verify agent was stopped
      updated_agent = Agents.get_agent(agent.id)
      assert updated_agent.status == "stopped"
    end
  end

  describe "start_agent/1" do
    test "returns error for invalid behavior" do
      params = %{
        "behavior" => "nonexistent_behavior",
        "config" => %{}
      }

      # This will return an error because the behavior is invalid
      result = Runtime.start_agent(params)

      # Should be an error for invalid behavior
      assert match?({:error, _}, result)
    end

    # Note: Tests that require running agent processes are covered in
    # test/maraithon/runtime/agent_test.exs which properly handles
    # database sandbox access for spawned processes.
  end

  describe "resume_all_agents/0" do
    test "resumes agents that were running" do
      # Create an agent that would be resumable
      {:ok, agent} = Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

      # This should attempt to resume agents
      # (doesn't fail even if process start fails)
      assert :ok = Runtime.resume_all_agents()

      # The agent should still exist
      assert Agents.get_agent(agent.id) != nil
    end
  end

  # Note: Tests for running agents (get_agent_status with runtime info,
  # send_message to running agent) are covered in test/maraithon/runtime/agent_test.exs
  # which properly handles database sandbox access for spawned processes.
end
