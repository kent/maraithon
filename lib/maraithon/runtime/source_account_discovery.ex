defmodule Maraithon.Runtime.SourceAccountDiscovery do
  @moduledoc """
  Runs one source-account discovery worker as a durable provider/model handoff.

  Provider work fetches only the delta after that account's discovery cursor.
  Empty deltas advance without a model call. Non-empty deltas are partitioned
  into small encrypted reasoning handoffs, and advance only after every
  handoff has made a decision for every source item. An enabled Chief
  contributes its Follow-through configuration; accounts without one use the
  same safe defaults without requiring a long-lived Agent row.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents.Agent
  alias Maraithon.BoundedJSON
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle, SourceScope}
  alias Maraithon.ChiefOfStaff.Skills.Followthrough
  alias Maraithon.Connectors.Gmail.BodyText
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.DurablePayload
  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.SlackSourceReplay
  alias Maraithon.Runtime.SourceCycleProofs
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @handoff_item_limit 5
  @handoff_binary_chunk_bytes 96_000
  @handoff_max_encoded_source_bundle_bytes 2_000_000
  @handoff_max_restored_binary_bytes 5_000_000
  @handoff_max_restored_bytes 10_000_000
  @candidate_source_record_max_bytes 104_000
  # A source record is serialized once into the prompt and once again into the
  # provider request. Keeping the model-facing projection well below the
  # request ceiling leaves room for JSON escaping, the decision contract, and
  # the required candidate envelope.
  @candidate_source_record_prompt_max_bytes 64_000
  @candidate_prompt_excerpt_max_bytes 32_000
  @candidate_prompt_context_max_items 3
  @candidate_prompt_context_string_max_bytes 600
  # Leave room beneath Todos.Intelligence's 120 KB escaped-request ceiling for
  # its fixed instructions and the candidate fields surrounding source evidence.
  @candidate_partition_max_bytes 96_000
  @candidate_prompt_overhead_bytes 8_000
  @candidate_summary_max_bytes 1_000
  @candidate_current_text_max_bytes 800
  @candidate_context_text_max_bytes 200
  @bounded_binary_marker "__maraithon_bounded_binary_v1__"
  @bounded_source_bundle_marker "__maraithon_bounded_source_bundle_v1__"
  @allowed_watermark_kinds ~w(gmail_discovery_watermark slack_discovery_watermark)

  @doc "Fetches one exact account delta and returns either a settled result or a sealed handoff."
  def acquire(account, agent, opts \\ [])

  def acquire(
        %ConnectedAccount{status: "connected"} = account,
        %Agent{} = agent,
        opts
      )
      when is_list(opts) do
    do_acquire(account, agent, opts)
  end

  def acquire(%ConnectedAccount{status: "connected"} = account, nil, opts)
      when is_list(opts) do
    do_acquire(account, nil, opts)
  end

  def acquire(%ConnectedAccount{}, agent, _opts) when is_nil(agent) or is_struct(agent, Agent),
    do: {:skip, :account_not_connected}

  def acquire(_account, _agent, _opts), do: {:error, :invalid_source_discovery_identity}

  defp do_acquire(account, agent, opts) do
    with :ok <- validate_ownership(account, agent),
         {:ok, _replay} <- validate_replay_opts(account, opts, "discovery"),
         {bundle, telemetry, proposals} <- acquire_bundle(account, agent, opts),
         :ok <- validate_complete_acquisition(account, telemetry),
         bundle <- maybe_filter_settled_source_items(bundle, account, "discovery", opts),
         watermarks <- serialize_watermarks(proposals, account.id),
         :ok <- validate_watermarks(watermarks),
         {:ok, partitions} <- partition_bundle(bundle),
         source_items <- Enum.sum(Enum.map(partitions, &source_item_count/1)),
         {:ok, handoffs} <-
           build_handoffs(partitions, account, agent, opts) do
      if source_items == 0 do
        with {:ok, watermark_result} <- settle_watermarks(account, watermarks, opts) do
          {:ok,
           Map.merge(
             %{
               outcome: "empty_delta",
               account_id: account.id,
               source_items: 0,
               source_item_refs: [],
               model_calls: 0
             },
             watermark_result
           )
           |> put_replay_metadata(opts)}
        end
      else
        fanout_count = length(handoffs)

        {:ok,
         %{
           outcome: "fanout_ready",
           account_id: account.id,
           source_items: source_items,
           fanout_count: fanout_count,
           handoffs: handoffs,
           finalizer:
             %{
               "account_id" => account.id,
               "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
               "expected_fanouts" => fanout_count,
               "expected_source_items" => source_items,
               "expected_source_refs_digest" =>
                 partitions |> Enum.flat_map(&source_item_refs/1) |> refs_digest(),
               "watermarks" => watermarks
             }
             |> maybe_put_agent_id(agent)
             |> put_replay_metadata(opts)
         }
         |> put_replay_metadata(opts)}
      end
    else
      nil -> {:error, :invalid_source_bundle}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_result}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  @doc "Reasons over one small sealed account-delta partition."
  def reason(account, agent, payload, opts \\ [])

  def reason(%ConnectedAccount{} = account, %Agent{} = agent, payload, opts)
      when is_map(payload) and is_list(opts) do
    do_reason(account, agent, payload, opts)
  end

  def reason(%ConnectedAccount{} = account, nil, payload, opts)
      when is_map(payload) and is_list(opts) do
    do_reason(account, nil, payload, opts)
  end

  def reason(_account, _agent, _payload, _opts), do: {:error, :invalid_source_discovery_payload}

  defp do_reason(account, agent, payload, opts) do
    with :ok <- validate_ownership(account, agent),
         {:ok, bundle} <- fetch_map(payload, "source_bundle"),
         {:ok, bundle} <- restore_partition_bundle(bundle),
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         {:ok, source_item_refs} <- fetch_list(payload, "source_item_refs", []),
         :ok <- validate_payload_identity(account, agent, payload),
         source_items when source_items > 0 <- source_item_count(bundle),
         ^source_items <- length(source_item_refs),
         ^source_item_refs <- source_item_refs(bundle),
         {:ok, outcome} <- run_todo_decisions(account, bundle, opts),
         ^source_items <- Map.get(outcome, :decision_count),
         ^source_item_refs <- Map.get(outcome, :decision_refs),
         :ok <- advance_watermarks(account, watermarks) do
      {:ok,
       outcome
       |> Map.put(:account_id, account.id)
       |> Map.put(:source_items, source_items)
       |> Map.put(:fanout_index, read_integer(payload, "fanout_index"))
       |> Map.put(:fanout_count, read_integer(payload, "fanout_count"))
       |> Map.put(:advanced_watermarks, length(watermarks))
       |> put_replay_metadata(payload)}
    else
      false -> {:error, :source_discovery_partition_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_payload}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  @doc "Advances a discovery cursor only after all child partitions prove exact decisions."
  def finalize(account, agent, payload, child_results, opts \\ [])

  def finalize(%ConnectedAccount{} = account, agent, payload, child_results, opts)
      when (is_nil(agent) or is_struct(agent, Agent)) and is_map(payload) and
             is_list(child_results) and is_list(opts) do
    with :ok <- validate_ownership(account, agent),
         :ok <- validate_payload_identity(account, agent, payload),
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         expected_fanouts when is_integer(expected_fanouts) and expected_fanouts > 0 <-
           read_integer(payload, "expected_fanouts"),
         expected_source_items
         when is_integer(expected_source_items) and expected_source_items > 0 <-
           read_integer(payload, "expected_source_items"),
         expected_source_refs_digest when is_binary(expected_source_refs_digest) <-
           read_string(payload, "expected_source_refs_digest"),
         :ok <-
           validate_child_results(
             account,
             child_results,
             expected_fanouts,
             expected_source_items,
             expected_source_refs_digest
           ),
         {:ok, watermark_result} <- settle_watermarks(account, watermarks, opts) do
      {:ok,
       Map.merge(
         %{
           outcome: "finalized",
           account_id: account.id,
           fanout_count: expected_fanouts,
           source_items: expected_source_items,
           decision_count: expected_source_items,
           model_calls: Enum.sum(Enum.map(child_results, &result_integer(&1, "model_calls")))
         },
         watermark_result
       )
       |> put_replay_metadata(payload)}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_finalizer}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def finalize(_account, _agent, _payload, _child_results, _opts),
    do: {:error, :invalid_source_discovery_finalizer}

  @doc false
  def partition_bundle(bundle) when is_map(bundle) do
    if source_identities_complete?(bundle) do
      bundle
      |> source_records()
      |> grouped_source_records()
      |> split_source_groups(@handoff_item_limit)
      |> pack_source_groups(@handoff_item_limit)
      |> compact_partitions(bundle)
    else
      {:error, :source_discovery_item_identity_missing}
    end
  end

  def partition_bundle(_bundle), do: {:error, :invalid_source_bundle}

  @doc false
  def restore_partition_bundle(%{@bounded_source_bundle_marker => _encoded} = bundle)
      when map_size(bundle) == 1 do
    with :ok <- validate_restore_budget(bundle) do
      restore_bounded_value(bundle)
    end
  end

  def restore_partition_bundle(bundle) when is_map(bundle) do
    with :ok <- validate_restore_budget(bundle),
         :ok <- reject_nested_source_bundle_markers(bundle) do
      restore_bounded_value(bundle)
    end
  end

  def restore_partition_bundle(_bundle), do: {:error, :invalid_source_bundle}

  defp build_handoffs([], _account, _agent, _opts), do: {:ok, []}

  defp build_handoffs(partitions, account, agent, opts)
       when is_list(partitions) and is_list(opts) do
    do_build_handoffs(partitions, account, agent, opts)
  end

  defp do_build_handoffs(partitions, account, agent, opts) do
    fanout_count = length(partitions)

    partitions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {partition, fanout_index}, {:ok, handoffs} ->
      handoff =
        %{
          "account_id" => account.id,
          "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
          "fanout_index" => fanout_index,
          "fanout_count" => fanout_count,
          "source_bundle" => partition,
          "source_item_refs" => source_item_refs(partition),
          "watermarks" => []
        }
        |> maybe_put_agent_id(agent)
        |> put_replay_metadata(opts)

      case bound_handoff(handoff) do
        {:ok, bounded_handoff} ->
          {:cont, {:ok, [bounded_handoff | handoffs]}}

        {:error, reason} ->
          {:halt, {:split, fanout_index - 1, partition, reason}}
      end
    end)
    |> case do
      {:ok, handoffs} ->
        {:ok, Enum.reverse(handoffs)}

      {:split, partition_index, partition, reason} ->
        with {:ok, split_partitions} <- split_partition_for_handoff(partition) do
          partitions
          |> List.replace_at(partition_index, split_partitions)
          |> List.flatten()
          |> do_build_handoffs(account, agent, opts)
        else
          {:error, _split_reason} -> {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp split_partition_for_handoff(partition) do
    records = source_records(partition)

    if length(records) > 1 do
      split_at = div(length(records), 2)
      {left, right} = Enum.split(records, split_at)

      with {:ok, left_partitions} <- compact_partition_records(partition, left),
           {:ok, right_partitions} <- compact_partition_records(partition, right) do
        {:ok, left_partitions ++ right_partitions}
      end
    else
      {:error, :source_discovery_handoff_payload_too_large}
    end
  end

  @doc false
  def bound_handoff(handoff) when is_map(handoff) do
    bounded_handoff = bound_large_binaries(handoff)

    with {:ok, bundle} <- fetch_map(bounded_handoff, "source_bundle") do
      if validate_restore_budget(bundle) == :ok and durable_handoff?(bounded_handoff) do
        {:ok, bounded_handoff}
      else
        seal_handoff(bounded_handoff, bundle)
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :source_discovery_handoff_payload_too_large}
    end
  end

  def bound_handoff(_handoff), do: {:error, :source_discovery_handoff_payload_too_large}

  defp seal_handoff(handoff, bundle) do
    with :ok <- validate_restore_budget(bundle, @handoff_max_encoded_source_bundle_bytes),
         {:ok, sealed_bundle} <- seal_source_bundle(bundle),
         sealed_handoff <- Map.put(handoff, "source_bundle", sealed_bundle),
         :ok <- validate_restore_budget(sealed_bundle),
         true <- durable_handoff?(sealed_handoff) do
      {:ok, sealed_handoff}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :source_discovery_handoff_payload_too_large}
    end
  end

  defp durable_handoff?(handoff) do
    match?(
      {:ok, _canonical},
      DurablePayload.prepare_map(
        handoff,
        BackgroundJob.max_payload_bytes(),
        BackgroundJob.payload_bounds()
      )
    )
  end

  defp seal_source_bundle(bundle) when is_map(bundle) do
    with {:ok, encoded} <- Jason.encode(bundle),
         true <- byte_size(encoded) <= @handoff_max_encoded_source_bundle_bytes do
      compressed = :zlib.gzip(encoded)
      base64 = Base.encode64(compressed)

      {:ok,
       %{
         @bounded_source_bundle_marker => %{
           "byte_size" => byte_size(encoded),
           "chunks" => chunk_binary(base64),
           "codec" => "json-gzip-base64",
           "sha256" => Base.url_encode64(:crypto.hash(:sha256, encoded), padding: false)
         }
       }}
    else
      _invalid -> {:error, :source_discovery_partition_too_large}
    end
  rescue
    _error -> {:error, :source_discovery_partition_too_large}
  end

  defp compact_partitions(record_partitions, bundle) do
    Enum.reduce_while(record_partitions, {:ok, []}, fn records, {:ok, partitions} ->
      case compact_partition_records(bundle, records) do
        {:ok, compacted} -> {:cont, {:ok, Enum.reverse(compacted, partitions)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, partitions} -> {:ok, Enum.reverse(partitions)}
      {:error, _reason} = error -> error
    end
  end

  defp compact_partition_records(bundle, records) when is_list(records) and records != [] do
    case compact_partition(bundle, records) do
      partition when is_map(partition) ->
        {:ok, [partition]}

      nil when length(records) > 1 ->
        split_at = div(length(records), 2)
        {left, right} = Enum.split(records, split_at)

        with {:ok, left_partitions} <- compact_partition_records(bundle, left),
             {:ok, right_partitions} <- compact_partition_records(bundle, right) do
          {:ok, left_partitions ++ right_partitions}
        end

      nil ->
        {:error, :source_discovery_partition_too_large}
    end
  end

  defp compact_partition_records(_bundle, _records),
    do: {:error, :source_discovery_partition_too_large}

  @doc false
  def compact_bundle(bundle) when is_map(bundle) do
    compact = build_compact_bundle(bundle)
    if encoded_bytes(compact) <= @handoff_max_encoded_source_bundle_bytes, do: compact
  end

  def compact_bundle(_bundle), do: nil

  @doc false
  def merge_partitions([first | _rest] = partitions) when is_map(first) do
    records = Enum.flat_map(partitions, &source_records/1)

    if records != [] and
         length(records) == length(Enum.uniq_by(records, &{&1.source, &1.identity})) do
      compact_partition(first, records)
    end
  end

  def merge_partitions(_partitions), do: nil

  @doc false
  def source_item_count(bundle) when is_map(bundle) do
    bundle |> source_records() |> length()
  end

  def source_item_count(_bundle), do: 0

  @doc false
  def source_item_refs(bundle) when is_map(bundle) do
    Enum.map(source_records(bundle), fn record ->
      Atom.to_string(record.source) <> ":" <> record.identity
    end)
  end

  def source_item_refs(_bundle), do: []

  @doc false
  def source_proof_items(bundle) when is_map(bundle) do
    Enum.map(source_records(bundle), fn record ->
      source_ref = Atom.to_string(record.source) <> ":" <> record.identity

      %{
        source_ref: source_ref,
        source_ref_digest: SourceCycleProofs.reference_digest(source_ref),
        source_identity_digest: :crypto.hash(:sha256, record.identity),
        source_revision_digest:
          :crypto.hash(:sha256, :erlang.term_to_binary(record.item, [:deterministic])),
        provider_occurred_at: provider_occurred_at(record)
      }
    end)
  end

  def source_proof_items(_bundle), do: []

  @doc false
  def filter_settled_source_items(bundle, %ConnectedAccount{} = account, role)
      when is_map(bundle) and role in ["discovery", "closure"] do
    records = source_records(bundle)
    proof_items = source_proof_items(bundle)
    settled = SourceCycleProofs.settled_revision_pairs(account.id, role, proof_items)

    remaining =
      records
      |> Enum.zip(proof_items)
      |> Enum.reject(fn {_record, proof_item} ->
        MapSet.member?(settled, {
          proof_item.source_ref_digest,
          proof_item.source_revision_digest
        })
      end)
      |> Enum.map(&elem(&1, 0))

    partition_source_bundle(bundle, remaining)
  end

  def filter_settled_source_items(bundle, _account, _role), do: bundle

  @doc false
  def refs_digest(refs) when is_list(refs) do
    refs
    |> Enum.sort()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp acquire_bundle(account, agent, opts) do
    acquisition = Keyword.get(opts, :acquisition, &Acquisition.build/4)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    source_scope = account_source_scope(account)

    context =
      %{
        user_id: account.user_id,
        agent_id: agent_id(agent),
        timestamp: now,
        trigger: %{type: :pubsub_event, job_type: "source_account_discovery"},
        event: %{topic: account_event_topic(account), payload: %{}},
        recent_events: [],
        source_scope: source_scope,
        source_watermark_role: "discovery",
        defer_watermark_advance: true,
        exhaustive_account_delta: true,
        account_delta_source: account_delta_source(account)
      }
      |> put_replay_context(opts, "discovery")

    acquisition.(
      account.user_id,
      ["followthrough"],
      %{"followthrough" => discovery_config(agent, account.user_id, source_scope)},
      context
    )
  end

  defp run_todo_decisions(account, bundle, opts) do
    now = Keyword.get(opts, :now, parse_datetime(bundle["fetched_at"]) || DateTime.utc_now())
    candidates = todo_candidates(account, bundle)
    source_refs = Enum.map(candidates, & &1["source_ref"])

    intelligence_opts =
      [
        exact_decisions: true,
        existing_limit: 80,
        now: now,
        semantic_dedupe: false,
        source: "source_account_discovery"
      ]
      |> maybe_put_llm_complete(opts)

    with true <- candidates != [] and length(candidates) == length(source_item_refs(bundle)),
         true <- Enum.all?(candidates, &candidate_evidence_complete?/1),
         {:ok, result} <- Todos.ingest_many(account.user_id, candidates, intelligence_opts),
         decisions when is_list(decisions) <- Map.get(result, :decisions),
         indexes <- decisions |> Enum.map(&Map.get(&1, :candidate_index)) |> Enum.sort(),
         true <- indexes == Enum.to_list(0..(length(candidates) - 1)),
         decision_refs <- Enum.map(decisions, &Enum.at(source_refs, &1.candidate_index)),
         true <- Enum.sort(decision_refs) == Enum.sort(source_refs),
         decision_manifest <-
           Enum.map(decisions, fn decision ->
             %{
               source_ref: Enum.at(source_refs, decision.candidate_index),
               action: decision.action,
               persisted_todo_id: Map.get(decision, :persisted_todo_id)
             }
           end) do
      {:ok,
       %{
         outcome: "evaluated",
         model_calls: Map.get(result, :model_calls, 1),
         todo_count: length(Map.get(result, :todos, [])),
         skipped_count: Map.get(result, :skipped_count, 0),
         decision_count: length(decisions),
         decision_refs: decision_refs,
         decision_manifest: decision_manifest
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :source_discovery_incomplete_decisions}
    end
  end

  defp maybe_put_llm_complete(intelligence_opts, opts) do
    case Keyword.get(opts, :llm_complete) do
      fun when is_function(fun, 1) -> Keyword.put(intelligence_opts, :llm_complete, fun)
      _other -> intelligence_opts
    end
  end

  defp todo_candidates(account, bundle) do
    account_label = source_account_label(account)

    bundle
    |> source_records()
    |> Enum.map(fn record ->
      source = Atom.to_string(record.source)
      source_ref = source <> ":" <> record.identity

      %{
        "source_ref" => source_ref,
        "source" => source,
        "kind" => if(source == "gmail", do: "gmail_triage", else: "general"),
        "title" => record |> candidate_title() |> PromptBudget.truncate_utf8(500),
        "summary" => candidate_summary(record),
        "next_action" => "Decide from the supplied source evidence whether you need to act.",
        "source_account_id" => account.id,
        "source_account_label" => account_label,
        "source_item_id" => source_item_id(record),
        "source_occurred_at" => source_occurred_at(record),
        "dedupe_key" =>
          "source-discovery:#{account.id}:#{short_digest(source_work_identity(record))}",
        "metadata" => %{
          "source_ref" => source_ref,
          "source_record" => candidate_source_record(record),
          "source_roles" => record.roles |> MapSet.to_list() |> Enum.map(&Atom.to_string/1)
        }
      }
    end)
  end

  defp candidate_source_record(%{source: :gmail, item: item}) do
    body = BodyText.from_message(item)

    thread_context = gmail_thread_context(item)

    evidence =
      item
      |> candidate_fields(
        ~w(id message_id thread_id google_provider subject from to cc snippet labels label_ids internal_date date body_available body_status thread_context_complete thread_context_frontier)
      )
      |> put_candidate_size("body", body)
      |> Map.put("body", body)
      |> Map.put("body_format", "readable_text")
      |> Map.put("thread_context", thread_context)

    lossless_candidate_record(evidence)
  end

  defp candidate_source_record(%{source: :slack, item: item}) do
    text = read_string(item, "text_resolved") || read_string(item, "text")

    thread_context =
      item
      |> Map.get("thread_context", [])
      |> Enum.map(fn message ->
        %{
          "ts" => read_string(message, "ts"),
          "user" => read_string(message, "user_display_name") || read_string(message, "user"),
          "text" => read_string(message, "text_resolved") || read_string(message, "text")
        }
      end)

    evidence =
      item
      |> candidate_fields(
        ~w(team_id channel_id channel_name conversation_kind is_dm is_mpim ts thread_ts target_ts provider_event_id user user_display_name user_name counterparty_id counterparty_display_name bot_id subtype permalink date thread_context_complete thread_context_frontier)
      )
      |> put_candidate_size("text", text)
      |> Map.put("text", text)
      |> Map.put("thread_context", thread_context)

    lossless_candidate_record(evidence)
  end

  defp lossless_candidate_record(evidence) when is_map(evidence) do
    complete = Map.put(evidence, "evidence_complete", true)

    cond do
      encoded_bytes(complete) > @candidate_source_record_max_bytes ->
        evidence
        |> Map.take(~w(id message_id thread_id google_provider team_id channel_id ts thread_ts))
        |> Map.put("evidence_complete", false)
        |> Map.put("evidence_bytes", encoded_bytes(evidence))

      prompt_encoded_bytes(complete) <= @candidate_source_record_prompt_max_bytes ->
        complete

      true ->
        # The full record remains in the encrypted handoff. This is only the
        # bounded view sent to the model; preserve the beginning and end of
        # long source text because email requests frequently put the explicit
        # action at the end of the message.
        prompt_compacted_candidate_record(evidence)
    end
  end

  defp prompt_compacted_candidate_record(evidence) do
    text_key = if Map.has_key?(evidence, "body"), do: "body", else: "text"
    text = Map.get(evidence, text_key)

    base =
      evidence
      |> Map.drop([text_key, "thread_context"])
      |> PromptBudget.compact(
        string_bytes: @candidate_prompt_context_string_max_bytes,
        list_items: 10,
        map_entries: 32,
        max_depth: 3,
        key_bytes: 128
      )
      |> Map.put("evidence_complete", true)
      |> Map.put("source_record_bytes", encoded_bytes(evidence))
      |> Map.put("source_record_prompt_compacted", true)

    [
      {@candidate_prompt_excerpt_max_bytes, @candidate_prompt_context_max_items,
       @candidate_prompt_context_string_max_bytes},
      {16_000, 2, 300},
      {8_000, 1, 160},
      {2_000, 0, 0}
    ]
    |> Enum.find_value(fn {text_max_bytes, context_items, context_string_bytes} ->
      candidate =
        base
        |> Map.put(text_key, prompt_text_excerpt(text, text_max_bytes))
        |> Map.put(
          "thread_context",
          compact_prompt_thread_context(
            Map.get(evidence, "thread_context", []),
            context_items,
            context_string_bytes
          )
        )

      if prompt_encoded_bytes(candidate) <= @candidate_source_record_prompt_max_bytes,
        do: candidate
    end) ||
      base
      |> Map.take(
        ~w(id message_id thread_id google_provider team_id channel_id ts thread_ts evidence_complete source_record_bytes source_record_prompt_compacted)
      )
      |> Map.put(text_key, prompt_text_excerpt(text, 0))
      |> Map.put("thread_context", [])
  end

  defp compact_prompt_thread_context(context, max_items, max_string_bytes)
       when is_list(context) and is_integer(max_items) and max_items >= 0 and
              is_integer(max_string_bytes) and max_string_bytes >= 0 do
    context
    |> Enum.filter(&is_map/1)
    |> Enum.take(max_items)
    |> Enum.map(fn item ->
      PromptBudget.compact(item,
        string_bytes: max(max_string_bytes, 1),
        list_items: 10,
        map_entries: 16,
        max_depth: 2,
        key_bytes: 128
      )
    end)
  end

  defp compact_prompt_thread_context(_context, _max_items, _max_string_bytes), do: []

  defp prompt_text_excerpt(nil, _max_bytes), do: nil

  defp prompt_text_excerpt(value, max_bytes)
       when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    sanitized = PromptBudget.truncate_utf8(value, byte_size(value))

    if byte_size(sanitized) <= max_bytes do
      sanitized
    else
      marker = "\n…[middle omitted from model prompt; sealed source retained]…\n"
      available = max(max_bytes - byte_size(marker), 0)
      head_bytes = div(available * 2, 3)
      tail_bytes = available - head_bytes

      head = PromptBudget.truncate_utf8(sanitized, head_bytes)

      tail =
        sanitized
        |> String.reverse()
        |> PromptBudget.truncate_utf8(tail_bytes)
        |> String.reverse()

      head <> marker <> tail
    end
  end

  defp prompt_text_excerpt(_value, _max_bytes), do: nil

  defp prompt_encoded_bytes(value) do
    value
    |> Jason.encode!()
    |> Jason.encode!()
    |> byte_size()
  end

  defp candidate_evidence_complete?(candidate) when is_map(candidate) do
    get_in(candidate, ["metadata", "source_record", "evidence_complete"]) == true
  end

  defp candidate_evidence_complete?(_candidate), do: false

  defp gmail_thread_context(item) do
    item
    |> Map.get("thread_context", [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn message ->
      body = BodyText.from_message(message) || read_string(message, "snippet")

      %{
        "message_id" => read_string(message, "message_id") || read_string(message, "id"),
        "from" => read_string(message, "from"),
        "to" => Map.get(message, "to"),
        "subject" => read_string(message, "subject"),
        "internal_date" => Map.get(message, "internal_date", Map.get(message, "date")),
        "body" => body
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp candidate_fields(item, keys) do
    Enum.reduce(keys, %{}, fn key, fields ->
      case Map.get(item, key, Map.get(item, existing_atom(key))) do
        nil -> fields
        value -> Map.put(fields, key, value)
      end
    end)
  end

  defp put_candidate_size(fields, _prefix, nil), do: fields

  defp put_candidate_size(fields, prefix, value) do
    fields
    |> Map.put(prefix <> "_bytes", byte_size(value))
    |> Map.put(prefix <> "_truncated", false)
  end

  defp candidate_title(%{source: :gmail, item: item}),
    do: read_string(item, "subject") || "New Gmail message"

  defp candidate_title(%{source: :slack, item: item}),
    do:
      read_string(item, "channel_name") || read_string(item, "channel_id") || "New Slack message"

  defp candidate_summary(%{source: :gmail, item: item}) do
    current =
      read_string(item, "body_text") || read_string(item, "text_body") ||
        read_string(item, "body") || read_string(item, "snippet") || "Gmail message"

    context =
      item
      |> gmail_thread_context()
      |> Enum.map(fn message ->
        sender = read_string(message, "from") || "Someone"
        body = read_string(message, "body")
        if body, do: "#{sender}: #{head_tail_excerpt(body, @candidate_context_text_max_bytes)}"
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> head_tail_excerpt(@candidate_context_text_max_bytes)

    [head_tail_excerpt(current, @candidate_current_text_max_bytes), context]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\nEarlier thread context:\n")
    |> candidate_excerpt()
  end

  defp candidate_summary(%{source: :slack, item: item}) do
    current = read_string(item, "text_resolved") || read_string(item, "text") || "Slack message"

    context =
      item
      |> Map.get("thread_context", [])
      |> Enum.map(fn message ->
        sender =
          read_string(message, "user_display_name") || read_string(message, "user") || "Someone"

        text = read_string(message, "text_resolved") || read_string(message, "text")
        if text, do: "#{sender}: #{head_tail_excerpt(text, @candidate_context_text_max_bytes)}"
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> head_tail_excerpt(@candidate_context_text_max_bytes)

    [head_tail_excerpt(current, @candidate_current_text_max_bytes), context]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\nThread context:\n")
    |> candidate_excerpt()
  end

  defp candidate_excerpt(value), do: head_tail_excerpt(value, @candidate_summary_max_bytes)

  defp head_tail_excerpt(nil, _max_bytes), do: nil

  defp head_tail_excerpt(value, max_bytes)
       when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    marker = "\n… [middle omitted] …\n"

    if byte_size(value) <= max_bytes or max_bytes <= byte_size(marker) do
      PromptBudget.truncate_utf8(value, max_bytes)
    else
      content_bytes = max_bytes - byte_size(marker)
      head_bytes = div(content_bytes, 2)
      tail_bytes = content_bytes - head_bytes
      tail_offset = max(byte_size(value) - tail_bytes, 0)

      head = PromptBudget.truncate_utf8(value, head_bytes)

      tail =
        value
        |> binary_part(tail_offset, byte_size(value) - tail_offset)
        |> PromptBudget.truncate_utf8(tail_bytes)

      head <> marker <> tail
    end
  end

  defp source_item_id(%{source: :gmail, item: item}),
    do: read_string(item, "message_id") || read_string(item, "id")

  defp source_item_id(%{source: :slack, item: item}) do
    channel_id = read_string(item, "channel_id")
    ts = read_string(item, "ts")
    if channel_id && ts, do: channel_id <> ":" <> ts
  end

  # A conversation represents one evolving open loop even when a provider
  # delivers several messages for it at once. Key Gmail work by thread and
  # Slack work by thread root so concurrent fan-outs cannot surface duplicate
  # work items for repeated notifications or replies in the same conversation.
  defp source_work_identity(%{source: :gmail, identity: identity, item: item}) do
    provider = read_string(item, "google_provider") || "unknown"
    "gmail:#{provider}:#{read_string(item, "thread_id") || identity}"
  end

  defp source_work_identity(%{source: :slack, identity: identity, item: item}) do
    team_id = read_string(item, "team_id") || "unknown"
    channel_id = read_string(item, "channel_id") || "unknown"
    thread_id = read_string(item, "thread_ts") || read_string(item, "ts") || identity
    "slack:#{team_id}:#{channel_id}:#{thread_id}"
  end

  defp source_occurred_at(%{source: :gmail, item: item}) do
    item
    |> Map.get("internal_date", Map.get(item, "date"))
    |> normalize_source_datetime(:millisecond)
  end

  defp source_occurred_at(%{source: :slack, item: item}) do
    item
    |> Map.get("date", Map.get(item, "ts"))
    |> normalize_source_datetime(:second)
  end

  defp normalize_source_datetime(%DateTime{} = value, _unit), do: DateTime.to_iso8601(value)

  defp normalize_source_datetime(value, unit) when is_integer(value) do
    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _other -> nil
    end
  end

  defp normalize_source_datetime(value, unit) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_iso8601(datetime)

      _other ->
        case Float.parse(value) do
          {number, ""} ->
            normalize_source_datetime(round(number * unit_multiplier(unit)), :microsecond)

          _invalid ->
            nil
        end
    end
  end

  defp normalize_source_datetime(_value, _unit), do: nil

  defp unit_multiplier(:second), do: 1_000_000
  defp unit_multiplier(:millisecond), do: 1_000

  defp source_account_label(%ConnectedAccount{metadata: metadata, provider: provider}) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    read_string(metadata, "account_email") || read_string(metadata, "team_name") || provider
  end

  defp short_digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 24)
  end

  defp discovery_config(agent, user_id, source_scope) do
    agent_config = if is_struct(agent, Agent), do: agent.config || %{}, else: %{}

    Followthrough.default_config()
    |> Map.merge(shared_config(agent_config))
    |> Map.merge(read_map(read_map(agent_config, "skill_configs"), "followthrough"))
    |> Map.put("user_id", user_id)
    |> Map.put("source_scope", source_scope)
    |> Map.put("assistant_behavior", "ai_chief_of_staff")
  end

  defp shared_config(config) do
    ["timezone", "timezone_name", "timezone_offset_hours", "source_policy"]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(config, key, Map.get(config, existing_atom(key))) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp build_compact_bundle(bundle) do
    %{
      "trigger" => Map.get(bundle, "trigger"),
      "fetched_at" => Map.get(bundle, "fetched_at"),
      "freshness" => SourceBundle.freshness(bundle),
      "source_scope" => SourceBundle.source_scope(bundle),
      "gmail" => %{
        "messages" => SourceBundle.gmail_messages(bundle),
        "inbox_messages" => SourceBundle.gmail_inbox_messages(bundle),
        "sent_messages" => SourceBundle.gmail_sent_messages(bundle),
        "messages_by_provider" => %{}
      },
      "calendar" => %{"events" => [], "events_by_provider" => %{}},
      "slack" => %{
        "workspaces" => [],
        "messages" => SourceBundle.slack_messages(bundle),
        "mentions" => SourceBundle.slack_mentions(bundle)
      }
    }
  end

  defp compact_partition(bundle, records) do
    partition = bundle |> partition_source_bundle(records) |> bound_large_binaries()
    compact_bundle(partition)
  end

  defp bound_large_binaries(value) when is_binary(value) do
    if byte_size(value) > @handoff_binary_chunk_bytes do
      compressed = :zlib.gzip(value)
      encoded = Base.encode64(compressed)

      %{
        @bounded_binary_marker => %{
          "byte_size" => byte_size(value),
          "chunks" => chunk_binary(encoded),
          "codec" => "gzip-base64",
          "sha256" => Base.url_encode64(:crypto.hash(:sha256, value), padding: false)
        }
      }
    else
      value
    end
  end

  defp bound_large_binaries(value) when is_list(value),
    do: Enum.map(value, &bound_large_binaries/1)

  defp bound_large_binaries(%_{} = value), do: value

  defp bound_large_binaries(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, bound_large_binaries(item)} end)
  end

  defp bound_large_binaries(value), do: value

  defp chunk_binary(value), do: do_chunk_binary(value, [])

  defp do_chunk_binary(<<>>, chunks), do: Enum.reverse(chunks)

  defp do_chunk_binary(value, chunks) when byte_size(value) <= @handoff_binary_chunk_bytes,
    do: Enum.reverse([value | chunks])

  defp do_chunk_binary(
         <<chunk::binary-size(@handoff_binary_chunk_bytes), rest::binary>>,
         chunks
       ),
       do: do_chunk_binary(rest, [chunk | chunks])

  defp restore_bounded_value(%{@bounded_binary_marker => encoded} = value)
       when map_size(value) == 1 do
    restore_bounded_binary(encoded)
  end

  defp restore_bounded_value(%{@bounded_source_bundle_marker => encoded} = value)
       when map_size(value) == 1 do
    restore_bounded_source_bundle(encoded)
  end

  defp restore_bounded_value(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, restored} ->
      case restore_bounded_value(item) do
        {:ok, restored_item} -> {:cont, {:ok, [restored_item | restored]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _reason} = error -> error
    end
  end

  defp restore_bounded_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, restored} ->
      case restore_bounded_value(item) do
        {:ok, restored_item} -> {:cont, {:ok, Map.put(restored, key, restored_item)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp restore_bounded_value(value), do: {:ok, value}

  defp restore_bounded_binary(%{
         "byte_size" => expected_size,
         "chunks" => chunks,
         "codec" => "gzip-base64",
         "sha256" => expected_digest
       })
       when is_integer(expected_size) and expected_size >= 0 and
              expected_size <= @handoff_max_restored_binary_bytes and is_list(chunks) and
              is_binary(expected_digest) do
    with true <-
           Enum.all?(chunks, &(is_binary(&1) and byte_size(&1) <= @handoff_binary_chunk_bytes)),
         {:ok, compressed} <- Base.decode64(Enum.join(chunks)),
         {:ok, restored} <- bounded_gunzip(compressed, expected_size),
         true <- byte_size(restored) == expected_size,
         true <-
           Base.url_encode64(:crypto.hash(:sha256, restored), padding: false) == expected_digest do
      {:ok, restored}
    else
      _other -> {:error, :source_discovery_partition_corrupt}
    end
  rescue
    _error -> {:error, :source_discovery_partition_corrupt}
  end

  defp restore_bounded_binary(_encoded), do: {:error, :source_discovery_partition_corrupt}

  defp restore_bounded_source_bundle(%{
         "byte_size" => expected_size,
         "chunks" => chunks,
         "codec" => "json-gzip-base64",
         "sha256" => expected_digest
       })
       when is_integer(expected_size) and expected_size >= 0 and
              expected_size <= @handoff_max_encoded_source_bundle_bytes and is_list(chunks) and
              is_binary(expected_digest) do
    with true <-
           Enum.all?(chunks, &(is_binary(&1) and byte_size(&1) <= @handoff_binary_chunk_bytes)),
         {:ok, compressed} <- Base.decode64(Enum.join(chunks)),
         {:ok, encoded} <- bounded_gunzip(compressed, expected_size),
         true <- byte_size(encoded) == expected_size,
         true <-
           Base.url_encode64(:crypto.hash(:sha256, encoded), padding: false) == expected_digest,
         {:ok, bundle} when is_map(bundle) <- Jason.decode(encoded),
         :ok <- validate_restore_budget(bundle, @handoff_max_encoded_source_bundle_bytes),
         :ok <- reject_nested_source_bundle_markers(bundle) do
      restore_bounded_value(bundle)
    else
      _other -> {:error, :source_discovery_partition_corrupt}
    end
  rescue
    _error -> {:error, :source_discovery_partition_corrupt}
  end

  defp restore_bounded_source_bundle(_encoded),
    do: {:error, :source_discovery_partition_corrupt}

  defp reject_nested_source_bundle_markers(%{@bounded_source_bundle_marker => _encoded} = value)
       when map_size(value) == 1,
       do: {:error, :source_discovery_partition_corrupt}

  defp reject_nested_source_bundle_markers(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case reject_nested_source_bundle_markers(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_nested_source_bundle_markers(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {_key, item}, :ok ->
      case reject_nested_source_bundle_markers(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_nested_source_bundle_markers(_value), do: :ok

  defp validate_restore_budget(value, encoded_limit \\ BackgroundJob.max_payload_bytes()) do
    bounds = [
      max_binary_bytes: BackgroundJob.payload_bounds()[:max_binary_bytes],
      max_depth: 64,
      max_nodes: 100_000,
      max_map_entries: BackgroundJob.payload_bounds()[:max_map_entries],
      max_list_items: BackgroundJob.payload_bounds()[:max_list_items]
    ]

    with {:ok, encoded} <- encode_restore_value(value),
         :ok <- validate_restore_encoded_size(encoded, encoded_limit),
         {:ok, canonical} <- decode_restore_value(encoded),
         :ok <- validate_restore_structure(canonical, encoded_limit, bounds),
         {:ok, expanded_bytes} <- marker_expanded_bytes(canonical, 0),
         :ok <- validate_expanded_size(byte_size(encoded) + expanded_bytes) do
      :ok
    end
  end

  defp encode_restore_value(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :source_discovery_partition_json_invalid}
    end
  end

  defp validate_restore_encoded_size(encoded, encoded_limit) do
    if byte_size(encoded) <= encoded_limit,
      do: :ok,
      else: {:error, :source_discovery_partition_encoded_too_large}
  end

  defp decode_restore_value(encoded) do
    case Jason.decode(encoded) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :source_discovery_partition_json_invalid}
    end
  end

  defp validate_restore_structure(canonical, encoded_limit, bounds) do
    if BoundedJSON.valid?(canonical, encoded_limit, bounds),
      do: :ok,
      else: {:error, :source_discovery_partition_structure_too_large}
  end

  defp validate_expanded_size(expanded_bytes) do
    if expanded_bytes <= @handoff_max_restored_bytes,
      do: :ok,
      else: {:error, :source_discovery_partition_expanded_too_large}
  end

  defp marker_expanded_bytes(
         %{@bounded_binary_marker => %{"byte_size" => expected_size}} = value,
         expanded_bytes
       )
       when map_size(value) == 1 and is_integer(expected_size) and expected_size >= 0 and
              expected_size <= @handoff_max_restored_binary_bytes do
    add_expanded_bytes(expanded_bytes, expected_size)
  end

  defp marker_expanded_bytes(
         %{@bounded_source_bundle_marker => %{"byte_size" => expected_size}} = value,
         expanded_bytes
       )
       when map_size(value) == 1 and is_integer(expected_size) and expected_size >= 0 and
              expected_size <= @handoff_max_encoded_source_bundle_bytes do
    add_expanded_bytes(expanded_bytes, expected_size)
  end

  defp marker_expanded_bytes(value, expanded_bytes) when is_list(value) do
    Enum.reduce_while(value, {:ok, expanded_bytes}, fn item, {:ok, bytes} ->
      case marker_expanded_bytes(item, bytes) do
        {:ok, next_bytes} -> {:cont, {:ok, next_bytes}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp marker_expanded_bytes(value, expanded_bytes) when is_map(value) do
    Enum.reduce_while(value, {:ok, expanded_bytes}, fn {_key, item}, {:ok, bytes} ->
      case marker_expanded_bytes(item, bytes) do
        {:ok, next_bytes} -> {:cont, {:ok, next_bytes}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp marker_expanded_bytes(_value, expanded_bytes), do: {:ok, expanded_bytes}

  defp add_expanded_bytes(expanded_bytes, additional_bytes) do
    total = expanded_bytes + additional_bytes

    if total <= @handoff_max_restored_bytes,
      do: {:ok, total},
      else: {:error, :source_discovery_partition_expanded_too_large}
  end

  defp bounded_gunzip(compressed, expected_size)
       when is_binary(compressed) and is_integer(expected_size) and expected_size >= 0 do
    zstream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zstream, 31)
      do_bounded_gunzip(zstream, compressed, expected_size, 0, [])
    rescue
      _error -> {:error, :source_discovery_partition_corrupt}
    catch
      _kind, _reason -> {:error, :source_discovery_partition_corrupt}
    after
      :zlib.close(zstream)
    end
  end

  defp bounded_gunzip(_compressed, _expected_size),
    do: {:error, :source_discovery_partition_corrupt}

  defp do_bounded_gunzip(zstream, input, expected_size, restored_size, chunks) do
    case :zlib.safeInflate(zstream, input) do
      {status, output} when status in [:continue, :finished] ->
        output_size = IO.iodata_length(output)
        next_size = restored_size + output_size

        cond do
          next_size > expected_size ->
            {:error, :source_discovery_partition_corrupt}

          status == :continue and output_size == 0 and input == <<>> ->
            {:error, :source_discovery_partition_corrupt}

          status == :finished ->
            {:ok, chunks |> Enum.reverse([output]) |> IO.iodata_to_binary()}

          true ->
            do_bounded_gunzip(zstream, <<>>, expected_size, next_size, [output | chunks])
        end
    end
  end

  defp partition_source_bundle(bundle, records) do
    gmail_records = Enum.filter(records, &(&1.source == :gmail))
    slack_records = Enum.filter(records, &(&1.source == :slack))

    %{
      "trigger" => Map.get(bundle, "trigger"),
      "fetched_at" => Map.get(bundle, "fetched_at"),
      "freshness" => SourceBundle.freshness(bundle),
      "source_scope" => SourceBundle.source_scope(bundle),
      "gmail" => %{
        "messages" => Enum.map(gmail_records, & &1.item),
        "inbox_messages" =>
          gmail_records |> Enum.filter(&MapSet.member?(&1.roles, :inbox)) |> Enum.map(& &1.item),
        "sent_messages" =>
          gmail_records |> Enum.filter(&MapSet.member?(&1.roles, :sent)) |> Enum.map(& &1.item),
        "messages_by_provider" => %{}
      },
      "calendar" => %{"events" => [], "events_by_provider" => %{}},
      "slack" => %{
        "workspaces" => [],
        "messages" => Enum.map(slack_records, & &1.item),
        "mentions" =>
          slack_records
          |> Enum.filter(&MapSet.member?(&1.roles, :mention))
          |> Enum.map(& &1.item)
      }
    }
  end

  defp source_records(bundle) do
    gmail_inbox_ids = bundle |> SourceBundle.gmail_inbox_messages() |> identity_set(:gmail)
    gmail_sent_ids = bundle |> SourceBundle.gmail_sent_messages() |> identity_set(:gmail)
    slack_mention_ids = bundle |> SourceBundle.slack_mentions() |> identity_set(:slack)

    gmail =
      (SourceBundle.gmail_messages(bundle) ++
         SourceBundle.gmail_inbox_messages(bundle) ++
         SourceBundle.gmail_sent_messages(bundle))
      |> unique_source_items(:gmail)
      |> Enum.map(fn {identity, item} ->
        roles =
          MapSet.new()
          |> maybe_put_role(:inbox, MapSet.member?(gmail_inbox_ids, identity))
          |> maybe_put_role(:sent, MapSet.member?(gmail_sent_ids, identity))

        %{source: :gmail, identity: identity, item: item, roles: roles}
      end)

    slack =
      (SourceBundle.slack_messages(bundle) ++ SourceBundle.slack_mentions(bundle))
      |> unique_source_items(:slack)
      |> Enum.map(fn {identity, item} ->
        roles =
          maybe_put_role(MapSet.new(), :mention, MapSet.member?(slack_mention_ids, identity))

        %{source: :slack, identity: identity, item: item, roles: roles}
      end)

    gmail ++ slack
  end

  defp grouped_source_records(records) do
    {order, groups} =
      Enum.reduce(records, {[], %{}}, fn record, {order, groups} ->
        key = source_group_identity(record)

        if Map.has_key?(groups, key) do
          {order, Map.update!(groups, key, &(&1 ++ [record]))}
        else
          {order ++ [key], Map.put(groups, key, [record])}
        end
      end)

    Enum.map(order, &Map.fetch!(groups, &1))
  end

  defp source_group_identity(%{source: :gmail, identity: identity, item: item}) do
    provider = read_string(item, "google_provider") || "unknown"
    {:gmail, provider, read_string(item, "thread_id") || identity}
  end

  defp source_group_identity(%{source: :slack, identity: identity, item: item}) do
    {:slack, read_string(item, "team_id"), read_string(item, "channel_id"),
     read_string(item, "thread_ts") || read_string(item, "ts") || identity}
  end

  defp provider_occurred_at(%{source: :gmail, item: item}) do
    item
    |> read_string("internal_date")
    |> parse_provider_datetime(:millisecond)
  end

  defp provider_occurred_at(%{source: :slack, item: item}) do
    item
    |> read_string("ts")
    |> parse_provider_datetime(:second)
  end

  defp provider_occurred_at(_record), do: nil

  defp parse_provider_datetime(nil, _unit), do: nil

  defp parse_provider_datetime(value, unit) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      _invalid ->
        case Float.parse(value) do
          {number, ""} when number >= 0 ->
            DateTime.from_unix!(round(number * unit_multiplier(unit)), :microsecond)

          _invalid ->
            nil
        end
    end
  rescue
    _error -> nil
  end

  defp split_source_groups(groups, limit) do
    Enum.flat_map(groups, &split_source_group(&1, limit))
  end

  defp split_source_group(group, limit) do
    {partitions, current, _current_count, _current_bytes} =
      Enum.reduce(group, {[], [], 0, 0}, fn record,
                                            {partitions, current, current_count, current_bytes} ->
        record_bytes = source_group_candidate_bytes([record])

        if current != [] and
             (current_count >= limit or
                current_bytes + record_bytes > @candidate_partition_max_bytes) do
          {[Enum.reverse(current) | partitions], [record], 1, record_bytes}
        else
          {partitions, [record | current], current_count + 1, current_bytes + record_bytes}
        end
      end)

    case current do
      [] -> Enum.reverse(partitions)
      current -> Enum.reverse([Enum.reverse(current) | partitions])
    end
  end

  defp pack_source_groups(groups, limit) do
    {partitions, current, _current_count, _current_bytes} =
      Enum.reduce(groups, {[], [], 0, 0}, fn group,
                                             {partitions, current, current_count, current_bytes} ->
        group_bytes = source_group_candidate_bytes(group)
        group_count = length(group)

        cond do
          current == [] ->
            {partitions, Enum.reverse(group), group_count, group_bytes}

          current_count + group_count <= limit and
              current_bytes + group_bytes <= @candidate_partition_max_bytes ->
            {partitions, Enum.reverse(group, current), current_count + group_count,
             current_bytes + group_bytes}

          true ->
            {[Enum.reverse(current) | partitions], Enum.reverse(group), group_count, group_bytes}
        end
      end)

    case current do
      [] -> Enum.reverse(partitions)
      current -> Enum.reverse([Enum.reverse(current) | partitions])
    end
  end

  defp source_group_candidate_bytes(group) do
    Enum.reduce(group, 0, fn record, bytes ->
      bytes + prompt_encoded_bytes(candidate_source_record(record)) +
        @candidate_prompt_overhead_bytes
    end)
  end

  defp source_identities_complete?(bundle) do
    gmail_items =
      SourceBundle.gmail_messages(bundle) ++
        SourceBundle.gmail_inbox_messages(bundle) ++ SourceBundle.gmail_sent_messages(bundle)

    slack_items = SourceBundle.slack_messages(bundle) ++ SourceBundle.slack_mentions(bundle)

    Enum.all?(gmail_items, &(is_map(&1) and not is_nil(source_identity(&1, :gmail)))) and
      Enum.all?(slack_items, &(is_map(&1) and not is_nil(source_identity(&1, :slack))))
  end

  defp identity_set(items, source) do
    items
    |> unique_source_items(source)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp unique_source_items(items, source) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.reduce([], fn item, acc ->
      case source_identity(item, source) do
        nil -> acc
        identity -> [{identity, item} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp source_identity(item, :gmail) do
    provider = read_string(item, "google_provider") || "unknown"
    id = read_string(item, "message_id") || read_string(item, "id")
    if id, do: provider <> ":" <> id
  end

  defp source_identity(item, :slack) do
    team_id = read_string(item, "team_id")
    channel_id = read_string(item, "channel_id")
    ts = read_string(item, "ts")
    if team_id && channel_id && ts, do: Enum.join([team_id, channel_id, ts], ":")
  end

  defp maybe_put_role(roles, role, true), do: MapSet.put(roles, role)
  defp maybe_put_role(roles, _role, false), do: roles

  defp validate_child_results(
         account,
         child_results,
         expected_fanouts,
         expected_source_items,
         expected_source_refs_digest
       ) do
    indexes =
      child_results
      |> Enum.map(&result_integer(&1, "fanout_index"))
      |> Enum.sort()

    decision_count = Enum.sum(Enum.map(child_results, &result_integer(&1, "decision_count")))
    source_items = Enum.sum(Enum.map(child_results, &result_integer(&1, "source_items")))
    decision_refs = Enum.flat_map(child_results, &result_string_list(&1, "decision_refs"))
    decision_manifest = Enum.flat_map(child_results, &result_list(&1, "decision_manifest"))

    if length(child_results) == expected_fanouts and indexes == Enum.to_list(1..expected_fanouts) and
         decision_count == expected_source_items and source_items == expected_source_items and
         length(decision_refs) == expected_source_items and
         length(Enum.uniq(decision_refs)) == expected_source_items and
         refs_digest(decision_refs) == expected_source_refs_digest and
         valid_discovery_decision_manifest?(
           account,
           decision_manifest,
           decision_refs,
           expected_source_refs_digest
         ) do
      :ok
    else
      {:error, :source_discovery_incomplete_decisions}
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

  defp result_list(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), [])) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp result_list(_result, _key), do: []

  defp valid_discovery_decision_manifest?(
         %ConnectedAccount{} = account,
         manifest,
         decision_refs,
         expected_source_refs_digest
       )
       when is_list(manifest) do
    manifest_refs = Enum.map(manifest, &manifest_string(&1, "source_ref"))

    persisted_todo_ids =
      manifest
      |> Enum.flat_map(fn entry ->
        case {manifest_action(entry), manifest_string(entry, "persisted_todo_id")} do
          {action, todo_id} when action in ["create", "update"] and is_binary(todo_id) ->
            [todo_id]

          _other ->
            []
        end
      end)
      |> Enum.uniq()

    length(manifest) == length(decision_refs) and
      Enum.all?(manifest, &valid_discovery_decision_entry?/1) and
      Enum.sort(manifest_refs) == Enum.sort(decision_refs) and
      refs_digest(manifest_refs) == expected_source_refs_digest and
      persisted_todos_exist?(account, persisted_todo_ids)
  end

  defp valid_discovery_decision_manifest?(_account, _manifest, _decision_refs, _digest),
    do: false

  defp valid_discovery_decision_entry?(entry) when is_map(entry) do
    source_ref = manifest_string(entry, "source_ref")
    action = manifest_action(entry)
    persisted_todo_id = manifest_string(entry, "persisted_todo_id")

    is_binary(source_ref) and action in ["create", "update", "skip"] and
      if(action == "skip",
        do: is_nil(persisted_todo_id),
        else: is_binary(persisted_todo_id)
      )
  end

  defp valid_discovery_decision_entry?(_entry), do: false

  defp manifest_action(entry) when is_map(entry) do
    case Map.get(entry, "action", Map.get(entry, :action)) do
      action when action in ["create", "update", "skip"] -> action
      action when action in [:create, :update, :skip] -> Atom.to_string(action)
      _other -> nil
    end
  end

  defp manifest_action(_entry), do: nil

  defp manifest_string(entry, key) when is_map(entry) do
    case Map.get(entry, key, Map.get(entry, existing_atom(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp manifest_string(_entry, _key), do: nil

  defp persisted_todos_exist?(_account, []), do: true

  defp persisted_todos_exist?(account, todo_ids) do
    count =
      Todo
      |> where(
        [todo],
        todo.id in ^todo_ids and todo.user_id == ^account.user_id and
          todo.source_account_id == ^account.id
      )
      |> Repo.aggregate(:count, :id)

    count == length(todo_ids)
  end

  defp encoded_bytes(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _reason} -> @handoff_max_encoded_source_bundle_bytes + 1
    end
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
      else: {:error, :source_discovery_watermark_invalid}
  end

  defp validate_watermarks(_watermarks), do: {:error, :source_discovery_watermark_invalid}

  defp advance_watermarks(account, watermarks) when is_list(watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      with true <- read_integer(watermark, "account_id") == account.id,
           kind when is_binary(kind) <- read_string(watermark, "kind"),
           true <- allowed_watermark_kind?(kind),
           value when is_binary(value) <- read_string(watermark, "value"),
           {:ok, _cursor} <- SourceCursors.put(account, kind, %{"value" => value}) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :source_discovery_watermark_account_mismatch}}
        nil -> {:halt, {:error, :invalid_source_discovery_watermark}}
        {:error, reason} -> {:halt, {:error, {:source_discovery_cursor_advance_failed, reason}}}
        _other -> {:halt, {:error, :invalid_source_discovery_watermark}}
      end
    end)
  end

  defp allowed_watermark_kind?(kind) do
    kind in @allowed_watermark_kinds or GmailSourceReplay.watermark_kind?(kind, "discovery") or
      SlackSourceReplay.watermark_kind?(kind, "discovery")
  end

  defp maybe_filter_settled_source_items(bundle, account, role, opts)
       when is_list(opts) do
    if is_map(Keyword.get(opts, :source_replay)) do
      bundle
    else
      filter_settled_source_items(bundle, account, role)
    end
  end

  defp validate_replay_opts(account, opts, role) do
    source_replay_module(account).validate_runtime_replay(
      account,
      Keyword.get(opts, :source_replay),
      role
    )
  end

  defp put_replay_context(context, opts, role) when is_map(context) and is_list(opts) do
    case Keyword.get(opts, :source_replay) do
      %{lower: lower, upper: upper, kind: kind}
      when is_integer(lower) and is_integer(upper) and is_binary(kind) ->
        if replay_watermark_kind?(kind, role) do
          context
          |> Map.put(:source_replay_window, %{lower: lower, upper: upper})
          |> Map.put(:source_watermark_kind_override, kind)
        else
          context
        end

      _other ->
        context
    end
  end

  defp replay_watermark_kind?(kind, role) do
    GmailSourceReplay.watermark_kind?(kind, role) or SlackSourceReplay.watermark_kind?(kind, role)
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

  defp validate_ownership(%ConnectedAccount{user_id: user_id}, %Agent{user_id: user_id}), do: :ok
  defp validate_ownership(%ConnectedAccount{}, nil), do: :ok
  defp validate_ownership(_account, _agent), do: {:error, :source_discovery_user_mismatch}

  defp validate_payload_identity(account, %Agent{} = agent, payload) do
    if read_integer(payload, "account_id") == account.id and
         read_string(payload, "agent_id") == agent.id do
      :ok
    else
      {:error, :source_discovery_payload_identity_mismatch}
    end
  end

  defp validate_payload_identity(account, nil, payload) do
    if read_integer(payload, "account_id") == account.id and
         is_nil(read_string(payload, "agent_id")) do
      :ok
    else
      {:error, :source_discovery_payload_identity_mismatch}
    end
  end

  defp maybe_put_agent_id(payload, %Agent{id: id}), do: Map.put(payload, "agent_id", id)
  defp maybe_put_agent_id(payload, nil), do: payload

  defp agent_id(%Agent{id: id}), do: id
  defp agent_id(nil), do: nil

  defp account_source_scope(%ConnectedAccount{provider: provider} = account) do
    service = if provider == "google" or String.starts_with?(provider, "google:"), do: "gmail"
    SourceScope.for_account(account, service)
  end

  defp account_event_topic(%ConnectedAccount{provider: "slack:" <> rest}) do
    team_id = rest |> String.split(":", parts: 2) |> List.first()
    "slack:#{team_id}"
  end

  defp account_event_topic(%ConnectedAccount{id: id}), do: "email:account-#{id}"

  defp account_delta_source(%ConnectedAccount{provider: "slack:" <> _rest}), do: "slack"
  defp account_delta_source(%ConnectedAccount{}), do: "gmail"

  defp validate_complete_acquisition(account, telemetry) do
    source = account_delta_source(account)

    if Acquisition.source_complete?(telemetry, source) do
      :ok
    else
      {:error, {:source_discovery_acquisition_incomplete, source}}
    end
  end

  defp read_map(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, existing_atom(key), %{})) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp fetch_map(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, {:missing_map_payload, key}}
    end
  end

  defp fetch_list(map, key, default \\ :missing) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      :error when is_list(default) -> {:ok, default}
      _other -> {:error, {:missing_list_payload, key}}
    end
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp read_integer(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
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

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp existing_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end
end
