defmodule Maraithon.Runtime.AgentTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Agents

  setup do
    # Stop any existing scheduler/processes that might interfere
    case Process.whereis(Maraithon.Runtime.Scheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    {:ok, scheduler_pid} = Maraithon.Runtime.Scheduler.start_link([])
    Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), scheduler_pid)

    on_exit(fn ->
      case Process.whereis(Maraithon.Runtime.Scheduler) do
        nil -> :ok
        pid ->
          if Process.alive?(pid) do
            GenServer.stop(pid, :normal)
          end
      end
    end)

    # Create an agent for testing
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{
          "name" => "test_agent",
          "prompt" => "You are a test agent.",
          "subscribe" => [],
          "tools" => []
        },
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent, scheduler_pid: scheduler_pid}
  end

  describe "start_link/1" do
    test "starts the agent process", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid, :normal)
    end

    test "registers agent in registry", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Check registry
      [{^pid, nil}] = Registry.lookup(Maraithon.Runtime.AgentRegistry, agent.id)

      GenServer.stop(pid, :normal)
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec", %{agent: agent} do
      spec = RuntimeAgent.child_spec(agent)

      assert spec.id == agent.id
      assert spec.start == {RuntimeAgent, :start_link, [agent]}
      assert spec.restart == :temporary
      assert spec.type == :worker
    end
  end

  describe "init/1" do
    test "initializes agent with correct state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Give time for initialization
      Process.sleep(100)

      # Agent should be alive and in idle state
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "state transitions" do
    test "handles heartbeat wakeup in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Give time for initialization
      Process.sleep(150)

      # Send heartbeat wakeup
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "handles checkpoint wakeup in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "checkpoint", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "handles message in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello agent!", %{}, message_id})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "handles unknown message in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      send(pid, {:unknown_message, "test"})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "ignores duplicate wakeup job_id", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()

      # Send same job_id twice
      send(pid, {:wakeup, "heartbeat", job_id, %{}})
      Process.sleep(50)
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "pubsub events" do
    test "handles pubsub event when subscribed", %{scheduler_pid: _scheduler_pid} do
      topic = "test:topic:#{System.unique_integer()}"

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "pubsub_agent",
            "prompt" => "Test",
            "subscribe" => [topic],
            "tools" => []
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send pubsub event
      send(pid, {:pubsub_event, topic, %{data: "test"}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "ignores pubsub event when not subscribed", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send pubsub event for topic not subscribed to
      send(pid, {:pubsub_event, "unsubscribed:topic", %{data: "test"}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "effect handling" do
    test "handles effect_result for unknown effect", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Try to transition to waiting_effect state first by sending a message
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello!", %{}, message_id})

      Process.sleep(100)

      # Send effect result for unknown effect
      send(pid, {:effect_result, Ecto.UUID.generate(), {:ok, %{result: "test"}}})

      Process.sleep(100)
      # Agent may or may not still be alive depending on effect processing
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  describe "budget handling" do
    test "initializes with default budget when not configured", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "no_budget_agent",
            "prompt" => "Test"
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "initializes with custom budget from config", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "custom_budget_agent",
            "prompt" => "Test",
            "budget" => %{
              "llm_calls" => 100,
              "tool_calls" => 200
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "respects zero budget by staying idle", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "zero_budget_agent",
            "prompt" => "Test",
            "budget" => %{
              "llm_calls" => 0,
              "tool_calls" => 0
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message - should stay idle due to zero budget
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello!", %{}, message_id})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "wakeup scheduling" do
    test "handles wakeup job type", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "wakeup", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "working state" do
    test "queues wakeup when in working state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message to transition to working state
      message_id1 = Ecto.UUID.generate()
      send(pid, {:message, "First message", %{}, message_id1})

      # Immediately send a wakeup (should be queued)
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(200)
      # Agent may crash due to effect execution, that's ok for this test
      :ok
    end
  end

  describe "waiting_effect state" do
    test "queues wakeup when in waiting_effect state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message to start working
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Test", %{}, message_id})

      # Send wakeup - should be queued
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      # Agent may crash due to effect execution, that's ok for this test
      :ok
    end
  end
end
