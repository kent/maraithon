defmodule Maraithon.Todos.CompletionSweep do
  @moduledoc """
  Deterministically closes stale open todos when source data proves completion.

  The sweep is intentionally conservative. It only marks a todo done when the
  underlying source has hard evidence that the work is no longer open:

    * Gmail thread todos with a later self-sent message in the same thread.
    * Local cold-thread todos with a later outgoing local message.
    * Dropped-commitment todos whose backing local reminder is completed.
    * Local calendar-conflict todos whose conflict start passed more than 24h ago.

  All mutations go through `Maraithon.Todos.mark_done/3` so linked insight state
  and resolution metadata stay consistent with manual todo actions.
  """

  import Ecto.Query

  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.Connectors.Gmail
  alias Maraithon.LLM.BoundedResponse
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias Maraithon.Todos.UserBatch

  require Logger

  @open_statuses ~w(open snoozed)
  @default_limit 20
  @max_limit 20
  @max_user_runtime_ms 120_000
  @max_gmail_operation_ms 10_000
  @calendar_conflict_grace_hours 24

  @type summary :: %{
          checked: non_neg_integer(),
          completed: non_neg_integer(),
          errors: non_neg_integer(),
          fetch_errors: non_neg_integer(),
          completed_by_source: map(),
          completed_by_reason: map()
        }

  @doc """
  Runs the completion sweep for every user with open todos.
  """
  def run_for_all_users(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    deadline = bounded_deadline(opts)
    user_ids = UserBatch.open_todo_user_ids(opts)

    results =
      Enum.reduce_while(user_ids, [], fn user_id, results ->
        if deadline_reached?(deadline) do
          {:halt, results}
        else
          user_opts = opts |> Keyword.put(:now, now) |> Keyword.put(:deadline_ms, deadline)
          {:cont, [run_for_user_safely(user_id, user_opts) | results]}
        end
      end)
      |> Enum.reverse()

    Enum.reduce(results, empty_all_summary(length(results)), &merge_user_summary/2)
  end

  @doc """
  Runs the completion sweep for one user.

  Tests may inject `:gmail_fetcher` as a two-arity function
  `(user_id, todo) -> {:ok, provider, thread_id, messages} | {:error, reason}`.
  """
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    deadline = bounded_deadline(opts)
    opts = Keyword.put(opts, :deadline_ms, deadline)

    limit =
      opts
      |> Keyword.get(:limit)
      |> positive_integer(@default_limit)
      |> min(@max_limit)

    # Resolve connected Google accounts once per user per run; retaining the
    # account email is required to scope legacy `google` tokens safely.
    connected_accounts = connected_gmail_accounts(user_id)

    self_emails =
      Keyword.get(opts, :self_emails) || self_emails_from_accounts(user_id, connected_accounts)

    opts =
      opts
      |> Keyword.put(:self_emails, self_emails)
      |> Keyword.put_new(:gmail_fetcher, fn fetch_user_id, todo ->
        fetch_gmail_thread(fetch_user_id, todo, connected_accounts)
      end)

    todos =
      Todo
      |> where([todo], todo.user_id == ^user_id and todo.status in ^@open_statuses)
      |> maybe_scope_source_account(opts)
      |> maybe_scope_todo_ids(opts)
      |> maybe_exclude_account_messages(opts)
      |> order_by([todo], asc_nulls_first: todo.last_completion_checked_at, asc: todo.id)
      |> limit(^limit)
      |> Repo.all()

    {summary, fetch_error_counts} =
      Enum.reduce_while(
        todos,
        {empty_user_summary(user_id, 0), %{}},
        fn todo, {summary, fetch_error_counts} ->
          if deadline_reached?(deadline) do
            {:halt, {summary, fetch_error_counts}}
          else
            summary = Map.update!(summary, :checked, &(&1 + 1))
            result = completion_evidence(todo, now, opts)
            stamp_completion_attempt(todo, now)

            next =
              case result do
                {:done, reason, note} ->
                  {mark_done(summary, todo, reason, note), fetch_error_counts}

                {:fetch_error, reason} ->
                  {
                    Map.update!(summary, :fetch_errors, &(&1 + 1)),
                    Map.update(fetch_error_counts, reason, 1, &(&1 + 1))
                  }

                :open ->
                  {summary, fetch_error_counts}
              end

            {:cont, next}
          end
        end
      )

    Enum.each(fetch_error_counts, fn {reason, count} ->
      Logger.warning(
        "Todo completion sweep could not verify Gmail items (#{count} todos)",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        affected_todo_count: count,
        failure_code: Maraithon.Redaction.error_class(reason)
      )
    end)

    summary
  end

  def run_for_user(_user_id, _opts), do: empty_user_summary(nil, 0)

  defp maybe_exclude_account_messages(query, opts) do
    if Keyword.get(opts, :skip_account_message_sources, false) do
      where(query, [todo], todo.source != "gmail")
    else
      query
    end
  end

  defp maybe_scope_source_account(query, opts) do
    case Keyword.get(opts, :source_account_id) do
      account_id when is_integer(account_id) ->
        where(query, [todo], todo.source_account_id == ^account_id)

      _other ->
        if Keyword.get(opts, :source_account_unassigned?, false) do
          where(query, [todo], is_nil(todo.source_account_id))
        else
          query
        end
    end
  end

  defp maybe_scope_todo_ids(query, opts) do
    case Keyword.get(opts, :todo_ids) do
      ids when is_list(ids) and ids != [] -> where(query, [todo], todo.id in ^ids)
      [] -> where(query, [todo], false)
      _other -> query
    end
  end

  # One user's crash must never abort the sweep for every user after them
  # (mirrors StalenessTriageSweep.run_for_user_safely/2).
  defp run_for_user_safely(user_id, opts) do
    run_for_user(user_id, opts)
  rescue
    error ->
      Logger.warning("Todo completion sweep crashed for user",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      %{empty_user_summary(user_id, 0) | errors: 1}
  catch
    kind, reason ->
      Logger.warning("Todo completion sweep crashed for user",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class({kind, reason})
      )

      %{empty_user_summary(user_id, 0) | errors: 1}
  end

  defp completion_evidence(%Todo{source: "gmail"} = todo, _now, opts) do
    gmail_completion_evidence(todo, opts)
  end

  defp completion_evidence(%Todo{source: "local_patterns"} = todo, now, _opts) do
    case Map.get(todo.metadata || %{}, "detector") do
      "cold_thread" -> cold_thread_completion_evidence(todo)
      "dropped_commitment" -> dropped_commitment_completion_evidence(todo)
      "calendar_conflict" -> calendar_conflict_completion_evidence(todo, now)
      _detector -> :open
    end
  end

  defp completion_evidence(_todo, _now, _opts), do: :open

  defp gmail_completion_evidence(%Todo{} = todo, opts) do
    source_at = source_anchor_datetime(todo)

    if is_struct(source_at, DateTime) do
      gmail_fetcher = Keyword.get(opts, :gmail_fetcher, &fetch_gmail_thread/2)
      self_emails = Keyword.get(opts, :self_emails, []) |> Enum.take(20)
      timeout_ms = remaining_operation_ms(opts)

      if timeout_ms > 0 do
        case BoundedResponse.run(
               fn ->
                 gmail_fetcher.(todo.user_id, todo)
                 |> normalize_gmail_fetch_result(source_at, self_emails)
               end,
               timeout_ms
             ) do
          {:error, %{reason: :timeout}} -> {:fetch_error, :gmail_timeout}
          {:error, %{reason: :request_failed}} -> {:fetch_error, :gmail_fetch_failed}
          result -> result
        end
      else
        {:fetch_error, :cycle_deadline}
      end
    else
      :open
    end
  end

  defp normalize_gmail_fetch_result(
         {:ok, provider, thread_id, messages},
         source_at,
         self_emails
       )
       when is_list(messages) do
    gmail_message_result(messages, provider, thread_id, source_at, self_emails)
  end

  defp normalize_gmail_fetch_result({:ok, messages}, source_at, self_emails)
       when is_list(messages) do
    gmail_message_result(messages, nil, nil, source_at, self_emails)
  end

  defp normalize_gmail_fetch_result({:error, reason}, _source_at, _self_emails)
       when reason in [:not_found, :invalid_gmail_id],
       do: :open

  defp normalize_gmail_fetch_result({:error, _reason}, _source_at, _self_emails),
    do: {:fetch_error, :gmail_fetch_failed}

  defp normalize_gmail_fetch_result(_invalid, _source_at, _self_emails),
    do: {:fetch_error, :invalid_gmail_response}

  defp gmail_message_result(messages, provider, thread_id, source_at, self_emails) do
    case later_self_message(messages, source_at, self_emails) do
      nil ->
        :open

      message ->
        {:done, :gmail_self_reply, gmail_resolution_note(provider, thread_id, message, source_at)}
    end
  end

  defp cold_thread_completion_evidence(%Todo{} = todo) do
    metadata = todo.metadata || %{}
    chat_key = first_present([metadata["chat_key"], todo.source_item_id])
    source_at = source_anchor_datetime(todo)

    if is_binary(chat_key) and is_struct(source_at, DateTime) do
      latest =
        LocalMessage
        |> where([message], message.user_id == ^todo.user_id)
        |> where([message], message.chat_key == ^chat_key)
        |> where([message], message.is_from_me == true)
        |> where([message], message.sent_at > ^source_at)
        |> order_by([message], desc: message.sent_at)
        |> limit(1)
        |> Repo.one()

      case latest do
        %LocalMessage{} = message ->
          {:done, :local_message_reply,
           "Scheduled completion sweep: Newer outgoing local message in chat #{chat_key} at #{format_dt(message.sent_at)} after source #{format_dt(source_at)}."}

        nil ->
          :open
      end
    else
      :open
    end
  end

  # `source_occurred_at` can be nil on some ingested todos; fall back to when
  # the todo was captured so those items still get completion-checked instead
  # of staying :open forever.
  defp source_anchor_datetime(%Todo{source_occurred_at: %DateTime{} = source_at}), do: source_at
  defp source_anchor_datetime(%Todo{inserted_at: %DateTime{} = inserted_at}), do: inserted_at

  defp source_anchor_datetime(%Todo{inserted_at: %NaiveDateTime{} = inserted_at}),
    do: DateTime.from_naive!(inserted_at, "Etc/UTC")

  defp source_anchor_datetime(_todo), do: nil

  defp dropped_commitment_completion_evidence(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    reminder_id =
      first_present([metadata["reminder_guid"], metadata["reminder_id"], todo.source_item_id])

    case completed_reminder(todo.user_id, reminder_id) do
      %LocalReminder{} = reminder ->
        {:done, :completed_local_reminder,
         "Scheduled completion sweep: Backing local reminder #{reminder_id} was completed at #{format_dt(reminder.completed_at)}."}

      nil ->
        :open
    end
  end

  defp calendar_conflict_completion_evidence(%Todo{} = todo, %DateTime{} = now) do
    cutoff = DateTime.add(now, -@calendar_conflict_grace_hours, :hour)

    if is_struct(todo.source_occurred_at, DateTime) and
         DateTime.compare(todo.source_occurred_at, cutoff) == :lt do
      {:done, :expired_calendar_conflict,
       "Scheduled completion sweep: Calendar conflict window passed more than #{@calendar_conflict_grace_hours} hours before this sweep."}
    else
      :open
    end
  end

  defp completed_reminder(_user_id, nil), do: nil

  defp completed_reminder(user_id, reminder_id) when is_binary(reminder_id) do
    identifier_filter =
      dynamic([reminder], reminder.guid == ^reminder_id or reminder.local_id == ^reminder_id)

    identifier_filter =
      case Ecto.UUID.cast(reminder_id) do
        {:ok, uuid} -> dynamic([reminder], ^identifier_filter or reminder.id == ^uuid)
        :error -> identifier_filter
      end

    LocalReminder
    |> where([reminder], reminder.user_id == ^user_id)
    |> where([reminder], reminder.is_completed == true)
    |> where(^identifier_filter)
    |> order_by([reminder], desc_nulls_last: reminder.completed_at, desc: reminder.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp completed_reminder(_user_id, _reminder_id), do: nil

  defp later_self_message(messages, %DateTime{} = source_at, self_emails) do
    messages
    |> Enum.reduce(nil, fn message, earliest ->
      if from_self?(message, self_emails) do
        case message_datetime(message) do
          %DateTime{} = message_at ->
            if DateTime.compare(message_at, source_at) == :gt do
              case earliest do
                nil ->
                  {message_at, message}

                {earliest_at, _earliest_message} ->
                  if DateTime.compare(message_at, earliest_at) == :lt,
                    do: {message_at, message},
                    else: earliest
              end
            else
              earliest
            end

          _ ->
            earliest
        end
      else
        earliest
      end
    end)
    |> case do
      {_message_at, message} -> message
      nil -> nil
    end
  end

  defp later_self_message(_messages, _source_at, _self_emails), do: nil

  defp from_self?(message, self_emails) do
    email = message |> read_field(:from) |> extract_email()
    email in self_emails
  end

  defp gmail_resolution_note(provider, thread_id, message, source_at) do
    message_id =
      bounded_note_field(read_field(message, :message_id) || read_field(message, :id), 256) ||
        "unknown"

    thread_id = bounded_note_field(thread_id, 256)
    provider = bounded_note_field(provider, 160)
    sent_at = message_datetime(message)

    [
      "Scheduled completion sweep: Sent Gmail reply #{message_id}",
      if(thread_id, do: "in thread #{thread_id}"),
      if(provider, do: "via #{provider}"),
      "at #{format_dt(sent_at)} after source #{format_dt(source_at)}."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp fetch_gmail_thread(user_id, %Todo{} = todo) do
    fetch_gmail_thread(user_id, todo, connected_gmail_accounts(user_id))
  end

  defp fetch_gmail_thread(user_id, %Todo{} = todo, connected_accounts) do
    with {:ok, reference} <- gmail_reference(todo),
         {:ok, providers, scoped?} <- gmail_provider_candidates(todo, connected_accounts),
         true <- providers != [] do
      providers
      |> Enum.reduce_while({nil, []}, fn provider, {_result, errors} ->
        case fetch_gmail_reference_for_provider(user_id, reference, provider) do
          {:ok, thread_id, messages} ->
            {:halt, {{:ok, provider, thread_id, messages}, errors}}

          {:error, :not_found} ->
            {:cont, {nil, errors}}

          {:error, reason} when scoped? ->
            {:halt, {nil, [{provider, reason} | errors]}}

          {:error, reason} ->
            # An accountless legacy todo may belong to any connected mailbox.
            # Keep searching so one broken mailbox cannot hide a healthy match,
            # but retain every operational error if no provider succeeds.
            {:cont, {nil, [{provider, reason} | errors]}}
        end
      end)
      |> case do
        {{:ok, _provider, _thread_id, _messages} = result, _errors} ->
          result

        {nil, []} ->
          {:error, :not_found}

        {nil, errors} ->
          {:error, {:gmail_provider_errors, Enum.reverse(errors)}}
      end
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp gmail_reference(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    thread_values = [
      metadata["thread_id"],
      metadata["gmail_thread_id"],
      metadata["source_thread_id"]
    ]

    message_values = [
      metadata["message_id"],
      metadata["gmail_message_id"],
      metadata["source_message_id"]
    ]

    thread_id = first_valid_gmail_id(thread_values)
    message_id = first_valid_gmail_id(message_values)

    cond do
      is_binary(thread_id) ->
        {:ok, {:thread, thread_id}}

      is_binary(message_id) ->
        {:ok, {:message, message_id}}

      valid_gmail_id?(todo.source_item_id) ->
        {:ok, {:legacy, Gmail.normalize_id(todo.source_item_id)}}

      Enum.any?(thread_values ++ message_values ++ [todo.source_item_id], &present?/1) ->
        {:error, :invalid_gmail_id}

      true ->
        {:error, :not_found}
    end
  end

  defp first_valid_gmail_id(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      if bounded_valid_binary?(value, 256), do: Gmail.normalize_id(value)
    end)
  end

  defp valid_gmail_id?(value) when is_binary(value) do
    bounded_valid_binary?(value, 256) and is_binary(Gmail.normalize_id(value))
  end

  defp valid_gmail_id?(_value), do: false

  defp present?(value) when is_binary(value),
    do: bounded_valid_binary?(value, 1_024) and String.trim(value) != ""

  defp present?(_value), do: false

  defp fetch_gmail_reference_for_provider(user_id, {:thread, thread_id}, provider) do
    fetch_gmail_thread_id(user_id, thread_id, provider)
  end

  defp fetch_gmail_reference_for_provider(user_id, {:message, message_id}, provider) do
    fetch_gmail_thread_from_message_id(user_id, message_id, provider)
  end

  defp fetch_gmail_reference_for_provider(user_id, {:legacy, id}, provider) do
    case fetch_gmail_thread_from_message_id(user_id, id, provider) do
      {:error, :not_found} -> fetch_gmail_thread_id(user_id, id, provider)
      result -> result
    end
  end

  defp fetch_gmail_thread_from_message_id(user_id, message_id, provider) do
    with {:ok, message} <- Gmail.fetch_message(user_id, message_id, provider: provider),
         thread_id when is_binary(thread_id) <-
           Gmail.normalize_id(read_field(message, :thread_id)),
         {:ok, ^thread_id, messages} <- fetch_gmail_thread_id(user_id, thread_id, provider) do
      {:ok, thread_id, messages}
    else
      nil -> {:error, :invalid_gmail_thread_id}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_gmail_thread_id(user_id, thread_id, provider) do
    case Gmail.fetch_thread_content(user_id, thread_id, provider: provider) do
      {:ok, messages} when is_list(messages) and messages != [] ->
        {:ok, thread_id, messages}

      {:ok, _messages} ->
        {:error, :unexpected_gmail_thread_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp gmail_provider_candidates(%Todo{} = todo, connected_accounts) do
    metadata = todo.metadata || %{}

    specific_hints =
      [
        metadata["google_provider"],
        metadata["provider"],
        metadata["google_account_email"],
        metadata["account_email"],
        todo.source_account_label
      ]
      |> Enum.map(&normalize_gmail_provider_hint/1)
      # `google` names the provider family, not a mailbox. It must never
      # conflict with or override a qualified account hint.
      |> Enum.reject(&(&1 in [nil, "google"]))
      |> Enum.uniq()

    case specific_hints do
      [] ->
        unscoped_gmail_provider_candidates(metadata["account"], connected_accounts)

      [hint] ->
        case connected_provider_for_authoritative_hint(hint, connected_accounts) do
          nil -> {:error, {:gmail_provider_unavailable, hint}}
          provider -> {:ok, [provider], true}
        end

      providers ->
        {:error, {:conflicting_gmail_provider_hints, providers}}
    end
  end

  defp unscoped_gmail_provider_candidates(weak_hint, connected_accounts) do
    providers =
      connected_accounts
      |> Enum.map(&Map.get(&1, "provider"))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case connected_provider_for_weak_hint(weak_hint, connected_accounts) do
      provider when is_binary(provider) -> {:ok, [provider], true}
      nil when providers == [] -> {:error, :no_gmail_provider}
      nil -> {:ok, providers, false}
    end
  end

  defp connected_provider_for_authoritative_hint(hint, connected_accounts)
       when is_binary(hint) do
    normalized_hint = String.downcase(hint)

    Enum.find_value(connected_accounts, fn account ->
      provider = Map.get(account, "provider")
      account_email = normalize_account_email(Map.get(account, "account_email"))

      if is_binary(provider) and
           (String.downcase(provider) == normalized_hint or
              (is_binary(account_email) and "google:#{account_email}" == normalized_hint)) do
        provider
      end
    end)
  end

  defp connected_provider_for_authoritative_hint(_hint, _connected_accounts), do: nil

  defp connected_provider_for_weak_hint(value, connected_accounts) do
    case normalize_gmail_provider_hint(value) do
      candidate when is_binary(candidate) and candidate != "google" ->
        Enum.find_value(connected_accounts, fn account ->
          provider = Map.get(account, "provider")

          if is_binary(provider) and String.downcase(provider) == candidate do
            provider
          end
        end)

      _ ->
        nil
    end
  end

  defp normalize_gmail_provider_hint(value)
       when is_binary(value) and byte_size(value) <= 320 do
    value = if String.valid?(value), do: value |> String.trim() |> String.downcase(), else: ""

    cond do
      value == "google" -> "google"
      String.starts_with?(value, "google:") and byte_size(value) > byte_size("google:") -> value
      String.contains?(value, "@") -> "google:#{value}"
      true -> nil
    end
  end

  defp normalize_gmail_provider_hint(_value), do: nil

  defp normalize_account_email(value)
       when is_binary(value) and byte_size(value) <= 320 do
    if String.valid?(value) do
      case value |> String.trim() |> String.downcase() do
        "" -> nil
        normalized -> normalized
      end
    end
  end

  defp normalize_account_email(_value), do: nil

  defp connected_gmail_accounts(user_id) when is_binary(user_id) do
    user_id
    |> SourceScope.resolve()
    |> SourceScope.google_accounts_for_service("gmail")
    |> Enum.take(20)
    |> Enum.sort_by(fn account ->
      {Map.get(account, "account_email") || "~", Map.get(account, "provider") || "~"}
    end)
    |> Enum.take(8)
  end

  defp connected_gmail_accounts(_user_id), do: []

  defp self_emails_from_accounts(user_id, connected_accounts) do
    account_emails =
      Enum.flat_map(connected_accounts, fn account ->
        [Map.get(account, "account_email"), provider_email(Map.get(account, "provider"))]
      end)

    ([user_id] ++ account_emails)
    |> Enum.take(20)
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 320 and String.valid?(&1)))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp provider_email("google:" <> email), do: email
  defp provider_email(_provider), do: nil

  defp stamp_completion_attempt(%Todo{id: id, user_id: user_id}, now) do
    Todo
    |> where([todo], todo.id == ^id and todo.user_id == ^user_id)
    |> Repo.update_all(set: [last_completion_checked_at: DateTime.truncate(now, :second)])

    :ok
  end

  defp mark_done(summary, %Todo{} = todo, reason, note) do
    provenance = %{
      "method" => "deterministic",
      "reason" => Atom.to_string(reason),
      "source" => todo.source,
      "source_item_id" => todo.source_item_id
    }

    case Todos.mark_done_if_current(todo, provenance, note: note) do
      {:ok, _updated} ->
        summary
        |> Map.update!(:completed, &(&1 + 1))
        |> increment_nested(:completed_by_source, todo.source)
        |> increment_nested(:completed_by_reason, Atom.to_string(reason))

      {:error, :todo_no_longer_open} ->
        summary

      {:error, error} ->
        Logger.warning("Todo completion sweep failed to mark todo done",
          user_fingerprint: Maraithon.Redaction.fingerprint(todo.user_id),
          todo_reference: Maraithon.Redaction.fingerprint(todo.id),
          failure_code: Maraithon.Redaction.error_class(error)
        )

        Map.update!(summary, :errors, &(&1 + 1))
    end
  end

  defp empty_all_summary(user_count) do
    %{
      users: user_count,
      checked: 0,
      completed: 0,
      errors: 0,
      fetch_errors: 0,
      completed_by_source: %{},
      completed_by_reason: %{},
      user_summaries: []
    }
  end

  defp empty_user_summary(user_id, checked) do
    %{
      user_id: user_id,
      checked: checked,
      completed: 0,
      errors: 0,
      fetch_errors: 0,
      completed_by_source: %{},
      completed_by_reason: %{}
    }
  end

  defp merge_user_summary(user_summary, all_summary) do
    all_summary
    |> Map.update!(:checked, &(&1 + user_summary.checked))
    |> Map.update!(:completed, &(&1 + user_summary.completed))
    |> Map.update!(:errors, &(&1 + user_summary.errors))
    |> Map.update!(:fetch_errors, &(&1 + user_summary.fetch_errors))
    |> Map.update!(:completed_by_source, &merge_count_maps(&1, user_summary.completed_by_source))
    |> Map.update!(:completed_by_reason, &merge_count_maps(&1, user_summary.completed_by_reason))
    |> Map.update!(:user_summaries, &[user_summary | &1])
  end

  defp merge_count_maps(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp increment_nested(summary, key, value) when is_binary(value) and value != "" do
    Map.update!(summary, key, fn counts -> Map.update(counts, value, 1, &(&1 + 1)) end)
  end

  defp increment_nested(summary, _key, _value), do: summary

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(_map, _key), do: nil

  defp message_datetime(message) do
    message
    |> read_field(:internal_date)
    |> parse_datetime()
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value)
       when is_binary(value) and byte_size(value) <= 100 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp extract_email(nil), do: nil

  defp extract_email(raw) when is_binary(raw) do
    raw = PromptBudget.truncate_utf8(raw, 512)

    email =
      case Regex.run(~r/<([^>]+)>/, raw) do
        [_, address] -> address
        _ -> raw
      end

    email
    |> String.trim()
    |> String.downcase()
  end

  defp extract_email(_raw), do: nil

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) ->
        bounded_valid_binary?(value, 1_024) and String.trim(value) != ""

      _ ->
        false
    end)
  end

  defp format_dt(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_dt(_datetime), do: "unknown time"

  defp bounded_deadline(opts) do
    now_ms = System.monotonic_time(:millisecond)

    runtime_ms =
      opts
      |> Keyword.get(:max_runtime_ms)
      |> positive_integer(@max_user_runtime_ms)
      |> min(@max_user_runtime_ms)

    max_deadline = now_ms + runtime_ms

    case Keyword.get(opts, :deadline_ms) do
      deadline when is_integer(deadline) -> min(deadline, max_deadline)
      _invalid -> max_deadline
    end
  end

  defp deadline_reached?(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  defp remaining_operation_ms(opts) do
    remaining = Keyword.get(opts, :deadline_ms, 0) - System.monotonic_time(:millisecond)
    remaining |> max(0) |> min(@max_gmail_operation_ms)
  end

  defp bounded_note_field(value, max_bytes) when is_binary(value) do
    value
    |> PromptBudget.truncate_utf8(max_bytes)
    |> String.trim()
    |> case do
      "" -> nil
      bounded -> bounded
    end
  end

  defp bounded_note_field(_value, _max_bytes), do: nil

  defp bounded_valid_binary?(value, max_bytes),
    do: is_binary(value) and byte_size(value) <= max_bytes and String.valid?(value)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
