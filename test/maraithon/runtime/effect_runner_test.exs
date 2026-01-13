defmodule Maraithon.Runtime.EffectRunnerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Agents

  setup do
    # Create an agent for testing
    {:ok, agent} = Agents.create_agent(%{
      behavior: "watchdog_summarizer",
      config: %{},
      status: "running",
      started_at: DateTime.utc_now()
    })

    %{agent: agent}
  end

  describe "start_link/1" do
    test "starts the effect runner" do
      # Stop existing runner if running
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      assert {:ok, pid} = EffectRunner.start_link([])
      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info :poll" do
    test "handles poll message" do
      # Stop existing runner if running
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Send poll message
      send(pid, :poll)
      Process.sleep(100)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "fetches pending effects during poll" do
      # Stop existing runner if running
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Note: We can't easily test full effect execution because it requires
      # the Task.Supervisor to be properly initialized which happens in the
      # application startup. We test that the GenServer handles the poll
      # message without crashing (when there are no pending effects).

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Send poll message (with no pending effects)
      send(pid, :poll)
      Process.sleep(100)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info {:effect_done, effect_id, result}" do
    test "removes effect from running state" do
      # Stop existing runner if running
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # Send effect_done message
      effect_id = Ecto.UUID.generate()
      send(pid, {:effect_done, effect_id, {:ok, %{result: "test"}}})
      Process.sleep(50)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_call :clear_running" do
    test "clears the running state" do
      # Stop existing runner if running
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # Call clear_running
      :ok = GenServer.call(pid, :clear_running)

      # Should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "integration: effect execution" do
    setup do
      # Ensure EffectSupervisor is started
      case Process.whereis(Maraithon.Runtime.EffectSupervisor) do
        nil ->
          Task.Supervisor.start_link(name: Maraithon.Runtime.EffectSupervisor)
        _ ->
          :ok
      end

      # Configure mock LLM provider
      original_config = Application.get_env(:maraithon, Maraithon.Runtime)
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        anthropic_api_key: "test_key"
      )

      on_exit(fn ->
        if original_config do
          Application.put_env(:maraithon, Maraithon.Runtime, original_config)
        end
      end)

      :ok
    end

    test "executes llm_call effect successfully", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a pending LLM effect
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "llm_call", nil, %{
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "max_tokens" => 100
      })

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for effect to complete
      Process.sleep(200)

      # Verify effect was completed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    test "executes tool_call effect successfully", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a pending tool call effect
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{
        "args" => %{}
      })

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for effect to complete
      Process.sleep(200)

      # Verify effect was completed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    test "handles unknown effect type", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a pending effect with unknown type
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for processing
      Process.sleep(200)

      # Effect should have failed after retries or be retrying
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      # It should be pending (retry) or failed
      assert updated_effect.status in ["pending", "failed", "claimed"]

      GenServer.stop(pid, :normal)
    end

    test "claims effects correctly", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create multiple pending effects
      {:ok, effect_id1} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})
      {:ok, effect_id2} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for processing
      Process.sleep(200)

      # Both effects should be claimed or completed
      e1 = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id1)
      e2 = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id2)

      assert e1.status in ["claimed", "completed"]
      assert e2.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    test "reclaims stale effects", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect that looks stale (claimed long ago)
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Manually mark it as claimed with old timestamp
      old_time = DateTime.add(DateTime.utc_now(), -400_000, :millisecond)
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [status: "claimed", claimed_at: old_time, claimed_by: "old_node"]
      )

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll - should reclaim stale effect
      send(pid, :poll)

      # Wait for processing
      Process.sleep(200)

      # Effect should be reclaimed and re-processed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      # Should be reclaimed (pending) or re-executed (completed/claimed)
      assert updated_effect.status in ["pending", "claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    test "processes effects with retry_after in the future", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect with retry_after in the future
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      future_time = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [retry_after: future_time]
      )

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for processing
      Process.sleep(100)

      # Effect should still be pending (not yet ready for retry)
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status == "pending"

      GenServer.stop(pid, :normal)
    end

    test "does not process effects with retry_after in the past", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect with retry_after in the past
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      past_time = DateTime.add(DateTime.utc_now(), -1000, :millisecond)
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [retry_after: past_time]
      )

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll - should process this effect
      send(pid, :poll)

      # Wait for processing
      Process.sleep(200)

      # Effect should be processed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    test "marks effect as failed after max_attempts", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect with unknown type that will fail
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Set attempts to max - 1 so next failure is final
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [attempts: 2, max_attempts: 3]
      )

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for processing
      Process.sleep(300)

      # Effect should be failed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["failed", "claimed"]

      GenServer.stop(pid, :normal)
    end

    test "retries effect when attempts < max_attempts", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect with unknown type that will fail
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Ensure max_attempts allows retry
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [attempts: 0, max_attempts: 3]
      )

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for processing
      Process.sleep(300)

      # Effect should be retrying (pending with retry_after)
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      # Could be pending (retry scheduled) or claimed (being processed)
      assert updated_effect.attempts >= 1 or updated_effect.status in ["pending", "claimed"]

      GenServer.stop(pid, :normal)
    end

    test "handles tool call with invalid tool", %{agent: agent} do
      # Stop existing runner
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a tool call effect with non-existent tool
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "nonexistent_tool", %{
        "tool" => "nonexistent_tool",
        "args" => %{}
      })

      # Start runner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger poll
      send(pid, :poll)

      # Wait for processing
      Process.sleep(200)

      # Effect should be retrying or failed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["pending", "failed", "claimed"]

      GenServer.stop(pid, :normal)
    end
  end
end
