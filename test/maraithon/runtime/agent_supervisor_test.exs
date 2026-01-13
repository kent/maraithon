defmodule Maraithon.Runtime.AgentSupervisorTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.AgentSupervisor
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

  describe "start_agent/1" do
    test "starts an agent process under the supervisor", %{scheduler_pid: _} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "supervisor_test_agent",
            "prompt" => "Test agent"
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = AgentSupervisor.start_agent(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      AgentSupervisor.stop_agent(pid)
    end

    test "agent is registered in AgentRegistry", %{scheduler_pid: _} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "registry_test_agent",
            "prompt" => "Test"
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = AgentSupervisor.start_agent(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Verify registered in registry
      [{^pid, nil}] = Registry.lookup(Maraithon.Runtime.AgentRegistry, agent.id)

      AgentSupervisor.stop_agent(pid)
    end
  end

  describe "stop_agent/1" do
    test "stops a running agent", %{scheduler_pid: _} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"name" => "stop_test", "prompt" => "Test"},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = AgentSupervisor.start_agent(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      assert Process.alive?(pid)

      :ok = AgentSupervisor.stop_agent(pid)

      # Give it a moment to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for already stopped agent", %{scheduler_pid: _} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"name" => "double_stop", "prompt" => "Test"},
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = AgentSupervisor.start_agent(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      :ok = AgentSupervisor.stop_agent(pid)
      Process.sleep(50)

      # Second stop should return error
      result = AgentSupervisor.stop_agent(pid)
      assert result == {:error, :not_found}
    end
  end
end
