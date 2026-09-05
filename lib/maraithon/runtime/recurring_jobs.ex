defmodule Maraithon.Runtime.RecurringJobs do
  @moduledoc """
  Durable schedules for application maintenance and bounded work discovery.

  Every schedule is one stable active `background_jobs` row. Successful
  interval work reschedules that exact claim from the PostgreSQL clock;
  wall-clock work supplies an exact PostgreSQL-computed deadline. Reconcile
  only repairs missing rows under a transaction-scoped advisory lock. PIDs and
  poll timers are wakeup hints, never schedule or ownership authority.
  """

  import Ecto.Query

  alias Maraithon.AssistantChat.RunRecovery
  alias Maraithon.PrivacyErasure
  alias Maraithon.PrivacyRetention
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.BriefNotifier
  alias Maraithon.Runtime.BriefingCron
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.DogfoodDigest
  alias Maraithon.Runtime.InsightNotifier
  alias Maraithon.Runtime.PeriodicJobs
  alias Maraithon.TelegramAssistant.RunReaper
  alias Maraithon.Todos.OutcomeLearning

  require Logger

  @queue "runtime_recurring"
  @job_type_prefix "runtime_recurring:"
  @dedupe_prefix "runtime-recurring:"
  @authority_lock "maraithon:runtime-recurring-jobs:v2"

  @doc "Returns the currently configured durable recurring-job specifications."
  def specs do
    [
      interval_spec(
        "insight_notifier",
        Config.positive_integer(:insight_notify_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:insight_notify_initial_delay_ms, :timer.seconds(1))
      ),
      interval_spec(
        "brief_notifier",
        Config.positive_integer(:brief_notify_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:brief_notify_initial_delay_ms, :timer.seconds(2))
      ),
      interval_spec(
        "briefing_cron",
        Config.positive_integer(:briefing_cron_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:briefing_cron_initial_delay_ms, :timer.seconds(5))
      ),
      interval_spec(
        "assistant_run_recovery",
        Config.positive_integer(:assistant_run_recovery_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:assistant_run_recovery_initial_delay_ms, :timer.minutes(1))
      ),
      interval_spec(
        "telegram_run_reaper",
        Config.positive_integer(:run_reaper_poll_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:run_reaper_initial_delay_ms, :timer.minutes(1))
      ),
      interval_spec(
        "token_refresher",
        Config.positive_integer(:oauth_refresh_interval_ms, :timer.minutes(5)),
        Config.positive_integer(:oauth_refresh_initial_delay_ms, :timer.seconds(5))
      ),
      interval_spec(
        "watch_renewer",
        Config.positive_integer(:watch_renewal_interval_ms, :timer.minutes(30)),
        Config.positive_integer(:watch_renewal_initial_delay_ms, :timer.seconds(10))
      ),
      interval_spec(
        "freshness_sweep",
        Config.positive_integer(:freshness_sweep_interval_ms, :timer.hours(1)),
        Config.positive_integer(:freshness_sweep_initial_delay_ms, :timer.seconds(15))
      ),
      configured_interval_spec(
        "proactive_check_in",
        :proactive_check_in_interval_ms,
        :timer.minutes(10),
        :proactive_check_in_initial_delay_ms
      ),
      configured_interval_spec(
        "source_account_discovery",
        :source_account_discovery_interval_ms,
        :timer.minutes(1),
        :source_account_discovery_initial_delay_ms
      ),
      configured_interval_spec(
        "todo_completion_sweep",
        :todo_completion_sweep_interval_ms,
        :timer.minutes(1),
        :todo_completion_sweep_initial_delay_ms
      ),
      configured_interval_spec(
        "nudge_sweep",
        :nudge_sweep_interval_ms,
        :timer.minutes(30),
        :nudge_sweep_initial_delay_ms
      ),
      interval_spec("critical_todo_push", :timer.minutes(5), :timer.seconds(15)),
      configured_interval_spec(
        "staleness_triage_sweep",
        :staleness_triage_sweep_interval_ms,
        :timer.hours(24),
        :staleness_triage_sweep_initial_delay_ms
      ),
      wall_clock_spec("dogfood_digest"),
      interval_spec(
        "todo_outcome_learning_recovery",
        Config.positive_integer(:todo_outcome_learning_recovery_interval_ms, :timer.minutes(5)),
        Config.positive_integer(
          :todo_outcome_learning_recovery_initial_delay_ms,
          :timer.minutes(5)
        )
      ),
      interval_spec(
        "privacy_erasure_discovery",
        Config.positive_integer(:privacy_erasure_discovery_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:privacy_erasure_discovery_initial_delay_ms, :timer.seconds(10))
      ),
      interval_spec(
        "privacy_retention",
        Config.positive_integer(:privacy_retention_interval_ms, :timer.minutes(15)),
        Config.positive_integer(:privacy_retention_initial_delay_ms, :timer.seconds(20))
      )
    ]
  end

  @doc "Repairs missing durable schedules while holding transaction-scoped authority."
  def reconcile do
    case DbResilience.with_database("recurring background job reconcile", fn ->
           Repo.transaction(fn ->
             if take_advisory_authority!() do
               now = database_now!()

               jobs = Enum.map(specs(), &repair_spec(&1, now))

               %{authority: true, jobs: jobs}
             else
               %{authority: false, jobs: []}
             end
           end)
         end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def execute(%BackgroundJob{job_type: job_type} = job) when is_binary(job_type) do
    case Enum.find(specs(), &(&1.job_type == job_type)) do
      nil ->
        {:error, {:unknown_recurring_job, job_type}}

      %{schedule: {:interval, interval_ms}} = spec ->
        case run_cycle(spec.name) do
          {:error, _reason} = error -> error
          {:ok, result} -> {:ok, result, {:reschedule_in, interval_ms}}
          result -> {:ok, result, {:reschedule_in, interval_ms}}
        end

      %{schedule: :wall_clock} = spec ->
        execute_wall_clock(spec, job)
    end
  end

  @doc false
  def job_type(name) when is_binary(name), do: @job_type_prefix <> name

  @doc false
  def dedupe_key(name) when is_binary(name), do: @dedupe_prefix <> name

  @doc false
  def queue, do: @queue

  defp configured_interval_spec(name, interval_key, default, initial_delay_key) do
    interval_ms = Config.positive_integer(interval_key, default)
    initial_delay_ms = Config.positive_integer(initial_delay_key, interval_ms)
    interval_spec(name, interval_ms, initial_delay_ms)
  end

  defp interval_spec(name, interval_ms, initial_delay_ms) do
    %{
      name: name,
      job_type: job_type(name),
      dedupe_key: dedupe_key(name),
      schedule: {:interval, interval_ms},
      initial_delay_ms: initial_delay_ms
    }
  end

  defp wall_clock_spec(name) do
    %{
      name: name,
      job_type: job_type(name),
      dedupe_key: dedupe_key(name),
      schedule: :wall_clock
    }
  end

  defp repair_spec(%{schedule: {:interval, _}} = spec, now) do
    case BackgroundJobs.enqueue(spec.job_type, %{
           queue: @queue,
           dedupe_key: spec.dedupe_key,
           max_attempts: 3,
           scheduled_at: initial_scheduled_at(spec, now),
           payload: %{"recurring_job" => spec.name}
         }) do
      {:ok, %BackgroundJob{} = job} ->
        %{name: spec.name, id: job.id, status: job.status}

      {:error, reason} ->
        Repo.rollback({:recurring_job_enqueue_failed, spec.name, reason})
    end
  end

  defp repair_spec(%{name: "dogfood_digest", schedule: :wall_clock} = spec, now) do
    case configured_dogfood_options() do
      {:ok, opts} ->
        with %DateTime{} = scheduled_at <- dogfood_next_fire(now, opts),
             payload = dogfood_payload(opts),
             {:ok, %BackgroundJob{} = job} <-
               BackgroundJobs.enqueue(spec.job_type, %{
                 queue: @queue,
                 dedupe_key: spec.dedupe_key,
                 max_attempts: 3,
                 scheduled_at: scheduled_at,
                 payload: payload
               }) do
          job = repair_wall_clock_payload(job, payload, scheduled_at, now)
          %{name: spec.name, id: job.id, status: job.status}
        else
          {:error, reason} -> Repo.rollback({:recurring_job_enqueue_failed, spec.name, reason})
        end

      {:error, :invalid_dogfood_digest_timezone} ->
        Logger.error("Dogfood digest schedule repair rejected: invalid timezone configuration")

        case existing_active_job(spec) do
          %BackgroundJob{} = job ->
            %{name: spec.name, id: job.id, status: job.status, repair: "rejected"}

          nil ->
            %{name: spec.name, id: nil, status: "disabled", repair: "rejected"}
        end
    end
  end

  defp repair_wall_clock_payload(job, payload, scheduled_at, now) do
    if job.payload == payload do
      job
    else
      case Repo.update_all(
             from(candidate in BackgroundJob,
               where: candidate.id == ^job.id and candidate.status == "pending"
             ),
             set: [payload: payload, scheduled_at: scheduled_at, updated_at: now]
           ) do
        {1, _rows} -> Repo.get!(BackgroundJob, job.id)
        {0, _rows} -> job
      end
    end
  end

  defp existing_active_job(spec) do
    Repo.one(
      from(job in BackgroundJob,
        where: job.dedupe_key == ^spec.dedupe_key,
        where: job.status in ["pending", "running"],
        order_by: [desc: job.inserted_at],
        limit: 1
      )
    )
  end

  defp initial_scheduled_at(%{schedule: {:interval, _}, initial_delay_ms: delay}, now),
    do: DateTime.add(now, delay, :millisecond)

  defp execute_wall_clock(%{name: "dogfood_digest"}, %BackgroundJob{} = job) do
    with {:ok, opts} <- dogfood_options_for(job),
         now = database_now!(),
         {:ok, outcome} <- DogfoodDigest.deliver(now, opts),
         %DateTime{} = next_fire <- dogfood_next_fire(database_now!(), opts) do
      {:ok, %{outcome: to_string(outcome), next_fire_at: next_fire}, {:reschedule_at, next_fire}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp dogfood_options_for(%BackgroundJob{payload: %{"wall_clock" => persisted}})
       when is_map(persisted) do
    persisted
    |> Map.put("user_id", Config.get(:dogfood_user_id, nil))
    |> normalize_dogfood_options()
  end

  defp dogfood_options_for(_job), do: configured_dogfood_options()

  defp configured_dogfood_options do
    %{
      "user_id" => Config.get(:dogfood_user_id, nil),
      "hour" => Config.get(:dogfood_digest_hour, 7),
      "minute" => Config.get(:dogfood_digest_minute, 30),
      "timezone" => Config.get(:dogfood_digest_timezone, "America/Toronto")
    }
    |> normalize_dogfood_options()
  end

  defp normalize_dogfood_options(options) do
    timezone = options["timezone"]

    if DogfoodDigest.timezone_valid?(timezone) do
      {:ok,
       %{
         user_id: options["user_id"],
         hour: bounded_schedule_integer(options["hour"], 0..23, 7),
         minute: bounded_schedule_integer(options["minute"], 0..59, 30),
         timezone: String.trim(timezone)
       }}
    else
      {:error, :invalid_dogfood_digest_timezone}
    end
  end

  defp dogfood_payload(opts) do
    %{
      "recurring_job" => "dogfood_digest",
      "wall_clock" => %{
        "hour" => opts.hour,
        "minute" => opts.minute,
        "timezone" => opts.timezone
      }
    }
  end

  defp dogfood_next_fire(now, opts) do
    DogfoodDigest.next_fire_after(now, opts.hour, opts.minute, opts.timezone)
  end

  defp bounded_schedule_integer(value, range, default) when is_integer(value) do
    if value in range, do: value, else: default
  end

  defp bounded_schedule_integer(_value, _range, default), do: default

  defp run_cycle("insight_notifier"), do: InsightNotifier.run_once()
  defp run_cycle("brief_notifier"), do: BriefNotifier.run_once()
  defp run_cycle("briefing_cron"), do: BriefingCron.run_once()
  defp run_cycle("assistant_run_recovery"), do: RunRecovery.run_once()
  defp run_cycle("telegram_run_reaper"), do: RunReaper.run_once()
  defp run_cycle("todo_outcome_learning_recovery"), do: OutcomeLearning.recover_pending()
  defp run_cycle("privacy_erasure_discovery"), do: PrivacyErasure.discover_missing_jobs(50)
  defp run_cycle("privacy_retention"), do: PrivacyRetention.run_cycle()
  defp run_cycle(name), do: PeriodicJobs.schedule(name)

  defp take_advisory_authority! do
    case Repo.query!(
           "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
           [@authority_lock],
           log: false
         ).rows do
      [[true]] -> true
      _not_authoritative -> false
    end
  end

  defp database_now! do
    case Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], log: false).rows do
      [[%NaiveDateTime{} = value]] -> DateTime.from_naive!(value, "Etc/UTC")
      [[%DateTime{} = value]] -> value
    end
  end
end
