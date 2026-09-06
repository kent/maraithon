defmodule Maraithon.Behaviors.AIChiefOfStaff do
  @moduledoc """
  Unified operator-facing assistant that orchestrates internal Chief of Staff skills.

  The first implementation slice composes the existing follow-through, travel,
  and briefing systems behind one behavior and one builder template.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.ChiefOfStaff.{Acquisition, AttentionArbiter, Skills, SourceBundle}
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OperatorEvents

  require Logger

  # GOALS.md: the Chief of Staff wakes every 10 minutes, with lean modes
  # allowed to stretch to 15. R1 (SPEC 04): default cadence is 10 minutes;
  # the floor (not a slow-down clamp) is 5 minutes so config can only make
  # cadence *faster*, never forced back up to the old hourly loop.
  @default_wakeup_interval_ms :timer.minutes(10)
  @min_wakeup_interval_ms :timer.minutes(5)
  # Gmail and Slack deltas are owned by the per-account source workers. The
  # Chief normally coordinates their persisted todos and only re-reads those
  # providers on this bounded deep-reconciliation cadence. This keeps the
  # ten-minute attention loop cheap without removing the parity safety pass.
  @default_deep_scan_interval_hours 4

  @impl true
  def init(config) do
    user_id = normalize_string(config["user_id"])
    enabled_skill_ids = Skills.enabled_ids(config)
    skill_configs = build_skill_configs(config, user_id, enabled_skill_ids)

    skill_states =
      Enum.reduce(enabled_skill_ids, %{}, fn skill_id, acc ->
        module = Skills.get!(skill_id)
        Map.put(acc, skill_id, module.init(Map.fetch!(skill_configs, skill_id)))
      end)

    %{
      user_id: user_id,
      enabled_skill_ids: enabled_skill_ids,
      skill_configs: skill_configs,
      skill_states: skill_states,
      cycle_skill_ids: nil,
      assistant_cycle_id: nil,
      pending_emit: nil,
      pending_emits: [],
      pending_effect_skill_id: nil,
      resume_index: 0,
      pending_watermarks: [],
      last_watermarks: %{},
      last_cycle_stats: %{},
      cycle_memory: %{"memo" => nil, "updated_at" => nil, "cycle_id" => nil},
      cycle_memo_generated: false,
      # R5 (SPEC 07): structured cross-cycle decision ledger, keyed by stable
      # item_id (todo id, insight id — never an ephemeral cycle id). Sibling
      # of the prose `cycle_memory`, never a replacement.
      decision_ledger: %{},
      wakeup_interval_ms:
        config
        |> Map.get("wakeup_interval_ms")
        |> positive_integer(@default_wakeup_interval_ms)
        |> max(@min_wakeup_interval_ms),
      last_deep_scan_at: nil,
      deep_scan_interval_ms:
        config
        |> Map.get("deep_scan_interval_hours")
        |> positive_integer(@default_deep_scan_interval_hours)
        |> :timer.hours()
    }
  end

  # Restored behavior_state snapshots can predate keys added by newer
  # releases; `%{state | key: ...}` update syntax and `state.key` dot access
  # both raise KeyError on such maps, killing every wakeup after a deploy
  # (observed in prod 2026-07-03 with :pending_watermarks). Seed any missing
  # keys with their init/1 defaults before the cycle logic touches them.
  @state_key_defaults %{
    source_bundle: nil,
    assistant_fetch_telemetry: nil,
    pending_watermarks: [],
    last_watermarks: %{},
    last_cycle_stats: %{},
    cycle_memory: %{"memo" => nil, "updated_at" => nil, "cycle_id" => nil},
    cycle_memo_generated: false,
    # R5 (SPEC 07): redundant with SPEC 08's generic init/1-merge on restore,
    # but harmless — kept so ensure_state_keys/1 also back-fills mid-wakeup.
    decision_ledger: %{},
    last_deep_scan_at: nil,
    deep_scan_interval_ms: :timer.hours(@default_deep_scan_interval_hours)
  }

  defp ensure_state_keys(state) when is_map(state) do
    Map.merge(@state_key_defaults, state)
  end

  @impl true
  def handle_wakeup(state, context) do
    state =
      case state.user_id do
        nil -> %{state | user_id: normalize_string(context[:user_id])}
        _ -> state
      end
      |> ensure_state_keys()
      |> ensure_cycle(context)

    run_from_index(state.resume_index || 0, state, context)
  end

  @impl true
  def handle_effect_result(effect_result, state, context) do
    state = ensure_state_keys(state)

    case state.pending_effect_skill_id do
      nil ->
        {:idle, state}

      :cycle_memo ->
        handle_cycle_memo_effect_result(effect_result, state, context)

      skill_id ->
        module = Skills.get!(skill_id)
        skill_state = Map.fetch!(state.skill_states, skill_id)
        index = skill_index(state, skill_id)
        skill_context = skill_context(state, context, skill_id, index)

        case module.handle_effect_result(effect_result, skill_state, skill_context) do
          {:effect, effect, next_skill_state} ->
            {:effect, effect, put_skill_state(state, skill_id, next_skill_state)}

          {:emit, emit, next_skill_state} ->
            state =
              state
              |> put_skill_state(skill_id, next_skill_state)
              |> Map.put(:pending_effect_skill_id, nil)
              |> stash_emit(emit, skill_id, index)

            {:continue, state}

          {:continue, next_skill_state} ->
            {:continue,
             state
             |> put_skill_state(skill_id, next_skill_state)
             |> Map.put(:pending_effect_skill_id, nil)
             |> Map.put(:resume_index, index)}

          {:idle, next_skill_state} ->
            state =
              state
              |> put_skill_state(skill_id, next_skill_state)
              |> Map.put(:pending_effect_skill_id, nil)

            {:continue, state}
        end
    end
  end

  @impl true
  def handle_effect_error(effect_type, reason, state, context) do
    state = ensure_state_keys(state)

    case state.pending_effect_skill_id do
      nil ->
        {:idle, state}

      :cycle_memo ->
        Logger.warning("ChiefOfStaff cycle memo generation failed",
          failure_code: Maraithon.Redaction.error_class(reason),
          error_class: Maraithon.Redaction.error_class({effect_type, reason})
        )

        finalize_cycle(mark_cycle_memo_done(state))

      skill_id ->
        module = Skills.get!(skill_id)
        skill_state = Map.fetch!(state.skill_states, skill_id)
        index = skill_index(state, skill_id)
        skill_context = skill_context(state, context, skill_id, index)

        if function_exported?(module, :handle_effect_error, 4) do
          case module.handle_effect_error(effect_type, reason, skill_state, skill_context) do
            {:effect, effect, next_skill_state} ->
              {:effect, effect, put_skill_state(state, skill_id, next_skill_state)}

            {:emit, emit, next_skill_state} ->
              state =
                state
                |> put_skill_state(skill_id, next_skill_state)
                |> Map.put(:pending_effect_skill_id, nil)
                |> stash_emit(emit, skill_id, index)

              {:continue, state}

            {:continue, next_skill_state} ->
              {:continue,
               state
               |> put_skill_state(skill_id, next_skill_state)
               |> Map.put(:pending_effect_skill_id, nil)
               |> Map.put(:resume_index, index)}

            {:idle, next_skill_state} ->
              state =
                state
                |> put_skill_state(skill_id, next_skill_state)
                |> Map.put(:pending_effect_skill_id, nil)

              {:continue, state}
          end
        else
          # R1 (SPEC 07): a skill without handle_effect_error/4 must not
          # terminate the whole cycle with a bare {:idle, ...} — that skips
          # every remaining skill AND finalize_cycle/1 (watermarks, emits,
          # cycle_skill_ids/resume_index reset), freezing a stale cycle that
          # any later trigger would resume against old data. Log, record an
          # operator event, and resume at the next skill; resume_index was
          # already stashed at effect-request time (run_from_index/3 set it
          # to index + 1) — do not recompute it. Yield to the runtime so it
          # renews authority before starting the next skill.
          Logger.warning("ChiefOfStaff skill effect failed; continuing cycle at next skill",
            skill_id: skill_id,
            effect_type: effect_type_label(effect_type),
            failure_code: Maraithon.Redaction.error_class(reason),
            assistant_cycle_id: state.assistant_cycle_id
          )

          record_skill_effect_error(state, skill_id, effect_type, reason)

          state = %{state | pending_effect_skill_id: nil}
          {:continue, state}
        end
    end
  end

  defp record_skill_effect_error(state, skill_id, effect_type, reason) do
    _ =
      OperatorEvents.record(%{
        user_id: state.user_id,
        source: "chief_of_staff",
        event_type: "cycle.skill_effect_error",
        source_item_id: skill_id,
        dedupe_key: "cos_skill_effect_error:#{state.assistant_cycle_id}:#{skill_id}",
        payload: %{
          "effect_type" => to_string(effect_type),
          "reason" => Maraithon.Redaction.error_summary(reason),
          "resume_index" => state.resume_index
        }
      })

    :ok
  end

  defp effect_type_label(effect_type) when is_atom(effect_type), do: Atom.to_string(effect_type)
  defp effect_type_label(_effect_type), do: "unknown"

  @impl true
  def snapshot_state(state) when is_map(state) do
    state
    |> Map.drop([:source_bundle, :assistant_fetch_telemetry])
    |> Maraithon.Behaviors.SnapshotTrim.trim()
  end

  def snapshot_state(state), do: state

  @doc false
  def pop_cycle_context(state) when is_map(state) do
    source_bundle = Map.get(state, :source_bundle)
    telemetry = Map.get(state, :assistant_fetch_telemetry)

    cycle_context =
      if is_nil(source_bundle) and is_nil(telemetry) do
        nil
      else
        %{source_bundle: source_bundle, assistant_fetch_telemetry: telemetry}
      end

    {Map.drop(state, [:source_bundle, :assistant_fetch_telemetry]), cycle_context}
  end

  @doc false
  def put_cycle_context(state, cycle_context) when is_map(state) and is_map(cycle_context) do
    state
    |> Map.put(:source_bundle, Map.get(cycle_context, :source_bundle))
    |> Map.put(:assistant_fetch_telemetry, Map.get(cycle_context, :assistant_fetch_telemetry))
  end

  @impl true
  def next_wakeup(state) do
    scan_schedule = {:relative, Map.get(state, :wakeup_interval_ms, @default_wakeup_interval_ms)}

    state.enabled_skill_ids
    |> drop_unknown_skill_ids(:next_wakeup)
    |> Enum.reduce(scan_schedule, fn skill_id, schedule ->
      module = Skills.get!(skill_id)
      skill_state = Map.fetch!(state.skill_states, skill_id)
      merge_wakeup(schedule, module.next_wakeup(skill_state))
    end)
    |> clamp_relative_scan_floor()
  end

  def default_skill_ids, do: Skills.default_enabled_ids()

  @impl true
  def schema_version, do: 2

  @impl true
  def migrate_state(stored_version, state, _config) when stored_version < 2 and is_map(state) do
    restart_restored_cycle(state)
  end

  def migrate_state(_stored_version, state, _config), do: state

  # SPEC 08 R6: called by the runtime only at restore time (never per-wakeup —
  # context deliberately does not carry raw agent_config). Recomputes the
  # config-derived slice of state — enabled_skill_ids, skill_configs, and
  # skill *existence* in skill_states — from the CURRENT config, so a skill
  # shipped after the snapshot was written (local_pattern_review) actually
  # turns on for existing agents. Touches ONLY those three keys; every
  # in-flight and accumulated key passes through untouched, and an existing
  # skill_states entry is never re-init'd (that would discard real
  # accumulated per-skill history). Pure and idempotent.
  @impl true
  def reconcile_restored_state(state, config) do
    state = restart_restored_cycle(state)
    live_ids = Skills.enabled_ids(config)

    # A snapshot can carry skill ids a later release removed or renamed;
    # Skills.get!/1 on such an id raises, and a raise here leaves the runtime
    # holding the UNreconciled state, so every subsequent wakeup raises too —
    # a deterministic crash loop. Drop unknown ids before anything looks them
    # up in the registry.
    snapshot_ids =
      drop_unknown_skill_ids(state.enabled_skill_ids || [], :reconcile_restored_state)

    desired_ids = degenerate_config_guard(live_ids, snapshot_ids)

    # Never prune a skill_states entry referenced by an in-flight cycle —
    # run_from_index/handle_effect_result Map.fetch! those ids. An orphaned
    # entry for a since-disabled skill is pruned on a later restore, once the
    # cycle that referenced it has finished.
    in_flight_ids = drop_unknown_skill_ids(state.cycle_skill_ids || [], :reconcile_in_flight)
    keep_ids = Enum.uniq(desired_ids ++ in_flight_ids)
    desired_configs = build_skill_configs(config, state.user_id, keep_ids)

    skill_states =
      Enum.reduce(keep_ids, %{}, fn skill_id, acc ->
        case Map.fetch(state.skill_states, skill_id) do
          {:ok, existing} ->
            Map.put(acc, skill_id, existing)

          :error ->
            module = Skills.get!(skill_id)
            skill_config = Map.get(desired_configs, skill_id, module.default_config())
            Map.put(acc, skill_id, module.init(skill_config))
        end
      end)

    %{
      state
      | enabled_skill_ids: desired_ids,
        skill_configs: desired_configs,
        skill_states: skill_states,
        # Sanitized alongside skill_states: keep_ids no longer carries unknown
        # ids, so an unsanitized cycle_skill_ids list would make run_from_index
        # crash on Map.fetch!/Skills.get! for the pruned entry.
        cycle_skill_ids: if(is_list(state.cycle_skill_ids), do: in_flight_ids)
    }
  end

  defp restart_restored_cycle(state) do
    skill_states =
      state
      |> Map.get(:skill_states, %{})
      |> Map.new(fn {skill_id, skill_state} ->
        {skill_id, reset_transient_skill_state(skill_id, skill_state)}
      end)

    state
    |> Map.drop([:source_bundle, :assistant_fetch_telemetry])
    |> Map.merge(%{
      skill_states: skill_states,
      cycle_skill_ids: nil,
      assistant_cycle_id: nil,
      pending_emit: nil,
      pending_emits: [],
      pending_effect_skill_id: nil,
      resume_index: 0,
      pending_watermarks: [],
      cycle_memo_generated: false
    })
  end

  @legacy_transient_skill_keys [
    :pending_tracker_input,
    :pending_check_in_input,
    :pending_brief_input,
    :pending_dedupe_key
  ]

  defp reset_transient_skill_state(skill_id, skill_state) when is_map(skill_state) do
    string_keys = Enum.map(@legacy_transient_skill_keys, &Atom.to_string/1)

    skill_state =
      skill_state
      |> Map.drop(@legacy_transient_skill_keys ++ string_keys)
      |> Map.drop([
        :source_bundle,
        "source_bundle",
        :assistant_fetch_telemetry,
        "assistant_fetch_telemetry"
      ])

    case skill_id do
      "commitment_tracker" ->
        Map.put(skill_state, :pending_effect, nil)

      "calendar_check_in" ->
        Map.put(skill_state, :pending_effect, nil)

      "holiday_radar" ->
        skill_state
        |> Map.put(:pending_review_key, nil)
        |> Map.update(:pending_holidays, %{}, &compact_restored_holidays/1)

      "morning_briefing" ->
        Map.put(skill_state, :pending_effect, nil)

      "local_pattern_review" ->
        skill_state
        |> Map.delete(:pending_candidates)
        |> Map.delete("pending_candidates")
        |> Map.put(:pending_candidate_refs, [])

      "inbox_calendar_advisor" ->
        skill_state
        |> Map.put(:pending_candidates, [])
        |> Map.put(:pending_direct_insights, [])
        |> Map.put(:pending_relationship_observations, [])
        |> Map.put(:pending_llm_kind, nil)
        |> Map.put(:pending_emit, nil)

      _other ->
        if Map.has_key?(skill_state, :pending_candidates),
          do: Map.put(skill_state, :pending_candidates, []),
          else: skill_state
    end
  end

  defp reset_transient_skill_state(_skill_id, skill_state), do: skill_state

  defp compact_restored_holidays(holidays) when is_map(holidays) do
    Map.new(holidays, fn {id, holiday} ->
      compact =
        if is_map(holiday) do
          Map.take(holiday, [:id, :name, :date, :region, "id", "name", "date", "region"])
        else
          %{}
        end

      {id, compact}
    end)
  end

  defp compact_restored_holidays(_holidays), do: %{}

  # Guard against a transient/misread config being mistaken for a deliberate
  # "disable (almost) everything" operator change. `Skills.enabled_ids/1`
  # returning `[]`, or a list far shorter than what the snapshot already had
  # enabled, is more plausibly a config-read blip (env var missing on this
  # particular restart, a partially-applied config change mid-deploy) than a
  # real intent to strip most of a user's enabled skills in one shot — and the
  # failure mode of guessing wrong the "config wins" way is severe and
  # irreversible-by-default: every skill_states entry not in the (wrongly)
  # shrunk desired_ids list is dropped from this restore's skill_states,
  # permanently discarding that skill's accumulated per-skill history the
  # moment this reconciled state is next checkpointed. Guessing wrong the
  # "snapshot wins" way, by contrast, only costs one extra restart cycle
  # before a genuine config change fully takes effect — a much cheaper
  # mistake. A normal config change (e.g. adding `local_pattern_review`, the
  # motivating case) only ever *grows* or lightly trims the list and never
  # trips this guard.
  defp degenerate_config_guard(live_ids, snapshot_ids) do
    cond do
      live_ids == [] and snapshot_ids != [] -> snapshot_ids
      snapshot_ids != [] and length(live_ids) < length(snapshot_ids) / 2 -> snapshot_ids
      true -> live_ids
    end
  end

  defp run_from_index(index, state, context) when index < 0, do: run_from_index(0, state, context)

  defp run_from_index(index, state, context) do
    skill_ids = cycle_skill_ids(state)

    if index >= length(skill_ids) do
      state = %{state | resume_index: 0}

      # R9 (SPEC 07): only a scheduled cycle re-synthesizes the prose memo —
      # a :message/:pubsub_event partial cycle ran 1-2 skills against thin
      # activity and must not overwrite the last full scan's richer memo (or
      # pay the LLM call). mark_cycle_memo_done/1 still runs so
      # cycle_memo_generated/pending_effect_skill_id reset consistently for
      # the next cycle, exactly as request_cycle_memo/2's :skip branch does;
      # cycle_memory itself is left untouched. The decision-ledger merge is
      # NOT gated this way — it already happened in stash_emit/4 for every
      # cycle regardless of trigger type.
      if scheduled_trigger?(context) do
        request_cycle_memo(state, context)
      else
        finalize_cycle(mark_cycle_memo_done(state))
      end
    else
      skill_id = Enum.at(skill_ids, index)
      module = Skills.get!(skill_id)
      skill_state = Map.fetch!(state.skill_states, skill_id)
      skill_context = skill_context(state, context, skill_id, index)

      case module.handle_wakeup(skill_state, skill_context) do
        {:effect, effect, next_skill_state} ->
          {:effect, effect,
           state
           |> put_skill_state(skill_id, next_skill_state)
           |> Map.put(:pending_effect_skill_id, skill_id)
           |> Map.put(:resume_index, index + 1)}

        {:emit, emit, next_skill_state} ->
          state =
            state
            |> put_skill_state(skill_id, next_skill_state)
            |> stash_emit(emit, skill_id, index)

          {:continue, %{state | resume_index: index + 1}}

        {:continue, next_skill_state} ->
          {:continue,
           state
           |> put_skill_state(skill_id, next_skill_state)
           |> Map.put(:resume_index, index)}

        {:idle, next_skill_state} ->
          state =
            state
            |> put_skill_state(skill_id, next_skill_state)

          {:continue, %{state | resume_index: index + 1}}
      end
    end
  end

  # R3/R4 (SPEC 04): before finalizing, ask the model for a short cycle memo
  # ("state of the world + what I decided/held this cycle") so the next
  # wakeup reasons over deltas instead of starting from scratch. This is a
  # cheap effect (skipped entirely on a quiet cycle with no deltas/emits —
  # near-zero spend) routed through the same effect/continue machinery
  # skills use, keyed off the `:cycle_memo` sentinel instead of a skill id.
  defp request_cycle_memo(%{cycle_memo_generated: true} = state, _context) do
    finalize_cycle(state)
  end

  defp request_cycle_memo(state, _context) do
    case memo_llm_params(state) do
      {:ok, params} ->
        {:effect, {:llm_call, params}, %{state | pending_effect_skill_id: :cycle_memo}}

      :skip ->
        finalize_cycle(mark_cycle_memo_done(state))
    end
  end

  defp handle_cycle_memo_effect_result({:llm_call, response}, state, context) do
    state =
      state
      |> put_cycle_memo(extract_memo_text(response), context)
      |> mark_cycle_memo_done()

    finalize_cycle(state)
  end

  defp handle_cycle_memo_effect_result(_effect_result, state, _context) do
    finalize_cycle(mark_cycle_memo_done(state))
  end

  defp mark_cycle_memo_done(state) do
    %{state | pending_effect_skill_id: nil, cycle_memo_generated: true}
  end

  # R9 (SPEC 07): identical semantics to goal_alignment.ex's
  # scheduled_trigger?/1 so "scheduled" is defined the same way everywhere.
  defp scheduled_trigger?(context) do
    case get_in(context, [:trigger, :type]) do
      nil -> is_nil(context[:event]) and is_nil(context[:last_message])
      :wakeup -> true
      _other -> false
    end
  end

  defp put_cycle_memo(state, nil, _context), do: state

  defp put_cycle_memo(state, memo_text, context) when is_binary(memo_text) do
    %{
      state
      | cycle_memory: %{
          "memo" => memo_text,
          "updated_at" => DateTime.to_iso8601(context[:timestamp] || DateTime.utc_now()),
          "cycle_id" => state.assistant_cycle_id
        }
    }
  end

  defp finalize_cycle(state) do
    advanced_watermarks = advance_pending_watermarks(state)
    log_cycle_delta_summary(state)

    emit =
      AttentionArbiter.finalize_emit(
        state.pending_emit,
        state.pending_emits,
        state.assistant_cycle_id,
        state.assistant_fetch_telemetry
      )

    state = %{
      state
      | cycle_skill_ids: nil,
        assistant_cycle_id: nil,
        source_bundle: nil,
        # R3 (SPEC 04): keep a compact per-source watermark/stats snapshot in
        # behavior_state (already snapshotted/restored) even though the
        # canonical watermark lives in `source_cursors` — this is what
        # carries "what I last saw per source" forward for the agent's own
        # reasoning, independent of the DB round-trip.
        last_watermarks: Map.merge(state.last_watermarks || %{}, advanced_watermarks),
        last_cycle_stats: (state.assistant_fetch_telemetry || %{}) |> Map.get("sources", %{}),
        assistant_fetch_telemetry: nil,
        pending_effect_skill_id: nil,
        pending_emits: [],
        pending_watermarks: [],
        cycle_memo_generated: false,
        resume_index: 0
    }

    case emit do
      nil ->
        # pending_emit must be cleared here too — leaving it set would leak a
        # stale emit into the next cycle's merge_emit/stash_emit path.
        {:idle, %{state | pending_emit: nil}}

      finalized_emit ->
        {:emit, finalized_emit, %{state | pending_emit: nil}}
    end
  end

  # R4 (SPEC 04): watermarks are only ever advanced here, after every skill's
  # effects for this cycle have completed (durable writes committed) and the
  # cycle memo attempt has resolved. Acquisition defers advancement for the
  # scheduled cycle (`defer_watermark_advance: true`) and instead proposes
  # `%{account:, kind:, value:}` entries; a crash before this point leaves the
  # watermark untouched, so the next wakeup reprocesses the same items rather
  # than silently skipping them. Returns a `%{"provider:kind" => value}`
  # summary for the behavior_state snapshot (R3).
  defp advance_pending_watermarks(%{pending_watermarks: watermarks}) when is_list(watermarks) do
    Enum.reduce(watermarks, %{}, fn entry, acc ->
      advance_pending_watermark(entry)

      case entry do
        %{
          account: %Maraithon.Accounts.ConnectedAccount{provider: provider},
          kind: kind,
          value: value
        }
        when is_binary(provider) and is_binary(kind) ->
          Map.put(acc, "#{provider}:#{kind}", value)

        _ ->
          acc
      end
    end)
  end

  defp advance_pending_watermarks(_state), do: %{}

  defp advance_pending_watermark(%{
         account: %Maraithon.Accounts.ConnectedAccount{} = account,
         kind: kind,
         value: value
       })
       when is_binary(kind) and is_binary(value) do
    case SourceCursors.put(account, kind, %{"value" => value}) do
      {:ok, _cursor} ->
        :ok

      {:error, reason} ->
        Logger.warning("ChiefOfStaff failed to advance source watermark",
          provider_reference: Maraithon.Redaction.fingerprint(account.provider),
          kind: kind,
          failure_code: Maraithon.Redaction.error_class(reason)
        )
    end
  end

  defp advance_pending_watermark(_other), do: :ok

  defp log_cycle_delta_summary(state) do
    sources = (state.assistant_fetch_telemetry || %{}) |> Map.get("sources", %{})
    source_count = if is_map(sources), do: min(map_size(sources), 64), else: 0

    Logger.info("ChiefOfStaff cycle source deltas",
      cycle_reference: Maraithon.Redaction.fingerprint(state.assistant_cycle_id),
      user_fingerprint: Maraithon.Redaction.fingerprint(state.user_id),
      source_count: source_count,
      item_count: min(telemetry_delta_count(state.assistant_fetch_telemetry), 1_000_000)
    )
  end

  @memo_max_chars 1500

  defp memo_llm_params(state) do
    if cycle_worth_memo?(state) do
      {:ok,
       %{
         "messages" => [%{"role" => "user", "content" => memo_prompt(state)}],
         "max_tokens" => 800,
         "temperature" => 0.2,
         # This is bounded summarization, not a reasoning task. Reserving the
         # whole budget for visible text leaves enough room for the requested
         # 1,500-character memo without inviting hidden reasoning overhead.
         "reasoning_effort" => "none"
       }}
    else
      :skip
    end
  end

  defp cycle_worth_memo?(state) do
    blank?(Map.get(state.cycle_memory || %{}, "memo")) or cycle_has_activity?(state)
  end

  defp cycle_has_activity?(state) do
    has_emits = state.pending_emits != [] or not is_nil(state.pending_emit)
    has_emits or telemetry_delta_count(state.assistant_fetch_telemetry) > 0
  end

  @delta_count_keys ~w(
    message_count event_count count item_count memo_count note_count
    open_due_soon recent_count visit_count chat_count feed_count
  )

  defp telemetry_delta_count(telemetry) when is_map(telemetry) do
    telemetry
    |> Map.get("sources", %{})
    |> Map.values()
    |> Enum.map(&source_item_count/1)
    |> Enum.sum()
  end

  defp telemetry_delta_count(_telemetry), do: 0

  defp source_item_count(summary) when is_map(summary) do
    @delta_count_keys
    |> Enum.map(&Map.get(summary, &1, 0))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp source_item_count(_summary), do: 0

  defp memo_prompt(state) do
    previous_memo = Map.get(state.cycle_memory || %{}, "memo")
    skills_ran = state.pending_emits |> Enum.map(& &1.skill_id) |> Enum.uniq()
    deltas = (state.assistant_fetch_telemetry || %{}) |> Map.get("sources", %{})

    """
    You are the Chief of Staff's cross-cycle memory. Write a short memo \
    (max #{@memo_max_chars} characters, plain text, no markdown) capturing \
    the state of the world and what you decided or held this cycle, so \
    your next wakeup can reason over the delta instead of starting from \
    scratch.

    Previous cycle memo:
    #{if blank?(previous_memo), do: "(none yet - this is the first cycle)", else: previous_memo}

    This cycle:
    - Skills that produced output: #{if skills_ran == [], do: "none", else: Enum.join(skills_ran, ", ")}
    - Per-source new-item counts since the last watermark: #{safe_json(deltas)}

    Write the memo now. Be concrete and terse: note open threads, anything \
    you decided to hold or suppress, and anything worth watching next \
    cycle. Do not repeat these instructions.
    """
  end

  defp extract_memo_text(response) do
    content =
      case response do
        %{content: content} when is_binary(content) -> content
        %{"content" => content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    case content && String.trim(content) do
      text when is_binary(text) and text != "" -> String.slice(text, 0, @memo_max_chars)
      _ -> nil
    end
  end

  defp safe_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  # R2 (SPEC 04): the scheduled wakeup path defers watermark advancement to
  # `finalize_cycle/1` (R4) and gets a capped no-cursor fallback lookback
  # (see Acquisition's `deep_lookback?`/`defer_watermark_advance`).
  defp ensure_cycle(%{cycle_skill_ids: nil} = state, context) do
    now = context[:timestamp] || DateTime.utc_now()
    reconcile_account_sources? = account_source_reconciliation?(state, context, now)

    cycle_context =
      Map.put(context, :skip_account_message_sources, not reconcile_account_sources?)

    cycle_skill_ids = selected_skill_ids(state, cycle_context)

    acquisition_context =
      cycle_context
      |> Map.put(:defer_watermark_advance, true)
      |> maybe_request_deep_scan(reconcile_account_sources?)

    {source_bundle, assistant_fetch_telemetry, proposed_watermarks} =
      acquisition_module().build(
        state.user_id || normalize_string(context[:user_id]),
        cycle_skill_ids,
        state.skill_configs,
        acquisition_context
      )

    %{
      state
      | cycle_skill_ids: cycle_skill_ids,
        assistant_cycle_id: Ecto.UUID.generate(),
        source_bundle: SourceBundle.with_index(source_bundle),
        assistant_fetch_telemetry: assistant_fetch_telemetry,
        pending_watermarks: proposed_watermarks,
        cycle_memo_generated: false,
        last_deep_scan_at: note_deep_scan(state, assistant_fetch_telemetry, now)
    }
  end

  defp ensure_cycle(state, _context), do: state

  # Recurring deep pass: scheduled cycles reacquire Gmail/Slack only when the
  # safety interval is due. Explicit callers can request the same path with
  # `:acquisition_deep_lookback`; reactive source ingress stays worker-owned.
  defp account_source_reconciliation?(state, context, now) do
    Map.get(context, :acquisition_deep_lookback) == true or
      (scheduled_trigger?(context) and deep_scan_due?(state, now))
  end

  defp deep_scan_due?(state, now) do
    interval_ms =
      Map.get(state, :deep_scan_interval_ms) || :timer.hours(@default_deep_scan_interval_hours)

    case Map.get(state, :last_deep_scan_at) do
      %DateTime{} = last -> DateTime.diff(now, last, :millisecond) >= interval_ms
      _never -> true
    end
  end

  defp maybe_request_deep_scan(acquisition_context, true) do
    Map.put(acquisition_context, :acquisition_deep_lookback, true)
  end

  defp maybe_request_deep_scan(acquisition_context, false), do: acquisition_context

  defp note_deep_scan(state, telemetry, now) do
    plan = (is_map(telemetry) && Map.get(telemetry, "plan")) || %{}

    if Map.get(plan, :deep_lookback?) == true and
         Map.get(plan, :account_message_sources) == true do
      now
    else
      Map.get(state, :last_deep_scan_at)
    end
  end

  defp selected_skill_ids(state, context) do
    state.enabled_skill_ids
    |> drop_unknown_skill_ids(:select_cycle_skills)
    |> Enum.filter(fn skill_id ->
      Skills.interested_in?(skill_id, state.skill_configs, context)
    end)
    |> maybe_drop_worker_owned_skills(context)
  end

  defp maybe_drop_worker_owned_skills(skill_ids, %{skip_account_message_sources: true}) do
    Enum.reject(skill_ids, &(&1 == "followthrough"))
  end

  defp maybe_drop_worker_owned_skills(skill_ids, _context), do: skill_ids

  # Snapshots restored from older releases can reference skill ids the current
  # registry no longer knows; Skills.get!/1 (and Skills.interested_in?/3, which
  # calls it) raises on them, which turned into a deterministic crash loop in
  # every wakeup. Drop them defensively wherever an enabled/cycle skill id list
  # is consumed. reconcile_restored_state/2 sanitizes at restore time, so this
  # only logs (once) in the unexpected case an unknown id survives.
  defp drop_unknown_skill_ids(skill_ids, where) when is_list(skill_ids) do
    {known, unknown} = Enum.split_with(skill_ids, &Skills.known?/1)

    if unknown != [] do
      Logger.warning("ChiefOfStaff dropping unknown skill ids",
        skill_ids: inspect(unknown),
        where: where
      )
    end

    known
  end

  defp drop_unknown_skill_ids(_skill_ids, _where), do: []

  defp cycle_skill_ids(%{cycle_skill_ids: skill_ids}) when is_list(skill_ids), do: skill_ids
  defp cycle_skill_ids(state), do: state.enabled_skill_ids

  defp skill_index(state, skill_id) do
    state
    |> cycle_skill_ids()
    |> Enum.find_index(&(&1 == skill_id))
    |> case do
      nil -> 0
      index -> index
    end
  end

  defp put_skill_state(state, skill_id, next_skill_state) do
    durable_skill_state =
      if is_map(next_skill_state) do
        Map.drop(next_skill_state, [
          :source_bundle,
          "source_bundle",
          :assistant_fetch_telemetry,
          "assistant_fetch_telemetry"
        ])
      else
        next_skill_state
      end

    put_in(state, [:skill_states, skill_id], durable_skill_state)
  end

  defp stash_emit(state, emit, skill_id, index) do
    # R6 (SPEC 07): pop the internal "ledger_entries" bookkeeping key out of
    # the payload before anything else touches it — the user-facing emit must
    # never carry it, and merge_emit/2's per-event-type clauses never see it.
    {emit, ledger_entries} = pop_ledger_entries(emit)
    state = merge_ledger_entries(state, ledger_entries, skill_id)

    %{
      state
      | pending_emit: merge_emit(state.pending_emit, emit),
        pending_emits:
          state.pending_emits ++
            [
              %{
                skill_id: skill_id,
                event_type: elem(emit, 0),
                rank: index + 1
              }
            ]
    }
  end

  # ==========================================================================
  # R5/R6/R8 (SPEC 07): structured cross-cycle decision ledger — capped map
  # keyed by stable item_id, sibling of the prose cycle_memory. The key is
  # deliberately "ledger_entries", never "decisions": commitment_tracker
  # already uses a `decisions` list for an unrelated todo-persistence-mode
  # concept.
  # ==========================================================================

  @decision_ledger_cap 40
  @decision_ledger_prompt_limit 20
  @ledger_decision_values ~w(held suppressed watch resolved)

  defp pop_ledger_entries({event_type, payload}) when is_map(payload) do
    {string_entries, payload} = Map.pop(payload, "ledger_entries")
    {atom_entries, payload} = Map.pop(payload, :ledger_entries)

    entries =
      [string_entries, atom_entries]
      |> Enum.flat_map(fn
        entries when is_list(entries) -> entries
        _other -> []
      end)

    {{event_type, payload}, entries}
  end

  defp pop_ledger_entries(emit), do: {emit, []}

  defp merge_ledger_entries(state, [], _skill_id), do: state

  defp merge_ledger_entries(state, entries, skill_id) when is_list(entries) do
    updated_at = DateTime.to_iso8601(DateTime.utc_now())
    cycle_id = state.assistant_cycle_id

    ledger =
      entries
      |> Enum.reduce(Map.get(state, :decision_ledger) || %{}, fn entry, acc ->
        case normalize_ledger_entry(entry) do
          {:ok, item_id, ledger_value} ->
            existing = Map.get(acc, item_id) || %{}

            Map.put(
              acc,
              item_id,
              Map.merge(ledger_value, %{
                "skill_id" => skill_id,
                "first_seen_cycle" => Map.get(existing, "first_seen_cycle") || cycle_id,
                "last_seen_cycle" => cycle_id,
                "updated_at" => updated_at
              })
            )

          :error ->
            # Malformed entries must never crash a cycle — drop and move on.
            Logger.debug("ChiefOfStaff dropped malformed ledger entry",
              failure_code: "malformed_ledger_entry"
            )

            acc
        end
      end)
      |> cap_decision_ledger()

    Map.put(state, :decision_ledger, ledger)
  end

  defp merge_ledger_entries(state, _entries, _skill_id), do: state

  defp normalize_ledger_entry(entry) when is_map(entry) do
    item_id = payload_string(entry, :item_id)
    item_type = payload_string(entry, :item_type)
    decision = payload_string(entry, :decision)
    reason = payload_string(entry, :reason)

    if item_id && item_type && reason && decision in @ledger_decision_values do
      {:ok, item_id, %{"item_type" => item_type, "decision" => decision, "reason" => reason}}
    else
      :error
    end
  end

  defp normalize_ledger_entry(_entry), do: :error

  # Over cap: drop "resolved" entries first (oldest updated_at first), then
  # fall back to the oldest updated_at overall.
  defp cap_decision_ledger(ledger) when map_size(ledger) <= @decision_ledger_cap, do: ledger

  defp cap_decision_ledger(ledger) do
    drop_ids =
      ledger
      |> Enum.sort_by(fn {_item_id, entry} ->
        {
          if(Map.get(entry, "decision") == "resolved", do: 0, else: 1),
          Map.get(entry, "updated_at") || ""
        }
      end)
      |> Enum.take(map_size(ledger) - @decision_ledger_cap)
      |> Enum.map(&elem(&1, 0))

    Map.drop(ledger, drop_ids)
  end

  # R8 (SPEC 07): prompt-injection view of the ledger — newest first, capped
  # to 20 entries (the 40-entry state cap is a storage cap, not a prompt cap).
  defp previous_decision_ledger(state) do
    (Map.get(state, :decision_ledger) || %{})
    |> Map.values()
    |> Enum.sort_by(&(Map.get(&1, "updated_at") || ""), :desc)
    |> Enum.take(@decision_ledger_prompt_limit)
  end

  defp skill_context(state, context, skill_id, index) do
    context
    |> Map.put(:source_bundle, state.source_bundle)
    |> Map.put(:assistant_cycle_id, state.assistant_cycle_id)
    |> Map.put(:assistant_fetch_telemetry, state.assistant_fetch_telemetry)
    |> Map.put(:assistant_origin_skill_id, skill_id)
    |> Map.put(:assistant_origin_skill_rank, index + 1)
    |> Map.put(:previous_cycle_memo, Map.get(state.cycle_memory || %{}, "memo"))
    |> Map.put(
      :previous_cycle_memo_updated_at,
      Map.get(state.cycle_memory || %{}, "updated_at")
    )
    |> Map.put(:previous_cycle_memo_cycle_id, Map.get(state.cycle_memory || %{}, "cycle_id"))
    |> Map.put(:previous_decision_ledger, previous_decision_ledger(state))
  end

  defp build_skill_configs(config, user_id, enabled_skill_ids) do
    skill_config_overrides =
      read_map(config, "skill_configs")

    Enum.reduce(enabled_skill_ids, %{}, fn skill_id, acc ->
      module = Skills.get!(skill_id)

      merged =
        module.default_config()
        |> Map.merge(shared_skill_config(config, user_id))
        |> Map.merge(read_map(skill_config_overrides, skill_id))
        |> maybe_put("assistant_behavior", "ai_chief_of_staff")

      Map.put(acc, skill_id, merged)
    end)
  end

  defp shared_skill_config(config, user_id) do
    %{}
    |> maybe_put("user_id", user_id)
    |> maybe_put("source_policy", read_string(config, "source_policy", nil))
    |> maybe_put("source_scope", read_map(config, "source_scope"))
    |> maybe_put("timezone", read_string(config, "timezone", nil))
    |> maybe_put("timezone_name", read_string(config, "timezone_name", nil))
    |> maybe_put_integer("timezone_offset_hours", read_integer(config, "timezone_offset_hours"))
    |> maybe_put_integer(
      "morning_brief_hour_local",
      read_integer(config, "morning_brief_hour_local")
    )
    |> maybe_put_integer(
      "morning_brief_minute_local",
      read_integer(config, "morning_brief_minute_local")
    )
    |> maybe_put_integer(
      "end_of_day_brief_hour_local",
      read_integer(config, "end_of_day_brief_hour_local")
    )
    |> maybe_put_integer(
      "weekly_review_day_local",
      read_integer(config, "weekly_review_day_local")
    )
    |> maybe_put_integer(
      "weekly_review_hour_local",
      read_integer(config, "weekly_review_hour_local")
    )
    |> maybe_put_integer("brief_max_items", read_integer(config, "brief_max_items"))
  end

  defp merge_emit(nil, emit), do: emit
  defp merge_emit(emit, nil), do: emit

  defp merge_emit({:insights_recorded, left}, {:insights_recorded, right}) do
    {:insights_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       categories: Enum.uniq(payload_list(left, :categories) ++ payload_list(right, :categories))
     }}
  end

  defp merge_emit({:insight_error, left}, {:insight_error, right}) do
    {:insight_error,
     %{
       reason:
         [payload_string(left, :reason), payload_string(right, :reason)]
         |> Enum.reject(&blank?/1)
         |> Enum.join(" | "),
       attempted_count:
         payload_int(left, :attempted_count, 0) + payload_int(right, :attempted_count, 0)
     }}
  end

  defp merge_emit({:briefs_recorded, left}, {:briefs_recorded, right}) do
    {:briefs_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       cadences: Enum.uniq(payload_list(left, :cadences) ++ payload_list(right, :cadences))
     }}
  end

  defp merge_emit({:brief_error, left}, {:brief_error, right}) do
    {:brief_error,
     %{
       reason:
         [payload_string(left, :reason), payload_string(right, :reason)]
         |> Enum.reject(&blank?/1)
         |> Enum.join(" | "),
       attempted_count:
         payload_int(left, :attempted_count, 0) + payload_int(right, :attempted_count, 0)
     }}
  end

  defp merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs}) do
    base = stringify_keys(recorded)
    briefs_key = shaped_key(recorded, :briefs)
    count_key = shaped_key(briefs, :count)
    cadences_key = shaped_key(briefs, :cadences)

    {:insights_recorded,
     Map.put(
       base,
       briefs_key,
       payload_list(recorded, :briefs) ++
         [
           %{
             count_key => payload_int(briefs, :count, 0),
             cadences_key => payload_list(briefs, :cadences)
           }
         ]
     )}
  end

  defp merge_emit({:briefs_recorded, briefs}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs})

  defp merge_emit({:insights_recorded, recorded}, {:insight_error, error}) do
    {:insights_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       shaped_key(recorded, :errors),
       payload_list(recorded, :errors) ++
         [
           %{
             shaped_key(error, :reason) => payload_string(error, :reason),
             shaped_key(error, :attempted_count) => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:insight_error, error}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:insight_error, error})

  defp merge_emit({:briefs_recorded, recorded}, {:brief_error, error}) do
    {:briefs_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       shaped_key(recorded, :errors),
       payload_list(recorded, :errors) ++
         [
           %{
             shaped_key(error, :reason) => payload_string(error, :reason),
             shaped_key(error, :attempted_count) => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:brief_error, error}, {:briefs_recorded, recorded}),
    do: merge_emit({:briefs_recorded, recorded}, {:brief_error, error})

  defp merge_emit(left, _right), do: left

  defp merge_wakeup(:none, other), do: other
  defp merge_wakeup(other, :none), do: other

  defp merge_wakeup({:relative, left_ms}, {:relative, right_ms}),
    do: {:relative, min(left_ms, right_ms)}

  defp merge_wakeup({:absolute, %DateTime{} = left}, {:absolute, %DateTime{} = right}) do
    if DateTime.compare(left, right) in [:lt, :eq],
      do: {:absolute, left},
      else: {:absolute, right}
  end

  defp merge_wakeup({:absolute, %DateTime{} = absolute}, {:relative, ms}) do
    relative_absolute = DateTime.add(DateTime.utc_now(), ms, :millisecond)

    if DateTime.compare(absolute, relative_absolute) == :gt,
      do: {:relative, ms},
      else: {:absolute, absolute}
  end

  defp merge_wakeup({:relative, ms}, {:absolute, %DateTime{} = absolute}),
    do: merge_wakeup({:absolute, absolute}, {:relative, ms})

  defp merge_wakeup(_left, right), do: right

  defp clamp_relative_scan_floor({:relative, ms}) when is_integer(ms) do
    {:relative, max(ms, @min_wakeup_interval_ms)}
  end

  # An absolute wakeup in the past (e.g. a DST-boundary miscomputation in a
  # skill's daily occurrence math) would fire immediately as overdue on every
  # cycle — a hot loop that pays a full acquisition each iteration. Floor it.
  defp clamp_relative_scan_floor({:absolute, %DateTime{} = at}) do
    floor_at = DateTime.add(DateTime.utc_now(), @min_wakeup_interval_ms, :millisecond)

    if DateTime.compare(at, floor_at) == :lt do
      {:absolute, floor_at}
    else
      {:absolute, at}
    end
  end

  defp clamp_relative_scan_floor(other), do: other

  defp acquisition_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:acquisition_module, Acquisition)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_integer(map, _key, nil), do: map
  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)

  defp read_map(payload, key) when is_map(payload) do
    case map_value(payload, key) do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp read_string(payload, key, default) when is_map(payload) do
    case map_value(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        value
        |> Atom.to_string()
        |> String.trim()
        |> case do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp read_integer(payload, key) when is_map(payload) do
    case map_value(payload, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp map_value(payload, key) when is_map(payload) and is_binary(key) do
    Map.get(payload, key) || Map.get(payload, existing_atom(key))
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_int(payload, key, default) do
    case payload_value(payload, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp payload_string(payload, key) do
    case payload_value(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp payload_list(payload, key) do
    case payload_value(payload, key) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp shaped_key(payload, key) when is_map(payload) do
    cond do
      Map.has_key?(payload, key) -> key
      Map.has_key?(payload, Atom.to_string(key)) -> Atom.to_string(key)
      true -> Atom.to_string(key)
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp stringify_keys(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      Map.put(acc, if(is_atom(key), do: Atom.to_string(key), else: key), value)
    end)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
