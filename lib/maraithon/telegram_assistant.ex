defmodule Maraithon.TelegramAssistant do
  @moduledoc """
  System-owned Telegram assistant runtime, persistence, and broker entrypoints.
  """

  import Ecto.Query

  alias Maraithon.LLM
  alias Maraithon.Repo

  alias Maraithon.TelegramAssistant.{
    ActionFailureCopy,
    LivenessSession,
    LivenessSupervisor,
    BriefTodoReview,
    PreparedAction,
    Proactive,
    ProactiveQueue,
    PushBroker,
    PushReceipt,
    Run,
    Runner,
    Step,
    TodoActions
  }

  alias Maraithon.AssistantChat.SecretRequestGuard
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.{PublicPayload, Todo, UserFacingCopy}

  # SPEC 05 R4: prepared-action types that represent an actual follow-up
  # message being sent on behalf of a todo (see
  # Maraithon.AssistantChat.TodoThreadPrimer, which stamps payload["todo_id"]
  # when a gmail/slack draft is prepared from a todo chat thread).
  @nudge_action_types ~w(gmail_send gmail_draft_send slack_post)
  @prepared_execution_result_key "_maraithon_execution_result"
  @prepared_execution_error_key "_maraithon_execution_error"
  @prepared_result_delivered_at_key "_maraithon_result_delivered_at"
  @prepared_execution_attempts_key "_maraithon_execution_attempts"
  @prepared_execution_token_key "_maraithon_execution_token"
  @prepared_execution_lease_until_key "_maraithon_execution_lease_until"
  @prepared_execution_reclaimable_key "_maraithon_execution_reclaimable"
  @prepared_confirmed_payload_hash_key "_maraithon_confirmed_payload_sha256"
  @prepared_result_delivery_state_key "_maraithon_result_delivery_state"
  @prepared_result_delivery_token_key "_maraithon_result_delivery_token"
  @prepared_result_delivery_lease_until_key "_maraithon_result_delivery_lease_until"
  @prepared_result_delivery_attempts_key "_maraithon_result_delivery_attempts"
  @prepared_result_delivery_error_key "_maraithon_result_delivery_error"

  # These are the only payload fields that the execution/delivery protocols
  # mutate after confirmation. Every other field, including execution-affecting
  # `_maraithon_*` instructions, remains covered by the frozen payload hash.
  @prepared_mutable_runtime_payload_keys [
    @prepared_execution_result_key,
    @prepared_execution_error_key,
    @prepared_result_delivered_at_key,
    @prepared_execution_attempts_key,
    @prepared_execution_token_key,
    @prepared_execution_lease_until_key,
    # Read and cleared for rows claimed by the previous protocol, but never
    # trusted as permission to reclaim an expired mutation owner.
    @prepared_execution_reclaimable_key,
    @prepared_confirmed_payload_hash_key,
    @prepared_result_delivery_state_key,
    @prepared_result_delivery_token_key,
    @prepared_result_delivery_lease_until_key,
    @prepared_result_delivery_attempts_key,
    @prepared_result_delivery_error_key
  ]

  @prepared_error_max_bytes 240
  @ambiguous_http_error_classes ["unknown_error", "Elixir.Req.TransportError"]
  @default_prepared_action_max_attempts 3
  @default_prepared_execution_lease_seconds 60
  @default_prepared_execution_heartbeat_ms 5_000
  @default_prepared_persistence_timeout_ms 5_000
  @prepared_result_delivery_lease_seconds 60

  # Only these actions have a provider key or exact durable evidence that lets
  # this owner reconcile/replay after it has observed its provider task finish.
  # This never permits reclaiming expired ownership while the old task may live.
  # Everything else is conservative after an ambiguous provider boundary.
  @replay_safe_prepared_action_types ~w(
    project_create project_update
    calendar_create_event calendar_update_event calendar_cancel_event
    linear_update_issue_state
    notaui_complete_task notaui_update_task
    agent_update agent_delete
  )

  require Logger

  @default_confirmation_window_seconds 15 * 60
  @default_typing_initial_delay_ms 1_200
  @default_typing_refresh_ms 4_000
  @default_contextual_progress_delay_ms 7_000
  @default_timeout_notice_ms 35_000
  @default_hard_timeout_ms 40_000

  def enabled? do
    config = config()

    case Keyword.get(config, :telegram_full_chat_enabled) do
      true -> true
      false -> false
      nil -> default_enabled?(config)
    end
  end

  def unified_push_enabled? do
    config = config()

    case Keyword.get(config, :telegram_unified_push_enabled) do
      true ->
        true

      false ->
        false

      # Mobile pushes do not depend on the Telegram chat switch or which LLM
      # provider powers chat. Keep an explicit broker opt-out authoritative.
      nil ->
        enabled?() or
          (Maraithon.Push.Notifier.enabled?() and Maraithon.Push.APNS.configured?())
    end
  end

  @doc false
  def unified_push_explicitly_disabled? do
    Keyword.get(config(), :telegram_unified_push_enabled) == false
  end

  def proactive_delivery_planner_enabled? do
    case Keyword.get(config(), :proactive_delivery_planner_enabled) do
      true -> true
      false -> false
      nil -> true
      value when is_binary(value) -> String.downcase(String.trim(value)) in ~w(true 1 yes)
      _value -> false
    end
  end

  def write_tools_enabled? do
    case Keyword.get(config(), :telegram_assistant_write_tools_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def agent_control_enabled? do
    case Keyword.get(config(), :telegram_agent_control_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def client_module do
    Keyword.get(config(), :client_module, Maraithon.TelegramAssistant.Client.LLMJson)
  end

  def handle_inbound(attrs) when is_map(attrs) do
    if enabled?() do
      case maybe_handle_secret_request(attrs) do
        :ok ->
          :ok

        :pass ->
          case BriefTodoReview.handle_text_request(attrs) do
            :ok -> :ok
            :ignored -> Runner.run_inbound(attrs)
          end
      end
    else
      {:fallback, :disabled}
    end
  end

  defp maybe_handle_secret_request(attrs) do
    case SecretRequestGuard.reply(attrs) do
      {:ok, text, structured_data} ->
        send_secret_guard_reply(attrs, text, structured_data)

      :pass ->
        :pass
    end
  end

  defp send_secret_guard_reply(
         %{conversation: %Conversation{} = conversation, chat_id: chat_id} = attrs,
         text,
         structured_data
       )
       when is_binary(chat_id) do
    case send_turn(conversation, chat_id, text,
           reply_to_message_id: Map.get(attrs, :source_message_id),
           intent: "credential_disclosure_guard",
           confidence: 1.0,
           turn_kind: "assistant_reply",
           origin_type: "system",
           structured_data: structured_data
         ) do
      {:ok, _conversation, _turn, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
      other -> {:error, {:invalid_telegram_send_result, other}}
    end
  end

  defp send_secret_guard_reply(_attrs, _text, _structured_data),
    do: {:error, :invalid_secret_guard_reply}

  def handle_callback_query(data) when is_map(data) do
    cond do
      not enabled?() ->
        :ignored

      not is_binary(read_string(data, "data")) ->
        :ignored

      true ->
        handle_assistant_callback(data, read_string(data, "data"))
    end
  end

  def handle_text_confirmation(
        conversation,
        user_turn,
        chat_id,
        reply_to_message_id,
        decision
      ) do
    handle_text_confirmation(
      conversation,
      user_turn,
      chat_id,
      reply_to_message_id,
      decision,
      []
    )
  end

  def handle_text_confirmation(
        %Conversation{} = conversation,
        user_turn,
        chat_id,
        reply_to_message_id,
        decision,
        opts
      )
      when decision in [:confirm, :reject] and is_list(opts) do
    case latest_prepared_action(conversation) do
      %PreparedAction{} = prepared_action ->
        respond_to_prepared_action(
          prepared_action,
          decision,
          conversation,
          user_turn,
          chat_id,
          reply_to_message_id,
          opts
        )

      nil ->
        {:fallback, :no_prepared_action}
    end
  end

  def handle_text_confirmation(
        _conversation,
        _user_turn,
        _chat_id,
        _reply_to_message_id,
        _decision,
        _opts
      ),
      do: {:fallback, :invalid_confirmation}

  def start_run(attrs) when is_map(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def complete_run(%Run{} = run, attrs \\ %{}) do
    finish_at =
      Map.get(attrs, :finished_at) || Map.get(attrs, "finished_at") || DateTime.utc_now()

    with :ok <- run_completion_guard(run, attrs) do
      _ = Maraithon.TelegramAssistant.RunStreamPreview.delete(run.id)

      run
      |> Run.hydrate_payloads()
      |> Run.changeset(%{
        status: Map.get(attrs, :status) || Map.get(attrs, "status") || "completed",
        result_summary:
          Map.get(attrs, :result_summary) || Map.get(attrs, "result_summary") || %{},
        finished_at: finish_at,
        error: Map.get(attrs, :error) || Map.get(attrs, "error")
      })
      |> Repo.update()
      |> hydrate_run_result()
    end
  end

  defp run_completion_guard(run, attrs) do
    case Keyword.get(config(), :run_completion_guard) do
      guard when is_function(guard, 2) -> guard.(run, attrs)
      _missing -> :ok
    end
  end

  def fail_run(%Run{} = run, error, status \\ "failed") do
    complete_run(run, %{status: status, error: normalize_error(error)})
  end

  def update_run(%Run{} = run, attrs) when is_map(attrs) do
    run
    |> Run.hydrate_payloads()
    |> Run.changeset(attrs)
    |> Repo.update()
    |> hydrate_run_result()
  end

  def resumable_delivery_run(conversation_id, source_message_id)
      when is_binary(conversation_id) and is_binary(source_message_id) do
    Run
    |> where([run], run.conversation_id == ^conversation_id)
    |> where([run], run.status in ["running", "degraded", "failed"])
    |> where(
      [run],
      run.delivery_checkpoint_source_message_id == ^source_message_id or
        (is_nil(run.delivery_checkpoint_source_message_id) and
           is_nil(run.result_summary) and
           fragment(
             "?->'delivery_checkpoint'->>'source_message_id' = ?",
             run.legacy_result_summary,
             ^source_message_id
           ))
    )
    |> order_by([run], desc: run.started_at)
    |> limit(1)
    |> Repo.one()
    |> Run.hydrate_payloads()
  end

  def resumable_delivery_run(_conversation_id, _source_message_id), do: nil

  # Kept for callers compiled against the narrower checkpoint API.
  def resumable_todo_digest_run(conversation_id, source_message_id),
    do: resumable_delivery_run(conversation_id, source_message_id)

  defp handle_assistant_callback(data, callback_data) do
    case TelegramResponder.parse_action_callback(callback_data) do
      {:ok, prepared_action_id, decision} ->
        chat_id = read_id_string(data, "chat_id")
        message_id = read_id_string(data, "message_id")
        callback_id = read_string(data, "callback_id")

        handle_prepared_action_decision(
          prepared_action_id,
          decision,
          chat_id,
          message_id,
          callback_id,
          durable: durable_processing?(data)
        )

      {:error, :invalid_callback} ->
        case BriefTodoReview.handle_callback(data) do
          :ok -> :ok
          {:noop, _reason} = noop -> noop
          {:error, _reason} = error -> error
          :ignored -> TodoActions.handle_callback(data)
          other -> {:error, {:invalid_brief_callback_result, other}}
        end
    end
  end

  def create_step(attrs) when is_map(attrs) do
    case insert_step(attrs) do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # A primary-key collision means the generated id raced an existing
        # row (seen once during deploy churn); retry once with a fresh id
        # instead of failing the whole run.
        if Keyword.has_key?(errors, :id) do
          insert_step(attrs)
        else
          {:error, changeset}
        end

      other ->
        other
    end
  end

  defp insert_step(attrs) do
    %Step{}
    |> Step.changeset(attrs)
    |> Repo.insert()
  end

  def complete_step(%Step{} = step, attrs \\ %{}) do
    step
    |> Step.hydrate_payloads()
    |> Step.changeset(%{
      status: Map.get(attrs, :status) || Map.get(attrs, "status") || "completed",
      response_payload:
        Map.get(attrs, :response_payload) || Map.get(attrs, "response_payload") || %{},
      finished_at:
        Map.get(attrs, :finished_at) || Map.get(attrs, "finished_at") || DateTime.utc_now(),
      error: Map.get(attrs, :error) || Map.get(attrs, "error")
    })
    |> Repo.update()
    |> hydrate_step_result()
  end

  defp hydrate_run_result({:ok, %Run{} = run}), do: {:ok, Run.hydrate_payloads(run)}
  defp hydrate_run_result(other), do: other

  defp hydrate_step_result({:ok, %Step{} = step}), do: {:ok, Step.hydrate_payloads(step)}
  defp hydrate_step_result(other), do: other

  defp hydrate_prepared_action_result({:ok, %PreparedAction{} = action}),
    do: {:ok, PreparedAction.hydrate_payload(action)}

  defp hydrate_prepared_action_result(other), do: other

  def create_prepared_action(attrs) when is_map(attrs) do
    %PreparedAction{}
    |> PreparedAction.changeset(attrs)
    |> Repo.insert()
    |> hydrate_prepared_action_result()
  end

  def update_prepared_action(%PreparedAction{} = prepared_action, attrs) when is_map(attrs) do
    prepared_action
    |> PreparedAction.hydrate_payload()
    |> PreparedAction.changeset(attrs)
    |> Repo.update()
    |> hydrate_prepared_action_result()
  end

  def get_prepared_action(id) when is_binary(id),
    do: id |> then(&Repo.get(PreparedAction, &1)) |> PreparedAction.hydrate_payload()

  def get_prepared_action(_id), do: nil

  @doc """
  Rejects an action only while the row is still awaiting confirmation.

  The supplied struct is only an identifier: the row is reloaded under
  `FOR UPDATE` before the transition so a stale Cancel tap cannot overwrite a
  concurrent confirmation or execution checkpoint.
  """
  def reject_prepared_action(%PreparedAction{} = prepared_action) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "awaiting_confirmation"} = locked_action ->
        if prepared_action_expired_at?(locked_action, database_now!()) do
          with {:ok, expired_action} <-
                 update_prepared_action(locked_action, %{
                   status: "expired",
                   error: "confirmation_expired"
                 }) do
            {:error, expired_action, :confirmation_expired}
          end
        else
          update_prepared_action(locked_action, %{status: "rejected", error: nil})
        end

      %PreparedAction{status: "expired"} = locked_action ->
        {:error, locked_action, :confirmation_expired}

      %PreparedAction{} = locked_action ->
        {:error, locked_action, :already_handled}
    end)
  end

  @doc """
  Applies mobile draft edits to the latest locked action only while it is
  awaiting confirmation. The updater receives the reloaded row and returns
  `{:ok, attrs}` or `{:error, reason}`.
  """
  def edit_prepared_action(%PreparedAction{} = prepared_action, updater)
      when is_function(updater, 1) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "awaiting_confirmation"} = locked_action ->
        if prepared_action_expired_at?(locked_action, database_now!()) do
          with {:ok, expired_action} <-
                 update_prepared_action(locked_action, %{
                   status: "expired",
                   error: "confirmation_expired"
                 }) do
            {:error, expired_action, :confirmation_expired}
          end
        else
          case updater.(locked_action) do
            {:ok, attrs} when is_map(attrs) -> update_prepared_action(locked_action, attrs)
            {:error, reason} -> {:error, locked_action, reason}
            other -> {:error, locked_action, {:invalid_prepared_action_edit, other}}
          end
        end

      %PreparedAction{status: "expired"} = locked_action ->
        {:error, locked_action, :confirmation_expired}

      %PreparedAction{} = locked_action ->
        {:error, locked_action, :already_handled}
    end)
  end

  @doc """
  Finds an existing non-expired, still-`awaiting_confirmation` PreparedAction
  linked to the given todo (via `payload["todo_id"]`), if any.

  SPEC 06 review finding #2: without this dedupe check, every "Send" tap on a
  todo card creates a brand-new Conversation + PreparedAction, so two taps
  produce two independent confirmation prompts and, if both are confirmed,
  two sends plus two independent nudge_count increments
  (`maybe_record_todo_nudge/1` below). `Maraithon.TelegramAssistant.TodoActions`
  calls this before preparing a new send so a repeat tap re-presents the
  existing confirmation instead of creating a duplicate, and uses it again at
  render time to keep the card's "Send" button from implying a fresh tap will
  do something when one is already pending.
  """
  def find_awaiting_prepared_action_for_todo(user_id, todo_id)
      when is_binary(user_id) and is_binary(todo_id) do
    now = DateTime.utc_now()

    PreparedAction
    |> where(
      [prepared_action],
      prepared_action.user_id == ^user_id and
        prepared_action.status == "awaiting_confirmation" and
        prepared_action.expires_at > ^now and
        (prepared_action.payload_todo_id == ^todo_id or
           (is_nil(prepared_action.payload_encryption_version) and
              fragment("?->>'todo_id' = ?", prepared_action.legacy_payload, ^todo_id)))
    )
    |> order_by([prepared_action], desc: prepared_action.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> PreparedAction.hydrate_payload()
  end

  def find_awaiting_prepared_action_for_todo(_user_id, _todo_id), do: nil

  @doc """
  Finds the still-`awaiting_confirmation` PreparedAction for a todo,
  scoped by `action_type` and *ignoring* `expires_at` (SPEC 02 R12).

  `find_awaiting_prepared_action_for_todo/2` filters `expires_at > now`,
  which makes it exactly the wrong query for resolving a conflict against
  the `telegram_prepared_actions_awaiting_todo_index` partial unique index:
  a row that is past `expires_at` but not yet swept still reads
  `status: "awaiting_confirmation"` and is precisely what blocks a new
  insert — this query finds it so the caller can force-expire and retry.
  """
  def find_awaiting_prepared_action_for_todo_ignoring_expiry(user_id, action_type, todo_id)
      when is_binary(user_id) and is_binary(action_type) and is_binary(todo_id) do
    PreparedAction
    |> where(
      [prepared_action],
      prepared_action.user_id == ^user_id and
        prepared_action.action_type == ^action_type and
        prepared_action.status == "awaiting_confirmation" and
        (prepared_action.payload_todo_id == ^todo_id or
           (is_nil(prepared_action.payload_encryption_version) and
              fragment("?->>'todo_id' = ?", prepared_action.legacy_payload, ^todo_id)))
    )
    |> order_by([prepared_action], desc: prepared_action.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> PreparedAction.hydrate_payload()
  end

  def find_awaiting_prepared_action_for_todo_ignoring_expiry(_user_id, _action_type, _todo_id),
    do: nil

  @doc """
  Actively expires `awaiting_confirmation` prepared actions past their
  `expires_at` (SPEC 02 R2/R11). Expiry was previously lazy-at-read only
  (`prepared_action_expired?/1`), so a row nobody ever read again sat
  `awaiting_confirmation` forever. Only touches rows still awaiting
  confirmation, so re-running is a no-op. Returns the number of rows
  expired.
  """
  def expire_stale_prepared_actions(now \\ DateTime.utc_now()) do
    {:ok, {count, _}} =
      Repo.transaction(fn ->
        :ok = Maraithon.DurablePayload.require_current_mutation!()

        Repo.update_all(
          from(prepared_action in PreparedAction,
            where: prepared_action.status == "awaiting_confirmation",
            where: prepared_action.expires_at < ^now
          ),
          set: [status: "expired", error: "confirmation_expired", updated_at: now]
        )
      end)

    count
  end

  @doc """
  Like `expire_stale_prepared_actions/1`, but also reports how many of the
  expired rows were minted recently and how old the oldest one was — so the
  stuck-state watchdog can tell "fresh confirmations are systematically
  failing" (alarm-worthy) apart from "first sweep chewed through a historical
  backlog" (self-healing, not an emergency).

  Returns `%{count:, recent_count:, oldest_inserted_at:}` where
  `recent_count` counts rows inserted within `recent_window_hours` of `now`.
  """
  def expire_stale_prepared_actions_with_stats(
        now \\ DateTime.utc_now(),
        recent_window_hours \\ 48
      ) do
    recent_cutoff = DateTime.add(now, -recent_window_hours * 60 * 60, :second)

    stats =
      Repo.one(
        from(prepared_action in PreparedAction,
          where: prepared_action.status == "awaiting_confirmation",
          where: prepared_action.expires_at < ^now,
          select: %{
            recent_count:
              fragment(
                "count(*) FILTER (WHERE ? > ?)",
                prepared_action.inserted_at,
                ^recent_cutoff
              ),
            oldest_inserted_at: min(prepared_action.inserted_at)
          }
        )
      ) || %{recent_count: 0, oldest_inserted_at: nil}

    count = expire_stale_prepared_actions(now)

    %{
      count: count,
      recent_count: stats.recent_count || 0,
      oldest_inserted_at: stats.oldest_inserted_at
    }
  end

  def latest_prepared_action(%Conversation{} = conversation) do
    prepared_action_id = get_in(conversation.metadata || %{}, ["latest_prepared_action_id"])

    cond do
      is_binary(prepared_action_id) ->
        case get_prepared_action(prepared_action_id) do
          %PreparedAction{status: "awaiting_confirmation"} = prepared_action ->
            if prepared_action_expired?(prepared_action) do
              expire_prepared_action(prepared_action)
              nil
            else
              prepared_action
            end

          _ ->
            nil
        end

      true ->
        PreparedAction
        |> where(
          [prepared_action],
          prepared_action.conversation_id == ^conversation.id and
            prepared_action.status == "awaiting_confirmation"
        )
        |> order_by([prepared_action], desc: prepared_action.inserted_at)
        |> limit(1)
        |> Repo.one()
        |> PreparedAction.hydrate_payload()
    end
  end

  def latest_prepared_action(_conversation), do: nil

  # Terminal delivery proofs and in-flight serialization states all block an
  # older or concurrent sender. `held_rate_limit` is deliberately excluded:
  # quiet-hours and interruption-budget holds must not permanently block a
  # later retry of the same dedupe_key.
  @blocking_push_decisions [
    "reserved",
    "sending",
    "delivery_unknown",
    "sent_now",
    "merged",
    "queued_digest"
  ]

  def record_push_receipt(attrs) when is_map(attrs) do
    %PushReceipt{}
    |> PushReceipt.changeset(attrs)
    |> Repo.insert(
      on_conflict: push_receipt_on_conflict(),
      conflict_target: [:user_id, :dedupe_key],
      returning: true
    )
  end

  # A non-blocking hold (`held_rate_limit`) must never overwrite a
  # previously committed blocking decision (`sent_now`/`merged`/
  # `queued_digest`) for the same dedupe_key — that would erase delivery
  # proof and let a duplicate send through. Blocking decisions may still
  # overwrite an existing hold, or another blocking decision (e.g. a
  # retried send), so those keep replacing normally.
  defp push_receipt_on_conflict do
    blocking = @blocking_push_decisions

    from(receipt in PushReceipt,
      update: [
        set: [
          decision:
            fragment(
              "CASE WHEN ? = ANY(?) AND NOT (EXCLUDED.decision = ANY(?)) THEN ? ELSE EXCLUDED.decision END",
              receipt.decision,
              ^blocking,
              ^blocking,
              receipt.decision
            ),
          origin_type:
            fragment(
              "CASE WHEN ? = ANY(?) AND NOT (EXCLUDED.decision = ANY(?)) THEN ? ELSE EXCLUDED.origin_type END",
              receipt.decision,
              ^blocking,
              ^blocking,
              receipt.origin_type
            ),
          origin_id:
            fragment(
              "CASE WHEN ? = ANY(?) AND NOT (EXCLUDED.decision = ANY(?)) THEN ? ELSE EXCLUDED.origin_id END",
              receipt.decision,
              ^blocking,
              ^blocking,
              receipt.origin_id
            ),
          metadata:
            fragment(
              "CASE WHEN ? = ANY(?) AND NOT (EXCLUDED.decision = ANY(?)) THEN ? ELSE EXCLUDED.metadata END",
              receipt.decision,
              ^blocking,
              ^blocking,
              receipt.metadata
            ),
          conversation_turn_id:
            fragment(
              "CASE WHEN ? = ANY(?) AND NOT (EXCLUDED.decision = ANY(?)) THEN ? ELSE EXCLUDED.conversation_turn_id END",
              receipt.decision,
              ^blocking,
              ^blocking,
              receipt.conversation_turn_id
            ),
          # `inserted_at` is also the decision/lease timestamp for this
          # immutable receipt row. Refresh it when a non-blocking hold becomes
          # a reservation; otherwise an old hold creates an instantly stale
          # in-flight lease. Do not rewrite a blocking proof with a later
          # non-blocking decision.
          inserted_at:
            fragment(
              "CASE WHEN ? = ANY(?) AND NOT (EXCLUDED.decision = ANY(?)) THEN ? ELSE EXCLUDED.inserted_at END",
              receipt.decision,
              ^blocking,
              ^blocking,
              receipt.inserted_at
            )
        ]
      ]
    )
  end

  def push_receipt_for(user_id, dedupe_key)
      when is_binary(user_id) and is_binary(dedupe_key) do
    case Repo.get_by(PushReceipt, user_id: user_id, dedupe_key: dedupe_key) do
      %PushReceipt{decision: decision} = receipt when decision in @blocking_push_decisions ->
        receipt

      _non_blocking_or_missing ->
        nil
    end
  end

  def push_receipt_for(_user_id, _dedupe_key), do: nil

  def send_turn(%Conversation{} = conversation, chat_id, text, opts \\ [])
      when is_binary(chat_id) and is_binary(text) do
    text =
      UserFacingCopy.open_work_language(text,
        strip_safe_label_prefixes: not Keyword.get(opts, :preserve_safe_label_prefixes, false)
      )

    reply_to_message_id = Keyword.get(opts, :reply_to_message_id)
    send_mode = resolve_send_mode(reply_to_message_id, Keyword.get(opts, :send_mode, :reply))
    telegram_opts = Keyword.get(opts, :telegram_opts, [])
    client_message_id = Keyword.get(opts, :client_message_id)
    delivery_state = Keyword.get(opts, :delivery_state, "delivered")

    case dispatch_turn(chat_id, text, reply_to_message_id, send_mode, telegram_opts, opts) do
      {:ok, result, telegram_message_id} ->
        structured_data =
          opts
          |> Keyword.get(:structured_data, %{})
          |> sanitize_structured_data()
          |> Map.put("terminal_response", Keyword.get(opts, :terminal_response, true))

        turn_attrs = %{
          "role" => Keyword.get(opts, :role, "assistant"),
          "telegram_message_id" => telegram_message_id,
          "client_message_id" => client_message_id,
          "delivery_state" => delivery_state,
          "reply_to_message_id" => reply_to_message_id,
          "text" => text,
          "intent" => Keyword.get(opts, :intent),
          "confidence" => Keyword.get(opts, :confidence),
          "turn_kind" => Keyword.get(opts, :turn_kind, "assistant_reply"),
          "origin_type" => Keyword.get(opts, :origin_type, "chat"),
          "origin_id" => Keyword.get(opts, :origin_id),
          "structured_data" => structured_data
        }

        case append_delivered_turn(conversation, turn_attrs) do
          {:ok, {updated_conversation, turn, insert_status}} ->
            delivery_result = put_local_turn_status(result, insert_status)
            {:ok, updated_conversation, turn, delivery_result}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed Telegram assistant send", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Telegram has no idempotency key for sendMessage. A provider success followed
  # by a local turn-write failure is therefore an acknowledged at-least-once
  # partition: return an error so durable ingress retries, while accepting that
  # the retry can produce a duplicate provider message.
  defp append_delivered_turn(conversation, turn_attrs) do
    case TelegramConversations.append_turn_with_status(conversation, turn_attrs) do
      {:error, reason} ->
        Logger.warning("Telegram provider send succeeded but turn persistence failed",
          conversation_reference: Maraithon.Redaction.fingerprint(conversation.id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:error, :telegram_turn_persistence_failed}

      {:ok, {_updated_conversation, _turn, _insert_status}} = result ->
        result

      other ->
        Logger.warning(
          "Telegram provider send succeeded but turn persistence returned invalid result",
          conversation_reference: Maraithon.Redaction.fingerprint(conversation.id),
          failure_code: Maraithon.Redaction.error_class(other)
        )

        {:error, :telegram_turn_persistence_failed}
    end
  rescue
    reason ->
      Logger.warning("Telegram provider send succeeded but turn persistence failed",
        conversation_reference: Maraithon.Redaction.fingerprint(conversation.id),
        failure_code: Maraithon.Redaction.error_class(reason)
      )

      {:error, :telegram_turn_persistence_failed}
  catch
    :exit, reason ->
      Logger.warning("Telegram provider send succeeded but turn persistence exited",
        conversation_reference: Maraithon.Redaction.fingerprint(conversation.id),
        failure_code: Maraithon.Redaction.error_class(reason)
      )

      {:error, :telegram_turn_persistence_failed}
  end

  defp put_local_turn_status(result, insert_status) when is_map(result) do
    Map.put(result, "_maraithon_local_turn_inserted", insert_status == :inserted)
  end

  defp put_local_turn_status(result, _insert_status), do: result

  def mark_conversation_awaiting_action(
        %Conversation{} = conversation,
        %PreparedAction{} = prepared_action
      ) do
    TelegramConversations.mark_awaiting_confirmation(conversation, %{
      "metadata" => %{
        "mode" => "assistant",
        "active_run_id" => prepared_action.run_id,
        "latest_prepared_action_id" => prepared_action.id
      }
    })
  end

  def clear_prepared_action_pointer(%Conversation{} = conversation) do
    TelegramConversations.update_metadata(conversation, %{"latest_prepared_action_id" => nil})
  end

  def deliver_insight(delivery), do: PushBroker.deliver_insight(delivery)
  def deliver_brief(brief), do: PushBroker.deliver_brief(brief)
  def deliver_push_candidate(candidate), do: PushBroker.deliver(candidate)
  def enqueue_proactive_candidate(attrs), do: ProactiveQueue.enqueue(attrs)
  def plan_proactive_check_in(user_id, opts \\ []), do: Proactive.plan_check_in(user_id, opts)

  def deliver_proactive_check_in(user_id, opts \\ []),
    do: Proactive.deliver_check_in(user_id, opts)

  defp sanitize_structured_data(structured_data) when is_map(structured_data) do
    structured_data
    |> sanitize_linked_todo("linked_todo")
    |> sanitize_linked_todo(:linked_todo)
  end

  defp sanitize_structured_data(_structured_data), do: %{}

  defp sanitize_linked_todo(structured_data, key) do
    case Map.fetch(structured_data, key) do
      {:ok, linked_todo} -> Map.put(structured_data, key, PublicPayload.todo(linked_todo))
      :error -> structured_data
    end
  end

  def confirmation_window_seconds do
    Keyword.get(config(), :confirmation_window_seconds, @default_confirmation_window_seconds)
  end

  def liveness_enabled? do
    case Keyword.get(config(), :telegram_liveness_enabled) do
      true -> true
      false -> false
      nil -> enabled?()
    end
  end

  def typing_initial_delay_ms do
    Keyword.get(config(), :typing_initial_delay_ms, @default_typing_initial_delay_ms)
  end

  def typing_refresh_ms do
    Keyword.get(config(), :typing_refresh_ms, @default_typing_refresh_ms)
  end

  def contextual_progress_delay_ms do
    Keyword.get(
      config(),
      :contextual_progress_delay_ms,
      @default_contextual_progress_delay_ms
    )
  end

  def timeout_notice_ms do
    Keyword.get(config(), :timeout_notice_ms, @default_timeout_notice_ms)
  end

  def hard_timeout_ms do
    Keyword.get(config(), :hard_timeout_ms) ||
      Keyword.get(config(), :max_wall_clock_ms, @default_hard_timeout_ms)
  end

  def start_liveness_session(%Run{} = run, attrs) when is_map(attrs) do
    if liveness_enabled?() do
      LivenessSupervisor.start_session(%{
        run_id: run.id,
        user_id: run.user_id,
        conversation_id: run.conversation_id,
        chat_id: run.chat_id,
        reply_to_message_id: Map.get(attrs, :source_message_id),
        source_text: Map.get(attrs, :text),
        owner_pid: self()
      })
    else
      {:error, :disabled}
    end
  end

  def note_liveness_context_loaded(run_id) when is_binary(run_id) do
    maybe_liveness_call(fn -> LivenessSession.note_context_loaded(run_id) end)
  end

  def note_liveness_tool(run_id, tool_name, args \\ %{})
      when is_binary(run_id) and is_binary(tool_name) and is_map(args) do
    maybe_liveness_call(fn -> LivenessSession.note_tool(run_id, tool_name, args) end)
  end

  def cancel_liveness_session(run_id) when is_binary(run_id) do
    maybe_liveness_call(fn -> LivenessSession.cancel(run_id) end)
  end

  def prepare_final_delivery(run_id) when is_binary(run_id) do
    if liveness_enabled?() do
      normalize_liveness_delivery(LivenessSession.prepare_final_delivery(run_id))
    else
      {:ok, default_liveness_delivery()}
    end
  end

  def liveness_timed_out?(run_id) when is_binary(run_id) do
    if liveness_enabled?() do
      LivenessSession.timed_out?(run_id)
    else
      false
    end
  end

  def model_provider_name do
    config()
    |> Keyword.get(:model_provider_name, LLM.provider_name())
    |> to_string()
  end

  def model_name do
    config()
    |> Keyword.get(:model_name, LLM.model())
    |> to_string()
  end

  defp handle_prepared_action_decision(
         prepared_action_id,
         decision,
         chat_id,
         reply_to_message_id,
         callback_id,
         opts
       ) do
    case get_prepared_action(prepared_action_id) do
      %PreparedAction{} = prepared_action ->
        if prepared_action_chat_authorized?(prepared_action, chat_id) do
          conversation =
            prepared_action.conversation_id &&
              Repo.get(Conversation, prepared_action.conversation_id)

          result =
            respond_to_prepared_action(
              prepared_action,
              normalize_decision(decision),
              conversation,
              nil,
              chat_id,
              reply_to_message_id,
              opts
            )

          finish_prepared_action_callback(
            result,
            callback_id,
            if(decision == "confirm", do: "Confirmed", else: "Cancelled")
          )
        else
          with :ok <-
                 answer_prepared_action_callback(
                   callback_id,
                   "This action isn't available here."
                 ) do
            {:noop, :prepared_action_chat_mismatch}
          end
        end

      nil ->
        with :ok <- answer_prepared_action_callback(callback_id, "Action not found") do
          {:noop, :prepared_action_not_found}
        end
    end
  end

  defp finish_prepared_action_callback(:ok, callback_id, text),
    do: answer_prepared_action_callback(callback_id, text)

  defp finish_prepared_action_callback(
         {:noop, :prepared_action_already_handled} = noop,
         callback_id,
         _text
       ) do
    with :ok <- answer_prepared_action_callback(callback_id, "Already handled"), do: noop
  end

  defp finish_prepared_action_callback(
         {:noop, :prepared_action_expired} = noop,
         callback_id,
         _text
       ) do
    with :ok <- answer_prepared_action_callback(callback_id, "Confirmation expired"), do: noop
  end

  defp finish_prepared_action_callback({:noop, _reason} = noop, callback_id, text) do
    with :ok <- answer_prepared_action_callback(callback_id, text), do: noop
  end

  defp finish_prepared_action_callback({:error, _reason} = error, _callback_id, _text),
    do: error

  defp finish_prepared_action_callback(other, _callback_id, _text),
    do: {:error, {:invalid_prepared_action_response_result, other}}

  defp answer_prepared_action_callback(nil, _text), do: :ok

  defp answer_prepared_action_callback(callback_id, text) do
    case TelegramResponder.answer_callback(callback_id, text) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_callback_answer_failed, reason}}
      other -> {:error, {:invalid_telegram_callback_answer_result, other}}
    end
  end

  # SPEC 06 review finding #3: `handle_prepared_action_decision/5` fetches the
  # PreparedAction by UUID alone, so a confirm/cancel callback carrying a
  # different chat's prepared_action_id (forged, replayed, or from a stale
  # inline keyboard after the chat was reused for another chief-of-staff
  # thread) would otherwise still execute. Requiring the inbound callback's
  # chat to match the chat the action was actually prepared for keeps this
  # scoped to the chat it belongs to, mirroring
  # `Maraithon.TelegramAssistant.TodoActions`'s own `:chat_mismatch` guard for
  # todo callbacks.
  defp prepared_action_chat_authorized?(%PreparedAction{chat_id: expected_chat_id}, chat_id)
       when is_binary(expected_chat_id) and is_binary(chat_id) do
    expected_chat_id == chat_id
  end

  defp prepared_action_chat_authorized?(_prepared_action, _chat_id), do: false

  defp respond_to_prepared_action(
         %PreparedAction{} = prepared_action,
         decision,
         %Conversation{} = conversation,
         user_turn,
         chat_id,
         reply_to_message_id,
         opts
       )
       when decision in [:confirm, :reject] and is_list(opts) do
    case decision do
      :confirm ->
        respond_to_prepared_action_confirmation(
          prepared_action,
          conversation,
          user_turn,
          chat_id,
          reply_to_message_id,
          opts
        )

      :reject ->
        case reject_prepared_action(prepared_action) do
          {:ok, updated_action} ->
            with :ok <- maybe_close_confirmation(conversation) do
              deliver_prepared_action_turn(
                conversation,
                chat_id,
                "Understood. I cancelled that action.",
                reply_to_message_id: reply_to_message_id,
                turn_kind: "system_notice",
                origin_type: "prepared_action",
                origin_id: updated_action.id,
                structured_data: %{
                  "prepared_action_id" => updated_action.id,
                  "decision" => "reject",
                  "source_turn_id" => user_turn && user_turn.id
                }
              )
            end

          {:error, _updated_action, :already_handled} ->
            {:noop, :prepared_action_already_handled}

          {:error, _expired_action, :confirmation_expired} ->
            {:noop, :prepared_action_expired}

          {:error, _updated_action, reason} ->
            {:error, reason}
        end
    end
  end

  defp respond_to_prepared_action(
         _prepared_action,
         _decision,
         _conversation,
         _user_turn,
         _chat_id,
         _reply_to_message_id,
         _opts
       ),
       do: {:error, :missing_prepared_action_conversation}

  defp respond_to_prepared_action_confirmation(
         prepared_action,
         conversation,
         user_turn,
         chat_id,
         reply_to_message_id,
         opts
       ) do
    durable? = Keyword.get(opts, :durable, false)

    case confirm_and_execute(prepared_action, opts) do
      {:ok, updated_action, result} ->
        deliver_prepared_action_result(
          updated_action,
          result,
          conversation,
          user_turn,
          chat_id,
          reply_to_message_id
        )

      {:ok, updated_action, result, :already_executed} ->
        if prepared_action_result_delivered?(updated_action) do
          with :ok <- maybe_close_confirmation(conversation) do
            {:noop, :prepared_action_already_delivered}
          end
        else
          deliver_prepared_action_result(
            updated_action,
            result,
            conversation,
            user_turn,
            chat_id,
            reply_to_message_id
          )
        end

      {:error, updated_action, reason, failure_state}
      when failure_state in [:permanent_failure, :already_failed, :manual_reconciliation] ->
        if prepared_action_result_delivered?(updated_action) do
          with :ok <- maybe_close_confirmation(conversation) do
            {:noop, :prepared_action_already_delivered}
          end
        else
          deliver_prepared_action_failure(
            updated_action,
            reason,
            conversation,
            user_turn,
            chat_id,
            reply_to_message_id
          )
        end

      {:error, updated_action, :already_handled} ->
        if durable? do
          {:noop, :prepared_action_already_handled}
        else
          with :ok <- maybe_close_confirmation(conversation) do
            deliver_prepared_action_turn(
              conversation,
              chat_id,
              "This was already handled.",
              reply_to_message_id: reply_to_message_id,
              turn_kind: "system_notice",
              origin_type: "prepared_action",
              origin_id: updated_action.id,
              structured_data: %{
                "prepared_action_id" => updated_action.id,
                "decision" => "confirm",
                "already_handled" => true,
                "source_turn_id" => user_turn && user_turn.id
              }
            )
          end
        end

      {:error, updated_action, reason} ->
        if durable? do
          {:error, {:prepared_action_execution_failed, closed_prepared_action_failure(reason)}}
        else
          with :ok <- maybe_close_confirmation(conversation) do
            deliver_prepared_action_turn(
              conversation,
              chat_id,
              prepared_action_failure_text(updated_action, reason),
              reply_to_message_id: reply_to_message_id,
              turn_kind: "action_result",
              origin_type: "prepared_action",
              origin_id: updated_action.id,
              structured_data: %{
                "prepared_action_id" => updated_action.id,
                "decision" => "confirm",
                "error" => Maraithon.Redaction.error_summary(reason),
                "source_turn_id" => user_turn && user_turn.id
              }
            )
          end
        end

      other ->
        {:error, {:invalid_prepared_action_result, other}}
    end
  end

  defp deliver_prepared_action_result(
         updated_action,
         result,
         conversation,
         user_turn,
         chat_id,
         reply_to_message_id
       ) do
    deliver_reserved_prepared_action_result(updated_action, conversation, fn reserved_action ->
      deliver_prepared_action_turn(
        conversation,
        chat_id,
        prepared_action_result_text(reserved_action, result),
        reply_to_message_id: reply_to_message_id,
        client_message_id: prepared_action_result_client_message_id(reserved_action),
        turn_kind: "action_result",
        origin_type: "prepared_action",
        origin_id: reserved_action.id,
        structured_data: %{
          "prepared_action_id" => reserved_action.id,
          "decision" => "confirm",
          "result" => prepared_execution_checkpoint(result),
          "source_turn_id" => user_turn && user_turn.id
        }
      )
    end)
  end

  defp deliver_prepared_action_failure(
         updated_action,
         reason,
         conversation,
         user_turn,
         chat_id,
         reply_to_message_id
       ) do
    terminal_status =
      if updated_action.status == "execution_unknown", do: "execution_unknown", else: "failed"

    deliver_reserved_prepared_action_result(updated_action, conversation, fn reserved_action ->
      deliver_prepared_action_turn(
        conversation,
        chat_id,
        prepared_action_failure_text(reserved_action, reason),
        reply_to_message_id: reply_to_message_id,
        client_message_id: prepared_action_result_client_message_id(reserved_action),
        turn_kind: "action_result",
        origin_type: "prepared_action",
        origin_id: reserved_action.id,
        structured_data: %{
          "prepared_action_id" => reserved_action.id,
          "decision" => "confirm",
          "status" => terminal_status,
          "error" => compact_prepared_action_error(reason),
          "source_turn_id" => user_turn && user_turn.id
        }
      )
    end)
  end

  defp deliver_reserved_prepared_action_result(prepared_action, conversation, deliver) do
    case reserve_prepared_action_result_delivery(prepared_action) do
      {:ok, reserved_action, token} when is_binary(token) ->
        case deliver.(reserved_action) do
          :ok ->
            with {:ok, _delivered_action} <-
                   complete_prepared_action_result_delivery(reserved_action, token),
                 :ok <- maybe_close_confirmation(conversation) do
              :ok
            end

          {:error, reason} = error ->
            # Telegram has no sendMessage idempotency key. Once dispatch began,
            # any failure is an at-least-once boundary, so fence it as unknown
            # rather than letting a callback replay send a duplicate.
            _ = fail_prepared_action_result_delivery(reserved_action, token, reason, :unknown)
            error

          other ->
            _ =
              fail_prepared_action_result_delivery(
                reserved_action,
                token,
                {:invalid_prepared_action_delivery_result, other},
                :unknown
              )

            {:error, {:invalid_prepared_action_delivery_result, other}}
        end

      {:ok, _delivered_action, :already_delivered} ->
        with :ok <- maybe_close_confirmation(conversation) do
          {:noop, :prepared_action_already_delivered}
        end

      {:error, _action, :prepared_action_result_delivery_in_progress} ->
        {:noop, :prepared_action_result_delivery_in_progress}

      {:error, _action, :prepared_action_result_delivery_unknown} ->
        {:noop, :prepared_action_result_delivery_unknown}

      {:error, _action, reason} ->
        {:error, reason}
    end
  end

  defp prepared_action_result_client_message_id(%PreparedAction{id: id}),
    do: "prepared-action-result:#{id}"

  def prepared_action_result_delivered?(%PreparedAction{} = prepared_action) do
    payload = prepared_action.payload || %{}

    Map.get(payload, @prepared_result_delivery_state_key) == "delivered" or
      is_binary(Map.get(payload, @prepared_result_delivered_at_key)) or
      prepared_action_result_turn_delivered?(prepared_action)
  end

  defp prepared_action_result_turn_delivered?(%PreparedAction{} = prepared_action) do
    is_binary(prepared_action.conversation_id) and
      Repo.exists?(
        from turn in Turn,
          where: turn.conversation_id == ^prepared_action.conversation_id,
          where: turn.turn_kind == "action_result",
          where: turn.origin_type == "prepared_action",
          where: turn.origin_id == ^prepared_action.id,
          where:
            turn.prepared_action_id == ^prepared_action.id or
              (is_nil(turn.prepared_action_id) and turn.origin_id == ^prepared_action.id),
          where: turn.delivery_state == "delivered"
      )
  end

  @doc false
  def reserve_prepared_action_result_delivery(%PreparedAction{} = prepared_action) do
    with_locked_prepared_action(prepared_action, fn action ->
      payload = action.payload || %{}

      cond do
        prepared_action_result_turn_delivered?(action) or
          Map.get(payload, @prepared_result_delivery_state_key) == "delivered" or
            is_binary(Map.get(payload, @prepared_result_delivered_at_key)) ->
          case checkpoint_prepared_action_delivery_state(action, payload, "delivered") do
            {:ok, delivered_action} ->
              {:ok, delivered_action, :already_delivered}

            {:error, reason} ->
              Repo.rollback({:prepared_action_delivery_checkpoint_failed, reason})
          end

        Map.get(payload, @prepared_result_delivery_state_key) == "reserved" ->
          if prepared_result_delivery_reservation_active?(payload, database_now!()) do
            {:error, action, :prepared_action_result_delivery_in_progress}
          else
            # A stale sender can have crossed Telegram's non-idempotent send
            # boundary. Terminalize the reservation; never reclaim it to send.
            unknown_payload =
              payload
              |> clear_prepared_result_delivery_owner()
              |> Map.put(@prepared_result_delivery_state_key, "unknown")

            case update_prepared_action(action, %{payload: unknown_payload}) do
              {:ok, unknown_action} ->
                {:error, unknown_action, :prepared_action_result_delivery_unknown}

              {:error, reason} ->
                Repo.rollback({:prepared_action_delivery_checkpoint_failed, reason})
            end
          end

        Map.get(payload, @prepared_result_delivery_state_key) in ["unknown", "failed"] ->
          {:error, action, :prepared_action_result_delivery_unknown}

        true ->
          now = database_now!()
          token = Ecto.UUID.generate()
          attempts = prepared_result_delivery_attempts(payload) + 1
          lease_until = DateTime.add(now, @prepared_result_delivery_lease_seconds, :second)

          reserved_payload =
            payload
            |> Map.put(@prepared_result_delivery_state_key, "reserved")
            |> Map.put(@prepared_result_delivery_token_key, token)
            |> Map.put(@prepared_result_delivery_attempts_key, attempts)
            |> Map.put(
              @prepared_result_delivery_lease_until_key,
              DateTime.to_iso8601(lease_until)
            )

          case update_prepared_action(action, %{payload: reserved_payload}) do
            {:ok, reserved_action} ->
              {:ok, reserved_action, token}

            {:error, reason} ->
              Repo.rollback({:prepared_action_delivery_reservation_failed, reason})
          end
      end
    end)
  end

  @doc false
  def complete_prepared_action_result_delivery(%PreparedAction{} = prepared_action, token)
      when is_binary(token) do
    with_locked_prepared_action(prepared_action, fn action ->
      payload = action.payload || %{}

      if prepared_result_delivery_token_matches?(payload, token) or
           prepared_action_result_turn_delivered?(action) do
        case checkpoint_prepared_action_delivery_state(action, payload, "delivered") do
          {:ok, delivered_action} -> {:ok, delivered_action}
          {:error, reason} -> Repo.rollback({:prepared_action_delivery_checkpoint_failed, reason})
        end
      else
        {:error, action, :prepared_action_result_delivery_owner_lost}
      end
    end)
    |> normalize_delivery_checkpoint_result()
  end

  @doc false
  def fail_prepared_action_result_delivery(
        %PreparedAction{} = prepared_action,
        token,
        reason,
        mode
      )
      when is_binary(token) and mode in [:retryable, :unknown] do
    with_locked_prepared_action(prepared_action, fn action ->
      payload = action.payload || %{}

      if prepared_result_delivery_token_matches?(payload, token) do
        state = if mode == :retryable, do: "retryable", else: "unknown"

        failed_payload =
          payload
          |> clear_prepared_result_delivery_owner()
          |> Map.put(@prepared_result_delivery_state_key, state)
          |> Map.put(
            @prepared_result_delivery_error_key,
            compact_prepared_action_error(reason)
          )

        case update_prepared_action(action, %{payload: failed_payload}) do
          {:ok, failed_action} ->
            {:ok, failed_action}

          {:error, update_reason} ->
            Repo.rollback({:prepared_action_delivery_checkpoint_failed, update_reason})
        end
      else
        {:error, action, :prepared_action_result_delivery_owner_lost}
      end
    end)
    |> normalize_delivery_checkpoint_result()
  end

  def mark_prepared_action_result_delivered(%PreparedAction{} = prepared_action) do
    with_locked_prepared_action(prepared_action, fn action ->
      case checkpoint_prepared_action_delivery_state(action, action.payload || %{}, "delivered") do
        {:ok, delivered_action} -> {:ok, delivered_action}
        {:error, reason} -> Repo.rollback({:prepared_action_delivery_checkpoint_failed, reason})
      end
    end)
    |> normalize_delivery_checkpoint_result()
  end

  defp checkpoint_prepared_action_delivery_state(action, payload, "delivered") do
    delivered_payload =
      payload
      |> clear_prepared_result_delivery_owner()
      |> Map.put(@prepared_result_delivery_state_key, "delivered")
      |> Map.put(@prepared_result_delivered_at_key, database_now!() |> DateTime.to_iso8601())
      |> Map.delete(@prepared_result_delivery_error_key)

    update_prepared_action(action, %{payload: delivered_payload})
  end

  defp normalize_delivery_checkpoint_result({:ok, %PreparedAction{}} = result), do: result

  defp normalize_delivery_checkpoint_result({:error, %PreparedAction{}, _reason}),
    do: {:error, :prepared_action_delivery_checkpoint_failed}

  defp normalize_delivery_checkpoint_result({:error, %PreparedAction{}, _reason, _state}),
    do: {:error, :prepared_action_delivery_checkpoint_failed}

  defp normalize_delivery_checkpoint_result(_other),
    do: {:error, :prepared_action_delivery_checkpoint_failed}

  defp prepared_result_delivery_token_matches?(payload, token),
    do: Map.get(payload, @prepared_result_delivery_token_key) == token

  defp prepared_result_delivery_reservation_active?(payload, now) do
    with token when is_binary(token) <- Map.get(payload, @prepared_result_delivery_token_key),
         lease when is_binary(lease) <-
           Map.get(payload, @prepared_result_delivery_lease_until_key),
         {:ok, lease_until, _offset} <- DateTime.from_iso8601(lease) do
      DateTime.compare(lease_until, now) == :gt
    else
      _ -> false
    end
  end

  defp clear_prepared_result_delivery_owner(payload) do
    payload
    |> Map.delete(@prepared_result_delivery_token_key)
    |> Map.delete(@prepared_result_delivery_lease_until_key)
  end

  defp prepared_result_delivery_attempts(payload) do
    case Map.get(payload, @prepared_result_delivery_attempts_key) do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _ -> 0
    end
  end

  defp deliver_prepared_action_turn(conversation, chat_id, text, opts) do
    case send_turn(conversation, chat_id, text, opts) do
      {:ok, _conversation, _turn, _telegram_result} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
      other -> {:error, {:invalid_telegram_send_result, other}}
    end
  end

  def confirm_and_execute(%PreparedAction{} = prepared_action),
    do: confirm_and_execute(prepared_action, [])

  def confirm_and_execute(%PreparedAction{} = prepared_action, opts) when is_list(opts) do
    # The confirmation decision is committed before any provider call. Mobile
    # payload edits run while this row is locked and are frozen by the same
    # awaiting -> confirmed update, so a stale editor can neither race the
    # decision nor alter the bytes later handed to the provider.
    case confirm_or_resume_prepared_action(prepared_action, opts) do
      {:ok, %PreparedAction{} = confirmed_action, state}
      when state in [:confirmed, :resume] ->
        execute_confirmed_prepared_action(confirmed_action, opts)

      other ->
        other
    end
  end

  defp confirm_or_resume_prepared_action(%PreparedAction{} = prepared_action, opts) do
    case Repo.transaction(
           fn ->
             prepared_action
             |> lock_prepared_action!()
             |> freeze_prepared_action_decision(opts)
           end,
           timeout: prepared_persistence_timeout_ms()
         ) do
      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, current_prepared_action_or(prepared_action),
         {:prepared_action_persistence_failed, closed_prepared_action_failure(reason)}}
    end
  rescue
    reason ->
      log_prepared_action_transition_failure(prepared_action, reason)
      {:error, current_prepared_action_or(prepared_action), :prepared_action_persistence_failed}
  catch
    :exit, reason ->
      log_prepared_action_transition_failure(prepared_action, reason)
      {:error, current_prepared_action_or(prepared_action), :prepared_action_persistence_failed}
  end

  defp freeze_prepared_action_decision(
         %PreparedAction{status: "awaiting_confirmation"} = prepared_action,
         opts
       ) do
    now = database_now!()

    if prepared_action_expired_at?(prepared_action, now) do
      expired_action =
        update_prepared_action_or_rollback(prepared_action, %{
          status: "expired",
          error: "confirmation_expired"
        })

      {:error, expired_action, :confirmation_expired}
    else
      with {:ok, payload} <- confirmed_payload(prepared_action, opts),
           {:ok, payload_hash} <- prepared_payload_hash(payload) do
        frozen_payload =
          Map.put(payload, @prepared_confirmed_payload_hash_key, payload_hash)

        confirmed_action =
          update_prepared_action_or_rollback(prepared_action, %{
            status: "confirmed",
            confirmed_at: now,
            error: nil,
            payload: frozen_payload
          })

        {:ok, confirmed_action, :confirmed}
      else
        {:error, reason} -> {:error, prepared_action, reason}
      end
    end
  end

  defp freeze_prepared_action_decision(%PreparedAction{status: "confirmed"} = action, _opts),
    do: {:ok, action, :resume}

  defp freeze_prepared_action_decision(%PreparedAction{status: "executed"} = action, _opts),
    do: {:ok, action, prepared_execution_result(action), :already_executed}

  defp freeze_prepared_action_decision(%PreparedAction{status: "failed"} = action, _opts),
    do: {:error, action, prepared_execution_error(action), :already_failed}

  defp freeze_prepared_action_decision(
         %PreparedAction{status: "execution_unknown"} = action,
         _opts
       ),
       do: {:error, action, prepared_execution_error(action), :manual_reconciliation}

  defp freeze_prepared_action_decision(%PreparedAction{status: "expired"} = action, _opts),
    do: {:error, action, :confirmation_expired}

  defp freeze_prepared_action_decision(%PreparedAction{} = action, _opts),
    do: {:error, action, :already_handled}

  defp confirmed_payload(%PreparedAction{} = action, opts) do
    case Keyword.get(opts, :payload_updater) do
      updater when is_function(updater, 1) ->
        case updater.(action) do
          {:ok, attrs} when is_map(attrs) ->
            case Map.get(attrs, :payload) || Map.get(attrs, "payload") do
              payload when is_map(payload) -> {:ok, payload}
              _missing -> {:ok, action.payload || %{}}
            end

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:invalid_prepared_action_edit, other}}
        end

      _missing ->
        {:ok, action.payload || %{}}
    end
  end

  defp prepared_payload_hash(payload) when is_map(payload) do
    payload
    |> Map.drop(@prepared_mutable_runtime_payload_keys)
    |> canonical_json_term()
    |> case do
      {:ok, canonical_payload} ->
        with {:ok, json} <- Jason.encode(canonical_payload) do
          {:ok,
           json
           |> then(&:crypto.hash(:sha256, &1))
           |> Base.encode16(case: :lower)}
        else
          _ -> {:error, :invalid_prepared_action_payload}
        end

      {:error, _reason} ->
        {:error, :invalid_prepared_action_payload}
    end
  end

  defp prepared_payload_hash(_payload), do: {:error, :invalid_prepared_action_payload}

  defp canonical_json_term(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested_value}, {:ok, acc} ->
      with {:ok, key} <- canonical_json_key(key),
           false <- Map.has_key?(acc, key),
           {:ok, canonical_value} <- canonical_json_term(nested_value) do
        {:cont, {:ok, Map.put(acc, key, canonical_value)}}
      else
        _ -> {:halt, {:error, :invalid_json_object}}
      end
    end)
    |> case do
      {:ok, canonical_map} ->
        values = canonical_map |> Enum.sort_by(&elem(&1, 0))
        {:ok, Jason.OrderedObject.new(values)}

      error ->
        error
    end
  end

  defp canonical_json_term(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn nested_value, {:ok, acc} ->
      case canonical_json_term(nested_value) do
        {:ok, canonical_value} -> {:cont, {:ok, [canonical_value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp canonical_json_term(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value}

  defp canonical_json_term(_value), do: {:error, :invalid_json_value}

  defp canonical_json_key(key) when is_binary(key), do: {:ok, key}
  defp canonical_json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp canonical_json_key(_key), do: {:error, :invalid_json_key}

  defp execute_confirmed_prepared_action(%PreparedAction{} = confirmed_action, opts) do
    case claim_prepared_action_execution(confirmed_action) do
      {:ok, %PreparedAction{} = claimed_action, token} when is_binary(token) ->
        execute_claimed_prepared_action(claimed_action, token, opts)

      {:ok, %PreparedAction{} = action, :already_executed} ->
        {:ok, action, prepared_execution_result(action), :already_executed}

      {:error, %PreparedAction{} = action, reason, :already_failed} ->
        {:error, action, reason, :already_failed}

      {:error, %PreparedAction{} = action, reason, :manual_reconciliation} ->
        {:error, action, reason, :manual_reconciliation}

      {:error, %PreparedAction{} = action, reason} ->
        {:error, action, reason}
    end
  end

  defp claim_prepared_action_execution(%PreparedAction{} = prepared_action) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "confirmed"} = action ->
        payload = action.payload || %{}
        now = database_now!()

        case validate_prepared_payload_integrity(payload) do
          :ok ->
            claim_valid_prepared_action_execution(action, payload, now)

          {:error, reason} ->
            error_checkpoint = prepared_execution_error_checkpoint(reason)

            failed_payload =
              payload
              |> clear_prepared_execution_claim()
              |> reset_prepared_result_delivery()
              |> Map.put(@prepared_execution_result_key, error_checkpoint)
              |> Map.put(@prepared_execution_error_key, error_checkpoint)

            case update_prepared_action(action, %{
                   status: "failed",
                   error: compact_prepared_action_error(reason),
                   payload: failed_payload
                 }) do
              {:ok, failed_action} ->
                {:error, failed_action, reason, :already_failed}

              {:error, update_reason} ->
                Repo.rollback({:prepared_action_status_update_failed, update_reason})
            end
        end

      %PreparedAction{status: "executed"} = action ->
        {:ok, action, :already_executed}

      %PreparedAction{status: "failed"} = action ->
        {:error, action, prepared_execution_error(action), :already_failed}

      %PreparedAction{status: "execution_unknown"} = action ->
        {:error, action, prepared_execution_error(action), :manual_reconciliation}

      %PreparedAction{status: "expired"} = action ->
        {:error, action, :confirmation_expired}

      %PreparedAction{} = action ->
        {:error, action, :already_handled}
    end)
  end

  defp claim_valid_prepared_action_execution(action, payload, now) do
    cond do
      prepared_execution_claim_active?(payload, now) ->
        {:error, action, :prepared_action_execution_in_progress}

      is_binary(Map.get(payload, @prepared_execution_token_key)) ->
        # An expired lease proves only that the owner stopped renewing; it does
        # not prove the mutation task is dead. Never launch a concurrent owner.
        # Terminalize for manual reconciliation instead, including legacy rows
        # that claimed to be replay-safe.
        case checkpoint_prepared_action_unknown_locked(
               action,
               payload,
               :prepared_action_execution_owner_lost
             ) do
          {:unknown, unknown_action} ->
            {:error, unknown_action, prepared_execution_error(unknown_action),
             :manual_reconciliation}

          other ->
            other
        end

      true ->
        token = Ecto.UUID.generate()
        attempts = prepared_execution_attempts(payload) + 1
        lease_until = DateTime.add(now, prepared_execution_lease_seconds(), :second)

        claimed_payload =
          payload
          |> Map.put(@prepared_execution_attempts_key, attempts)
          |> Map.put(@prepared_execution_token_key, token)
          |> Map.put(@prepared_execution_lease_until_key, DateTime.to_iso8601(lease_until))

        case update_prepared_action(action, %{payload: claimed_payload}) do
          {:ok, claimed_action} -> {:ok, claimed_action, token}
          {:error, reason} -> Repo.rollback({:prepared_action_claim_failed, reason})
        end
    end
  end

  defp validate_prepared_payload_integrity(payload) do
    with expected when is_binary(expected) <-
           Map.get(payload, @prepared_confirmed_payload_hash_key),
         true <- byte_size(expected) == 64,
         {:ok, actual} <- prepared_payload_hash(payload),
         true <- expected == actual do
      :ok
    else
      _ -> {:error, :prepared_action_payload_tampered}
    end
  end

  defp prepared_execution_claim_active?(payload, now) when is_map(payload) do
    with token when is_binary(token) <- Map.get(payload, @prepared_execution_token_key),
         lease when is_binary(lease) <- Map.get(payload, @prepared_execution_lease_until_key),
         {:ok, lease_until, _offset} <- DateTime.from_iso8601(lease) do
      DateTime.compare(lease_until, now) == :gt
    else
      _missing_or_stale -> false
    end
  end

  defp prepared_execution_claim_active?(_payload, _now), do: false

  defp execute_claimed_prepared_action(claimed_action, token, opts) do
    task = Task.async(fn -> safely_execute_prepared_action(claimed_action) end)

    case await_prepared_action_provider(task, claimed_action, token) do
      {:ok, {:ok, result}} ->
        case checkpoint_prepared_action_success(claimed_action, token, result) do
          {:ok, executed_action, :executed} ->
            _ = maybe_record_todo_nudge(executed_action)
            _ = maybe_record_calendar_block(executed_action, result)
            {:ok, executed_action, result}

          {:ok, executed_action, :already_executed} ->
            {:ok, executed_action, prepared_execution_result(executed_action), :already_executed}

          {:error, current_action, reason} ->
            handle_prepared_action_success_checkpoint_failure(
              current_action,
              token,
              reason,
              result
            )
        end

      {:ok, {:error, reason}} ->
        if ambiguous_execution_failure?(reason) and
             not replay_safe_prepared_action?(claimed_action) do
          checkpoint_prepared_action_unknown(claimed_action, token, reason)
        else
          checkpoint_prepared_action_failure(claimed_action, token, reason, opts)
        end

      {:error, reason} ->
        if replay_safe_prepared_action?(claimed_action) do
          _ = release_finished_prepared_action_claim(claimed_action, token, reason)
          {:error, current_prepared_action_or(claimed_action), reason}
        else
          checkpoint_prepared_action_unknown(claimed_action, token, reason)
        end
    end
  end

  defp await_prepared_action_provider(task, prepared_action, token) do
    case Task.yield(task, prepared_execution_heartbeat_ms()) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:ok, {:error, {:prepared_action_execution_exception, reason}}}

      nil ->
        case renew_prepared_action_execution_claim(prepared_action, token) do
          {:ok, renewed_action} ->
            await_prepared_action_provider(task, renewed_action, token)

          {:error, reason} ->
            # The provider task is linked to this lease owner. Kill and await it
            # before returning so a later reclaim can never overlap live work.
            _ = Task.shutdown(task, :brutal_kill)
            {:error, {:prepared_action_execution_lease_lost, reason}}
        end
    end
  end

  defp renew_prepared_action_execution_claim(prepared_action, token) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "confirmed"} = action ->
        if execution_token_matches?(action, token) do
          lease_until =
            database_now!()
            |> DateTime.add(prepared_execution_lease_seconds(), :second)
            |> DateTime.to_iso8601()

          payload =
            Map.put(action.payload || %{}, @prepared_execution_lease_until_key, lease_until)

          case update_prepared_action(action, %{payload: payload}) do
            {:ok, renewed_action} -> {:ok, renewed_action}
            {:error, reason} -> Repo.rollback({:prepared_action_lease_renewal_failed, reason})
          end
        else
          {:error, action, :prepared_action_execution_owner_lost}
        end

      %PreparedAction{} = action ->
        {:error, action, :prepared_action_execution_owner_lost}
    end)
    |> case do
      {:ok, %PreparedAction{}} = result -> result
      {:error, %PreparedAction{}, reason} -> {:error, reason}
      {:error, %PreparedAction{}, reason, _state} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp safely_execute_prepared_action(prepared_action) do
    prepared_action_executor().execute_prepared_action(prepared_action)
  rescue
    error -> {:error, {:prepared_action_execution_exception, error}}
  catch
    kind, reason -> {:error, {:prepared_action_execution_exception, {kind, reason}}}
  end

  defp checkpoint_prepared_action_success(prepared_action, token, result) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "confirmed"} = action ->
        if execution_token_matches?(action, token) do
          payload =
            action.payload
            |> Kernel.||(%{})
            |> clear_prepared_execution_claim()
            |> reset_prepared_result_delivery()
            |> Map.put(@prepared_execution_result_key, prepared_execution_checkpoint(result))
            |> Map.delete(@prepared_execution_error_key)

          case update_prepared_action(action, %{
                 status: "executed",
                 executed_at: database_now!(),
                 error: nil,
                 payload: payload
               }) do
            {:ok, executed_action} -> {:ok, executed_action, :executed}
            {:error, reason} -> Repo.rollback({:prepared_action_status_update_failed, reason})
          end
        else
          {:error, action, :prepared_action_execution_in_progress}
        end

      %PreparedAction{status: "executed"} = action ->
        {:ok, action, :already_executed}

      %PreparedAction{} = action ->
        {:error, action, :already_handled}
    end)
  end

  defp handle_prepared_action_success_checkpoint_failure(action, token, reason, result) do
    if replay_safe_prepared_action?(action) do
      _ = release_finished_prepared_action_claim(action, token, reason)
      {:error, current_prepared_action_or(action), reason}
    else
      checkpoint_prepared_action_unknown(
        action,
        token,
        {:provider_success_checkpoint_failed, reason, prepared_execution_checkpoint(result)}
      )
    end
  end

  defp release_finished_prepared_action_claim(prepared_action, token, reason) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "confirmed"} = action ->
        if execution_token_matches?(action, token) do
          payload = clear_prepared_execution_claim(action.payload || %{})

          case update_prepared_action(action, %{
                 error: compact_prepared_action_error(reason),
                 payload: payload
               }) do
            {:ok, released_action} ->
              {:ok, released_action}

            {:error, update_reason} ->
              Repo.rollback({:prepared_action_claim_release_failed, update_reason})
          end
        else
          {:error, action, :prepared_action_execution_owner_lost}
        end

      %PreparedAction{} = action ->
        {:error, action, :already_handled}
    end)
  end

  defp checkpoint_prepared_action_unknown(prepared_action, token, reason) do
    result =
      with_locked_prepared_action(prepared_action, fn
        %PreparedAction{status: "confirmed"} = action ->
          if execution_token_matches?(action, token) do
            checkpoint_prepared_action_unknown_locked(action, action.payload || %{}, reason)
          else
            {:error, action, :prepared_action_execution_owner_lost}
          end

        %PreparedAction{status: "execution_unknown"} = action ->
          {:unknown, action}

        %PreparedAction{} = action ->
          {:error, action, :already_handled}
      end)

    case result do
      {:unknown, unknown_action} ->
        {:error, unknown_action, prepared_execution_error(unknown_action), :manual_reconciliation}

      # If the terminal write itself fails, the original claim remains marked
      # non-reclaimable. That conservative marker is safer than a duplicate.
      {:error, current_action, _checkpoint_reason} ->
        {:error, current_action, :prepared_action_persistence_failed}

      other ->
        other
    end
  end

  defp checkpoint_prepared_action_unknown_locked(action, payload, reason) do
    error_checkpoint = prepared_execution_error_checkpoint(reason, "execution_unknown")

    unknown_payload =
      payload
      |> clear_prepared_execution_claim()
      |> reset_prepared_result_delivery()
      |> Map.put(@prepared_execution_result_key, error_checkpoint)
      |> Map.put(@prepared_execution_error_key, error_checkpoint)

    case update_prepared_action(action, %{
           status: "execution_unknown",
           error: "prepared_action_execution_unknown",
           payload: unknown_payload
         }) do
      {:ok, unknown_action} ->
        {:unknown, unknown_action}

      {:error, update_reason} ->
        Repo.rollback({:prepared_action_unknown_checkpoint_failed, update_reason})
    end
  end

  defp checkpoint_prepared_action_failure(prepared_action, token, reason, opts) do
    durable? = Keyword.get(opts, :durable, false)
    error_class = prepared_action_error_class(reason)
    max_attempts = prepared_action_max_attempts()

    result =
      with_locked_prepared_action(prepared_action, fn
        %PreparedAction{status: "confirmed"} = action ->
          if execution_token_matches?(action, token) do
            attempts = prepared_execution_attempts(action.payload || %{})

            if durable? and error_class in [:transient, :ambiguous] and attempts < max_attempts do
              payload = clear_prepared_execution_claim(action.payload || %{})

              case update_prepared_action(action, %{
                     status: "confirmed",
                     error: compact_prepared_action_error(reason),
                     payload: payload
                   }) do
                {:ok, retryable_action} ->
                  {:retry, retryable_action}

                {:error, update_reason} ->
                  Repo.rollback({:prepared_action_status_update_failed, update_reason})
              end
            else
              error_checkpoint = prepared_execution_error_checkpoint(reason)

              payload =
                action.payload
                |> Kernel.||(%{})
                |> clear_prepared_execution_claim()
                |> reset_prepared_result_delivery()
                |> Map.put(@prepared_execution_result_key, error_checkpoint)
                |> Map.put(@prepared_execution_error_key, error_checkpoint)

              case update_prepared_action(action, %{
                     status: "failed",
                     error: compact_prepared_action_error(reason),
                     payload: payload
                   }) do
                {:ok, failed_action} ->
                  {:failed, failed_action}

                {:error, update_reason} ->
                  Repo.rollback({:prepared_action_status_update_failed, update_reason})
              end
            end
          else
            {:error, action, :prepared_action_execution_in_progress}
          end

        %PreparedAction{status: "executed"} = action ->
          {:ok, action, :already_executed}

        %PreparedAction{status: "failed"} = action ->
          {:error, action, prepared_execution_error(action), :already_failed}

        %PreparedAction{status: "execution_unknown"} = action ->
          {:error, action, prepared_execution_error(action), :manual_reconciliation}

        %PreparedAction{} = action ->
          {:error, action, :already_handled}
      end)

    case result do
      {:retry, retryable_action} ->
        {:error, retryable_action, reason}

      {:failed, failed_action} ->
        {:error, failed_action, reason, :permanent_failure}

      other ->
        other
    end
  end

  defp execution_token_matches?(%PreparedAction{payload: payload}, token)
       when is_map(payload) and is_binary(token),
       do: Map.get(payload, @prepared_execution_token_key) == token

  defp execution_token_matches?(_action, _token), do: false

  defp clear_prepared_execution_claim(payload) when is_map(payload) do
    payload
    |> Map.delete(@prepared_execution_token_key)
    |> Map.delete(@prepared_execution_lease_until_key)
    |> Map.delete(@prepared_execution_reclaimable_key)
  end

  defp reset_prepared_result_delivery(payload) do
    payload
    |> clear_prepared_result_delivery_owner()
    |> Map.delete(@prepared_result_delivery_state_key)
    |> Map.delete(@prepared_result_delivered_at_key)
    |> Map.delete(@prepared_result_delivery_error_key)
  end

  defp prepared_execution_attempts(payload) when is_map(payload) do
    case Map.get(payload, @prepared_execution_attempts_key) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {attempts, ""} when attempts >= 0 -> attempts
          _invalid -> 0
        end

      _missing ->
        0
    end
  end

  defp prepared_execution_attempts(_payload), do: 0

  defp replay_safe_prepared_action?(%PreparedAction{action_type: action_type}),
    do: action_type in @replay_safe_prepared_action_types

  defp prepared_action_max_attempts do
    case Keyword.get(
           config(),
           :prepared_action_max_attempts,
           @default_prepared_action_max_attempts
         ) do
      attempts when is_integer(attempts) and attempts > 0 -> attempts
      _invalid -> @default_prepared_action_max_attempts
    end
  end

  defp prepared_execution_lease_seconds do
    case Keyword.get(
           config(),
           :prepared_action_execution_lease_seconds,
           @default_prepared_execution_lease_seconds
         ) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _invalid -> @default_prepared_execution_lease_seconds
    end
  end

  defp prepared_execution_heartbeat_ms do
    configured =
      case Keyword.get(
             config(),
             :prepared_action_execution_heartbeat_ms,
             @default_prepared_execution_heartbeat_ms
           ) do
        milliseconds when is_integer(milliseconds) and milliseconds > 0 -> milliseconds
        _invalid -> @default_prepared_execution_heartbeat_ms
      end

    min(configured, max(div(prepared_execution_lease_seconds() * 1_000, 3), 10))
  end

  defp prepared_persistence_timeout_ms do
    case Keyword.get(
           config(),
           :prepared_action_persistence_timeout_ms,
           @default_prepared_persistence_timeout_ms
         ) do
      milliseconds when is_integer(milliseconds) and milliseconds > 0 -> milliseconds
      _invalid -> @default_prepared_persistence_timeout_ms
    end
  end

  defp database_now! do
    case Repo.query!("SELECT clock_timestamp()").rows do
      [[%DateTime{} = now]] -> now
      [[%NaiveDateTime{} = now]] -> DateTime.from_naive!(now, "Etc/UTC")
      _ -> raise "database did not return an authoritative timestamp"
    end
  end

  defp log_prepared_action_transition_failure(prepared_action, reason) do
    Logger.warning("Prepared action transition failed",
      prepared_action_reference: Maraithon.Redaction.fingerprint(prepared_action.id),
      failure_code: Maraithon.Redaction.error_class(reason)
    )
  end

  defp current_prepared_action_or(%PreparedAction{} = prepared_action) do
    get_prepared_action(prepared_action.id) || PreparedAction.hydrate_payload(prepared_action)
  rescue
    _reason -> prepared_action
  catch
    _kind, _reason -> prepared_action
  end

  defp lock_prepared_action!(%PreparedAction{id: id}) do
    PreparedAction
    |> where([prepared_action], prepared_action.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp with_locked_prepared_action(%PreparedAction{} = prepared_action, callback)
       when is_function(callback, 1) do
    case Repo.transaction(
           fn ->
             :ok = Maraithon.DurablePayload.require_current_mutation!()

             prepared_action
             |> lock_prepared_action!()
             |> PreparedAction.hydrate_payload()
             |> callback.()
           end,
           timeout: prepared_persistence_timeout_ms()
         ) do
      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, current_prepared_action_or(prepared_action),
         {:prepared_action_persistence_failed, closed_prepared_action_failure(reason)}}
    end
  rescue
    reason ->
      log_prepared_action_transition_failure(prepared_action, reason)
      {:error, current_prepared_action_or(prepared_action), :prepared_action_persistence_failed}
  catch
    :exit, reason ->
      log_prepared_action_transition_failure(prepared_action, reason)
      {:error, current_prepared_action_or(prepared_action), :prepared_action_persistence_failed}
  end

  defp update_prepared_action_or_rollback(prepared_action, attrs) do
    case update_prepared_action(prepared_action, attrs) do
      {:ok, updated_action} -> updated_action
      {:error, reason} -> Repo.rollback({:prepared_action_status_update_failed, reason})
    end
  end

  defp prepared_execution_checkpoint(result) do
    case Map.get(serialize_result(result), "message") do
      message when is_binary(message) and message != "" -> %{"message" => message}
      _missing -> %{"message" => "The confirmed action completed."}
    end
  end

  defp prepared_execution_result(%PreparedAction{payload: payload}) when is_map(payload) do
    case Map.get(payload, @prepared_execution_result_key) do
      result when is_map(result) -> result
      _missing -> %{"message" => "This action was already completed."}
    end
  end

  defp prepared_execution_error(%PreparedAction{payload: payload, error: error})
       when is_map(payload) do
    case Map.get(payload, @prepared_execution_error_key) do
      checkpoint when is_map(checkpoint) -> checkpoint
      _missing when is_binary(error) -> error
      _missing -> "prepared_action_failed"
    end
  end

  defp prepared_execution_error(%PreparedAction{error: error}) when is_binary(error), do: error
  defp prepared_execution_error(_prepared_action), do: "prepared_action_failed"

  defp prepared_execution_error_checkpoint(reason, status \\ "failed") do
    checkpoint = %{
      "status" => status,
      "class" => Atom.to_string(prepared_action_error_class(reason)),
      "code" => prepared_action_error_code(reason),
      "error" => compact_prepared_action_error(reason)
    }

    case structured_error_http_status(reason) do
      http_status when is_integer(http_status) -> Map.put(checkpoint, "http_status", http_status)
      nil -> checkpoint
    end
  end

  defp compact_prepared_action_error(reason) do
    summary =
      case prepared_action_error_code(reason) do
        code when is_binary(reason) and code != "unknown_error" -> code
        _ -> Maraithon.Redaction.error_summary(reason)
      end

    Maraithon.PromptBudget.truncate_utf8(summary, @prepared_error_max_bytes)
  end

  defp prepared_action_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp prepared_action_error_code(reason) when is_binary(reason) do
    if byte_size(reason) <= 100 and Regex.match?(~r/^[a-z][a-z0-9_]*$/, reason) do
      reason
    else
      "unknown_error"
    end
  end

  defp prepared_action_error_code({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)

  defp prepared_action_error_code({kind, _status, _detail}) when is_atom(kind),
    do: Atom.to_string(kind)

  defp prepared_action_error_code(reason), do: Maraithon.Redaction.error_class(reason)

  @doc false
  def prepared_action_error_class(reason) do
    case explicit_prepared_action_error_class(reason) do
      error_class when error_class in [:transient, :permanent, :ambiguous] ->
        error_class

      nil ->
        cond do
          ambiguous_execution_failure?(reason) -> :ambiguous
          transient_prepared_action_error?(reason) -> :transient
          true -> :permanent
        end
    end
  end

  defp explicit_prepared_action_error_class(reason) when is_map(reason) do
    case Map.get(reason, :class) || Map.get(reason, "class") do
      :transient -> :transient
      :permanent -> :permanent
      :ambiguous -> :ambiguous
      "transient" -> :transient
      "permanent" -> :permanent
      "ambiguous" -> :ambiguous
      _ -> nil
    end
  end

  defp explicit_prepared_action_error_class(_reason), do: nil

  defp ambiguous_execution_failure?(reason)
       when reason in [
              :timeout,
              :closed,
              :econnreset,
              :network_error,
              :transport_error,
              :prepared_action_execution_owner_lost
            ],
       do: true

  defp ambiguous_execution_failure?({kind, status, _detail})
       when kind in [:api_error, :http_error, :http_status] and status in [408, 504],
       do: true

  defp ambiguous_execution_failure?({kind, status})
       when kind in [:api_error, :http_error, :http_status] and status in [408, 504],
       do: true

  # Maraithon.HTTP intentionally drops raw transport detail. These closed
  # classes can therefore be the only remaining proof that a write response
  # was lost after the provider may have accepted it.
  defp ambiguous_execution_failure?({:http_error, error_class})
       when error_class in @ambiguous_http_error_classes,
       do: true

  defp ambiguous_execution_failure?({:prepared_action_execution_exception, _reason}), do: true

  defp ambiguous_execution_failure?({:provider_success_checkpoint_failed, _reason, _result}),
    do: true

  defp ambiguous_execution_failure?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&ambiguous_execution_failure?/1)
  end

  defp ambiguous_execution_failure?(reason) when is_map(reason) do
    explicit_prepared_action_error_class(reason) == :ambiguous or
      structured_error_http_status(reason) in [408, 504] or
      ambiguous_execution_failure?(
        Map.get(reason, :reason) || Map.get(reason, "reason") || Map.get(reason, :error) ||
          Map.get(reason, "error")
      )
  end

  defp ambiguous_execution_failure?(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["timeout", "timed_out", "closed", "network_error", "transport_error"]))
  end

  defp ambiguous_execution_failure?(_reason), do: false

  defp transient_prepared_action_error?(reason)
       when reason in [
              :timeout,
              :closed,
              :econnrefused,
              :econnreset,
              :enetunreach,
              :ehostunreach,
              :nxdomain,
              :network_error,
              :transport_error,
              :rate_limited,
              :llm_busy,
              :temporarily_unavailable,
              :prepared_action_execution_in_progress
            ],
       do: true

  # HTTP semantics are decided from the structured status before inspecting
  # any detail text. In particular a user-facing phrase containing "timeout"
  # cannot turn a real 400/401/403/404/422 into a retryable poison row.
  defp transient_prepared_action_error?({kind, status, _detail})
       when kind in [:api_error, :http_error, :telegram_error] and is_integer(status),
       do: transient_http_status?(status)

  defp transient_prepared_action_error?({kind, status})
       when kind in [:api_error, :http_error, :telegram_error] and is_integer(status),
       do: transient_http_status?(status)

  defp transient_prepared_action_error?({kind, detail})
       when kind in [:network_error, :transport_error, :rate_limited, :llm_busy],
       do: transient_prepared_action_error?(kind) or transient_prepared_action_error?(detail)

  defp transient_prepared_action_error?({kind, detail})
       when kind in [:api_error, :http_error, :telegram_error],
       do: transient_prepared_action_error?(detail)

  defp transient_prepared_action_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&transient_prepared_action_error?/1)
  end

  defp transient_prepared_action_error?(reason) when is_map(reason) do
    case structured_http_status(reason) do
      status when is_integer(status) ->
        transient_http_status?(status)

      nil ->
        nested_reason =
          Map.get(reason, :reason) || Map.get(reason, "reason") ||
            Map.get(reason, :error) || Map.get(reason, "error")

        transient_prepared_action_error?(nested_reason)
    end
  end

  defp transient_prepared_action_error?(reason) when is_binary(reason) do
    normalized = reason |> String.trim() |> String.downcase()

    normalized in [
      "timeout",
      "timed_out",
      "network_error",
      "transport_error",
      "rate_limited",
      "temporarily_unavailable",
      "econnrefused",
      "econnreset",
      "enetunreach",
      "ehostunreach",
      "nxdomain"
    ] or
      String.contains?(normalized, "temporarily unavailable") or
      Regex.match?(
        ~r/(?:http(?:_status)?|status(?:_code)?)\s*[:=_-]?\s*(408|409|429|5[0-9]{2})(?:\D|$)/,
        normalized
      )
  end

  defp transient_prepared_action_error?(_reason), do: false

  defp structured_error_http_status({kind, status, _detail})
       when kind in [:api_error, :http_error, :telegram_error] and is_integer(status),
       do: status

  defp structured_error_http_status({kind, status})
       when kind in [:api_error, :http_error, :telegram_error] and is_integer(status),
       do: status

  defp structured_error_http_status(reason) when is_map(reason),
    do: structured_http_status(reason)

  defp structured_error_http_status(_reason), do: nil

  defp structured_http_status(reason) when is_map(reason) do
    [
      Map.get(reason, :status),
      Map.get(reason, "status"),
      Map.get(reason, :status_code),
      Map.get(reason, "status_code"),
      Map.get(reason, :http_status),
      Map.get(reason, "http_status")
    ]
    |> Enum.find_value(&normalize_http_status/1)
  end

  defp normalize_http_status(status) when is_integer(status), do: status

  defp normalize_http_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {value, ""} -> value
      _invalid -> nil
    end
  end

  defp normalize_http_status(_status), do: nil

  defp transient_http_status?(status) when status in [408, 409, 429], do: true
  defp transient_http_status?(status) when is_integer(status) and status >= 500, do: true
  defp transient_http_status?(_status), do: false

  defp closed_prepared_action_failure({kind, status, _detail})
       when is_atom(kind) and is_integer(status),
       do: {kind, status}

  defp closed_prepared_action_failure({kind, detail}) when is_atom(kind),
    do: {kind, Maraithon.Redaction.error_class(detail)}

  defp closed_prepared_action_failure(%{} = reason) do
    %{
      class: prepared_action_error_class(reason),
      status: structured_http_status(reason),
      code: Maraithon.Redaction.error_class(reason)
    }
  end

  defp closed_prepared_action_failure(kind) when is_atom(kind), do: kind
  defp closed_prepared_action_failure(_reason), do: :prepared_action_persistence_failed

  def expire_prepared_action(%PreparedAction{} = prepared_action) do
    with_locked_prepared_action(prepared_action, fn
      %PreparedAction{status: "awaiting_confirmation"} = locked_action ->
        if prepared_action_expired_at?(locked_action, database_now!()) do
          update_prepared_action(locked_action, %{
            status: "expired",
            error: "confirmation_expired"
          })
        else
          {:error, locked_action, :confirmation_not_expired}
        end

      %PreparedAction{status: "expired"} = locked_action ->
        {:error, locked_action, :confirmation_expired}

      %PreparedAction{} = locked_action ->
        {:error, locked_action, :already_handled}
    end)
  end

  def prepared_action_expired?(%PreparedAction{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  def prepared_action_expired?(_prepared_action), do: false

  defp prepared_action_expired_at?(
         %PreparedAction{expires_at: %DateTime{} = expires_at},
         %DateTime{} = now
       ),
       do: DateTime.compare(expires_at, now) == :lt

  defp prepared_action_expired_at?(_prepared_action, _now), do: false

  defp maybe_close_confirmation(%Conversation{} = conversation) do
    with {:ok, reopened} <- TelegramConversations.reopen(conversation),
         {:ok, _updated} <- clear_prepared_action_pointer(reopened) do
      :ok
    else
      {:error, reason} -> {:error, {:conversation_update_failed, reason}}
      other -> {:error, {:invalid_conversation_update_result, other}}
    end
  end

  defp maybe_close_confirmation(_conversation),
    do: {:error, :missing_prepared_action_conversation}

  defp prepared_action_result_text(prepared_action, result) do
    case Map.get(serialize_result(result), "message") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        "Completed #{prepared_action_label(prepared_action.action_type)}."
    end
  end

  defp prepared_action_failure_text(
         %PreparedAction{status: "execution_unknown", action_type: action_type},
         _reason
       ) do
    "Maraithon could not verify whether #{prepared_action_uncertain_label(action_type)}. " <>
      "Check the connected service before trying again."
  end

  defp prepared_action_failure_text(%PreparedAction{} = prepared_action, reason) do
    "Maraithon could not #{prepared_action_failure_label(prepared_action.action_type)}. " <>
      prepared_action_failure_detail(reason)
  end

  defp prepared_action_uncertain_label("gmail_send"), do: "the Gmail message was sent"
  defp prepared_action_uncertain_label("gmail_draft_send"), do: "the Gmail draft was sent"
  defp prepared_action_uncertain_label("slack_post"), do: "the Slack message was posted"
  defp prepared_action_uncertain_label(_action_type), do: "the confirmed action completed"

  defp prepared_action_label("gmail_send"), do: "the Gmail message"
  defp prepared_action_label("gmail_draft_send"), do: "the Gmail draft"
  defp prepared_action_label("slack_post"), do: "the Slack message"
  defp prepared_action_label("linear_create_issue"), do: "the Linear issue"
  defp prepared_action_label("linear_create_comment"), do: "the Linear comment"
  defp prepared_action_label("linear_update_issue_state"), do: "the Linear issue status update"
  defp prepared_action_label("notaui_complete_task"), do: "the Notaui task"
  defp prepared_action_label("notaui_update_task"), do: "the Notaui task update"
  defp prepared_action_label("calendar_create_event"), do: "the calendar block"
  defp prepared_action_label("calendar_update_event"), do: "the calendar block update"
  defp prepared_action_label("calendar_cancel_event"), do: "the calendar block cancellation"
  defp prepared_action_label("agent_create"), do: "the agent creation"
  defp prepared_action_label("agent_update"), do: "the agent update"
  defp prepared_action_label("agent_delete"), do: "the agent removal"
  defp prepared_action_label("project_create"), do: "the project creation"
  defp prepared_action_label("project_update"), do: "the project update"
  defp prepared_action_label(_action_type), do: "that action"

  defp prepared_action_failure_label("gmail_send"), do: "send the Gmail message"
  defp prepared_action_failure_label("gmail_draft_send"), do: "send the Gmail draft"
  defp prepared_action_failure_label("slack_post"), do: "send the Slack message"
  defp prepared_action_failure_label("linear_create_issue"), do: "create the Linear issue"
  defp prepared_action_failure_label("linear_create_comment"), do: "add the Linear comment"

  defp prepared_action_failure_label("linear_update_issue_state"),
    do: "update the Linear issue status"

  defp prepared_action_failure_label("notaui_complete_task"), do: "complete the Notaui task"
  defp prepared_action_failure_label("notaui_update_task"), do: "update the Notaui task"
  defp prepared_action_failure_label("calendar_create_event"), do: "book the calendar block"
  defp prepared_action_failure_label("calendar_update_event"), do: "update the calendar block"
  defp prepared_action_failure_label("calendar_cancel_event"), do: "cancel the calendar block"
  defp prepared_action_failure_label("agent_create"), do: "create the automation"
  defp prepared_action_failure_label("agent_update"), do: "update the automation"
  defp prepared_action_failure_label("agent_delete"), do: "remove the automation"
  defp prepared_action_failure_label("project_create"), do: "create the project"
  defp prepared_action_failure_label("project_update"), do: "update the project"
  defp prepared_action_failure_label(_action_type), do: "complete that action"

  defp prepared_action_failure_detail(:confirmation_expired),
    do: "The confirmation expired before it could run."

  defp prepared_action_failure_detail(:project_not_found),
    do: "The project it referenced is no longer available."

  defp prepared_action_failure_detail(:agent_not_found),
    do: "The agent it referenced is no longer available."

  defp prepared_action_failure_detail(:gmail_not_connected),
    do: "Gmail is not connected."

  defp prepared_action_failure_detail(:slack_not_connected),
    do: "Slack is not connected."

  defp prepared_action_failure_detail(:linear_not_connected),
    do: "Linear is not connected."

  defp prepared_action_failure_detail(:linear_reauth_required),
    do: "Linear needs to be reconnected before this action can run."

  defp prepared_action_failure_detail(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> prepared_action_failure_detail_from_text()
  end

  defp prepared_action_failure_detail(reason) do
    reason
    |> normalize_error()
    |> String.downcase()
    |> prepared_action_failure_detail_from_text()
  end

  defp prepared_action_failure_detail_from_text(reason) do
    cond do
      # SPEC 12 R6/R10: calendar time-blocking failure copy carries the
      # concrete next step (reconnect link, new slot), so it must win over
      # the generic google/reauth buckets below.
      String.contains?(reason, "calendar_write_scope_required") ->
        ActionFailureCopy.calendar_action("calendar_write_scope_required")

      String.contains?(reason, "slot_no_longer_free") ->
        ActionFailureCopy.calendar_action("slot_no_longer_free")

      String.contains?(reason, "calendar_block_start_passed") ->
        ActionFailureCopy.calendar_action("calendar_block_start_passed")

      String.contains?(reason, "calendar_event_not_managed") ->
        ActionFailureCopy.calendar_action("calendar_event_not_managed")

      String.contains?(reason, "calendar_event_already_gone") ->
        ActionFailureCopy.calendar_action("calendar_event_already_gone")

      String.contains?(reason, "confirmation_expired") ->
        "The confirmation expired before it could run."

      String.contains?(reason, "project_not_found") ->
        "The project it referenced is no longer available."

      String.contains?(reason, "agent_not_found") ->
        "The agent it referenced is no longer available."

      String.contains?(reason, "invalid_user_context") ->
        "Sign in again so the account can be confirmed."

      String.contains?(reason, "reauth") ->
        "The required account needs to be reconnected before this action can run."

      String.contains?(reason, "gmail") or String.contains?(reason, "google_account") ->
        "Gmail is not connected."

      String.contains?(reason, "slack") ->
        "Slack is not connected."

      String.contains?(reason, "linear") ->
        "Linear is not connected."

      String.contains?(reason, "not_connected") ->
        "The required account is not connected."

      true ->
        "Review the action before running it again."
    end
  end

  defp serialize_result(%{} = result), do: stringify_map(result)
  defp serialize_result(result), do: %{"value" => inspect(result)}

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp default_enabled?(config) do
    Keyword.has_key?(config, :client_module) or LLM.provider() == Maraithon.LLM.OpenAIProvider
  end

  defp resolve_send_mode(_reply_to_message_id, :edit), do: :edit
  defp resolve_send_mode(_reply_to_message_id, :persist), do: :persist
  defp resolve_send_mode(nil, _mode), do: :send
  defp resolve_send_mode(_reply_to_message_id, mode) when mode in [:send, :reply], do: mode
  defp resolve_send_mode(_reply_to_message_id, _mode), do: :reply

  defp dispatch_turn(chat_id, text, _reply_to_message_id, :send, telegram_opts, _opts) do
    case TelegramResponder.send(chat_id, text, telegram_opts) do
      {:ok, result} -> {:ok, result, normalize_id(Map.get(result, "message_id"))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_turn(_chat_id, _text, _reply_to_message_id, :persist, _telegram_opts, _opts) do
    {:ok, %{"delivery" => "persisted"}, nil}
  end

  defp dispatch_turn(chat_id, text, reply_to_message_id, :reply, telegram_opts, _opts) do
    case TelegramResponder.reply(chat_id, reply_to_message_id, text, telegram_opts) do
      {:ok, result} -> {:ok, result, normalize_id(Map.get(result, "message_id"))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_turn(chat_id, text, reply_to_message_id, :edit, telegram_opts, opts) do
    message_id = Keyword.get(opts, :message_id)

    if is_binary(message_id) do
      case TelegramResponder.edit(chat_id, message_id, text, telegram_opts) do
        {:ok, result} ->
          {:ok, result, message_id}

        {:error, reason} ->
          Logger.warning("Failed Telegram assistant edit, falling back to send",
            chat_id: chat_id,
            message_id: message_id,
            reason: inspect(reason)
          )

          fallback_mode = resolve_send_mode(reply_to_message_id, :reply)
          dispatch_turn(chat_id, text, reply_to_message_id, fallback_mode, telegram_opts, [])
      end
    else
      dispatch_turn(chat_id, text, reply_to_message_id, :reply, telegram_opts, [])
    end
  end

  defp normalize_decision("confirm"), do: :confirm
  defp normalize_decision("reject"), do: :reject
  defp normalize_decision(:confirm), do: :confirm
  defp normalize_decision(:reject), do: :reject
  defp normalize_decision(_decision), do: :reject

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  # SPEC 05/06 R4: when a confirmed send referencing a todo actually
  # completes, either stamp the todo's nudge state (when the todo is
  # `owed_to_me`, a nudge keeps the loop open) or close the todo out with a
  # resolution note referencing what was sent (every other direction: the
  # send itself was the requested action, e.g. an `owed_by_me` reply).
  defp maybe_record_todo_nudge(
         %PreparedAction{action_type: action_type, user_id: user_id, payload: payload} =
           prepared_action
       )
       when action_type in @nudge_action_types do
    case read_string(payload, "todo_id") do
      todo_id when is_binary(todo_id) ->
        close_or_nudge_todo(user_id, todo_id, prepared_action)

      _ ->
        :ok
    end
  end

  defp maybe_record_todo_nudge(_prepared_action), do: :ok

  # SPEC 12 R9: parallel to `maybe_record_todo_nudge/1` — stamp calendar
  # block bookkeeping onto the linked todo's metadata after a successful
  # execute. `result` is the runner's normalized (string-keyed) tool result.
  defp maybe_record_calendar_block(
         %PreparedAction{
           action_type: "calendar_create_event",
           user_id: user_id,
           payload: payload
         },
         result
       ) do
    with todo_id when is_binary(todo_id) <- read_string(payload || %{}, "todo_id"),
         event_id when is_binary(event_id) <- calendar_result_event_id(result) do
      _ =
        Todos.record_calendar_block(user_id, todo_id, %{
          "event_id" => event_id,
          "calendar_id" => "primary",
          "start_at" => read_string(payload || %{}, "start_at"),
          "end_at" => read_string(payload || %{}, "end_at"),
          "created_at" => DateTime.to_iso8601(DateTime.utc_now())
        })

      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_record_calendar_block(
         %PreparedAction{
           action_type: "calendar_update_event",
           user_id: user_id,
           payload: payload
         },
         _result
       ) do
    payload = payload || %{}

    with todo_id when is_binary(todo_id) <- read_string(payload, "todo_id"),
         event_id when is_binary(event_id) <- read_string(payload, "event_id") do
      changes =
        %{}
        |> maybe_put_present("start_at", read_string(payload, "start_at"))
        |> maybe_put_present("end_at", read_string(payload, "end_at"))

      _ = Todos.update_calendar_block(user_id, todo_id, event_id, changes)
      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_record_calendar_block(
         %PreparedAction{
           action_type: "calendar_cancel_event",
           user_id: user_id,
           payload: payload
         },
         _result
       ) do
    payload = payload || %{}

    with todo_id when is_binary(todo_id) <- read_string(payload, "todo_id"),
         event_id when is_binary(event_id) <- read_string(payload, "event_id") do
      _ = Todos.clear_calendar_block(user_id, todo_id, event_id)
      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_record_calendar_block(_prepared_action, _result), do: :ok

  defp calendar_result_event_id(result) when is_map(result) do
    case get_in(result, ["event", "event_id"]) do
      event_id when is_binary(event_id) and event_id != "" -> event_id
      _ -> nil
    end
  end

  defp calendar_result_event_id(_result), do: nil

  defp maybe_put_present(map, _key, nil), do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)

  defp close_or_nudge_todo(user_id, todo_id, %PreparedAction{
         action_type: action_type,
         preview_text: preview_text
       }) do
    case Todos.get_for_user(user_id, todo_id) do
      %Todo{direction: "owed_to_me"} ->
        _ = Todos.record_nudge_sent(user_id, todo_id, channel: action_type)
        :ok

      %Todo{} ->
        _ =
          Todos.mark_done(user_id, todo_id,
            note: send_resolution_note(action_type, preview_text),
            actor_type: "assistant",
            actor_label: "Maraithon"
          )

        :ok

      nil ->
        :ok
    end
  end

  defp send_resolution_note(action_type, preview_text) do
    base = "Sent via #{send_channel_label(action_type)}."

    if is_binary(preview_text) and String.trim(preview_text) != "" do
      "#{base} #{preview_text}"
    else
      base
    end
  end

  defp send_channel_label("gmail_send"), do: "Gmail"
  defp send_channel_label("gmail_draft_send"), do: "Gmail"
  defp send_channel_label("slack_post"), do: "Slack"
  defp send_channel_label(_action_type), do: "the connected channel"

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp read_string(map, key, default \\ nil) when is_map(map) do
    case fetch(map, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp read_id_string(map, key) when is_map(map) do
    map
    |> fetch(key)
    |> normalize_id()
  end

  defp durable_processing?(data) when is_map(data),
    do: Map.get(data, :durable_processing, false) == true

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp prepared_action_executor do
    Keyword.get(config(), :prepared_action_executor, Runner)
  end

  defp config do
    Application.get_env(:maraithon, :telegram_assistant, [])
  end

  defp maybe_liveness_call(fun) when is_function(fun, 0) do
    if liveness_enabled?() do
      fun.()
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Telegram assistant liveness operation failed",
        reason: Exception.message(error)
      )

      :ok
  end

  defp normalize_liveness_delivery({:ok, %{delivery: _delivery, summary: _summary} = result}) do
    {:ok, result}
  end

  defp normalize_liveness_delivery(_result) do
    {:ok, default_liveness_delivery()}
  end

  defp default_liveness_delivery do
    %{
      delivery: %{mode: :send},
      summary: %{
        "typing_started" => false,
        "progress_note_sent" => false,
        "timeout_notice_sent" => false,
        "final_delivery_mode" => "send"
      }
    }
  end
end
