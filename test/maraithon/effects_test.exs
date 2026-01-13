defmodule Maraithon.EffectsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.Agents

  setup do
    {:ok, agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})
    %{agent_id: agent.id}
  end

  describe "request/5" do
    test "creates pending effect", %{agent_id: agent_id} do
      {:ok, effect_id} = Effects.request(agent_id, :tool_call, "read_file", %{path: "/tmp/test"})

      effect = Repo.get!(Effect, effect_id)
      assert effect.agent_id == agent_id
      assert effect.effect_type == "tool_call"
      assert effect.params["path"] == "/tmp/test"
      assert effect.params["tool"] == "read_file"
      assert effect.status == "pending"
    end

    test "uses provided effect_id", %{agent_id: agent_id} do
      custom_id = Ecto.UUID.generate()

      {:ok, effect_id} =
        Effects.request(agent_id, :test, nil, %{}, %{effect_id: custom_id})

      assert effect_id == custom_id
    end

    test "uses provided idempotency_key", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      {:ok, effect_id} =
        Effects.request(agent_id, :test, nil, %{}, %{idempotency_key: key})

      effect = Repo.get!(Effect, effect_id)
      assert effect.idempotency_key == key
    end

    test "does not include tool key when tool_name is nil", %{agent_id: agent_id} do
      {:ok, effect_id} = Effects.request(agent_id, :send_message, nil, %{text: "hello"})

      effect = Repo.get!(Effect, effect_id)
      refute Map.has_key?(effect.params, "tool")
      assert effect.params["text"] == "hello"
    end
  end

  describe "check_idempotency/1" do
    test "returns :not_found when no matching effect" do
      assert Effects.check_idempotency(Ecto.UUID.generate()) == :not_found
    end

    test "returns cached result for completed effect", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        idempotency_key: key,
        effect_type: "test",
        status: "completed",
        result: %{success: true}
      })
      |> Repo.insert!()

      assert {:cached, %{"success" => true}} = Effects.check_idempotency(key)
    end

    test "returns cached error for failed effect", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        idempotency_key: key,
        effect_type: "test",
        status: "failed",
        error: "Something went wrong"
      })
      |> Repo.insert!()

      assert {:cached_error, "Something went wrong"} = Effects.check_idempotency(key)
    end

    test "returns :not_found for pending effect", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        idempotency_key: key,
        effect_type: "test",
        status: "pending"
      })
      |> Repo.insert!()

      assert Effects.check_idempotency(key) == :not_found
    end
  end
end
