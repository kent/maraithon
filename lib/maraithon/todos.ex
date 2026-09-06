defmodule Maraithon.Todos do
  @moduledoc """
  Context for user-scoped todo items managed by conversational operators.
  """

  import Ecto.Query

  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Insights.Insight
  alias Maraithon.LLM.Embeddings
  alias Maraithon.LocalEmbeddings
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects.Project
  alias Maraithon.Repo
  alias Maraithon.Timezones

  alias Maraithon.Todos.{
    ActionDrafts,
    ActivityEvent,
    AttentionRanker,
    Brief,
    CounterpartyResolver,
    DecisionSignals,
    Intelligence,
    OutcomeLearning,
    SignalGate,
    SurfaceQuality
  }

  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Todos.Todo

  require Logger

  @open_statuses ~w(open snoozed)
  @feedback_values ~w(helpful not_helpful)
  @fallback_title "Review open work"
  @fallback_summary "This saved open work needs a keep, delegate, or dismiss decision."
  @fallback_action "Open the source context, confirm the request, then keep, delegate, or dismiss it."

  # SPEC 05: direction enum + legacy metadata vocabulary mapping. The writer
  # prompt (intelligence.ex, commitment_tracker.ex) and any legacy synced
  # records may still emit the old commitment_direction/thread_state values;
  # this is the single place that normalizes them onto the `direction` column.
  @directions ~w(owed_by_me owed_to_me fyi)
  @owed_by_me_legacy ~w(i_owe asked_of_me)
  @owed_to_me_legacy ~w(pending_reply user_owes waiting_on_user waiting_on_me waiting_on_kent)

  @embedding_table "todos"

  def get_for_user(user_id, todo_id)
      when is_binary(user_id) and is_binary(todo_id) do
    Todo
    |> Repo.get_by(id: todo_id, user_id: user_id)
    |> polish_todo_copy()
  end

  def get_for_user(_user_id, _todo_id), do: nil

  @doc "Records the first explicit human detail view for outcome learning."
  def record_user_opened(user_id, todo_id, opts \\ []) do
    OutcomeLearning.record_user_opened(user_id, todo_id, opts)
  end

  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = normalize_limit(Keyword.get(opts, :limit, 20), 20)
    page_offset = normalize_offset(Keyword.get(opts, :offset, 0))
    sort_by = normalize_sort_by(Keyword.get(opts, :sort_by, "rank"))
    sort_dir = normalize_sort_dir(Keyword.get(opts, :sort_dir, "desc"))
    decision_only? = decision_only_option?(opts)

    # Offset applies after order_by so pages are stable within one sort pass.
    # The default "updated desc" sort shifts under concurrent writes — that's
    # accepted; paging clients reconcile by id.
    query =
      user_id
      |> filtered_todo_query(opts)
      |> maybe_filter_decision_only(decision_only?)
      |> apply_todo_order(sort_by, sort_dir)
      |> order_by([todo], asc: todo.id)

    if decision_only? do
      # The SQL predicate is only a broad candidate filter. Apply the exact
      # decision predicate before slicing so offsets count actual decisions,
      # not candidates that are discarded after the query.
      query
      |> exact_decision_todos()
      |> Enum.drop(page_offset)
      |> Enum.take(limit)
    else
      query
      |> offset(^page_offset)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&polish_todo_copy/1)
    end
  end

  @doc "Returns up to three actionable Critical todos for a mobile reminder."
  def list_critical_for_push(user_id) when is_binary(user_id) do
    # Match the mobile app's Critical band (90+) and its actionable work,
    # not monitoring, waiting-on, hidden, completed, or still-snoozed items.
    user_id
    |> filtered_todo_query(
      statuses: ["open", "snoozed"],
      open_due_only: true,
      attention_mode: "act_now",
      direction: "owed_by_me",
      owner_user_id: user_id
    )
    |> where([todo], todo.priority >= 90)
    |> order_by([todo], desc: todo.priority, asc_nulls_last: todo.due_at, asc: todo.id)
    |> limit(3)
    |> Repo.all()
    |> Enum.map(&polish_todo_copy/1)
  end

  @doc "Returns filtered todo ids in the same deterministic order as list_for_user/2."
  def list_ids_for_user(user_id, opts \\ []) when is_binary(user_id) do
    sort_by = normalize_sort_by(Keyword.get(opts, :sort_by, "rank"))
    sort_dir = normalize_sort_dir(Keyword.get(opts, :sort_dir, "desc"))
    decision_only? = decision_only_option?(opts)

    query =
      user_id
      |> filtered_todo_query(opts)
      |> maybe_filter_decision_only(decision_only?)
      |> apply_todo_order(sort_by, sort_dir)
      |> order_by([todo], asc: todo.id)

    if decision_only? do
      query
      |> exact_decision_todos()
      |> Enum.map(& &1.id)
    else
      query
      |> select([todo], todo.id)
      |> Repo.all()
    end
  end

  @doc """
  Cheap collection version for conditional GETs: one aggregate over ALL the
  user's todos regardless of status or filters. Coarse on purpose — any todo
  insert, update, or delete invalidates every filtered mobile view. Card
  projections derived from other tables may lag until some todo row changes;
  that's accepted.
  """
  def collection_version(user_id) when is_binary(user_id) do
    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> select([todo], {count(todo.id), max(todo.updated_at)})
    |> Repo.one()
  end

  def count_for_user(user_id, opts \\ []) when is_binary(user_id) do
    decision_only? = decision_only_option?(opts)

    query =
      user_id
      |> filtered_todo_query(opts)
      |> maybe_filter_decision_only(decision_only?)
      |> exclude(:order_by)

    if decision_only? do
      # `maybe_filter_decision_only/2` is intentionally a broad SQL-level
      # superset (see its docstring); the precise "does this actually need a
      # decision" call happens here via DecisionSignals, same as list_for_user.
      query
      |> exact_decision_todos()
      |> length()
    else
      query
      |> select([todo], count(todo.id))
      |> Repo.one()
    end
  end

  def list_open_for_user(user_id, opts \\ []) when is_binary(user_id) do
    opts =
      opts
      |> Keyword.put_new(:statuses, @open_statuses)
      |> Keyword.put(:open_due_only, true)

    list_for_user(user_id, opts)
  end

  @doc """
  Open todos where someone else owes the operator (`direction: "owed_to_me"`),
  ordered by due date then priority. Answers "who am I waiting on?".

  Pass `person_id: crm_person_id` (alias `:counterparty_person_id`) to scope
  to one counterparty — "what is Charlie waiting on from me?" as a SQL filter.
  """
  def list_owed_to_me(user_id, opts \\ [])

  def list_owed_to_me(user_id, opts) when is_binary(user_id) and is_list(opts) do
    opts
    |> Keyword.put(:direction, "owed_to_me")
    |> Keyword.put_new(:sort_by, "due")
    |> then(&list_open_for_user(user_id, &1))
  end

  def list_owed_to_me(_user_id, _opts), do: []

  @doc """
  Open todos the operator owes someone else (`direction: "owed_by_me"`),
  ordered by due date then priority. Answers "what do I owe?".

  Pass `person_id: crm_person_id` (alias `:counterparty_person_id`) to scope
  to one counterparty — "what do I owe Charlie?" as a SQL filter.
  """
  def list_owed_by_me(user_id, opts \\ [])

  def list_owed_by_me(user_id, opts) when is_binary(user_id) and is_list(opts) do
    opts
    |> Keyword.put(:direction, "owed_by_me")
    |> Keyword.put_new(:sort_by, "due")
    |> then(&list_open_for_user(user_id, &1))
  end

  def list_owed_by_me(_user_id, _opts), do: []

  def list_recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 40)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> order_by([todo], desc: todo.updated_at, desc: todo.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&polish_todo_copy/1)
  end

  def list_activity_for_user(user_id, opts \\ [])

  def list_activity_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit =
      opts
      |> Keyword.get(:limit, 50)
      |> normalize_limit(50)
      |> min(200)

    ActivityEvent
    |> where([event], event.user_id == ^user_id)
    |> maybe_filter_activity_event_type(Keyword.get(opts, :event_type))
    |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_activity_for_user(_user_id, _opts), do: []

  defp maybe_filter_activity_event_type(query, nil), do: query

  defp maybe_filter_activity_event_type(query, event_type)
       when event_type in ["created", "deleted", "marked_done"] do
    where(query, [event], event.event_type == ^event_type)
  end

  defp maybe_filter_activity_event_type(query, _invalid), do: where(query, [event], false)

  def list_by_ids(user_id, todo_ids, opts \\ [])

  def list_by_ids(user_id, todo_ids, opts)
      when is_binary(user_id) and is_list(todo_ids) do
    ids =
      todo_ids
      |> Enum.flat_map(&cast_todo_id/1)
      |> Enum.uniq()

    if ids == [] do
      []
    else
      statuses = normalize_status_filters(Keyword.get(opts, :statuses))
      open_due_only? = Keyword.get(opts, :open_due_only, false)
      order = Map.new(Enum.with_index(ids))

      Todo
      |> where([todo], todo.user_id == ^user_id and todo.id in ^ids)
      |> maybe_filter_statuses(statuses)
      |> maybe_filter_open_due_only(open_due_only?)
      |> Repo.all()
      |> Enum.sort_by(fn todo -> Map.get(order, todo.id, map_size(order)) end)
      |> Enum.map(&polish_todo_copy/1)
    end
  end

  def list_by_ids(_user_id, _todo_ids, _opts), do: []

  defp cast_todo_id(value) when is_binary(value) do
    value = String.trim(value)

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  defp cast_todo_id(_value), do: []

  defp polish_todo_copy(%Todo{} = todo), do: UserFacingCopy.polish_attrs(todo)
  defp polish_todo_copy(other), do: other

  defp enqueue_brief(%Todo{} = todo) do
    case Brief.enqueue_generation(todo) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("todo brief enqueue failed", todo_id: todo.id, reason: inspect(reason))
        :ok
    end
  end

  def sync_many_from_insights(insights) when is_list(insights) do
    insights
    |> Enum.reduce({:ok, []}, fn
      %Insight{} = insight, {:ok, acc} ->
        case sync_from_insight(insight) do
          {:ok, %Todo{} = todo} -> {:ok, [todo | acc]}
          {:ok, nil} -> {:ok, acc}
          {:error, reason} -> {:error, reason}
        end

      _other, {:ok, acc} ->
        {:ok, acc}
    end)
    |> case do
      {:ok, todos} -> {:ok, Enum.reverse(todos)}
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_many_from_insights(_insights), do: {:error, :invalid_insights}

  def sync_from_insight(%Insight{} = insight) do
    case SignalGate.allow_insight?(insight) do
      {:ok, _reason} ->
        case upsert_synced_insight_todo(insight) do
          {:ok, %Todo{} = todo} = result ->
            enqueue_brief(todo)
            result

          other ->
            other
        end

      {:skip, _reason} ->
        {:ok, nil}
    end
  end

  def sync_from_insight(_insight), do: {:error, :invalid_insight}

  def upsert_many(user_id, attrs_list, opts \\ [])

  def upsert_many(user_id, attrs_list, opts)
      when is_binary(user_id) and is_list(attrs_list) and is_list(opts) do
    attrs_list
    |> Enum.reduce({:ok, []}, fn attrs, {:ok, acc} ->
      case upsert_one(user_id, attrs, opts) do
        {:ok, todo} -> {:ok, [todo | acc]}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, todos} ->
        todos = Enum.reverse(todos)
        Enum.each(todos, &enqueue_brief/1)

        {:ok, todos}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def upsert_many(_user_id, _attrs_list, _opts), do: {:error, :invalid_todo_attrs}

  def ingest_many(user_id, attrs_list, opts \\ [])

  def ingest_many(user_id, attrs_list, opts)
      when is_binary(user_id) and is_list(attrs_list) and is_list(opts) do
    Intelligence.ingest_many(user_id, attrs_list, opts)
  end

  def ingest_many(_user_id, _attrs_list, _opts), do: {:error, :invalid_todo_candidates}

  def mark_done(user_id, todo_id, opts \\ [])

  def mark_done(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    note = Keyword.get(opts, :note)
    update_status(user_id, todo_id, "done", note, %{}, opts)
  end

  def mark_done(_user_id, _todo_id, _opts), do: {:error, :not_found}

  @doc """
  Records an evidence-based closure only if the evaluated todo is still current.

  The snapshot check, provenance, linked insight, and activity event share the
  same row-locked transaction. A delayed provider/model response cannot replace
  a subsequent user edit, dismissal, or completion.
  """
  def mark_done_if_current(%Todo{} = todo, provenance, opts \\ []) when is_map(provenance) do
    provenance = Map.put(provenance, "recorded_at", DateTime.to_iso8601(DateTime.utc_now()))

    update_status(
      todo.user_id,
      todo.id,
      "done",
      Keyword.get(opts, :note),
      %{"automatic_completion" => provenance},
      opts |> Keyword.put(:expected_todo, todo) |> Keyword.put(:actor_type, "agent")
    )
  end

  def dismiss(user_id, todo_id, opts \\ [])

  def dismiss(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    note = Keyword.get(opts, :note)
    source = normalize_feedback_source(Keyword.get(opts, :source, "dismiss"))

    update_status(
      user_id,
      todo_id,
      "dismissed",
      note,
      put_dismissal_signal(%{}, source),
      opts
    )
  end

  def dismiss(_user_id, _todo_id, _opts), do: {:error, :not_found}

  def mark_important(user_id, todo_id, opts \\ [])

  def mark_important(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    source = Keyword.get(opts, :source)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               attention_mode: "act_now",
               priority: max(todo.priority || 0, 90),
               status: if(todo.status == "snoozed", do: "open", else: todo.status),
               snoozed_until: nil,
               metadata: put_importance_override(todo.metadata || %{}, source)
             })
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_important(_user_id, _todo_id, _opts), do: {:error, :not_found}

  def snooze(user_id, todo_id, until_datetime, opts \\ [])

  def snooze(user_id, todo_id, until_datetime, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_struct(until_datetime, DateTime) do
    note = Keyword.get(opts, :note)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               status: "snoozed",
               snoozed_until: until_datetime,
               closed_at: nil,
               metadata: put_resolution_note(todo.metadata || %{}, note)
             })
             |> Repo.update(),
           {:ok, _insight} <- sync_linked_insight(updated) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def snooze(_user_id, _todo_id, _until_datetime, _opts), do: {:error, :not_found}

  def record_feedback(user_id, todo_id, feedback, opts \\ [])

  def record_feedback(user_id, todo_id, feedback, opts)
      when is_binary(user_id) and is_binary(todo_id) and feedback in @feedback_values do
    source = Keyword.get(opts, :source)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               metadata: put_feedback(todo.metadata || %{}, feedback, source)
             })
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} ->
        todo = polish_todo_copy(todo)
        _ = maybe_learn_from_feedback(todo, feedback)
        {:ok, todo}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record_feedback(_user_id, _todo_id, _feedback, _opts), do: {:error, :not_found}

  def see_less_like(user_id, todo_id, opts \\ [])

  def see_less_like(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    source = normalize_feedback_source(Keyword.get(opts, :source, "todo_surface"))

    case update_status(
           user_id,
           todo_id,
           "dismissed",
           see_less_resolution_note(source),
           put_see_less_queued_feedback(%{}, source),
           Keyword.put(opts, :source, source)
         ) do
      {:ok, dismissed} ->
        {:ok, %{todo: dismissed, memory: nil, training: %{"queued" => true}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def see_less_like(_user_id, _todo_id, _opts), do: {:error, :not_found}

  def update_for_user(user_id, todo_id, attrs, opts \\ [])

  def update_for_user(user_id, todo_id, attrs, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_map(attrs) and is_list(opts) do
    Repo.transaction(fn ->
      with %Todo{} = todo <- get_todo_for_update(user_id, todo_id) do
        changes = update_attrs(todo, attrs)
        changes = if changes == %{}, do: changes, else: ActionDrafts.ensure(changes, todo)

        if changes == %{} do
          Repo.rollback(:empty_update)
        else
          with {:ok, updated} <- todo |> Todo.changeset(changes) |> Repo.update(),
               {:ok, _insight} <- sync_linked_insight(updated),
               {:ok, _event} <- maybe_record_status_activity(todo, updated, updated.status, opts),
               {:ok, _learning_event} <- OutcomeLearning.maybe_enqueue(todo, updated, opts) do
            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        nil -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} ->
        _ = safe_refresh_embedding(todo)
        todo = polish_todo_copy(todo)
        enqueue_brief(todo)
        {:ok, todo}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :empty_update} ->
        {:error, :empty_update}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_for_user(_user_id, _todo_id, _attrs, _opts), do: {:error, :not_found}

  @doc """
  Merges top-level keys into the todo's metadata with a direct write. This
  skips the full update pipeline (insight sync, embedding refresh, outcome
  learning), so it is only for bookkeeping keys such as brief leases.
  """
  def merge_metadata(user_id, todo_id, metadata)
      when is_binary(user_id) and is_binary(todo_id) and is_map(metadata) do
    Repo.transaction(fn ->
      case get_todo_for_update(user_id, todo_id) do
        %Todo{} = todo ->
          merged = Map.merge(todo.metadata || %{}, stringify_top_level_keys(metadata))

          case todo |> Todo.changeset(%{metadata: merged}) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        nil ->
          Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, reason} -> {:error, reason}
    end
  end

  def merge_metadata(_user_id, _todo_id, _metadata), do: {:error, :not_found}

  @doc """
  Stores a generated chief-of-staff brief on the todo and, when the brief
  includes a reply, replaces the todo's `action_draft` with it. Clears any
  generation lease. Uses a direct write because the todo's own copy (title,
  summary, next action) does not change.
  """
  def put_brief(user_id, todo_id, brief, action_draft)
      when is_binary(user_id) and is_binary(todo_id) and is_map(brief) do
    Repo.transaction(fn ->
      case get_todo_for_update(user_id, todo_id) do
        %Todo{} = todo ->
          metadata =
            (todo.metadata || %{})
            |> Map.put(Brief.metadata_key(), brief)
            |> Map.delete("brief_generation")

          changes =
            %{metadata: metadata}
            |> maybe_put_action_draft(action_draft)

          case todo |> Todo.changeset(changes) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        nil ->
          Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_brief(_user_id, _todo_id, _brief, _action_draft), do: {:error, :not_found}

  defp maybe_put_action_draft(changes, %{} = draft) when map_size(draft) > 0,
    do: Map.put(changes, :action_draft, draft)

  defp maybe_put_action_draft(changes, _draft), do: changes

  def annotate_scope(user_id, todo_id, attrs \\ [])

  def annotate_scope(user_id, todo_id, attrs)
      when is_binary(user_id) and is_binary(todo_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{metadata: put_scope_metadata(todo.metadata || %{}, attrs)})
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def annotate_scope(_user_id, _todo_id, _attrs), do: {:error, :not_found}

  def align_scope_for_project(user_id, project_id, attrs \\ %{})

  def align_scope_for_project(user_id, project_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("project_id", project_id)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> where([todo], todo.status in ^@open_statuses)
    |> where(
      [todo],
      fragment("coalesce(?->>'suggested_project_id', '') = ?", todo.metadata, ^project_id)
    )
    |> Repo.all()
    |> Enum.reduce({:ok, []}, fn %Todo{} = todo, {:ok, acc} ->
      case annotate_scope(user_id, todo.id, attrs) do
        {:ok, updated} -> {:ok, [updated | acc]}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, todos} -> {:ok, Enum.reverse(todos)}
      {:error, reason} -> {:error, reason}
    end
  end

  def align_scope_for_project(_user_id, _project_id, _attrs), do: {:error, :not_found}

  def summarize_for_prompt(user_id, limit \\ 8)

  def summarize_for_prompt(user_id, limit) when is_binary(user_id) do
    list_open_for_user(user_id, limit: limit)
    |> Enum.map(&serialize_for_prompt/1)
  end

  def summarize_for_prompt(_user_id, _limit), do: []

  def serialize_for_prompt(%Todo{} = todo) do
    todo = UserFacingCopy.polish_attrs(todo)

    %{
      id: todo.id,
      source: todo.source,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      due_at: todo.due_at,
      notes: todo.notes,
      action_plan: todo.action_plan,
      action_draft: todo.action_draft || %{},
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority,
      source_account_id: todo.source_account_id,
      source_account_label: todo.source_account_label,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      inserted_at: todo.inserted_at,
      updated_at: todo.updated_at,
      direction: todo.direction,
      counterparty_person_id: todo.counterparty_person_id,
      counterparty_label: todo.counterparty_label,
      last_nudged_at: todo.last_nudged_at,
      nudge_count: todo.nudge_count,
      next_nudge_at: todo.next_nudge_at,
      follow_up_channel: todo.follow_up_channel,
      attention_profile: AttentionRanker.profile(todo),
      surface_quality: SurfaceQuality.assess(todo),
      metadata: summarize_metadata(todo.metadata || %{})
    }
  end

  @doc """
  Records that a follow-up/nudge referencing this todo was actually
  delivered (e.g. a prepared Gmail/Slack send tied to the todo executed).
  Increments `nudge_count`, stamps `last_nudged_at`, and optionally sets
  `follow_up_channel` / `next_nudge_at`.
  """
  def record_nudge_sent(user_id, todo_id, opts \\ [])

  def record_nudge_sent(user_id, todo_id, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)
    channel = normalize_optional_string(Keyword.get(opts, :channel))
    next_nudge_at = Keyword.get(opts, :next_nudge_at)

    # DB-side atomic increment (review fix, minor): the prior read-then-write
    # `(todo.nudge_count || 0) + 1` could lose increments under concurrent
    # nudges for the same todo. `update_all` with `inc:` pushes the +1 to
    # Postgres so it's race-free; `updated_at` is set explicitly here since
    # `update_all` bypasses the changeset/Repo.update autogeneration that
    # normally stamps it.
    set_fields =
      [last_nudged_at: now, next_nudge_at: next_nudge_at, updated_at: now]
      |> maybe_put_keyword(:follow_up_channel, channel)

    Todo
    |> where([todo], todo.id == ^todo_id and todo.user_id == ^user_id)
    |> Repo.update_all(inc: [nudge_count: 1], set: set_fields)
    |> case do
      {1, _} ->
        case Repo.get_by(Todo, id: todo_id, user_id: user_id) do
          %Todo{} = todo -> {:ok, polish_todo_copy(todo)}
          nil -> {:error, :not_found}
        end

      {0, _} ->
        {:error, :not_found}
    end
  end

  def record_nudge_sent(_user_id, _todo_id, _opts), do: {:error, :not_found}

  @doc """
  Clears the follow-up cadence on a todo without closing it (SPEC 01 R6).

  Consumer of SPEC 05's `"acknowledged_only"` counterparty-reply outcome: the
  counterparty acknowledged but did not actually answer, so the item stays
  open for the operator while the stale nudge schedule stops firing. Uses the
  same race-free atomic `Repo.update_all` style as `record_nudge_sent/3`
  (never read-then-write) since it can race a concurrent nudge send for the
  same todo. Until SPEC 05 ships this helper simply has no caller — that is
  the intended degraded mode.
  """
  def clear_nudge_cadence(user_id, todo_id, opts \\ [])

  def clear_nudge_cadence(user_id, todo_id, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)

    note =
      Keyword.get(
        opts,
        :note,
        "Counterparty acknowledged but didn't answer — cadence cleared, still open."
      )

    note_patch = %{"resolution_note" => note}

    from(todo in Todo,
      where: todo.id == ^todo_id and todo.user_id == ^user_id,
      update: [
        set: [
          next_nudge_at: nil,
          updated_at: ^now,
          metadata:
            fragment("coalesce(?, '{}'::jsonb) || ?", todo.metadata, type(^note_patch, :map))
        ]
      ]
    )
    |> Repo.update_all([])
    |> case do
      {1, _} ->
        case Repo.get_by(Todo, id: todo_id, user_id: user_id) do
          %Todo{} = todo -> {:ok, polish_todo_copy(todo)}
          nil -> {:error, :not_found}
        end

      {0, _} ->
        {:error, :not_found}
    end
  end

  def clear_nudge_cadence(_user_id, _todo_id, _opts), do: {:error, :not_found}

  @doc """
  Stamps the calendar block Maraithon created for this todo onto
  `metadata["calendar_block"]` (SPEC 12 R9). `block` carries string keys:
  `event_id` / `calendar_id` / `start_at` / `end_at` / `created_at`.

  Tolerant of todos created before SPEC 12 shipped — this only merges the
  one metadata key, never assumes any prior shape.
  """
  def record_calendar_block(user_id, todo_id, %{} = block)
      when is_binary(user_id) and is_binary(todo_id) do
    update_calendar_block_metadata(user_id, todo_id, fn _current -> block end)
  end

  def record_calendar_block(_user_id, _todo_id, _block), do: {:error, :not_found}

  @doc """
  Merges `changes` (e.g. moved `start_at`/`end_at`) into the stored
  `metadata["calendar_block"]` — only when the stored pointer names the same
  `event_id`, so a stale/hand-edited pointer is never overwritten with data
  about a different event (SPEC 12 R9/R11).
  """
  def update_calendar_block(user_id, todo_id, event_id, %{} = changes)
      when is_binary(user_id) and is_binary(todo_id) and is_binary(event_id) do
    update_calendar_block_metadata(user_id, todo_id, fn
      %{"event_id" => ^event_id} = current -> Map.merge(current, changes)
      current -> current
    end)
  end

  def update_calendar_block(_user_id, _todo_id, _event_id, _changes), do: {:error, :not_found}

  @doc """
  Removes the stored `metadata["calendar_block"]` pointer after the matching
  event was cancelled (SPEC 12 R9). A mismatched or absent pointer is a
  no-op — never an error, since the user may have deleted/edited the event
  directly in Google Calendar.
  """
  def clear_calendar_block(user_id, todo_id, event_id)
      when is_binary(user_id) and is_binary(todo_id) and is_binary(event_id) do
    update_calendar_block_metadata(user_id, todo_id, fn
      %{"event_id" => ^event_id} -> :delete
      current -> current
    end)
  end

  def clear_calendar_block(_user_id, _todo_id, _event_id), do: {:error, :not_found}

  defp update_calendar_block_metadata(user_id, todo_id, fun) do
    case Repo.get_by(Todo, id: todo_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Todo{} = todo ->
        metadata = todo.metadata || %{}
        current = Map.get(metadata, "calendar_block")

        metadata =
          case fun.(current) do
            :delete -> Map.delete(metadata, "calendar_block")
            nil -> metadata
            %{} = block -> Map.put(metadata, "calendar_block", block)
          end

        if metadata == (todo.metadata || %{}) do
          {:ok, todo}
        else
          todo
          |> Todo.changeset(%{metadata: metadata})
          |> Repo.update()
        end
    end
  end

  @doc """
  Lenient, timezone-aware datetime coercion shared by ingest and the
  conversational snooze tool (SPEC 01 R2/R3).

  Accepts `DateTime`/`NaiveDateTime`/`Date` structs and ISO-8601 strings with
  or without an offset. A bare date resolves to a sane local end-of-day
  (20:00) in the user's timezone and a naive datetime is read as local wall
  time — both converted to UTC for storage.
  When no timezone can be resolved, a bare date deterministically falls back
  to UTC end-of-day (never midnight, which flips the calendar date for every
  western-hemisphere operator). Returns `nil` for unparseable input.

  The second argument is either a `user_id` (timezone resolved from
  `Maraithon.BriefingSchedules.summarize_for_prompt/1`) or an already-resolved
  timezone context map from `user_timezone_context/1`.
  """
  def parse_flexible_datetime(value, user_id_or_timezone \\ nil)

  def parse_flexible_datetime(value, user_id) when is_binary(user_id) do
    coerce_due_datetime(value, user_timezone_context(user_id))
  end

  def parse_flexible_datetime(value, %{} = timezone_context) do
    coerce_due_datetime(value, timezone_context)
  end

  def parse_flexible_datetime(value, _user_id_or_timezone) do
    coerce_due_datetime(value, nil)
  end

  @doc """
  Resolves the user's timezone context (`%{timezone_name: ..., offset_hours: ...}`)
  from their briefing schedule, or `nil` when it cannot be resolved (no
  configured briefing agent, or a lookup failure). Callers fall back to
  deterministic UTC handling on `nil`.
  """
  def user_timezone_context(user_id) when is_binary(user_id) do
    summary = BriefingSchedules.summarize_for_prompt(user_id)

    if Map.get(summary, :configured) do
      %{
        timezone_name: Map.get(summary, :timezone_name),
        offset_hours: normalize_timezone_offset_hours(Map.get(summary, :timezone_offset_hours))
      }
    else
      nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  def user_timezone_context(_user_id), do: nil

  defp normalize_timezone_offset_hours(value) when is_integer(value), do: value
  defp normalize_timezone_offset_hours(_value), do: 0

  @doc """
  Bucket of open todos shaped like `Commitments.bucket_for_brief/2`, used by
  the morning briefing prompt (SPEC 05 R6). This replaces the retired
  `Commitment` schema as the brief's "what do I owe" source of truth.

  SPEC 06 R3: accepts a `:direction` option. The default remains
  `"owed_by_me"` (behavior- and label-preserving for the morning brief's
  existing call). `direction: "owed_to_me"` buckets what others owe the
  operator (`"source" => "todos_owed_to_me"`); `direction: :all` buckets all
  open todos with no direction filter (`"source" => "todos_open_all"`). The
  private bucketing helpers are direction-agnostic and take the explicit
  `:timezone_offset_hours`, so every direction shares the same due math.
  """
  def bucket_for_brief(user_id, opts \\ [])

  def bucket_for_brief(user_id, opts) when is_binary(user_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
    timezone_label = Keyword.get(opts, :timezone_label, brief_timezone_offset_label(offset_hours))
    limit = Keyword.get(opts, :limit, 50)

    {source, todos} =
      case Keyword.get(opts, :direction, "owed_by_me") do
        all when all in [:all, "all"] ->
          {"todos_open_all", list_open_for_user(user_id, limit: limit)}

        "owed_to_me" ->
          {"todos_owed_to_me", list_owed_to_me(user_id, limit: limit)}

        _owed_by_me ->
          {"todos_owed_by_me", list_owed_by_me(user_id, limit: limit)}
      end

    items =
      todos
      |> Enum.map(&brief_item_for_todo/1)
      |> Enum.map(&brief_put_display_due(&1, offset_hours, timezone_label))

    %{
      "source" => source,
      "active_count" => length(items),
      "overdue" => Enum.filter(items, &brief_overdue?(&1, now, offset_hours)),
      "due_today" => Enum.filter(items, &brief_due_today?(&1, now, offset_hours)),
      "coming_up" => Enum.filter(items, &brief_coming_up?(&1, now, offset_hours)),
      "no_deadline" => Enum.filter(items, &is_nil(&1["due_at"]))
    }
  end

  def bucket_for_brief(_user_id, _opts) do
    %{
      "source" => "todos_owed_by_me",
      "active_count" => 0,
      "overdue" => [],
      "due_today" => [],
      "coming_up" => [],
      "no_deadline" => []
    }
  end

  @doc """
  Embedding-similarity dedupe fallback (SPEC 05 R5). Returns up to `limit`
  of the user's open todos whose title/summary embedding is closest to
  `text`, for injection into the intelligence prompt's `existing_todos` so
  the model can choose `update` instead of creating a near-duplicate with
  different wording. Returns `[]` (never raises) when pgvector isn't
  installed, the embed call fails, or `text` is blank.
  """
  def semantic_duplicate_candidates(user_id, text, opts \\ [])

  def semantic_duplicate_candidates(user_id, text, opts)
      when is_binary(user_id) and is_binary(text) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 5)
    min_similarity = Keyword.get(opts, :min_similarity, 0.75)
    embed_opts = Keyword.get(opts, :embed_opts, [])

    case normalize_optional_string(text) do
      nil ->
        []

      normalized ->
        if LocalEmbeddings.embedding_storage_available?(@embedding_table) do
          case safe_embed(normalized, embed_opts) do
            {:ok, vector} ->
              @embedding_table
              |> LocalEmbeddings.semantic_search(user_id, vector,
                limit: max(limit * 4, limit),
                min_similarity: min_similarity
              )
              |> load_open_todos_ranked(user_id, limit)

            {:error, _reason} ->
              []
          end
        else
          []
        end
    end
  rescue
    error ->
      Logger.warning("todo semantic dedupe search failed", reason: Exception.message(error))
      []
  catch
    _kind, _reason -> []
  end

  def semantic_duplicate_candidates(_user_id, _text, _opts), do: []

  @doc """
  Batch variant of `semantic_duplicate_candidates/3` (SPEC 05 review,
  Finding 3). Takes multiple texts and returns a parallel list of duplicate
  candidate lists, computing all embeddings in a single provider round-trip
  (`Embeddings.embed_many/2`) instead of one call per text. The local
  pgvector similarity search still runs once per text (that's an in-process
  DB query, not a network call), so this only collapses the expensive part.
  Never raises; degrades to `[]` per position on any failure.
  """
  def semantic_duplicate_candidates_many(user_id, texts, opts \\ [])

  def semantic_duplicate_candidates_many(user_id, texts, opts)
      when is_binary(user_id) and is_list(texts) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 5)
    min_similarity = Keyword.get(opts, :min_similarity, 0.75)
    embed_opts = Keyword.get(opts, :embed_opts, [])

    normalized = Enum.map(texts, &normalize_optional_string/1)

    if not LocalEmbeddings.embedding_storage_available?(@embedding_table) or
         Enum.all?(normalized, &is_nil/1) do
      Enum.map(normalized, fn _ -> [] end)
    else
      indexed = normalized |> Enum.with_index() |> Enum.filter(fn {text, _i} -> text != nil end)

      case safe_embed_many(Enum.map(indexed, &elem(&1, 0)), embed_opts) do
        {:ok, vectors} ->
          vectors_by_index = indexed |> Enum.map(&elem(&1, 1)) |> Enum.zip(vectors) |> Map.new()

          Enum.with_index(normalized)
          |> Enum.map(fn {_text, index} ->
            case Map.get(vectors_by_index, index) do
              nil ->
                []

              vector ->
                @embedding_table
                |> LocalEmbeddings.semantic_search(user_id, vector,
                  limit: max(limit * 4, limit),
                  min_similarity: min_similarity
                )
                |> load_open_todos_ranked(user_id, limit)
            end
          end)

        {:error, _reason} ->
          Enum.map(normalized, fn _ -> [] end)
      end
    end
  rescue
    error ->
      Logger.warning("todo semantic dedupe batch search failed", reason: Exception.message(error))
      Enum.map(texts, fn _ -> [] end)
  catch
    _kind, _reason -> Enum.map(texts, fn _ -> [] end)
  end

  def semantic_duplicate_candidates_many(_user_id, texts, _opts) when is_list(texts),
    do: Enum.map(texts, fn _ -> [] end)

  def semantic_duplicate_candidates_many(_user_id, _texts, _opts), do: []

  defp safe_embed(text, opts) do
    Embeddings.embed(text, opts)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_embed_many(texts, opts) do
    Embeddings.embed_many(texts, opts)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp load_open_todos_ranked([], _user_id, _limit), do: []

  defp load_open_todos_ranked(id_similarity_pairs, user_id, limit) do
    ids = Enum.map(id_similarity_pairs, &elem(&1, 0))
    similarity_by_id = Map.new(id_similarity_pairs)

    Todo
    |> where(
      [todo],
      todo.user_id == ^user_id and todo.id in ^ids and todo.status in ^@open_statuses
    )
    |> Repo.all()
    |> Enum.sort_by(&Map.get(similarity_by_id, &1.id, 0.0), :desc)
    |> Enum.take(limit)
  end

  @doc """
  Recomputes and persists the title+summary embedding for a todo
  (best-effort; never raises). Called at insert/update so future ingestion
  cycles can find this todo as a semantic dedupe candidate.
  """
  def refresh_embedding(%Todo{} = todo) do
    LocalEmbeddings.refresh(@embedding_table, todo.id, embedding_source_text(todo))
  end

  def refresh_embedding(_other), do: {:error, :invalid_todo}

  defp embedding_source_text(%Todo{} = todo) do
    [todo.title, todo.summary]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  defp safe_refresh_embedding(%Todo{} = todo) do
    refresh_embedding(todo)
  rescue
    error ->
      Logger.warning("todo embedding refresh failed",
        todo_id: todo.id,
        reason: Exception.message(error)
      )

      :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_refresh_embedding(_other), do: :ok

  defp tap_refresh_embedding({:ok, %Todo{} = todo}) do
    _ = safe_refresh_embedding(todo)
    {:ok, todo}
  end

  defp tap_refresh_embedding(other), do: other

  defp brief_item_for_todo(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "source" => "todo",
      "source_id" => todo.id,
      "title" => todo.title,
      "owed_to" => todo.counterparty_label,
      "project" => read_string(todo.metadata || %{}, "project", nil),
      "due_at" => brief_datetime_to_iso(todo.due_at),
      "status" => todo.status,
      "priority" => todo.priority,
      "evidence" => [],
      "metadata" => Map.take(todo.metadata || %{}, ["source_insight_id", "record"])
    }
  end

  defp brief_put_display_due(item, offset_hours, timezone_label) when is_map(item) do
    case brief_display_due_label(item["due_at"], offset_hours, timezone_label) do
      nil -> item
      label -> Map.put(item, "display_due", label)
    end
  end

  defp brief_overdue?(%{"due_at" => nil}, _now, _offset_hours), do: false

  defp brief_overdue?(item, now, offset_hours) do
    case brief_parse_datetime(item["due_at"]) do
      nil ->
        false

      due_at ->
        Date.compare(brief_local_date(due_at, offset_hours), brief_local_date(now, offset_hours)) ==
          :lt
    end
  end

  defp brief_due_today?(%{"due_at" => nil}, _now, _offset_hours), do: false

  defp brief_due_today?(item, now, offset_hours) do
    case brief_parse_datetime(item["due_at"]) do
      nil ->
        false

      due_at ->
        Date.compare(brief_local_date(due_at, offset_hours), brief_local_date(now, offset_hours)) ==
          :eq
    end
  end

  defp brief_coming_up?(%{"due_at" => nil}, _now, _offset_hours), do: false

  defp brief_coming_up?(item, now, offset_hours) do
    case brief_parse_datetime(item["due_at"]) do
      nil ->
        false

      due_at ->
        today = brief_local_date(now, offset_hours)
        due_date = brief_local_date(due_at, offset_hours)
        days = Date.diff(due_date, today)
        days > 0 and days <= 7
    end
  end

  @doc """
  The user-local calendar date for a UTC timestamp at a fixed hour offset.

  SPEC 01 R2: this is the shared date-localization primitive underneath
  `brief_overdue?`/`brief_due_today?` and `Maraithon.OpenLoops`' due-date
  bucketing — comparing raw UTC calendar dates misclassifies items near
  local midnight, so both call this instead of `DateTime.to_date/1`.
  """
  def brief_local_date(%DateTime{} = datetime, offset_hours) when is_integer(offset_hours) do
    datetime
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_date()
  end

  def brief_local_date(%DateTime{} = datetime, _offset_hours), do: DateTime.to_date(datetime)

  defp brief_display_due_label(nil, _offset_hours, _timezone_label), do: nil

  defp brief_display_due_label(value, offset_hours, timezone_label) do
    case brief_parse_datetime(value) do
      nil ->
        nil

      due_at ->
        due_at
        |> DateTime.add(offset_hours, :hour)
        |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{timezone_label}")
    end
  end

  defp brief_timezone_offset_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC#{sign}#{hours}:00"
  end

  defp brief_timezone_offset_label(_offset), do: "UTC"

  defp brief_parse_datetime(nil), do: nil
  defp brief_parse_datetime(%DateTime{} = value), do: value

  defp brief_parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp brief_parse_datetime(_value), do: nil

  defp brief_datetime_to_iso(nil), do: nil
  defp brief_datetime_to_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp brief_datetime_to_iso(value), do: to_string(value)

  defp upsert_one(user_id, attrs, opts) when is_binary(user_id) and is_map(attrs) do
    normalized_attrs =
      user_id
      |> normalize_attrs(attrs)
      |> UserFacingCopy.polish_attrs()
      |> ActionDrafts.ensure()
      |> maybe_put_model_selected_at(opts)

    case existing_todo_for_upsert(user_id, normalized_attrs) do
      {%Todo{} = todo, matched_attrs} ->
        update_upserted_todo(todo, matched_attrs, attrs)

      nil ->
        case insert_upserted_todo(normalized_attrs, opts) do
          {:error, %Ecto.Changeset{} = changeset} = error ->
            # Read-then-write race: a concurrent writer inserted the same
            # dedupe key between our lookup and insert, surfaced through the
            # `todos_user_id_dedupe_key_index` unique constraint. The row
            # exists now, so retry once through the update path.
            if dedupe_key_conflict?(changeset) do
              case existing_todo_for_upsert(user_id, normalized_attrs) do
                {%Todo{} = todo, matched_attrs} ->
                  update_upserted_todo(todo, matched_attrs, attrs)

                nil ->
                  error
              end
            else
              error
            end

          other ->
            other
        end
    end
  end

  defp maybe_put_model_selected_at(attrs, opts) when is_map(attrs) and is_list(opts) do
    if Keyword.get(opts, :model_selected?, false) and
         Map.get(attrs, "source") not in ["manual", "mobile"] do
      Map.put_new(attrs, "model_selected_at", DateTime.utc_now())
    else
      attrs
    end
  end

  defp update_upserted_todo(%Todo{} = todo, matched_attrs, attrs) do
    todo
    |> Todo.changeset(merge_upsert_attrs(todo, matched_attrs, attrs))
    |> Repo.update()
    |> tap_refresh_embedding()
  end

  defp insert_upserted_todo(normalized_attrs, opts) do
    Repo.transaction(fn ->
      with {:ok, inserted} <- %Todo{} |> Todo.changeset(normalized_attrs) |> Repo.insert(),
           {:ok, _event} <- record_activity_event(inserted, "created", opts) do
        inserted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap_refresh_embedding()
  end

  defp dedupe_key_conflict?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :dedupe_key) do
      {_message, meta} -> Keyword.get(meta, :constraint) == :unique
      _other -> false
    end
  end

  defp existing_todo_for_upsert(user_id, attrs) do
    case Repo.get_by(Todo, user_id: user_id, dedupe_key: attrs["dedupe_key"]) do
      %Todo{} = todo ->
        {todo, attrs}

      nil ->
        case existing_source_item_todo(user_id, attrs) do
          %Todo{} = todo ->
            {todo, Map.put(attrs, "dedupe_key", todo.dedupe_key)}

          nil ->
            nil
        end
    end
  end

  defp existing_source_item_todo(user_id, attrs) do
    source = normalize_optional_string(Map.get(attrs, "source"))
    source_item_id = normalize_optional_string(Map.get(attrs, "source_item_id"))
    kind = normalize_optional_string(Map.get(attrs, "kind"))
    owner_user_id = normalize_optional_string(Map.get(attrs, "owner_user_id"))

    if source && source_item_id && kind && owner_user_id do
      Todo
      |> where(
        [todo],
        todo.user_id == ^user_id and todo.source == ^source and
          todo.source_item_id == ^source_item_id and todo.kind == ^kind and
          todo.owner_user_id == ^owner_user_id
      )
      |> order_by([todo],
        asc:
          fragment(
            "CASE ? WHEN 'open' THEN 0 WHEN 'snoozed' THEN 1 WHEN 'dismissed' THEN 2 WHEN 'done' THEN 3 ELSE 4 END",
            todo.status
          ),
        desc: todo.updated_at
      )
      |> limit(1)
      |> Repo.one()
    end
  end

  defp upsert_synced_insight_todo(%Insight{} = insight) do
    attrs = synced_insight_attrs(insight)

    case Repo.get_by(Todo, user_id: insight.user_id, dedupe_key: attrs.dedupe_key) do
      %Todo{} = todo ->
        if preserve_closed_synced_todo?(todo, attrs) do
          {:ok, todo}
        else
          todo
          |> Todo.changeset(attrs)
          |> Repo.update()
          |> tap_refresh_embedding()
        end

      nil ->
        Repo.transaction(fn ->
          with {:ok, inserted} <- %Todo{} |> Todo.changeset(attrs) |> Repo.insert(),
               {:ok, _event} <- record_activity_event(inserted, "created", []) do
            inserted
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> tap_refresh_embedding()
    end
  end

  defp get_todo_for_update(user_id, todo_id) do
    Todo
    |> where([todo], todo.id == ^todo_id and todo.user_id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp update_status(user_id, todo_id, status, note, extra_metadata, opts) do
    activity_opts = Keyword.put_new(opts, :note, note)

    Repo.transaction(fn ->
      with %Todo{} = todo <- get_todo_for_update(user_id, todo_id),
           :ok <- validate_status_snapshot(todo, Keyword.get(opts, :expected_todo)),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               status: status,
               snoozed_until: nil,
               closed_at: DateTime.utc_now() |> DateTime.truncate(:second),
               metadata:
                 (todo.metadata || %{})
                 |> put_resolution_note(note)
                 |> Map.merge(extra_metadata || %{})
             })
             |> Repo.update(),
           {:ok, _insight} <- sync_linked_insight(updated),
           {:ok, _event} <- maybe_record_status_activity(todo, updated, status, activity_opts),
           {:ok, _learning_event} <- OutcomeLearning.maybe_enqueue(todo, updated, activity_opts) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_status_snapshot(_todo, nil), do: :ok

  defp validate_status_snapshot(%Todo{status: status}, %Todo{})
       when status not in ["open", "snoozed"],
       do: {:error, :todo_no_longer_open}

  defp validate_status_snapshot(%Todo{} = current, %Todo{} = expected) do
    if current.id == expected.id and current.user_id == expected.user_id and
         current.updated_at == expected.updated_at do
      :ok
    else
      {:error, :stale_todo}
    end
  end

  defp maybe_record_status_activity(%Todo{status: status}, %Todo{}, status, _opts), do: {:ok, nil}

  defp maybe_record_status_activity(_previous, %Todo{} = updated, status, opts) do
    case activity_event_type_for_status(status) do
      nil -> {:ok, nil}
      event_type -> record_activity_event(updated, event_type, opts)
    end
  end

  defp activity_event_type_for_status("done"), do: "marked_done"
  defp activity_event_type_for_status("dismissed"), do: "deleted"
  defp activity_event_type_for_status(_status), do: nil

  defp record_activity_event(%Todo{} = todo, event_type, opts) do
    actor = activity_actor_attrs(opts)

    attrs =
      %{
        user_id: todo.user_id,
        todo_id: todo.id,
        event_type: event_type,
        todo_title: todo.title,
        todo_source: todo.source,
        metadata: activity_event_metadata(todo, opts),
        occurred_at: DateTime.utc_now()
      }
      |> Map.merge(actor)

    %ActivityEvent{}
    |> ActivityEvent.changeset(attrs)
    |> Repo.insert()
  end

  defp activity_actor_attrs(opts) do
    actor_type = normalize_actor_type(Keyword.get(opts, :actor_type, "agent"))

    %{
      actor_type: actor_type,
      actor_id: normalize_optional_string(Keyword.get(opts, :actor_id)),
      actor_label:
        normalize_optional_string(Keyword.get(opts, :actor_label)) ||
          default_actor_label(actor_type)
    }
  end

  defp normalize_actor_type(:user), do: "user"
  defp normalize_actor_type(:agent), do: "agent"
  defp normalize_actor_type("user"), do: "user"
  defp normalize_actor_type("agent"), do: "agent"
  defp normalize_actor_type(_value), do: "agent"

  defp default_actor_label("user"), do: "User"
  defp default_actor_label("agent"), do: "Maraithon"

  defp activity_event_metadata(%Todo{} = todo, opts) do
    %{"todo_status" => todo.status}
    |> maybe_put("note", normalize_optional_string(Keyword.get(opts, :note)))
  end

  defp sync_linked_insight(%Todo{} = todo) do
    case linked_insight(todo) do
      %Insight{} = insight ->
        insight
        |> Ecto.Changeset.change(linked_insight_changes(insight, todo))
        |> Repo.update()

      nil ->
        {:ok, nil}
    end
  end

  defp linked_insight(%Todo{} = todo) do
    case get_in(todo.metadata || %{}, ["source_insight_id"]) do
      insight_id when is_binary(insight_id) ->
        Repo.get_by(Insight, id: insight_id, user_id: todo.user_id)

      _ ->
        nil
    end
  end

  defp maybe_learn_from_feedback(%Todo{} = todo, feedback) when feedback in @feedback_values do
    case linked_insight(todo) do
      %Insight{} = insight ->
        PreferenceMemory.learn_from_feedback(todo.user_id, insight, feedback,
          allow_fallback?: false
        )

      nil ->
        {:ok, %{reply: nil, learned: []}}
    end
  rescue
    _error ->
      {:ok, %{reply: nil, learned: []}}
  end

  defp maybe_learn_from_feedback(_todo, _feedback), do: {:ok, %{reply: nil, learned: []}}

  defp linked_insight_changes(%Insight{} = insight, %Todo{} = todo) do
    changes =
      case todo.status do
        "done" ->
          %{status: "acknowledged", snoozed_until: nil}

        "dismissed" ->
          %{status: "dismissed", snoozed_until: nil}

        "snoozed" ->
          %{status: "snoozed", snoozed_until: todo.snoozed_until}

        _ ->
          %{}
      end

    case linked_insight_resolution_metadata(insight, todo) do
      nil -> changes
      metadata -> Map.put(changes, :metadata, metadata)
    end
  end

  defp linked_insight_resolution_metadata(%Insight{} = insight, %Todo{} = todo) do
    note = get_in(todo.metadata || %{}, ["resolution_note"])

    resolution =
      %{
        "todo_resolution" => %{
          "status" => todo.status,
          "resolved_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "note" => normalize_optional_string(note)
        }
      }
      |> compact_map()

    if map_size(resolution) == 0 do
      nil
    else
      Map.merge(insight.metadata || %{}, resolution)
    end
  end

  defp merge_upsert_attrs(%Todo{} = existing, attrs, raw_attrs) do
    incoming_status = Map.get(attrs, "status", "open")

    status = merge_status(existing.status, incoming_status)

    closed_at =
      if status in ["done", "dismissed"] do
        existing.closed_at || Map.get(attrs, "closed_at")
      else
        nil
      end

    snoozed_until =
      if status == "snoozed" do
        existing.snoozed_until || Map.get(attrs, "snoozed_until")
      else
        nil
      end

    direction = preserved_update_direction(existing, raw_attrs)

    attrs
    |> Map.put("status", status)
    |> Map.put("model_selected_at", merged_model_selected_at(existing, attrs))
    |> Map.put("closed_at", closed_at)
    |> Map.put("snoozed_until", snoozed_until)
    |> Map.put("direction", direction)
    |> Map.put(
      "counterparty_person_id",
      preserved_update_counterparty_person_id(existing, attrs, raw_attrs)
    )
    |> Map.put("counterparty_label", preserved_update_counterparty_label(existing, raw_attrs))
    |> Map.put("next_nudge_at", preserved_update_next_nudge_at(existing, attrs, direction))
  end

  # SPEC 01 R1, mirroring preserved_update_direction/2 above: on the upsert
  # update path, an incoming scan that simply omitted next_nudge_at must not
  # wipe an existing cadence back to nil — but the owed_to_me-only invariant
  # still wins, so any non-owed_to_me resolution clears it regardless.
  defp merged_model_selected_at(%Todo{} = existing, attrs) do
    if existing.source in ["manual", "mobile"] do
      nil
    else
      existing.model_selected_at || Map.get(attrs, "model_selected_at")
    end
  end

  defp preserved_update_next_nudge_at(%Todo{} = existing, attrs, direction) do
    cond do
      direction != "owed_to_me" -> nil
      match?(%DateTime{}, Map.get(attrs, "next_nudge_at")) -> Map.get(attrs, "next_nudge_at")
      true -> existing.next_nudge_at
    end
  end

  # SPEC 05 review (Finding 2): normalize_attrs/2 always resolves a
  # "direction" (defaulting to "owed_by_me") so the create path always has
  # a sensible value, but by the time that default is baked in we can no
  # longer tell "explicitly set to owed_by_me" apart from "not provided at
  # all". On the update path that ambiguity meant every upsert whose
  # incoming attrs omitted (or sent an invalid) direction/counterparty
  # silently reset an existing owed_to_me todo back to owed_by_me. Re-derive
  # from the *raw*, pre-normalization attrs here so we can preserve the
  # existing value when nothing valid was explicitly provided — mirroring
  # update_direction_attr/2 on the explicit-tool-update path. The create
  # path is unaffected; it never goes through this function.
  defp preserved_update_direction(%Todo{} = existing, raw_attrs) do
    if attr_present?(raw_attrs, "direction") do
      normalize_direction(read_string(raw_attrs, "direction", nil)) || existing.direction
    else
      existing.direction
    end
  end

  # SPEC 04 R2/R3 (update path): an explicit incoming counterparty_person_id
  # attr still wins (explicit nil keeps the existing value — unchanged
  # semantic). When the attr is absent, an existing FK is never overwritten,
  # but a nil FK may now be filled by the value the R2 resolver stamped into
  # the normalized attrs — this is what lets a re-upsert flip an earlier
  # :not_found/:ambiguous outcome to a resolution once the CRM candidate set
  # changes, without ever clobbering a human- or tool-set value.
  defp preserved_update_counterparty_person_id(%Todo{} = existing, attrs, raw_attrs) do
    if attr_present?(raw_attrs, "counterparty_person_id") do
      read_uuid(raw_attrs, "counterparty_person_id", nil) || existing.counterparty_person_id
    else
      existing.counterparty_person_id || Map.get(attrs, "counterparty_person_id")
    end
  end

  defp preserved_update_counterparty_label(%Todo{} = existing, raw_attrs) do
    if attr_present?(raw_attrs, "counterparty_label") do
      read_string(raw_attrs, "counterparty_label", nil) || existing.counterparty_label
    else
      existing.counterparty_label
    end
  end

  defp merge_status(_existing_status, incoming_status)
       when incoming_status in ["done", "dismissed", "snoozed"] do
    incoming_status
  end

  defp merge_status(existing_status, "open")
       when existing_status in ["done", "dismissed", "snoozed"] do
    existing_status
  end

  defp merge_status(_existing_status, incoming_status), do: incoming_status

  defp update_attrs(%Todo{} = todo, attrs) when is_map(attrs) do
    %{}
    |> update_text_attr(attrs, "source", "source")
    |> update_integer_attr(attrs, "source_account_id", "source_account_id")
    |> update_text_attr(attrs, "source_account_label", "source_account_label")
    |> update_project_id_attr(todo, attrs)
    |> update_agent_actionability_attrs(attrs)
    |> update_kind_attr(attrs)
    |> update_attention_mode_attr(attrs)
    |> update_text_attr(attrs, "title", "title")
    |> update_text_attr(attrs, "todo", "summary")
    |> update_text_attr(attrs, "summary", "summary")
    |> update_text_attr(attrs, "next_action", "next_action")
    |> update_datetime_attr(attrs, "due_at", "due_at")
    |> update_datetime_attr(attrs, "due_date", "due_at")
    |> update_text_attr(attrs, "notes", "notes")
    |> update_text_attr(attrs, "action_plan", "action_plan")
    |> update_action_draft_attr(attrs)
    |> update_text_attr(attrs, "owner_user_id", "owner_user_id")
    |> update_text_attr(attrs, "owner_label", "owner_label")
    |> update_integer_attr(attrs, "priority", "priority", &clamp_integer(&1, 0, 100))
    |> update_status_attrs(todo, attrs)
    |> update_text_attr(attrs, "source_item_id", "source_item_id")
    |> update_datetime_attr(attrs, "source_occurred_at", "source_occurred_at")
    |> update_text_attr(attrs, "dedupe_key", "dedupe_key")
    |> update_direction_attr(attrs)
    |> update_text_attr(attrs, "counterparty_person_id", "counterparty_person_id")
    |> update_text_attr(attrs, "counterparty_label", "counterparty_label")
    |> update_metadata_attr(todo, attrs)
    |> record_completion_reopening(todo)
    |> UserFacingCopy.polish_attrs()
  end

  defp record_completion_reopening(changes, %Todo{status: status} = todo)
       when status in ["done", "dismissed"] do
    if Map.get(changes, "status") in ["open", "snoozed"] do
      reopened_at = DateTime.to_iso8601(DateTime.utc_now())

      metadata =
        Map.get(changes, "metadata", todo.metadata || %{})
        |> Map.put("completion_reopened_at", reopened_at)
        |> Map.put("completion_correction", %{
          "reopened_at" => reopened_at,
          "previous_status" => status,
          "previous_automatic_completion" => (todo.metadata || %{})["automatic_completion"]
        })
        |> Map.drop(["automatic_completion", "resolution_note"])

      changes
      |> Map.put("metadata", metadata)
      |> Map.put("last_completion_checked_at", nil)
    else
      changes
    end
  end

  defp record_completion_reopening(changes, _todo), do: changes

  defp update_text_attr(changes, attrs, key, field) do
    if attr_present?(attrs, key) do
      case read_string(attrs, key, nil) do
        nil -> changes
        value -> Map.put(changes, field, value)
      end
    else
      changes
    end
  end

  defp update_integer_attr(changes, attrs, key, field, transform \\ & &1) do
    if attr_present?(attrs, key) do
      case read_integer(attrs, key, nil) do
        nil -> changes
        value -> Map.put(changes, field, transform.(value))
      end
    else
      changes
    end
  end

  defp update_project_id_attr(changes, %Todo{} = todo, attrs) do
    if attr_present?(attrs, "project_id") do
      case fetch_attr(attrs, "project_id") do
        value when value in [nil, ""] ->
          Map.put(changes, "project_id", nil)

        value when is_binary(value) ->
          case Ecto.UUID.cast(String.trim(value)) do
            {:ok, project_id} ->
              if project_belongs_to_user?(project_id, todo.user_id),
                do: Map.put(changes, "project_id", project_id),
                else: Map.put(changes, "project_id", "invalid_project")

            :error ->
              Map.put(changes, "project_id", "invalid_project")
          end

        _other ->
          Map.put(changes, "project_id", "invalid_project")
      end
    else
      changes
    end
  end

  defp update_agent_actionability_attrs(changes, attrs) do
    changes =
      if attr_present?(attrs, "agent_actionability") do
        Map.put(
          changes,
          "agent_actionability",
          normalize_agent_actionability(read_string(attrs, "agent_actionability", "needs_you"))
        )
      else
        changes
      end

    changes =
      if attr_present?(attrs, "agent_action_label") do
        Map.put(changes, "agent_action_label", read_string(attrs, "agent_action_label", nil))
      else
        changes
      end

    if attr_present?(attrs, "agent_action_requires_approval") do
      Map.put(
        changes,
        "agent_action_requires_approval",
        read_boolean_attr(attrs, "agent_action_requires_approval", true)
      )
    else
      changes
    end
  end

  defp update_datetime_attr(changes, attrs, key, field) do
    if attr_present?(attrs, key) do
      case read_datetime(attrs, key) do
        nil -> changes
        value -> Map.put(changes, field, value)
      end
    else
      changes
    end
  end

  defp update_kind_attr(changes, attrs) do
    if attr_present?(attrs, "kind") do
      Map.put(changes, "kind", normalize_kind(read_string(attrs, "kind", "general")))
    else
      changes
    end
  end

  defp update_attention_mode_attr(changes, attrs) do
    if attr_present?(attrs, "attention_mode") do
      Map.put(
        changes,
        "attention_mode",
        normalize_attention_mode(read_string(attrs, "attention_mode", "act_now"))
      )
    else
      changes
    end
  end

  defp update_direction_attr(changes, attrs) do
    if attr_present?(attrs, "direction") do
      case normalize_direction(read_string(attrs, "direction", nil)) do
        nil -> changes
        direction -> Map.put(changes, "direction", direction)
      end
    else
      changes
    end
  end

  defp update_action_draft_attr(changes, attrs) do
    if attr_present?(attrs, "action_draft") or attr_present?(attrs, "draft") do
      Map.put(changes, "action_draft", read_action_draft(attrs))
    else
      changes
    end
  end

  defp update_status_attrs(changes, %Todo{} = todo, attrs) do
    changes =
      if attr_present?(attrs, "status") do
        status = normalize_status(read_string(attrs, "status", "open"))
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case status do
          "open" ->
            changes
            |> Map.put("status", "open")
            |> Map.put("closed_at", nil)
            |> Map.put("snoozed_until", nil)

          "done" ->
            changes
            |> Map.put("status", "done")
            |> Map.put("closed_at", todo.closed_at || now)
            |> Map.put("snoozed_until", nil)

          "dismissed" ->
            changes
            |> Map.put("status", "dismissed")
            |> Map.put("closed_at", todo.closed_at || now)
            |> Map.put("snoozed_until", nil)

          "snoozed" ->
            snoozed_until =
              read_datetime(attrs, "snoozed_until") || todo.snoozed_until ||
                DateTime.add(now, 24, :hour)

            changes
            |> Map.put("status", "snoozed")
            |> Map.put("closed_at", nil)
            |> Map.put("snoozed_until", snoozed_until)
        end
      else
        changes
      end

    update_datetime_attr(changes, attrs, "snoozed_until", "snoozed_until")
  end

  defp update_metadata_attr(changes, %Todo{} = todo, attrs) do
    if attr_present?(attrs, "metadata") do
      metadata = read_map(attrs, "metadata") |> stringify_top_level_keys()

      merged_metadata =
        if truthy?(fetch_attr(attrs, "replace_metadata")) do
          metadata
        else
          Map.merge(todo.metadata || %{}, metadata)
        end

      Map.put(changes, "metadata", merged_metadata)
    else
      changes
    end
  end

  defp attr_present?(attrs, key) when is_map(attrs) and is_binary(key) do
    Map.has_key?(attrs, key) or
      case existing_atom_key(key) do
        atom_key when is_atom(atom_key) -> Map.has_key?(attrs, atom_key)
        _ -> false
      end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp normalize_attrs(user_id, attrs) do
    metadata = read_map(attrs, "metadata")
    source = read_string(attrs, "source", "system")
    kind = normalize_kind(read_string(attrs, "kind", "general"))
    source_item_id = read_string(attrs, "source_item_id", nil)

    # SPEC 01 R2: due-date-shaped values (due_at/due_date/due/snoozed_until/
    # next_nudge_at) resolve bare dates and naive datetimes in the user's
    # local timezone instead of midnight UTC. Instant timestamps
    # (source_occurred_at/closed_at — "when did this actually happen") keep
    # the plain `read_datetime/2` coercion; they must never get the
    # end-of-day-local shift.
    due_tz = due_timezone_context(user_id, attrs)

    due_at =
      read_due_datetime(attrs, "due_at", due_tz) ||
        read_due_datetime(attrs, "due_date", due_tz) ||
        read_due_datetime(attrs, "due", due_tz)

    owner_user_id = read_string(attrs, "owner_user_id", user_id)
    owner_label = read_string(attrs, "owner_label", read_string(attrs, "owner", nil))

    action_plan =
      read_string(
        attrs,
        "action_plan",
        read_string(attrs, "draft_plan", read_string(attrs, "plan", nil))
      )

    direction =
      normalize_direction(read_string(attrs, "direction", nil)) ||
        direction_from_legacy_metadata(metadata) || "owed_by_me"

    # SPEC 01 R1: the runtime — not the model — enforces that only
    # `owed_to_me` items ever carry a follow-up cadence. Whatever the model
    # returned, any other direction persists next_nudge_at: nil. The column
    # is `:utc_datetime` (second precision), so truncate before the changeset.
    next_nudge_at =
      if direction == "owed_to_me" do
        case read_due_datetime(attrs, "next_nudge_at", due_tz) do
          %DateTime{} = value -> DateTime.truncate(value, :second)
          _other -> nil
        end
      else
        nil
      end

    counterparty_label =
      read_string(attrs, "counterparty_label", counterparty_label_from_metadata(metadata))

    # Computed once here (instead of inline in the map below) because
    # `dedupe_key_for/4` generates a fresh UUID when no stable source key is
    # available — the R2a counterparty guard below must see the same key the
    # persisted map carries.
    dedupe_key =
      read_string(attrs, "dedupe_key", dedupe_key_for(source, kind, source_item_id, metadata))

    %{
      "user_id" => user_id,
      "direction" => direction,
      "next_nudge_at" => next_nudge_at,
      "counterparty_person_id" =>
        resolve_counterparty_person_id(user_id, attrs, direction, counterparty_label, dedupe_key),
      "counterparty_label" => counterparty_label,
      "owner_user_id" => owner_user_id,
      "owner_label" => normalize_owner_label(owner_label, owner_user_id, user_id),
      "source" => source,
      "source_account_id" => read_integer(attrs, "source_account_id", nil),
      "source_account_label" =>
        read_string(attrs, "source_account_label", source_account_label_from_metadata(metadata)),
      "project_id" => resolve_project_id(user_id, attrs, metadata),
      "agent_actionability" =>
        normalize_agent_actionability(read_string(attrs, "agent_actionability", "needs_you")),
      "agent_action_label" => read_string(attrs, "agent_action_label", nil),
      "agent_action_requires_approval" =>
        read_boolean_attr(attrs, "agent_action_requires_approval", true),
      "kind" => kind,
      "attention_mode" =>
        normalize_attention_mode(read_string(attrs, "attention_mode", "act_now")),
      "title" => read_string(attrs, "title", @fallback_title),
      "summary" => read_string(attrs, "summary", read_string(attrs, "todo", @fallback_summary)),
      "next_action" => read_string(attrs, "next_action", @fallback_action),
      "due_at" => due_at,
      "notes" => read_string(attrs, "notes", nil),
      "action_plan" => action_plan,
      "action_draft" => read_action_draft(attrs),
      "priority" => clamp_integer(read_integer(attrs, "priority", 50), 0, 100),
      "status" => normalize_status(read_string(attrs, "status", "open")),
      "snoozed_until" => read_due_datetime(attrs, "snoozed_until", due_tz),
      "closed_at" => read_datetime(attrs, "closed_at"),
      "source_item_id" => source_item_id,
      "source_occurred_at" => read_datetime(attrs, "source_occurred_at"),
      "dedupe_key" => dedupe_key,
      "metadata" => metadata
    }
    |> ActionDrafts.ensure()
  end

  # SPEC 04 R2/R2a/R3: resolve counterparty_label -> counterparty_person_id at
  # the single choke point both automated writers (Todos.Intelligence and the
  # CommitmentTracker skill) share. Deterministic resolver only — no LLM call
  # on this path.
  #
  # - R3: an explicitly present "counterparty_person_id" attr always wins
  #   (including explicit nil, which the update path's
  #   preserved_update_counterparty_person_id/3 treats as "keep existing" —
  #   unchanged). The resolver never runs when the key is present.
  # - R2: only owed_by_me/owed_to_me todos with a label get resolved;
  #   ambiguity and no-match leave the FK nil — a wrong-person FK is worse
  #   than none.
  # - R2a: before hitting the CRM search, a narrow indexed read of the same
  #   (user_id, dedupe_key) row existing_todo_for_upsert/2 fetches moments
  #   later short-circuits re-upserts of an already-resolved todo (webhook
  #   redelivery, re-sync storms) so the per-upsert cost is one cheap todo
  #   lookup, not one CRM search per upsert forever. The resolver still runs
  #   when the label changed or the persisted FK is nil, so a later upsert may
  #   flip :not_found/:ambiguous to a resolution once the CRM candidate set
  #   changes (no memoization, per the idempotency invariant).
  defp resolve_counterparty_person_id(user_id, attrs, direction, counterparty_label, dedupe_key) do
    cond do
      attr_present?(attrs, "counterparty_person_id") ->
        read_uuid(attrs, "counterparty_person_id", nil)

      not is_binary(counterparty_label) or direction not in ["owed_by_me", "owed_to_me"] ->
        nil

      true ->
        case existing_counterparty_for_upsert(user_id, dedupe_key) do
          {existing_label, existing_person_id}
          when existing_label == counterparty_label and is_binary(existing_person_id) ->
            existing_person_id

          _new_row_or_changed_label_or_unresolved ->
            case CounterpartyResolver.resolve_person(user_id, counterparty_label) do
              {:ok, person} -> person.id
              _ambiguous_or_not_found -> nil
            end
        end
    end
  end

  defp existing_counterparty_for_upsert(user_id, dedupe_key) when is_binary(dedupe_key) do
    Todo
    |> where([todo], todo.user_id == ^user_id and todo.dedupe_key == ^dedupe_key)
    |> select([todo], {todo.counterparty_label, todo.counterparty_person_id})
    |> Repo.one()
  end

  defp existing_counterparty_for_upsert(_user_id, _dedupe_key), do: nil

  defp dedupe_key_for(source, kind, source_item_id, metadata) do
    thread_id =
      case metadata do
        %{"thread_id" => value} when is_binary(value) and value != "" -> value
        _ -> nil
      end

    source_key = source_item_id || thread_id || Ecto.UUID.generate()
    "#{source}:#{kind}:#{source_key}"
  end

  defp synced_insight_attrs(%Insight{} = insight) do
    metadata = insight.metadata || %{}
    source = insight.source || "system"

    {source_account_id, source_account_label} =
      source_account_fields(insight.user_id, source, metadata)

    %{
      user_id: insight.user_id,
      owner_user_id: insight.user_id,
      owner_label: owner_label_from_metadata(metadata),
      source: source,
      source_account_id: source_account_id,
      source_account_label: source_account_label,
      project_id: resolve_project_id(insight.user_id, metadata, %{}),
      agent_actionability:
        normalize_agent_actionability(read_string(metadata, "agent_actionability", "needs_you")),
      agent_action_label: read_string(metadata, "agent_action_label", nil),
      agent_action_requires_approval:
        read_boolean_attr(metadata, "agent_action_requires_approval", true),
      kind: todo_kind_from_insight(insight),
      attention_mode: normalize_attention_mode(insight.attention_mode || "act_now"),
      title: normalize_required_text(insight.title, @fallback_title),
      summary: normalize_required_text(insight.summary, @fallback_summary),
      next_action: normalize_required_text(insight.recommended_action, @fallback_action),
      due_at: insight.due_at,
      notes: notes_from_metadata(metadata),
      action_plan: action_plan_from_metadata(metadata),
      action_draft: read_action_draft(metadata),
      priority: clamp_integer(insight.priority || 50, 0, 100),
      status: todo_status_from_insight(insight.status),
      snoozed_until: insight.snoozed_until,
      closed_at: todo_closed_at(insight),
      model_selected_at: insight.inserted_at || DateTime.utc_now(),
      source_item_id: insight.source_id,
      source_occurred_at: insight.source_occurred_at,
      dedupe_key: todo_dedupe_key_for_insight(insight),
      metadata: todo_metadata_from_insight(insight)
    }
    |> UserFacingCopy.polish_attrs()
    |> ActionDrafts.ensure()
  end

  defp todo_kind_from_insight(%Insight{source: "gmail"}), do: "gmail_triage"
  defp todo_kind_from_insight(_insight), do: "general"

  defp todo_status_from_insight("acknowledged"), do: "done"
  defp todo_status_from_insight("dismissed"), do: "dismissed"
  defp todo_status_from_insight("snoozed"), do: "snoozed"
  defp todo_status_from_insight(_status), do: "open"

  defp todo_closed_at(%Insight{status: status, updated_at: updated_at})
       when status in ["acknowledged", "dismissed"] do
    updated_at || DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp todo_closed_at(_insight), do: nil

  defp todo_dedupe_key_for_insight(%Insight{} = insight) do
    logical_key = insight.tracking_key || insight.dedupe_key || insight.id
    "insight:#{logical_key}"
  end

  defp todo_metadata_from_insight(%Insight{} = insight) do
    (insight.metadata || %{})
    |> Map.put("source_insight_id", insight.id)
    |> Map.put("source_insight_status", insight.status)
    |> Map.put("source_insight_dedupe_key", insight.dedupe_key)
    |> Map.put("source_insight_tracking_key", insight.tracking_key)
    |> Map.put("source_insight_category", insight.category)
    |> maybe_put("source_insight_due_at", insight.due_at && DateTime.to_iso8601(insight.due_at))
    |> maybe_put("source_agent_id", insight.agent_id)
    |> maybe_put("confidence", insight.confidence)
  end

  defp preserve_closed_synced_todo?(%Todo{} = todo, attrs) when is_map(attrs) do
    incoming_status = Map.get(attrs, :status) || Map.get(attrs, "status")

    incoming_source_at =
      Map.get(attrs, :source_occurred_at) || Map.get(attrs, "source_occurred_at")

    todo.status in ["done", "dismissed"] and incoming_status == "open" and
      not source_newer_than_closed_todo?(incoming_source_at, todo)
  end

  defp source_newer_than_closed_todo?(%DateTime{} = incoming_source_at, %Todo{} = todo) do
    case todo.closed_at || todo.source_occurred_at || todo.updated_at || todo.inserted_at do
      %DateTime{} = previous_at -> DateTime.compare(incoming_source_at, previous_at) == :gt
      _ -> true
    end
  end

  defp source_newer_than_closed_todo?(_incoming_source_at, _todo), do: false

  defp filtered_todo_query(user_id, opts) do
    source = Keyword.get(opts, :source)
    source_account_id = Keyword.get(opts, :source_account_id)
    source_account_unassigned? = Keyword.get(opts, :source_account_unassigned?, false)
    kind = Keyword.get(opts, :kind)
    attention_mode = Keyword.get(opts, :attention_mode)
    owner_user_id = Keyword.get(opts, :owner_user_id)
    project_id = Keyword.get(opts, :project_id)
    agent_actionability = Keyword.get(opts, :agent_actionability)
    due_before = Keyword.get(opts, :due_before) || Keyword.get(opts, :due_before_or_at)
    due_after = Keyword.get(opts, :due_after) || Keyword.get(opts, :due_after_or_at)
    due_nil? = Keyword.get(opts, :due_nil?, false)
    statuses = normalize_status_filters(Keyword.get(opts, :statuses))
    query_text = normalize_query_text(Keyword.get(opts, :query))
    open_due_only? = Keyword.get(opts, :open_due_only, false)
    exclude_unsurfaceable? = Keyword.get(opts, :exclude_unsurfaceable?, true)
    direction = Keyword.get(opts, :direction)

    counterparty_person_id =
      Keyword.get(opts, :person_id) || Keyword.get(opts, :counterparty_person_id)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> maybe_filter_statuses(statuses)
    |> maybe_filter_open_due_only(open_due_only?)
    |> maybe_exclude_unsurfaceable_open_work(exclude_unsurfaceable?)
    |> maybe_filter_source(source)
    |> maybe_filter_source_account_id(source_account_id)
    |> maybe_filter_source_account_unassigned(source_account_unassigned?)
    |> maybe_filter_kind(kind)
    |> maybe_filter_attention_mode(attention_mode)
    |> maybe_filter_owner_user_id(owner_user_id)
    |> maybe_filter_project_id(project_id)
    |> maybe_filter_agent_actionability(agent_actionability)
    |> maybe_filter_direction(direction)
    |> maybe_filter_counterparty_person_id(counterparty_person_id)
    |> maybe_filter_due_after(due_after)
    |> maybe_filter_due_before(due_before)
    |> maybe_filter_due_nil(due_nil?)
    |> maybe_filter_query(query_text)
  end

  defp maybe_filter_project_id(query, nil), do: query
  defp maybe_filter_project_id(query, ""), do: query
  defp maybe_filter_project_id(query, "all"), do: query
  defp maybe_filter_project_id(query, "inbox"), do: where(query, [todo], is_nil(todo.project_id))

  defp maybe_filter_project_id(query, project_id) when is_binary(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, uuid} -> where(query, [todo], todo.project_id == ^uuid)
      :error -> where(query, [todo], false)
    end
  end

  defp maybe_filter_project_id(query, _project_id), do: query

  defp maybe_filter_agent_actionability(query, nil), do: query
  defp maybe_filter_agent_actionability(query, ""), do: query
  defp maybe_filter_agent_actionability(query, "all"), do: query

  defp maybe_filter_agent_actionability(query, "can_help") do
    where(query, [todo], todo.agent_actionability in ["can_prepare", "can_execute"])
  end

  defp maybe_filter_agent_actionability(query, value)
       when value in ["needs_you", "can_prepare", "can_execute"] do
    where(query, [todo], todo.agent_actionability == ^value)
  end

  defp maybe_filter_agent_actionability(query, _value), do: query

  defp maybe_filter_direction(query, nil), do: query
  defp maybe_filter_direction(query, ""), do: query
  defp maybe_filter_direction(query, "all"), do: query

  defp maybe_filter_direction(query, direction) when is_binary(direction) do
    where(query, [todo], todo.direction == ^direction)
  end

  defp maybe_filter_direction(query, _direction), do: query

  # SPEC 04 R4: person filter mirroring maybe_filter_direction/2 — this is
  # what lets "what do I owe Charlie?" resolve to a SQL filter
  # (direction + counterparty_person_id) instead of the model reading labels.
  # Accepted via the :person_id opt (alias :counterparty_person_id) on
  # list_owed_to_me/2, list_owed_by_me/2, and every filtered_todo_query/2
  # caller. A non-UUID value filters to zero rows rather than being silently
  # ignored (an invalid filter must not confidently return everything).
  defp maybe_filter_counterparty_person_id(query, nil), do: query
  defp maybe_filter_counterparty_person_id(query, ""), do: query
  defp maybe_filter_counterparty_person_id(query, "all"), do: query

  defp maybe_filter_counterparty_person_id(query, person_id) when is_binary(person_id) do
    case Ecto.UUID.cast(person_id) do
      {:ok, uuid} -> where(query, [todo], todo.counterparty_person_id == ^uuid)
      :error -> where(query, [todo], false)
    end
  end

  defp maybe_filter_counterparty_person_id(query, _person_id), do: query

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, ""), do: query
  defp maybe_filter_source(query, "all"), do: query

  defp maybe_filter_source(query, source) when is_binary(source) do
    where(query, [todo], todo.source == ^source)
  end

  defp maybe_filter_source_account_id(query, nil), do: query
  defp maybe_filter_source_account_id(query, ""), do: query

  defp maybe_filter_source_account_id(query, source_account_id) do
    case normalize_integer_filter(source_account_id) do
      nil -> query
      id -> where(query, [todo], todo.source_account_id == ^id)
    end
  end

  defp maybe_filter_source_account_unassigned(query, true) do
    where(query, [todo], is_nil(todo.source_account_id))
  end

  defp maybe_filter_source_account_unassigned(query, _value), do: query

  defp maybe_filter_statuses(query, nil), do: query
  defp maybe_filter_statuses(query, []), do: where(query, [todo], false)

  defp maybe_filter_statuses(query, statuses) when is_list(statuses) do
    where(query, [todo], todo.status in ^statuses)
  end

  defp maybe_exclude_unsurfaceable_open_work(query, false), do: query

  defp maybe_exclude_unsurfaceable_open_work(query, true) do
    where(
      query,
      [todo],
      todo.status not in ^@open_statuses or
        fragment(
          "coalesce(? #>> '{surface_quality,surfaceable}', 'true') != 'false'",
          todo.metadata
        )
    )
  end

  defp maybe_filter_open_due_only(query, false), do: query

  defp maybe_filter_open_due_only(query, true) do
    where(
      query,
      [todo],
      todo.status != "snoozed" or is_nil(todo.snoozed_until) or
        todo.snoozed_until <= ^DateTime.utc_now()
    )
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, ""), do: query

  defp maybe_filter_kind(query, kind) when is_binary(kind) do
    where(query, [todo], todo.kind == ^kind)
  end

  defp maybe_filter_attention_mode(query, nil), do: query
  defp maybe_filter_attention_mode(query, ""), do: query
  defp maybe_filter_attention_mode(query, "all"), do: query

  defp maybe_filter_attention_mode(query, attention_mode) when is_binary(attention_mode) do
    where(query, [todo], todo.attention_mode == ^attention_mode)
  end

  defp maybe_filter_decision_only(query, false), do: query

  # SPEC 05 R3: replaces the old three-path metadata fragment disjunction
  # (commitment_direction / thread_state / conversation_context.momentum_state)
  # with the durable `direction` column those fragments have been backfilled
  # into. This is intentionally a broad SQL-level prefilter; the precise
  # per-row "does this actually need a decision" call still happens in
  # `DecisionSignals.needs_decision?/1` after the query runs.
  defp maybe_filter_decision_only(query, true) do
    where(
      query,
      [todo],
      todo.status in ^@open_statuses and todo.direction in ["owed_by_me", "owed_to_me"]
    )
  end

  defp decision_only_option?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {:decision_only?, value} -> truthy?(value)
      {:decision_only, value} -> truthy?(value)
      {"decision_only?", value} -> truthy?(value)
      {"decision_only", value} -> truthy?(value)
      _entry -> false
    end)
  end

  defp decision_only_option?(opts) when is_map(opts) do
    opts
    |> Map.take([:decision_only?, :decision_only, "decision_only?", "decision_only"])
    |> Map.values()
    |> Enum.any?(&truthy?/1)
  end

  defp decision_only_option?(_opts), do: false

  defp exact_decision_todos(query) do
    query
    |> Repo.all()
    |> Enum.map(&polish_todo_copy/1)
    |> Enum.filter(&DecisionSignals.needs_decision?/1)
  end

  defp maybe_filter_owner_user_id(query, nil), do: query
  defp maybe_filter_owner_user_id(query, ""), do: query

  defp maybe_filter_owner_user_id(query, owner_user_id) when is_binary(owner_user_id) do
    where(query, [todo], todo.owner_user_id == ^owner_user_id)
  end

  defp maybe_filter_owner_user_id(query, _owner_user_id), do: query

  defp maybe_filter_due_after(query, nil), do: query
  defp maybe_filter_due_after(query, ""), do: query

  defp maybe_filter_due_after(query, value) do
    case coerce_datetime(value) do
      nil -> query
      due_after -> where(query, [todo], not is_nil(todo.due_at) and todo.due_at >= ^due_after)
    end
  end

  defp maybe_filter_due_before(query, nil), do: query
  defp maybe_filter_due_before(query, ""), do: query

  defp maybe_filter_due_before(query, value) do
    case coerce_datetime(value) do
      nil -> query
      due_before -> where(query, [todo], not is_nil(todo.due_at) and todo.due_at <= ^due_before)
    end
  end

  defp maybe_filter_due_nil(query, true), do: where(query, [todo], is_nil(todo.due_at))
  defp maybe_filter_due_nil(query, "true"), do: where(query, [todo], is_nil(todo.due_at))
  defp maybe_filter_due_nil(query, _due_nil?), do: query

  defp apply_todo_order(query, "title", "asc"),
    do: order_by(query, [todo], asc: todo.title, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "title", "desc"),
    do: order_by(query, [todo], desc: todo.title, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "source", "asc"),
    do: order_by(query, [todo], asc: todo.source, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "source", "desc"),
    do: order_by(query, [todo], desc: todo.source, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "status", "asc"),
    do: order_by(query, [todo], asc: todo.status, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "status", "desc"),
    do: order_by(query, [todo], desc: todo.status, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "attention", "asc"),
    do:
      order_by(query, [todo],
        asc:
          fragment(
            "CASE WHEN ? = 'act_now' THEN 0 WHEN ? = 'monitor' THEN 1 ELSE 2 END",
            todo.attention_mode,
            todo.attention_mode
          ),
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "attention", "desc"),
    do:
      order_by(query, [todo],
        desc:
          fragment(
            "CASE WHEN ? = 'act_now' THEN 0 WHEN ? = 'monitor' THEN 1 ELSE 2 END",
            todo.attention_mode,
            todo.attention_mode
          ),
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "priority", "asc"),
    do:
      order_by(query, [todo],
        asc: todo.priority,
        asc_nulls_last: todo.due_at,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "priority", "desc"),
    do:
      order_by(query, [todo],
        desc: todo.priority,
        asc_nulls_last: todo.due_at,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "due", "asc"),
    do:
      order_by(query, [todo],
        asc_nulls_last: todo.due_at,
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "due", "desc"),
    do:
      order_by(query, [todo],
        desc_nulls_last: todo.due_at,
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "updated", "asc"),
    do:
      order_by(query, [todo],
        asc: todo.updated_at,
        desc: todo.priority,
        asc_nulls_last: todo.due_at
      )

  defp apply_todo_order(query, "updated", "desc"),
    do:
      order_by(query, [todo],
        desc: todo.updated_at,
        desc: todo.priority,
        asc_nulls_last: todo.due_at
      )

  defp apply_todo_order(query, _sort_by, _sort_dir) do
    order_by(
      query,
      [
        todo
      ],
      asc:
        fragment(
          "CASE WHEN ? = 'act_now' THEN 0 WHEN ? = 'monitor' THEN 1 ELSE 2 END",
          todo.attention_mode,
          todo.attention_mode
        ),
      desc: todo.priority,
      asc_nulls_last: todo.due_at,
      desc: todo.updated_at,
      desc: todo.inserted_at
    )
  end

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, query_text) when is_binary(query_text) do
    pattern = "%" <> query_text <> "%"

    where(
      query,
      [todo],
      ilike(todo.title, ^pattern) or
        ilike(todo.summary, ^pattern) or
        ilike(todo.next_action, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.notes, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.action_plan, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.owner_label, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.source_account_label, ^pattern) or
        ilike(todo.source, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.source_item_id, ^pattern) or
        fragment("coalesce(?->>'subject', '') ILIKE ?", todo.metadata, ^pattern) or
        fragment("coalesce(?->>'from', '') ILIKE ?", todo.metadata, ^pattern) or
        fragment("coalesce(?->>'google_account_email', '') ILIKE ?", todo.metadata, ^pattern)
    )
  end

  defp put_resolution_note(metadata, nil), do: metadata
  defp put_resolution_note(metadata, ""), do: metadata

  defp put_resolution_note(metadata, note) when is_binary(note) do
    Map.put(metadata, "resolution_note", String.trim(note))
  end

  defp put_feedback(metadata, feedback, source) when feedback in @feedback_values do
    Map.put(metadata, "assistant_feedback", %{
      "value" => feedback,
      "source" => source,
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  defp put_dismissal_signal(metadata, source) when is_map(metadata) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Map.put(metadata, "assistant_feedback", %{
      "value" => "not_important",
      "signal_strength" => "low",
      "source" => source,
      "recorded_at" => recorded_at
    })
  end

  defp put_see_less_queued_feedback(metadata, source) when is_map(metadata) do
    feedback = %{
      "value" => "see_less",
      "source" => source,
      "learning" => "queued",
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    metadata
    |> Map.put("assistant_feedback", feedback)
    |> Map.put("see_less_feedback", feedback)
  end

  defp see_less_resolution_note(source) when is_binary(source) and source != "" do
    "See less feedback recorded from #{source}."
  end

  defp see_less_resolution_note(_source), do: "See less feedback recorded."

  defp normalize_feedback_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "todo_surface"
      source -> source
    end
  end

  defp normalize_feedback_source(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_feedback_source(_value), do: "todo_surface"

  defp put_importance_override(metadata, source) when is_map(metadata) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    metadata
    |> Map.put("assistant_feedback", %{
      "value" => "important",
      "source" => source,
      "recorded_at" => recorded_at
    })
    |> Map.put("importance_override", %{
      "value" => "important",
      "source" => source,
      "recorded_at" => recorded_at
    })
  end

  defp put_scope_metadata(metadata, attrs) when is_map(metadata) and is_map(attrs) do
    metadata
    |> Map.merge(scope_metadata_attrs(attrs))
  end

  defp put_scope_metadata(metadata, _attrs), do: metadata

  defp scope_metadata_attrs(attrs) when is_map(attrs) do
    %{
      "suggested_project_id" => normalize_optional_string(fetch_attr(attrs, "project_id")),
      "suggested_project_name" => normalize_optional_string(fetch_attr(attrs, "project_name")),
      "suggested_life_domain" => normalize_life_domain(fetch_attr(attrs, "life_domain")),
      "scope_confidence" => normalize_confidence(fetch_attr(attrs, "confidence")),
      "scope_reasoning" => normalize_optional_string(fetch_attr(attrs, "reasoning")),
      "scope_source" =>
        normalize_optional_string(fetch_attr(attrs, "source")) || "chief_of_staff_weekend",
      "scope_updated_at" => normalize_datetime(fetch_attr(attrs, "reviewed_at"))
    }
    |> compact_map()
  end

  defp summarize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      "thread_id",
      "google_account_email",
      "from",
      "to",
      "cc",
      "bcc",
      "recipient",
      "sender_name",
      "requested_by",
      "contact",
      "crm_people",
      "chat_key",
      "sender_handle",
      "chat_display_name",
      "channel_name",
      "conversation_name",
      "matching_message_excerpt",
      "body_excerpt",
      "source_excerpt",
      "source_quote",
      "quote",
      "snippet",
      "email_subject",
      "thread_subject",
      "subject",
      "account_email",
      "source_account_label",
      "person",
      "company",
      "organization",
      "relationship",
      "relationship_context",
      "relationship_strength",
      "interaction_count",
      "communication_frequency",
      "context",
      "context_brief",
      "why_it_matters",
      "project",
      "project_name",
      "life_domain",
      "source_tags",
      "commitment_direction",
      "team_name",
      "workspace_name",
      "owner",
      "assignee",
      "draft_plan",
      "suggested_reply_points",
      "life_domain",
      "resolution_note",
      "assistant_feedback",
      "see_less_feedback",
      "source_insight_id",
      "source_insight_status",
      "suggested_project_id",
      "suggested_project_name",
      "suggested_life_domain",
      "scope_confidence",
      "scope_reasoning",
      "surface_quality"
    ])
    |> maybe_put("record", summarize_record_metadata(fetch_attr(metadata, "record")))
  end

  defp summarize_metadata(_metadata), do: %{}

  defp summarize_record_metadata(record) when is_map(record) do
    summarized =
      record
      |> Map.take([
        "person",
        "company",
        "organization",
        "relationship",
        "relationship_context",
        "relationship_strength",
        "interaction_count",
        "communication_frequency",
        "summary",
        "ask",
        "commitment",
        "context",
        "why_it_matters",
        "project",
        "project_name"
      ])
      |> compact_map()

    if summarized == %{}, do: nil, else: summarized
  end

  defp summarize_record_metadata(_record), do: nil

  defp normalize_kind(kind) when kind in ~w(general gmail_triage), do: kind
  defp normalize_kind(_kind), do: "general"

  defp resolve_project_id(user_id, attrs, _metadata) do
    case fetch_attr(attrs, "project_id") do
      value when value in [nil, ""] ->
        nil

      value when is_binary(value) ->
        case Ecto.UUID.cast(String.trim(value)) do
          {:ok, project_id} ->
            if project_belongs_to_user?(project_id, user_id),
              do: project_id,
              else: "invalid_project"

          :error ->
            "invalid_project"
        end

      _other ->
        "invalid_project"
    end
  end

  defp project_belongs_to_user?(project_id, user_id)
       when is_binary(project_id) and is_binary(user_id) do
    Project
    |> where([project], project.id == ^project_id and project.user_id == ^user_id)
    |> Repo.exists?()
  end

  defp project_belongs_to_user?(_project_id, _user_id), do: false

  defp normalize_agent_actionability(value)
       when value in ~w(needs_you can_prepare can_execute),
       do: value

  defp normalize_agent_actionability(_value), do: "needs_you"

  defp read_boolean_attr(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when value in [true, "true", "1", 1] -> true
      value when value in [false, "false", "0", 0] -> false
      _other -> default
    end
  end

  defp normalize_attention_mode(value) when value in ~w(act_now monitor), do: value
  defp normalize_attention_mode(_value), do: "act_now"

  defp normalize_status(value) when value in ~w(open done dismissed snoozed), do: value
  defp normalize_status(_value), do: "open"

  defp normalize_direction(value) when value in @directions, do: value
  defp normalize_direction(_value), do: nil

  # SPEC 05 R2: maps the writer's legacy commitment_direction/thread_state
  # vocabulary onto the new direction enum. Falls back to nil (caller
  # decides the default) when no legacy signal is present.
  defp direction_from_legacy_metadata(metadata) when is_map(metadata) do
    [
      read_string(metadata, "commitment_direction", nil),
      read_string(metadata, "thread_state", nil),
      metadata |> read_map("conversation_context") |> read_string("momentum_state", nil)
    ]
    |> Enum.map(&normalize_legacy_direction/1)
    |> Enum.find(& &1)
  end

  defp direction_from_legacy_metadata(_metadata), do: nil

  defp normalize_legacy_direction(value) when value in @owed_by_me_legacy, do: "owed_by_me"
  defp normalize_legacy_direction(value) when value in @owed_to_me_legacy, do: "owed_to_me"
  defp normalize_legacy_direction(_value), do: nil

  defp normalize_status_filters(nil), do: nil

  defp normalize_status_filters(statuses) when is_list(statuses) do
    statuses
    |> Enum.map(fn
      value when is_binary(value) -> normalize_status(String.trim(value))
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_status_filters(status) when is_binary(status) do
    normalize_status_filters([status])
  end

  defp normalize_status_filters(_statuses), do: []

  defp normalize_sort_by(value)
       when value in ~w(rank title source status attention priority due updated),
       do: value

  defp normalize_sort_by("due_at"), do: "due"
  defp normalize_sort_by("updated_at"), do: "updated"
  defp normalize_sort_by("inserted_at"), do: "updated"
  defp normalize_sort_by(_value), do: "rank"

  defp normalize_sort_dir(value) when value in ~w(asc desc), do: value
  defp normalize_sort_dir(_value), do: "desc"

  defp normalize_limit(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_limit(_value, default), do: default

  defp normalize_offset(value) when is_integer(value) and value >= 0, do: value

  defp normalize_offset(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_offset(_value), do: 0

  defp normalize_query_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query_text(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_life_domain(value) when value in ~w(home work), do: value
  defp normalize_life_domain(_value), do: nil

  defp normalize_confidence(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp normalize_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_datetime(value) when is_binary(value), do: normalize_optional_string(value)
  defp normalize_datetime(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_required_text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp normalize_required_text(_value, default), do: default

  defp normalize_owner_label(nil, _owner_user_id, _user_id), do: nil
  defp normalize_owner_label("", _owner_user_id, _user_id), do: nil
  defp normalize_owner_label(owner_user_id, owner_user_id, _user_id), do: nil
  defp normalize_owner_label(user_id, _owner_user_id, user_id), do: nil
  defp normalize_owner_label(owner_label, _owner_user_id, _user_id), do: owner_label

  defp source_account_label_from_metadata(metadata) when is_map(metadata) do
    read_string(
      metadata,
      "source_account_label",
      read_string(
        metadata,
        "google_account_email",
        read_string(
          metadata,
          "account_email",
          read_string(
            metadata,
            "email",
            read_string(
              metadata,
              "team_name",
              read_string(metadata, "workspace_name", read_string(metadata, "username", nil))
            )
          )
        )
      )
    )
  end

  defp source_account_label_from_metadata(_metadata), do: nil

  defp source_account_fields(user_id, source, metadata) do
    explicit_id = read_integer(metadata, "source_account_id", nil)
    explicit_label = source_account_label_from_metadata(metadata)

    account =
      if is_nil(explicit_id) do
        source
        |> source_account_provider(metadata)
        |> case do
          provider when is_binary(provider) -> ConnectedAccounts.get(user_id, provider)
          _other -> nil
        end
      end

    {
      explicit_id || (account && account.id),
      explicit_label || connected_account_label(account)
    }
  end

  defp source_account_provider(source, metadata) when source in ["gmail", "email"] do
    read_string(metadata, "google_provider", nil) ||
      metadata
      |> source_account_label_from_metadata()
      |> google_provider_from_label()
  end

  defp source_account_provider("slack", metadata) do
    case read_string(metadata, "team_id", nil) do
      team_id when is_binary(team_id) -> "slack:#{team_id}"
      _other -> nil
    end
  end

  defp source_account_provider(_source, _metadata), do: nil

  defp google_provider_from_label("google:" <> _account = provider), do: provider

  defp google_provider_from_label(label) when is_binary(label) do
    if String.contains?(label, "@"), do: "google:#{String.downcase(label)}"
  end

  defp google_provider_from_label(_label), do: nil

  defp connected_account_label(%{provider: provider, metadata: metadata}) do
    metadata = metadata || %{}

    read_string(
      metadata,
      "account_email",
      read_string(
        metadata,
        "email",
        read_string(metadata, "team_name", connected_account_provider_label(provider))
      )
    )
  end

  defp connected_account_label(_account), do: nil

  defp connected_account_provider_label("google:" <> account), do: account
  defp connected_account_provider_label("slack:" <> team_id), do: team_id
  defp connected_account_provider_label(_provider), do: nil

  defp owner_label_from_metadata(metadata) when is_map(metadata) do
    read_string(
      metadata,
      "owner_label",
      read_string(metadata, "owner", read_string(metadata, "assignee", nil))
    )
  end

  defp owner_label_from_metadata(_metadata), do: nil

  defp counterparty_label_from_metadata(metadata) when is_map(metadata) do
    read_string(
      metadata,
      "person",
      read_string(
        metadata,
        "contact",
        read_string(metadata, "requested_by", read_string(metadata, "sender_name", nil))
      )
    )
  end

  defp counterparty_label_from_metadata(_metadata), do: nil

  defp read_uuid(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> uuid
          :error -> default
        end

      _ ->
        default
    end
  end

  defp notes_from_metadata(metadata) when is_map(metadata) do
    read_string(metadata, "notes", read_string(metadata, "note", nil))
  end

  defp notes_from_metadata(_metadata), do: nil

  defp action_plan_from_metadata(metadata) when is_map(metadata) do
    read_string(metadata, "action_plan", read_string(metadata, "draft_plan", nil))
  end

  defp action_plan_from_metadata(_metadata), do: nil

  defp read_action_draft(attrs) when is_map(attrs) do
    case fetch_attr(attrs, "action_draft") || fetch_attr(attrs, "draft") do
      value when is_map(value) ->
        stringify_top_level_keys(value)

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> %{}
          trimmed -> %{"text" => trimmed}
        end

      _ ->
        %{}
    end
  end

  defp read_action_draft(_attrs), do: %{}

  defp read_string(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp read_map(attrs, key) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_integer(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_datetime(attrs, key) do
    attrs
    |> fetch_attr(key)
    |> coerce_datetime()
  end

  # SPEC 01 R2 — due-date-shaped coercion. Deliberately a separate function
  # from `coerce_datetime/1` (instant semantics) so the two can never be
  # accidentally swapped at a call site: due dates get local end-of-day /
  # local-wall-time resolution, instants (`source_occurred_at`, `closed_at`,
  # query filters) stay on the plain UTC reading.
  @due_shaped_keys ~w(due_at due_date due snoozed_until next_nudge_at)
  @due_local_end_of_day ~T[20:00:00]
  @due_utc_fallback_end_of_day ~T[23:59:59]

  defp due_timezone_context(user_id, attrs) do
    if Enum.any?(@due_shaped_keys, fn key -> fetch_attr(attrs, key) not in [nil, ""] end) do
      user_timezone_context(user_id)
    else
      nil
    end
  end

  defp read_due_datetime(attrs, key, timezone_context) do
    attrs
    |> fetch_attr(key)
    |> coerce_due_datetime(timezone_context)
  end

  defp coerce_due_datetime(%DateTime{} = value, _timezone_context), do: value

  defp coerce_due_datetime(%NaiveDateTime{} = value, timezone_context) do
    local_naive_to_utc(value, timezone_context)
  end

  defp coerce_due_datetime(%Date{} = value, %{} = timezone_context) do
    value
    |> NaiveDateTime.new!(@due_local_end_of_day)
    |> local_naive_to_utc(timezone_context)
  end

  defp coerce_due_datetime(%Date{} = value, _timezone_context) do
    # Deterministic no-timezone fallback: UTC end-of-day, never midnight —
    # midnight UTC is the previous evening for every US timezone (the bug
    # class behind the 2026-07-03 briefing incident).
    DateTime.new!(value, @due_utc_fallback_end_of_day, "Etc/UTC")
  end

  defp coerce_due_datetime(value, timezone_context) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, parsed, _offset} ->
            parsed

          _ ->
            case NaiveDateTime.from_iso8601(trimmed) do
              {:ok, naive} ->
                coerce_due_datetime(naive, timezone_context)

              _ ->
                case Date.from_iso8601(trimmed) do
                  {:ok, date} -> coerce_due_datetime(date, timezone_context)
                  _ -> nil
                end
            end
        end
    end
  end

  defp coerce_due_datetime(_value, _timezone_context), do: nil

  # Reads a naive datetime as the user's local wall clock and converts to a
  # UTC instant. Uses `Timezones.offset_for_local/3` with the datetime being
  # resolved (per-date DST correctness), never "now"'s offset.
  defp local_naive_to_utc(%NaiveDateTime{} = naive, %{} = timezone_context) do
    local_as_utc = DateTime.from_naive!(naive, "Etc/UTC")

    offset =
      Timezones.offset_for_local(
        Map.get(timezone_context, :timezone_name),
        local_as_utc,
        Map.get(timezone_context, :offset_hours, 0)
      )

    DateTime.add(local_as_utc, -offset, :hour)
  end

  defp local_naive_to_utc(%NaiveDateTime{} = naive, _timezone_context) do
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp coerce_datetime(%DateTime{} = value), do: value

  defp coerce_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp coerce_datetime(%Date{} = value) do
    DateTime.new!(value, ~T[00:00:00], "Etc/UTC")
  end

  defp coerce_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, parsed, _offset} ->
            parsed

          _ ->
            case Date.from_iso8601(trimmed) do
              {:ok, date} -> coerce_datetime(date)
              _ -> nil
            end
        end
    end
  end

  defp coerce_datetime(_value), do: nil

  defp fetch_attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(key) do
          atom_key when is_atom(atom_key) -> Map.get(attrs, atom_key)
          _ -> nil
        end
    end
  end

  defp clamp_integer(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp normalize_integer_filter(value) when is_integer(value), do: value

  defp normalize_integer_filter(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer_filter(_value), do: nil

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map

  defp maybe_put(map, key, value) do
    Map.put(map, key, value)
  end

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, _key, ""), do: keyword

  defp maybe_put_keyword(keyword, key, value) do
    Keyword.put(keyword, key, value)
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(_key), do: nil
end
