defmodule Maraithon.Runtime.SourceCycleSettlement do
  @moduledoc """
  Seals one exact source-account coverage proof before its cursor advances.

  The proof, its decision receipts, the cursor update, and the background-job
  completion all share the coordinated settlement transaction. Raw provider
  references are used transiently to join encrypted handoffs and are reduced
  to SHA-256 digests before the proof is persisted.
  """

  import Ecto.Query

  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.SourceCycleProofs
  alias Maraithon.Runtime.SlackSourceReplay
  alias Maraithon.Todos.Todo

  @discovery_acquire "runtime_partition:source_account_discovery"
  @discovery_reason "runtime_partition:source_account_discovery_reason"
  @discovery_finalize "runtime_partition:source_account_discovery_finalize"
  @closure_acquire "runtime_partition:source_account_closure_acquire"
  @closure_reason "runtime_partition:source_account_closure_reason"
  @closure_finalize "runtime_partition:source_account_closure_finalize"

  @doc false
  def seal(current_job, result, account, watermarks, opts \\ [])

  def seal(%BackgroundJob{} = current_job, result, account, [watermark], opts)
      when is_map(result) and is_map(watermark) and is_list(opts) do
    with {:ok, graph} <- job_graph(current_job),
         :ok <- validate_graph_owner(graph, account.user_id),
         {:ok, identity} <- cycle_identity(graph, account, watermark, opts),
         {:ok, source_items} <- source_items(graph, result),
         {:ok, snapshots} <- todo_snapshots(graph),
         {:ok, cycle} <-
           SourceCycleProofs.create_cycle_in_transaction(identity, source_items, snapshots),
         :ok <- record_receipts(cycle, graph, source_items, snapshots),
         {:ok, counts} <- SourceCycleProofs.verify_complete_in_transaction(cycle) do
      {:ok, counts}
    end
  end

  def seal(%BackgroundJob{}, _result, _account, _watermarks, _opts),
    do: {:error, :invalid_source_cycle_settlement}

  defp job_graph(%BackgroundJob{job_type: type} = current)
       when type in [@discovery_acquire, @closure_acquire] do
    {:ok,
     %{
       role: if(type == @discovery_acquire, do: "discovery", else: "closure"),
       acquisition: BackgroundJob.hydrate_payloads(current),
       reasons: [],
       finalizer: nil
     }}
  end

  defp job_graph(%BackgroundJob{job_type: type} = current)
       when type in [@discovery_finalize, @closure_finalize] do
    current = BackgroundJob.hydrate_payloads(current)
    payload = current.payload || %{}
    role = if(type == @discovery_finalize, do: "discovery", else: "closure")
    reason_type = if(role == "discovery", do: @discovery_reason, else: @closure_reason)
    acquisition_type = if(role == "discovery", do: @discovery_acquire, else: @closure_acquire)

    with acquisition_id when is_binary(acquisition_id) <-
           read_string(payload, "acquisition_job_id"),
         reason_ids when is_list(reason_ids) and reason_ids != [] <-
           read_string_list(payload, "reason_job_ids"),
         {:ok, jobs} <- load_jobs([acquisition_id | reason_ids]),
         %BackgroundJob{job_type: ^acquisition_type} = acquisition <-
           Map.get(jobs, acquisition_id),
         reasons when length(reasons) == length(reason_ids) <-
           Enum.map(reason_ids, &Map.get(jobs, &1)),
         true <- Enum.all?(reasons, &match?(%BackgroundJob{job_type: ^reason_type}, &1)) do
      {:ok,
       %{
         role: role,
         acquisition: acquisition,
         reasons: reasons,
         finalizer: current
       }}
    else
      _invalid -> {:error, :source_cycle_job_graph_incomplete}
    end
  end

  defp job_graph(_job), do: {:error, :source_cycle_job_type_not_supported}

  defp load_jobs(ids) do
    normalized_ids = Enum.flat_map(ids, &cast_uuid/1)

    jobs =
      BackgroundJob
      |> where([job], job.id in ^normalized_ids)
      |> Repo.all()
      |> Enum.map(&BackgroundJob.hydrate_payloads/1)
      |> Map.new(&{&1.id, &1})

    if map_size(jobs) == length(ids), do: {:ok, jobs}, else: {:error, :missing_source_cycle_job}
  end

  defp validate_graph_owner(graph, user_id) do
    jobs = [graph.acquisition | graph.reasons] ++ List.wrap(graph.finalizer)

    if Enum.all?(jobs, &(&1.user_id == user_id)),
      do: :ok,
      else: {:error, :source_cycle_owner_mismatch}
  end

  defp cycle_identity(graph, account, watermark, opts) do
    kind = read_string(watermark, "kind")
    upper = read_string(watermark, "value")
    lower = Keyword.get(opts, :lower_cursor, :load)

    lower =
      case lower do
        :load -> SourceCursors.get(account.id, kind) |> then(&(&1 && &1.value))
        value when is_nil(value) or is_binary(value) -> value
        _invalid -> :invalid
      end

    boundary =
      cond do
        String.starts_with?(kind || "", "gmail_") -> "lower_inclusive_upper_exclusive"
        SlackSourceReplay.watermark_kind?(kind, graph.role) -> "lower_inclusive_upper_exclusive"
        String.starts_with?(kind || "", "slack_") -> "lower_exclusive_upper_inclusive"
        true -> nil
      end

    if is_binary(kind) and is_binary(upper) and is_binary(boundary) and lower != :invalid do
      {:ok,
       %{
         user_id: account.user_id,
         connected_account_id: account.id,
         provider: account.provider,
         role: graph.role,
         cursor_kind: kind,
         lower_cursor: lower,
         upper_cursor: upper,
         boundary: boundary,
         acquisition_job_id: graph.acquisition.id,
         reason_job_ids: Enum.map(graph.reasons, & &1.id),
         finalizer_job_id: graph.finalizer && graph.finalizer.id
       }}
    else
      {:error, :invalid_source_cycle_watermark}
    end
  end

  defp source_items(%{reasons: []}, result) do
    proof_items = read_list(result, "source_proof_items")
    source_refs = read_string_list(result, "source_item_refs")

    items =
      if proof_items == [] do
        Enum.map(source_refs, &proof_item_from_reference/1)
      else
        Enum.map(proof_items, &normalize_proof_item/1)
      end

    if Enum.all?(items, &is_map/1), do: {:ok, items}, else: {:error, :invalid_source_proof_item}
  end

  defp source_items(%{reasons: reasons}, _result) do
    # Closure batches share source bundles. Every job's payload binding has
    # already been checked; expand and hash each identical bundle only once.
    reasons
    |> Enum.uniq_by(&read_map(&1.payload || %{}, "source_bundle"))
    |> Enum.reduce_while({:ok, []}, fn reason, {:ok, items} ->
      with bundle when is_map(bundle) <- read_map(reason.payload || %{}, "source_bundle"),
           {:ok, restored} <- SourceAccountDiscovery.restore_partition_bundle(bundle) do
        {:cont, {:ok, items ++ SourceAccountDiscovery.source_proof_items(restored)}}
      else
        _invalid -> {:halt, {:error, :source_cycle_bundle_unavailable}}
      end
    end)
    |> case do
      {:ok, items} ->
        {:ok, Enum.uniq_by(items, &{&1.source_ref_digest, &1.source_revision_digest})}

      {:error, _reason} = error ->
        error
    end
  end

  defp todo_snapshots(%{role: "discovery"}), do: {:ok, []}
  defp todo_snapshots(%{role: "closure", reasons: []}), do: {:ok, []}

  defp todo_snapshots(%{role: "closure", reasons: reasons}) do
    snapshots =
      reasons
      |> Enum.flat_map(&read_list(&1.payload || %{}, "todo_snapshots"))
      |> Enum.map(&normalize_snapshot/1)

    if Enum.all?(snapshots, &is_map/1) do
      unique_snapshots = Enum.uniq_by(snapshots, & &1.todo_id)

      if Enum.all?(unique_snapshots, fn snapshot ->
           Enum.all?(
             Enum.filter(snapshots, &(&1.todo_id == snapshot.todo_id)),
             &(&1 == snapshot)
           )
         end) do
        {:ok, unique_snapshots}
      else
        {:error, :invalid_source_cycle_todo_snapshot}
      end
    else
      {:error, :invalid_source_cycle_todo_snapshot}
    end
  end

  defp record_receipts(cycle, %{reasons: []}, _items, _snapshots) do
    if cycle.source_item_count == 0 or cycle.role == "closure",
      do: :ok,
      else: {:error, :source_cycle_missing_reason_receipts}
  end

  defp record_receipts(cycle, %{role: "discovery"} = graph, items, _snapshots) do
    item_by_ref = Map.new(items, &{&1.source_ref, &1})

    entries =
      Enum.flat_map(graph.reasons, fn reason ->
        reason.result
        |> read_list("decision_manifest")
        |> Enum.map(&{&1, reason.id})
      end)

    todos =
      entries
      |> Enum.map(fn {entry, _reason_id} -> read_string(entry, "persisted_todo_id") end)
      |> load_todos(cycle.user_id)

    receipts =
      Enum.map(entries, fn {entry, reason_id} ->
        source_decision_receipt(entry, reason_id, item_by_ref, cycle.user_id, todos)
      end)

    with true <- Enum.all?(receipts, &is_map/1),
         {:ok, _dispositions} <-
           SourceCycleProofs.record_source_decisions_in_transaction(cycle, receipts) do
      :ok
    else
      _invalid -> {:error, :invalid_source_cycle_decision_receipt}
    end
  end

  defp record_receipts(cycle, %{role: "closure"} = graph, items, snapshots) do
    snapshot_by_id = Map.new(snapshots, &{&1.todo_id, &1})
    todos = load_todos(Map.keys(snapshot_by_id), cycle.user_id)
    evidence_digest = joined_digest(Enum.map(items, & &1.source_revision_digest))

    receipts =
      graph.reasons
      |> Enum.flat_map(fn reason ->
        reason.result
        |> read_list("todo_decision_manifest")
        |> Enum.map(&{&1, reason.id})
      end)
      |> Enum.group_by(fn {entry, _reason_job_id} -> read_string(entry, "todo_ref") end)
      |> Enum.map(fn {_todo_id, entries} ->
        {entry, reason_job_id} = closure_receipt_entry(entries)

        todo_closure_receipt(
          entry,
          reason_job_id,
          snapshot_by_id,
          cycle.user_id,
          evidence_digest,
          todos
        )
      end)

    with true <- Enum.all?(receipts, &is_map/1),
         {:ok, _dispositions} <-
           SourceCycleProofs.record_todo_closures_in_transaction(cycle, receipts) do
      :ok
    else
      _invalid -> {:error, :invalid_source_cycle_closure_receipt}
    end
  end

  defp closure_receipt_entry(entries) do
    entries
    |> Enum.sort_by(fn {entry, reason_job_id} ->
      {if(read_string(entry, "action") == "evaluated", do: 0, else: 1), reason_job_id}
    end)
    |> hd()
  end

  defp load_todos(ids, user_id) do
    ids = ids |> Enum.flat_map(&cast_uuid/1) |> Enum.uniq()

    Todo
    |> where([todo], todo.user_id == ^user_id and todo.id in ^ids)
    |> select([todo], struct(todo, [:id, :user_id, :status, :updated_at]))
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp source_decision_receipt(entry, reason_job_id, item_by_ref, user_id, todos) do
    source_ref = read_string(entry, "source_ref")
    action = read_string(entry, "action")
    todo_id = read_string(entry, "persisted_todo_id")
    item = Map.get(item_by_ref, source_ref)
    todo = Map.get(todos, todo_id)

    cond do
      not is_map(item) or action not in ["create", "update", "skip"] ->
        nil

      action == "skip" and is_nil(todo_id) ->
        %{
          source_ref_digest: item.source_ref_digest,
          reason_job_id: reason_job_id,
          action: action,
          evaluator: "model",
          reason_code: "model_skip",
          evidence_digest: item.source_revision_digest
        }

      action in ["create", "update"] and match?(%Todo{user_id: ^user_id}, todo) ->
        %{
          source_ref_digest: item.source_ref_digest,
          reason_job_id: reason_job_id,
          action: action,
          todo_id: todo.id,
          todo_state_digest: todo_state_digest(todo.id, todo.status, todo.updated_at),
          evaluator: "model",
          reason_code: "model_#{action}",
          evidence_digest: item.source_revision_digest
        }

      true ->
        nil
    end
  end

  defp todo_closure_receipt(entry, reason_job_id, snapshots, user_id, evidence_digest, todos) do
    todo_id = read_string(entry, "todo_ref")
    action = read_string(entry, "action")
    snapshot = Map.get(snapshots, todo_id)
    todo = Map.get(todos, todo_id)

    if is_map(snapshot) and match?(%Todo{user_id: ^user_id}, todo) do
      {outcome, evaluator, reason_code} = closure_outcome(action, todo.status)

      %{
        todo_id: todo.id,
        reason_job_id: reason_job_id,
        todo_before_digest: snapshot.todo_state_digest,
        todo_after_digest: todo_state_digest(todo.id, todo.status, todo.updated_at),
        outcome: outcome,
        evaluator: evaluator,
        reason_code: reason_code,
        evidence_digest: if(outcome == "completed", do: evidence_digest)
      }
    end
  end

  defp closure_outcome("evaluated", "done"), do: {"completed", "model", "completion_evidence"}

  defp closure_outcome("evaluated", status) when status in ["open", "snoozed"],
    do: {"still_open", "model", "no_completion_evidence"}

  defp closure_outcome(_action, _status), do: {"superseded", "policy", "todo_superseded"}

  defp normalize_proof_item(item) when is_map(item) do
    source_ref = read_string(item, "source_ref")
    ref_digest = read_binary(item, "source_ref_digest")
    identity_digest = read_binary(item, "source_identity_digest")
    revision_digest = read_binary(item, "source_revision_digest")
    occurred_at = read_datetime(item, "provider_occurred_at")

    if is_binary(source_ref) and byte_size(source_ref) in 1..4096 and digest?(ref_digest) and
         digest?(identity_digest) and digest?(revision_digest) do
      %{
        source_ref: source_ref,
        source_ref_digest: ref_digest,
        source_identity_digest: identity_digest,
        source_revision_digest: revision_digest,
        provider_occurred_at: occurred_at
      }
    end
  end

  defp normalize_proof_item(_item), do: nil

  defp proof_item_from_reference(reference) when is_binary(reference) and reference != "" do
    digest = SourceCycleProofs.reference_digest(reference)

    %{
      source_ref: reference,
      source_ref_digest: digest,
      source_identity_digest: digest,
      source_revision_digest: digest,
      provider_occurred_at: nil
    }
  end

  defp proof_item_from_reference(_reference), do: nil

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    todo_id = read_string(snapshot, "id")
    status = read_string(snapshot, "status")
    updated_at = read_datetime(snapshot, "updated_at")

    if is_binary(todo_id) and status in ["open", "snoozed"] and match?(%DateTime{}, updated_at) do
      %{
        todo_id: todo_id,
        eligible_status: status,
        todo_updated_at: updated_at,
        todo_state_digest: todo_state_digest(todo_id, status, updated_at)
      }
    end
  end

  defp normalize_snapshot(_snapshot), do: nil

  defp todo_state_digest(id, status, %DateTime{} = updated_at) do
    joined_digest([id, status, DateTime.to_iso8601(updated_at)])
  end

  defp joined_digest(parts) do
    parts
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> [normalized]
      :error -> []
    end
  end

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp read_map(map, key) when is_map(map) do
    case read(map, key) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  defp read_map(_map, _key), do: nil

  defp read_list(map, key) when is_map(map) do
    case read(map, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp read_string_list(map, key) do
    map
    |> read_list(key)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp read_string(map, key) when is_map(map) do
    case read(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) and value not in [nil, true, false] -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_binary(map, key) when is_map(map) do
    case read(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp read_datetime(map, key) when is_map(map) do
    case read(map, key) do
      %DateTime{} = datetime -> datetime
      value when is_binary(value) -> parse_datetime(value)
      _other -> nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp read(map, key) do
    Map.get(map, key, Map.get(map, known_atom(key)))
  end

  defp known_atom("acquisition_job_id"), do: :acquisition_job_id
  defp known_atom("action"), do: :action
  defp known_atom("decision_manifest"), do: :decision_manifest
  defp known_atom("id"), do: :id
  defp known_atom("kind"), do: :kind
  defp known_atom("persisted_todo_id"), do: :persisted_todo_id
  defp known_atom("provider_occurred_at"), do: :provider_occurred_at
  defp known_atom("reason_job_ids"), do: :reason_job_ids
  defp known_atom("source_bundle"), do: :source_bundle
  defp known_atom("source_identity_digest"), do: :source_identity_digest
  defp known_atom("source_item_refs"), do: :source_item_refs
  defp known_atom("source_proof_items"), do: :source_proof_items
  defp known_atom("source_ref"), do: :source_ref
  defp known_atom("source_ref_digest"), do: :source_ref_digest
  defp known_atom("source_revision_digest"), do: :source_revision_digest
  defp known_atom("status"), do: :status
  defp known_atom("todo_decision_manifest"), do: :todo_decision_manifest
  defp known_atom("todo_ref"), do: :todo_ref
  defp known_atom("todo_snapshots"), do: :todo_snapshots
  defp known_atom("updated_at"), do: :updated_at
  defp known_atom("value"), do: :value
end
