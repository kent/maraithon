defmodule Maraithon.LocalVoiceMemos do
  @moduledoc """
  Context for macOS Voice Memos recordings synced from a user's local
  machine. Owns bulk-insert with idempotent dedupe, recent lookups, simple
  ILIKE search, and per-device purges.
  """

  import Ecto.Query

  require Logger

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalVoiceMemos.EmbedJob
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.LocalSearch
  alias Maraithon.Repo

  @max_audio_bytes 5 * 1024 * 1024

  @doc """
  Ingests a batch of voice memo maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint — re-sending the
  same payload is a no-op.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  """
  def ingest_batch(user_id, device_id, memos)
      when is_binary(user_id) and is_list(memos) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      memos
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    {inserted_count, inserted_rows} =
      if rows == [] do
        {0, []}
      else
        Repo.insert_all(LocalVoiceMemo, rows,
          on_conflict: :nothing,
          conflict_target: [:user_id, :device_id, :source, :guid],
          returning: [:id]
        )
      end

    enqueue_embed_jobs(user_id, inserted_rows)

    total = length(rows)
    duplicate_count = total - inserted_count
    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :voice_memos_ingested],
      %{
        count: length(memos),
        accepted: inserted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: inserted_count,
       duplicate: duplicate_count,
       invalid: invalid_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _memos), do: {:error, :invalid_batch}

  @doc """
  Returns the most recent voice memos for a user, newest created first.
  """
  def recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id,
        order_by: [desc: memo.created_at],
        limit: ^limit
    )
  end

  @doc """
  Searches voice memos for a user using a substring match on the encrypted
  `title` and `snippet` fields. Decrypts in memory and filters — fine for
  the small device-bounded volumes we expect today.
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 50)
    query = LocalSearch.compile(term)

    user_id
    |> recent_for_user(limit: 500)
    |> Enum.filter(&matches_term?(&1, query))
    |> Enum.take(limit)
  end

  @doc """
  Semantic search for voice memos whose title, snippet, or transcript
  are semantically similar to `query`. Pairs with `search/3`
  (substring) — use `semantic_search/3` when the user asks "find the
  memo where I talked about ..." or "that voice memo about a similar
  idea" and won't remember the exact words used.

  See `Maraithon.LocalSemanticSearch` for the in-memory ranker.
  """
  def semantic_search(user_id, query, opts \\ [])

  def semantic_search(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 12)
    pool_size = Keyword.get(opts, :pool_size, 200)

    user_id
    |> recent_for_user(limit: pool_size)
    |> Maraithon.LocalSemanticSearch.rank_by_similarity(
      query,
      &memo_text/1,
      Keyword.put(opts, :limit, limit)
    )
  end

  def semantic_search(user_id, query_vector, opts)
      when is_binary(user_id) and is_list(query_vector) and is_list(opts) do
    pgvector_semantic_search(user_id, query_vector, opts)
  end

  def semantic_search(_user_id, _query, _opts), do: []

  defp pgvector_semantic_search(user_id, query_vector, opts) do
    limit = Keyword.get(opts, :limit, 10)

    case LocalEmbeddings.semantic_search("local_voice_memos", user_id, query_vector, opts) do
      [] ->
        []

      rows ->
        ids = Enum.map(rows, fn {id, _sim} -> id end)

        memos =
          Repo.all(
            from memo in LocalVoiceMemo,
              where: memo.user_id == ^user_id and memo.id in ^ids
          )

        sim_by_id = Map.new(rows)

        memos
        |> Enum.map(fn memo -> {memo, Map.get(sim_by_id, memo.id, 0.0)} end)
        |> Enum.sort_by(fn {_memo, sim} -> -sim end)
        |> Enum.take(limit)
    end
  end

  defp memo_text(%LocalVoiceMemo{title: title, snippet: snippet, transcript: transcript}) do
    [title, snippet, transcript]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  Fetches one voice memo for a user by its source GUID. Returns `nil`
  when no matching memo exists.

  TODO: depends on server schema agent for the durable query semantics
  shared with the assistant tool surface
  (`Maraithon.Tools.VoiceMemosGet`).
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every voice memo for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from memo in LocalVoiceMemo,
          where: memo.user_id == ^user_id and memo.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  # -- internals ---------------------------------------------------------

  defp prepare_row(memo, user_id, device_id, now) when is_map(memo) do
    guid = fetch(memo, :guid)

    {audio_bytes, decoded_audio_truncated} =
      decode_audio(fetch(memo, :audio_bytes), user_id, device_id, guid)

    audio_truncated =
      decoded_audio_truncated ||
        (is_nil(audio_bytes) && truthy?(fetch(memo, :audio_truncated)))

    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(memo, :source) || "voice_memos",
      guid: guid,
      local_id: fetch(memo, :local_id),
      title: Maraithon.TextSanitize.scrub(fetch(memo, :title)),
      snippet: Maraithon.TextSanitize.scrub(fetch(memo, :snippet)),
      duration_seconds: parse_integer(fetch(memo, :duration_seconds)),
      file_size_bytes: parse_integer(fetch(memo, :file_size_bytes)),
      created_at: parse_datetime(fetch(memo, :created_at)),
      audio_bytes: audio_bytes,
      audio_truncated: audio_truncated,
      audio_mime: fetch(memo, :audio_mime) || "audio/m4a",
      transcript: Maraithon.TextSanitize.scrub(fetch(memo, :transcript)),
      transcript_engine: fetch(memo, :transcript_engine),
      transcript_lang: fetch(memo, :transcript_lang),
      encrypted_with_device_key: truthy?(fetch(memo, :encrypted_with_device_key)),
      key_id: fetch(memo, :key_id)
    }

    changeset = LocalVoiceMemo.changeset(%LocalVoiceMemo{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalVoiceMemo.__schema__(:fields)
        |> Kernel.--([:id, :inserted_at, :updated_at])
        |> Enum.into(%{}, fn field -> {field, Map.get(struct, field)} end)
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {:ok, row}
    else
      {:error, changeset}
    end
  end

  defp prepare_row(_other, _user_id, _device_id, _now), do: {:error, :invalid}

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_other), do: false

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp matches_term?(
         %LocalVoiceMemo{title: title, snippet: snippet, transcript: transcript},
         query
       ) do
    LocalSearch.matches?(query, [title, snippet, transcript])
  end

  # Accepts audio as raw binary (already decoded) or as a base64 string,
  # then caps at `@max_audio_bytes`. Oversize payloads return
  # `{nil, true}` so the caller stores `audio_truncated = true` with no
  # bytes; the server never persists more than the cap, regardless of
  # what the client uploaded. Returns `{nil, false}` when no audio was
  # provided at all.
  defp decode_audio(nil, _user_id, _device_id, _guid), do: {nil, false}
  defp decode_audio("", _user_id, _device_id, _guid), do: {nil, false}

  defp decode_audio(value, user_id, device_id, guid) when is_binary(value) do
    case maybe_decode_base64(value) do
      {:ok, bytes} -> cap_audio(bytes, user_id, device_id, guid)
      :error -> {nil, false}
    end
  end

  defp decode_audio(_other, _user_id, _device_id, _guid), do: {nil, false}

  defp maybe_decode_base64(value) do
    cond do
      # Already raw bytes: keep as-is.
      not String.printable?(value) ->
        {:ok, value}

      true ->
        case Base.decode64(value, ignore: :whitespace) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> :error
        end
    end
  end

  defp cap_audio(bytes, user_id, device_id, guid) when is_binary(bytes) do
    if byte_size(bytes) > @max_audio_bytes do
      :telemetry.execute(
        [:maraithon, :companion, :voice_memos_audio_truncated],
        %{bytes: byte_size(bytes)},
        %{user_id: user_id, device_id: device_id, guid: guid}
      )

      Logger.warning(
        "voice_memos audio over cap, storing truncated",
        user_id: user_id,
        device_id: device_id,
        guid: guid,
        bytes: byte_size(bytes),
        cap: @max_audio_bytes
      )

      {nil, true}
    else
      {bytes, false}
    end
  end

  defp enqueue_embed_jobs(_user_id, []), do: :ok

  defp enqueue_embed_jobs(user_id, inserted_rows) do
    if LocalEmbeddings.embedding_storage_available?("local_voice_memos") do
      Enum.each(inserted_rows, fn
        %{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        %LocalVoiceMemo{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        _ -> :ok
      end)
    end

    :ok
  end
end
