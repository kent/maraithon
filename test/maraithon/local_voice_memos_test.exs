defmodule Maraithon.LocalVoiceMemosTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalVoiceMemos
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo

  defp sample_memo(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "v:1",
        "guid" => guid,
        "title" => "Standup recap",
        "snippet" => "transcription excerpt",
        "duration_seconds" => 64,
        "file_size_bytes" => 102_400,
        "created_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp memos_for(user_id, device_id) do
    Repo.all(
      from memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.device_id == ^device_id
    )
  end

  defp memo_count(user_id, device_id) do
    Repo.aggregate(
      from(memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "vm-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      memos =
        for i <- 1..3 do
          sample_memo("guid-#{i}", %{"title" => "memo #{i}"})
        end

      {:ok, %{accepted: 3, duplicate: 0, invalid: 0}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      stored = memos_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.device_id == device_id))
      assert Enum.all?(stored, &(&1.title in ["memo 1", "memo 2", "memo 3"]))
    end

    test "dedupes via the unique constraint on re-send" do
      user_id = "vm-dedupe-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      memos = [sample_memo("g-a"), sample_memo("g-b")]

      {:ok, %{accepted: 2, duplicate: 0}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      {:ok, %{accepted: 0, duplicate: 2}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      assert memo_count(user_id, device_id) == 2
    end

    test "applies the default source when omitted" do
      user_id = "vm-source-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1") |> Map.delete("source")
        ])

      [stored] = memos_for(user_id, device_id)
      assert stored.source == "voice_memos"
    end

    test "tolerates nil titles (Voice Memos with generated names)" do
      user_id = "vm-nil-title-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1", %{"title" => nil})
        ])

      [stored] = memos_for(user_id, device_id)
      assert is_nil(stored.title)
    end
  end

  describe "recent_for_user/2" do
    test "returns memos newest created first" do
      user_id = "vm-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1", %{
            "created_at" => "2026-05-10T10:00:00Z",
            "title" => "older"
          }),
          sample_memo("g2", %{
            "created_at" => "2026-05-10T12:00:00Z",
            "title" => "newer"
          })
        ])

      [first, second] = LocalVoiceMemos.recent_for_user(user_id)
      assert first.title == "newer"
      assert second.title == "older"
    end
  end

  describe "search/3" do
    test "matches substring on title and snippet" do
      user_id = "vm-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1", %{
            "title" => "Morning rant",
            "snippet" => "talking about coffee"
          }),
          sample_memo("g2", %{
            "title" => "Standup",
            "snippet" => "team blockers"
          })
        ])

      results = LocalVoiceMemos.search(user_id, "blockers")
      assert length(results) == 1
      assert hd(results).title == "Standup"

      results_case = LocalVoiceMemos.search(user_id, "MORNING")
      assert length(results_case) == 1
    end
  end

  describe "audio + transcript ingest (v1.5)" do
    test "stores base64-encoded audio bytes under the cap" do
      user_id = "vm-audio-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      raw = :crypto.strong_rand_bytes(2048)
      b64 = Base.encode64(raw)

      {:ok, %{accepted: 1}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g-aud", %{
            "audio_bytes" => b64,
            "audio_mime" => "audio/m4a",
            "transcript" => "hello world this is a test transcript",
            "transcript_engine" => "sf_speech",
            "transcript_lang" => "en-US"
          })
        ])

      [stored] = memos_for(user_id, device_id)
      assert stored.audio_bytes == raw
      assert stored.audio_truncated == false
      assert stored.audio_mime == "audio/m4a"
      assert stored.transcript == "hello world this is a test transcript"
      assert stored.transcript_engine == "sf_speech"
      assert stored.transcript_lang == "en-US"
    end

    test "truncates oversize audio and flags audio_truncated" do
      user_id = "vm-trunc-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      oversized = :crypto.strong_rand_bytes(5 * 1024 * 1024 + 1)
      b64 = Base.encode64(oversized)

      {:ok, %{accepted: 1}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g-big", %{"audio_bytes" => b64})
        ])

      [stored] = memos_for(user_id, device_id)
      assert is_nil(stored.audio_bytes)
      assert stored.audio_truncated == true
    end

    test "tolerates missing audio + transcript fields (backwards-compat)" do
      user_id = "vm-bc-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g-bc")
        ])

      [stored] = memos_for(user_id, device_id)
      assert is_nil(stored.audio_bytes)
      assert stored.audio_truncated == false
      assert stored.audio_mime == "audio/m4a"
      assert is_nil(stored.transcript)
    end

    test "honors an explicit truncation marker when the client omits oversize audio" do
      user_id = "vm-client-trunc-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g-client-big", %{
            "audio_bytes" => nil,
            "audio_truncated" => true,
            "file_size_bytes" => 6 * 1024 * 1024
          })
        ])

      [stored] = memos_for(user_id, device_id)
      assert is_nil(stored.audio_bytes)
      assert stored.audio_truncated == true
    end

    test "search/3 matches on transcript text" do
      user_id = "vm-tx-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g-tx1", %{
            "title" => nil,
            "snippet" => nil,
            "transcript" => "remember to ship the audio feature on friday"
          }),
          sample_memo("g-tx2", %{
            "title" => nil,
            "snippet" => nil,
            "transcript" => "groceries: milk, eggs, bread"
          })
        ])

      results = LocalVoiceMemos.search(user_id, "friday")
      assert length(results) == 1
      assert hd(results).guid == "g-tx1"
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "vm-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1"),
          sample_memo("g2")
        ])

      assert memo_count(user_id, device_id) == 2

      {:ok, %{deleted: 2}} = LocalVoiceMemos.purge_device(user_id, device_id)

      assert memo_count(user_id, device_id) == 0
    end
  end
end
