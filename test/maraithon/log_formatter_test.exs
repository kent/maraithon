defmodule Maraithon.LogFormatterTest do
  use ExUnit.Case, async: true

  alias Maraithon.LogFormatter

  describe "format/4" do
    test "formats log entry as JSON" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 123_456}}
      metadata = []

      result = LogFormatter.format(:info, "Test message", timestamp, metadata)

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      assert decoded["severity"] == "INFO"
      assert decoded["message"] == "Test message"
      assert decoded["timestamp"] =~ "2024-01-15T12:30:45"
    end

    test "maps log levels to Cloud Logging severity" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}

      assert get_severity(:debug, timestamp) == "DEBUG"
      assert get_severity(:info, timestamp) == "INFO"
      assert get_severity(:warn, timestamp) == "WARNING"
      assert get_severity(:warning, timestamp) == "WARNING"
      assert get_severity(:error, timestamp) == "ERROR"
    end

    test "includes optional metadata fields" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}
      metadata = [request_id: "req-123", agent_id: "agent-456"]

      result = LogFormatter.format(:info, "Test", timestamp, metadata)

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      assert decoded["request_id"] == "req-123"
      assert decoded["agent_id"] == "agent-456"
    end

    test "includes module/function/line labels" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}
      metadata = [module: MyModule, function: :test, line: 42]

      result = LogFormatter.format(:info, "Test", timestamp, metadata)

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      labels = decoded["logging.googleapis.com/labels"]
      assert labels["module"] == "Elixir.MyModule"
      assert labels["function"] == "test"
      assert labels["line"] == "42"
    end

    test "handles iodata messages" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}

      result = LogFormatter.format(:info, ["Hello", " ", "World"], timestamp, [])

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      assert decoded["message"] == "Hello World"
    end
  end

  defp get_severity(level, timestamp) do
    result = LogFormatter.format(level, "Test", timestamp, [])
    json = result |> IO.iodata_to_binary() |> String.trim()
    decoded = Jason.decode!(json)
    decoded["severity"]
  end
end
