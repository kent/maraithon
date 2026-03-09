defmodule Maraithon.LogBufferTest do
  use ExUnit.Case, async: false

  require Logger

  setup do
    Maraithon.LogBuffer.clear()

    on_exit(fn ->
      Maraithon.LogBuffer.clear()
    end)

    :ok
  end

  test "captures recent logger entries with metadata" do
    Logger.warning("first buffer entry")
    Logger.error("second buffer entry", request_id: "req-123", agent_id: "agent-1")
    Logger.flush()
    _ = :sys.get_state(Maraithon.LogBuffer)

    [latest, older] = Maraithon.LogBuffer.recent(2)

    assert latest.level == :error
    assert latest.message =~ "second buffer entry"
    assert latest.metadata["request_id"] == "req-123"
    assert latest.metadata["agent_id"] == "agent-1"
    assert older.message =~ "first buffer entry"
  end

  test "keeps only the configured maximum number of entries" do
    for index <- 1..520 do
      Maraithon.LogBuffer.record(%{level: :info, message: "entry-#{index}"})
    end

    _ = :sys.get_state(Maraithon.LogBuffer)

    recent = Maraithon.LogBuffer.recent(600)

    assert length(recent) == 500
    assert hd(recent).message == "entry-520"
    refute Enum.any?(recent, &(&1.message == "entry-1"))
  end
end
