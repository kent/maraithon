defmodule Maraithon.Runtime.TodoCompletionSweep do
  @moduledoc """
  Runs deterministic and model-assisted completion for durable user partitions.

  The recurring coordinator discovers tenants; the fair model/user lane owns
  execution, retries, and crash recovery. This module has no timer process.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceScope}
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.SlackSourceReplay
  alias Maraithon.Todos.{CompletionSweep, CrossSourceCompletion, Todo, UserBatch}

  @deterministic_batch_size 20
  @cross_source_batch_size 20

  require Logger

  def run_once(opts \\ []) do
    user_ids = UserBatch.open_todo_user_ids(opts)
    bounded_opts = Keyword.put(opts, :user_ids, user_ids)

    bounded_opts
    |> CompletionSweep.run_for_all_users()
    |> Map.put(:cross_source, run_cross_source_pass(bounded_opts))
  end

  @doc "Executes one tenant partition."
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) do
    if Keyword.get(opts, :exhaustive_completion, false) do
      run_for_user_exhaustive(user_id, opts)
    else
      deterministic = CompletionSweep.run_for_user(user_id, opts)

      # A nested error would look like a successful job to the durable runner
      # and suppress retries until the next backstop interval.
      case run_cross_source_user(user_id, opts) do
        {:error, _reason} = error ->
          error

        cross_source ->
          if deterministic.errors == 0 and deterministic.fetch_errors == 0 do
            Map.put(deterministic, :cross_source, cross_source)
          else
            {:error, :completion_sweep_incomplete}
          end
      end
    end
  rescue
    error ->
      Logger.warning("Todo completion user partition crashed",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}

  @doc "Executes one exact connected-account closure partition."
  def run_for_account(account, opts \\ [])

  def run_for_account(%ConnectedAccount{status: "connected"} = account, opts) do
    source_scope = account_source_scope(account)

    with {:ok, source_bundle, proposed_watermarks} <-
           acquire_account_delta(account, source_scope, opts) do
      account_opts =
        opts
        |> Keyword.put(:source_scope, source_scope)
        |> Keyword.put(:exhaustive_completion, true)
        |> maybe_put_source_bundle(source_bundle)

      result = run_for_user(account.user_id, account_opts)

      with :ok <- maybe_advance_closure_watermarks(result, proposed_watermarks) do
        result
      end
    end
  end

  def run_for_account(%ConnectedAccount{}, _opts), do: {:skip, :account_not_connected}
  def run_for_account(_account, _opts), do: {:error, :invalid_account}

  @doc false
  def acquire_account_delta(account, opts \\ [])

  def acquire_account_delta(%ConnectedAccount{} = account, opts) when is_list(opts) do
    with {:ok, _replay} <-
           source_replay_module(account).validate_runtime_replay(
             account,
             Keyword.get(opts, :source_replay),
             "closure"
           ) do
      acquire_account_delta(account, account_source_scope(account), opts)
    end
  end

  def acquire_account_delta(_account, _opts), do: {:error, :invalid_account}

  defp source_replay_module(%ConnectedAccount{provider: "slack:" <> _team_id}),
    do: SlackSourceReplay

  defp source_replay_module(_account), do: GmailSourceReplay

  @doc false
  def open_todo_ids_for_account(account, opts \\ [])

  def open_todo_ids_for_account(%ConnectedAccount{} = account, opts) when is_list(opts) do
    # Evidence belongs to this account, but the work it settles may have been
    # created from another account or source. Snapshot every open todo for the
    # user so a Slack acknowledgement can close Gmail work (and vice versa).
    open_todo_ids(account.user_id, Keyword.delete(opts, :source_account_id))
  end

  def open_todo_ids_for_account(_account, _opts), do: []

  @doc false
  def open_todo_snapshots_for_account(account, opts \\ [])

  def open_todo_snapshots_for_account(%ConnectedAccount{} = account, opts)
      when is_list(opts) do
    Todo
    |> where([todo], todo.user_id == ^account.user_id and todo.status in ["open", "snoozed"])
    |> maybe_scope_todo_ids(Keyword.delete(opts, :source_account_id))
    |> order_by([todo], asc: todo.id)
    |> select([todo], %{
      "id" => todo.id,
      "status" => todo.status,
      "updated_at" => todo.updated_at
    })
    |> Repo.all()
    |> Enum.map(fn snapshot ->
      Map.update!(snapshot, "updated_at", &DateTime.to_iso8601/1)
    end)
  end

  def open_todo_snapshots_for_account(_account, _opts), do: []

  @doc false
  def resolve_todo_decision_manifest(account, todo_ids, evaluated_refs)

  def resolve_todo_decision_manifest(
        %ConnectedAccount{} = account,
        todo_ids,
        evaluated_refs
      )
      when is_list(todo_ids) and is_list(evaluated_refs) do
    todo_ids = Enum.filter(todo_ids, &(is_binary(&1) and &1 != ""))
    evaluated_refs = Enum.filter(evaluated_refs, &(is_binary(&1) and &1 != ""))

    rows =
      Todo
      |> where([todo], todo.user_id == ^account.user_id)
      |> where([todo], todo.id in ^todo_ids)
      |> select([todo], {todo.id, todo.status})
      |> Repo.all()

    row_ids = Enum.map(rows, &elem(&1, 0))
    evaluated_set = MapSet.new(evaluated_refs)

    superseded_refs =
      rows
      |> Enum.filter(fn {id, status} ->
        not MapSet.member?(evaluated_set, id) and status not in ["open", "snoozed"]
      end)
      |> Enum.map(&elem(&1, 0))

    decision_refs = Enum.uniq(evaluated_refs ++ superseded_refs)

    if length(todo_ids) == length(Enum.uniq(todo_ids)) and
         length(evaluated_refs) == length(Enum.uniq(evaluated_refs)) and
         Enum.sort(row_ids) == Enum.sort(todo_ids) and
         Enum.all?(evaluated_refs, &(&1 in todo_ids)) and
         Enum.sort(decision_refs) == Enum.sort(todo_ids) do
      {:ok,
       %{
         decision_refs: todo_ids,
         evaluated_refs: evaluated_refs,
         superseded_refs: superseded_refs
       }}
    else
      {:error, :source_closure_todo_decision_manifest_incomplete}
    end
  end

  def resolve_todo_decision_manifest(_account, _todo_ids, _evaluated_refs),
    do: {:error, :source_closure_todo_decision_manifest_incomplete}

  defp acquire_account_delta(account, source_scope, opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :source_bundle) ->
        {:ok, Keyword.get(opts, :source_bundle), Keyword.get(opts, :proposed_watermarks, [])}

      Keyword.get(opts, :live_sources, true) == false ->
        {:ok, nil, []}

      true ->
        do_acquire_account_delta(account, source_scope, opts)
    end
  end

  defp do_acquire_account_delta(account, source_scope, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    context =
      %{
        user_id: account.user_id,
        timestamp: now,
        trigger: %{type: :pubsub_event, job_type: "source_account_closure"},
        event: %{topic: account_event_topic(account), payload: %{}},
        recent_events: [],
        source_scope: source_scope,
        source_watermark_role: "closure",
        defer_watermark_advance: true,
        exhaustive_account_delta: true,
        account_delta_source: account_delta_source(account)
      }
      |> put_replay_context(opts)

    {bundle, telemetry, proposed_watermarks} =
      Acquisition.build(
        account.user_id,
        ["followthrough"],
        %{"followthrough" => %{"lookback_hours" => 48}},
        context
      )

    if Acquisition.source_complete?(telemetry, account_delta_source(account)) do
      {:ok, bundle, proposed_watermarks}
    else
      {:error, {:source_closure_acquisition_incomplete, account_delta_source(account)}}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  defp put_replay_context(context, opts) when is_map(context) and is_list(opts) do
    case Keyword.get(opts, :source_replay) do
      %{lower: lower, upper: upper, kind: kind}
      when is_integer(lower) and is_integer(upper) and is_binary(kind) ->
        context
        |> Map.put(:source_replay_window, %{lower: lower, upper: upper})
        |> Map.put(:source_watermark_kind_override, kind)

      _other ->
        context
    end
  end

  defp maybe_put_source_bundle(opts, source_bundle) when is_map(source_bundle) do
    Keyword.put(opts, :source_bundle, source_bundle)
  end

  defp maybe_put_source_bundle(opts, _source_bundle), do: opts

  defp maybe_advance_closure_watermarks(result, proposed_watermarks) do
    cond do
      closure_result_settled?(result) ->
        Enum.reduce_while(proposed_watermarks, :ok, fn proposal, :ok ->
          case SourceCursors.put(proposal.account, proposal.kind, %{"value" => proposal.value}) do
            {:ok, _cursor} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:closure_cursor_advance_failed, reason}}}
          end
        end)

      proposed_watermarks == [] ->
        :ok

      true ->
        {:error, :source_closure_incomplete}
    end
  end

  defp closure_result_settled?(%{errors: 0, cross_source: {:error, _reason}}), do: false
  defp closure_result_settled?(%{errors: 0, cross_source: {:skip, :no_open_todos}}), do: false
  defp closure_result_settled?(%{errors: 0, fetch_errors: 0, coverage_complete?: true}), do: true
  defp closure_result_settled?(_result), do: false

  defp run_for_user_exhaustive(user_id, opts) do
    initial_ids = open_todo_ids(user_id, opts)

    deterministic =
      if Keyword.get(opts, :skip_deterministic_completion, false) do
        %{empty_deterministic(user_id) | checked: length(initial_ids)}
      else
        run_deterministic_batches(user_id, initial_ids, opts)
      end

    remaining_ids = open_todo_ids(user_id, opts)
    cross_source = run_cross_source_batches(user_id, remaining_ids, opts)

    case cross_source do
      {:error, _reason} = error ->
        error

      %{} ->
        deterministic
        |> Map.put(:eligible_todos, length(initial_ids))
        |> Map.put(:cross_source, cross_source)
        |> Map.put(:model_calls, result_count(cross_source, :model_calls))
        |> Map.put(:todo_decision_refs, result_string_list(cross_source, :decision_refs))
        |> Map.put(
          :coverage_complete?,
          deterministic.checked == length(initial_ids) and deterministic.errors == 0 and
            deterministic.fetch_errors == 0 and
            cross_source_complete?(cross_source, remaining_ids)
        )
    end
  end

  defp run_deterministic_batches(user_id, todo_ids, opts) do
    todo_ids
    |> Enum.chunk_every(@deterministic_batch_size)
    |> Enum.with_index()
    |> Enum.reduce(empty_deterministic(user_id), fn {batch, index}, acc ->
      result =
        CompletionSweep.run_for_user(
          user_id,
          opts
          |> Keyword.put(:todo_ids, batch)
          |> Keyword.put(:limit, length(batch))
          |> Keyword.put(:now, batch_now(opts, index))
        )

      merge_deterministic(acc, result)
    end)
  end

  defp run_cross_source_batches(_user_id, [], _opts) do
    %{checked: 0, completed: 0, model_calls: 0, expected: 0, decision_refs: []}
  end

  defp run_cross_source_batches(user_id, todo_ids, opts) do
    todo_ids
    |> Enum.chunk_every(@cross_source_batch_size)
    |> Enum.with_index()
    |> Enum.reduce_while(
      %{
        checked: 0,
        completed: 0,
        model_calls: 0,
        expected: length(todo_ids),
        decision_refs: []
      },
      fn {batch, index}, acc ->
        result =
          run_cross_source_user(
            user_id,
            opts
            |> Keyword.put(:todo_ids, batch)
            |> Keyword.put(:exhaustive_completion, true)
            |> Keyword.put(:now, batch_now(opts, index + 10_000))
          )

        case result do
          %{checked: checked, completed: completed} = summary ->
            {:cont,
             %{
               acc
               | checked: acc.checked + checked,
                 completed: acc.completed + completed,
                 model_calls: acc.model_calls + result_count(summary, :model_calls),
                 decision_refs: acc.decision_refs ++ result_string_list(summary, :decision_refs)
             }}

          {:skip, :no_open_todos} ->
            {:cont, acc}

          {:error, reason} ->
            {:halt, {:error, reason}}

          other ->
            {:halt, {:error, {:invalid_cross_source_completion_result, inspect(other)}}}
        end
      end
    )
  end

  defp open_todo_ids(user_id, opts) do
    Todo
    |> where([todo], todo.user_id == ^user_id and todo.status in ["open", "snoozed"])
    |> maybe_scope_todos(opts)
    |> maybe_scope_todo_ids(opts)
    |> order_by([todo], asc: todo.id)
    |> select([todo], todo.id)
    |> Repo.all()
  end

  defp maybe_scope_todos(query, opts) do
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

  defp empty_deterministic(user_id) do
    %{
      user_id: user_id,
      checked: 0,
      completed: 0,
      errors: 0,
      fetch_errors: 0,
      completed_by_source: %{},
      completed_by_reason: %{}
    }
  end

  defp merge_deterministic(acc, result) when is_map(result) do
    acc
    |> Map.update!(:checked, &(&1 + result_count(result, :checked)))
    |> Map.update!(:completed, &(&1 + result_count(result, :completed)))
    |> Map.update!(:errors, &(&1 + result_count(result, :errors)))
    |> Map.update!(:fetch_errors, &(&1 + result_count(result, :fetch_errors)))
    |> Map.update!(
      :completed_by_source,
      &merge_counts(&1, Map.get(result, :completed_by_source, %{}))
    )
    |> Map.update!(
      :completed_by_reason,
      &merge_counts(&1, Map.get(result, :completed_by_reason, %{}))
    )
  end

  defp merge_counts(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp cross_source_complete?(
         %{checked: checked, expected: expected, decision_refs: decision_refs},
         remaining_ids
       ),
       do:
         checked == expected and expected == length(remaining_ids) and
           Enum.sort(decision_refs) == Enum.sort(remaining_ids) and
           length(Enum.uniq(decision_refs)) == expected

  defp cross_source_complete?(_result, _remaining_ids), do: false

  defp result_count(result, key) when is_map(result) do
    case Map.get(result, key) || Map.get(result, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp result_string_list(result, key) when is_map(result) do
    case Map.get(result, key) || Map.get(result, Atom.to_string(key)) do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _other -> []
    end
  end

  defp batch_now(opts, offset) do
    opts
    |> Keyword.get(:now, DateTime.utc_now())
    |> DateTime.add(offset, :microsecond)
  end

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

  defp run_cross_source_user(user_id, opts) do
    cross_source_opts =
      Keyword.take(opts, [
        :now,
        :llm_complete,
        :live_sources,
        :source_bundle,
        :source_bundle_fetcher,
        :source_timeout_ms,
        :source_skill_config,
        :skip_account_message_sources,
        :source_account_id,
        :source_account_unassigned?,
        :source_scope,
        :exact_source_delta,
        :source_item_refs,
        :todo_ids,
        :exhaustive_completion
      ])

    CrossSourceCompletion.run_for_user(user_id, cross_source_opts)
  rescue
    error ->
      Logger.warning("Cross-source completion user partition failed",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      {:error, Maraithon.Redaction.error_class(error)}
  end

  defp run_cross_source_pass(opts) do
    summary =
      opts
      |> Keyword.take([
        :user_ids,
        :now,
        :llm_complete,
        :live_sources,
        :source_bundle,
        :source_bundle_fetcher,
        :source_timeout_ms,
        :source_skill_config
      ])
      |> CrossSourceCompletion.run_for_all_users()

    if summary.completed > 0 or summary.errors > 0 do
      Logger.info("Cross-source completion cycle",
        users: summary.users,
        checked: summary.checked,
        completed: summary.completed,
        skipped: summary.skipped,
        errors: summary.errors
      )
    end

    summary
  rescue
    error ->
      Logger.warning("Cross-source completion cycle failed",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      %{users: 0, checked: 0, completed: 0, skipped: 0, errors: 1}
  end
end
