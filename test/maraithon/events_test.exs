defmodule Maraithon.EventsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Events
  alias Maraithon.Agents

  setup do
    {:ok, agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})
    %{agent_id: agent.id}
  end

  describe "append/4" do
    test "creates event with auto-incrementing sequence number", %{agent_id: agent_id} do
      {:ok, event1} = Events.append(agent_id, "initialized", %{foo: "bar"})
      {:ok, event2} = Events.append(agent_id, "processed", %{baz: "qux"})

      assert event1.sequence_num == 1
      assert event2.sequence_num == 2
    end

    test "creates event with provided sequence number", %{agent_id: agent_id} do
      {:ok, event} = Events.append(agent_id, "test", %{}, sequence_num: 42)

      assert event.sequence_num == 42
    end

    test "creates event with idempotency key", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()
      {:ok, event} = Events.append(agent_id, "test", %{}, idempotency_key: key)

      assert event.idempotency_key == key
    end
  end

  describe "list_events/2" do
    setup %{agent_id: agent_id} do
      Events.append(agent_id, "event1", %{data: 1})
      Events.append(agent_id, "event2", %{data: 2})
      Events.append(agent_id, "event1", %{data: 3})
      :ok
    end

    test "lists all events for agent", %{agent_id: agent_id} do
      events = Events.list_events(agent_id)

      assert length(events) == 3
      assert Enum.map(events, & &1.sequence_num) == [1, 2, 3]
    end

    test "filters by after_seq", %{agent_id: agent_id} do
      events = Events.list_events(agent_id, after_seq: 1)

      assert length(events) == 2
      assert hd(events).sequence_num == 2
    end

    test "limits results", %{agent_id: agent_id} do
      events = Events.list_events(agent_id, limit: 2)

      assert length(events) == 2
    end

    test "filters by event types", %{agent_id: agent_id} do
      events = Events.list_events(agent_id, types: ["event1"])

      assert length(events) == 2
      assert Enum.all?(events, &(&1.event_type == "event1"))
    end

    test "returns formatted events", %{agent_id: agent_id} do
      [event | _] = Events.list_events(agent_id)

      assert Map.has_key?(event, :id)
      assert Map.has_key?(event, :sequence_num)
      assert Map.has_key?(event, :event_type)
      assert Map.has_key?(event, :payload)
      assert Map.has_key?(event, :created_at)
    end
  end

  describe "latest_sequence_num/1" do
    test "returns 0 when no events", _context do
      # Use a different agent to test empty state
      {:ok, new_agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})

      assert Events.latest_sequence_num(new_agent.id) == 0
    end

    test "returns latest sequence number", %{agent_id: agent_id} do
      Events.append(agent_id, "event1", %{})
      Events.append(agent_id, "event2", %{})
      Events.append(agent_id, "event3", %{})

      assert Events.latest_sequence_num(agent_id) == 3
    end
  end

  describe "get_events_after/2" do
    test "returns events after sequence number", %{agent_id: agent_id} do
      Events.append(agent_id, "event1", %{})
      Events.append(agent_id, "event2", %{})
      Events.append(agent_id, "event3", %{})

      events = Events.get_events_after(agent_id, 1)

      assert length(events) == 2
      sequence_nums = Enum.map(events, & &1.sequence_num)
      assert sequence_nums == [2, 3]
    end

    test "returns empty list when no events after", %{agent_id: agent_id} do
      Events.append(agent_id, "event1", %{})

      events = Events.get_events_after(agent_id, 1)

      assert events == []
    end
  end
end
