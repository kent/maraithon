defmodule Maraithon.Runtime.BackgroundJobHandler do
  @moduledoc """
  Executes app-level background jobs.

  Keep handlers small and explicit. Source scanners and interactive flows should
  enqueue one of these job types, then return quickly while the queue performs
  the slower work under supervision.
  """

  import Ecto.Query

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.{Connector, Gmail, GoogleCalendar}
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Observation
  alias Maraithon.InsightNotifications
  alias Maraithon.Insights.Refresh
  alias Maraithon.LocalContacts
  alias Maraithon.OpenLoops
  alias Maraithon.OperatorEvents
  alias Maraithon.PrivacyErasure
  alias Maraithon.RelationshipIntelligence
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.PeriodicJobs
  alias Maraithon.Runtime.RecurringJobs
  alias Maraithon.Todos.Brief, as: TodoBrief

  require Logger

  # Default backoff applied when a provider returns 429 without a parseable
  # `Retry-After` header.
  @default_rate_limit_retry_seconds 30

  def execute(%BackgroundJob{
        job_type: "privacy_erasure",
        payload: %{"request_id" => request_id}
      })
      when is_binary(request_id) do
    case PrivacyErasure.perform(request_id) do
      {:ok, %{state: "completed"} = status} ->
        {:ok, privacy_result(status)}

      {:ok, status} ->
        {:ok, privacy_result(status), {:reschedule_in, PrivacyErasure.reschedule_ms()}}

      {:error, :not_found} ->
        {:ok, %{scope: "unknown", state: "gone"}}

      {:error, reason} ->
        {:error, {:privacy_erasure_failed, reason}}
    end
  end

  def execute(%BackgroundJob{job_type: "privacy_erasure"}),
    do: {:error, :invalid_privacy_erasure_payload}

  def execute(%BackgroundJob{
        job_type: "telegram_webhook_event",
        payload: %{"event" => event}
      })
      when is_map(event) do
    case InsightNotifications.process_telegram_event_durable(event) do
      :ok ->
        {:ok, %{source: "telegram_webhook", outcome: "processed"}}

      {:noop, reason} when is_atom(reason) ->
        {:ok, %{source: "telegram_webhook", outcome: "noop", reason: to_string(reason)}}

      {:error, reason} ->
        {:error, {:telegram_event_processing_failed, reason}}

      other ->
        {:error, {:invalid_telegram_processing_result, other}}
    end
  end

  def execute(%BackgroundJob{job_type: "telegram_webhook_event"}),
    do: {:error, :invalid_telegram_webhook_payload}

  def execute(%BackgroundJob{job_type: "gmail_incremental_sync"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      provider = payload_string(job, "provider", "google")

      case ConnectedAccounts.get(user_id, provider) do
        nil ->
          {:error, {:connected_account_not_found, provider}}

        account ->
          case Gmail.sync_history(user_id, account, provider: provider) do
            {:ok, result} ->
              with :ok <- publish_gmail_sync_completed(user_id, account, job, result) do
                {:ok, Map.put(result, :source, "gmail_incremental_sync")}
              end

            {:error, reason} ->
              handle_google_rate_limit(reason)
          end
      end
    end
  end

  def execute(%BackgroundJob{job_type: "calendar_incremental_sync"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      provider = payload_string(job, "provider", "google")

      case ConnectedAccounts.get(user_id, provider) do
        nil ->
          {:error, {:connected_account_not_found, provider}}

        account ->
          case GoogleCalendar.sync_history(user_id, account, provider: provider) do
            {:ok, result} ->
              with :ok <- publish_calendar_sync_completed(user_id, job, result) do
                {:ok, Map.put(result, :source, "calendar_incremental_sync")}
              end

            {:error, reason} ->
              handle_google_rate_limit(reason)
          end
      end
    end
  end

  def execute(%BackgroundJob{job_type: "email_processing"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Refresh.queue_for_user(user_id,
        requested_by: payload_string(job, "requested_by", "background_job"),
        reason: payload_string(job, "reason", "email_processing")
      )
    end
  end

  def execute(%BackgroundJob{job_type: "insight_refresh"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Refresh.queue_for_user(user_id,
        requested_by: payload_string(job, "requested_by", "background_job"),
        reason: payload_string(job, "reason", "background_refresh")
      )
    end
  end

  def execute(
        %BackgroundJob{
          job_type: "todo_brief_generation",
          payload: %{"todo_id" => todo_id}
        } = job
      )
      when is_binary(todo_id) do
    with {:ok, user_id} <- require_user_id(job) do
      case TodoBrief.generate_and_store(user_id, todo_id) do
        {:ok, _todo} ->
          {:ok, %{source: "todo_brief_generation", todo_id: todo_id, status: "ready"}}

        {:error, reason} ->
          defer_model_capacity(reason)
      end
    end
  end

  def execute(%BackgroundJob{job_type: "todo_brief_generation"}),
    do: {:error, :invalid_todo_brief_payload}

  def execute(%BackgroundJob{job_type: "relationship_learning"} = job) do
    with {:ok, user_id} <- require_user_id(job),
         observations when is_list(observations) and observations != [] <-
           get_in(job.payload || %{}, ["observations"]) do
      RelationshipIntelligence.learn_from_observations(user_id, observations,
        source: payload_string(job, "source", "background_relationship_learning")
      )
    else
      [] -> {:ok, %{relationship_learning: "skipped", reason: "no_observations"}}
      nil -> {:ok, %{relationship_learning: "skipped", reason: "no_observations"}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_relationship_observations}
    end
  end

  def execute(%BackgroundJob{job_type: "open_loop_check"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      query = payload_string(job, "query", nil)
      limit = payload_integer(job, "limit", 12)
      snapshot = OpenLoops.snapshot(user_id, query: query, limit: limit)

      _ =
        OperatorEvents.record(%{
          user_id: user_id,
          source: "background_jobs",
          event_type: "open_loop_check.completed",
          source_item_id: job.id,
          dedupe_key: "background:open_loop_check.completed:#{job.id}",
          payload: %{
            "job_id" => job.id,
            "query" => query,
            "totals" => Map.get(snapshot, :totals, %{}),
            "source" => Map.get(snapshot, :source)
          }
        })

      {:ok,
       %{
         source: "background_open_loop_check",
         totals: Map.get(snapshot, :totals, %{}),
         open_loop_tool_names: Map.get(snapshot, :tool_names, [])
       }}
    end
  end

  def execute(%BackgroundJob{job_type: "relationship_ingestion"} = job) do
    case payload_string(job, "window_id", nil) do
      window_id when is_binary(window_id) ->
        result = process_ingestion_window(window_id)

        # New communications change who matters; refresh the activity-based
        # ranking, the relationship graph, and downstream intelligence after
        # each learned window.
        with {:ok, user_id} <- require_user_id(job) do
          _ = Maraithon.Runtime.BackgroundJobs.enqueue_communication_score_refresh(user_id)
          _ = Maraithon.Runtime.BackgroundJobs.enqueue_relationship_graph_refresh(user_id)
          _ = Maraithon.Runtime.BackgroundJobs.enqueue_person_dedupe(user_id)
          _ = Maraithon.Runtime.BackgroundJobs.enqueue_goal_people_discovery(user_id)
          _ = Maraithon.Runtime.BackgroundJobs.enqueue_person_enrichment(user_id)
        end

        result

      _ ->
        {:error, :missing_window_id}
    end
  end

  def execute(%BackgroundJob{job_type: "communication_score_refresh"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      case Maraithon.Crm.CommunicationScore.refresh_for_user(user_id) do
        {:ok, summary} -> {:ok, Map.put(summary, :source, "communication_score_refresh")}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def execute(%BackgroundJob{job_type: "relationship_graph_refresh"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      case Maraithon.Crm.RelationshipGraph.refresh_for_user(user_id) do
        {:ok, summary} -> {:ok, Map.put(summary, :source, "relationship_graph_refresh")}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def execute(%BackgroundJob{job_type: "person_enrichment"} = job) do
    with {:ok, user_id} <- require_user_id(job),
         {:ok, summary} <-
           Maraithon.Crm.PersonEnrichment.run_for_upcoming(user_id,
             days: payload_integer(job, "days", 21),
             max: payload_integer(job, "max", 5)
           ) do
      {:ok, Map.put(summary, :source, "person_enrichment")}
    end
  end

  def execute(%BackgroundJob{job_type: "goal_people_discovery"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Maraithon.Crm.GoalPeopleDiscovery.run(user_id,
        people_limit: payload_integer(job, "people_limit", 500),
        goal_limit: payload_integer(job, "goal_limit", 20),
        links_per_goal: payload_integer(job, "links_per_goal", 12)
      )
    end
  end

  def execute(%BackgroundJob{job_type: "person_dedupe"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      case Maraithon.Crm.PersonDeduper.run(user_id,
             people_limit: payload_integer(job, "people_limit", 5_000),
             group_limit: payload_integer(job, "group_limit", 100),
             max_merges: payload_integer(job, "max_merges", 50)
           ) do
        {:ok, summary} ->
          # SPEC 04 R8: soft-match merge suggestions run on the same cadence
          # as the deterministic deduper, sequenced strictly after it so a
          # pair the deduper just auto-merged this cycle is naturally gone
          # rather than separately flagged. The summary is always attached —
          # including "0 candidates" cycles — so a silently-regressed scan
          # never looks identical to "no duplicates exist".
          {:ok, Map.put(summary, :merge_suggestions, merge_suggestion_summary(user_id))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def execute(%BackgroundJob{job_type: "counterparty_backfill"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Maraithon.Todos.CounterpartyBackfill.run(user_id,
        limit: payload_integer(job, "limit", 500)
      )
    end
  end

  def execute(%BackgroundJob{job_type: "relationship_backfill"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      source = payload_string(job, "source", nil)

      if is_binary(source) do
        process_backfill_page(user_id, source, job)
      else
        {:error, :missing_backfill_source}
      end
    end
  end

  def execute(%BackgroundJob{job_type: "local_messages_embed"} = job) do
    dispatch_local_embed_job(job, Maraithon.LocalMessages.EmbedJob)
  end

  def execute(%BackgroundJob{job_type: "local_notes_embed"} = job) do
    dispatch_local_embed_job(job, Maraithon.LocalNotes.EmbedJob)
  end

  def execute(%BackgroundJob{job_type: "local_voice_memos_embed"} = job) do
    dispatch_local_embed_job(job, Maraithon.LocalVoiceMemos.EmbedJob)
  end

  def execute(%BackgroundJob{job_type: "local_calendar_events_embed"} = job) do
    dispatch_local_embed_job(job, Maraithon.LocalCalendar.EmbedJob)
  end

  def execute(%BackgroundJob{job_type: "local_reminders_embed"} = job) do
    dispatch_local_embed_job(job, Maraithon.LocalReminders.EmbedJob)
  end

  def execute(%BackgroundJob{job_type: "local_files_embed"} = job) do
    dispatch_local_embed_job(job, Maraithon.LocalFiles.EmbedJob)
  end

  def execute(%BackgroundJob{job_type: "memory_items_embedding_backfill"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Maraithon.Memory.EmbeddingBackfill.run_for_user(user_id,
        limit: payload_integer(job, "limit", 25)
      )
    end
  end

  def execute(%BackgroundJob{job_type: "local_contacts_crm_merge"} = job) do
    with {:ok, user_id} <- require_user_id(job),
         contact_ids when is_list(contact_ids) and contact_ids != [] <-
           get_in(job.payload || %{}, ["contact_ids"]) do
      LocalContacts.merge_contacts_into_crm(user_id, contact_ids)
    else
      [] -> {:ok, %{source: "local_contacts_crm_merge", skipped: "no_contacts"}}
      nil -> {:ok, %{source: "local_contacts_crm_merge", skipped: "no_contacts"}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_local_contact_ids}
    end
  end

  def execute(%BackgroundJob{queue: "runtime_provider_account"} = job),
    do: PeriodicJobs.execute(job)

  def execute(%BackgroundJob{queue: "runtime_model_user"} = job),
    do: PeriodicJobs.execute(job)

  def execute(%BackgroundJob{queue: "runtime_recurring"} = job),
    do: RecurringJobs.execute(job)

  def execute(%BackgroundJob{job_type: job_type}),
    do: {:error, {:unknown_background_job, job_type}}

  defp publish_gmail_sync_completed(user_id, account, job, result) do
    _ = wake_source_account(account, "gmail_sync_completed")

    event =
      Connector.build_event("gmail_sync_completed", "gmail", %{
        user_id: user_id,
        provider: account.provider,
        count: Map.get(result, :count, 0)
      })
      |> put_gmail_sync_dedupe_key(job)

    case Connector.publish(gmail_account_topic(user_id, account), event) do
      :ok -> :ok
      {:error, reason} -> {:error, {:gmail_sync_completion_publish_failed, reason}}
    end
  end

  defp wake_source_account(account, reason) do
    case PeriodicJobs.wake_source_account(account) do
      {:ok, _result} ->
        :ok

      {:error, wake_reason} ->
        Logger.warning("Source account wakeup enqueue failed",
          account_reference: Maraithon.Redaction.fingerprint(account.id),
          trigger: reason,
          failure_code: Maraithon.Redaction.error_class(wake_reason)
        )

        :ok
    end
  end

  defp put_gmail_sync_dedupe_key(event, job) do
    case job.dedupe_key || job.id do
      identity when is_binary(identity) and identity != "" ->
        Map.put(event, :dedupe_key, "#{identity}:gmail_sync_completed")

      _missing_identity ->
        event
    end
  end

  defp gmail_account_topic(user_id, account) do
    metadata = account.metadata || %{}

    account_email =
      metadata["account_email"] || metadata["email"] || account.external_account_id ||
        gmail_provider_email(account.provider) || user_id

    "email:#{account_email |> to_string() |> String.trim() |> String.downcase()}"
  end

  defp gmail_provider_email("google:" <> account_email) when account_email != "",
    do: account_email

  defp gmail_provider_email(_provider), do: nil

  defp publish_calendar_sync_completed(user_id, job, result) do
    event =
      Connector.build_event("calendar_sync_completed", "google_calendar", %{
        user_id: user_id,
        count: Map.get(result, :count, 0)
      })
      |> put_calendar_sync_dedupe_key(job)

    case Connector.publish("calendar:#{user_id}", event) do
      :ok -> :ok
      {:error, reason} -> {:error, {:calendar_sync_completion_publish_failed, reason}}
    end
  end

  defp put_calendar_sync_dedupe_key(event, job) do
    case job.dedupe_key || job.id do
      identity when is_binary(identity) and identity != "" ->
        Map.put(event, :dedupe_key, "#{identity}:calendar_sync_completed")

      _missing_identity ->
        event
    end
  end

  defp dispatch_local_embed_job(%BackgroundJob{} = job, module) do
    case payload_string(job, "record_id", nil) do
      record_id when is_binary(record_id) ->
        module.run(record_id)

      _ ->
        {:error, :missing_record_id}
    end
  end

  @doc false
  def process_ingestion_window(window_id) do
    case Repo.get(Window, window_id) do
      nil ->
        {:error, :window_not_found}

      %Window{status: "completed"} ->
        {:ok, %{source: "crm_ingest", window_id: window_id, skipped: "already_completed"}}

      %Window{} = window ->
        observations =
          Repo.all(
            from o in Observation, where: o.window_id == ^window_id, order_by: o.occurred_at
          )

        run_ingestion_passes(window, observations)
    end
  end

  defp run_ingestion_passes(%Window{} = window, observations) do
    user_id = window.user_id
    now = DateTime.utc_now()

    with {:ok, relationship_result} <-
           run_relationship_pass(user_id, observations, now),
         {:ok, open_loop_result} <- run_open_loop_pass(user_id, observations, now) do
      mark_window_completed(window, observations, now, relationship_result, open_loop_result)
      record_completion_event(window, observations, relationship_result, open_loop_result, now)

      {:ok,
       %{
         source: "crm_ingest",
         window_id: window.id,
         observations_count: length(observations),
         relationship: relationship_result,
         open_loop: open_loop_result
       }}
    else
      {:error, stage, reason} ->
        mark_window_failed(window, "#{stage}:#{inspect(reason)}", now)
        {:error, reason}
    end
  end

  defp run_relationship_pass(_user_id, [], _now), do: {:ok, %{skipped: "no_observations"}}

  defp run_relationship_pass(user_id, observations, now) do
    intelligence_input = Enum.map(observations, &Observation.to_intelligence_input/1)

    case RelationshipIntelligence.learn_from_observations(user_id, intelligence_input,
           source: "crm_ingest",
           now: now
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, :relationship_pass, reason}
    end
  end

  defp run_open_loop_pass(_user_id, [], _now), do: {:ok, %{skipped: "no_observations"}}

  defp run_open_loop_pass(user_id, observations, now) do
    intelligence_input = Enum.map(observations, &Observation.to_intelligence_input/1)

    case OpenLoops.reconcile_from_observations(user_id, intelligence_input,
           source: "crm_ingest",
           now: now
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, :open_loop_pass, reason}
    end
  end

  defp mark_window_completed(%Window{} = window, observations, now, _r, _o) do
    obs_ids = Enum.map(observations, & &1.id)

    if obs_ids != [] do
      Repo.update_all(
        from(o in Observation, where: o.id in ^obs_ids),
        set: [learned_at: now, updated_at: now]
      )
    end

    Repo.update_all(
      from(w in Window, where: w.id == ^window.id),
      set: [
        status: "completed",
        completed_at: now,
        last_error: nil,
        updated_at: now
      ]
    )
  end

  defp mark_window_failed(%Window{} = window, last_error, now) do
    Repo.update_all(
      from(w in Window, where: w.id == ^window.id),
      set: [
        status: "failed",
        failed_at: now,
        last_error: String.slice(last_error || "", 0, 1_000),
        updated_at: now
      ]
    )
  end

  defp record_completion_event(
         %Window{} = window,
         observations,
         relationship_result,
         open_loop_result,
         now
       ) do
    people_touched =
      observations
      |> Enum.flat_map(&(&1.resolved_person_ids || []))
      |> Enum.uniq()
      |> length()

    todos_touched =
      open_loop_result
      |> Map.get(:todo_changes, [])
      |> length()

    _ =
      OperatorEvents.record(%{
        user_id: window.user_id,
        source: "crm_ingest",
        event_type: "crm_ingest.completed",
        source_item_id: window.id,
        dedupe_key: "crm_ingest:completed:#{window.id}",
        occurred_at: now,
        payload: %{
          "window_id" => window.id,
          "source" => window.source,
          "observations_count" => length(observations),
          "people_touched" => people_touched,
          "todos_touched" => todos_touched,
          "relationship_summary" => Map.get(relationship_result, :summary),
          "open_loop_summary" => Map.get(open_loop_result, :ingested) |> summarize_ingested()
        }
      })

    :ok
  end

  defp summarize_ingested(nil), do: nil

  defp summarize_ingested(%{} = ingested) do
    %{
      "todos" => Map.get(ingested, :todos, []) |> length(),
      "decisions" => Map.get(ingested, :decisions, []) |> length()
    }
  end

  defp summarize_ingested(_), do: nil

  defp process_backfill_page(user_id, source, %BackgroundJob{} = job) do
    max_observations = payload_integer(job, "max_observations", 5_000)
    observations_so_far = payload_integer(job, "observations_so_far", 0)

    if observations_so_far >= max_observations do
      _ = Ingest.flush_pending(user_id, source)

      {:ok,
       %{
         source: "crm_backfill",
         user_id: user_id,
         backfill_source: source,
         status: "ceiling_reached",
         observations: observations_so_far
       }}
    else
      # v1: backfill is a no-op landing surface. Real connector pagers will be
      # wired per source in a follow-up; flushing any pending observations
      # keeps the chain idempotent in the meantime.
      _ = Ingest.flush_pending(user_id, source)

      Logger.info("relationship_backfill page accepted",
        user_id: user_id,
        source: source,
        observations_so_far: observations_so_far
      )

      {:ok,
       %{
         source: "crm_backfill",
         user_id: user_id,
         backfill_source: source,
         status: "noop",
         observations: observations_so_far
       }}
    end
  end

  # Google APIs (Gmail, Calendar) surface 429s as `Maraithon.HTTP`'s
  # `:rate_limited` error. Rather than burning a job attempt on a transient
  # rate limit, translate it into `{:retry_after, seconds, reason}` so
  # `BackgroundJobRunner` reschedules at `Retry-After` (or a default backoff)
  # without incrementing `attempts`.
  defp handle_google_rate_limit({:rate_limited, retry_after_seconds, _body} = reason)
       when is_integer(retry_after_seconds) do
    {:error, {:retry_after, retry_after_seconds, reason}}
  end

  defp handle_google_rate_limit({:rate_limited, _body} = reason) do
    {:error, {:retry_after, @default_rate_limit_retry_seconds, reason}}
  end

  defp handle_google_rate_limit(reason), do: {:error, reason}

  # Todo briefs share the bounded model gate with other reasoning work. Local
  # slot pressure and provider cooldowns are scheduling signals, not failed
  # brief attempts, so preserve them for BackgroundJobRunner's durable
  # retry-after path instead of spending the job's three-attempt budget.
  @doc false
  def defer_model_capacity(reason) do
    case PeriodicJobs.retry_after_seconds_for(reason) do
      {:ok, seconds} -> {:error, {:retry_after, seconds, reason}}
      :none -> {:error, reason}
    end
  end

  # SPEC 04 R8-R10: the suggestion pass proposes only (PreparedAction +
  # Telegram confirm card); it never merges. A failure here must not fail
  # the dedupe job, but it must stay visible in the job result.
  defp merge_suggestion_summary(user_id) do
    case Maraithon.Crm.PersonMergeSuggestions.run(user_id) do
      {:ok, summary} -> summary
      {:error, reason} -> %{source: "person_merge_suggestions", error: inspect(reason)}
    end
  rescue
    error -> %{source: "person_merge_suggestions", error: Exception.message(error)}
  end

  defp privacy_result(status) do
    %{
      scope: Map.get(status, :scope, "unknown"),
      state: Map.get(status, :state, "unknown"),
      blocker_code: Map.get(status, :blocker_code)
    }
  end

  defp require_user_id(%BackgroundJob{user_id: user_id})
       when is_binary(user_id) and user_id != "",
       do: {:ok, user_id}

  defp require_user_id(_job), do: {:error, :missing_user_id}

  defp payload_string(%BackgroundJob{payload: payload}, key, default) when is_map(payload) do
    case Map.get(payload, key, default) do
      nil -> default
      "" -> default
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end
  end

  defp payload_string(_job, _key, default), do: default

  defp payload_integer(%BackgroundJob{payload: payload}, key, default) when is_map(payload) do
    case Map.get(payload, key, default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp payload_integer(_job, _key, default), do: default

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end
end
