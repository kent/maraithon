defmodule Maraithon.Crm.IngestTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Ingest.WindowPolicy
  alias Maraithon.Crm.Observation
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  setup do
    user_id = "ingest-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  describe "observe/2" do
    test "persists an observation, upserts a person, bumps counters, opens a window",
         %{user_id: user_id} do
      changeset = sample_changeset(user_id, "msg-1", "charlie@example.com", "Charlie")

      assert {:ok, :buffered, observation_id} = Ingest.observe(user_id, changeset)
      observation = Repo.get!(Observation, observation_id)

      assert observation.user_id == user_id
      assert observation.source == "gmail"
      assert observation.window_id != nil
      assert length(observation.resolved_person_ids) == 1
      [person_id] = observation.resolved_person_ids

      person = Crm.get_person_for_user(user_id, person_id)
      assert person.display_name == "Charlie"
      assert person.contact_details["emails"] == ["charlie@example.com"]
      assert person.interaction_count == 1
      assert person.last_interaction_at != nil

      window = Repo.get!(Window, observation.window_id)
      assert window.status == "open"
      assert window.observation_count == 1

      refute Repo.exists?(
               from j in BackgroundJob,
                 where: j.dedupe_key == ^"crm_ingest:flush:#{window.id}"
             )
    end

    test "duplicate (user_id, source, source_item_id) is a no-op", %{user_id: user_id} do
      changeset_one = sample_changeset(user_id, "msg-dup", "dana@example.com", "Dana")
      changeset_two = sample_changeset(user_id, "msg-dup", "dana@example.com", "Dana")

      assert {:ok, :buffered, _id} = Ingest.observe(user_id, changeset_one)
      assert {:ok, :duplicate} = Ingest.observe(user_id, changeset_two)

      assert Repo.aggregate(Observation, :count, :id) == 1
    end

    test "concurrent duplicate observations converge without a constraint error", %{
      user_id: user_id
    } do
      sandbox_owner = self()

      results =
        1..2
        |> Task.async_stream(
          fn _attempt ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, sandbox_owner, self())

            Ingest.observe(
              user_id,
              sample_changeset(user_id, "msg-race", "riley@example.com", "Riley")
            )
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, :buffered, _id}, &1)) == 1
      assert Enum.count(results, &match?({:ok, :duplicate}, &1)) == 1
      assert Repo.aggregate(Observation, :count, :id) == 1
    end

    test "concurrent distinct observations share one open source window", %{
      user_id: user_id
    } do
      sandbox_owner = self()

      results =
        1..4
        |> Task.async_stream(
          fn index ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, sandbox_owner, self())

            Ingest.observe(
              user_id,
              sample_changeset(
                user_id,
                "window-race-#{index}",
                "window-race-#{index}@example.com",
                "Window Race #{index}"
              )
            )
          end,
          max_concurrency: 4,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, :buffered, _id}, &1))

      assert [%Window{observation_count: 4}] =
               Repo.all(
                 from w in Window,
                   where: w.user_id == ^user_id and w.source == "gmail" and w.status == "open"
               )
    end

    test "size threshold flushes the window and enqueues exactly one job",
         %{user_id: user_id} do
      threshold = WindowPolicy.max_observations()

      results =
        for i <- 1..threshold do
          changeset =
            sample_changeset(
              user_id,
              "size-#{i}",
              "person-#{i}@example.com",
              "Person #{i}"
            )

          Ingest.observe(user_id, changeset)
        end

      buffered_count = Enum.count(results, &match?({:ok, :buffered, _}, &1))
      flushed_count = Enum.count(results, &match?({:ok, :flushed, _, _}, &1))

      assert buffered_count == threshold - 1
      assert flushed_count == 1

      assert [job] = relationship_ingestion_jobs(user_id)
      assert job.job_type == "relationship_ingestion"
      assert job.queue == "relationships"
      assert is_binary(job.payload["window_id"])

      window = Repo.get!(Window, job.payload["window_id"])
      assert window.status == "flushed"
      assert window.flushed_at != nil
      assert window.flush_job_id == job.id
    end
  end

  describe "flush_pending/2" do
    test "flushes any open window with observations", %{user_id: user_id} do
      Ingest.observe(user_id, sample_changeset(user_id, "f-1", "a@example.com", "A"))
      Ingest.observe(user_id, sample_changeset(user_id, "f-2", "b@example.com", "B"))

      assert {:ok, :flushed, _job_id} = Ingest.flush_pending(user_id, "gmail")

      assert [%BackgroundJob{job_type: "relationship_ingestion"}] =
               relationship_ingestion_jobs(user_id)
    end

    test "is a no-op when there is no open window", %{user_id: user_id} do
      assert {:ok, :nothing_to_flush} = Ingest.flush_pending(user_id, "gmail")
      assert relationship_ingestion_job_count(user_id) == 0
    end
  end

  describe "sweep_stale_windows/1" do
    test "force-flushes open windows older than the stale threshold", %{user_id: user_id} do
      assert {:ok, :buffered, _id} =
               Ingest.observe(
                 user_id,
                 sample_changeset(user_id, "s-1", "stale@example.com", "Stale")
               )

      window =
        Repo.one(
          from w in Window,
            where: w.user_id == ^user_id and w.source == "gmail" and w.status == "open"
        )

      old_opened_at =
        DateTime.add(DateTime.utc_now(), -(Ingest.stale_window_minutes() + 5) * 60, :second)

      Repo.update_all(from(w in Window, where: w.id == ^window.id),
        set: [opened_at: old_opened_at]
      )

      assert {:ok, 1} = Ingest.sweep_stale_windows()

      reloaded = Repo.get!(Window, window.id)
      assert reloaded.status == "flushed"

      assert [%BackgroundJob{job_type: "relationship_ingestion"}] =
               relationship_ingestion_jobs(user_id)
    end

    test "leaves fresh windows alone", %{user_id: user_id} do
      Ingest.observe(user_id, sample_changeset(user_id, "fr-1", "fresh@example.com", "Fresh"))

      assert {:ok, 0} = Ingest.sweep_stale_windows()
      assert relationship_ingestion_job_count(user_id) == 0
    end
  end

  defp sample_changeset(user_id, source_item_id, email, display_name) do
    Observation.new(%{
      "user_id" => user_id,
      "source" => "gmail",
      "source_account" => "primary",
      "source_item_id" => source_item_id,
      "occurred_at" => DateTime.utc_now(),
      "direction" => "inbound",
      "participants" => [
        %{
          "role" => "from",
          "identifier" => %{"email" => email},
          "display_name" => display_name
        }
      ],
      "subject" => "Hello from #{display_name}",
      "excerpt" => "Hi Kent, just checking in."
    })
  end

  defp relationship_ingestion_jobs(user_id) do
    Repo.all(
      from j in BackgroundJob,
        where: j.user_id == ^user_id and j.job_type == "relationship_ingestion",
        order_by: [asc: j.inserted_at]
    )
  end

  defp relationship_ingestion_job_count(user_id) do
    Repo.aggregate(
      from(j in BackgroundJob,
        where: j.user_id == ^user_id and j.job_type == "relationship_ingestion"
      ),
      :count,
      :id
    )
  end
end
