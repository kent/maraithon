defmodule Maraithon.Crm.Ingest do
  @moduledoc """
  Synchronous funnel for source events that should update CRM state.

  Adapters (Gmail, Calendar, Slack) build a `Crm.Observation` changeset from
  their normalized webhook or pull payload, then call `observe/2` here.

  This module is intentionally a thin, deterministic layer:

    * dedupe by `(user_id, source, source_item_id)` so duplicate Pub/Sub
      replays or pull-overlapping-with-webhook collapse to a no-op,
    * resolve participants into `Crm.Person` rows and bump interaction
      counters via `Crm.resolve_contact/3` and `Crm.bump_interaction/3`,
    * attach the observation to the user's open `Crm.Ingest.Window` for
      the source, opening one if needed,
    * ask `Crm.Ingest.WindowPolicy` whether the window is ready, and on
      a guarded `open -> flushed` transition enqueue a single
      `relationship_ingestion` background job.

  All semantic decisions (relationship facts, todo creates, nudge
  candidates) live in the `relationship_ingestion` handler downstream;
  nothing here calls the model.
  """

  import Ecto.Query

  alias Maraithon.Accounts
  alias Ecto.Multi
  alias Maraithon.Crm
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Ingest.WindowPolicy
  alias Maraithon.Crm.Observation
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  require Logger

  @stale_window_minutes 30
  @open_window_conflict_target "(user_id, source) WHERE status = 'open'"

  @type observe_result ::
          {:ok, :duplicate}
          | {:ok, :buffered, observation_id :: String.t()}
          | {:ok, :flushed, observation_id :: String.t(), job_id :: String.t()}
          | {:error, term()}

  @doc """
  Persist an observation, update synchronous CRM state, and possibly flush.

  `changeset` is the result of `Crm.Observation.new/1` from a source adapter.
  """
  @spec observe(String.t(), Ecto.Changeset.t() | Observation.t()) :: observe_result()
  def observe(user_id, %Ecto.Changeset{} = changeset) when is_binary(user_id) do
    changeset = Ecto.Changeset.put_change(changeset, :user_id, user_id)

    case insert_observation(changeset) do
      {:ok, %Observation{} = obs} ->
        finalize_observation(user_id, obs)

      {:duplicate, _} ->
        {:ok, :duplicate}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def observe(user_id, %Observation{} = obs) when is_binary(user_id) do
    observe(user_id, Observation.changeset(obs, %{}))
  end

  def observe(_user_id, _input), do: {:error, :invalid_input}

  @doc """
  Force any open window for `(user_id, source)` to flush, regardless of size.

  Called by pull-driven adapters after they finish a sweep, and by the
  backfill handler after each page. Returns `{:ok, :nothing_to_flush}` when
  there is no open window or the open window has zero observations.
  """
  @spec flush_pending(String.t(), String.t()) ::
          {:ok, :flushed, String.t()}
          | {:ok, :nothing_to_flush}
          | {:ok, :already_flushed}
          | {:error, term()}
  def flush_pending(user_id, source) when is_binary(user_id) and is_binary(source) do
    case open_window(user_id, source) do
      nil ->
        {:ok, :nothing_to_flush}

      %Window{observation_count: 0} ->
        {:ok, :nothing_to_flush}

      %Window{} = window ->
        case guarded_flush(window) do
          {1, _} -> enqueue_flush(window)
          {0, _} -> {:ok, :already_flushed}
        end
    end
  end

  def flush_pending(_user_id, _source), do: {:error, :invalid_input}

  @doc """
  Force-flush any open window older than `@stale_window_minutes`.

  Designed to be called from `BackgroundJobRunner`'s reclaim tick. Returns
  the number of windows force-flushed.
  """
  @spec sweep_stale_windows(DateTime.t()) :: {:ok, non_neg_integer()}
  def sweep_stale_windows(now \\ DateTime.utc_now())

  def sweep_stale_windows(%DateTime{} = now) do
    sweep_windows_older_than(now, @stale_window_minutes * 60)
  end

  @doc "Force-flush open windows older than a caller-selected bounded age."
  def sweep_windows_older_than(%DateTime{} = now, age_seconds)
      when is_integer(age_seconds) and age_seconds > 0 do
    cutoff = DateTime.add(now, -age_seconds, :second)

    stale =
      from(w in Window,
        where: w.status == "open",
        where: w.observation_count > 0,
        where: w.opened_at < ^cutoff
      )
      |> Repo.all()

    flushed =
      Enum.reduce(stale, 0, fn window, acc ->
        case guarded_flush(window) do
          {1, _} ->
            case enqueue_flush(window) do
              {:ok, :flushed, _job_id} -> acc + 1
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    {:ok, flushed}
  end

  @doc """
  Enqueue a one-shot bounded backfill chain for a user/source.

  See `Maraithon.Runtime.BackgroundJobs.enqueue_relationship_backfill/3`.
  """
  def enqueue_backfill(user_id, source, opts \\ [])
      when is_binary(user_id) and is_binary(source) do
    BackgroundJobs.enqueue_relationship_backfill(user_id, source, opts)
  end

  def stale_window_minutes, do: @stale_window_minutes

  ## ---------- internals ----------

  defp insert_observation(changeset) do
    user_id = Ecto.Changeset.get_field(changeset, :user_id)
    source = Ecto.Changeset.get_field(changeset, :source)
    source_item_id = Ecto.Changeset.get_field(changeset, :source_item_id)

    case Repo.get_by(Observation,
           user_id: user_id,
           source: source,
           source_item_id: source_item_id
         ) do
      %Observation{} = existing ->
        {:duplicate, existing}

      nil ->
        proposed_id = Ecto.Changeset.get_field(changeset, :id) || Ecto.UUID.generate()
        changeset = Ecto.Changeset.put_change(changeset, :id, proposed_id)

        case Repo.insert(changeset,
               on_conflict: [set: [source_item_id: source_item_id]],
               conflict_target: [:user_id, :source, :source_item_id],
               returning: true
             ) do
          {:ok, %Observation{id: ^proposed_id} = obs} ->
            {:ok, obs}

          {:ok, %Observation{} = obs} ->
            {:duplicate, obs}

          {:error, %Ecto.Changeset{} = invalid} ->
            {:error, invalid}
        end
    end
  end

  defp finalize_observation(user_id, %Observation{} = obs) do
    person_ids = resolve_participants(user_id, obs)
    bump_counters(person_ids, obs.occurred_at, obs.source)

    if person_ids != [] do
      Repo.update_all(
        from(o in Observation, where: o.id == ^obs.id),
        set: [resolved_person_ids: person_ids, updated_at: DateTime.utc_now()]
      )
    end

    case attach_to_window(user_id, obs) do
      {:ok, window} ->
        decide_flush(obs, window)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_participants(user_id, %Observation{participants: participants}) do
    participants = participants || []

    participants
    |> Enum.flat_map(&participant_to_identifiers/1)
    |> Enum.uniq()
    |> Enum.reduce([], fn {identifier, display_name}, acc ->
      case Crm.resolve_contact(user_id, identifier, display_name: display_name) do
        {:ok, person} -> [person.id | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @identifier_kinds ~w(email slack_id phone phone_number telegram_id)

  defp participant_to_identifiers(%{} = participant) do
    identifier_map =
      participant
      |> stringify_keys()
      |> Map.get("identifier", %{})
      |> case do
        m when is_map(m) -> stringify_keys(m)
        _ -> %{}
      end

    display_name =
      Map.get(participant, "display_name") || Map.get(participant, :display_name)

    identifier_map
    |> Map.take(@identifier_kinds)
    |> Enum.flat_map(fn
      {kind, value} when is_binary(value) and value != "" ->
        [{%{kind_to_atom(kind) => value}, display_name}]

      _ ->
        []
    end)
  end

  defp participant_to_identifiers(_), do: []

  defp kind_to_atom("email"), do: :email
  defp kind_to_atom("slack_id"), do: :slack_id
  defp kind_to_atom("phone"), do: :phone
  defp kind_to_atom("phone_number"), do: :phone
  defp kind_to_atom("telegram_id"), do: :telegram_id

  defp bump_counters(person_ids, occurred_at, source) do
    Enum.each(person_ids, fn person_id ->
      _ = Crm.bump_interaction(person_id, occurred_at, source)
    end)
  end

  defp attach_to_window(user_id, %Observation{} = obs) do
    Multi.new()
    |> Multi.run(:window, fn _repo, _changes ->
      ensure_open_window(user_id, obs.source)
    end)
    |> Multi.run(:link_observation, fn _repo, %{window: window} ->
      {1, _} =
        Repo.update_all(
          from(o in Observation, where: o.id == ^obs.id),
          set: [window_id: window.id, updated_at: DateTime.utc_now()]
        )

      {1, _} =
        Repo.update_all(
          from(w in Window, where: w.id == ^window.id),
          inc: [observation_count: 1],
          set: [updated_at: DateTime.utc_now()]
        )

      {:ok, Repo.get!(Window, window.id)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{link_observation: window}} -> {:ok, window}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp ensure_open_window(user_id, source) do
    case open_window_for_update(user_id, source) do
      %Window{} = existing ->
        {:ok, existing}

      nil ->
        now = DateTime.utc_now()

        %Window{}
        |> Window.changeset(%{
          "user_id" => user_id,
          "source" => source,
          "status" => "open",
          "opened_at" => now,
          "observation_count" => 0
        })
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: {:unsafe_fragment, @open_window_conflict_target}
        )
        |> case do
          {:ok, %Window{}} ->
            # `ON CONFLICT DO NOTHING` keeps the surrounding Ecto.Multi
            # transaction usable when another observation creates the same
            # partial-index row first. Always re-read the authoritative row:
            # on conflict Ecto may return the proposed struct even though that
            # id was not inserted.
            case open_window_for_update(user_id, source) do
              %Window{} = window -> {:ok, window}
              nil -> {:error, :open_window_missing}
            end

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, changeset}
        end
    end
  end

  defp open_window_for_update(user_id, source) do
    Repo.one(
      from(w in Window,
        where: w.user_id == ^user_id and w.source == ^source and w.status == "open",
        lock: "FOR UPDATE",
        limit: 1
      )
    )
  end

  defp open_window(user_id, source) do
    Repo.one(
      from(w in Window,
        where: w.user_id == ^user_id and w.source == ^source and w.status == "open",
        limit: 1
      )
    )
  end

  defp decide_flush(%Observation{} = obs, %Window{} = window) do
    flush_count = recent_flush_count(window.user_id, window.source)

    if WindowPolicy.ready?(window, DateTime.utc_now(), flush_count, false) do
      case guarded_flush(window) do
        {1, _} ->
          case enqueue_flush(window) do
            {:ok, :flushed, job_id} -> {:ok, :flushed, obs.id, job_id}
            {:error, reason} -> {:error, reason}
          end

        {0, _} ->
          {:ok, :buffered, obs.id}
      end
    else
      {:ok, :buffered, obs.id}
    end
  end

  defp guarded_flush(%Window{} = window) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(w in Window,
        where: w.id == ^window.id,
        where: w.status == "open",
        select: w
      ),
      set: [status: "flushed", flushed_at: now, updated_at: now]
    )
  end

  defp enqueue_flush(%Window{} = window) do
    if RuntimeConfig.multinode_coordination_enabled?() do
      case BackgroundJobs.enqueue_relationship_ingestion(
             window.id,
             existing_user_id(window.user_id)
           ) do
        {:ok, job} ->
          Repo.update_all(
            from(w in Window, where: w.id == ^window.id),
            set: [flush_job_id: job.id, updated_at: DateTime.utc_now()]
          )

          {:ok, :flushed, job.id}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, :flushed, nil}
    end
  end

  defp existing_user_id(user_id) when is_binary(user_id) do
    if Accounts.get_user(user_id), do: user_id
  end

  defp existing_user_id(_user_id), do: nil

  defp recent_flush_count(user_id, source) do
    cutoff = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.aggregate(
      from(w in Window,
        where: w.user_id == ^user_id,
        where: w.source == ^source,
        where: w.flushed_at >= ^cutoff
      ),
      :count
    )
  end

  defp stringify_keys(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(value), do: value
end
