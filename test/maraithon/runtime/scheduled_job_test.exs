defmodule Maraithon.Runtime.ScheduledJobTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.ScheduledJob

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        job_type: "timer",
        fire_at: DateTime.utc_now()
      }

      changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)

      assert changeset.valid?
    end

    test "valid changeset with all fields" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        job_type: "timer",
        fire_at: DateTime.utc_now(),
        payload: %{message: "hello"},
        status: "delivered",
        delivered_at: DateTime.utc_now()
      }

      changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)

      assert changeset.valid?
    end

    test "requires agent_id" do
      attrs = %{
        job_type: "timer",
        fire_at: DateTime.utc_now()
      }

      changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)

      refute changeset.valid?
      assert %{agent_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires job_type" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        fire_at: DateTime.utc_now()
      }

      changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)

      refute changeset.valid?
      assert %{job_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires fire_at" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        job_type: "timer"
      }

      changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)

      refute changeset.valid?
      assert %{fire_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status values" do
      valid_statuses = ["pending", "delivered", "cancelled"]

      for status <- valid_statuses do
        attrs = %{
          agent_id: Ecto.UUID.generate(),
          job_type: "timer",
          fire_at: DateTime.utc_now(),
          status: status
        }

        changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)
        assert changeset.valid?, "Status #{status} should be valid"
      end
    end

    test "rejects invalid status" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        job_type: "timer",
        fire_at: DateTime.utc_now(),
        status: "invalid"
      }

      changeset = ScheduledJob.changeset(%ScheduledJob{}, attrs)

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
