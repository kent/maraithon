defmodule Maraithon.Runtime.NudgeSweep do
  @moduledoc """
  The time-based follow-up firing engine (SPEC 01 R4).

  Every discovery cycle finds todos whose moment has arrived — a follow-up cadence
  (`next_nudge_at`) that elapsed, a snooze that expired, a due date that is
  overdue or inside the due-soon horizon — runs one bounded, best-effort LLM
  decision pass per affected user ("is a nudge/resurface appropriate right
  now?"), and enqueues the model-approved moments as `ProactiveCandidate`
  rows through the EXISTING delivery gate (`DeliveryPlanner` →
  `ProactiveQualityGate` → interruption budget → `PushBroker` quiet hours +
  receipt dedupe). It never sends anything directly and never messages a
  counterparty — the outbound nudge stays behind the operator's explicit
  "Send" confirm (`close_or_nudge_todo/3`), which is also the only path that
  may call `Todos.record_nudge_sent/3`.

  Durable recurring discovery enqueues one bounded job per affected tenant.
  The dedicated model/user lane keeps the engine independent from the full
  `AIChiefOfStaff` skill cycle while providing crash recovery, one active job
  per tenant, and starvation-free rotation across tenants.
  """

  import Ecto.Query

  alias Maraithon.AssistantHarness.PromptStability
  alias Maraithon.LLM
  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos
  alias Maraithon.Todos.ActionDrafts
  alias Maraithon.Todos.Todo

  require Logger

  @default_todos_per_user 20
  @default_due_soon_horizon_hours 4
  @default_nudge_cap 4
  @default_llm_timeout_ms 60_000
  # A single tenant pass can return decisions for up to 20 todos, including
  # ready-to-review follow-up drafts. The old 2,048-token budget repeatedly
  # ended otherwise valid provider responses with finish_reason=length.
  @default_max_tokens 4_096
  @max_users_per_cycle 10
  @max_explicit_user_ids 1_000
  @max_todos_per_user 20
  @max_due_soon_horizon_hours 168
  @max_nudge_cap 20
  @max_cycle_ms 120_000
  @max_prompt_bytes 32_000
  @max_prompt_items_bytes 12_000
  @max_response_bytes 128_000
  @max_decisions_scan 100
  @max_decisions 20
  @max_draft_text_bytes 2_000
  @max_next_nudge_at_bytes 100
  @max_decision_attempts 2
  @decision_retry_reserve_ms 15_000
  @minimum_decision_retry_ms 1_000
  @task_shutdown_margin_ms 250

  @open_statuses ~w(open snoozed)

  # A todo can match several reasons at once; the user gets exactly one
  # coherent card per todo per tick, keyed and phrased on the most urgent
  # reason (SPEC 01 edge cases): overdue > nudge-due > due-soon > snooze-expiry.
  @reason_priority %{
    overdue: 0,
    nudge_limit: 1,
    nudge_due: 1,
    due_soon: 2,
    snooze_expiry: 3
  }

  @reason_default_urgency %{
    overdue: 0.75,
    nudge_limit: 0.6,
    nudge_due: 0.6,
    due_soon: 0.65,
    snooze_expiry: 0.55
  }

  @doc """
  Runs one full sweep synchronously (directly callable in tests, no timer).
  """
  def run_once(opts \\ []) do
    {summary, _next_cursor} = do_run_once(opts)
    summary
  end

  defp do_run_once(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    horizon_hours = due_soon_horizon_hours(opts)
    deadline = System.monotonic_time(:millisecond) + @max_cycle_ms

    user_ids =
      case Keyword.get(opts, :user_ids) do
        user_ids when is_list(user_ids) ->
          user_ids
          |> Enum.take(@max_explicit_user_ids)
          |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_280))
          |> Enum.uniq()
          |> Enum.take(@max_users_per_cycle)

        _other ->
          select_due_user_ids(now, horizon_hours, Keyword.get(opts, :after_user_id))
      end

    empty = %{
      users: length(user_ids),
      checked: 0,
      proposed: 0,
      held: 0,
      cadence_updates: 0,
      skipped: 0,
      errors: 0
    }

    bounded_opts = Keyword.put(opts, :deadline_monotonic_ms, deadline)

    {summary, last_attempted} =
      user_ids
      |> Enum.with_index()
      |> Enum.reduce_while({empty, nil}, fn {user_id, index}, {acc, last} ->
        if System.monotonic_time(:millisecond) >= deadline do
          unattempted = length(user_ids) - index
          {:halt, {%{acc | skipped: acc.skipped + unattempted}, last}}
        else
          next =
            case run_for_user(user_id, bounded_opts) do
              %{} = result ->
                %{
                  acc
                  | checked: acc.checked + result.checked,
                    proposed: acc.proposed + result.proposed,
                    held: acc.held + result.held,
                    cadence_updates: acc.cadence_updates + result.cadence_updates
                }

              {:skip, _reason} ->
                %{acc | skipped: acc.skipped + 1}

              {:error, _reason} ->
                %{acc | errors: acc.errors + 1}
            end

          {:cont, {next, user_id}}
        end
      end)

    {summary, last_attempted}
  end

  @doc "Returns the next bounded, cursor-rotated page of due tenants."
  def due_user_ids(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    horizon_hours = due_soon_horizon_hours(opts)
    select_due_user_ids(now, horizon_hours, Keyword.get(opts, :after_user_id))
  end

  @doc """
  Runs the decision pass for one user. Returns a count map, `{:skip, reason}`
  when nothing is due, or `{:error, reason}` when the model call fails.
  Tests may inject `:llm_complete` as a one-arity function.
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    horizon_hours = due_soon_horizon_hours(opts)

    nudge_cap =
      opts
      |> Keyword.get(:nudge_cap)
      |> positive_integer(@default_nudge_cap)
      |> min(@max_nudge_cap)

    todos = due_todos(user_id, now, horizon_hours, opts)

    case todos do
      [] ->
        {:skip, :none_due}

      todos ->
        timezone_context = Todos.user_timezone_context(user_id)
        reasons = Map.new(todos, fn todo -> {todo.id, todo_reason(todo, now, nudge_cap)} end)

        case decide(user_id, todos, reasons, now, timezone_context, opts) do
          {:ok, decisions} ->
            apply_decisions(user_id, todos, reasons, decisions, now, timezone_context)

          {:error, reason} ->
            Logger.warning("Nudge sweep decision pass failed",
              user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
              checked: length(todos),
              failure_code: Maraithon.Redaction.error_class(reason)
            )

            {:error, reason}
        end
    end
  rescue
    error ->
      failure_code = Maraithon.Redaction.error_class(error)

      Logger.warning("Nudge sweep user pass crashed",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: failure_code
      )

      {:error, failure_code}
  end

  # ── Selection ─────────────────────────────────────────────────────────────

  # A bounded lexical cursor rotates due users across cycles without scanning
  # the full tenant set or permanently starving IDs beyond the first page.
  defp select_due_user_ids(now, horizon_hours, after_user_id) do
    horizon_end = DateTime.add(now, horizon_hours * 3_600, :second)
    query = due_user_query(now, horizon_end)

    cursor =
      if is_binary(after_user_id) and byte_size(after_user_id) <= 1_280,
        do: after_user_id,
        else: nil

    first_page =
      query
      |> maybe_after_user(cursor)
      |> order_by([todo], asc: todo.user_id)
      |> limit(^@max_users_per_cycle)
      |> Repo.all()

    remaining = @max_users_per_cycle - length(first_page)

    if remaining > 0 and is_binary(cursor) do
      wrap_page =
        query
        |> where([todo], todo.user_id <= ^cursor)
        |> order_by([todo], asc: todo.user_id)
        |> limit(^remaining)
        |> Repo.all()

      first_page ++ wrap_page
    else
      first_page
    end
  end

  defp due_user_query(now, horizon_end) do
    from(t in Todo,
      where: t.status in @open_statuses,
      where:
        (t.direction == "owed_to_me" and not is_nil(t.next_nudge_at) and
           t.next_nudge_at <= ^now) or
          (t.status == "snoozed" and not is_nil(t.snoozed_until) and
             t.snoozed_until <= ^now) or
          (not is_nil(t.due_at) and t.due_at <= ^horizon_end and
             (t.status == "open" or
                (not is_nil(t.snoozed_until) and t.snoozed_until <= ^now))),
      distinct: true,
      select: t.user_id
    )
  end

  defp maybe_after_user(query, nil), do: query
  defp maybe_after_user(query, cursor), do: where(query, [todo], todo.user_id > ^cursor)

  defp due_todos(user_id, now, horizon_hours, opts) do
    horizon_end = DateTime.add(now, horizon_hours * 3600, :second)

    todo_limit =
      opts
      |> Keyword.get(:todos_per_user)
      |> positive_integer(@default_todos_per_user)
      |> min(@max_todos_per_user)

    Repo.all(
      from(t in Todo,
        where: t.user_id == ^user_id,
        where: t.status in @open_statuses,
        # A due/overdue todo only fires while it is open or its snooze
        # has elapsed — snoozing a past-due todo must actually silence it.
        where:
          (t.direction == "owed_to_me" and not is_nil(t.next_nudge_at) and
             t.next_nudge_at <= ^now) or
            (t.status == "snoozed" and not is_nil(t.snoozed_until) and
               t.snoozed_until <= ^now) or
            (not is_nil(t.due_at) and t.due_at <= ^horizon_end and
               (t.status == "open" or
                  (not is_nil(t.snoozed_until) and t.snoozed_until <= ^now))),
        order_by: [asc_nulls_last: t.due_at, asc: t.inserted_at],
        limit: ^todo_limit
      )
    )
  end

  defp todo_reason(%Todo{} = todo, now, nudge_cap) do
    nudge_count = todo.nudge_count || 0

    nudge_due? =
      todo.direction == "owed_to_me" and match?(%DateTime{}, todo.next_nudge_at) and
        DateTime.compare(todo.next_nudge_at, now) != :gt

    cond do
      match?(%DateTime{}, todo.due_at) and DateTime.compare(todo.due_at, now) != :gt ->
        :overdue

      nudge_due? and nudge_count >= nudge_cap ->
        # Anti-nag cap (SPEC 01 R7): after N sends without a reply, stop
        # proposing more nudges and surface a one-time decision instead.
        :nudge_limit

      nudge_due? ->
        :nudge_due

      match?(%DateTime{}, todo.due_at) ->
        :due_soon

      todo.status == "snoozed" and match?(%DateTime{}, todo.snoozed_until) and
          DateTime.compare(todo.snoozed_until, now) != :gt ->
        :snooze_expiry

      true ->
        :snooze_expiry
    end
  end

  # ── Decision (bounded, best-effort LLM pass) ──────────────────────────────

  defp decide(_user_id, todos, reasons, now, timezone_context, opts) do
    prompt = build_prompt(todos, reasons, now, timezone_context)

    configured_timeout =
      opts
      |> Keyword.get(:llm_timeout_ms)
      |> positive_integer(@default_llm_timeout_ms)
      |> min(@default_llm_timeout_ms)

    deadline =
      case Keyword.get(opts, :deadline_monotonic_ms) do
        value when is_integer(value) -> value
        _other -> System.monotonic_time(:millisecond) + @max_cycle_ms
      end

    decision_deadline =
      min(deadline, System.monotonic_time(:millisecond) + configured_timeout)

    allowed_ids = MapSet.new(todos, & &1.id)

    cond do
      decision_deadline <= System.monotonic_time(:millisecond) ->
        {:error, :nudge_sweep_deadline}

      prompt_message_bytes(prompt) > @max_prompt_bytes ->
        {:error, :nudge_sweep_prompt_too_large}

      true ->
        decide_with_retry(prompt, allowed_ids, opts, decision_deadline, 1)
    end
  end

  defp decide_with_retry(prompt, allowed_ids, opts, deadline, attempt) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)
    timeout_ms = decision_attempt_timeout(remaining_ms, attempt)

    result = decision_attempt(prompt, allowed_ids, opts, timeout_ms)

    if retry_decision?(result, attempt, deadline) do
      {:error, reason} = result

      Logger.info("Retrying nudge sweep decision pass",
        attempt: attempt,
        failure_code: Maraithon.Redaction.error_class(reason)
      )

      decide_with_retry(prompt, allowed_ids, opts, deadline, attempt + 1)
    else
      result
    end
  end

  defp decision_attempt(prompt, allowed_ids, opts, timeout_ms) when timeout_ms > 0 do
    provider_timeout_ms = max(timeout_ms - @task_shutdown_margin_ms, 1)

    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        try do
          {:ok, complete_decision(prompt, opts, provider_timeout_ms)}
        rescue
          exception -> {:error, Maraithon.Redaction.error_class(exception)}
        catch
          kind, _reason -> {:error, to_string(kind)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {:ok, response}}} -> decode_response(response, allowed_ids)
      {:ok, {:ok, {:error, reason}}} -> {:error, closed_llm_failure(reason)}
      {:ok, {:ok, _other}} -> {:error, :unexpected_llm_result}
      {:ok, {:error, failure_code}} -> {:error, {:llm_task_failed, failure_code}}
      {:exit, _reason} -> {:error, :llm_task_exit}
      nil -> {:error, {:llm_timeout, timeout_ms}}
    end
  end

  defp decision_attempt(_prompt, _allowed_ids, _opts, _timeout_ms),
    do: {:error, :nudge_sweep_deadline}

  defp complete_decision(prompt, opts, timeout_ms) do
    case Keyword.get(opts, :llm_complete) do
      complete when is_function(complete, 1) -> complete.(prompt)
      _other -> default_llm_complete(prompt, Keyword.put(opts, :llm_timeout_ms, timeout_ms))
    end
  end

  defp retry_decision?({:error, reason}, attempt, deadline) do
    attempt < @max_decision_attempts and
      deadline - System.monotonic_time(:millisecond) >= @minimum_decision_retry_ms and
      retryable_decision_failure?(reason)
  end

  defp retry_decision?(_result, _attempt, _deadline), do: false

  defp retryable_decision_failure?(:nudge_sweep_invalid_response), do: true
  defp retryable_decision_failure?(reason), do: LLM.transient_failure?(reason)

  defp decision_attempt_timeout(remaining_ms, 1)
       when remaining_ms >= @decision_retry_reserve_ms + @minimum_decision_retry_ms,
       do: remaining_ms - @decision_retry_reserve_ms

  defp decision_attempt_timeout(remaining_ms, _attempt), do: remaining_ms

  # Keep local/provider backpressure typed so PeriodicJobs can durably defer it
  # without spending the job's retry budget. Collapse every other provider
  # response to a closed atom before it reaches logs or durable error fields.
  defp closed_llm_failure({:llm_busy, retry_after_ms} = reason)
       when is_integer(retry_after_ms) and retry_after_ms >= 0,
       do: reason

  defp closed_llm_failure({:rate_limited, retry_after_ms} = reason)
       when is_integer(retry_after_ms) and retry_after_ms >= 0,
       do: reason

  defp closed_llm_failure({:rate_limited, retry_after_seconds, _detail} = reason)
       when is_integer(retry_after_seconds) and retry_after_seconds >= 0,
       do: reason

  defp closed_llm_failure({kind, _detail})
       when kind in [
              :content_filtered,
              :incomplete_response,
              :insufficient_quota,
              :invalid_request,
              :invalid_response,
              :network_error,
              :provider_error,
              :provider_refusal
            ],
       do: kind

  defp closed_llm_failure({:api_error, status, _detail}) when status in 500..599,
    do: {:api_error, status}

  defp closed_llm_failure({:api_error, _status, _detail}), do: :api_error
  defp closed_llm_failure(:timeout), do: :llm_timeout
  defp closed_llm_failure(:rate_limited), do: :rate_limited
  defp closed_llm_failure(_reason), do: :llm_call_failed

  defp build_prompt(todos, reasons, now, timezone_context) do
    items =
      Enum.map(todos, fn todo ->
        reason = Map.fetch!(reasons, todo.id)

        %{
          "todo_id" => bounded_text(todo.id, 255),
          "reason" => reason_label(reason),
          "direction" => bounded_text(todo.direction, 50),
          "status" => bounded_text(todo.status, 50),
          "title" => bounded_text(todo.title, 500),
          "summary" => bounded_text(todo.summary, 1_200),
          "next_action" => bounded_text(todo.next_action, 800),
          "counterparty" => bounded_text(todo.counterparty_label, 255),
          "nudge_count" => todo.nudge_count || 0,
          "due_at_local" => local_label(todo.due_at, timezone_context),
          "snoozed_until_local" => local_label(todo.snoozed_until, timezone_context),
          "last_nudged_at_local" => local_label(todo.last_nudged_at, timezone_context),
          "follow_up_was_scheduled_for_local" =>
            local_label(todo.next_nudge_at, timezone_context),
          "captured_at_local" =>
            local_label(todo.source_occurred_at || todo.inserted_at, timezone_context),
          "days_waiting" => days_between(todo.source_occurred_at || todo.inserted_at, now)
        }
        |> compact_map()
      end)
      |> PromptBudget.bounded(@max_prompt_items_bytes,
        string_bytes: 1_200,
        list_items: @max_todos_per_user,
        map_entries: 20,
        max_depth: 3,
        key_bytes: 64
      )
      |> case do
        list when is_list(list) -> list
        _other -> []
      end

    """
    You are the follow-up timing decider for a chief-of-staff product. Each
    item below is due RIGHT NOW for one of these reasons:
    - follow_up_due: the operator is waiting on someone (owed_to_me) and the scheduled follow-up moment arrived.
    - follow_up_limit_reached: #{@default_nudge_cap}+ nudges already went out with no reply — propose a one-time keep-chasing / snooze / drop decision, not another routine nudge.
    - overdue / due_soon: a hard deadline passed or is within a few hours (any direction).
    - snooze_expired: the operator snoozed this and the snooze elapsed.

    Decide, per item, whether to surface it to the operator right now.
    Rules:
    - Bias to HOLD. If the counterparty likely already replied since capture,
      or you cannot tell, or the item looks stale/irrelevant, do not surface it —
      nudging someone who already answered damages trust.
    - You are only proposing the moment to the operator. Nothing you return is
      ever sent to the counterparty; the operator confirms every send.
    - For a surfaced item write a short title and a why-now body the operator
      can act on immediately (who, waiting since when, what to do). Address
      the operator as "you".
    - For a surfaced follow_up_due item also write draft_text: concise
      suggested follow-up wording in the operator's voice to the counterparty.
    - For a follow_up_due item you HOLD, set next_nudge_at to the ISO-8601
      datetime when the follow-up should be re-checked instead (size it to the
      counterparty/urgency; omit it to leave the schedule unchanged).
    - All *_local timestamps below are already in the operator's local time.

    CURRENT_LOCAL_TIME: #{local_label(now, timezone_context)}

    DUE_ITEMS_JSON:
    #{Jason.encode!(items)}

    Respond with only this JSON shape, no prose:
    {
      "decisions": [
        {
          "todo_id": "uuid",
          "surface": true,
          "title": "short card title",
          "body": "why-now text the operator sees",
          "urgency": 0.0,
          "why_now": "one short sentence",
          "draft_text": "suggested follow-up wording, or omitted",
          "next_nudge_at": "ISO-8601 datetime, only when surface=false for follow_up_due"
        }
      ]
    }
    Return {"decisions": []} to hold everything.
    """
  end

  defp prompt_message_bytes(prompt) when is_binary(prompt) do
    [%{"role" => "user", "content" => prompt}]
    |> PromptStability.encode!()
    |> byte_size()
  end

  defp reason_label(:nudge_due), do: "follow_up_due"
  defp reason_label(:nudge_limit), do: "follow_up_limit_reached"
  defp reason_label(:overdue), do: "overdue"
  defp reason_label(:due_soon), do: "due_soon"
  defp reason_label(:snooze_expiry), do: "snooze_expired"

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    prompt
    |> decision_request_params(opts)
    |> LLM.complete()
  end

  @doc false
  def decision_request_params(prompt, opts \\ [])

  def decision_request_params(prompt, opts) when is_binary(prompt) and is_list(opts) do
    config = Application.get_env(:maraithon, :todos, [])

    %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" =>
        opts
        |> Keyword.get(:max_tokens)
        |> positive_integer(@default_max_tokens)
        |> min(4_096),
      "temperature" => 0.1,
      "reasoning_effort" =>
        config
        |> Keyword.get(:reasoning_effort, "none")
        |> bounded_reasoning_effort(),
      "timeout_ms" =>
        opts
        |> Keyword.get(:llm_timeout_ms)
        |> positive_integer(@default_llm_timeout_ms)
        |> min(@default_llm_timeout_ms)
    }
  end

  defp decode_response(response, allowed_ids) when is_struct(allowed_ids, MapSet) do
    content =
      case response do
        %{"content" => content} when is_binary(content) -> content
        %{content: content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _other -> nil
      end

    with content when is_binary(content) and byte_size(content) <= @max_response_bytes <- content,
         json when is_binary(json) <- extract_json(content),
         {:ok, %{"decisions" => decisions}} when is_list(decisions) <- Jason.decode(json) do
      decisions =
        decisions
        |> Enum.take(@max_decisions_scan)
        |> Enum.reduce({[], MapSet.new()}, fn decision, {selected, seen} ->
          todo_id = if is_map(decision), do: decision["todo_id"]

          cond do
            length(selected) >= @max_decisions ->
              {selected, seen}

            not is_binary(todo_id) or byte_size(todo_id) > 255 ->
              {selected, seen}

            not MapSet.member?(allowed_ids, todo_id) or MapSet.member?(seen, todo_id) ->
              {selected, seen}

            true ->
              {[normalize_decision(decision) | selected], MapSet.put(seen, todo_id)}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      {:ok, decisions}
    else
      _other -> {:error, :nudge_sweep_invalid_response}
    end
  end

  defp normalize_decision(decision) do
    %{
      "todo_id" => decision["todo_id"],
      "surface" => decision["surface"] == true,
      "title" => bounded_text(decision["title"], 800),
      "body" => bounded_text(decision["body"], 4_000),
      "why_now" => bounded_text(decision["why_now"], 1_000),
      "draft_text" => bounded_text(decision["draft_text"], @max_draft_text_bytes),
      "next_nudge_at" => bounded_text(decision["next_nudge_at"], @max_next_nudge_at_bytes),
      "urgency" => bounded_urgency_value(decision["urgency"])
    }
  end

  defp bounded_urgency_value(value) when is_float(value) and value >= 0.0 and value <= 1.0,
    do: value

  defp bounded_urgency_value(value) when is_integer(value) and value in 0..1, do: value
  defp bounded_urgency_value(_value), do: nil

  defp extract_json(content) do
    with {start, _length} <- :binary.match(content, "{"),
         [_ | _] = closers <- :binary.matches(content, "}") do
      {finish, _length} = List.last(closers)
      binary_part(content, start, finish - start + 1)
    else
      _other -> nil
    end
  end

  # ── Apply (runtime enforcement) ───────────────────────────────────────────

  defp apply_decisions(user_id, todos, reasons, decisions, now, timezone_context) do
    todos_by_id = Map.new(todos, &{&1.id, &1})

    cadence_updates =
      Enum.count(decisions, fn decision ->
        apply_cadence_update(user_id, todos_by_id, reasons, decision, now, timezone_context)
      end)

    surfaced =
      decisions
      |> Enum.filter(&(&1["surface"] == true))
      |> Enum.flat_map(fn decision ->
        with todo_id when is_binary(todo_id) <- decision["todo_id"],
             %Todo{} = todo <- Map.get(todos_by_id, todo_id),
             # Snooze re-open race guard: re-check status at the moment the
             # candidate is about to be enqueued, not just at query time —
             # never resurrect a todo the completion sweeps closed meanwhile.
             %Todo{status: status} = fresh <- Todos.get_for_user(user_id, todo_id),
             true <- status in @open_statuses do
          [%{todo: fresh, reason: Map.fetch!(reasons, todo.id), decision: decision}]
        else
          _other -> []
        end
      end)

    Enum.each(surfaced, fn %{todo: todo, reason: reason, decision: decision} ->
      maybe_refresh_action_draft(user_id, todo, reason, decision, now)
    end)

    proposed =
      surfaced
      |> bundle_by_counterparty()
      |> Enum.count(fn bundle -> enqueue_bundle(user_id, bundle, now, timezone_context) end)

    # Held is implicit: a missing decision or surface=false simply enqueues
    # nothing this tick (bias-to-hold) — the item re-enters selection on the
    # next tick unless the model re-armed its cadence above.
    %{
      checked: length(todos),
      proposed: proposed,
      held: length(todos) - length(surfaced),
      cadence_updates: cadence_updates
    }
  end

  # Model held a follow_up_due item and proposed the next check-in moment.
  # Runtime validates: owed_to_me only, still open, strictly in the future,
  # coerced through the same lenient timezone-aware parser as ingest.
  defp apply_cadence_update(user_id, todos_by_id, reasons, decision, now, timezone_context) do
    with false <- decision["surface"] == true,
         todo_id when is_binary(todo_id) <- decision["todo_id"],
         %Todo{direction: "owed_to_me"} <- Map.get(todos_by_id, todo_id),
         :nudge_due <- Map.get(reasons, todo_id),
         raw when not is_nil(raw) <- decision["next_nudge_at"],
         %DateTime{} = next_nudge_at <-
           Todos.parse_flexible_datetime(raw, timezone_context || user_id),
         :gt <- DateTime.compare(next_nudge_at, now) do
      next_nudge_at = DateTime.truncate(next_nudge_at, :second)
      stamped_at = DateTime.truncate(now, :second)

      {count, _rows} =
        Todo
        |> where(
          [todo],
          todo.id == ^todo_id and todo.user_id == ^user_id and
            todo.direction == "owed_to_me" and todo.status in @open_statuses
        )
        |> Repo.update_all(set: [next_nudge_at: next_nudge_at, updated_at: stamped_at])

      count == 1
    else
      _other -> false
    end
  end

  # SPEC 01 R4: a surfaced follow-up card must be able to offer "Send", not
  # just "Draft" — refresh the todo's draft with the model's wording, but
  # only over an absent/write-boundary-generic draft, never over real
  # prepared material.
  defp maybe_refresh_action_draft(user_id, %Todo{} = todo, reason, decision, now)
       when reason in [:nudge_due, :nudge_limit] do
    draft_text = decision["draft_text"]

    if is_binary(draft_text) and String.trim(draft_text) != "" and
         not real_draft_present?(todo) do
      draft = %{
        "kind" => "message",
        "label" => "Follow-up nudge draft",
        "text" => String.trim(draft_text),
        "source" => "nudge_sweep",
        "style" => "counterparty_nudge",
        "channel" => todo.source
      }

      Todo
      |> where([t], t.id == ^todo.id and t.user_id == ^user_id)
      |> Repo.update_all(set: [action_draft: draft, updated_at: DateTime.truncate(now, :second)])

      :ok
    else
      :ok
    end
  end

  defp maybe_refresh_action_draft(_user_id, _todo, _reason, _decision, _now), do: :ok

  defp real_draft_present?(%Todo{action_draft: draft}) when is_map(draft) do
    text = ActionDrafts.preview(draft)

    generic? =
      Map.get(draft, "kind") == "next_step" or Map.get(draft, "source") == "todo_write_boundary"

    is_binary(text) and String.trim(text) != "" and not generic?
  end

  defp real_draft_present?(_todo), do: false

  # Per-counterparty cap (SPEC 01 R7): several due todos waiting on the same
  # person in one tick become one proposed candidate, not one card each.
  defp bundle_by_counterparty(surfaced) do
    surfaced
    |> Enum.group_by(fn %{todo: todo} -> counterparty_group_key(todo) end)
    |> Map.values()
    |> Enum.map(fn members ->
      Enum.sort_by(members, fn %{todo: todo, reason: reason} ->
        {Map.fetch!(@reason_priority, reason), due_sort_value(todo)}
      end)
    end)
  end

  defp counterparty_group_key(%Todo{} = todo) do
    person_id = bounded_text(todo.counterparty_person_id, 255)
    label = bounded_text(todo.counterparty_label, 255)

    cond do
      is_binary(person_id) and person_id != "" -> {:person, person_id}
      is_binary(label) and label != "" -> {:label, String.downcase(label)}
      true -> {:todo, todo.id}
    end
  end

  defp due_sort_value(%Todo{due_at: %DateTime{} = due_at}), do: DateTime.to_unix(due_at, :second)
  defp due_sort_value(_todo), do: 9_999_999_999

  defp enqueue_bundle(user_id, [primary | rest] = _bundle, now, timezone_context) do
    %{todo: todo, reason: reason, decision: decision} = primary
    todo_ids = [todo.id | Enum.map(rest, & &1.todo.id)]

    title =
      decision["title"]
      |> presence()
      |> Kernel.||(default_title(todo, reason))
      |> truncate(200)

    body =
      decision["body"]
      |> presence()
      |> Kernel.||(todo.next_action || todo.summary || title)
      |> append_bundle_note(rest)
      |> truncate(4_000)

    attrs = %{
      user_id: user_id,
      source: "nudge",
      source_id: todo.id,
      dedupe_key: dedupe_key(todo, reason, now, timezone_context),
      title: title,
      body: body,
      urgency: clamp_urgency(decision["urgency"], Map.fetch!(@reason_default_urgency, reason)),
      why_now: decision["why_now"] |> presence() |> truncate(1_000),
      structured_data: %{
        "todo_ids" => todo_ids,
        "message_class" => "todo_digest",
        "nudge_reason" => reason_label(reason)
      }
    }

    case ProactiveQueue.enqueue(attrs) do
      {:ok, _candidate} ->
        true

      {:error, reason_error} ->
        # Ids/field-names only — never inspect a full changeset here, its
        # `changes` would put todo summary/body content into the logs.
        Logger.warning("Nudge sweep could not enqueue candidate",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          todo_reference: Maraithon.Redaction.fingerprint(todo.id),
          nudge_reason: reason_label(reason),
          failure_code: enqueue_error_summary(reason_error)
        )

        false
    end
  end

  defp enqueue_error_summary(%Ecto.Changeset{errors: errors}) do
    "invalid_candidate:#{errors |> Keyword.keys() |> Enum.map_join(",", &to_string/1)}"
  end

  defp enqueue_error_summary(other), do: Maraithon.Redaction.error_class(other)

  defp append_bundle_note(body, []), do: body

  defp append_bundle_note(body, rest) do
    titles =
      rest
      |> Enum.map(fn %{todo: todo} -> "- #{bounded_text(todo.title, 255) || "Untitled"}" end)
      |> Enum.join("\n")

    body <> "\n\nAlso due with the same person:\n" <> titles
  end

  defp default_title(%Todo{} = todo, :nudge_limit) do
    "No reply after #{todo.nudge_count || 0} nudges — keep chasing, snooze, or drop it?"
  end

  defp default_title(%Todo{} = todo, _reason), do: todo.title

  # Dedupe key design (SPEC 01 R4): the key changes only when the underlying
  # reason changes. Nudge-due keys are keyed on nudge_count (advances only
  # when a real send goes out via record_nudge_sent/3); horizon-based reasons
  # are bucketed on the LOCAL calendar day so they fire at most once per day
  # per todo. Never a raw timestamp — that would defeat dedupe entirely.
  defp dedupe_key(%Todo{} = todo, :nudge_due, _now, _timezone_context) do
    "nudge:#{todo.id}:nudge_due:#{todo.nudge_count || 0}"
  end

  defp dedupe_key(%Todo{} = todo, :nudge_limit, _now, _timezone_context) do
    "nudge:#{todo.id}:nudge_limit:#{todo.nudge_count || 0}"
  end

  defp dedupe_key(%Todo{} = todo, reason, now, timezone_context)
       when reason in [:overdue, :due_soon, :snooze_expiry] do
    "nudge:#{todo.id}:#{reason}:#{Date.to_iso8601(local_today(now, timezone_context))}"
  end

  defp local_today(now, timezone_context) do
    offset =
      case timezone_context do
        %{offset_hours: offset} when is_integer(offset) -> offset
        _other -> 0
      end

    Todos.brief_local_date(now, offset)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp local_label(nil, _timezone_context), do: nil

  defp local_label(%DateTime{} = datetime, timezone_context) do
    offset =
      case timezone_context do
        %{offset_hours: offset} when is_integer(offset) -> offset
        _other -> 0
      end

    local = DateTime.add(datetime, offset, :hour)
    label = if offset >= 0, do: "UTC+#{offset}", else: "UTC#{offset}"

    "#{Calendar.strftime(local, "%Y-%m-%d %H:%M")} local (#{label})"
  end

  defp days_between(%DateTime{} = from, %DateTime{} = to) do
    div(max(DateTime.diff(to, from, :second), 0), 86_400)
  end

  defp days_between(_from, _to), do: nil

  defp due_soon_horizon_hours(opts) do
    positive_integer(
      Keyword.get(
        opts,
        :due_soon_horizon_hours,
        Config.positive_integer(
          :nudge_sweep_due_soon_horizon_hours,
          @default_due_soon_horizon_hours
        )
      ),
      @default_due_soon_horizon_hours
    )
    |> min(@max_due_soon_horizon_hours)
  end

  defp clamp_urgency(value, _default) when is_float(value), do: value |> max(0.0) |> min(1.0)

  defp clamp_urgency(value, default) when is_integer(value),
    do: clamp_urgency(value / 1, default)

  defp clamp_urgency(_value, default), do: default

  defp presence(value) when is_binary(value), do: bounded_text(value, 4_000)
  defp presence(_value), do: nil

  defp truncate(nil, _max_bytes), do: nil
  defp truncate(text, max_bytes), do: bounded_text(text, max_bytes)

  defp bounded_text(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 do
    text
    |> PromptBudget.truncate_utf8(max_bytes)
    |> String.trim()
    |> case do
      "" -> nil
      bounded -> bounded
    end
  end

  defp bounded_text(_text, _max_bytes), do: nil

  defp bounded_reasoning_effort(value) when value in ["none", "minimal", "low", "medium", "high"],
    do: value

  defp bounded_reasoning_effort(_value), do: "none"

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
