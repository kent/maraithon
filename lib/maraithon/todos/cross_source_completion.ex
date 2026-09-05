defmodule Maraithon.Todos.CrossSourceCompletion do
  @moduledoc """
  LLM-backed completion pass that closes open todos when later source material
  shows the work was already handled.

  The deterministic `CompletionSweep` only sees hard same-source evidence (a
  Gmail reply closes a Gmail todo). This pass gives the model current material
  from every connected Chief-of-Staff source, plus persisted observations, so it
  can reason across Gmail, Slack, Calendar, local messages, notes, reminders,
  files, browser history, and other companion sources.

  The bar for closing is strict and the LLM must quote source evidence;
  ambiguous matches stay open, because wrongly closing real work is worse than
  showing a finished item.
  """

  import Ecto.Query

  alias Maraithon.AssistantHarness.PromptStability
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle}
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm.Observation
  alias Maraithon.LLM
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.PushBroker
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias Maraithon.Todos.UserBatch

  require Logger

  @open_statuses ~w(open snoozed)
  # Per-cycle LLM prompt-size cap (SPEC 05 R3). This bounds "how many todos
  # we check this cycle", not "which 40 we permanently limit to":
  # evidence-linked (delta) candidates fill the budget first, and whatever
  # remains rotates through the backstop by `last_completion_checked_at`.
  @max_todos 40
  # Safety bound on the open-todo scan for one pathological user; not the
  # real per-cycle cap (see @max_todos above).
  @max_open_todo_scan 500
  @max_observations 120
  @max_outgoing_messages 80
  @max_live_evidence_per_source 120
  # Live acquisition intentionally sees a broad, per-source-bounded window so
  # candidate selection can notice fresh links. The LLM prompt is a separate,
  # much smaller budget: keep one linked item per checked todo first, then
  # round-robin across channels so a noisy source cannot crowd out the rest.
  @max_prompt_evidence_items 96
  @max_prompt_linked_evidence_items 56
  @max_prompt_evidence_per_channel 8
  @max_prompt_bytes 96_000
  @max_prompt_health_text 12_000
  @max_prompt_health_sources 32
  @max_prompt_health_providers 8
  @max_prompt_health_counts 16
  @evidence_window_days 7
  @min_todo_age_minutes 30
  @min_confidence 0.8
  @max_excerpt 280
  @default_max_tokens 2_048
  @default_timeout_ms 60_000
  @source_acquisition_timeout_ms 90_000
  @source_skill_id "commitment_tracker"
  @source_skill_config %{
    "email_scan_limit" => 40,
    "event_scan_limit" => 40,
    "gmail_fetch_timeout_ms" => 18_000,
    "gmail_body_fetch_limit" => 24,
    "gmail_body_fetch_timeout_ms" => 750,
    "calendar_fetch_timeout_ms" => 12_000,
    "slack_fetch_timeout_ms" => 45_000,
    "slack_channel_fetch_timeout_ms" => 4_000,
    "slack_search_timeout_ms" => 5_000,
    "slack_self_authored_query_limit" => 3,
    "slack_channel_scan_limit" => 4,
    "slack_message_scan_limit" => 60,
    "companion_fetch_timeout_ms" => 4_000,
    "local_message_limit" => 180,
    "local_chat_limit" => 80,
    "local_voice_memo_limit" => 60,
    "local_note_limit" => 80,
    "local_reminder_limit" => 80,
    "local_file_limit" => 80,
    "local_browser_visit_limit" => 160,
    "lookback_hours" => @evidence_window_days * 24 * 2
  }

  @doc """
  Runs the cross-source pass for every user with open todos.
  """
  def run_for_all_users(opts \\ []) do
    user_ids = UserBatch.open_todo_user_ids(opts)

    empty = %{users: length(user_ids), checked: 0, completed: 0, skipped: 0, errors: 0}

    Enum.reduce(user_ids, empty, fn user_id, acc ->
      case run_for_user_safely(user_id, opts) do
        %{checked: checked, completed: completed} ->
          %{acc | checked: acc.checked + checked, completed: acc.completed + completed}

        {:skip, _reason} ->
          %{acc | skipped: acc.skipped + 1}

        {:error, _reason} ->
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # One user's crash must never abort the pass for every user after them
  # (mirrors StalenessTriageSweep.run_for_user_safely/2).
  defp run_for_user_safely(user_id, opts) do
    run_for_user(user_id, opts)
  rescue
    error ->
      failure_code = Maraithon.Redaction.error_class(error)

      Logger.warning("Cross-source completion crashed for user",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: failure_code
      )

      {:error, {:exception, failure_code}}
  catch
    kind, reason ->
      failure_code = Maraithon.Redaction.error_class(reason)

      Logger.warning("Cross-source completion crashed for user",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: to_string(kind)
      )

      {:error, {kind, failure_code}}
  end

  @doc """
  Runs the cross-source pass for one user.

  Returns `%{checked: n, completed: n}`, `{:skip, reason}` when there is
  nothing to evaluate, or `{:error, reason}` when the LLM call fails.
  Tests may inject `:llm_complete` as a prompt-level one-arity function or
  `:llm_request` as a request-map one-arity function.
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    # Cheap existence gate first (SPEC 05 R2): evidence acquisition — which
    # fires live Gmail/Slack/etc. calls — must never run for a user with
    # nothing to check, preserving the original zero-open-todos short-circuit.
    open_todos = open_todo_pool(user_id, now, opts)

    cond do
      open_todos == [] ->
        {:skip, :no_open_todos}

      true ->
        # Evidence before candidate selection (SPEC 05 R2): live acquisition
        # is independent of which todos are checked (`build_live_source_bundle/4`
        # takes `_todos` and never reads it), so collecting first lets R3
        # partition candidates into evidence-linked vs backstop.
        evidence = collect_evidence(user_id, open_todos, now, opts)

        with :ok <- validate_exact_source_evidence(evidence, opts) do
          if actionable_evidence?(evidence) do
            todos = select_candidates(user_id, open_todos, evidence)

            # Stamp only on success: a failed evaluation checked nothing, so
            # advancing the backstop rotation would skip these todos unchecked.
            case evaluate_fitting(user_id, todos, evidence, now, opts) do
              {:ok, result, evaluated_todos} ->
                stamp_completion_checked(user_id, evaluated_todos, now)

                result
                |> Map.put_new(:model_calls, 1)
                |> Map.put(:decision_refs, Enum.map(evaluated_todos, & &1.id))

              {:error, _reason} = error ->
                error
            end
          else
            if Keyword.get(opts, :exhaustive_completion, false) do
              stamp_completion_checked(user_id, open_todos, now)

              %{
                checked: length(open_todos),
                completed: 0,
                model_calls: 0,
                outcome: "no_completion_evidence",
                decision_refs: Enum.map(open_todos, & &1.id)
              }
            else
              {:skip, :no_evidence}
            end
          end
        end
    end
  end

  defp actionable_evidence?(evidence) when is_list(evidence) do
    Enum.any?(evidence, fn item ->
      read_string(item, "channel", nil) != "source_health" or source_health_actionable?(item)
    end)
  end

  defp actionable_evidence?(_evidence), do: false

  defp validate_exact_source_evidence(evidence, opts) do
    if Keyword.get(opts, :exact_source_delta, false) do
      expected =
        opts
        |> Keyword.get(:source_item_refs, [])
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.sort()

      actual =
        evidence
        |> Enum.map(&read_string(&1, "source_ref", nil))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      if expected != [] and actual == expected do
        :ok
      else
        {:error, :cross_source_completion_source_coverage_incomplete}
      end
    else
      :ok
    end
  end

  defp source_health_actionable?(item) when is_map(item) do
    with text when is_binary(text) <- read_string(item, "text", nil),
         {:ok, health} when is_map(health) <- Jason.decode(text) do
      health
      |> nested_statuses()
      |> Enum.any?(&(&1 in ["partial", "unavailable", "error"]))
    else
      _other -> false
    end
  end

  defp source_health_actionable?(_item), do: false

  defp nested_statuses(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"status", status} when is_binary(status) -> [status]
      {_key, nested} -> nested_statuses(nested)
    end)
  end

  defp nested_statuses(value) when is_list(value), do: Enum.flat_map(value, &nested_statuses/1)
  defp nested_statuses(_value), do: []

  # ── Candidates ────────────────────────────────────────────────────────────

  defp open_todo_pool(user_id, now, run_opts) do
    case Keyword.get(run_opts, :todo_ids) do
      ids when is_list(ids) -> exact_todo_pool(user_id, ids, run_opts)
      _other -> rotating_todo_pool(user_id, now, run_opts)
    end
  end

  defp exact_todo_pool(_user_id, [], _run_opts), do: []

  defp exact_todo_pool(user_id, todo_ids, run_opts) do
    Todo
    |> where(
      [todo],
      todo.user_id == ^user_id and todo.id in ^todo_ids and todo.status in ^@open_statuses
    )
    |> maybe_scope_todo_query(run_opts)
    |> order_by([todo], asc: todo.id)
    |> Repo.all()
  end

  defp rotating_todo_pool(user_id, now, run_opts) do
    age_cutoff = DateTime.add(now, -@min_todo_age_minutes * 60, :second)

    opts =
      [
        statuses: @open_statuses,
        limit: @max_open_todo_scan,
        sort_by: "updated",
        sort_dir: "asc",
        # Completion checking must see everything open — an unsurfaceable todo
        # still deserves to be closed when the evidence proves it done.
        exclude_unsurfaceable?: false
      ]
      |> maybe_put_source_account_filter(run_opts)

    user_id
    |> Todos.list_for_user(opts)
    |> Enum.filter(fn todo ->
      DateTime.compare(todo.inserted_at, age_cutoff) == :lt
    end)
  end

  defp maybe_scope_todo_query(query, run_opts) do
    case Keyword.get(run_opts, :source_account_id) do
      account_id when is_integer(account_id) ->
        where(query, [todo], todo.source_account_id == ^account_id)

      _other ->
        if Keyword.get(run_opts, :source_account_unassigned?, false) do
          where(query, [todo], is_nil(todo.source_account_id))
        else
          query
        end
    end
  end

  defp maybe_put_source_account_filter(opts, run_opts) when is_list(run_opts) do
    case Keyword.get(run_opts, :source_account_id) do
      account_id when is_integer(account_id) ->
        Keyword.put(opts, :source_account_id, account_id)

      _other ->
        if Keyword.get(run_opts, :source_account_unassigned?, false) do
          Keyword.put(opts, :source_account_unassigned?, true)
        else
          opts
        end
    end
  end

  # Delta-driven candidate selection with a bounded backstop (SPEC 05 R3):
  # anything with fresh related activity ("active") is checked every cycle
  # regardless of its position in any ordering; the remaining budget rotates
  # deterministically through the rest by `last_completion_checked_at`
  # ascending with never-checked items first.
  defp select_candidates(user_id, todos, evidence) do
    identifiers = evidence_identifiers(evidence)

    {active, backstop} = Enum.split_with(todos, &evidence_linked?(&1, identifiers))

    active = Enum.sort_by(active, &completion_rotation_sort_key/1)

    active =
      if length(active) > @max_todos do
        # Linked candidates still share the same finite prompt budget. Rotate
        # them by the durable completion-check stamp instead of repeatedly
        # taking the same updated-at prefix forever.
        Logger.info("Cross-source completion truncated active candidates to the per-cycle cap",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          active: length(active),
          cap: @max_todos
        )

        Enum.take(active, @max_todos)
      else
        active
      end

    backstop_fill =
      backstop
      |> Enum.sort_by(&completion_rotation_sort_key/1)
      |> Enum.take(max(@max_todos - length(active), 0))

    active ++ backstop_fill
  end

  defp completion_rotation_sort_key(todo) do
    case todo.last_completion_checked_at do
      %DateTime{} = checked_at ->
        {1, DateTime.to_unix(checked_at, :microsecond), todo.id}

      _never_checked ->
        {0, 0, todo.id}
    end
  end

  defp evidence_identifiers(evidence) do
    evidence
    |> Enum.reject(fn item -> read_string(item, "channel", nil) == "source_health" end)
    |> Enum.reduce(%{item_ids: MapSet.new(), label_items: []}, fn item, acc ->
      ids =
        [
          read_string(item, "thread_id", nil),
          read_string(item, "source_item_id", nil),
          read_string(item, "target_source_item_id", nil)
        ]
        |> Enum.reject(&is_nil/1)

      acc = %{acc | item_ids: Enum.into(ids, acc.item_ids)}

      channel = read_string(item, "channel", nil)
      account = read_string(item, "account", nil)
      subject = read_string(item, "subject", nil)

      if channel && account && subject do
        %{acc | label_items: [{channel, account, String.downcase(subject)} | acc.label_items]}
      else
        acc
      end
    end)
  end

  defp evidence_linked?(todo, %{item_ids: item_ids, label_items: label_items}) do
    (is_binary(todo.source_item_id) and todo.source_item_id != "" and
       MapSet.member?(item_ids, todo.source_item_id)) or
      counterparty_label_linked?(todo, label_items)
  end

  defp counterparty_label_linked?(
         %Todo{source: source, source_account_label: account, counterparty_label: label},
         label_items
       )
       when is_binary(source) and is_binary(account) and is_binary(label) do
    case String.trim(label) do
      "" ->
        false

      trimmed ->
        needle = String.downcase(trimmed)

        Enum.any?(label_items, fn {channel, evidence_account, subject} ->
          channel == source and evidence_account == account and
            String.contains?(subject, needle)
        end)
    end
  end

  defp counterparty_label_linked?(_todo, _label_items), do: false

  # Bulk-stamp every candidate considered this cycle (SPEC 05 R4) — including
  # ones that did not close — so the backstop rotation advances even when
  # nothing resolved. `update_all` with an explicit `set:` list (mirroring
  # `Todos.record_nudge_sent/3`), namespaced by user and tolerant of ids that
  # no longer exist (zero rows affected is fine). `updated_at` is deliberately
  # not touched: a "we looked at it" stamp across 40 todos every cycle must
  # not churn updated-ordering or freshness signals.
  defp stamp_completion_checked(_user_id, [], _now), do: :ok

  defp stamp_completion_checked(user_id, todos, now) do
    ids = Enum.map(todos, & &1.id)
    stamped_at = DateTime.truncate(now, :second)

    Todo
    |> where([todo], todo.id in ^ids and todo.user_id == ^user_id)
    |> Repo.update_all(set: [last_completion_checked_at: stamped_at])

    :ok
  end

  # ── Evidence ──────────────────────────────────────────────────────────────

  defp collect_evidence(user_id, todos, now, opts) do
    cutoff = DateTime.add(now, -@evidence_window_days * 24 * 3600, :second)

    persisted_evidence =
      if Keyword.has_key?(opts, :source_account_id) do
        []
      else
        observation_evidence(user_id, cutoff) ++ outgoing_message_evidence(user_id, cutoff)
      end

    persisted_evidence
    |> Enum.concat(live_source_evidence(user_id, todos, now, opts))
    |> dedupe_evidence()
  end

  defp observation_evidence(user_id, cutoff) do
    Repo.all(
      from(o in Observation,
        where: o.user_id == ^user_id and o.occurred_at >= ^cutoff,
        where: not is_nil(o.excerpt) and o.excerpt != "",
        order_by: [desc: o.occurred_at],
        limit: @max_observations,
        select: %{
          source: o.source,
          direction: o.direction,
          subject: o.subject,
          excerpt: o.excerpt,
          occurred_at: o.occurred_at
        }
      )
    )
    |> Enum.map(fn obs ->
      %{
        "channel" => obs.source,
        "kind" => observation_kind(obs),
        "subject" => obs.subject,
        "text" => truncate(obs.excerpt, @max_excerpt),
        "at" => DateTime.to_iso8601(obs.occurred_at)
      }
    end)
  rescue
    _exception -> []
  end

  defp observation_kind(%{source: "gmail", direction: "outbound"}), do: "email sent by the user"
  defp observation_kind(%{source: "gmail"}), do: "email received"
  defp observation_kind(%{source: "slack"}), do: "slack message"
  defp observation_kind(%{source: source}), do: to_string(source)

  defp outgoing_message_evidence(user_id, cutoff) do
    Repo.all(
      from(m in LocalMessage,
        where: m.user_id == ^user_id and m.is_from_me == true,
        where: m.sent_at >= ^cutoff,
        where: not is_nil(m.text) and m.text != "",
        order_by: [desc: m.sent_at],
        limit: @max_outgoing_messages,
        select: %{
          chat: m.chat_display_name,
          handle: m.chat_key,
          text: m.text,
          sent_at: m.sent_at
        }
      )
    )
    |> Enum.map(fn message ->
      %{
        "channel" => "imessage",
        "kind" => "message sent by the user",
        "subject" => message.chat || message.handle,
        "text" => truncate(message.text, @max_excerpt),
        "at" => DateTime.to_iso8601(message.sent_at)
      }
    end)
  rescue
    _exception -> []
  end

  defp live_source_evidence(user_id, todos, now, opts) do
    cond do
      Keyword.has_key?(opts, :source_bundle) ->
        opts
        |> Keyword.get(:source_bundle)
        |> source_bundle_evidence(now, Keyword.get(opts, :exact_source_delta, false))

      Keyword.get(opts, :live_sources, true) ->
        fetch_live_source_bundle(user_id, todos, now, opts)

      true ->
        []
    end
  rescue
    exception ->
      failure_code = Maraithon.Redaction.error_class(exception)

      Logger.warning("Cross-source completion could not collect live source evidence",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: failure_code
      )

      live_source_unavailable_evidence(now, failure_code)
  catch
    kind, reason ->
      failure_code = Maraithon.Redaction.error_class(reason)

      Logger.warning("Cross-source completion could not collect live source evidence",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: to_string(kind)
      )

      live_source_unavailable_evidence(now, failure_code)
  end

  defp fetch_live_source_bundle(user_id, todos, now, opts) do
    timeout_ms =
      opts
      |> Keyword.get(:source_timeout_ms)
      |> positive_integer(@source_acquisition_timeout_ms)
      |> min(@source_acquisition_timeout_ms)

    fetcher = Keyword.get(opts, :source_bundle_fetcher) || (&build_live_source_bundle/4)

    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        try do
          evidence =
            user_id
            |> fetcher.(todos, now, opts)
            |> source_bundle_evidence(now, false)

          {:ok, evidence}
        rescue
          exception -> {:error, Maraithon.Redaction.error_class(exception)}
        catch
          kind, _reason -> {:error, to_string(kind)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, bundle}} ->
        bundle

      {:ok, {:error, _failure_code}} ->
        raise "live source acquisition failed"

      {:exit, _reason} ->
        raise "live source acquisition failed"

      nil ->
        raise "live source acquisition timed out"
    end
  end

  defp build_live_source_bundle(user_id, _todos, now, opts) do
    skill_config =
      @source_skill_config
      |> Map.merge(Keyword.get(opts, :source_skill_config, %{}))

    context =
      %{
        user_id: user_id,
        timestamp: now,
        trigger: %{type: :wakeup, job_type: "todo_completion_sweep"},
        recent_events: [],
        event: nil,
        # An explicit evidence sweep, not a scheduled scan — keep the deep
        # lookback window (SPEC 04 R2 caps scheduled scans to 48h).
        acquisition_deep_lookback: true
      }
      |> maybe_put_context_source_scope(Keyword.get(opts, :source_scope))

    {bundle, _telemetry, _proposed_watermarks} =
      Acquisition.build(
        user_id,
        [@source_skill_id],
        %{@source_skill_id => skill_config},
        context
      )

    bundle
  end

  defp maybe_put_context_source_scope(context, source_scope) when is_map(source_scope) do
    Map.put(context, :source_scope, source_scope)
  end

  defp maybe_put_context_source_scope(context, _source_scope), do: context

  defp live_source_unavailable_evidence(now, reason) do
    [
      %{
        "channel" => "source_health",
        "kind" => "connected source coverage for this sweep",
        "subject" => "all connected Chief-of-Staff sources",
        "text" =>
          Jason.encode!(%{
            "live_sources" => %{
              "status" => "unavailable",
              "reason" => truncate(reason, @max_excerpt)
            }
          }),
        "at" => DateTime.to_iso8601(now)
      }
    ]
  end

  defp source_bundle_evidence(bundle, now, exact?) when is_map(bundle) and is_boolean(exact?) do
    [
      source_health_evidence(bundle, now),
      bundle
      |> SourceBundle.gmail_messages()
      |> evidence_bucket(&gmail_source_evidence(&1, exact?), exact?),
      bundle |> SourceBundle.calendar_events() |> evidence_bucket(&calendar_source_evidence/1),
      bundle
      |> SourceBundle.calendar_local_events()
      |> evidence_bucket(&local_calendar_source_evidence/1),
      bundle
      |> SourceBundle.slack_messages()
      |> evidence_bucket(&slack_source_evidence(&1, exact?), exact?),
      bundle
      |> SourceBundle.slack_mentions()
      |> evidence_bucket(&slack_mention_evidence(&1, exact?), exact?),
      bundle |> SourceBundle.imessage_messages() |> evidence_bucket(&imessage_source_evidence/1),
      bundle |> SourceBundle.notes() |> evidence_bucket(&note_source_evidence/1),
      bundle |> SourceBundle.reminders() |> evidence_bucket(&reminder_source_evidence/1),
      bundle |> SourceBundle.files() |> evidence_bucket(&file_source_evidence/1),
      bundle
      |> SourceBundle.browser_visits()
      |> evidence_bucket(&browser_history_source_evidence/1),
      bundle |> SourceBundle.voice_memos() |> evidence_bucket(&voice_memo_source_evidence/1)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp source_bundle_evidence(_bundle, _now, _exact?), do: []

  defp source_health_evidence(bundle, now) do
    freshness = SourceBundle.freshness(bundle)

    %{
      "channel" => "source_health",
      "kind" => "connected source coverage for this sweep",
      "subject" => "all connected Chief-of-Staff sources",
      "text" => compact_source_health_json(freshness),
      "at" => DateTime.to_iso8601(now)
    }
  end

  defp compact_source_health_json(freshness) when is_map(freshness) do
    entries =
      freshness
      |> Enum.take(@max_prompt_health_sources * 4)
      |> Enum.sort_by(fn {source, _details} -> bounded_prompt_string(to_string(source), 64) end)
      |> Enum.take(@max_prompt_health_sources)

    detailed =
      Map.new(entries, fn {source, details} ->
        source = bounded_prompt_string(to_string(source), 64)

        value =
          %{
            "source" => bounded_prompt_string(read_string(details, "source", source), 64),
            "status" => bounded_prompt_string(read_string(details, "status", "unknown"), 64),
            "fetched_at" => bounded_prompt_string(read_string(details, "fetched_at", nil), 64),
            "reason" => bounded_prompt_string(read_string(details, "reason", nil), 400),
            "providers" => compact_health_providers(read_value(details, "providers")),
            "counts" => compact_health_counts(read_value(details, "counts"))
          }
          |> compact_map()

        {source, value}
      end)

    case Jason.encode!(detailed) do
      encoded when byte_size(encoded) <= @max_prompt_health_text ->
        encoded

      _too_large ->
        entries
        |> Map.new(fn {source, details} ->
          {bounded_prompt_string(to_string(source), 64),
           %{"status" => bounded_prompt_string(read_string(details, "status", "unknown"), 64)}}
        end)
        |> Jason.encode!()
        |> case do
          encoded when byte_size(encoded) <= @max_prompt_health_text -> encoded
          _still_too_large -> Jason.encode!(%{"source_health" => "summary_too_large"})
        end
    end
  end

  defp compact_source_health_json(_freshness), do: "{}"

  defp compact_health_providers(providers) when is_list(providers) do
    providers
    |> Enum.take(@max_prompt_health_providers)
    |> Enum.map(&health_provider_label/1)
    |> Enum.reject(&is_nil/1)
  end

  defp compact_health_providers(_providers), do: []

  defp health_provider_label(provider) when is_binary(provider) do
    bounded_prompt_string(provider, 160)
  end

  defp health_provider_label(provider) when is_map(provider) do
    ["provider", "account", "email", "label", "name", "id"]
    |> Enum.find_value(fn key -> read_string(provider, key, nil) end)
    |> bounded_prompt_string(160)
  end

  defp health_provider_label(_provider), do: nil

  defp compact_health_counts(counts) when is_map(counts) do
    counts
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(@max_prompt_health_counts)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case compact_health_count(value) do
        nil -> acc
        compact -> Map.put(acc, bounded_prompt_string(to_string(key), 80), compact)
      end
    end)
  end

  defp compact_health_counts(_counts), do: %{}

  defp compact_health_count(value) when is_number(value) or is_boolean(value), do: value
  defp compact_health_count(value) when is_binary(value), do: bounded_prompt_string(value, 160)
  defp compact_health_count(_value), do: nil

  defp evidence_bucket(items, mapper) when is_list(items) and is_function(mapper, 1) do
    items
    |> Enum.take(@max_live_evidence_per_source * 4)
    |> Enum.map(mapper)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&evidence_sort_key/1, :desc)
    |> Enum.take(@max_live_evidence_per_source)
  end

  defp evidence_bucket(_items, _mapper), do: []

  defp evidence_bucket(items, mapper, true) when is_list(items) and is_function(mapper, 1) do
    items
    |> Enum.map(mapper)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&evidence_sort_key/1, :desc)
  end

  defp evidence_bucket(items, mapper, false), do: evidence_bucket(items, mapper)

  defp gmail_source_evidence(message, exact?) when is_map(message) and is_boolean(exact?) do
    current_text =
      source_evidence_text(
        message,
        ~w(body_text text_body body snippet html_body),
        exact?
      )

    thread_context =
      message
      |> read_list("thread_context")
      |> Enum.map(fn reply ->
        sender = read_string(reply, "from", "Someone")

        text =
          source_evidence_text(
            reply,
            ~w(body_text text_body body snippet html_body),
            exact?
          )

        if text, do: "#{sender}: #{text}"
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    evidence_item(
      %{
        "channel" => "gmail",
        "kind" => gmail_kind(message),
        "subject" => read_string(message, "subject", nil),
        "text" =>
          [current_text, thread_context]
          |> Enum.reject(&blank?/1)
          |> Enum.join("\nEarlier Gmail thread context:\n"),
        "at" => evidence_time(message, ["internal_date", "date"]),
        "source_item_id" => read_string(message, "message_id", read_string(message, "id", nil)),
        "source_ref" => gmail_source_ref(message),
        "thread_id" => read_string(message, "thread_id", nil),
        "account" =>
          read_string(message, "account", read_string(message, "google_account_email", nil))
      },
      exact?
    )
  end

  defp gmail_source_evidence(_message, _exact?), do: nil

  defp gmail_source_ref(message) do
    provider = read_string(message, "google_provider", "unknown")
    id = read_string(message, "message_id", read_string(message, "id", nil))
    if id, do: "gmail:" <> provider <> ":" <> id
  end

  defp gmail_kind(message) do
    labels = read_list(message, "labels")

    cond do
      "SENT" in labels -> "email sent by the user"
      "INBOX" in labels -> "email received"
      true -> "gmail message"
    end
  end

  defp calendar_source_evidence(event) when is_map(event) do
    calendar_evidence_item("google_calendar", "calendar event", event)
  end

  defp calendar_source_evidence(_event), do: nil

  defp local_calendar_source_evidence(event) when is_map(event) do
    calendar_evidence_item("local_calendar", "local calendar event", event)
  end

  defp local_calendar_source_evidence(_event), do: nil

  defp calendar_evidence_item(channel, kind, event) do
    summary = read_string(event, "summary", read_string(event, "title", nil))

    text =
      [
        read_string(event, "description", nil),
        read_string(event, "notes", nil),
        read_string(event, "location", nil),
        read_string(event, "html_link", nil),
        event |> read_list("attendees") |> attendee_summary()
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    evidence_item(%{
      "channel" => channel,
      "kind" => kind,
      "subject" => summary,
      "text" => text,
      "at" => evidence_time(event, ["start", "start_at", "created", "updated"]),
      "source_item_id" =>
        read_string(event, "event_id", read_string(event, "id", read_string(event, "guid", nil))),
      "account" => read_string(event, "account", read_string(event, "google_account_email", nil))
    })
  end

  defp slack_source_evidence(message, exact?) when is_map(message) and is_boolean(exact?) do
    current_text = source_evidence_text(message, ~w(text_resolved text), exact?)
    channel_id = read_string(message, "channel_id", nil)
    message_ts = read_string(message, "ts", nil)

    target_ts =
      read_string(
        message,
        "target_ts",
        read_string(message, "thread_ts", message_ts)
      )

    thread_context =
      message
      |> read_list("thread_context")
      |> Enum.map(fn reply ->
        sender =
          read_string(reply, "user_display_name", read_string(reply, "user", "Someone"))

        text = source_evidence_text(reply, ~w(text_resolved text), exact?)
        if text, do: "#{sender}: #{text}"
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    evidence_item(
      %{
        "channel" => "slack",
        "kind" => "slack message",
        "subject" =>
          read_string(message, "channel_name", read_string(message, "channel_id", nil)),
        "text" =>
          [current_text, thread_context]
          |> Enum.reject(&blank?/1)
          |> Enum.join("\nThread context:\n"),
        "at" => evidence_time(message, ["date", "ts"]),
        "source_item_id" => slack_source_item_id(channel_id, message_ts),
        "target_source_item_id" => slack_source_item_id(channel_id, target_ts),
        "source_ref" => slack_source_ref(message),
        "thread_id" => read_string(message, "thread_ts", nil),
        "permalink" => read_string(message, "permalink", nil)
      },
      exact?
    )
  end

  defp slack_source_evidence(_message, _exact?), do: nil

  defp slack_source_ref(message) do
    team_id = read_string(message, "team_id", nil)
    channel_id = read_string(message, "channel_id", nil)
    ts = read_string(message, "ts", nil)

    if team_id && channel_id && ts,
      do: "slack:" <> Enum.join([team_id, channel_id, ts], ":")
  end

  defp slack_mention_evidence(message, exact?) when is_map(message) and is_boolean(exact?) do
    message
    |> slack_source_evidence(exact?)
    |> case do
      nil -> nil
      item -> Map.put(item, "kind", "slack mention")
    end
  end

  defp slack_mention_evidence(_message, _exact?), do: nil

  defp imessage_source_evidence(message) when is_map(message) do
    evidence_item(%{
      "channel" => "imessage",
      "kind" =>
        if(truthy?(read_value(message, "is_from_me")),
          do: "message sent by the user",
          else: "message received"
        ),
      "subject" =>
        read_string(message, "chat_display_name", read_string(message, "chat_key", nil)),
      "text" => read_string(message, "text", nil),
      "at" => evidence_time(message, ["sent_at", "date"]),
      "source_item_id" => read_string(message, "guid", read_string(message, "message_id", nil))
    })
  end

  defp imessage_source_evidence(_message), do: nil

  defp note_source_evidence(note) when is_map(note) do
    evidence_item(%{
      "channel" => "notes",
      "kind" => "note",
      "subject" => read_string(note, "title", nil),
      "text" => read_string(note, "body", read_string(note, "text", nil)),
      "at" => evidence_time(note, ["updated_at", "modified_at", "created_at"]),
      "source_item_id" => read_string(note, "guid", read_string(note, "id", nil))
    })
  end

  defp note_source_evidence(_note), do: nil

  defp reminder_source_evidence(reminder) when is_map(reminder) do
    evidence_item(%{
      "channel" => "reminders",
      "kind" =>
        if(truthy?(read_value(reminder, "is_completed")),
          do: "completed reminder",
          else: "open reminder"
        ),
      "subject" => read_string(reminder, "title", nil),
      "text" => read_string(reminder, "notes", nil),
      "at" => evidence_time(reminder, ["completed_at", "due_at", "updated_at"]),
      "source_item_id" => read_string(reminder, "guid", read_string(reminder, "id", nil))
    })
  end

  defp reminder_source_evidence(_reminder), do: nil

  defp file_source_evidence(file) when is_map(file) do
    evidence_item(%{
      "channel" => "files",
      "kind" => "recent file",
      "subject" => read_string(file, "name", read_string(file, "filename", nil)),
      "text" => read_string(file, "path", read_string(file, "text", nil)),
      "at" => evidence_time(file, ["modified_at", "created_at"]),
      "source_item_id" => read_string(file, "id", read_string(file, "path", nil))
    })
  end

  defp file_source_evidence(_file), do: nil

  defp browser_history_source_evidence(visit) when is_map(visit) do
    evidence_item(%{
      "channel" => "browser_history",
      "kind" => "browser visit",
      "subject" => read_string(visit, "title", nil),
      "text" => read_string(visit, "url", nil),
      "at" => evidence_time(visit, ["visited_at", "last_visit_at"]),
      "source_item_id" => read_string(visit, "id", read_string(visit, "url", nil))
    })
  end

  defp browser_history_source_evidence(_visit), do: nil

  defp voice_memo_source_evidence(memo) when is_map(memo) do
    evidence_item(%{
      "channel" => "voice_memos",
      "kind" => "voice memo",
      "subject" => read_string(memo, "title", nil),
      "text" => read_string(memo, "transcript", read_string(memo, "text", nil)),
      "at" => evidence_time(memo, ["recorded_at", "created_at", "updated_at"]),
      "source_item_id" => read_string(memo, "guid", read_string(memo, "id", nil))
    })
  end

  defp voice_memo_source_evidence(_memo), do: nil

  # ── Evaluation ────────────────────────────────────────────────────────────

  defp evaluate_fitting(_user_id, [], _evidence, _now, _opts),
    do: {:error, :no_prompt_candidates_fit}

  defp evaluate_fitting(user_id, todos, evidence, now, opts) do
    evaluation =
      if Keyword.get(opts, :exact_source_delta, false) do
        evaluate_exact_evidence_chunks(user_id, todos, evidence, now, opts)
      else
        evaluate(user_id, todos, evidence, now, opts)
      end

    case evaluation do
      %{} = result ->
        {:ok, Map.put_new(result, :model_calls, 1), todos}

      {:error, reason} = error ->
        if prompt_budget_error?(reason) and length(todos) > 1 do
          if Keyword.get(opts, :exhaustive_completion, false) do
            {left, right} = Enum.split(todos, div(length(todos), 2))

            with {:ok, left_result, left_todos} <-
                   evaluate_fitting(user_id, left, evidence, now, opts),
                 {:ok, right_result, right_todos} <-
                   evaluate_fitting(user_id, right, evidence, now, opts) do
              {:ok,
               %{
                 checked: left_result.checked + right_result.checked,
                 completed: left_result.completed + right_result.completed,
                 model_calls: left_result.model_calls + right_result.model_calls
               }, left_todos ++ right_todos}
            end
          else
            evaluate_fitting(user_id, Enum.drop(todos, -1), evidence, now, opts)
          end
        else
          error
        end
    end
  end

  defp prompt_budget_error?({reason, _actual, _limit})
       when reason in [
              :prompt_base_exceeds_budget,
              :required_evidence_exceeds_budget,
              :prompt_exceeds_budget,
              :exact_completion_evidence_exceeds_budget,
              :exact_completion_evidence_item_exceeds_budget
            ],
       do: true

  defp prompt_budget_error?({:required_evidence_items_exceed_limit, _actual, _limit}), do: true
  defp prompt_budget_error?({:evidence_budget_too_small, _limit}), do: true
  defp prompt_budget_error?(_reason), do: false

  defp evaluate(user_id, todos, evidence, now, opts) do
    with {:ok, resolutions, authorized_evidence} <-
           evaluate_resolutions(user_id, todos, evidence, now, opts),
         {:ok, completed} <-
           apply_resolutions(
             user_id,
             Map.new(todos, &{&1.id, &1}),
             resolutions,
             authorized_evidence,
             opts
           ) do
      %{checked: length(todos), completed: completed}
    else
      {:error, reason} ->
        log_evaluation_failure(
          "Cross-source completion pass failed",
          "Cross-source completion deferred for model capacity",
          user_id,
          reason
        )

        {:error, reason}

      other ->
        {:error, {:unexpected_llm_result, other}}
    end
  end

  defp evaluate_resolutions(user_id, todos, evidence, now, opts) do
    llm_complete = Keyword.get(opts, :llm_complete) || (&default_llm_complete(&1, opts))

    with {:ok, {prompt, authorized_evidence}} <-
           build_prompt(user_id, todos, evidence, now, opts),
         {:ok, response} <- llm_complete.(prompt),
         {:ok, resolutions} <- decode_response(response),
         :ok <- validate_resolution_coverage(resolutions, todos, opts) do
      {:ok, resolutions, authorized_evidence}
    end
  end

  defp evaluate_exact_evidence_chunks(user_id, todos, evidence, now, opts) do
    exact_opts = Keyword.put(opts, :exhaustive_completion, true)

    result =
      with {:ok, evidence_chunks} <-
             partition_exact_prompt_evidence(user_id, todos, evidence, now, exact_opts),
           {:ok, evaluations} <-
             evaluate_exact_chunks(user_id, todos, evidence_chunks, now, exact_opts),
           {resolutions, authorized_evidence} <-
             aggregate_exact_resolutions(todos, evaluations),
           {:ok, completed} <-
             apply_resolutions(
               user_id,
               Map.new(todos, &{&1.id, &1}),
               resolutions,
               authorized_evidence,
               exact_opts
             ) do
        %{
          checked: length(todos),
          completed: completed,
          model_calls: length(evidence_chunks)
        }
      end

    case result do
      %{} = summary ->
        summary

      {:error, reason} = error ->
        log_evaluation_failure(
          "Cross-source exact completion pass failed",
          "Cross-source exact completion deferred for model capacity",
          user_id,
          reason
        )

        error
    end
  end

  defp evaluate_exact_chunks(user_id, todos, evidence_chunks, now, opts) do
    Enum.reduce_while(evidence_chunks, {:ok, []}, fn chunk, {:ok, evaluations} ->
      case evaluate_resolutions(user_id, todos, chunk, now, opts) do
        {:ok, resolutions, authorized_evidence} ->
          {:cont, {:ok, [{resolutions, authorized_evidence} | evaluations]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, evaluations} -> {:ok, Enum.reverse(evaluations)}
      {:error, _reason} = error -> error
    end
  end

  defp log_evaluation_failure(failure_message, deferred_message, user_id, reason) do
    metadata = [
      user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
      failure_code: Maraithon.Redaction.error_class(reason)
    ]

    if model_capacity_deferral?(reason) do
      Logger.info(deferred_message, metadata)
    else
      Logger.warning(failure_message, metadata)
    end
  end

  defp model_capacity_deferral?(:llm_busy), do: true
  defp model_capacity_deferral?({:llm_busy, _retry_after}), do: true
  defp model_capacity_deferral?({:rate_limited, _retry_after}), do: true
  defp model_capacity_deferral?({:rate_limited, _retry_after, _detail}), do: true
  defp model_capacity_deferral?(_reason), do: false

  defp aggregate_exact_resolutions(todos, evaluations) do
    resolutions =
      Enum.map(todos, fn todo ->
        candidates =
          Enum.map(evaluations, fn {chunk_resolutions, authorized_evidence} ->
            resolution =
              Enum.find(chunk_resolutions, &(&1["todo_id"] == todo.id)) ||
                %{"todo_id" => todo.id, "completed" => false}

            {resolution, authorized_evidence}
          end)

        completion =
          Enum.find(candidates, fn {resolution, authorized_evidence} ->
            exact_completion_resolution?(todo, resolution, authorized_evidence)
          end)

        acknowledgement =
          Enum.find(candidates, fn {resolution, authorized_evidence} ->
            exact_acknowledgement_resolution?(todo, resolution, authorized_evidence)
          end)

        case completion || acknowledgement do
          {resolution, _authorized_evidence} ->
            resolution

          nil ->
            %{"todo_id" => todo.id, "completed" => false}
        end
      end)

    authorized_evidence = Enum.flat_map(evaluations, &elem(&1, 1))
    {resolutions, authorized_evidence}
  end

  defp exact_completion_resolution?(
         %Todo{direction: "owed_to_me"},
         %{"reply_outcome" => "acknowledged_only"},
         _evidence
       ),
       do: false

  defp exact_completion_resolution?(%Todo{} = todo, resolution, evidence) do
    resolution["completed"] == true and
      authorized_resolution_evidence?(todo, resolution, evidence)
  end

  defp exact_acknowledgement_resolution?(
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "acknowledged_only"} = resolution,
         evidence
       ) do
    authorized_acknowledgement_evidence?(todo, resolution, evidence)
  end

  defp exact_acknowledgement_resolution?(_todo, _resolution, _evidence), do: false

  defp partition_exact_prompt_evidence(user_id, todos, evidence, now, opts) do
    with {:ok, fragments} <-
           split_exact_prompt_evidence(user_id, todos, evidence, now, opts),
         {:ok, chunks} <- pack_exact_prompt_evidence(user_id, todos, fragments, now, opts),
         :ok <- validate_exact_partition_refs(evidence, chunks) do
      {:ok, chunks}
    end
  end

  defp split_exact_prompt_evidence(user_id, todos, evidence, now, opts) do
    Enum.reduce_while(evidence, {:ok, []}, fn item, {:ok, fragments} ->
      case split_exact_prompt_item(user_id, todos, item, now, opts) do
        {:ok, item_fragments} -> {:cont, {:ok, fragments ++ item_fragments}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp split_exact_prompt_item(user_id, todos, item, now, opts) when is_map(item) do
    case build_prompt(user_id, todos, [item], now, opts) do
      {:ok, _prompt} ->
        {:ok, [item]}

      {:error, {:prompt_base_exceeds_budget, _actual, _limit}} = error ->
        error

      {:error, _reason} ->
        with text when is_binary(text) <- exact_string(item, "text", nil),
             {:ok, left, right} <- split_utf8_text(text),
             {:ok, left_fragments} <-
               split_exact_prompt_item(user_id, todos, Map.put(item, "text", left), now, opts),
             {:ok, right_fragments} <-
               split_exact_prompt_item(user_id, todos, Map.put(item, "text", right), now, opts) do
          {:ok, left_fragments ++ right_fragments}
        else
          _invalid -> exact_item_budget_error(item)
        end
    end
  end

  defp split_exact_prompt_item(_user_id, _todos, item, _now, _opts),
    do: exact_item_budget_error(item)

  defp pack_exact_prompt_evidence(user_id, todos, fragments, now, opts) do
    fragments
    |> Enum.reduce_while({:ok, [], []}, fn fragment, {:ok, chunks, current} ->
      candidate = current ++ [fragment]

      case build_prompt(user_id, todos, candidate, now, opts) do
        {:ok, _prompt} ->
          {:cont, {:ok, chunks, candidate}}

        {:error, _reason} when current != [] ->
          {:cont, {:ok, chunks ++ [current], [fragment]}}

        {:error, _reason} ->
          {:halt, exact_item_budget_error(fragment)}
      end
    end)
    |> case do
      {:ok, chunks, []} -> {:ok, chunks}
      {:ok, chunks, current} -> {:ok, chunks ++ [current]}
      {:error, _reason} = error -> error
    end
  end

  defp validate_exact_partition_refs(evidence, chunks) do
    expected = exact_source_refs(evidence)
    actual = chunks |> List.flatten() |> exact_source_refs()

    if expected != [] and actual == expected do
      :ok
    else
      {:error, :cross_source_completion_partition_coverage_incomplete}
    end
  end

  defp exact_source_refs(evidence) do
    evidence
    |> Enum.map(&read_string(&1, "source_ref", nil))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp exact_item_budget_error(item) do
    actual = item |> compact_exact_prompt_evidence_item() |> Jason.encode!() |> byte_size()
    {:error, {:exact_completion_evidence_item_exceeds_budget, actual, @max_prompt_bytes}}
  end

  defp split_utf8_text(text) when is_binary(text) do
    if String.valid?(text) do
      codepoints = String.codepoints(text)
      split_at = div(length(codepoints), 2)

      case Enum.split(codepoints, split_at) do
        {left, right} when left != [] and right != [] ->
          {:ok, IO.iodata_to_binary(left), IO.iodata_to_binary(right)}

        _unsplittable ->
          {:error, :exact_completion_evidence_text_unsplittable}
      end
    else
      {:error, :exact_completion_evidence_text_invalid_utf8}
    end
  end

  defp build_prompt(user_id, todos, evidence, now, opts) do
    exhaustive? = Keyword.get(opts, :exhaustive_completion, false)
    todos_json = todos |> Enum.map(&prompt_todo/1) |> Jason.encode!()
    empty_prompt = render_prompt(todos_json, "[]", now, exhaustive?)
    base_bytes = prompt_request_bytes(empty_prompt)

    if base_bytes > @max_prompt_bytes do
      {:error, {:prompt_base_exceeds_budget, base_bytes, @max_prompt_bytes}}
    else
      # The prompt is itself a JSON message string, so reserve worst-case
      # outer escaping instead of treating raw prompt bytes as request bytes.
      evidence_budget = div(max(@max_prompt_bytes - base_bytes + byte_size("[]"), 0), 2)

      with {:ok, {evidence_json, included_evidence}} <-
             encode_evidence_for_mode(todos, evidence, evidence_budget, opts) do
        prompt = render_prompt(todos_json, evidence_json, now, exhaustive?)
        prompt_bytes = prompt_request_bytes(prompt)

        if prompt_bytes <= @max_prompt_bytes do
          if included_evidence < length(evidence) do
            Logger.info("Cross-source completion bounded LLM prompt evidence",
              user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
              available_evidence: length(evidence),
              included_evidence: included_evidence,
              prompt_bytes: prompt_bytes,
              prompt_byte_cap: @max_prompt_bytes
            )
          end

          {:ok, {prompt, Jason.decode!(evidence_json)}}
        else
          {:error, {:prompt_exceeds_budget, prompt_bytes, @max_prompt_bytes}}
        end
      end
    end
  end

  defp encode_evidence_for_mode(todos, evidence, evidence_budget, opts) do
    if Keyword.get(opts, :exact_source_delta, false) do
      encode_exact_prompt_evidence(evidence, evidence_budget)
    else
      with {:ok, {required, optional}} <- select_prompt_evidence(todos, evidence) do
        encode_prompt_evidence(required, optional, evidence_budget)
      end
    end
  end

  defp encode_exact_prompt_evidence(evidence, max_bytes)
       when is_list(evidence) and is_integer(max_bytes) and max_bytes >= 2 do
    encoded = Enum.map(evidence, &(compact_exact_prompt_evidence_item(&1) |> Jason.encode!()))
    evidence_json = "[" <> Enum.join(encoded, ",") <> "]"

    if byte_size(evidence_json) <= max_bytes do
      {:ok, {evidence_json, length(evidence)}}
    else
      {:error, {:exact_completion_evidence_exceeds_budget, byte_size(evidence_json), max_bytes}}
    end
  end

  defp encode_exact_prompt_evidence(_evidence, max_bytes),
    do: {:error, {:evidence_budget_too_small, max_bytes}}

  defp compact_exact_prompt_evidence_item(item) do
    %{
      "channel" => read_string(item, "channel", nil),
      "kind" => read_string(item, "kind", nil),
      "subject" => read_string(item, "subject", nil),
      "text" => exact_string(item, "text", nil),
      "at" => read_string(item, "at", nil),
      "source_ref" => read_string(item, "source_ref", nil),
      "source_item_id" => read_string(item, "source_item_id", nil),
      "target_source_item_id" => read_string(item, "target_source_item_id", nil),
      "thread_id" => read_string(item, "thread_id", nil),
      "account" => read_string(item, "account", nil),
      "permalink" => read_string(item, "permalink", nil)
    }
    |> compact_map()
  end

  defp prompt_request_bytes(prompt) when is_binary(prompt) do
    [%{"role" => "user", "content" => prompt}]
    |> PromptStability.encode!()
    |> byte_size()
  end

  defp prompt_todo(todo) do
    %{
      "todo_id" => bounded_prompt_string(todo.id, 64),
      "source_channel" => bounded_prompt_string(todo.source, 64),
      "title" => bounded_prompt_string(todo.title, 240),
      "summary" => bounded_prompt_string(todo.summary, 480),
      "next_action" => bounded_prompt_string(todo.next_action, 320),
      "captured_at" => DateTime.to_iso8601(todo.source_occurred_at || todo.inserted_at),
      # SPEC 05 R5: structured linkage so the model can match a specific piece
      # of inbound evidence to a specific waiting-on item.
      "direction" => bounded_prompt_string(todo.direction, 64),
      "counterparty_label" => bounded_prompt_string(todo.counterparty_label, 200),
      "source_item_id" => bounded_prompt_string(todo.source_item_id, 256),
      "source_account_label" => bounded_prompt_string(todo.source_account_label, 200)
    }
    |> compact_map()
    |> PromptBudget.project_fields(
      ~w(todo_id source_channel title summary next_action captured_at direction counterparty_label source_item_id source_account_label),
      900,
      string_bytes: 480,
      list_items: 5,
      map_entries: 12,
      max_depth: 2,
      key_bytes: 64
    )
  end

  defp select_prompt_evidence(todos, evidence) do
    indexed =
      evidence
      |> Enum.reject(&is_nil/1)
      |> Enum.with_index()

    {health, activity} =
      Enum.split_with(indexed, fn {item, _index} ->
        read_string(item, "channel", nil) == "source_health"
      end)

    health = health |> sort_prompt_evidence_newest() |> Enum.take(1)

    linked =
      Enum.filter(activity, fn {item, _index} ->
        Enum.any?(todos, &evidence_linked_to_todo?(&1, item))
      end)

    linked_heads =
      todos
      |> Enum.flat_map(fn todo ->
        case best_linked_evidence(todo, linked) do
          nil -> []
          item -> [item]
        end
      end)
      |> Enum.uniq_by(&elem(&1, 1))

    linked_head_indexes = indexed_evidence_set(linked_heads)

    linked_head_channels =
      linked_heads
      |> Enum.map(fn {item, _index} -> read_string(item, "channel", "unknown") end)
      |> MapSet.new()

    channel_heads =
      activity
      |> Enum.reject(fn {item, index} ->
        MapSet.member?(linked_head_indexes, index) or
          MapSet.member?(
            linked_head_channels,
            read_string(item, "channel", "unknown")
          )
      end)
      |> group_prompt_evidence_by_channel()
      |> Enum.map(fn {_channel, items} -> items |> sort_prompt_evidence_newest() |> hd() end)

    required =
      (health ++ linked_heads ++ channel_heads)
      |> Enum.uniq_by(&elem(&1, 1))

    if length(required) > @max_prompt_evidence_items do
      {:error,
       {:required_evidence_items_exceed_limit, length(required), @max_prompt_evidence_items}}
    else
      required_indexes = indexed_evidence_set(required)

      linked_tail =
        linked
        |> Enum.reject(fn {_item, index} -> MapSet.member?(required_indexes, index) end)
        |> sort_prompt_evidence_newest()
        |> Enum.take(max(@max_prompt_linked_evidence_items - length(linked_heads), 0))

      selected_indexes = indexed_evidence_set(required ++ linked_tail)

      fair_tail =
        activity
        |> Enum.reject(fn {_item, index} -> MapSet.member?(selected_indexes, index) end)
        |> group_prompt_evidence_by_channel()
        |> Enum.map(fn {_channel, items} ->
          items
          |> sort_prompt_evidence_newest()
          |> Enum.take(@max_prompt_evidence_per_channel)
        end)
        |> round_robin_prompt_evidence()

      optional =
        (linked_tail ++ fair_tail)
        |> Enum.uniq_by(&elem(&1, 1))
        |> Enum.take(@max_prompt_evidence_items - length(required))

      {:ok, {Enum.map(required, &elem(&1, 0)), Enum.map(optional, &elem(&1, 0))}}
    end
  end

  defp best_linked_evidence(todo, linked) do
    linked
    |> Enum.filter(fn {item, _index} -> evidence_linked_to_todo?(todo, item) end)
    |> Enum.sort_by(
      fn {item, index} ->
        {if(exact_evidence_link?(todo, item), do: 1, else: 0), evidence_sort_key(item), -index}
      end,
      :desc
    )
    |> List.first()
  end

  defp exact_evidence_link?(todo, item) do
    source_item_id = todo.source_item_id

    is_binary(source_item_id) and source_item_id != "" and
      source_item_id in [
        read_string(item, "source_item_id", nil),
        read_string(item, "thread_id", nil),
        read_string(item, "target_source_item_id", nil)
      ]
  end

  defp evidence_linked_to_todo?(todo, item) do
    evidence_linked?(todo, evidence_identifiers([item]))
  end

  defp indexed_evidence_set(indexed) do
    indexed |> Enum.map(&elem(&1, 1)) |> MapSet.new()
  end

  defp group_prompt_evidence_by_channel(indexed) do
    indexed
    |> Enum.group_by(fn {item, _index} -> read_string(item, "channel", "unknown") end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp sort_prompt_evidence_newest(indexed) do
    Enum.sort_by(indexed, fn {item, index} -> {evidence_sort_key(item), -index} end, :desc)
  end

  defp round_robin_prompt_evidence(groups) do
    Enum.flat_map(0..(@max_prompt_evidence_per_channel - 1), fn offset ->
      Enum.flat_map(groups, fn group ->
        case Enum.at(group, offset) do
          nil -> []
          item -> [item]
        end
      end)
    end)
  end

  defp encode_prompt_evidence(required, optional, max_bytes)
       when is_integer(max_bytes) and max_bytes >= 2 do
    with {:ok, required_json, used_bytes} <-
           encode_required_prompt_evidence(required, max_bytes) do
      {encoded, _used_bytes} =
        Enum.reduce(optional, {required_json, used_bytes}, fn item, {items, bytes} ->
          encoded_item = item |> compact_prompt_evidence_item() |> Jason.encode!()
          separator_bytes = if items == [], do: 0, else: 1
          item_bytes = byte_size(encoded_item) + separator_bytes

          if bytes + item_bytes <= max_bytes do
            {[encoded_item | items], bytes + item_bytes}
          else
            # Skip an oversized optional item and continue so one pathological
            # record cannot starve later channels that would still fit.
            {items, bytes}
          end
        end)

      evidence_json = "[" <> (encoded |> Enum.reverse() |> Enum.join(",")) <> "]"
      {:ok, {evidence_json, length(encoded)}}
    end
  end

  defp encode_prompt_evidence(_required, _optional, max_bytes) do
    {:error, {:evidence_budget_too_small, max_bytes}}
  end

  defp encode_required_prompt_evidence(required, max_bytes) do
    Enum.reduce_while(required, {:ok, [], 2}, fn item, {:ok, items, bytes} ->
      encoded_item = item |> compact_prompt_evidence_item() |> Jason.encode!()
      separator_bytes = if items == [], do: 0, else: 1
      item_bytes = byte_size(encoded_item) + separator_bytes

      if bytes + item_bytes <= max_bytes do
        {:cont, {:ok, [encoded_item | items], bytes + item_bytes}}
      else
        {:halt, {:error, {:required_evidence_exceeds_budget, bytes + item_bytes, max_bytes}}}
      end
    end)
  end

  defp compact_prompt_evidence_item(item) do
    channel = read_string(item, "channel", nil)
    text_limit = if channel == "source_health", do: @max_prompt_health_text, else: 1_000

    %{
      "channel" => bounded_prompt_string(channel, 64),
      "kind" => bounded_prompt_string(read_string(item, "kind", nil), 160),
      "subject" => bounded_prompt_string(read_string(item, "subject", nil), 360),
      "text" => bounded_prompt_string(read_string(item, "text", nil), text_limit),
      "at" => bounded_prompt_string(read_string(item, "at", nil), 64),
      "source_item_id" => bounded_prompt_string(read_string(item, "source_item_id", nil), 256),
      "target_source_item_id" =>
        bounded_prompt_string(read_string(item, "target_source_item_id", nil), 256),
      "thread_id" => bounded_prompt_string(read_string(item, "thread_id", nil), 256),
      "account" => bounded_prompt_string(read_string(item, "account", nil), 200),
      "permalink" => bounded_prompt_string(read_string(item, "permalink", nil), 500)
    }
    |> compact_map()
    |> PromptBudget.project_fields(
      ~w(channel kind subject text at source_item_id target_source_item_id thread_id account permalink),
      if(channel == "source_health", do: 13_000, else: 1_200),
      string_bytes: text_limit,
      list_items: 4,
      map_entries: 11,
      max_depth: 2,
      key_bytes: 64
    )
  end

  defp bounded_prompt_string(value, max_bytes) when is_binary(value) do
    PromptBudget.truncate_utf8(value, max_bytes)
  end

  defp bounded_prompt_string(_value, _max_bytes), do: nil

  defp render_prompt(todos_json, evidence_json, now, exhaustive?) do
    """
    You are the completion checker for a chief-of-staff product. The user has
    saved open work items. Below is current source material from every connected
    source this sweep could access: Gmail, Slack, Google Calendar, local
    Calendar, iMessage/Messages, Reminders, Notes, files, browser history, voice
    memos, and persisted CRM observations. The `source_health` item records
    which sources were ready, partial, unavailable, or empty for this sweep.

    Decide which open work items the user has ALREADY COMPLETED or which have
    been made obsolete by newer source evidence, judged only from the supplied
    source material.

    Strict rules:
    - Close an item only when the evidence explicitly shows that the specific
      work was done: a past-tense completion statement by the user ("paid",
      "sent it", "booked", "submitted", "done", "renewed", "shipped"), or a
      counterparty confirming receipt/closure ("got it, thanks", a receipt or
      confirmation message), about the SAME counterparty/object as the item.
    - For work whose action is to create, publish, schedule, or share an event,
      later source material showing the same event exists, has a public/manage
      URL, has guests/attendees, is live, is being promoted, or is otherwise
      already operating is completion evidence for that creation/publishing
      step. Do not keep the creation item open just because follow-on work
      remains; follow-on work belongs in a separate work item.
    - Use intelligence, not keyword overlap. Compare the object, counterparty,
      timing, source references, and the actual action requested. Source search
      terms or topic similarity alone are not completion.
    - Evidence must be AFTER the item's captured_at timestamp.
    - Topic overlap alone is NOT completion. Future intent ("will pay
      tomorrow"), questions, reminders, or partial progress are NOT
      completion.
    - When an item's `direction` is `owed_to_me`, a reply FROM the
      counterparty (not from the user — check the evidence item's `kind`,
      e.g. `email received`, `slack message`, `message received`, never
      `... sent by the user`) that actually answers or resolves what the
      item's `next_action`/`summary` describes is completion for that item,
      exactly like the user doing the work — return it with
      "completed": true and "reply_outcome": "answered". A reply that only
      acknowledges ("got your message, will look at it") or defers ("will
      get back to you Friday") is NOT completion — return that item with
      "completed": false and "reply_outcome": "acknowledged_only", still
      quoting the acknowledgment as evidence_quote, and leave it open. Omit
      reply_outcome (or use "no_reply") when there is no counterparty-reply
      signal for an item.
    - If a relevant connected source is unavailable or the source window is too
      weak to prove completion, leave the item open.
    - When unsure, leave the item open. Wrongly closing real work is worse
      than showing a finished item.

    OPEN_WORK_ITEMS_JSON:
    #{todos_json}

    RECENT_ACTIVITY_JSON (current time #{DateTime.to_iso8601(now)}):
    #{evidence_json}

    #{resolution_coverage_instruction(exhaustive?)}Respond with only this JSON shape, no prose:
    {
      "resolutions": [
        {
          "todo_id": "uuid of a completed item",
          "completed": true,
          "evidence_channel": "slack | gmail | google_calendar | local_calendar | imessage | reminders | notes | files | browser_history | voice_memos | crm",
          "evidence_quote": "the exact activity text that proves completion",
          "reasoning": "one short sentence",
          "confidence": 0.0,
          "reply_outcome": "answered | acknowledged_only | no_reply — only for owed_to_me items with a counterparty-reply signal; omit otherwise"
        }
      ]
    }
    #{empty_resolution_instruction(exhaustive?)}
    """
  end

  defp resolution_coverage_instruction(true) do
    """
    This is an exact closure sweep. Return exactly one resolution for every
    OPEN_WORK_ITEMS_JSON entry, using each todo_id exactly once. For work that
    is not provably complete, return completed=false with a short reason; do
    not omit it. The response is rejected unless its todo_id set exactly
    matches the input set.
    """
  end

  defp resolution_coverage_instruction(false), do: ""

  defp empty_resolution_instruction(true),
    do: "Never return an empty resolutions list when work items were supplied."

  defp empty_resolution_instruction(false),
    do: ~s(Return {"resolutions": []} when nothing is provably complete.)

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])
    llm_request = Keyword.get(opts, :llm_request, &LLM.complete/1)

    llm_request.(%{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.1,
      # The prompt already asks for explicit, evidence-backed reasoning in
      # the JSON payload. Hidden chain-of-thought consumed the entire output
      # budget on hybrid models and left no parseable response.
      "reasoning_effort" => Keyword.get(config, :reasoning_effort, "none"),
      "timeout_ms" => Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    })
  end

  defp decode_response(response) do
    content =
      case response do
        %{"content" => content} when is_binary(content) -> content
        %{content: content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _other -> nil
      end

    with content when is_binary(content) and byte_size(content) <= 128_000 <- content,
         json when is_binary(json) <- extract_json(content),
         {:ok, %{"resolutions" => resolutions}} when is_list(resolutions) <- Jason.decode(json),
         prefix = Enum.take(resolutions, @max_todos + 1),
         true <- length(prefix) <= @max_todos do
      {:ok, prefix}
    else
      _other -> {:error, :cross_source_completion_invalid_response}
    end
  end

  defp validate_resolution_coverage(resolutions, todos, opts) do
    if Keyword.get(opts, :exhaustive_completion, false) do
      expected_ids = todos |> Enum.map(& &1.id) |> Enum.sort()

      actual_ids =
        Enum.map(resolutions, fn
          %{"todo_id" => todo_id, "completed" => completed}
          when is_binary(todo_id) and is_boolean(completed) ->
            todo_id

          _other ->
            nil
        end)

      if Enum.all?(actual_ids, &is_binary/1) and Enum.sort(actual_ids) == expected_ids do
        :ok
      else
        {:error, :cross_source_completion_incomplete_decisions}
      end
    else
      :ok
    end
  end

  # Byte offsets are safe here: the braces are ASCII, so slicing between
  # them keeps any multibyte content in the middle intact.
  defp extract_json(content) do
    with {start, _length} <- :binary.match(content, "{"),
         [_ | _] = closers <- :binary.matches(content, "}") do
      {finish, _length} = List.last(closers)
      binary_part(content, start, finish - start + 1)
    else
      _other -> nil
    end
  end

  # SPEC 05 shared contract (05 owns this dispatch; 01 only consumes it):
  # the model emits exactly one `owed_to_me` reply-outcome per resolved item —
  # "answered" closes (identical in effect to the user doing the work),
  # "acknowledged_only" keeps the item open but clears its nudge cadence,
  # "no_reply"/omitted leaves the item and its cadence untouched.
  defp apply_resolutions(user_id, todos_by_id, resolutions, evidence, opts) do
    resolutions
    |> Enum.filter(&is_map/1)
    # The model can emit the same todo twice; only the first resolution per
    # todo applies, so a duplicate can never double-close or double-notify.
    |> Enum.uniq_by(& &1["todo_id"])
    |> Enum.reduce_while({:ok, 0}, fn resolution, {:ok, count} ->
      with todo_id when is_binary(todo_id) <- resolution["todo_id"],
           %Todo{} = todo <- Map.get(todos_by_id, todo_id) do
        case apply_resolution(user_id, todo, resolution, evidence, opts, count) do
          {:ok, next_count} -> {:cont, {:ok, next_count}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        _other -> {:cont, {:ok, count}}
      end
    end)
  end

  # `owed_to_me` + acknowledgment-only counterparty reply (SPEC 05 R7): never
  # a completion, regardless of what else the resolution claims — stop the
  # old chase cadence but keep the item open, and never notify (an
  # acknowledged-only reply is not a completion event worth a push).
  defp apply_resolution(
         user_id,
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "acknowledged_only"} = resolution,
         evidence,
         _opts,
         count
       ) do
    if authorized_acknowledgement_evidence?(todo, resolution, evidence) do
      case Todos.clear_nudge_cadence(user_id, todo.id) do
        {:ok, _todo} ->
          Logger.info("Cross-source completion cleared nudge cadence (acknowledged-only reply)",
            user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
            todo_reference: Maraithon.Redaction.fingerprint(todo.id)
          )

          {:ok, count}

        {:error, reason} ->
          Logger.warning("Cross-source completion could not clear nudge cadence",
            user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
            todo_reference: Maraithon.Redaction.fingerprint(todo.id),
            failure_code: Maraithon.Redaction.error_class(reason)
          )

          {:error, :completion_acknowledgement_write_failed}
      end
    else
      {:ok, count}
    end
  end

  defp apply_resolution(user_id, %Todo{} = todo, resolution, evidence, opts, count) do
    with true <- resolution["completed"] == true,
         confidence when is_number(confidence) and confidence >= @min_confidence <-
           resolution["confidence"],
         quote_text when is_binary(quote_text) and quote_text != "" <-
           resolution["evidence_quote"],
         true <- authorized_resolution_evidence?(todo, resolution, evidence) do
      note = resolution_note(todo, resolution, quote_text)

      case Todos.mark_done(user_id, todo.id, note: note) do
        {:ok, _todo} ->
          Logger.info("Cross-source completion closed todo",
            user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
            todo_reference: Maraithon.Redaction.fingerprint(todo.id),
            todo_source: todo.source,
            evidence_channel: resolution["evidence_channel"]
          )

          maybe_push_completion_confirmation(user_id, todo, resolution, opts)
          {:ok, count + 1}

        {:error, reason} ->
          Logger.warning("Cross-source completion could not close todo",
            user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
            todo_reference: Maraithon.Redaction.fingerprint(todo.id),
            failure_code: Maraithon.Redaction.error_class(reason)
          )

          {:error, :completion_write_failed}
      end
    else
      _other -> {:ok, count}
    end
  end

  defp authorized_resolution_evidence?(todo, resolution, evidence),
    do: authorized_evidence?(todo, resolution, evidence, fn _item -> true end)

  defp authorized_acknowledgement_evidence?(todo, resolution, evidence),
    do: authorized_evidence?(todo, resolution, evidence, &inbound_reply_evidence?/1)

  defp authorized_evidence?(todo, resolution, evidence, kind_authorized?) do
    quote = bounded_prompt_string(resolution["evidence_quote"], 500)
    channel = bounded_prompt_string(resolution["evidence_channel"], 64)
    todo_at = todo.source_occurred_at || todo.inserted_at
    confidence = resolution["confidence"]

    is_number(confidence) and confidence >= @min_confidence and is_binary(quote) and
      byte_size(quote) >= 4 and allowed_evidence_channel?(channel) and
      Enum.any?(evidence, fn item ->
        evidence_channel = read_string(item, "channel", nil)
        evidence_at = item |> read_string("at", nil) |> parse_datetime()
        text = read_string(item, "text", "")
        subject = read_string(item, "subject", "")

        kind_authorized?.(item) and evidence_channel == channel and
          evidence_channel != "source_health" and evidence_linked_to_todo?(todo, item) and
          match?(%DateTime{}, evidence_at) and DateTime.compare(evidence_at, todo_at) == :gt and
          evidence_quote_matches?(quote, text, subject)
      end)
  end

  defp inbound_reply_evidence?(item) do
    read_string(item, "kind", nil) in ["email received", "message received", "slack mention"]
  end

  defp allowed_evidence_channel?(channel) do
    channel in ~w(
      slack gmail google_calendar local_calendar imessage reminders notes files browser_history
      voice_memos crm
    )
  end

  defp evidence_quote_matches?(quote, text, subject) do
    quote = normalize_evidence_quote(quote)

    byte_size(quote) >= 4 and
      Enum.any?([text, subject], fn candidate ->
        candidate = normalize_evidence_quote(candidate)
        candidate != "" and String.contains?(candidate, quote)
      end)
  end

  # Exact evidence fragments can be substantially larger than the ordinary
  # compact prompt excerpts. Authorization must search the same lossless text
  # the model saw; rejecting every fragment over 2KB would make a valid quote
  # near the end of an oversized Gmail/Slack item impossible to authorize.
  # A fragment can never exceed the request cap because it was admitted by
  # `build_prompt/5`, so this remains bounded.
  defp normalize_evidence_quote(value)
       when is_binary(value) and byte_size(value) <= @max_prompt_bytes do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize_evidence_quote(_value), do: ""

  # Distinct confirmation copy for the counterparty-answered close (SPEC 05
  # R7); everything else keeps the pre-existing generic note.
  defp resolution_note(
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "answered"} = resolution,
         quote_text
       ) do
    "#{counterparty_name(todo)} replied — closing that loop. " <>
      "#{evidence_channel_label(resolution["evidence_channel"])} " <>
      "shows it: \"#{truncate(quote_text, 200)}\""
  end

  defp resolution_note(_todo, resolution, quote_text) do
    "Handled already — #{evidence_channel_label(resolution["evidence_channel"])} " <>
      "shows it: \"#{truncate(quote_text, 200)}\""
  end

  # SPEC 05 R8: Telegram confirmation for the `owed_to_me` inbound-reply close
  # only — `owed_by_me`/`fyi` closes stay silent exactly as before. Goes
  # through `PushBroker.deliver/1` (the only path that respects quiet hours,
  # the interruption budget, and push-receipt dedupe), never `TelegramResponder`
  # directly. `chat_id` must be resolved explicitly — `deliver/1` hard-requires
  # it and never supplies it.
  defp maybe_push_completion_confirmation(
         user_id,
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "answered"},
         opts
       ) do
    case ConnectedAccounts.telegram_destination(user_id) do
      nil ->
        Logger.info(
          "Cross-source completion skipped closing-loop push: no Telegram destination",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          todo_reference: Maraithon.Redaction.fingerprint(todo.id)
        )

        :ok

      chat_id ->
        deliver = Keyword.get(opts, :push_deliver) || (&PushBroker.deliver/1)

        candidate = %{
          user_id: user_id,
          chat_id: chat_id,
          origin_type: "todo_completion_confirm",
          origin_id: todo.id,
          # Defense-in-depth idempotency: a todo can only close once (closing
          # exits the open/snoozed candidate pool), but the receipt dedupe on
          # this key means even a hypothetical double-apply cannot double-notify.
          dedupe_key: "todo_completion_confirm:#{todo.id}",
          # Low urgency, never the >= 0.9 quiet-hours exemption; rides the
          # normal budget/quiet-hours path like any other low-urgency notice.
          urgency: 0.3,
          interrupt_now: false,
          body: "#{counterparty_name(todo)} replied — closing that loop on: #{todo.title}."
        }

        case deliver.(candidate) do
          {:ok, _result} ->
            :ok

          {:fallback, _reason} ->
            :ok

          {:error, reason} ->
            Logger.warning("Cross-source completion closing-loop push failed",
              user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
              todo_reference: Maraithon.Redaction.fingerprint(todo.id),
              failure_code: Maraithon.Redaction.error_class(reason)
            )

            :ok
        end
    end
  end

  defp maybe_push_completion_confirmation(_user_id, _todo, _resolution, _opts), do: :ok

  defp counterparty_name(%Todo{counterparty_label: label}) when is_binary(label) do
    case String.trim(label) do
      "" -> "They"
      trimmed -> trimmed
    end
  end

  defp counterparty_name(_todo), do: "They"

  defp evidence_channel_label("gmail"), do: "your email activity"
  defp evidence_channel_label("slack"), do: "your Slack activity"
  defp evidence_channel_label("google_calendar"), do: "your Google Calendar"
  defp evidence_channel_label("local_calendar"), do: "your calendar"
  defp evidence_channel_label("imessage"), do: "a message you sent"
  defp evidence_channel_label("reminders"), do: "your reminders"
  defp evidence_channel_label("notes"), do: "your notes"
  defp evidence_channel_label("files"), do: "your files"
  defp evidence_channel_label("browser_history"), do: "your browser history"
  defp evidence_channel_label("voice_memos"), do: "your voice memos"
  defp evidence_channel_label(_other), do: "your recent activity"

  defp evidence_item(attrs) when is_map(attrs) do
    text = read_string(attrs, "text", nil)
    subject = read_string(attrs, "subject", nil)

    if blank?(text) and blank?(subject) do
      nil
    else
      attrs
      |> Map.update("text", nil, &truncate(&1, @max_excerpt))
      |> Map.update("subject", nil, &truncate(&1, 180))
      |> compact_map()
    end
  end

  defp evidence_item(_attrs), do: nil

  defp evidence_item(attrs, true) when is_map(attrs) do
    text = read_string(attrs, "text", nil)
    subject = read_string(attrs, "subject", nil)

    if blank?(text) and blank?(subject), do: nil, else: compact_map(attrs)
  end

  defp evidence_item(attrs, false), do: evidence_item(attrs)

  defp dedupe_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn item ->
      {
        read_string(item, "channel", nil),
        read_string(item, "source_item_id", nil),
        read_string(item, "target_source_item_id", nil),
        read_string(item, "thread_id", nil),
        read_string(item, "subject", nil),
        read_string(item, "text", nil)
      }
    end)
  end

  defp evidence_sort_key(item) when is_map(item) do
    case item |> read_string("at", nil) |> parse_datetime() do
      %DateTime{} = at -> DateTime.to_unix(at, :microsecond)
      _ -> 0
    end
  end

  defp evidence_sort_key(_item), do: 0

  defp evidence_time(map, keys) when is_map(map) and is_list(keys) do
    keys
    |> Enum.find_value(fn key ->
      map
      |> read_value(key)
      |> normalize_evidence_time()
    end)
  end

  defp evidence_time(_map, _keys), do: nil

  defp normalize_evidence_time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp normalize_evidence_time(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp normalize_evidence_time(%{date: date}), do: normalize_evidence_time(date)
  defp normalize_evidence_time(%{"date" => date}), do: normalize_evidence_time(date)

  defp normalize_evidence_time(value)
       when is_binary(value) and byte_size(value) <= 100 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_iso8601(datetime)

      _invalid_iso8601 ->
        normalize_unix_evidence_time(value)
    end
  end

  defp normalize_evidence_time(_value), do: nil

  defp normalize_unix_evidence_time(value) do
    with true <- Regex.match?(~r/^\d{1,12}(?:\.\d{1,6})?$/, value),
         {seconds, ""} <- Float.parse(value),
         true <- seconds >= 0 and seconds <= 253_402_300_799,
         microseconds <- round(seconds * 1_000_000),
         {:ok, datetime} <- DateTime.from_unix(microseconds, :microsecond) do
      DateTime.to_iso8601(datetime)
    else
      _invalid -> nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp attendee_summary([]), do: nil

  defp attendee_summary(attendees) when is_list(attendees) do
    attendees
    |> Enum.take(12)
    |> Enum.map(fn
      attendee when is_map(attendee) ->
        first_present([
          read_string(attendee, "display_name", nil),
          read_string(attendee, "displayName", nil),
          read_string(attendee, "email", nil)
        ])

      attendee when is_binary(attendee) ->
        attendee

      _other ->
        nil
    end)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      names -> "Attendees: " <> Enum.join(names, ", ")
    end
  end

  defp attendee_summary(_attendees), do: nil

  defp slack_source_item_id(channel_id, ts) when is_binary(channel_id) and is_binary(ts),
    do: "#{channel_id}:#{ts}"

  defp slack_source_item_id(_channel_id, _ts), do: nil

  defp read_list(map, key) when is_map(map) do
    case read_value(map, key) do
      value when is_list(value) -> value
      _other -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp source_evidence_text(map, keys, true) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case exact_string(map, key, nil) do
        value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
        _missing -> nil
      end
    end)
  end

  defp source_evidence_text(map, keys, false) when is_map(map) and is_list(keys) do
    keys
    |> Enum.map(&read_string(map, &1, nil))
    |> first_present()
  end

  defp exact_string(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_binary(value) -> if(String.valid?(value), do: value, else: default)
      _other -> default
    end
  end

  defp exact_string(_map, _key, default), do: default

  defp read_string(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_binary(value) ->
        value
        |> PromptBudget.truncate_utf8(64_000)
        |> String.trim()
        |> case do
          "" -> default
          trimmed -> trimmed
        end

      nil ->
        default

      value when is_atom(value) ->
        value |> Atom.to_string() |> read_string_value(default)

      value when is_integer(value) or is_float(value) ->
        to_string(value)

      _other ->
        default
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_string_value("", default), do: default
  defp read_string_value(value, _default), do: value

  defp read_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp read_value(_map, _key), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find(values, fn
      value when is_binary(value) and byte_size(value) <= 64_000 ->
        String.valid?(value) and String.trim(value) != ""

      value when is_binary(value) ->
        false

      nil ->
        false

      _value ->
        true
    end)
  end

  defp first_present(_values), do: nil

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value) and byte_size(value) <= 16 do
    value
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["true", "yes", "1"]))
  end

  defp truthy?(_value), do: false

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
