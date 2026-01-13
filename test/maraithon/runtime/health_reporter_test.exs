defmodule Maraithon.Runtime.HealthReporterTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Runtime.HealthReporter

  describe "start_link/1" do
    test "starts the health reporter" do
      # Stop existing reporter if running
      case Process.whereis(HealthReporter) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Start fresh
      assert {:ok, pid} = HealthReporter.start_link([])
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info/2" do
    test "handles :report message and schedules next report" do
      # Stop existing reporter if running
      case Process.whereis(HealthReporter) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = HealthReporter.start_link([])

      # Allow the GenServer process to use our database connection
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Capture log with level setting
      _log =
        capture_log([level: :info], fn ->
          # Trigger the report manually
          send(pid, :report)
          # Give it time to process
          Process.sleep(150)
        end)

      # The handler runs and schedules next report
      # Just verify the process is still alive after handling the message
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end
end
