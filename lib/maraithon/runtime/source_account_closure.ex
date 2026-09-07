defmodule Maraithon.Runtime.SourceAccountClosure do
  @moduledoc """
  Runs one source-account closure worker as a durable provider/model handoff.

  The provider lane reads only the account's closure delta. Empty deltas move
  the closure cursor without model work. A non-empty delta is sealed once and
  handed to a bounded source-partition × todo-batch matrix. The workers stay
  small while every todo sees every source partition exactly once. A finalizer
  moves the cursor only after the complete matrix is proven.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.SlackSourceReplay
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.TodoCompletionSweep
  alias Maraithon.Todos.CrossSourceCompletion
  alias Maraithon.Todos.Todo

  @max_replay_fanouts 500
  @partitioning_version 1
  @oversized_legacy_fanouts 1_000
  @allowed_watermark_kinds ~w(gmail_closure_watermark slack_closure_watermark)

  @doc false
  def legacy_oversized_graph?(%{"fanout_count" => count} = result)
      when is_integer(count) and count >= @oversized_legacy_fanouts do
    is_nil(result["closure_partitioning_version"])
  end

  def legacy_oversized_graph?(_result), do: false

  def acquire(account, opts \\ [])

  def acquire(%ConnectedAccount{status: "connected"} = account, opts) when is_list(opts) do
    with {:ok, _replay} <- validate_replay_opts(account, opts),
         {:ok, bundle, proposals} <- TodoCompletionSweep.acquire_account_delta(account, opts),
         watermarks <- serialize_watermarks(proposals, account.id),
         :ok <- validate_watermarks(watermarks),
         bundle <- maybe_filter_settled_source_items(bundle, account, opts),
         {:ok, source_partitions} <- SourceAccountDiscovery.partition_bundle(bundle),
         source_items <-
           Enum.sum(Enum.map(source_partitions, &SourceAccountDiscovery.source_item_count/1)),
         source_refs <- SourceAccountDiscovery.source_item_refs(bundle),
         true <- length(source_refs) == source_items,
         source_proof_items <- SourceAccountDiscovery.source_proof_items(bundle),
         true <- length(source_proof_items) == source_items,
         todo_snapshots <- TodoCompletionSweep.open_todo_snapshots_for_account(account, opts),
         todo_ids <- Enum.map(todo_snapshots, &Map.fetch!(&1, "id")) do
      cond do
        source_items == 0 ->
          settle_without_fanout(account, watermarks, "empty_delta", [], opts)

        todo_ids == [] ->
          settle_without_fanout(
            account,
            watermarks,
            "no_open_todos",
            source_proof_items,
            opts
          )

        true ->
          build_fanout(
            account,
            source_partitions,
            watermarks,
            source_refs,
            todo_snapshots,
            opts
          )
      end
    else
      false -> {:error, :source_closure_source_identity_mismatch}
      nil -> {:error, :invalid_source_bundle}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_result}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def acquire(%ConnectedAccount{}, _opts), do: {:skip, :account_not_connected}
  def acquire(_account, _opts), do: {:error, :invalid_source_account}

  defp settle_without_fanout(account, watermarks, outcome, source_proof_items, opts) do
    with {:ok, watermark_result} <- settle_watermarks(account, watermarks, opts) do
      {:ok,
       Map.merge(
         %{
           outcome: outcome,
           account_id: account.id,
           source_items: length(source_proof_items),
           source_item_refs: Enum.map(source_proof_items, & &1.source_ref),
           source_proof_items: source_proof_items,
           todo_decision_count: 0,
           model_calls: 0
         },
         watermark_result
       )
       |> put_replay_metadata(opts)}
    end
  end

  defp build_fanout(account, source_partitions, watermarks, source_refs, todo_snapshots, opts) do
    todo_batches = Enum.chunk_every(todo_snapshots, CrossSourceCompletion.max_todos_per_request())
    packed_partitions = pack_source_partitions(source_partitions)

    with {:ok, handoffs, bounded_partitions} <-
           build_bounded_handoffs(todo_batches, packed_partitions, account, opts) do
      fanout_result(
        account,
        handoffs,
        bounded_partitions,
        todo_batches,
        watermarks,
        source_refs,
        todo_snapshots,
        opts
      )
    end
  end

  defp fanout_result(
         account,
         handoffs,
         source_partitions,
         todo_batches,
         watermarks,
         source_refs,
         todo_snapshots,
         opts
       ) do
    todo_ids = Enum.map(todo_snapshots, &Map.fetch!(&1, "id"))
    fanout_count = length(handoffs)

    {:ok,
     %{
       outcome: "fanout_ready",
       closure_partitioning_version: @partitioning_version,
       account_id: account.id,
       source_items: length(source_refs),
       source_partition_count: length(source_partitions),
       todo_count: length(todo_ids),
       todo_batch_count: length(todo_batches),
       fanout_count: fanout_count,
       handoffs: handoffs,
       finalizer:
         %{
           "account_id" => account.id,
           "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
           "expected_fanouts" => fanout_count,
           "expected_source_items" => length(source_refs),
           "expected_source_partitions" => length(source_partitions),
           "expected_source_refs_digest" => SourceAccountDiscovery.refs_digest(source_refs),
           "expected_todo_count" => length(todo_ids),
           "expected_todo_batches" => length(todo_batches),
           "expected_todo_refs_digest" => SourceAccountDiscovery.refs_digest(todo_ids),
           "watermarks" => watermarks
         }
         |> put_replay_metadata(opts)
     }
     |> put_replay_metadata(opts)}
  end

  defp build_bounded_handoffs(todo_batches, source_partitions, account, opts) do
    fanout_count = length(todo_batches) * length(source_partitions)
    source_partition_count = length(source_partitions)
    todo_batch_count = length(todo_batches)

    with :ok <- validate_replay_fanout_count(fanout_count, opts) do
      todo_batches
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {todo_snapshot_batch, todo_batch_index} ->
        Enum.map(Enum.with_index(source_partitions, 1), fn
          {source_bundle, source_partition_index} ->
            {todo_snapshot_batch, todo_batch_index, source_bundle, source_partition_index}
        end)
      end)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn
        {{todo_snapshot_batch, todo_batch_index, source_bundle, source_partition_index},
         fanout_index},
        {:ok, handoffs} ->
          todo_ids = Enum.map(todo_snapshot_batch, &Map.fetch!(&1, "id"))
          source_refs = SourceAccountDiscovery.source_item_refs(source_bundle)

          handoff =
            %{
              "account_id" => account.id,
              "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
              "fanout_index" => fanout_index,
              "fanout_count" => fanout_count,
              "source_partition_index" => source_partition_index,
              "source_partition_count" => source_partition_count,
              "todo_batch_index" => todo_batch_index,
              "todo_batch_count" => todo_batch_count,
              "source_items" => length(source_refs),
              "source_item_refs" => source_refs,
              "source_refs_digest" => SourceAccountDiscovery.refs_digest(source_refs),
              "source_bundle" => source_bundle,
              "todo_ids" => todo_ids,
              "todo_snapshots" => todo_snapshot_batch,
              "todo_count" => length(todo_ids),
              "watermarks" => []
            }
            |> put_replay_metadata(opts)

          case SourceAccountDiscovery.bound_handoff(handoff) do
            {:ok, bounded_handoff} ->
              {:cont, {:ok, [bounded_handoff | handoffs]}}

            {:error, _reason} ->
              {:halt, {:split, source_partition_index - 1, source_bundle}}
          end
      end)
      |> case do
        {:ok, handoffs} ->
          {:ok, Enum.reverse(handoffs), source_partitions}

        {:split, partition_index, partition} ->
          # Full handoffs include todo snapshots and coverage metadata as well
          # as the source bundle. Split only the partition that exceeds those
          # bounds, then rebuild the matrix with its final indices and counts.
          with {:ok, split_partitions} <-
                 SourceAccountDiscovery.split_partition_for_handoff(partition) do
            bounded_partitions =
              source_partitions
              |> List.replace_at(partition_index, split_partitions)
              |> List.flatten()

            build_bounded_handoffs(todo_batches, bounded_partitions, account, opts)
          else
            {:error, _reason} -> {:error, :source_closure_handoff_payload_too_large}
          end
      end
    end
  end

  defp validate_replay_fanout_count(fanout_count, opts) do
    if is_map(Keyword.get(opts, :source_replay)) and fanout_count > @max_replay_fanouts,
      do: {:error, :gmail_source_replay_fanout_limit},
      else: :ok
  end

  defp pack_source_partitions([]), do: []

  defp pack_source_partitions([first | rest]) do
    {packed, _current, current_bundle} =
      Enum.reduce(rest, {[], [first], first}, fn partition, {packed, current, current_bundle} ->
        candidate = current ++ [partition]

        case SourceAccountDiscovery.merge_partitions(candidate) do
          %{} = merged ->
            {packed, candidate, merged}

          nil ->
            {[current_bundle | packed], [partition], partition}
        end
      end)

    Enum.reverse([current_bundle | packed])
  end

  def reason(account, payload, opts \\ [])

  def reason(%ConnectedAccount{} = account, payload, opts)
      when is_map(payload) and is_list(opts) do
    with true <- read_integer(payload, "account_id") == account.id,
         {:ok, bundle} <- fetch_map(payload, "source_bundle"),
         {:ok, bundle} <- SourceAccountDiscovery.restore_partition_bundle(bundle),
         fanout_index when is_integer(fanout_index) and fanout_index > 0 <-
           read_integer(payload, "fanout_index"),
         fanout_count when is_integer(fanout_count) and fanout_count >= fanout_index <-
           read_integer(payload, "fanout_count"),
         source_partition_index
         when is_integer(source_partition_index) and
                source_partition_index > 0 <-
           read_integer(payload, "source_partition_index"),
         source_partition_count
         when is_integer(source_partition_count) and
                source_partition_count >= source_partition_index <-
           read_integer(payload, "source_partition_count"),
         todo_batch_index when is_integer(todo_batch_index) and todo_batch_index > 0 <-
           read_integer(payload, "todo_batch_index"),
         todo_batch_count
         when is_integer(todo_batch_count) and
                todo_batch_count >= todo_batch_index <-
           read_integer(payload, "todo_batch_count"),
         expected_source_items
         when is_integer(expected_source_items) and expected_source_items > 0 <-
           read_integer(payload, "source_items"),
         {:ok, source_item_refs} <- fetch_list(payload, "source_item_refs"),
         expected_source_refs_digest when is_binary(expected_source_refs_digest) <-
           read_string(payload, "source_refs_digest"),
         {:ok, todo_ids} <- fetch_list(payload, "todo_ids"),
         {:ok, todo_snapshots} <- fetch_list(payload, "todo_snapshots"),
         expected_todo_count when is_integer(expected_todo_count) and expected_todo_count > 0 <-
           read_integer(payload, "todo_count"),
         true <- length(todo_ids) == expected_todo_count,
         true <- length(Enum.uniq(todo_ids)) == expected_todo_count,
         true <- Enum.map(todo_snapshots, &read_string(&1, "id")) == todo_ids,
         ^expected_source_items <- SourceAccountDiscovery.source_item_count(bundle),
         ^source_item_refs <- SourceAccountDiscovery.source_item_refs(bundle),
         true <-
           SourceAccountDiscovery.refs_digest(source_item_refs) == expected_source_refs_digest,
         result when is_map(result) <-
           TodoCompletionSweep.run_for_account(
             account,
             opts
             |> Keyword.put(:exact_source_delta, true)
             |> Keyword.put(:skip_deterministic_completion, true)
             |> Keyword.put(:source_bundle, bundle)
             |> Keyword.put(:source_item_refs, source_item_refs)
             |> Keyword.put(:todo_ids, todo_ids)
           ),
         true <- settled_result?(result),
         {:ok, todo_manifest} <-
           TodoCompletionSweep.resolve_todo_decision_manifest(
             account,
             todo_ids,
             Map.get(result, :todo_decision_refs, [])
           ) do
      {:ok,
       %{
         outcome: "evaluated",
         account_id: account.id,
         source_items: expected_source_items,
         source_item_refs: source_item_refs,
         source_refs_digest: expected_source_refs_digest,
         decision_count: expected_todo_count,
         decision_refs: todo_manifest.decision_refs,
         todo_ids: todo_ids,
         todo_decision_count: expected_todo_count,
         todo_decision_refs: todo_manifest.decision_refs,
         evaluated_todo_decision_count: length(todo_manifest.evaluated_refs),
         evaluated_todo_decision_refs: todo_manifest.evaluated_refs,
         superseded_todo_decision_count: length(todo_manifest.superseded_refs),
         superseded_todo_decision_refs: todo_manifest.superseded_refs,
         todo_decision_manifest:
           Enum.map(todo_manifest.evaluated_refs, &%{todo_ref: &1, action: "evaluated"}) ++
             Enum.map(todo_manifest.superseded_refs, &%{todo_ref: &1, action: "superseded"}),
         model_calls: Map.get(result, :model_calls, 0),
         fanout_index: fanout_index,
         fanout_count: fanout_count,
         source_partition_index: source_partition_index,
         source_partition_count: source_partition_count,
         todo_batch_index: todo_batch_index,
         todo_batch_count: todo_batch_count,
         result: result
       }
       |> put_replay_metadata(payload)}
    else
      false -> {:error, :source_closure_unsettled_or_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_payload}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def reason(_account, _payload, _opts), do: {:error, :invalid_source_closure_payload}

  @doc "Advances a closure cursor only after all source partitions prove complete."
  def finalize(account, payload, child_results, opts \\ [])

  def finalize(%ConnectedAccount{} = account, payload, child_results, opts)
      when is_map(payload) and is_list(child_results) and is_list(opts) do
    with true <- read_integer(payload, "account_id") == account.id,
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         expected_fanouts when is_integer(expected_fanouts) and expected_fanouts > 0 <-
           read_integer(payload, "expected_fanouts"),
         expected_source_items
         when is_integer(expected_source_items) and expected_source_items > 0 <-
           read_integer(payload, "expected_source_items"),
         expected_source_partitions
         when is_integer(expected_source_partitions) and expected_source_partitions > 0 <-
           read_integer(payload, "expected_source_partitions"),
         expected_source_refs_digest when is_binary(expected_source_refs_digest) <-
           read_string(payload, "expected_source_refs_digest"),
         expected_todo_count when is_integer(expected_todo_count) and expected_todo_count > 0 <-
           read_integer(payload, "expected_todo_count"),
         expected_todo_batches
         when is_integer(expected_todo_batches) and expected_todo_batches > 0 <-
           read_integer(payload, "expected_todo_batches"),
         expected_todo_refs_digest when is_binary(expected_todo_refs_digest) <-
           read_string(payload, "expected_todo_refs_digest"),
         :ok <-
           validate_child_results(
             account,
             child_results,
             expected_fanouts,
             expected_source_items,
             expected_source_partitions,
             expected_source_refs_digest,
             expected_todo_count,
             expected_todo_batches,
             expected_todo_refs_digest
           ),
         {:ok, watermark_result} <- settle_watermarks(account, watermarks, opts) do
      {:ok,
       Map.merge(
         %{
           outcome: "finalized",
           account_id: account.id,
           fanout_count: expected_fanouts,
           source_items: expected_source_items,
           todo_count: expected_todo_count,
           decision_count: expected_todo_count,
           todo_decision_count: expected_todo_count,
           model_calls: Enum.sum(Enum.map(child_results, &result_integer(&1, "model_calls")))
         },
         watermark_result
       )
       |> put_replay_metadata(payload)}
    else
      false -> {:error, :source_closure_finalizer_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_finalizer}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def finalize(_account, _payload, _child_results, _opts),
    do: {:error, :invalid_source_closure_finalizer}

  defp settled_result?(%{
         errors: 0,
         fetch_errors: 0,
         coverage_complete?: true,
         cross_source: cross_source
       })
       when is_map(cross_source),
       do: true

  defp settled_result?(_result), do: false

  defp validate_child_results(
         account,
         child_results,
         expected_fanouts,
         expected_source_items,
         expected_source_partitions,
         expected_source_refs_digest,
         expected_todo_count,
         expected_todo_batches,
         expected_todo_refs_digest
       ) do
    indexes = child_results |> Enum.map(&result_integer(&1, "fanout_index")) |> Enum.sort()

    coordinates =
      Enum.map(child_results, fn result ->
        {result_integer(result, "todo_batch_index"),
         result_integer(result, "source_partition_index")}
      end)

    expected_coordinates =
      for todo_batch <- 1..expected_todo_batches,
          source_partition <- 1..expected_source_partitions,
          do: {todo_batch, source_partition}

    children_valid? =
      Enum.all?(child_results, fn result ->
        decision_refs = result_string_list(result, "decision_refs")

        result_integer(result, "fanout_count") == expected_fanouts and
          result_integer(result, "source_partition_count") == expected_source_partitions and
          result_integer(result, "todo_batch_count") == expected_todo_batches and
          result_integer(result, "decision_count") == length(decision_refs) and
          result_integer(result, "todo_decision_count") == length(decision_refs) and
          valid_closure_decision_manifest?(
            account,
            result_list(result, "todo_decision_manifest"),
            decision_refs,
            result_string_list(result, "evaluated_todo_decision_refs"),
            result_string_list(result, "superseded_todo_decision_refs")
          )
      end)

    source_coverage? =
      Enum.all?(1..expected_todo_batches, fn todo_batch_index ->
        batch_results =
          Enum.filter(
            child_results,
            &(result_integer(&1, "todo_batch_index") == todo_batch_index)
          )

        refs = Enum.flat_map(batch_results, &result_string_list(&1, "source_item_refs"))

        length(refs) == expected_source_items and length(Enum.uniq(refs)) == expected_source_items and
          SourceAccountDiscovery.refs_digest(refs) == expected_source_refs_digest
      end)

    todo_coverage? =
      Enum.all?(1..expected_source_partitions, fn source_partition_index ->
        partition_results =
          Enum.filter(
            child_results,
            &(result_integer(&1, "source_partition_index") == source_partition_index)
          )

        refs = Enum.flat_map(partition_results, &result_string_list(&1, "decision_refs"))

        length(refs) == expected_todo_count and length(Enum.uniq(refs)) == expected_todo_count and
          SourceAccountDiscovery.refs_digest(refs) == expected_todo_refs_digest
      end)

    if expected_fanouts == expected_source_partitions * expected_todo_batches and
         length(child_results) == expected_fanouts and
         indexes == Enum.to_list(1..expected_fanouts) and
         Enum.sort(coordinates) == Enum.sort(expected_coordinates) and children_valid? and
         source_coverage? and todo_coverage? do
      :ok
    else
      {:error, :source_closure_incomplete_decisions}
    end
  end

  defp result_integer(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp result_integer(_result, _key), do: 0

  defp result_string_list(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), [])) do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _other -> []
    end
  end

  defp result_string_list(_result, _key), do: []

  defp result_string(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp result_string(_result, _key), do: nil

  defp result_list(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), [])) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp result_list(_result, _key), do: []

  defp valid_closure_decision_manifest?(
         account,
         manifests,
         decision_refs,
         evaluated_refs,
         superseded_refs
       ) do
    manifest_entries =
      Enum.map(manifests, fn manifest ->
        {result_string(manifest, "todo_ref"), result_string(manifest, "action")}
      end)

    manifest_refs = Enum.map(manifest_entries, &elem(&1, 0))

    manifest_evaluated_refs =
      for {todo_ref, "evaluated"} <- manifest_entries, do: todo_ref

    manifest_superseded_refs =
      for {todo_ref, "superseded"} <- manifest_entries, do: todo_ref

    length(manifests) == length(decision_refs) and
      Enum.all?(manifest_entries, fn
        {todo_ref, action}
        when is_binary(todo_ref) and action in ["evaluated", "superseded"] ->
          true

        _invalid ->
          false
      end) and
      Enum.sort(manifest_refs) == Enum.sort(decision_refs) and
      Enum.sort(manifest_evaluated_refs) == Enum.sort(evaluated_refs) and
      Enum.sort(manifest_superseded_refs) == Enum.sort(superseded_refs) and
      length(Enum.uniq(evaluated_refs ++ superseded_refs)) == length(decision_refs) and
      persisted_todos_exist?(account, decision_refs)
  end

  defp persisted_todos_exist?(account, todo_ids) do
    persisted_count =
      Todo
      |> where(
        [todo],
        todo.user_id == ^account.user_id and todo.id in ^todo_ids
      )
      |> select([todo], count(todo.id))
      |> Repo.one()

    persisted_count == length(todo_ids)
  end

  defp serialize_watermarks(proposals, account_id) when is_list(proposals) do
    proposals
    |> Enum.flat_map(fn
      %{
        account: %ConnectedAccount{id: ^account_id},
        kind: kind,
        value: value
      } = proposal
      when is_binary(kind) and is_binary(value) ->
        if allowed_watermark_kind?(kind) do
          watermark = %{"account_id" => account_id, "kind" => kind, "value" => value}

          if Map.has_key?(proposal, :expected_lower_value) do
            [Map.put(watermark, "expected_lower_value", proposal.expected_lower_value)]
          else
            [watermark]
          end
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.uniq_by(&{&1["kind"], &1["value"]})
  end

  defp serialize_watermarks(_proposals, _account_id), do: []

  defp validate_watermarks([
         %{"account_id" => account_id, "kind" => kind, "value" => value}
       ])
       when is_integer(account_id) and is_binary(kind) and is_binary(value) and value != "" do
    if allowed_watermark_kind?(kind),
      do: :ok,
      else: {:error, :source_closure_watermark_invalid}
  end

  defp validate_watermarks(_watermarks), do: {:error, :source_closure_watermark_invalid}

  defp advance_watermarks(account, watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      with true <- read_integer(watermark, "account_id") == account.id,
           kind when is_binary(kind) <- read_string(watermark, "kind"),
           true <- allowed_watermark_kind?(kind),
           value when is_binary(value) <- read_string(watermark, "value"),
           {:ok, _cursor} <- SourceCursors.put(account, kind, %{"value" => value}) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :source_closure_watermark_account_mismatch}}
        nil -> {:halt, {:error, :invalid_source_closure_watermark}}
        {:error, reason} -> {:halt, {:error, {:source_closure_cursor_advance_failed, reason}}}
        _other -> {:halt, {:error, :invalid_source_closure_watermark}}
      end
    end)
  end

  defp allowed_watermark_kind?(kind) do
    kind in @allowed_watermark_kinds or GmailSourceReplay.watermark_kind?(kind, "closure") or
      SlackSourceReplay.watermark_kind?(kind, "closure")
  end

  defp maybe_filter_settled_source_items(bundle, account, opts) when is_list(opts) do
    if is_map(Keyword.get(opts, :source_replay)) do
      bundle
    else
      SourceAccountDiscovery.filter_settled_source_items(bundle, account, "closure")
    end
  end

  defp validate_replay_opts(account, opts) do
    source_replay_module(account).validate_runtime_replay(
      account,
      Keyword.get(opts, :source_replay),
      "closure"
    )
  end

  defp source_replay_module(%ConnectedAccount{provider: "slack:" <> _team_id}),
    do: SlackSourceReplay

  defp source_replay_module(_account), do: GmailSourceReplay

  defp put_replay_metadata(value, source) when is_map(value) do
    replay =
      cond do
        is_list(source) -> Keyword.get(source, :source_replay)
        is_map(source) and Map.get(source, "source_replay_mode") == "historical" -> source
        true -> nil
      end

    case replay do
      %{reference: reference, lower: lower, upper: upper} = replay
      when is_binary(reference) and is_integer(lower) and is_integer(upper) ->
        value
        |> Map.put(:source_replay_mode, "historical")
        |> Map.put(:source_replay_reference, reference)
        |> Map.put(:source_replay_lower, lower)
        |> Map.put(:source_replay_upper, upper)
        |> maybe_put_replay_kind(replay)
        |> maybe_put_replay_provider(replay)

      %{
        "source_replay_reference" => reference,
        "source_replay_lower" => lower,
        "source_replay_upper" => upper
      } = replay
      when is_binary(reference) and is_integer(lower) and is_integer(upper) ->
        value
        |> Map.put(:source_replay_mode, "historical")
        |> Map.put(:source_replay_reference, reference)
        |> Map.put(:source_replay_lower, lower)
        |> Map.put(:source_replay_upper, upper)
        |> maybe_put_replay_kind(replay)
        |> maybe_put_replay_provider(replay)

      _other ->
        value
    end
  end

  defp maybe_put_replay_kind(value, %{kind: kind}) when is_binary(kind),
    do: Map.put(value, :source_replay_kind, kind)

  defp maybe_put_replay_kind(value, %{"source_replay_kind" => kind}) when is_binary(kind),
    do: Map.put(value, :source_replay_kind, kind)

  defp maybe_put_replay_kind(value, _replay), do: value

  defp maybe_put_replay_provider(value, %{kind: kind}) when is_binary(kind) do
    if SlackSourceReplay.watermark_kind?(kind, "discovery") or
         SlackSourceReplay.watermark_kind?(kind, "closure") do
      Map.put(value, :source_replay_provider, "slack")
    else
      Map.put(value, :source_replay_provider, "gmail")
    end
  end

  defp maybe_put_replay_provider(value, %{"source_replay_provider" => provider})
       when provider in ["gmail", "slack"],
       do: Map.put(value, :source_replay_provider, provider)

  defp maybe_put_replay_provider(value, _replay), do: value

  defp settle_watermarks(account, watermarks, opts)
       when is_list(watermarks) and is_list(opts) do
    if Keyword.get(opts, :defer_watermark_commit, false) do
      {:ok, %{advanced_watermarks: 0, deferred_watermarks: watermarks}}
    else
      with :ok <- advance_watermarks(account, watermarks) do
        {:ok, %{advanced_watermarks: length(watermarks)}}
      end
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, {:missing_map_payload, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _other -> {:error, {:missing_list_payload, key}}
    end
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp read_integer(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp existing_atom("fanout_index"), do: :fanout_index
  defp existing_atom("fanout_count"), do: :fanout_count
  defp existing_atom("source_partition_index"), do: :source_partition_index
  defp existing_atom("source_partition_count"), do: :source_partition_count
  defp existing_atom("todo_batch_index"), do: :todo_batch_index
  defp existing_atom("todo_batch_count"), do: :todo_batch_count
  defp existing_atom("source_items"), do: :source_items
  defp existing_atom("source_item_refs"), do: :source_item_refs
  defp existing_atom("decision_count"), do: :decision_count
  defp existing_atom("decision_refs"), do: :decision_refs
  defp existing_atom("source_refs_digest"), do: :source_refs_digest
  defp existing_atom("todo_decision_count"), do: :todo_decision_count
  defp existing_atom("todo_decision_manifest"), do: :todo_decision_manifest
  defp existing_atom("evaluated_todo_decision_refs"), do: :evaluated_todo_decision_refs
  defp existing_atom("superseded_todo_decision_refs"), do: :superseded_todo_decision_refs
  defp existing_atom("todo_ref"), do: :todo_ref
  defp existing_atom("action"), do: :action
  defp existing_atom("model_calls"), do: :model_calls
  defp existing_atom(_key), do: :__missing__
end
