defmodule Maraithon.ChiefOfStaff.Acquisition do
  @moduledoc """
  Assistant-owned source acquisition for one Chief of Staff cycle.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.{Skills, SourceBundle, SourceScope}
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Crm
  alias Maraithon.Crm.Observation
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.News
  alias Maraithon.OAuth
  alias Maraithon.Redaction
  alias Maraithon.Repo
  alias Maraithon.Slack.UserDirectory
  alias Maraithon.SourceFreshness
  alias Maraithon.Timezones
  alias Maraithon.Tools.SlackHelpers

  require Logger

  @max_gmail_message_limit 250
  @default_gmail_body_fetch_limit 40
  @default_gmail_body_fetch_timeout_ms 5_000
  @default_gmail_fetch_timeout_ms 20_000
  @gmail_candidate_fetch_concurrency 12
  @gmail_provider_fetch_concurrency 3
  @gmail_provider_phase_timeout_ms 9_000
  @gmail_targeted_search_phase_timeout_ms 4_000
  @gmail_candidate_detail_timeout_ms 5_000
  @default_gmail_poll_safety_overlap_seconds 60 * 60
  @gmail_query_boundary_overlap_seconds 1
  @gmail_body_fetch_concurrency 8
  @gmail_body_phase_timeout_ms 8_000
  @default_calendar_limit 250
  @default_calendar_fetch_timeout_ms 15_000
  @default_slack_channel_limit 12
  @default_slack_message_limit 100
  @default_slack_fetch_timeout_ms 45_000
  @default_slack_channel_fetch_timeout_ms 6_000
  @default_slack_search_timeout_ms 6_000
  @default_slack_poll_safety_overlap_seconds 60 * 60
  @slack_thread_fetch_limit 6
  @slack_thread_reply_limit 40
  @slack_user_directory_limit 80
  @slack_user_directory_timeout_ms 1_500
  @slack_conversations_page_limit 1_000
  @slack_history_page_limit 200
  @slack_replies_page_limit 200
  @max_slack_pagination_pages 2_000
  @slack_search_page_limit 100
  @max_slack_search_pages 100
  @slack_self_authored_search_result_limit 50
  @slack_broadcast_search_result_limit 100
  @slack_broadcast_mentions [
    {"@here", "<!here>"},
    {"@channel", "<!channel>"},
    {"@everyone", "<!everyone>"}
  ]
  @slack_loggable_api_error_codes ~w(
    account_inactive
    channel_not_found
    internal_error
    invalid_auth
    missing_scope
    not_authed
    not_in_channel
    rate_limited
    ratelimited
    restricted_action
    thread_not_found
    token_revoked
  )
  @slack_self_authored_search_queries [
    "\"I am going to\"",
    "\"I'm going to\"",
    "\"I will\"",
    "\"I'll\"",
    "\"I need to\"",
    "\"I have to\"",
    "\"follow up\""
  ]
  @default_slack_self_authored_query_limit length(@slack_self_authored_search_queries)
  # R2 (SPEC 04): the no-cursor fallback window for a *scheduled* wakeup scan
  # is 48h, not 14 days — cursor-based delta fetch (Gmail/Slack) already wins
  # whenever a watermark exists, so this only matters pre-cursor and for the
  # sources that have no cursor mechanism (calendar, companion locals).
  # Briefings/backfills that need a deeper window opt in explicitly via
  # `context[:acquisition_deep_lookback]` (see `deep_lookback?/2`).
  @default_lookback_hours 48
  @scheduled_scan_lookback_cap_hours 48
  @default_timezone_offset_hours -5
  @commercial_gmail_lookback_days 7
  @commercial_gmail_query_limit 5
  @default_forward_days 14
  # Gmail's newest-N delta is not enough for high-volume inboxes. These
  # provider-side searches recover likely asks and promises from every
  # connected mailbox before the global candidate cap is applied.
  @default_actionable_gmail_queries [
    ~s(newer_than:14d -in:sent {"can you" "could you" "please send" "please share" "please reply" "action required"}),
    ~s(newer_than:14d -in:sent {"following up" "any update" "when can" deadline urgent asap}),
    ~s(newer_than:14d in:sent {"I will" "I'll" "we will" "we'll" "I can" "we can"}),
    ~s(newer_than:14d in:sent {"will send" "will share" "follow up" "circle back" "get this to you"})
  ]
  @default_commercial_gmail_queries []
  @default_slack_key_channels []
  @default_local_calendar_limit 250
  @default_local_message_limit 200
  @default_local_chat_limit 100
  @default_local_voice_memo_limit 80
  @default_local_note_limit 100
  @default_local_reminder_limit 100
  @default_local_file_limit 100
  @default_local_browser_visit_limit 250
  @default_companion_fetch_timeout_ms 5_000
  @default_news_fetch_timeout_ms 5_000
  @default_weather_fetch_timeout_ms 5_000

  @source_bundle_keys %{
    "gmail" => "gmail",
    "calendar" => "calendar",
    "slack" => "slack",
    "calendar_local" => "calendar_local",
    "imessage" => "imessage",
    "voice_memos" => "voice_memos",
    "notes" => "notes",
    "reminders" => "reminders",
    "files" => "files",
    "browser_history" => "browser_history",
    "news" => "news",
    "weather" => "weather"
  }

  # Returns `{bundle, telemetry, proposed_watermarks}`. `proposed_watermarks`
  # is a list of `%{account:, kind:, value:}` entries — populated whenever
  # `context[:defer_watermark_advance]` is true (the scheduled AIChiefOfStaff
  # cycle sets this so R4's crash-safe advancement can happen in
  # `finalize_cycle/1` instead of here).
  #
  # Watermark advancement is opt-in (post-review fix): the *only* caller that
  # may move `gmail_poll_watermark`/`slack_watermark` forward is the scheduled
  # AIChiefOfStaff cycle (`ensure_cycle/2` sets `defer_watermark_advance:
  # true`, `finalize_cycle/1` applies the proposals). Every other caller
  # (backfills, rebuilds, smoke tests, the completion sweep's evidence read)
  # must NOT advance the cursor the agent's own delta fetch depends on —
  # otherwise they silently consume deltas the agent never sees. Callers that
  # want the cursor to move immediately (none today) can opt in explicitly
  # with `context[:advance_watermarks] == true`. See `watermark_advance_mode/2`.
  def build(user_id, skill_ids, skill_configs, context)
      when is_binary(user_id) and is_list(skill_ids) and is_map(skill_configs) and is_map(context) do
    source_scope = resolve_source_scope(user_id, skill_ids, skill_configs, context)
    bundle = SourceBundle.empty(context, source_scope)
    plan = build_plan(user_id, skill_ids, skill_configs, context)

    {telemetry, bundle} =
      {%{"fetches" => [], "sources" => %{}, "plan" => plan, "proposed_watermarks" => []}, bundle}
      |> run_source_fetches(source_fetchers(user_id, source_scope, plan, context))

    {proposed_watermarks, telemetry} = Map.pop(telemetry, "proposed_watermarks", [])

    {bundle, telemetry, proposed_watermarks}
  end

  def build(_user_id, _skill_ids, _skill_configs, context) when is_map(context) do
    bundle = SourceBundle.empty(context, %{})

    {bundle,
     %{
       "fetches" => [],
       "sources" => %{},
       "plan" => %{}
     }, []}
  end

  @doc "Returns true only when one provider source was enumerated without a partial result."
  def source_complete?(telemetry, source)
      when is_map(telemetry) and source in ["gmail", "slack"] do
    summary = telemetry |> Map.get("sources", %{}) |> Map.get(source, %{})

    summary["status"] == "ready" and
      normalize_list(summary["failed_providers"]) == [] and
      normalize_list(summary["partial_providers"]) == []
  end

  def source_complete?(_telemetry, _source), do: false

  # R10/R11 (SPEC 07): a :pubsub_event trigger on one of the three subscribed
  # topic families (email:/calendar:/slack: — the only topics
  # SourceScope.subscriptions/2 ever returns) fetches gmail + calendar +
  # slack together, but skips news/weather and every companion source: no
  # skill that runs on a :pubsub_event trigger ever consults them.
  # Never narrow further within {gmail, calendar, slack} — Followthrough
  # always runs both its Gmail/Calendar and Slack sub-behaviors in one
  # wakeup, and starving one of data would produce a confidently wrong
  # "nothing to follow up on". Any other trigger (:message, :wakeup, nil, or
  # an unrecognized pubsub topic) fails open to the full unscoped fetch.
  defp source_fetchers(user_id, source_scope, plan, context) do
    connector_fetchers = [
      source_fetcher("gmail", gmail_fetch_timeout_ms(plan), fn state ->
        maybe_fetch_gmail(state, user_id, source_scope, plan, context)
      end),
      source_fetcher("calendar", calendar_fetch_timeout_ms(plan), fn state ->
        maybe_fetch_calendar(state, user_id, source_scope, plan, context)
      end),
      source_fetcher("slack", slack_fetch_timeout_ms(plan), fn state ->
        maybe_fetch_slack(state, user_id, source_scope, plan, context)
      end)
    ]

    cond do
      plan[:account_delta_source] == "gmail" ->
        Enum.filter(connector_fetchers, &(&1.source == "gmail"))

      plan[:account_delta_source] == "slack" ->
        Enum.filter(connector_fetchers, &(&1.source == "slack"))

      pubsub_scoped_trigger?(context) ->
        connector_fetchers

      true ->
        connector_fetchers ++
          [
            source_fetcher("news", news_fetch_timeout_ms(plan), fn state ->
              maybe_fetch_news(state, user_id, source_scope, plan, context)
            end),
            source_fetcher("weather", weather_fetch_timeout_ms(plan), fn state ->
              maybe_fetch_weather(state, user_id, source_scope, plan, context)
            end)
          ] ++ companion_source_fetchers(user_id, plan, context)
    end
  end

  @pubsub_scoped_topic_prefixes ["email:", "calendar:", "slack:"]

  defp pubsub_scoped_trigger?(context) when is_map(context) do
    get_in(context, [:trigger, :type]) == :pubsub_event and
      scoped_pubsub_topic?(get_in(context, [:event, :topic]))
  end

  defp pubsub_scoped_trigger?(_context), do: false

  defp scoped_pubsub_topic?(topic) when is_binary(topic) do
    Enum.any?(@pubsub_scoped_topic_prefixes, &String.starts_with?(topic, &1))
  end

  defp scoped_pubsub_topic?(_topic), do: false

  defp source_fetcher(source, timeout_ms, fun)
       when is_binary(source) and is_integer(timeout_ms) and is_function(fun, 1) do
    %{source: source, timeout_ms: max(timeout_ms, 1), fun: fun}
  end

  defp run_source_fetches({telemetry, bundle} = state, fetchers) when is_list(fetchers) do
    started_at = System.monotonic_time(:millisecond)

    fetchers
    |> Enum.map(fn fetcher ->
      Map.put(
        fetcher,
        :task,
        Task.Supervisor.async_nolink(
          Maraithon.Runtime.ToolCallSupervisor,
          fn -> safe_fetch(fetcher.fun, state) end
        )
      )
    end)
    |> Enum.sort_by(& &1.timeout_ms)
    |> Enum.reduce({telemetry, bundle}, fn fetcher, acc ->
      remaining_ms =
        fetcher.timeout_ms - (System.monotonic_time(:millisecond) - started_at)

      case Task.yield(fetcher.task, max(remaining_ms, 0)) ||
             Task.shutdown(fetcher.task, :brutal_kill) do
        {:ok, {:ok, {source_telemetry, source_bundle}}}
        when is_map(source_telemetry) and is_map(source_bundle) ->
          merge_source_result(acc, source_telemetry, source_bundle)

        {:ok, {:error, reason}} ->
          mark_source_fetch_failed(acc, fetcher.source, reason)

        {:exit, reason} ->
          mark_source_fetch_failed(acc, fetcher.source, Redaction.error_class(reason))

        nil ->
          mark_source_fetch_timeout(acc, fetcher.source, fetcher.timeout_ms)

        other ->
          mark_source_fetch_failed(acc, fetcher.source, Redaction.error_class(other))
      end
    end)
  end

  defp safe_fetch(fun, state) when is_function(fun, 1) do
    {:ok, fun.(state)}
  rescue
    exception ->
      {:error, Redaction.error_class(exception)}
  catch
    kind, reason ->
      {:error, to_string(kind) <> ":" <> Redaction.error_class(reason)}
  end

  defp merge_source_result({telemetry, bundle}, source_telemetry, source_bundle) do
    fetches = Map.get(telemetry, "fetches", []) ++ Map.get(source_telemetry, "fetches", [])

    proposed_watermarks =
      Map.get(telemetry, "proposed_watermarks", []) ++
        Map.get(source_telemetry, "proposed_watermarks", [])

    telemetry =
      telemetry
      |> Map.put("fetches", fetches)
      |> Map.put("proposed_watermarks", proposed_watermarks)
      |> Map.update("sources", Map.get(source_telemetry, "sources", %{}), fn sources ->
        Map.merge(sources, Map.get(source_telemetry, "sources", %{}))
      end)

    {telemetry, merge_source_bundle(bundle, source_bundle)}
  end

  defp merge_source_bundle(bundle, source_bundle) do
    source_bundle
    |> SourceBundle.freshness()
    |> Enum.reduce(bundle, fn {source, freshness}, acc ->
      acc
      |> put_bundle_freshness(source, freshness)
      |> maybe_merge_source_payload(source, source_bundle)
    end)
  end

  defp put_bundle_freshness(bundle, source, freshness) do
    Map.update(bundle, "freshness", %{source => freshness}, &Map.put(&1, source, freshness))
  end

  defp maybe_merge_source_payload(bundle, source, source_bundle) do
    case Map.get(@source_bundle_keys, source) do
      key when is_binary(key) ->
        if Map.has_key?(source_bundle, key) do
          Map.put(bundle, key, Map.get(source_bundle, key))
        else
          bundle
        end

      _other ->
        bundle
    end
  end

  defp mark_source_fetch_timeout({telemetry, bundle}, source, timeout_ms) do
    mark_source_fetch_failed(
      {telemetry, bundle},
      source,
      "source fetch timed out after #{timeout_ms}ms",
      "timeout",
      %{"timeout_ms" => timeout_ms}
    )
  end

  defp mark_source_fetch_failed({telemetry, bundle}, source, reason) do
    mark_source_fetch_failed({telemetry, bundle}, source, reason, "error", %{})
  end

  defp mark_source_fetch_failed({telemetry, bundle}, source, reason, status, metadata) do
    bundle = SourceBundle.mark_unavailable(bundle, source, reason, metadata)

    telemetry =
      telemetry
      |> Map.update("fetches", [], fn fetches ->
        [
          %{
            "source" => source,
            "mode" => "connector",
            "status" => status,
            "reason" => reason
          }
          |> Map.merge(metadata)
          | fetches
        ]
      end)
      |> put_source_summary(
        source,
        %{"status" => status, "reason" => reason} |> Map.merge(metadata)
      )

    {telemetry, bundle}
  end

  defp call_with_timeout(fun, timeout_ms) when is_function(fun, 0) do
    task =
      Task.Supervisor.async_nolink(
        Maraithon.Runtime.ToolCallSupervisor,
        fn -> safe_call(fun) end
      )

    case Task.yield(task, max(timeout_ms, 1)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> result
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    exception ->
      {:error, Redaction.error_class(exception)}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp maybe_fetch_gmail({telemetry, bundle}, _user_id, _source_scope, %{gmail: false}, _context),
    do: {telemetry, bundle}

  defp maybe_fetch_gmail({telemetry, bundle}, user_id, source_scope, plan, context) do
    case event_gmail_messages(context, source_scope) do
      {:ok, %{messages: messages, providers: providers}} ->
        messages = enrich_gmail_messages(messages, user_id, nil, plan)

        bundle =
          SourceBundle.put_gmail(bundle, %{
            "messages" => messages,
            "inbox_messages" => filter_messages_by_label(messages, "INBOX", plan.inbox_limit),
            "sent_messages" => filter_messages_by_label(messages, "SENT", plan.sent_limit),
            "messages_by_provider" => group_messages_by_provider(messages),
            "providers" => providers,
            "metadata" => %{"mode" => "event"},
            "status" => "ready",
            "fetched_at" => context[:timestamp] || DateTime.utc_now()
          })

        telemetry =
          put_source_summary(telemetry, "gmail", %{
            "mode" => "event",
            "providers" => providers,
            "message_count" => length(messages),
            "full_body_count" => count_full_body_messages(messages),
            "body_missing_count" => count_body_missing_messages(messages)
          })

        {telemetry, bundle}

      :fallback ->
        fetch_gmail_from_sources(telemetry, bundle, user_id, source_scope, plan, context)
    end
  end

  defp maybe_fetch_calendar(
         {telemetry, bundle},
         _user_id,
         _source_scope,
         %{calendar: false},
         _context
       ),
       do: {telemetry, bundle}

  defp maybe_fetch_calendar({telemetry, bundle}, user_id, source_scope, plan, context) do
    case event_calendar_events(context) do
      {:ok, events} ->
        bundle =
          SourceBundle.put_calendar(bundle, %{
            "events" => events,
            "events_by_provider" => group_events_by_provider(events),
            "providers" => event_calendar_providers(events),
            "metadata" => %{"mode" => "event"},
            "status" => "ready",
            "fetched_at" => context[:timestamp] || DateTime.utc_now()
          })

        telemetry =
          put_source_summary(telemetry, "calendar", %{
            "mode" => "event",
            "providers" => event_calendar_providers(events),
            "event_count" => length(events)
          })

        {telemetry, bundle}

      :fallback ->
        fetch_calendar_from_sources(telemetry, bundle, user_id, source_scope, plan, context)
    end
  end

  defp maybe_fetch_slack({telemetry, bundle}, _user_id, _source_scope, %{slack: false}, _context),
    do: {telemetry, bundle}

  defp maybe_fetch_slack({telemetry, bundle}, user_id, source_scope, plan, context) do
    team_ids = SourceScope.slack_team_ids(source_scope)

    if team_ids == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "slack", "slack_workspace_not_connected")
      {put_source_summary(telemetry, "slack", %{"status" => "unavailable"}), bundle}
    else
      now = context[:timestamp] || DateTime.utc_now()

      {oldest, now_watermark} =
        case {plan.source_replay_window, slack_source_replay?(plan)} do
          {%{lower: lower, upper: upper}, true} ->
            {Integer.to_string(lower), Integer.to_string(upper)}

          _other ->
            oldest =
              now
              |> DateTime.add(-plan.lookback_hours, :hour)
              |> DateTime.to_unix(:second)
              |> Integer.to_string()

            {oldest, now |> DateTime.to_unix(:second) |> Integer.to_string()}
        end

      watermark_mode = watermark_advance_mode(context, plan)
      watermark_kind = source_watermark_kind(context, "slack")

      {workspaces, fetches, proposed_watermarks} =
        Enum.reduce(team_ids, {[], telemetry["fetches"], []}, fn team_id,
                                                                 {workspace_acc, fetch_acc,
                                                                  watermark_acc} ->
          slack_account = ConnectedAccounts.get(user_id, "slack:#{team_id}")

          {team_oldest, expected_lower_value} =
            if slack_source_replay?(plan) do
              {oldest, oldest}
            else
              slack_poll_oldest(
                slack_account,
                oldest,
                deep_lookback_fetch?(plan),
                watermark_kind
              )
            end

          case fetch_slack_workspace(
                 user_id,
                 source_scope,
                 team_id,
                 plan,
                 team_oldest,
                 now_watermark
               ) do
            {:ok, workspace, workspace_fetches} ->
              # R4: mirrors the gmail/calendar branches - confirms recovery
              # for a Slack workspace previously flagged stale/reauth.
              SourceFreshness.mark_success(user_id, "slack:#{team_id}")

              watermark_acc =
                accumulate_watermark(
                  watermark_acc,
                  slack_account,
                  watermark_kind,
                  now_watermark,
                  watermark_mode,
                  expected_lower_value
                )

              {[workspace | workspace_acc], workspace_fetches ++ fetch_acc, watermark_acc}

            {:error, reason, workspace_fetches} ->
              ConnectedAccounts.report_access_issue(user_id, "slack:#{team_id}", reason)

              Logger.warning("ChiefOfStaff acquisition failed to fetch Slack",
                user_fingerprint: Redaction.fingerprint(user_id),
                workspace_reference: Redaction.fingerprint(team_id),
                failure_code: Redaction.error_class(reason),
                failure_codes: slack_workspace_failure_counts(reason)
              )

              {workspace_acc,
               [
                 %{
                   "source" => "slack",
                   "team_id" => team_id,
                   "mode" => "connector",
                   "status" => "error",
                   "reason" => Redaction.error_class(reason)
                 }
                 | workspace_fetches ++ fetch_acc
               ], watermark_acc}
          end
        end)

      messages =
        workspaces
        |> Enum.flat_map(&slack_workspace_messages/1)

      conversation_count =
        workspaces
        |> Enum.flat_map(&Map.get(&1, "channels", []))
        |> length()

      status = if workspaces == [], do: "partial", else: "ready"

      bundle =
        SourceBundle.put_slack(bundle, %{
          "workspaces" => Enum.reverse(workspaces),
          "mentions" => slack_mentions_from_workspaces(workspaces),
          "providers" => team_ids,
          "metadata" => %{"mode" => "connector", "oldest" => oldest},
          "status" => status,
          "fetched_at" => context[:timestamp] || DateTime.utc_now()
        })

      telemetry =
        telemetry
        |> Map.put("fetches", fetches)
        |> Map.update("proposed_watermarks", proposed_watermarks, &(proposed_watermarks ++ &1))
        |> put_source_summary("slack", %{
          "mode" => "connector",
          "status" => status,
          "teams" => team_ids,
          "workspace_count" => length(workspaces),
          "conversation_count" => conversation_count,
          "message_count" => length(messages)
        })

      {telemetry, bundle}
    end
  end

  # Slack recomputes `oldest = now - lookback_hours` every cycle. When a
  # `slack_watermark` cursor exists for this workspace, fetch only messages
  # after the last successful poll instead; the lookback window remains the
  # fallback for workspaces with no cursor yet. A deep-lookback fetch (fix
  # for the "deep lookback silently bypassed" gap) always uses the widened
  # window instead of the cursor, regardless of what's stored, so morning
  # briefings/backfills actually get the deeper context they asked for.
  defp slack_poll_oldest(_account, fallback_oldest, true, _kind),
    do: {fallback_oldest, nil}

  defp slack_poll_oldest(nil, fallback_oldest, _deep_lookback?, _kind),
    do: {fallback_oldest, nil}

  defp slack_poll_oldest(account, fallback_oldest, _deep_lookback?, kind) do
    case SourceCursors.get(account.id, kind) do
      %{value: value} when is_binary(value) and value != "" ->
        {slack_replay_oldest(value), value}

      _ ->
        {fallback_oldest, nil}
    end
  end

  defp slack_replay_oldest(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds
        |> floor()
        |> Kernel.-(configured_slack_poll_safety_overlap_seconds())
        |> max(0)
        |> Integer.to_string()

      _invalid ->
        value
    end
  end

  defp configured_slack_poll_safety_overlap_seconds do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(
      :slack_poll_safety_overlap_seconds,
      @default_slack_poll_safety_overlap_seconds
    )
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_slack_poll_safety_overlap_seconds
    end
  end

  # Watermark advancement is opt-in and tri-state (post-review fix for the
  # "non-agent callers advance the agent's poll watermarks" gap):
  #
  #   :defer   - the scheduled AIChiefOfStaff cycle (`defer_watermark_advance:
  #              true`) stashes a proposed watermark entry instead of writing
  #              it; `finalize_cycle/1` (R4) advances it only after this
  #              cycle's durable writes have committed, so a mid-cycle crash
  #              reprocesses rather than skips.
  #   :advance - explicit opt-in (`advance_watermarks: true`) for a caller
  #              that wants the immediate-write behavior this module used to
  #              apply unconditionally. No caller uses this today.
  #   :none    - the default for every other caller (backfills, rebuilds,
  #              smoke tests, the completion sweep's evidence read) — the
  #              cursor is left untouched so the agent's own delta fetch
  #              never has deltas silently swallowed out from under it.
  #
  # A deep-lookback fetch is always `:none`: it deliberately reads a much
  # wider window than the delta cursor represents, so it must never move
  # the cursor the normal delta poll depends on.
  defp watermark_advance_mode(context, plan) when is_map(context) do
    cond do
      deep_lookback_fetch?(plan) -> :none
      Map.get(context, :defer_watermark_advance) == true -> :defer
      Map.get(context, :advance_watermarks) == true -> :advance
      true -> :none
    end
  end

  defp watermark_advance_mode(_context, _plan), do: :none

  defp deep_lookback_fetch?(%{deep_lookback?: true}), do: true
  defp deep_lookback_fetch?(_plan), do: false

  defp accumulate_watermark(acc, nil, _kind, _value, _mode, _expected_lower), do: acc

  defp accumulate_watermark(
         acc,
         %ConnectedAccount{} = account,
         kind,
         value,
         :defer,
         expected_lower
       ) do
    [
      %{
        account: %ConnectedAccount{
          id: account.id,
          user_id: account.user_id,
          provider: account.provider
        },
        kind: kind,
        value: value,
        expected_lower_value: expected_lower
      }
      | acc
    ]
  end

  defp accumulate_watermark(
         acc,
         %ConnectedAccount{} = account,
         kind,
         value,
         :advance,
         _expected_lower
       ) do
    case SourceCursors.put(account, kind, %{"value" => value}) do
      {:ok, _cursor} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to advance source watermark",
          provider_reference: Redaction.fingerprint(account.provider),
          kind: kind,
          failure_code: Redaction.error_class(reason)
        )
    end

    acc
  end

  defp accumulate_watermark(
         acc,
         %ConnectedAccount{},
         _kind,
         _value,
         :none,
         _expected_lower
       ),
       do: acc

  defp companion_source_fetchers(user_id, plan, context) when is_binary(user_id) do
    now = context[:timestamp] || DateTime.utc_now()
    lookback_start = DateTime.add(now, -plan.lookback_hours, :hour)
    calendar_end = DateTime.add(now, plan.forward_days, :day)
    timeout_ms = companion_fetch_timeout_ms(plan)

    [
      source_fetcher("calendar_local", timeout_ms, fn state ->
        fetch_companion_source(state, "calendar_local", fn ->
          events =
            user_id
            |> LocalCalendar.events_around(
              since: lookback_start,
              until: calendar_end,
              limit: plan.local_calendar_limit
            )
            |> Enum.map(&local_calendar_event_for_bundle/1)

          {:ok,
           &SourceBundle.put_calendar_local(&1, %{
             "events" => events,
             "counts" => %{"event_count" => length(events)},
             "metadata" => %{"mode" => "companion"}
           }), %{"event_count" => length(events)}}
        end)
      end),
      source_fetcher("imessage", timeout_ms, fn state ->
        fetch_companion_source(state, "imessage", fn ->
          source_messages =
            LocalMessages.recent_for_user(user_id, limit: plan.local_message_limit)

          source_chats =
            LocalMessages.chats_recent(user_id, limit: plan.local_chat_limit, now: now)

          people_by_handle =
            user_id
            |> Crm.people_by_contact_values(message_sender_handles(source_messages, source_chats))

          messages =
            Enum.map(source_messages, &local_message_for_bundle(&1, people_by_handle))

          chats =
            Enum.map(source_chats, &local_chat_for_bundle(&1, people_by_handle))

          {:ok,
           &SourceBundle.put_imessage(&1, %{
             "messages" => messages,
             "chats" => chats,
             "counts" => %{"message_count" => length(messages), "chat_count" => length(chats)},
             "metadata" => %{"mode" => "companion"}
           }), %{"message_count" => length(messages), "chat_count" => length(chats)}}
        end)
      end),
      source_fetcher("voice_memos", timeout_ms, fn state ->
        fetch_companion_source(state, "voice_memos", fn ->
          memos =
            user_id
            |> LocalVoiceMemos.recent_for_user(limit: plan.local_voice_memo_limit)
            |> Enum.map(&voice_memo_for_bundle/1)

          {:ok,
           &SourceBundle.put_voice_memos(&1, %{
             "memos" => memos,
             "counts" => %{"memo_count" => length(memos)},
             "metadata" => %{"mode" => "companion"}
           }), %{"memo_count" => length(memos)}}
        end)
      end),
      source_fetcher("notes", timeout_ms, fn state ->
        fetch_companion_source(state, "notes", fn ->
          notes =
            user_id
            |> LocalNotes.recent_for_user(limit: plan.local_note_limit)
            |> Enum.map(&note_for_bundle/1)

          {:ok,
           &SourceBundle.put_notes(&1, %{
             "notes" => notes,
             "counts" => %{"note_count" => length(notes)},
             "metadata" => %{"mode" => "companion"}
           }), %{"note_count" => length(notes)}}
        end)
      end),
      source_fetcher("reminders", timeout_ms, fn state ->
        fetch_companion_source(state, "reminders", fn ->
          reminders =
            user_id
            |> LocalReminders.due_soon(
              days_ahead: plan.forward_days,
              limit: plan.local_reminder_limit
            )
            |> Enum.map(&reminder_for_bundle/1)

          {:ok,
           &SourceBundle.put_reminders(&1, %{
             "reminders" => reminders,
             "counts" => %{"open_due_soon" => length(reminders)},
             "metadata" => %{"mode" => "companion"}
           }), %{"open_due_soon" => length(reminders)}}
        end)
      end),
      source_fetcher("files", timeout_ms, fn state ->
        fetch_companion_source(state, "files", fn ->
          files =
            user_id
            |> LocalFiles.recent_for_user(limit: plan.local_file_limit)
            |> Enum.map(&file_for_bundle/1)

          {:ok,
           &SourceBundle.put_files(&1, %{
             "files" => files,
             "counts" => %{"recent_count" => length(files)},
             "metadata" => %{"mode" => "companion"}
           }), %{"recent_count" => length(files)}}
        end)
      end),
      source_fetcher("browser_history", timeout_ms, fn state ->
        fetch_companion_source(state, "browser_history", fn ->
          visits =
            user_id
            |> LocalBrowserHistory.recent_visits(limit: plan.local_browser_visit_limit)
            |> Enum.map(&browser_visit_for_bundle/1)

          {:ok,
           &SourceBundle.put_browser_history(&1, %{
             "visits" => visits,
             "counts" => %{"visit_count" => length(visits)},
             "metadata" => %{"mode" => "companion"}
           }), %{"visit_count" => length(visits)}}
        end)
      end)
    ]
  end

  defp companion_source_fetchers(_user_id, _plan, _context), do: []

  defp fetch_companion_source({telemetry, bundle}, source, fetch_fun) do
    case fetch_fun.() do
      {:ok, put_fun, counts} when is_function(put_fun, 1) ->
        bundle = put_fun.(bundle)

        telemetry =
          telemetry
          |> Map.update("fetches", [], fn fetches ->
            [
              %{
                "source" => source,
                "mode" => "companion",
                "status" => "ok"
              }
              |> Map.merge(counts)
              | fetches
            ]
          end)
          |> put_source_summary(
            source,
            %{"mode" => "companion", "status" => "ready"} |> Map.merge(counts)
          )

        {telemetry, bundle}

      {:error, reason} ->
        companion_source_error({telemetry, bundle}, source, reason)
    end
  rescue
    exception ->
      companion_source_error({telemetry, bundle}, source, Redaction.error_class(exception))
  catch
    kind, reason ->
      companion_source_error(
        {telemetry, bundle},
        source,
        to_string(kind) <> ":" <> Redaction.error_class(reason)
      )
  end

  defp companion_source_error({telemetry, bundle}, source, reason) do
    bundle = SourceBundle.mark_unavailable(bundle, source, Redaction.error_class(reason))

    telemetry =
      telemetry
      |> Map.update("fetches", [], fn fetches ->
        [
          %{
            "source" => source,
            "mode" => "companion",
            "status" => "error",
            "reason" => Redaction.error_class(reason)
          }
          | fetches
        ]
      end)
      |> put_source_summary(source, %{
        "mode" => "companion",
        "status" => "error",
        "reason" => Redaction.error_class(reason)
      })

    {telemetry, bundle}
  end

  defp maybe_fetch_news({telemetry, bundle}, _user_id, _source_scope, %{news: false}, _context),
    do: {telemetry, bundle}

  defp maybe_fetch_news({telemetry, bundle}, _user_id, _source_scope, plan, context) do
    now = context[:timestamp] || DateTime.utc_now()

    case news_module().fetch_for_brief(Map.get(plan, :news_config, %{}), now) do
      {:ok, %{} = result} ->
        bundle =
          SourceBundle.put_news(bundle, %{
            "items" => Map.get(result, "items", []),
            "feeds" => Map.get(result, "feeds", []),
            "providers" => Map.get(result, "feeds", []),
            "metadata" => %{"mode" => "rss"},
            "status" => Map.get(result, "status", "ready"),
            "fetched_at" => Map.get(result, "fetched_at", DateTime.to_iso8601(now))
          })

        fetches = Map.get(result, "fetches", [])

        telemetry =
          telemetry
          |> Map.update("fetches", fetches, &(fetches ++ &1))
          |> put_source_summary("news", %{
            "mode" => "rss",
            "status" => Map.get(result, "status", "ready"),
            "feed_count" => length(Map.get(result, "feeds", [])),
            "item_count" => length(Map.get(result, "items", []))
          })

        {telemetry, bundle}

      {:error, reason} ->
        bundle = SourceBundle.mark_unavailable(bundle, "news", Redaction.error_class(reason))

        telemetry =
          put_source_summary(telemetry, "news", %{
            "mode" => "rss",
            "status" => "error",
            "reason" => Redaction.error_class(reason)
          })

        {telemetry, bundle}
    end
  end

  defp maybe_fetch_weather(
         {telemetry, bundle},
         _user_id,
         _source_scope,
         %{weather: false},
         _context
       ),
       do: {telemetry, bundle}

  defp maybe_fetch_weather({telemetry, bundle}, _user_id, _source_scope, plan, context) do
    now = context[:timestamp] || DateTime.utc_now()

    case weather_module().fetch_for_brief(Map.get(plan, :weather_config, %{}), now) do
      {:ok, %{} = result} ->
        bundle = SourceBundle.put_weather(bundle, result)

        telemetry =
          put_source_summary(telemetry, "weather", %{
            "mode" => "open_meteo",
            "status" => Map.get(result, "status", "ready"),
            "location" => Map.get(result, "location")
          })

        {telemetry, bundle}

      {:error, reason} ->
        bundle = SourceBundle.mark_unavailable(bundle, "weather", Redaction.error_class(reason))

        telemetry =
          put_source_summary(telemetry, "weather", %{
            "mode" => "open_meteo",
            "status" => "error",
            "reason" => Redaction.error_class(reason)
          })

        {telemetry, bundle}
    end
  end

  defp fetch_slack_workspace(user_id, source_scope, team_id, plan, oldest, newest) do
    token_preference = if plan.exhaustive_account_delta?, do: "user", else: "auto"

    with {:ok, token} <-
           SlackHelpers.resolve_access_token(user_id, team_id, token_preference: token_preference),
         {:ok, conversations} <-
           list_all_slack_conversations(token.access_token,
             types: ["public_channel", "private_channel", "mpim", "im"]
           ) do
      workspace = SourceScope.slack_workspace_for_team(source_scope, team_id) || %{}

      readable_conversations =
        conversations
        |> Enum.filter(&slack_readable_conversation?/1)
        |> Enum.sort_by(&slack_channel_priority(&1, plan.slack_key_channels))

      conversations =
        readable_conversations
        |> maybe_take_slack_conversations(plan)

      {mentions, mention_fetches, broadcast_fetches, self_authored_messages,
       self_authored_fetches} =
        if slack_durable_event_delta?(plan) or slack_source_replay?(plan) do
          {[], [], [], [], []}
        else
          {direct_mentions, mention_fetches} =
            fetch_slack_mentions(user_id, team_id, workspace, plan, oldest)

          {broadcast_mentions, broadcast_fetches} =
            fetch_slack_broadcast_mentions(user_id, team_id, workspace, plan, oldest)

          {self_authored_messages, self_authored_fetches} =
            fetch_slack_self_authored_messages(user_id, team_id, workspace, plan, oldest)

          {dedupe_slack_messages(direct_mentions ++ broadcast_mentions), mention_fetches,
           broadcast_fetches, self_authored_messages, self_authored_fetches}
        end

      {channels, fetches, _user_directory, coverage_errors} =
        cond do
          slack_durable_event_delta?(plan) ->
            channels =
              conversations
              |> Enum.map(fn channel ->
                channel
                |> serialize_slack_channel()
                |> Map.put("messages", [])
              end)
              |> Enum.reverse()

            fetch = %{
              "source" => "slack",
              "team_id" => team_id,
              "mode" => "durable_event_delta",
              "status" => "ok",
              "conversation_count" => length(conversations),
              "history_request_count" => 0
            }

            {channels, [fetch], %{}, []}

          slack_source_replay?(plan) ->
            # Historical replays use the fully-paginated workspace search below
            # as their source stream. Calling conversations.history once for every
            # readable conversation is both redundant and subject to Slack's
            # per-method rate limit, so it cannot provide a timely proof for a
            # real workspace. We still list every readable conversation here to
            # establish the authorized scope and attach each returned message to
            # its concrete channel, DM, or group DM.
            channels =
              Enum.map(conversations, fn channel ->
                channel
                |> serialize_slack_channel()
                |> Map.put("messages", [])
              end)

            {channels, [], %{}, []}

          true ->
            Enum.reduce(conversations, {[], [], %{}, []}, fn channel,
                                                             {channel_acc, fetch_acc,
                                                              directory_acc, error_acc} ->
              channel_id = channel["id"]

              case call_with_timeout(
                     fn ->
                       fetch_slack_conversation_history(
                         token.access_token,
                         channel_id,
                         oldest,
                         plan
                       )
                     end,
                     slack_channel_fetch_timeout_ms(plan)
                   ) do
                {:ok, history} ->
                  raw_messages =
                    history
                    |> Map.get("messages", [])
                    |> normalize_list()

                  {raw_messages, thread_fetches, thread_errors} =
                    expand_slack_threads(token.access_token, channel_id, raw_messages, plan)

                  user_directory =
                    slack_user_directory(token.access_token, raw_messages, channel, directory_acc)

                  messages =
                    raw_messages
                    |> Enum.map(
                      &serialize_slack_message(&1, channel, team_id, workspace, user_directory)
                    )
                    |> maybe_filter_slack_replay_messages(plan)

                  channel_payload =
                    channel
                    |> serialize_slack_channel()
                    |> put_slack_channel_user_fields(channel, user_directory)
                    |> Map.put("messages", messages)

                  {
                    [channel_payload | channel_acc],
                    [
                      %{
                        "source" => "slack",
                        "team_id" => team_id,
                        "channel_id" => channel_id,
                        "conversation_kind" => slack_conversation_kind(channel),
                        "mode" => "connector",
                        "status" => "ok",
                        "count" => length(messages),
                        "thread_fetch_count" => count_ok_slack_thread_fetches(thread_fetches),
                        "thread_reply_count" => count_slack_thread_replies(thread_fetches)
                      }
                      | thread_fetches ++ fetch_acc
                    ],
                    user_directory,
                    thread_errors ++ error_acc
                  }

                {:error, reason} ->
                  {
                    channel_acc,
                    [
                      %{
                        "source" => "slack",
                        "team_id" => team_id,
                        "channel_id" => channel_id,
                        "conversation_kind" => slack_conversation_kind(channel),
                        "mode" => "connector",
                        "status" => "error",
                        "reason" => Redaction.error_class(reason)
                      }
                      | fetch_acc
                    ],
                    directory_acc,
                    [{:conversation_history_failed, channel_id, reason} | error_acc]
                  }
              end
            end)
        end

      event_messages =
        if slack_source_replay?(plan),
          do: [],
          else: slack_event_messages(user_id, team_id, workspace, oldest, newest, plan)

      {provider_delta_messages, provider_delta_fetches, provider_delta_errors} =
        if slack_durable_event_delta?(plan) or slack_source_replay?(plan) do
          fetch_slack_search_delta(
            user_id,
            token.access_token,
            team_id,
            workspace,
            readable_conversations,
            oldest,
            newest,
            plan
          )
        else
          {[], [], []}
        end

      delta_messages = dedupe_slack_messages(event_messages ++ provider_delta_messages)

      {delta_messages, event_thread_fetches, event_thread_errors} =
        if slack_source_replay?(plan) do
          # A search result already carries every source message, including a
          # reply below an old root. Thread hydration is contextual enrichment,
          # not source discovery; keeping it out of this proof avoids allowing
          # conversations.replies rate limits to erase a known source delta.
          {delta_messages, [], []}
        else
          hydrate_slack_event_threads(
            token.access_token,
            team_id,
            workspace,
            readable_conversations,
            delta_messages,
            plan
          )
        end

      # In the low-latency path, durable events and the provider search delta
      # are the source items. A historical replay uses the fully-paginated
      # provider search stream alone, so it stays complete without exceeding
      # Slack's per-conversation history limits. Thread hydration is optional
      # conversational context and is not allowed to alter that source proof.

      coverage_errors =
        if slack_source_replay?(plan) do
          provider_delta_errors ++ event_thread_errors ++ coverage_errors
        else
          coverage_errors
        end

      channels =
        channels
        |> Enum.reverse()
        |> merge_slack_event_messages(delta_messages)
        |> maybe_prepend_slack_search_channel(self_authored_messages)

      workspace_payload = %{
        "team_id" => team_id,
        "team_name" => Map.get(workspace, "team_name"),
        "channels" => channels,
        "key_channels" => channels,
        "mentions" => mentions,
        "metadata" => %{
          "conversation_count" => length(conversations),
          "conversation_scope" => "all_connected_conversations",
          "token_provider" => token.provider
        }
      }

      workspace_fetches =
        [
          %{
            "source" => "slack",
            "team_id" => team_id,
            "mode" => "durable_event_ingress",
            "status" => "ok",
            "count" => length(event_messages)
          }
          | provider_delta_fetches ++
              event_thread_fetches ++
              self_authored_fetches ++ broadcast_fetches ++ mention_fetches ++ fetches
        ]

      if plan.exhaustive_account_delta? and coverage_errors != [] do
        {:error, {:slack_workspace_incomplete, slack_coverage_failure_counts(coverage_errors)},
         workspace_fetches}
      else
        {:ok, workspace_payload, workspace_fetches}
      end
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  # A fresh reply to an old thread is absent from `conversations.history`:
  # Slack keeps the root in its original chronological position. The signed
  # Events API ingress is therefore authoritative for exact account deltas;
  # provider-backed non-exhaustive snapshots merge the same durable events.
  defp slack_event_messages(user_id, team_id, workspace, oldest, newest, plan) do
    source_accounts =
      [team_id, Map.get(workspace, "external_account_id")]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    query =
      Observation
      |> where(
        [observation],
        observation.user_id == ^user_id and observation.source == "slack" and
          observation.source_account in ^source_accounts
      )
      |> maybe_after_slack_observation(oldest)
      |> maybe_before_slack_observation(newest)
      |> order_by([observation], asc: observation.occurred_at, asc: observation.id)

    query =
      if plan.exhaustive_account_delta?,
        do: query,
        else: limit(query, ^plan.slack_message_limit)

    observations =
      Repo.transaction(fn ->
        _locked_account_id =
          ConnectedAccount
          |> where(
            [account],
            account.user_id == ^user_id and account.provider == ^"slack:#{team_id}" and
              account.status == "connected"
          )
          |> lock("FOR UPDATE")
          |> select([account], account.id)
          |> Repo.one()

        Repo.all(query)
      end)
      |> case do
        {:ok, observations} ->
          observations

        {:error, reason} ->
          raise "Slack event delta lock failed: #{Redaction.error_class(reason)}"
      end

    observations
    |> Enum.map(&slack_observation_message(&1, team_id, workspace))
    |> dedupe_slack_messages()
  end

  # Events API delivery is the low-latency path, but a connected Slack app can
  # be misconfigured or briefly unable to deliver callbacks. One paginated
  # user-token search per workspace is a cheap opportunistic repair lane for
  # roots and replies that Slack search exposes. It is not the authoritative
  # denominator: the per-conversation reconciliation workers own that job.
  # Search is filtered back to the exact cursor window and readable scope. Any
  # pagination Slack does expose must still be consumed completely.
  defp fetch_slack_search_delta(
         user_id,
         access_token,
         team_id,
         workspace,
         readable_conversations,
         oldest,
         newest,
         plan
       ) do
    query = slack_search_window_query(oldest, newest)

    case fetch_all_slack_search_matches(access_token, query, 1, [], 0) do
      {:ok, raw_matches, page_count, total_count} ->
        readable_channel_ids =
          readable_conversations
          |> Enum.map(&normalize_string(&1["id"]))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        {readable_matches, outside_scope_matches} =
          Enum.split_with(raw_matches, fn match ->
            channel_id = slack_match_channel_id(match["channel"])
            is_binary(channel_id) and MapSet.member?(readable_channel_ids, channel_id)
          end)

        messages =
          readable_matches
          |> Enum.filter(&slack_search_match_in_window?(&1, oldest, newest, plan))
          |> Enum.map(&serialize_slack_match(&1, team_id, workspace, %{}))
          |> dedupe_slack_messages()

        {messages, restored_thread_metadata_count} =
          restore_slack_search_thread_metadata(user_id, team_id, messages)

        fetches = [
          %{
            "source" => "slack",
            "team_id" => team_id,
            "mode" => "provider_search_delta",
            "status" => "ok",
            "count" => length(messages),
            "provider_match_count" => total_count,
            "page_count" => page_count,
            "outside_scope_count" => length(outside_scope_matches),
            "restored_thread_metadata_count" => restored_thread_metadata_count
          }
        ]

        {messages, fetches, []}

      {:error, reason} ->
        fetch = %{
          "source" => "slack",
          "team_id" => team_id,
          "mode" => "provider_search_delta",
          "status" => "error",
          "reason" => Redaction.error_class(reason)
        }

        {[], [fetch], [{:provider_search_failed, team_id, reason}]}
    end
  end

  # Legacy Slack search results do not reliably include `thread_ts`. Events
  # API ingress and bounded conversation reconciliation both persist the exact
  # provider message identity with authoritative thread metadata, so recovery
  # search can restore that field with one indexed local read. This keeps
  # search a source-recovery lane and avoids an extra conversations.replies
  # request for every result.
  defp restore_slack_search_thread_metadata(user_id, team_id, messages)
       when is_binary(user_id) and is_binary(team_id) and is_list(messages) do
    missing_source_item_ids =
      messages
      |> Enum.filter(&is_nil(normalize_string(&1["thread_ts"])))
      |> Enum.map(&slack_search_observation_source_item_id(team_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if missing_source_item_ids == [] do
      {messages, 0}
    else
      thread_ts_by_source_item =
        Observation
        |> where(
          [observation],
          observation.user_id == ^user_id and observation.source == "slack" and
            observation.source_item_id in ^missing_source_item_ids
        )
        |> select([observation], {observation.source_item_id, observation.metadata})
        |> Repo.all()
        |> Enum.reduce(%{}, fn {source_item_id, metadata}, acc ->
          case normalize_string((metadata || %{})["thread_ts"]) do
            nil -> acc
            thread_ts -> Map.put(acc, source_item_id, thread_ts)
          end
        end)

      Enum.map_reduce(messages, 0, fn message, restored_count ->
        source_item_id = slack_search_observation_source_item_id(team_id, message)

        case {normalize_string(message["thread_ts"]), thread_ts_by_source_item[source_item_id]} do
          {nil, thread_ts} when is_binary(thread_ts) ->
            {Map.put(message, "thread_ts", thread_ts), restored_count + 1}

          _other ->
            {message, restored_count}
        end
      end)
    end
  end

  defp slack_search_observation_source_item_id(
         team_id,
         %{"channel_id" => channel_id, "ts" => ts}
       )
       when is_binary(team_id) and is_binary(channel_id) and is_binary(ts) do
    "#{team_id}:#{channel_id}:#{ts}"
  end

  defp slack_search_observation_source_item_id(_team_id, _message), do: nil

  defp fetch_all_slack_search_matches(access_token, query, page, acc, page_count)
       when page_count < @max_slack_search_pages do
    case slack_module().search_messages(access_token, query,
           count: @slack_search_page_limit,
           page: page,
           sort: "timestamp",
           sort_dir: "asc"
         ) do
      {:ok, response} ->
        matches =
          response
          |> get_in(["messages", "matches"])
          |> normalize_list()

        accumulated = acc ++ matches
        next_page_count = page_count + 1
        total_count = slack_search_total_count(response, length(accumulated))
        provider_page_count = slack_search_page_count(response, total_count)

        cond do
          provider_page_count > @max_slack_search_pages ->
            {:error, :slack_search_pagination_limit}

          page < provider_page_count ->
            fetch_all_slack_search_matches(
              access_token,
              query,
              page + 1,
              accumulated,
              next_page_count
            )

          length(accumulated) < total_count ->
            {:error, :slack_search_pagination_incomplete}

          true ->
            {:ok, dedupe_raw_slack_search_matches(accumulated), next_page_count, total_count}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_slack_search_matches(_access_token, _query, _page, _acc, _page_count),
    do: {:error, :slack_search_pagination_limit}

  defp slack_search_total_count(response, default) do
    response
    |> get_in(["messages", "total"])
    |> nonnegative_integer(default)
  end

  defp slack_search_page_count(response, total_count) do
    response
    |> get_in(["messages", "pagination", "page_count"])
    |> nonnegative_integer(
      response
      |> get_in(["messages", "paging", "pages"])
      |> nonnegative_integer(ceil_div(total_count, @slack_search_page_limit))
    )
  end

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp nonnegative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> default
    end
  end

  defp nonnegative_integer(_value, default), do: default

  defp dedupe_raw_slack_search_matches(matches) do
    Enum.uniq_by(matches, fn match ->
      {slack_match_channel_id(match["channel"]), normalize_string(match["ts"])}
    end)
  end

  defp slack_search_window_query(oldest, newest) do
    after_date = slack_search_boundary_date(oldest, -1)
    before_date = slack_search_boundary_date(newest, 1)
    "after:#{after_date} before:#{before_date}"
  end

  defp slack_search_boundary_date(timestamp, day_offset) do
    with {seconds, _rest} <- Float.parse(to_string(timestamp)),
         {:ok, datetime} <- DateTime.from_unix(round(seconds * 1_000_000), :microsecond) do
      datetime
      |> DateTime.to_date()
      |> Date.add(day_offset)
      |> Date.to_iso8601()
    else
      _invalid -> Date.utc_today() |> Date.add(day_offset) |> Date.to_iso8601()
    end
  end

  defp slack_search_match_in_window?(match, oldest, newest, plan) do
    with {lower, _rest} <- Float.parse(to_string(oldest)),
         {upper, _rest} <- Float.parse(to_string(newest)),
         ts when ts > 0 <- slack_ts_sort_value(match) do
      if slack_source_replay?(plan),
        do: ts >= lower and ts < upper,
        else: ts > lower and ts <= upper
    else
      _invalid -> false
    end
  end

  defp hydrate_slack_event_threads(
         access_token,
         team_id,
         workspace,
         conversations,
         event_messages,
         plan
       ) do
    readable_channel_ids =
      conversations
      |> Enum.map(&normalize_string(&1["id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {event_messages, inaccessible_event_messages} =
      Enum.split_with(event_messages, fn message ->
        channel_id = normalize_string(message["channel_id"])
        is_binary(channel_id) and MapSet.member?(readable_channel_ids, channel_id)
      end)

    access_boundary_fetches =
      inaccessible_event_messages
      |> Enum.group_by(&normalize_string(&1["channel_id"]))
      |> Enum.map(fn {channel_id, messages} ->
        %{
          "source" => "slack",
          "team_id" => team_id,
          "channel_id" => channel_id,
          "mode" => "durable_event_authorization",
          "status" => "terminal",
          "reason" => "access_boundary",
          "count" => length(messages)
        }
      end)

    thread_refs =
      event_messages
      |> Enum.flat_map(fn message ->
        channel_id = normalize_string(message["channel_id"])
        thread_ts = normalize_string(message["thread_ts"])
        if channel_id && thread_ts, do: [{channel_id, thread_ts}], else: []
      end)
      |> Enum.uniq()

    Enum.reduce(thread_refs, {event_messages, access_boundary_fetches, []}, fn
      {channel_id, thread_ts}, {message_acc, fetch_acc, error_acc} ->
        if MapSet.member?(readable_channel_ids, channel_id) do
          case call_with_timeout(
                 fn -> fetch_slack_thread_replies(access_token, channel_id, thread_ts, plan) end,
                 slack_channel_fetch_timeout_ms(plan)
               ) do
            {:ok, response} ->
              raw_messages = response |> Map.get("messages", []) |> normalize_list()

              channel =
                Enum.find(conversations, &(&1["id"] == channel_id)) || %{"id" => channel_id}

              directory = slack_user_directory(access_token, raw_messages, channel, %{})

              serialized =
                Enum.map(
                  raw_messages,
                  &serialize_slack_message(&1, channel, team_id, workspace, directory)
                )

              fetch = %{
                "source" => "slack",
                "team_id" => team_id,
                "channel_id" => channel_id,
                "thread_ts" => thread_ts,
                "mode" => "event_thread_replies",
                "status" => "ok",
                "count" => length(serialized)
              }

              {attach_slack_thread_context(message_acc, channel_id, thread_ts, serialized),
               [fetch | fetch_acc], error_acc}

            {:error, reason} ->
              fetch = %{
                "source" => "slack",
                "team_id" => team_id,
                "channel_id" => channel_id,
                "thread_ts" => thread_ts,
                "mode" => "event_thread_replies",
                "status" => "error",
                "reason" => Redaction.error_class(reason)
              }

              {message_acc, [fetch | fetch_acc],
               [{:event_thread_replies_failed, channel_id, thread_ts, reason} | error_acc]}
          end
        else
          fetch = %{
            "source" => "slack",
            "team_id" => team_id,
            "channel_id" => channel_id,
            "thread_ts" => thread_ts,
            "mode" => "event_thread_replies",
            "status" => "terminal",
            "reason" => "access_boundary",
            "count" => 0
          }

          {message_acc, [fetch | fetch_acc], error_acc}
        end
    end)
  end

  defp attach_slack_thread_context(messages, channel_id, thread_ts, thread_messages) do
    Enum.map(messages, fn message ->
      if normalize_string(message["channel_id"]) == channel_id and
           normalize_string(message["thread_ts"]) == thread_ts do
        context = bounded_slack_thread_context(message, thread_ts, thread_messages)

        message
        |> Map.put("thread_context", context)
        |> Map.put("thread_context_complete", true)
        |> Map.put("thread_context_frontier", normalize_string(message["ts"]))
      else
        message
      end
    end)
  end

  # Thread replies are provider context, not delta candidates. Keep every
  # message that existed at this event's frontier. The discovery worker owns
  # prompt-size admission and fails closed if the lossless evidence cannot fit;
  # silently dropping an older reply can turn an actionable thread into a
  # false skip.
  defp bounded_slack_thread_context(message, thread_ts, thread_messages) do
    message_ts = normalize_string(message["ts"])
    frontier = slack_ts_sort_value(message)

    eligible =
      thread_messages
      |> Enum.filter(fn thread_message ->
        thread_message_ts = normalize_string(thread_message["ts"])
        thread_message_ts != message_ts and slack_ts_sort_value(thread_message) <= frontier
      end)
      |> Enum.sort_by(&slack_ts_sort_value/1)

    root = Enum.find(eligible, &(normalize_string(&1["ts"]) == thread_ts))

    replies = Enum.reject(eligible, &(normalize_string(&1["ts"]) == thread_ts))

    [root | replies]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&normalize_string(&1["ts"]))
  end

  defp maybe_after_slack_observation(query, oldest) when is_binary(oldest) do
    case Float.parse(oldest) do
      {seconds, _rest} when seconds >= 0 ->
        inserted_after = DateTime.from_unix!(round(seconds * 1_000_000), :microsecond)
        where(query, [observation], observation.inserted_at > ^inserted_after)

      _other ->
        query
    end
  end

  defp maybe_after_slack_observation(query, _oldest), do: query

  defp maybe_before_slack_observation(query, newest) when is_binary(newest) do
    case Float.parse(newest) do
      {seconds, _rest} when seconds >= 0 ->
        inserted_before = DateTime.from_unix!(round(seconds * 1_000_000), :microsecond)
        where(query, [observation], observation.inserted_at <= ^inserted_before)

      _other ->
        query
    end
  end

  defp maybe_before_slack_observation(query, _newest), do: query

  defp slack_observation_message(%Observation{} = observation, team_id, workspace) do
    metadata = observation.metadata || %{}
    channel_id = normalize_string(metadata["channel"])
    ts = normalize_string(metadata["ts"]) || slack_observation_ts(observation, channel_id)

    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => channel_id,
      "channel_name" => "event ingress",
      "conversation_kind" => "event",
      "ts" => ts,
      "thread_ts" => normalize_string(metadata["thread_ts"]),
      "target_ts" => normalize_string(metadata["target_ts"]),
      "subtype" => normalize_string(metadata["event_type"]),
      "provider_event_id" => normalize_string(metadata["provider_event_id"]),
      "user" => slack_observation_user(observation.participants),
      "text" => normalize_string(metadata["text"]) || observation.excerpt,
      "text_resolved" => normalize_string(metadata["text"]) || observation.excerpt,
      "ingress" => "events_api"
    }
  end

  defp slack_observation_ts(%Observation{source_item_id: source_item_id}, channel_id)
       when is_binary(source_item_id) and is_binary(channel_id) do
    source_item_id
    |> String.split(":")
    |> List.last()
  end

  defp slack_observation_ts(%Observation{occurred_at: %DateTime{} = occurred_at}, _channel_id) do
    seconds = DateTime.to_unix(occurred_at, :second)
    microseconds = elem(occurred_at.microsecond, 0)
    "#{seconds}.#{microseconds |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end

  defp slack_observation_ts(_observation, _channel_id), do: nil

  defp slack_observation_user(participants) when is_list(participants) do
    Enum.find_value(participants, fn participant ->
      get_in(participant, ["identifier", "slack_id"])
    end)
  end

  defp slack_observation_user(_participants), do: nil

  defp merge_slack_event_messages(channels, []), do: channels

  defp merge_slack_event_messages(channels, event_messages) do
    {channels, unmatched} =
      Enum.reduce(event_messages, {channels, []}, fn message, {channel_acc, unmatched_acc} ->
        channel_id = message["channel_id"]

        {channel_acc, matched?} =
          Enum.map_reduce(channel_acc, false, fn channel, matched? ->
            if channel["id"] == channel_id do
              messages = merge_serialized_slack_messages(channel["messages"], [message])
              {Map.put(channel, "messages", messages), true}
            else
              {channel, matched?}
            end
          end)

        if matched?,
          do: {channel_acc, unmatched_acc},
          else: {channel_acc, [message | unmatched_acc]}
      end)

    case Enum.reverse(unmatched) do
      [] ->
        channels

      messages ->
        [
          %{
            "id" => "slack_events:delta",
            "name" => "Slack event ingress",
            "conversation_kind" => "event",
            "messages" => messages
          }
          | channels
        ]
    end
  end

  defp merge_serialized_slack_messages(left, right) do
    dedupe_slack_messages(normalize_list(left) ++ normalize_list(right))
  end

  defp fetch_slack_mentions(user_id, team_id, workspace, plan, oldest) do
    user_ids = slack_user_ids_for_team(user_id, team_id)
    oldest_date = slack_search_after_date(oldest)

    user_ids
    |> Enum.take(3)
    |> Enum.reduce({[], []}, fn slack_user_id, {mention_acc, fetch_acc} ->
      query = "<@#{slack_user_id}> after:#{oldest_date}"

      with {:ok, token} <-
             SlackHelpers.resolve_access_token(user_id, team_id,
               token_preference: "user",
               slack_user_id: slack_user_id
             ),
           {:ok, response} <-
             call_with_timeout(
               fn ->
                 slack_module().search_messages(token.access_token, query,
                   count: plan.slack_message_limit,
                   sort: "timestamp",
                   sort_dir: "desc"
                 )
               end,
               slack_search_timeout_ms(plan)
             ) do
        raw_matches =
          response
          |> get_in(["messages", "matches"])
          |> normalize_list()

        user_directory = slack_user_directory(token.access_token, raw_matches, nil)

        matches =
          Enum.map(raw_matches, &serialize_slack_match(&1, team_id, workspace, user_directory))

        {
          mention_acc ++ matches,
          [
            %{
              "source" => "slack",
              "team_id" => team_id,
              "mode" => "mention_search",
              "status" => "ok",
              "slack_user_id" => slack_user_id,
              "count" => length(matches)
            }
            | fetch_acc
          ]
        }
      else
        {:error, :no_user_token} ->
          {mention_acc, fetch_acc}

        {:error, reason} ->
          {mention_acc,
           [
             %{
               "source" => "slack",
               "team_id" => team_id,
               "mode" => "mention_search",
               "status" => "error",
               "slack_user_id" => slack_user_id,
               "reason" => Redaction.error_class(reason)
             }
             | fetch_acc
           ]}
      end
    end)
  end

  defp fetch_slack_broadcast_mentions(user_id, team_id, workspace, plan, oldest) do
    oldest_date = slack_search_after_date(oldest)
    search_limit = slack_broadcast_search_limit(plan)

    case SlackHelpers.resolve_access_token(user_id, team_id, token_preference: "user") do
      {:ok, token} ->
        Enum.reduce(@slack_broadcast_mentions, {[], []}, fn {rendered, raw_token},
                                                            {mention_acc, fetch_acc} ->
          query = "#{rendered} after:#{oldest_date}"

          case call_with_timeout(
                 fn ->
                   slack_module().search_messages(token.access_token, query,
                     count: search_limit,
                     sort: "timestamp",
                     sort_dir: "desc"
                   )
                 end,
                 slack_search_timeout_ms(plan)
               ) do
            {:ok, response} ->
              raw_matches =
                response
                |> get_in(["messages", "matches"])
                |> normalize_list()
                |> Enum.filter(&slack_broadcast_match?(&1, raw_token))
                |> Enum.filter(&slack_search_match_recent?(&1, oldest))

              user_directory = slack_user_directory(token.access_token, raw_matches, nil)

              matches =
                Enum.map(raw_matches, fn match ->
                  match
                  |> serialize_slack_match(team_id, workspace, user_directory)
                  |> Map.put("search_mode", "broadcast_mention")
                  |> Map.put("search_query", query)
                end)

              fetch = %{
                "source" => "slack",
                "team_id" => team_id,
                "mode" => "broadcast_mention_search",
                "status" => "ok",
                "mention" => rendered,
                "count" => length(matches)
              }

              {dedupe_slack_messages(mention_acc ++ matches), [fetch | fetch_acc]}

            {:error, reason} ->
              fetch = %{
                "source" => "slack",
                "team_id" => team_id,
                "mode" => "broadcast_mention_search",
                "status" => "error",
                "mention" => rendered,
                "reason" => Redaction.error_class(reason)
              }

              {mention_acc, [fetch | fetch_acc]}
          end
        end)

      {:error, :no_user_token} ->
        {[], []}

      {:error, reason} ->
        {[],
         [
           %{
             "source" => "slack",
             "team_id" => team_id,
             "mode" => "broadcast_mention_search",
             "status" => "error",
             "reason" => Redaction.error_class(reason)
           }
         ]}
    end
  end

  defp fetch_slack_self_authored_messages(user_id, team_id, workspace, plan, oldest) do
    user_ids = slack_user_ids_for_team(user_id, team_id)
    search_limit = slack_self_authored_search_limit(plan)
    search_timeout_ms = slack_search_timeout_ms(plan)
    queries = slack_self_authored_search_queries(plan)

    user_ids
    |> Enum.take(3)
    |> Enum.reduce({[], []}, fn slack_user_id, {message_acc, fetch_acc} ->
      case SlackHelpers.resolve_access_token(user_id, team_id,
             token_preference: "user",
             slack_user_id: slack_user_id
           ) do
        {:ok, token} ->
          {matches, query_fetches} =
            fetch_slack_self_authored_queries(
              token.access_token,
              team_id,
              workspace,
              slack_user_id,
              search_limit,
              search_timeout_ms,
              queries,
              oldest
            )

          {dedupe_slack_messages(message_acc ++ matches), query_fetches ++ fetch_acc}

        {:error, :no_user_token} ->
          {message_acc, fetch_acc}

        {:error, reason} ->
          {message_acc,
           [
             %{
               "source" => "slack",
               "team_id" => team_id,
               "mode" => "self_authored_search",
               "status" => "error",
               "slack_user_id" => slack_user_id,
               "reason" => Redaction.error_class(reason)
             }
             | fetch_acc
           ]}
      end
    end)
  end

  defp fetch_slack_self_authored_queries(
         access_token,
         team_id,
         workspace,
         slack_user_id,
         search_limit,
         search_timeout_ms,
         queries,
         oldest
       ) do
    Enum.reduce(queries, {[], []}, fn query, {message_acc, fetch_acc} ->
      case call_with_timeout(
             fn ->
               slack_module().search_messages(access_token, query,
                 count: search_limit,
                 sort: "timestamp",
                 sort_dir: "desc"
               )
             end,
             search_timeout_ms
           ) do
        {:ok, response} ->
          raw_matches =
            response
            |> get_in(["messages", "matches"])
            |> normalize_list()
            |> Enum.filter(&slack_search_match_for_user?(&1, slack_user_id))
            |> Enum.filter(&slack_search_match_recent?(&1, oldest))

          user_directory = slack_user_directory(access_token, raw_matches, nil)

          matches =
            raw_matches
            |> Enum.map(fn match ->
              match
              |> serialize_slack_match(team_id, workspace, user_directory)
              |> Map.put("search_mode", "self_authored")
              |> Map.put("search_query", query)
            end)

          fetch = %{
            "source" => "slack",
            "team_id" => team_id,
            "mode" => "self_authored_search",
            "status" => "ok",
            "slack_user_id" => slack_user_id,
            "query" => query,
            "count" => length(matches)
          }

          {dedupe_slack_messages(message_acc ++ matches), [fetch | fetch_acc]}

        {:error, reason} ->
          fetch = %{
            "source" => "slack",
            "team_id" => team_id,
            "mode" => "self_authored_search",
            "status" => "error",
            "slack_user_id" => slack_user_id,
            "query" => query,
            "reason" => Redaction.error_class(reason)
          }

          {message_acc, [fetch | fetch_acc]}
      end
    end)
  end

  defp maybe_prepend_slack_search_channel(channels, []), do: channels

  defp maybe_prepend_slack_search_channel(channels, messages) when is_list(channels) do
    [
      %{
        "id" => "slack_search:self_authored",
        "name" => "self-authored Slack search",
        "conversation_kind" => "search",
        "messages" => dedupe_slack_messages(messages)
      }
      | channels
    ]
  end

  defp slack_broadcast_search_limit(plan) when is_map(plan) do
    plan
    |> Map.get(:slack_message_limit, @default_slack_message_limit)
    |> parse_integer()
    |> case do
      limit when is_integer(limit) and limit > 0 ->
        min(limit, @slack_broadcast_search_result_limit)

      _other ->
        @slack_broadcast_search_result_limit
    end
  end

  defp slack_broadcast_search_limit(_plan), do: @slack_broadcast_search_result_limit

  defp slack_self_authored_search_limit(plan) when is_map(plan) do
    limit =
      plan
      |> Map.get(:slack_message_limit, @default_slack_message_limit)
      |> parse_integer()

    (limit || @default_slack_message_limit)
    |> min(@slack_self_authored_search_result_limit)
  end

  defp slack_self_authored_search_limit(_plan), do: @default_slack_message_limit

  defp slack_self_authored_search_queries(plan) do
    @slack_self_authored_search_queries
    |> Enum.take(slack_self_authored_query_limit(plan))
  end

  defp slack_search_match_for_user?(match, slack_user_id) when is_map(match) do
    normalize_string(match["user"]) == slack_user_id
  end

  defp slack_search_match_for_user?(_match, _slack_user_id), do: false

  defp slack_broadcast_match?(match, raw_token) when is_map(match) and is_binary(raw_token) do
    match
    |> Map.get("text", "")
    |> to_string()
    |> String.contains?(raw_token)
  end

  defp slack_broadcast_match?(_match, _raw_token), do: false

  defp slack_search_match_recent?(match, oldest) when is_map(match) and is_binary(oldest) do
    with {oldest_seconds, _} <- Float.parse(oldest),
         ts when ts > 0 <- slack_ts_sort_value(match) do
      ts >= oldest_seconds
    else
      _ -> true
    end
  end

  defp slack_search_match_recent?(_match, _oldest), do: true

  defp expand_slack_threads(access_token, channel_id, raw_messages, plan)
       when is_binary(access_token) and is_binary(channel_id) and is_list(raw_messages) do
    thread_ids =
      raw_messages
      |> slack_thread_ids_from_messages()
      |> maybe_take_slack_threads(plan)

    Enum.reduce(thread_ids, {raw_messages, [], []}, fn thread_ts,
                                                       {message_acc, fetch_acc, error_acc} ->
      case call_with_timeout(
             fn ->
               fetch_slack_thread_replies(access_token, channel_id, thread_ts, plan)
             end,
             slack_channel_fetch_timeout_ms(plan)
           ) do
        {:ok, response} ->
          replies =
            response
            |> Map.get("messages", [])
            |> normalize_list()

          fetch = %{
            "source" => "slack",
            "channel_id" => channel_id,
            "thread_ts" => thread_ts,
            "mode" => "thread_replies",
            "status" => "ok",
            "count" => length(replies),
            "has_more" => response["has_more"] || false
          }

          {merge_slack_messages(message_acc, replies), [fetch | fetch_acc], error_acc}

        {:error, reason} ->
          fetch = %{
            "source" => "slack",
            "channel_id" => channel_id,
            "thread_ts" => thread_ts,
            "mode" => "thread_replies",
            "status" => "error",
            "reason" => Redaction.error_class(reason)
          }

          {message_acc, [fetch | fetch_acc],
           [{:thread_replies_failed, channel_id, thread_ts, reason} | error_acc]}
      end
    end)
  end

  defp expand_slack_threads(_access_token, _channel_id, raw_messages, _plan),
    do: {raw_messages, [], []}

  defp maybe_take_slack_threads(thread_ids, %{exhaustive_account_delta?: true}), do: thread_ids

  defp maybe_take_slack_threads(thread_ids, _plan),
    do: Enum.take(thread_ids, @slack_thread_fetch_limit)

  defp slack_thread_ids_from_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&slack_thread_ids_from_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp slack_thread_ids_from_messages(_messages), do: []

  defp slack_thread_ids_from_message(message) when is_map(message) do
    ts = normalize_string(message["ts"])
    thread_ts = normalize_string(message["thread_ts"])

    cond do
      thread_ts ->
        [thread_ts]

      slack_threaded_root?(message) and ts ->
        [ts]

      true ->
        []
    end
  end

  defp slack_thread_ids_from_message(_message), do: []

  defp slack_threaded_root?(message) when is_map(message) do
    positive_integer?(message["reply_count"]) or present_string?(message["latest_reply"])
  end

  defp slack_threaded_root?(_message), do: false

  defp positive_integer?(value) when is_integer(value), do: value > 0

  defp positive_integer?(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int > 0
      _ -> false
    end
  end

  defp positive_integer?(_value), do: false

  defp slack_thread_reply_limit(plan) when is_map(plan) do
    plan
    |> Map.get(:slack_message_limit, @default_slack_message_limit)
    |> max(1)
    |> min(@slack_thread_reply_limit)
  end

  defp slack_thread_reply_limit(_plan), do: @default_slack_message_limit

  defp fetch_slack_thread_replies(access_token, channel_id, thread_ts, %{
         exhaustive_account_delta?: true
       }) do
    fetch_all_slack_thread_replies(access_token, channel_id, thread_ts, nil, [], 0)
  end

  defp fetch_slack_thread_replies(access_token, channel_id, thread_ts, plan) do
    slack_module().get_thread_replies(access_token, channel_id, thread_ts,
      limit: slack_thread_reply_limit(plan)
    )
  end

  defp fetch_all_slack_thread_replies(
         access_token,
         channel_id,
         thread_ts,
         cursor,
         acc,
         page_count
       )
       when page_count < @max_slack_pagination_pages do
    opts =
      [limit: @slack_replies_page_limit]
      |> maybe_put_cursor(cursor)

    case slack_module().get_thread_replies(access_token, channel_id, thread_ts, opts) do
      {:ok, response} ->
        messages = acc ++ normalize_list(response["messages"])
        next_cursor = slack_next_cursor(response)

        cond do
          next_cursor ->
            fetch_all_slack_thread_replies(
              access_token,
              channel_id,
              thread_ts,
              next_cursor,
              messages,
              page_count + 1
            )

          response["has_more"] == true ->
            {:error, :slack_thread_pagination_incomplete}

          true ->
            {:ok,
             response
             |> Map.put("messages", dedupe_raw_slack_messages(messages))
             |> Map.put("has_more", false)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_slack_thread_replies(
         _access_token,
         _channel_id,
         _thread_ts,
         _cursor,
         _acc,
         _page_count
       ),
       do: {:error, :slack_thread_pagination_limit}

  defp merge_slack_messages(messages, replies) do
    (normalize_list(messages) ++ normalize_list(replies))
    |> Enum.uniq_by(&normalize_string(&1["ts"]))
    |> Enum.sort_by(&slack_ts_sort_value/1, :desc)
  end

  defp dedupe_slack_messages(messages) when is_list(messages) do
    messages
    |> normalize_list()
    |> Enum.uniq_by(fn message ->
      {
        normalize_string(message["team_id"]),
        normalize_string(message["channel_id"]),
        normalize_string(message["ts"])
      }
    end)
    |> Enum.sort_by(&slack_ts_sort_value/1, :desc)
  end

  defp slack_ts_sort_value(message) when is_map(message) do
    case Float.parse(to_string(message["ts"] || "")) do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  defp slack_ts_sort_value(_message), do: 0.0

  defp count_ok_slack_thread_fetches(fetches) when is_list(fetches) do
    Enum.count(fetches, &(&1["mode"] == "thread_replies" and &1["status"] == "ok"))
  end

  defp count_ok_slack_thread_fetches(_fetches), do: 0

  defp count_slack_thread_replies(fetches) when is_list(fetches) do
    fetches
    |> Enum.filter(&(&1["mode"] == "thread_replies" and &1["status"] == "ok"))
    |> Enum.map(&(&1["count"] || 0))
    |> Enum.sum()
  end

  defp count_slack_thread_replies(_fetches), do: 0

  defp fetch_gmail_from_sources(telemetry, bundle, user_id, source_scope, plan, context) do
    providers = SourceScope.google_account_providers(source_scope, "gmail")

    if providers == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "gmail", "google_gmail_not_connected")
      {put_source_summary(telemetry, "gmail", %{"status" => "unavailable"}), bundle}
    else
      now_watermark = gmail_upper_watermark(context, plan)

      query_upper_watermark =
        now_watermark
        |> String.to_integer()
        |> Kernel.+(@gmail_query_boundary_overlap_seconds)
        |> Integer.to_string()

      lookback_days = max(div(plan.lookback_hours, 24), @commercial_gmail_lookback_days)
      fallback_query = "newer_than:#{lookback_days}d before:#{query_upper_watermark}"

      commercial_gmail_queries =
        Enum.map(plan.commercial_gmail_queries, &"#{&1} before:#{query_upper_watermark}")

      watermark_mode = watermark_advance_mode(context, plan)
      deep_lookback? = deep_lookback_fetch?(plan)
      watermark_kind = source_watermark_kind(context, "gmail")
      replay_window = plan.source_replay_window
      provider_count = length(providers)
      provider_concurrency = min(@gmail_provider_fetch_concurrency, provider_count)
      phase_budgets = gmail_phase_budgets(plan)
      provider_waves = ceil_div(provider_count, provider_concurrency)
      provider_task_timeout = max(div(phase_budgets.provider, provider_waves), 1)

      detail_concurrency =
        max(div(@gmail_candidate_fetch_concurrency, provider_concurrency), 1)

      detail_timeout =
        @gmail_candidate_detail_timeout_ms
        |> min(max(provider_task_timeout - 250, 1))

      provider_quotas =
        gmail_provider_candidate_quotas(
          providers,
          plan.gmail_message_limit,
          commercial_gmail_queries
        )

      provider_candidate_limits =
        Map.new(provider_quotas, fn {provider, quota} -> {provider, quota.total} end)

      per_provider_candidate_limit =
        provider_candidate_limits
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      provider_specs =
        Enum.map(providers, fn provider ->
          account = ConnectedAccounts.get(user_id, provider)

          window =
            gmail_poll_window(
              account,
              fallback_query,
              deep_lookback?,
              watermark_kind,
              now_watermark,
              replay_window
            )

          quota = Map.fetch!(provider_quotas, provider)
          {provider, account, window, quota}
        end)

      # Targeted commercial searches are useful on the first bounded lookback
      # because they can rescue older actionable mail from the newest-N cap.
      # Once an account has a cursor, the base `after:<cursor>` query already
      # contains every new message. Re-running lookback-only targeted searches
      # here would reintroduce old mail into an otherwise exact delta and send
      # the same batch through the model on every poll.
      commercial_providers =
        if plan.exhaustive_account_delta? or is_map(replay_window) do
          []
        else
          provider_specs
          |> Enum.filter(fn {_provider, _account, window, _quota} ->
            window.query == fallback_query
          end)
          |> Enum.map(&elem(&1, 0))
        end

      provider_results =
        Task.async_stream(
          provider_specs,
          fn {provider, _account, window, quota} ->
            safe_gmail_task(fn ->
              candidate_limit = if is_map(replay_window), do: quota.total, else: quota.base

              fetch_gmail_provider_candidates(
                user_id,
                source_scope,
                provider,
                window.query,
                candidate_limit,
                detail_concurrency,
                detail_timeout,
                plan.exhaustive_account_delta?,
                window
              )
            end)
          end,
          max_concurrency: provider_concurrency,
          ordered: true,
          timeout: provider_task_timeout,
          on_timeout: :kill_task
        )

      {raw_messages_by_provider, provider_statuses, proposed_watermarks} =
        provider_specs
        |> Enum.zip(provider_results)
        |> Enum.reduce({%{}, %{}, []}, fn
          {{provider, account, window, _quota}, {:ok, {:ok, messages, fetch_metadata}}},
          {message_acc, status_acc, watermark_acc} ->
            outcome = gmail_candidate_fetch_outcome(fetch_metadata)

            if outcome == :complete do
              SourceFreshness.mark_success(user_id, provider)
            end

            log_gmail_candidate_fetch(outcome, user_id, provider, fetch_metadata)

            # Only a completely enumerated result may advance. A newest-N
            # window with a next page is useful evidence, but advancing over it
            # would permanently skip the unenumerated messages.
            watermark_acc =
              if outcome == :complete do
                accumulate_watermark(
                  watermark_acc,
                  account,
                  watermark_kind,
                  now_watermark,
                  watermark_mode,
                  window.cursor
                )
              else
                watermark_acc
              end

            provider_status =
              if outcome == :complete,
                do: {:ok, 0, fetch_metadata},
                else: {:partial, 0, fetch_metadata}

            {
              Map.put(message_acc, provider, messages),
              Map.put(status_acc, provider, provider_status),
              watermark_acc
            }

          {{provider, _account, _window, _quota}, {:ok, {:error, reason}}},
          {message_acc, status_acc, watermark_acc} ->
            ConnectedAccounts.report_access_issue(user_id, provider, reason)

            Logger.warning("ChiefOfStaff acquisition failed to fetch Gmail",
              user_fingerprint: Redaction.fingerprint(user_id),
              provider_reference: Redaction.fingerprint(provider),
              failure_code: Redaction.error_class(reason)
            )

            {
              message_acc,
              Map.put(status_acc, provider, {:error, reason}),
              watermark_acc
            }

          {{provider, _account, _window, _quota}, {:ok, {:task_failure, reason}}},
          {message_acc, status_acc, watermark_acc} ->
            Logger.warning("ChiefOfStaff Gmail provider task failed",
              user_fingerprint: Redaction.fingerprint(user_id),
              provider_reference: Redaction.fingerprint(provider),
              failure_code: Redaction.error_class(reason)
            )

            {
              message_acc,
              Map.put(status_acc, provider, {:task_error, reason}),
              watermark_acc
            }

          {{provider, _account, _window, _quota}, {:exit, reason}},
          {message_acc, status_acc, watermark_acc} ->
            # A bounded task timeout is a cycle-budget failure, not evidence
            # that the account needs OAuth repair.
            Logger.warning("ChiefOfStaff Gmail provider phase did not finish",
              user_fingerprint: Redaction.fingerprint(user_id),
              provider_reference: Redaction.fingerprint(provider),
              failure_code: Redaction.error_class(reason)
            )

            {
              message_acc,
              Map.put(status_acc, provider, {:task_error, reason}),
              watermark_acc
            }
        end)

      {raw_messages_by_provider, provider_statuses} =
        append_commercial_gmail_candidates(
          raw_messages_by_provider,
          provider_statuses,
          user_id,
          source_scope,
          commercial_providers,
          provider_quotas,
          detail_concurrency,
          detail_timeout,
          commercial_gmail_queries,
          phase_budgets.commercial
        )

      messages =
        providers
        |> interleave_gmail_provider_messages(raw_messages_by_provider)
        |> dedupe_messages()
        |> maybe_take_gmail_messages(plan)
        |> enrich_gmail_messages(user_id, nil, plan)
        |> sort_messages()

      messages_by_provider = group_messages_by_provider(messages)

      provider_fetches =
        Enum.map(providers, fn provider ->
          provider_messages = Map.get(messages_by_provider, provider, [])

          case Map.get(provider_statuses, provider) do
            {:ok, commercial_count, fetch_metadata} ->
              gmail_provider_fetch_telemetry(
                provider,
                "ok",
                commercial_count,
                provider_messages,
                fetch_metadata
              )

            {:partial, commercial_count, fetch_metadata} ->
              gmail_provider_fetch_telemetry(
                provider,
                "partial",
                commercial_count,
                provider_messages,
                fetch_metadata
              )

            {:error, reason} ->
              %{
                "source" => "gmail",
                "provider" => provider,
                "mode" => "connector",
                "status" => "error",
                "reason" => Redaction.error_class(reason)
              }

            {:task_error, reason} ->
              %{
                "source" => "gmail",
                "provider" => provider,
                "mode" => "connector",
                "status" => "timeout",
                "reason" => Redaction.error_class(reason)
              }
          end
        end)

      complete_providers =
        Enum.filter(providers, fn provider ->
          match?({:ok, _commercial_count, _metadata}, Map.get(provider_statuses, provider))
        end)

      partial_providers =
        Enum.filter(providers, fn provider ->
          match?({:partial, _commercial_count, _metadata}, Map.get(provider_statuses, provider))
        end)

      backfill_needed_providers =
        Enum.filter(partial_providers, fn provider ->
          case Map.get(provider_statuses, provider) do
            {:partial, _commercial_count, %{truncated?: true, detail_failure_count: 0}} -> true
            _other -> false
          end
        end)

      failed_providers = providers -- (complete_providers ++ partial_providers)
      successful_provider_count = length(complete_providers) + length(partial_providers)
      status = if length(complete_providers) == provider_count, do: "ready", else: "partial"

      bundle =
        SourceBundle.put_gmail(bundle, %{
          "messages" => messages,
          "inbox_messages" => filter_messages_by_label(messages, "INBOX", plan.inbox_limit),
          "sent_messages" => filter_messages_by_label(messages, "SENT", plan.sent_limit),
          "messages_by_provider" => messages_by_provider,
          "providers" => providers,
          "metadata" => %{
            "mode" => "connector",
            "query" => fallback_query,
            "candidate_limit" => plan.gmail_message_limit,
            "complete_providers" => complete_providers,
            "partial_providers" => partial_providers,
            "failed_providers" => failed_providers,
            "backfill_needed_providers" => backfill_needed_providers
          },
          "status" => status,
          "fetched_at" => context[:timestamp] || DateTime.utc_now()
        })

      telemetry =
        telemetry
        |> Map.update("fetches", provider_fetches, &(provider_fetches ++ &1))
        |> Map.update("proposed_watermarks", proposed_watermarks, &(proposed_watermarks ++ &1))
        |> put_source_summary("gmail", %{
          "mode" => "connector",
          "status" => status,
          "providers" => providers,
          "complete_providers" => complete_providers,
          "partial_providers" => partial_providers,
          "failed_providers" => failed_providers,
          "backfill_needed_providers" => backfill_needed_providers,
          "successful_provider_count" => successful_provider_count,
          "complete_provider_count" => length(complete_providers),
          "candidate_limit" => plan.gmail_message_limit,
          "per_provider_candidate_limit" => per_provider_candidate_limit,
          "provider_candidate_limits" => provider_candidate_limits,
          "commercial_provider_count" => length(commercial_providers),
          "message_count" => length(messages),
          "full_body_count" => count_full_body_messages(messages),
          "body_missing_count" => count_body_missing_messages(messages),
          "phase_budgets_ms" => phase_budgets
        })

      {telemetry, bundle}
    end
  end

  defp fetch_gmail_provider_candidates(
         _user_id,
         _source_scope,
         _provider,
         _query,
         message_limit,
         _detail_concurrency,
         _detail_timeout,
         _exhaustive?,
         _window
       )
       when not is_integer(message_limit) or message_limit <= 0 do
    {:ok, [], gmail_fetch_metadata(0, 0, 0, false, false)}
  end

  defp fetch_gmail_provider_candidates(
         user_id,
         source_scope,
         provider,
         query,
         message_limit,
         detail_concurrency,
         detail_timeout,
         exhaustive?,
         window
       ) do
    fetch_opts =
      gmail_candidate_fetch_opts(
        detail_concurrency,
        detail_timeout,
        exhaustive?,
        Map.get(window, :replay?, false),
        message_limit
      )

    case gmail_module().fetch_messages(
           user_id,
           fetch_opts ++
             [
               max_results: message_limit,
               label_ids: [],
               query: query,
               provider: provider
             ]
         ) do
      {:ok, messages, metadata} when is_list(messages) and is_map(metadata) ->
        annotated = annotate_google_items(messages, source_scope, provider)
        metadata = normalize_gmail_fetch_metadata(metadata, message_limit, length(messages))

        {annotated, metadata} =
          maybe_hydrate_gmail_thread_context(
            user_id,
            annotated,
            source_scope,
            provider,
            exhaustive?,
            detail_concurrency,
            detail_timeout,
            metadata
          )

        with {:ok, filtered} <- filter_gmail_messages_to_window(annotated, window) do
          {:ok, filtered, metadata}
        end

      {:ok, messages} when is_list(messages) ->
        # Test doubles and older connector implementations do not expose
        # completeness metadata. Their explicit success remains complete.
        annotated = annotate_google_items(messages, source_scope, provider)
        metadata = gmail_fetch_metadata(length(messages), length(messages), 0, false, true)

        {annotated, metadata} =
          maybe_hydrate_gmail_thread_context(
            user_id,
            annotated,
            source_scope,
            provider,
            exhaustive?,
            detail_concurrency,
            detail_timeout,
            metadata
          )

        with {:ok, filtered} <- filter_gmail_messages_to_window(annotated, window) do
          {:ok, filtered, metadata}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_gmail_fetch_result, summarize_task_value(other)}}
    end
  end

  defp maybe_hydrate_gmail_thread_context(
         _user_id,
         messages,
         _source_scope,
         _provider,
         false,
         _concurrency,
         _timeout,
         metadata
       ),
       do: {messages, Map.merge(metadata, %{thread_fetch_count: 0, thread_failure_count: 0})}

  defp maybe_hydrate_gmail_thread_context(
         user_id,
         messages,
         source_scope,
         provider,
         true,
         concurrency,
         timeout,
         metadata
       ) do
    {thread_ids, invalid_delta_count} = gmail_delta_thread_ids(messages)

    thread_results =
      thread_ids
      |> Task.async_stream(
        fn thread_id ->
          result =
            gmail_module().fetch_thread_content(user_id, thread_id, provider: provider)

          {thread_id, result}
        end,
        max_concurrency: max(min(concurrency, max(length(thread_ids), 1)), 1),
        ordered: true,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {threads, fetch_failure_count} =
      Enum.reduce(thread_results, {%{}, invalid_delta_count}, fn
        {:ok, {thread_id, {:ok, thread_messages}}}, {thread_acc, failure_count}
        when is_list(thread_messages) and thread_messages != [] ->
          annotated_thread = annotate_google_items(thread_messages, source_scope, provider)

          if gmail_thread_complete?(thread_id, annotated_thread, messages) do
            {Map.put(thread_acc, thread_id, annotated_thread), failure_count}
          else
            {thread_acc, failure_count + 1}
          end

        _failure, {thread_acc, failure_count} ->
          {thread_acc, failure_count + 1}
      end)

    hydrated =
      Enum.map(messages, fn message ->
        thread_id = read_gmail_string(message, "thread_id")

        case Map.get(threads, thread_id) do
          thread_messages when is_list(thread_messages) ->
            attach_gmail_thread_context(message, thread_messages)

          _missing ->
            message
        end
      end)

    metadata =
      metadata
      |> Map.put(:thread_fetch_count, length(thread_ids))
      |> Map.put(:thread_failure_count, fetch_failure_count)

    metadata =
      if fetch_failure_count == 0 do
        metadata
      else
        metadata
        |> Map.update!(:detail_failure_count, &(&1 + fetch_failure_count))
        |> Map.put(:complete?, false)
      end

    {hydrated, metadata}
  end

  defp gmail_delta_thread_ids(messages) do
    Enum.reduce(messages, {[], 0}, fn message, {thread_ids, invalid_count} ->
      case {read_gmail_string(message, "message_id") || read_gmail_string(message, "id"),
            read_gmail_string(message, "thread_id"), gmail_message_frontier(message)} do
        {message_id, thread_id, frontier}
        when is_binary(message_id) and is_binary(thread_id) and is_integer(frontier) ->
          {[thread_id | thread_ids], invalid_count}

        _invalid ->
          {thread_ids, invalid_count + 1}
      end
    end)
    |> then(fn {thread_ids, invalid_count} ->
      {thread_ids |> Enum.reverse() |> Enum.uniq(), invalid_count}
    end)
  end

  defp gmail_thread_complete?(thread_id, thread_messages, delta_messages) do
    hydrated_ids =
      thread_messages
      |> Enum.reduce_while(MapSet.new(), fn message, ids ->
        case {read_gmail_string(message, "message_id") || read_gmail_string(message, "id"),
              read_gmail_string(message, "thread_id"), gmail_message_frontier(message)} do
          {message_id, ^thread_id, frontier}
          when is_binary(message_id) and is_integer(frontier) ->
            {:cont, MapSet.put(ids, message_id)}

          _invalid ->
            {:halt, :invalid}
        end
      end)

    delta_ids =
      delta_messages
      |> Enum.filter(&(read_gmail_string(&1, "thread_id") == thread_id))
      |> Enum.map(&(read_gmail_string(&1, "message_id") || read_gmail_string(&1, "id")))

    match?(%MapSet{}, hydrated_ids) and
      Enum.all?(delta_ids, &MapSet.member?(hydrated_ids, &1))
  end

  defp attach_gmail_thread_context(message, thread_messages) do
    frontier = gmail_message_frontier(message)
    delta_id = read_gmail_string(message, "message_id") || read_gmail_string(message, "id")

    context =
      thread_messages
      |> Enum.filter(fn thread_message ->
        message_id =
          read_gmail_string(thread_message, "message_id") ||
            read_gmail_string(thread_message, "id")

        thread_frontier = gmail_message_frontier(thread_message)

        message_id != delta_id and is_integer(thread_frontier) and thread_frontier <= frontier
      end)
      |> Enum.sort_by(fn thread_message ->
        {gmail_message_frontier(thread_message),
         read_gmail_string(thread_message, "message_id") ||
           read_gmail_string(thread_message, "id")}
      end)

    message
    |> Map.put("thread_context", context)
    |> Map.put("thread_context_complete", true)
    |> Map.put("thread_context_frontier", frontier)
  end

  defp gmail_message_frontier(message) when is_map(message) do
    message
    |> Map.get("internal_date", Map.get(message, :internal_date))
    |> gmail_frontier_value()
  end

  defp gmail_message_frontier(_message), do: nil

  defp gmail_frontier_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp gmail_frontier_value(%NaiveDateTime{} = value) do
    value |> DateTime.from_naive!("Etc/UTC") |> gmail_frontier_value()
  end

  defp gmail_frontier_value(value) when is_integer(value), do: value * 1_000

  defp gmail_frontier_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} -> milliseconds * 1_000
      _invalid -> parse_gmail_frontier_datetime(value)
    end
  end

  defp gmail_frontier_value(_value), do: nil

  defp parse_gmail_frontier_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp read_gmail_string(message, key) when is_map(message) do
    atom_key =
      case key do
        "id" -> :id
        "message_id" -> :message_id
        "thread_id" -> :thread_id
      end

    case Map.get(message, key, Map.get(message, atom_key)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp append_commercial_gmail_candidates(
         messages_by_provider,
         provider_statuses,
         _user_id,
         _source_scope,
         _providers,
         _provider_quotas,
         _detail_concurrency,
         _detail_timeout,
         [],
         _phase_timeout
       ),
       do: {messages_by_provider, provider_statuses}

  defp append_commercial_gmail_candidates(
         messages_by_provider,
         provider_statuses,
         user_id,
         source_scope,
         providers,
         provider_quotas,
         detail_concurrency,
         detail_timeout,
         queries,
         phase_timeout
       )
       when is_map(messages_by_provider) and is_map(provider_statuses) and is_list(queries) and
              is_integer(phase_timeout) and phase_timeout > 0 do
    successful_providers =
      Enum.filter(providers, fn provider ->
        case Map.get(provider_statuses, provider) do
          {:ok, _commercial_count, _metadata} -> true
          {:partial, _commercial_count, _metadata} -> true
          _other -> false
        end
      end)

    provider_concurrency =
      max(min(@gmail_provider_fetch_concurrency, length(successful_providers)), 1)

    provider_waves = max(ceil_div(length(successful_providers), provider_concurrency), 1)
    provider_timeout = max(div(phase_timeout, provider_waves), 1)
    query_timeout = max(provider_timeout - 100, 1)

    query_concurrency =
      max(
        min(detail_concurrency, div(@gmail_candidate_fetch_concurrency, provider_concurrency)),
        1
      )

    results =
      Task.async_stream(
        successful_providers,
        fn provider ->
          safe_gmail_task(fn ->
            quota = get_in(provider_quotas, [provider, :commercial]) || 0

            commercial_messages =
              fetch_commercial_gmail_messages(
                user_id,
                provider,
                queries,
                gmail_commercial_fetch_opts(
                  query_concurrency,
                  min(detail_timeout, query_timeout),
                  query_timeout
                ),
                quota
              )
              |> annotate_google_items(source_scope, provider)

            {provider, commercial_messages}
          end)
        end,
        max_concurrency: provider_concurrency,
        ordered: true,
        timeout: provider_timeout,
        on_timeout: :kill_task
      )

    successful_providers
    |> Enum.zip(results)
    |> Enum.reduce({messages_by_provider, provider_statuses}, fn
      {_expected_provider, {:ok, {provider, commercial_messages}}}, {message_acc, status_acc} ->
        total_quota = get_in(provider_quotas, [provider, :total]) || 0

        combined =
          (commercial_messages ++ Map.get(message_acc, provider, []))
          |> dedupe_messages()
          |> Enum.take(total_quota)

        status =
          case Map.fetch!(status_acc, provider) do
            {:ok, _count, metadata} -> {:ok, length(commercial_messages), metadata}
            {:partial, _count, metadata} -> {:partial, length(commercial_messages), metadata}
          end

        {Map.put(message_acc, provider, combined), Map.put(status_acc, provider, status)}

      {provider, {:ok, {:task_failure, reason}}}, {message_acc, status_acc} ->
        Logger.debug("ChiefOfStaff optional commercial Gmail search failed",
          user_fingerprint: Redaction.fingerprint(user_id),
          provider_reference: Redaction.fingerprint(provider),
          failure_code: Redaction.error_class(reason)
        )

        {message_acc, status_acc}

      {provider, {:exit, reason}}, {message_acc, status_acc} ->
        Logger.debug("ChiefOfStaff optional commercial Gmail search did not finish",
          user_fingerprint: Redaction.fingerprint(user_id),
          provider_reference: Redaction.fingerprint(provider),
          failure_code: Redaction.error_class(reason)
        )

        {message_acc, status_acc}
    end)
  end

  defp append_commercial_gmail_candidates(
         messages_by_provider,
         provider_statuses,
         _user_id,
         _source_scope,
         _providers,
         _provider_quotas,
         _detail_concurrency,
         _detail_timeout,
         _queries,
         _phase_timeout
       ),
       do: {messages_by_provider, provider_statuses}

  defp gmail_candidate_fetch_opts(
         detail_concurrency,
         detail_timeout,
         true,
         replay?,
         message_limit
       ) do
    opts = [
      message_format: :full,
      message_fetch_concurrency: detail_concurrency,
      message_fetch_timeout_ms: detail_timeout,
      include_fetch_metadata: true,
      paginate: true
    ]

    if replay?, do: Keyword.put(opts, :max_total_results, message_limit), else: opts
  end

  defp gmail_candidate_fetch_opts(
         detail_concurrency,
         detail_timeout,
         _exhaustive?,
         _replay?,
         _message_limit
       ) do
    [
      message_format: :metadata,
      message_fetch_concurrency: detail_concurrency,
      message_fetch_timeout_ms: detail_timeout,
      include_fetch_metadata: true
    ]
  end

  defp maybe_take_gmail_messages(messages, %{exhaustive_account_delta?: true}), do: messages

  defp maybe_take_gmail_messages(messages, plan),
    do: Enum.take(messages, plan.gmail_message_limit)

  defp gmail_commercial_fetch_opts(query_concurrency, detail_timeout, query_timeout) do
    [
      message_format: :metadata,
      message_fetch_concurrency: 1,
      message_fetch_timeout_ms: detail_timeout,
      include_fetch_metadata: true,
      commercial_query_concurrency: query_concurrency,
      commercial_query_timeout_ms: query_timeout
    ]
  end

  defp gmail_provider_candidate_quotas(providers, total_limit, queries)
       when is_list(providers) and providers != [] and is_integer(total_limit) and
              total_limit >= 0 do
    provider_count = length(providers)
    base_quota = div(total_limit, provider_count)
    remainder = rem(total_limit, provider_count)
    query_count = queries |> normalize_commercial_gmail_queries() |> length()

    providers
    |> Enum.with_index()
    |> Map.new(fn {provider, index} ->
      total = base_quota + if(index < remainder, do: 1, else: 0)

      commercial =
        if query_count > 0 do
          # Reserve enough per-account room for targeted asks/promises to
          # survive a noisy newest-N base window. The total provider quota is
          # unchanged, so this improves recall without growing prompt input.
          min(query_count * @commercial_gmail_query_limit * 2, div(total, 2))
        else
          0
        end

      {provider, %{total: total, base: total - commercial, commercial: commercial}}
    end)
  end

  defp gmail_provider_candidate_quotas(providers, _total_limit, _queries)
       when is_list(providers) do
    Map.new(providers, &{&1, %{total: 0, base: 0, commercial: 0}})
  end

  defp normalize_commercial_gmail_queries(queries) when is_list(queries) do
    queries
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_commercial_gmail_queries(_queries), do: []

  defp gmail_commercial_query_specs(queries, total_limit) do
    queries = normalize_commercial_gmail_queries(queries)
    query_count = length(queries)

    if query_count == 0 or not is_integer(total_limit) or total_limit <= 0 do
      []
    else
      base_quota = div(total_limit, query_count)
      remainder = rem(total_limit, query_count)

      queries
      |> Enum.with_index()
      |> Enum.flat_map(fn {query, index} ->
        quota = base_quota + if(index < remainder, do: 1, else: 0)
        if quota > 0, do: [{query, quota}], else: []
      end)
    end
  end

  defp normalize_gmail_fetch_metadata(metadata, requested_count, success_count) do
    listed_count = fetch_metadata_integer(metadata, :listed_count, requested_count)
    requested_count = fetch_metadata_integer(metadata, :requested_count, requested_count)
    detail_success_count = fetch_metadata_integer(metadata, :detail_success_count, success_count)

    detail_failure_count =
      fetch_metadata_integer(
        metadata,
        :detail_failure_count,
        max(requested_count - detail_success_count, 0)
      )

    truncated? = fetch_metadata_boolean(metadata, :truncated?, false)

    declared_complete? =
      fetch_metadata_boolean(
        metadata,
        :complete?,
        detail_failure_count == 0 and not truncated?
      )

    complete? = declared_complete? and detail_failure_count == 0 and not truncated?

    gmail_fetch_metadata(
      listed_count,
      detail_success_count,
      detail_failure_count,
      truncated?,
      complete?
    )
    |> Map.put(:requested_count, requested_count)
  end

  defp gmail_candidate_fetch_outcome(%{
         complete?: true,
         truncated?: false,
         detail_failure_count: 0
       }),
       do: :complete

  defp gmail_candidate_fetch_outcome(_fetch_metadata), do: :partial

  defp log_gmail_candidate_fetch(:complete, _user_id, _provider, _fetch_metadata), do: :ok

  defp log_gmail_candidate_fetch(:partial, user_id, provider, fetch_metadata) do
    Logger.warning(
      "ChiefOfStaff Gmail candidate fetch was incomplete " <>
        "(detail failures: #{fetch_metadata.detail_failure_count}, " <>
        "truncated: #{fetch_metadata.truncated?})",
      user_fingerprint: Redaction.fingerprint(user_id),
      provider_reference: Redaction.fingerprint(provider),
      detail_failure_count: fetch_metadata.detail_failure_count,
      truncated: fetch_metadata.truncated?
    )
  end

  defp gmail_fetch_metadata(
         listed_count,
         detail_success_count,
         detail_failure_count,
         truncated?,
         complete?
       ) do
    %{
      listed_count: listed_count,
      requested_count: detail_success_count + detail_failure_count,
      detail_success_count: detail_success_count,
      detail_failure_count: detail_failure_count,
      truncated?: truncated?,
      complete?: complete?
    }
  end

  defp fetch_metadata_integer(metadata, key, default) do
    case Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp fetch_metadata_boolean(metadata, key, default) do
    case Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default)) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp gmail_provider_fetch_telemetry(
         provider,
         status,
         commercial_count,
         provider_messages,
         fetch_metadata
       ) do
    %{
      "source" => "gmail",
      "provider" => provider,
      "mode" => "connector",
      "status" => status,
      "count" => length(provider_messages),
      "targeted_search_count" => commercial_count,
      # Retain the old field for dashboards while configured commercial
      # searches and built-in actionable searches share the same phase.
      "commercial_search_count" => commercial_count,
      "listed_count" => fetch_metadata.listed_count,
      "requested_count" => fetch_metadata.requested_count,
      "detail_success_count" => fetch_metadata.detail_success_count,
      "detail_failure_count" => fetch_metadata.detail_failure_count,
      "thread_fetch_count" => Map.get(fetch_metadata, :thread_fetch_count, 0),
      "thread_failure_count" => Map.get(fetch_metadata, :thread_failure_count, 0),
      "truncated" => fetch_metadata.truncated?,
      "full_body_count" => count_full_body_messages(provider_messages),
      "body_missing_count" => count_body_missing_messages(provider_messages)
    }
  end

  defp safe_gmail_task(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      error -> {:task_failure, {:exception, error.__struct__}}
    catch
      kind, reason -> {:task_failure, {kind, summarize_task_value(reason)}}
    end
  end

  defp summarize_task_value(value) do
    inspect(value, pretty: false, limit: 10, printable_limit: 200)
  end

  defp interleave_gmail_provider_messages(providers, messages_by_provider)
       when is_list(providers) and is_map(messages_by_provider) do
    providers
    |> Enum.map(&Map.get(messages_by_provider, &1, []))
    |> interleave_gmail_queues()
  end

  defp interleave_gmail_provider_messages(_providers, _messages_by_provider), do: []

  defp interleave_gmail_queues(queues) do
    round =
      Enum.flat_map(queues, fn
        [message | _rest] -> [message]
        [] -> []
      end)

    if round == [] do
      []
    else
      remaining =
        Enum.map(queues, fn
          [_message | rest] -> rest
          [] -> []
        end)

      round ++ interleave_gmail_queues(remaining)
    end
  end

  # Gmail search operators are strict at both timestamp boundaries, and a
  # message can become search-visible after a cycle has already committed a
  # later watermark. Each poll therefore replays a bounded interval below the
  # durable cursor. The provider query is widened by one additional second on
  # both sides, then hydrated messages are filtered locally to the exact
  # `[cursor - safety_overlap, now)` interval.
  defp gmail_poll_window(account, _fallback_query, _deep_lookback?, kind, _now, %{
         lower: lower,
         upper: upper
       })
       when is_integer(lower) and is_integer(upper) and lower >= 0 and upper > lower do
    cursor =
      case account && SourceCursors.get(account.id, kind) do
        %{value: value} when is_binary(value) -> value
        _other -> nil
      end

    %{
      query:
        "after:#{max(lower - @gmail_query_boundary_overlap_seconds, 0)} before:#{upper + @gmail_query_boundary_overlap_seconds}",
      lower: lower,
      upper: upper,
      cursor: cursor,
      replay?: true
    }
  end

  defp gmail_poll_window(_account, fallback_query, true, _kind, now, _replay_window),
    do: %{query: fallback_query, lower: nil, upper: watermark_integer(now), cursor: nil}

  defp gmail_poll_window(nil, fallback_query, _deep_lookback?, _kind, now, _replay_window),
    do: %{query: fallback_query, lower: nil, upper: watermark_integer(now), cursor: nil}

  defp gmail_poll_window(
         account,
         fallback_query,
         _deep_lookback?,
         kind,
         now,
         _replay_window
       ) do
    upper = watermark_integer(now)

    case SourceCursors.get(account.id, kind) do
      %{value: value} when is_binary(value) and value != "" ->
        case watermark_integer(value) do
          cursor when is_integer(cursor) ->
            lower = max(cursor - configured_gmail_poll_safety_overlap_seconds(), 0)
            query_lower = max(lower - @gmail_query_boundary_overlap_seconds, 0)
            query_upper = upper + @gmail_query_boundary_overlap_seconds

            %{
              query: "after:#{query_lower} before:#{query_upper}",
              lower: lower,
              upper: upper,
              cursor: value
            }

          nil ->
            %{query: fallback_query, lower: nil, upper: upper, cursor: nil}
        end

      _ ->
        %{query: fallback_query, lower: nil, upper: upper, cursor: nil}
    end
  end

  defp filter_gmail_messages_to_window(
         messages,
         %{lower: lower, upper: upper, replay?: true}
       )
       when is_list(messages) and (is_nil(lower) or is_integer(lower)) and is_integer(upper) do
    lower_frontier = if is_integer(lower), do: lower * 1_000_000
    upper_frontier = upper * 1_000_000

    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, filtered} ->
      case gmail_message_frontier(message) do
        frontier when is_integer(frontier) ->
          if (is_nil(lower_frontier) or frontier >= lower_frontier) and
               frontier < upper_frontier do
            {:cont, {:ok, [message | filtered]}}
          else
            {:cont, {:ok, filtered}}
          end

        _missing ->
          {:halt, {:error, :gmail_source_replay_frontier_missing}}
      end
    end)
    |> case do
      {:ok, filtered} when length(filtered) <= @max_gmail_message_limit ->
        {:ok, Enum.reverse(filtered)}

      {:ok, _too_many} ->
        {:error, :gmail_source_replay_item_limit}

      {:error, _reason} = error ->
        error
    end
  end

  defp filter_gmail_messages_to_window(messages, %{lower: lower, upper: upper})
       when is_list(messages) and (is_nil(lower) or is_integer(lower)) and is_integer(upper) do
    lower_frontier = if is_integer(lower), do: lower * 1_000_000
    upper_frontier = upper * 1_000_000

    {:ok,
     Enum.filter(messages, fn message ->
       case gmail_message_frontier(message) do
         frontier when is_integer(frontier) ->
           (is_nil(lower_frontier) or frontier >= lower_frontier) and frontier < upper_frontier

         _missing ->
           false
       end
     end)}
  end

  defp filter_gmail_messages_to_window(messages, _window) when is_list(messages),
    do: {:ok, messages}

  defp watermark_integer(value) when is_integer(value), do: value

  defp watermark_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp watermark_integer(_value), do: nil

  defp configured_gmail_poll_safety_overlap_seconds do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(
      :gmail_poll_safety_overlap_seconds,
      @default_gmail_poll_safety_overlap_seconds
    )
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_gmail_poll_safety_overlap_seconds
    end
  end

  defp source_watermark_kind(context, source) when source in ["gmail", "slack"] do
    override =
      Map.get(
        context,
        :source_watermark_kind_override,
        Map.get(context, "source_watermark_kind_override")
      )

    role = Map.get(context, :source_watermark_role, Map.get(context, "source_watermark_role"))

    case {source, override, role} do
      {_source, override, role}
      when is_binary(override) and role in ["discovery", "closure"] ->
        override

      {_source, _override, role} when role in ["discovery", "closure"] ->
        "#{source}_#{role}_watermark"

      {"gmail", _override, _role} ->
        "gmail_poll_watermark"

      _other ->
        "slack_watermark"
    end
  end

  defp fetch_calendar_from_sources(telemetry, bundle, user_id, source_scope, plan, context) do
    providers = SourceScope.google_account_providers(source_scope, "calendar")

    if providers == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "calendar", "google_calendar_not_connected")
      {put_source_summary(telemetry, "calendar", %{"status" => "unavailable"}), bundle}
    else
      reference_at = context[:timestamp] || DateTime.utc_now()

      time_min =
        plan[:calendar_time_min] ||
          reference_at
          |> DateTime.add(-plan.lookback_hours, :hour)
          |> DateTime.to_iso8601()

      time_max =
        reference_at
        |> DateTime.add(plan.forward_days, :day)
        |> DateTime.to_iso8601()

      {events_by_provider, fetches} =
        Enum.reduce(providers, {%{}, telemetry["fetches"]}, fn provider, {event_acc, fetch_acc} ->
          case calendar_module().list_events(user_id,
                 max_results: plan.calendar_limit,
                 time_min: time_min,
                 time_max: time_max,
                 provider: provider
               ) do
            {:ok, events} ->
              # R4: mirrors the gmail branch above - a successful calendar
              # fetch confirms recovery for calendar sources previously
              # flagged stale/watch_expired/reauth.
              SourceFreshness.mark_success(user_id, provider)

              annotated = annotate_google_items(events, source_scope, provider)

              {
                Map.put(event_acc, provider, annotated),
                [
                  %{
                    "source" => "calendar",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "ok",
                    "count" => length(annotated)
                  }
                  | fetch_acc
                ]
              }

            {:error, reason} ->
              ConnectedAccounts.report_access_issue(user_id, provider, reason)

              Logger.warning("ChiefOfStaff acquisition failed to fetch calendar",
                user_fingerprint: Redaction.fingerprint(user_id),
                provider_reference: Redaction.fingerprint(provider),
                failure_code: Redaction.error_class(reason)
              )

              {
                event_acc,
                [
                  %{
                    "source" => "calendar",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "error",
                    "reason" => Redaction.error_class(reason)
                  }
                  | fetch_acc
                ]
              }
          end
        end)

      events =
        events_by_provider
        |> Map.values()
        |> List.flatten()
        |> sort_events()

      status = if events == [], do: "partial", else: "ready"

      bundle =
        SourceBundle.put_calendar(bundle, %{
          "events" => events,
          "events_by_provider" => events_by_provider,
          "providers" => providers,
          "metadata" => %{"mode" => "connector", "time_min" => time_min, "time_max" => time_max},
          "status" => status,
          "fetched_at" => context[:timestamp] || DateTime.utc_now()
        })

      telemetry =
        telemetry
        |> Map.put("fetches", fetches)
        |> put_source_summary("calendar", %{
          "mode" => "connector",
          "status" => status,
          "providers" => providers,
          "event_count" => length(events)
        })

      {telemetry, bundle}
    end
  end

  defp build_plan(user_id, skill_ids, skill_configs, context) do
    requirements =
      skill_ids
      |> Skills.requirements()
      |> Enum.map(&stringify_keys/1)

    event_source = event_source(context)

    max_email_scan_limit =
      max_skill_integer(skill_ids, skill_configs, "email_scan_limit", 14)

    max_event_scan_limit =
      max_skill_integer(skill_ids, skill_configs, "event_scan_limit", 12)

    max_slack_channel_limit =
      max_skill_integer(
        skill_ids,
        skill_configs,
        "slack_channel_scan_limit",
        @default_slack_channel_limit
      )

    max_slack_message_limit =
      max_skill_integer(
        skill_ids,
        skill_configs,
        "slack_message_scan_limit",
        @default_slack_message_limit
      )

    max_lookback_hours =
      max_skill_integer(skill_ids, skill_configs, "lookback_hours", @default_lookback_hours)

    news_config = news_config(skill_ids, skill_configs)
    weather_config = weather_config(skill_ids, skill_configs)
    morning_brief? = morning_brief_trigger?(user_id, skill_ids, skill_configs, context)
    account_message_sources? = not truthy?(Map.get(context, :skip_account_message_sources))
    exhaustive_account_delta? = truthy?(Map.get(context, :exhaustive_account_delta))
    source_replay_window = source_replay_window(context)

    account_delta_source =
      case Map.get(context, :account_delta_source, Map.get(context, "account_delta_source")) do
        source when source in ["gmail", "slack"] -> source
        _other -> nil
      end

    # R2 (SPEC 04): scheduled scans cap the no-cursor fallback window to 48h
    # regardless of what any individual skill's own `lookback_hours` config
    # requests (commitment_tracker/goal_alignment/travel_logistics default to
    # 14-30 days for their own post-fetch analysis window, independent of the
    # acquisition fetch window). Morning briefings and explicit
    # backfill/rebuild callers (`context[:acquisition_deep_lookback]`) opt
    # back into the deeper window.
    # Deep lookback also fires when the daily commitment review is due — that
    # skill audits the full multi-day window, so running it on an incremental
    # delta bundle would gut the review. The behavior additionally opts in on
    # its periodic deep-scan cadence via `:acquisition_deep_lookback`.
    deep_lookback? =
      morning_brief? or
        commitment_review_due?(user_id, skill_ids, skill_configs, context) or
        truthy?(Map.get(context, :acquisition_deep_lookback))

    raw_lookback_hours = max(max_lookback_hours, 24)

    scheduled_scan_lookback_hours =
      if deep_lookback?,
        do: raw_lookback_hours,
        else: min(raw_lookback_hours, @scheduled_scan_lookback_cap_hours)

    %{
      gmail:
        account_message_sources? and
          service_required?(requirements, "google", "gmail") and
          event_allows_source?(event_source, "gmail"),
      calendar:
        service_required?(requirements, "google", "calendar") and
          event_allows_source?(event_source, "google_calendar"),
      slack: account_message_sources?,
      account_message_sources: account_message_sources?,
      news: morning_brief? and news_enabled?(news_config),
      news_config: news_config,
      weather: morning_brief? and weather_enabled?(weather_config),
      weather_config: weather_config,
      web_context: morning_brief?,
      exhaustive_account_delta?: exhaustive_account_delta?,
      source_replay_window: source_replay_window,
      account_delta_source: account_delta_source,
      inbox_limit: max(max_email_scan_limit, 100),
      sent_limit: max(max_email_scan_limit * 2, 100),
      gmail_message_limit:
        if(exhaustive_account_delta?,
          do: @max_gmail_message_limit,
          else: min(max_email_scan_limit * 4, @max_gmail_message_limit)
        ),
      gmail_body_fetch_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "gmail_body_fetch_limit",
          @default_gmail_body_fetch_limit
        ),
      gmail_body_fetch_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "gmail_body_fetch_timeout_ms",
          configured_gmail_body_fetch_timeout_ms()
        ),
      gmail_fetch_timeout_ms:
        if(exhaustive_account_delta?,
          do: 180_000,
          else:
            max_skill_integer(
              skill_ids,
              skill_configs,
              "gmail_fetch_timeout_ms",
              @default_gmail_fetch_timeout_ms
            )
        ),
      calendar_fetch_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "calendar_fetch_timeout_ms",
          @default_calendar_fetch_timeout_ms
        ),
      calendar_limit:
        if(morning_brief?,
          do: max(max_event_scan_limit * 10, @default_calendar_limit),
          else: max(max_event_scan_limit * 2, @default_calendar_limit)
        ),
      calendar_time_min: calendar_time_min(skill_ids, skill_configs, context, morning_brief?),
      slack_channel_limit: max_slack_channel_limit,
      slack_fetch_timeout_ms:
        if(exhaustive_account_delta?,
          do: 300_000,
          else:
            max_skill_integer(
              skill_ids,
              skill_configs,
              "slack_fetch_timeout_ms",
              @default_slack_fetch_timeout_ms
            )
        ),
      slack_channel_fetch_timeout_ms:
        if(exhaustive_account_delta?,
          do: 60_000,
          else:
            max_skill_integer(
              skill_ids,
              skill_configs,
              "slack_channel_fetch_timeout_ms",
              @default_slack_channel_fetch_timeout_ms
            )
        ),
      slack_search_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "slack_search_timeout_ms",
          @default_slack_search_timeout_ms
        ),
      slack_self_authored_query_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "slack_self_authored_query_limit",
          @default_slack_self_authored_query_limit
        ),
      slack_message_limit:
        if(morning_brief?,
          do: max(max_slack_message_limit, @default_slack_message_limit),
          else: max_slack_message_limit
        ),
      slack_key_channels: slack_key_channels(skill_ids, skill_configs),
      commercial_gmail_queries: commercial_gmail_queries(skill_ids, skill_configs),
      local_calendar_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_calendar_limit",
          @default_local_calendar_limit
        ),
      local_message_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_message_limit",
          @default_local_message_limit
        ),
      local_chat_limit:
        max_skill_integer(skill_ids, skill_configs, "local_chat_limit", @default_local_chat_limit),
      local_voice_memo_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_voice_memo_limit",
          @default_local_voice_memo_limit
        ),
      local_note_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_note_limit",
          @default_local_note_limit
        ),
      local_reminder_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_reminder_limit",
          @default_local_reminder_limit
        ),
      local_file_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_file_limit",
          @default_local_file_limit
        ),
      local_browser_visit_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_browser_visit_limit",
          @default_local_browser_visit_limit
        ),
      companion_fetch_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "companion_fetch_timeout_ms",
          @default_companion_fetch_timeout_ms
        ),
      news_fetch_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "news_fetch_timeout_ms",
          @default_news_fetch_timeout_ms
        ),
      weather_fetch_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "weather_fetch_timeout_ms",
          @default_weather_fetch_timeout_ms
        ),
      lookback_hours: scheduled_scan_lookback_hours,
      deep_lookback?: deep_lookback?,
      forward_days: @default_forward_days
    }
  end

  defp gmail_upper_watermark(_context, %{source_replay_window: %{upper: upper}})
       when is_integer(upper),
       do: Integer.to_string(upper)

  defp gmail_upper_watermark(context, _plan) do
    (context[:timestamp] || DateTime.utc_now())
    |> DateTime.to_unix(:second)
    |> Integer.to_string()
  end

  defp source_replay_window(context) when is_map(context) do
    case Map.get(context, :source_replay_window, Map.get(context, "source_replay_window")) do
      %{lower: lower, upper: upper}
      when is_integer(lower) and is_integer(upper) and lower >= 0 and upper > lower ->
        %{lower: lower, upper: upper}

      %{"lower" => lower, "upper" => upper}
      when is_integer(lower) and is_integer(upper) and lower >= 0 and upper > lower ->
        %{lower: lower, upper: upper}

      _other ->
        nil
    end
  end

  defp source_replay_window(_context), do: nil

  defp news_config(skill_ids, skill_configs) do
    skill_ids
    |> Enum.map(fn skill_id -> Map.get(skill_configs, skill_id, %{}) end)
    |> Enum.reduce(%{}, fn config, acc ->
      acc
      |> maybe_put("news_enabled", Map.get(config, "news_enabled"))
      |> maybe_put("news_limit", Map.get(config, "news_limit"))
      |> maybe_merge_news_feeds(Map.get(config, "news_feeds"))
    end)
  end

  defp calendar_time_min(_skill_ids, _skill_configs, _context, false), do: nil

  defp calendar_time_min(skill_ids, skill_configs, context, true) do
    reference_at = context[:timestamp] || DateTime.utc_now()

    timezone_offset_hours =
      first_skill_integer(
        skill_ids,
        skill_configs,
        "timezone_offset_hours",
        @default_timezone_offset_hours
      )

    reference_at
    |> local_day_start_utc(timezone_offset_hours)
    |> DateTime.to_iso8601()
  end

  defp weather_config(skill_ids, skill_configs) do
    skill_ids
    |> Enum.map(fn skill_id -> Map.get(skill_configs, skill_id, %{}) end)
    |> Enum.reduce(%{}, fn config, acc ->
      acc
      |> maybe_put("weather_enabled", Map.get(config, "weather_enabled"))
      |> maybe_put("weather_location", Map.get(config, "weather_location"))
      |> maybe_put("weather_latitude", Map.get(config, "weather_latitude"))
      |> maybe_put("weather_longitude", Map.get(config, "weather_longitude"))
      |> maybe_put("timezone", Map.get(config, "timezone") || Map.get(config, "timezone_name"))
    end)
  end

  defp weather_enabled?(%{"weather_enabled" => false}), do: false
  defp weather_enabled?(%{"weather_enabled" => "false"}), do: false
  defp weather_enabled?(%{"weather_enabled" => "0"}), do: false
  defp weather_enabled?(config) when is_map(config), do: true

  defp news_enabled?(%{"news_enabled" => false}), do: false
  defp news_enabled?(%{"news_enabled" => "false"}), do: false
  defp news_enabled?(%{"news_enabled" => "0"}), do: false

  defp news_enabled?(config) when is_map(config) do
    config
    |> Map.get("news_feeds", [])
    |> List.wrap()
    |> Enum.any?()
  end

  defp maybe_merge_news_feeds(config, feeds) when is_list(feeds) do
    current = Map.get(config, "news_feeds", [])
    Map.put(config, "news_feeds", Enum.uniq(current ++ feeds))
  end

  defp maybe_merge_news_feeds(config, _feeds), do: config

  defp resolve_source_scope(user_id, skill_ids, skill_configs, context) do
    configured_scope =
      skill_ids
      |> Enum.map(fn skill_id ->
        skill_configs
        |> Map.get(skill_id, %{})
        |> Map.get("source_scope")
      end)
      |> Enum.find(&is_map/1)

    live_scope = SourceScope.resolve(user_id)
    requested_scope = context[:source_scope] || context["source_scope"]

    cond do
      is_map(requested_scope) ->
        SourceScope.intersect(live_scope, requested_scope)

      SourceScope.google_accounts(live_scope) == [] and
          SourceScope.slack_workspaces(live_scope) == [] ->
        SourceScope.normalize(configured_scope || %{})

      true ->
        live_scope
    end
  end

  defp event_gmail_messages(context, source_scope) do
    payload = get_in(context, [:event, :payload])
    source = payload_source(payload)

    if source == "gmail" do
      messages =
        payload
        |> payload_data()
        |> Map.get("messages", [])
        |> annotate_event_messages(source_scope, context)

      if messages == [] do
        # Gmail push notifications only announce that mailbox history changed.
        # A completion event also carries no bodies. Fall back to provider
        # acquisition so an empty envelope never suppresses the real search.
        :fallback
      else
        {:ok,
         %{
           messages: messages,
           providers:
             messages
             |> Enum.map(&Map.get(&1, "google_provider"))
             |> Enum.filter(&is_binary/1)
             |> Enum.uniq()
         }}
      end
    else
      :fallback
    end
  end

  defp event_calendar_events(context) do
    payload = get_in(context, [:event, :payload])
    source = payload_source(payload)

    if source == "google_calendar" do
      events =
        payload
        |> payload_data()
        |> Map.get("events", [])
        |> Enum.map(&stringify_keys/1)

      # Calendar watch callbacks are also change notifications, not event
      # payloads. Read every connected calendar after the durable sync ends.
      if events == [], do: :fallback, else: {:ok, events}
    else
      :fallback
    end
  end

  defp annotate_event_messages(messages, source_scope, context) when is_list(messages) do
    google_source =
      case get_in(context, [:event, :topic]) do
        "email:" <> account_email ->
          SourceScope.google_account_for_email(source_scope, account_email)

        _ ->
          nil
      end

    provider = account_provider(google_source)
    account_email = account_email(google_source)

    Enum.map(messages, fn message ->
      message
      |> stringify_keys()
      |> maybe_put("google_provider", provider)
      |> maybe_put("account", account_email)
    end)
  end

  defp annotate_event_messages(_messages, _source_scope, _context), do: []

  defp payload_source(payload) when is_map(payload) do
    payload
    |> stringify_keys()
    |> Map.get("source")
  end

  defp payload_source(_payload), do: nil

  defp payload_data(payload) when is_map(payload) do
    payload
    |> stringify_keys()
    |> Map.get("data", %{})
    |> stringify_keys()
  end

  defp payload_data(_payload), do: %{}

  defp event_source(context) do
    payload_source(get_in(context, [:event, :payload]))
  end

  # A morning-brief acquisition (deep lookback, news/weather, web context) is
  # only warranted on the cycle where the morning briefing will actually
  # generate. morning_briefing is default-enabled, so gating on skill
  # membership alone made EVERY 10-minute scheduled wakeup refetch the full
  # deep window (14 days of Gmail/Slack, cursor ignored) plus news/weather.
  # The briefing cron's wakeup carries a distinct payload
  # (Maraithon.Runtime.BriefingCron), and a plain scheduled wakeup only
  # qualifies when the briefing is due-and-not-yet-generated for the local
  # day — the same due check BriefingSchedules.list_due_morning_agents/1 and
  # the skill's own due_now?/Briefs dedupe use.
  defp morning_brief_trigger?(user_id, skill_ids, skill_configs, context) do
    ("briefing" in skill_ids or "morning_briefing" in skill_ids) and
      get_in(context, [:trigger, :type]) == :wakeup and
      is_nil(get_in(context, [:event, :payload])) and
      (briefing_cron_wakeup?(context) or
         morning_brief_due?(user_id, skill_ids, skill_configs, context))
  end

  defp briefing_cron_wakeup?(context) do
    case get_in(context, [:trigger, :payload]) do
      %{} = payload ->
        Map.get(payload, "source") == "briefing_cron" or
          Map.get(payload, "cadence") == "morning"

      _other ->
        false
    end
  end

  defp morning_brief_due?(user_id, skill_ids, skill_configs, context) when is_binary(user_id) do
    now = context[:timestamp] || DateTime.utc_now()

    offset_fallback =
      first_skill_integer(
        skill_ids,
        skill_configs,
        "timezone_offset_hours",
        @default_timezone_offset_hours
      )

    timezone_name =
      skill_ids
      |> Enum.find_value(fn skill_id ->
        config = Map.get(skill_configs, skill_id, %{})
        normalize_string(Map.get(config, "timezone") || Map.get(config, "timezone_name"))
      end)

    hour =
      skill_ids
      |> first_skill_integer(skill_configs, "morning_brief_hour_local", 8)
      |> then(fn value -> if value in 0..23, do: value, else: 8 end)

    minute =
      skill_ids
      |> first_skill_integer(skill_configs, "morning_brief_minute_local", 0)
      |> then(fn value -> if value in 0..59, do: value, else: 0 end)

    local_now = DateTime.add(now, Timezones.offset_at(timezone_name, now, offset_fallback), :hour)

    Time.compare(DateTime.to_time(local_now), Time.new!(hour, minute, 0)) != :lt and
      not Briefs.exists?(
        user_id,
        "morning_briefing:" <> Date.to_iso8601(DateTime.to_date(local_now))
      )
  end

  defp morning_brief_due?(_user_id, _skill_ids, _skill_configs, _context), do: false

  # Same shape as morning_brief_due?, keyed on the commitment tracker's daily
  # review: due once local time passes commitment_review_hour_local and no
  # "commitment_tracker:<local-date>" brief has been recorded yet.
  defp commitment_review_due?(user_id, skill_ids, skill_configs, context)
       when is_binary(user_id) do
    "commitment_tracker" in skill_ids and
      get_in(context, [:trigger, :type]) == :wakeup and
      commitment_review_window_open?(user_id, skill_ids, skill_configs, context)
  end

  defp commitment_review_due?(_user_id, _skill_ids, _skill_configs, _context), do: false

  defp commitment_review_window_open?(user_id, skill_ids, skill_configs, context) do
    now = context[:timestamp] || DateTime.utc_now()
    tracker_config = Map.get(skill_configs, "commitment_tracker", %{})

    offset_fallback =
      first_skill_integer(
        skill_ids,
        skill_configs,
        "timezone_offset_hours",
        @default_timezone_offset_hours
      )

    timezone_name =
      normalize_string(
        Map.get(tracker_config, "timezone") || Map.get(tracker_config, "timezone_name")
      )

    hour =
      tracker_config
      |> Map.get("commitment_review_hour_local")
      |> then(fn value -> if is_integer(value) and value in 0..23, do: value, else: 7 end)

    local_now = DateTime.add(now, Timezones.offset_at(timezone_name, now, offset_fallback), :hour)

    Time.compare(DateTime.to_time(local_now), Time.new!(hour, 0, 0)) != :lt and
      not Briefs.exists?(
        user_id,
        "commitment_tracker:" <> Date.to_iso8601(DateTime.to_date(local_now))
      )
  end

  defp truthy?(true), do: true
  defp truthy?(_other), do: false

  defp slack_key_channels(skill_ids, skill_configs) do
    configured =
      skill_ids
      |> Enum.flat_map(fn skill_id ->
        skill_configs
        |> Map.get(skill_id, %{})
        |> configured_list("slack_key_channels")
      end)
      |> Enum.map(&normalize_channel_name/1)
      |> Enum.reject(&is_nil/1)

    (@default_slack_key_channels ++ configured)
    |> Enum.map(&normalize_channel_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp commercial_gmail_queries(skill_ids, skill_configs) do
    configured =
      skill_ids
      |> Enum.flat_map(fn skill_id ->
        skill_configs
        |> Map.get(skill_id, %{})
        |> configured_list("commercial_gmail_queries")
      end)
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)

    (@default_actionable_gmail_queries ++ @default_commercial_gmail_queries ++ configured)
    |> Enum.uniq()
  end

  defp service_required?(requirements, provider, service) do
    Enum.any?(requirements, fn requirement ->
      requirement["provider"] == provider and
        (service == nil or requirement["service"] == service)
    end)
  end

  defp event_allows_source?(nil, _source), do: true
  defp event_allows_source?("gmail", "gmail"), do: true
  defp event_allows_source?("google_calendar", "google_calendar"), do: true
  defp event_allows_source?(source, _expected) when is_binary(source), do: false
  defp event_allows_source?(_source, _expected), do: true

  defp max_skill_integer(skill_ids, skill_configs, key, default) do
    skill_ids
    |> Enum.map(fn skill_id ->
      skill_configs
      |> Map.get(skill_id, %{})
      |> Map.get(key)
      |> parse_integer()
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> default
      values -> Enum.max(values)
    end
  end

  defp first_skill_integer(skill_ids, skill_configs, key, default) do
    skill_ids
    |> Enum.find_value(fn skill_id ->
      skill_configs
      |> Map.get(skill_id, %{})
      |> Map.get(key)
      |> parse_integer()
    end)
    |> case do
      nil -> default
      value -> value
    end
  end

  defp local_day_start_utc(%DateTime{} = reference_at, offset_hours)
       when is_integer(offset_hours) do
    reference_at
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-offset_hours, :hour)
  end

  defp annotate_google_items(items, source_scope, provider) when is_list(items) do
    google_source = SourceScope.google_account_for_provider(source_scope, provider)
    account_email = account_email(google_source)

    Enum.map(items, fn item ->
      item
      |> stringify_keys()
      |> maybe_put("google_provider", provider)
      |> maybe_put("account", account_email)
    end)
  end

  defp annotate_google_items(_items, _source_scope, _provider), do: []

  defp enrich_gmail_messages(messages, user_id, default_provider, plan)
       when is_list(messages) and is_binary(user_id) do
    normalized = Enum.map(messages, &normalize_gmail_body_state/1)

    body_candidates =
      normalized
      |> Enum.with_index()
      |> Enum.reject(fn {message, _index} -> gmail_body_available?(message) end)
      |> Enum.take(gmail_body_fetch_limit(plan))

    enriched_by_index =
      body_candidates
      |> Enum.map(&elem(&1, 0))
      |> enrich_gmail_message_bodies(user_id, default_provider, plan)
      |> then(fn enriched ->
        body_candidates
        |> Enum.map(&elem(&1, 1))
        |> Enum.zip(enriched)
        |> Map.new()
      end)

    normalized
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      case Map.fetch(enriched_by_index, index) do
        {:ok, enriched} ->
          enriched

        :error ->
          if gmail_body_available?(message) do
            normalize_gmail_body_state(message)
          else
            mark_gmail_body_not_fetched(message)
          end
      end
    end)
  end

  defp enrich_gmail_messages(messages, _user_id, _default_provider, _plan) when is_list(messages),
    do: Enum.map(messages, &normalize_gmail_body_state/1)

  defp enrich_gmail_messages(_messages, _user_id, _default_provider, _plan), do: []

  defp enrich_gmail_message_bodies([], _user_id, _default_provider, _plan), do: []

  defp enrich_gmail_message_bodies(messages, user_id, default_provider, plan) do
    waves = ceil_div(length(messages), @gmail_body_fetch_concurrency)
    body_phase_timeout = gmail_phase_budgets(plan).body

    timeout =
      min(
        gmail_body_fetch_timeout_ms(plan),
        max(div(body_phase_timeout, max(waves, 1)), 1)
      )

    results =
      Task.async_stream(
        messages,
        fn message ->
          safe_gmail_task(fn -> enrich_gmail_message(user_id, message, default_provider) end)
        end,
        max_concurrency: @gmail_body_fetch_concurrency,
        ordered: true,
        timeout: timeout,
        on_timeout: :kill_task
      )

    messages
    |> Enum.zip(results)
    |> Enum.map(fn
      {_original, {:ok, message}} when is_map(message) ->
        message

      {original, _failure} ->
        mark_gmail_body_unavailable(original, "fetch_failed")
    end)
  end

  defp normalize_gmail_body_state(message) do
    message = stringify_keys(message)

    if gmail_body_available?(message) do
      message
      |> put_gmail_body_text()
      |> mark_gmail_body_available()
    else
      message
    end
  end

  defp mark_gmail_body_available(message) when is_map(message) do
    status =
      case Map.get(message, "body_status") do
        "available" <> _suffix = existing -> existing
        _other -> "available"
      end

    message
    |> Map.put("body_available", true)
    |> Map.put("body_status", status)
  end

  defp mark_gmail_body_not_fetched(message) do
    message = stringify_keys(message)

    case Map.get(message, "body_status") do
      status when is_binary(status) and status != "" ->
        Map.put(message, "body_available", false)

      _status ->
        mark_gmail_body_unavailable(message, "not_fetched")
    end
  end

  defp mark_gmail_body_unavailable(message, status) do
    message
    |> stringify_keys()
    |> Map.put("body_available", false)
    |> Map.put("body_status", status)
  end

  defp gmail_body_fetch_limit(plan) when is_map(plan) do
    plan
    |> Map.get(:gmail_body_fetch_limit, @default_gmail_body_fetch_limit)
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_gmail_body_fetch_limit
    end
  end

  defp gmail_body_fetch_limit(_plan), do: @default_gmail_body_fetch_limit

  defp gmail_phase_budgets(%{exhaustive_account_delta?: true} = plan) do
    total = max(gmail_fetch_timeout_ms(plan), 4)
    reserve = min(5_000, max(div(total, 20), 1))

    %{
      provider: max(total - reserve, 1),
      commercial: 1,
      body: 1,
      reserve: reserve,
      total: total
    }
  end

  defp gmail_phase_budgets(plan) do
    total = max(gmail_fetch_timeout_ms(plan), 4)
    reserve = min(2_000, max(div(total, 10), 1))
    usable = max(total - reserve, 3)
    targeted = min(@gmail_targeted_search_phase_timeout_ms, max(div(usable, 4), 1))
    remaining = max(usable - targeted, 2)
    provider = min(@gmail_provider_phase_timeout_ms, max(div(remaining + 1, 2), 1))
    body = min(@gmail_body_phase_timeout_ms, max(remaining - provider, 1))

    %{provider: provider, commercial: targeted, body: body, reserve: reserve, total: total}
  end

  defp ceil_div(0, divisor) when is_integer(divisor) and divisor > 0, do: 0

  defp ceil_div(value, divisor)
       when is_integer(value) and value > 0 and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

  defp gmail_body_fetch_timeout_ms(plan) when is_map(plan) do
    plan
    |> Map.get(:gmail_body_fetch_timeout_ms, configured_gmail_body_fetch_timeout_ms())
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> configured_gmail_body_fetch_timeout_ms()
    end
  end

  defp gmail_body_fetch_timeout_ms(_plan), do: configured_gmail_body_fetch_timeout_ms()

  defp gmail_fetch_timeout_ms(plan),
    do: plan_positive_integer(plan, :gmail_fetch_timeout_ms, @default_gmail_fetch_timeout_ms)

  defp calendar_fetch_timeout_ms(plan),
    do:
      plan_positive_integer(plan, :calendar_fetch_timeout_ms, @default_calendar_fetch_timeout_ms)

  defp slack_fetch_timeout_ms(plan),
    do: plan_positive_integer(plan, :slack_fetch_timeout_ms, @default_slack_fetch_timeout_ms)

  defp slack_channel_fetch_timeout_ms(plan),
    do:
      plan_positive_integer(
        plan,
        :slack_channel_fetch_timeout_ms,
        @default_slack_channel_fetch_timeout_ms
      )

  defp slack_search_timeout_ms(plan),
    do: plan_positive_integer(plan, :slack_search_timeout_ms, @default_slack_search_timeout_ms)

  defp slack_self_authored_query_limit(plan),
    do:
      plan_positive_integer(
        plan,
        :slack_self_authored_query_limit,
        @default_slack_self_authored_query_limit
      )

  defp companion_fetch_timeout_ms(plan),
    do:
      plan_positive_integer(
        plan,
        :companion_fetch_timeout_ms,
        @default_companion_fetch_timeout_ms
      )

  defp news_fetch_timeout_ms(plan),
    do: plan_positive_integer(plan, :news_fetch_timeout_ms, @default_news_fetch_timeout_ms)

  defp weather_fetch_timeout_ms(plan),
    do: plan_positive_integer(plan, :weather_fetch_timeout_ms, @default_weather_fetch_timeout_ms)

  defp plan_positive_integer(plan, key, default) when is_map(plan) do
    plan
    |> Map.get(key, default)
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp plan_positive_integer(_plan, _key, default), do: default

  defp configured_gmail_body_fetch_timeout_ms do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:gmail_body_fetch_timeout_ms, @default_gmail_body_fetch_timeout_ms)
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_gmail_body_fetch_timeout_ms
    end
  end

  defp fetch_commercial_gmail_messages(
         _user_id,
         _provider,
         _queries,
         _fetch_opts,
         total_limit
       )
       when not is_integer(total_limit) or total_limit <= 0,
       do: []

  defp fetch_commercial_gmail_messages(user_id, provider, queries, fetch_opts, total_limit)
       when is_list(queries) and is_list(fetch_opts) do
    query_specs = gmail_commercial_query_specs(queries, total_limit)

    query_concurrency =
      fetch_opts
      |> Keyword.get(:commercial_query_concurrency, 1)
      |> min(max(length(query_specs), 1))
      |> max(1)

    query_timeout =
      Keyword.get(
        fetch_opts,
        :commercial_query_timeout_ms,
        @gmail_targeted_search_phase_timeout_ms
      )

    gmail_opts =
      Keyword.drop(fetch_opts, [:commercial_query_concurrency, :commercial_query_timeout_ms])

    query_specs
    |> Task.async_stream(
      fn {query, limit} ->
        safe_gmail_task(fn ->
          result =
            gmail_module().fetch_messages(
              user_id,
              gmail_opts ++
                [
                  max_results: limit,
                  label_ids: [],
                  query: query,
                  provider: provider
                ]
            )

          {query, result}
        end)
      end,
      max_concurrency: query_concurrency,
      ordered: true,
      timeout: query_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {query, {:ok, messages, _metadata}}} when is_list(messages) ->
        annotate_targeted_gmail_matches(messages, query)

      {:ok, {query, {:ok, messages}}} when is_list(messages) ->
        annotate_targeted_gmail_matches(messages, query)

      {:ok, {query, {:error, reason}}} ->
        Logger.debug("ChiefOfStaff commercial Gmail search failed",
          user_fingerprint: Redaction.fingerprint(user_id),
          provider_reference: Redaction.fingerprint(provider),
          query_reference: Redaction.fingerprint(query),
          failure_code: Redaction.error_class(reason)
        )

        []

      {:ok, {:task_failure, reason}} ->
        Logger.debug("ChiefOfStaff commercial Gmail task failed",
          user_fingerprint: Redaction.fingerprint(user_id),
          provider_reference: Redaction.fingerprint(provider),
          failure_code: Redaction.error_class(reason)
        )

        []

      {:exit, reason} ->
        Logger.debug("ChiefOfStaff commercial Gmail search timed out",
          user_fingerprint: Redaction.fingerprint(user_id),
          provider_reference: Redaction.fingerprint(provider),
          failure_code: Redaction.error_class(reason)
        )

        []
    end)
    |> dedupe_messages()
    |> Enum.take(total_limit)
  end

  defp annotate_targeted_gmail_matches(messages, query)
       when is_list(messages) and is_binary(query) do
    Enum.map(messages, fn message ->
      message
      |> stringify_keys()
      |> Map.put("search_mode", "targeted_actionable")
      |> Map.put("search_query", query)
    end)
  end

  defp annotate_targeted_gmail_matches(messages, _query), do: messages

  defp enrich_gmail_message(user_id, message, default_provider) do
    metadata = stringify_keys(message)
    provider = Map.get(metadata, "google_provider") || default_provider
    message_id = Map.get(metadata, "message_id") || Map.get(metadata, "id")

    cond do
      gmail_body_available?(metadata) ->
        metadata
        |> put_gmail_body_text()
        |> mark_gmail_body_available()

      is_binary(provider) and provider != "" and is_binary(message_id) and message_id != "" ->
        case gmail_module().fetch_message_content(user_id, message_id,
               provider: provider,
               listed_message: true
             ) do
          {:ok, content} ->
            merged =
              metadata
              |> merge_gmail_content(content)
              |> maybe_put("google_provider", provider)
              |> put_gmail_body_text()

            if gmail_body_available?(merged) do
              merged
              |> mark_gmail_body_available()
            else
              merged
              |> Map.put("body_available", false)
              |> Map.put("body_status", "full_body_empty")
            end

          {:error, reason} ->
            metadata
            |> Map.put("body_available", false)
            |> Map.put("body_status", "fetch_error")
            |> Map.put("body_error", Redaction.error_class(reason))
        end

      true ->
        metadata
        |> Map.put("body_available", false)
        |> Map.put("body_status", "missing_provider_or_message_id")
    end
  end

  defp merge_gmail_content(metadata, content) do
    content = stringify_keys(content)

    Map.merge(metadata, content, fn _key, original, fetched ->
      if blank_string?(fetched), do: original, else: fetched
    end)
  end

  defp put_gmail_body_text(message) do
    body = Maraithon.Connectors.Gmail.BodyText.from_message(message)

    maybe_put(message, "body_text", body)
  end

  defp gmail_body_available?(message) when is_map(message) do
    message
    |> put_gmail_body_text()
    |> Map.get("body_text")
    |> present_string?()
  end

  defp gmail_body_available?(_message), do: false

  defp count_full_body_messages(messages) when is_list(messages),
    do: Enum.count(messages, &gmail_body_available?/1)

  defp count_full_body_messages(_messages), do: 0

  defp count_body_missing_messages(messages) when is_list(messages) do
    Enum.count(messages, fn message ->
      is_map(message) and Map.get(message, "body_available") == false
    end)
  end

  defp count_body_missing_messages(_messages), do: 0

  defp group_messages_by_provider(messages) when is_list(messages) do
    Enum.group_by(messages, &Map.get(&1, "google_provider", "unknown"))
  end

  defp group_events_by_provider(events) when is_list(events) do
    Enum.group_by(events, &Map.get(&1, "google_provider", "unknown"))
  end

  defp filter_messages_by_label(messages, label, _limit) when is_list(messages) do
    Enum.filter(messages, fn message ->
      labels = message |> Map.get("labels", []) |> Enum.map(&to_string/1)
      targeted? = Map.get(message, "search_mode") == "targeted_actionable"

      label in labels or (label == "INBOX" and targeted? and "SENT" not in labels)
    end)
  end

  defp filter_messages_by_label(_messages, _label, _limit), do: []

  defp local_calendar_event_for_bundle(%Maraithon.LocalCalendar.LocalEvent{} = event) do
    %{
      "event_id" => event.guid || event.id,
      "source" => "local_calendar",
      "calendar_name" => event.calendar_name,
      "summary" => event.title || "Untitled event",
      "notes" => truncate_string(event.notes, 2_000),
      "start" => timestamp(event.start_at),
      "end" => timestamp(event.end_at),
      "location" => event.location,
      "attendees" => event.attendee_emails || [],
      "organizer" => event.organizer_email,
      "is_all_day" => event.is_all_day,
      "source_account_label" => event.calendar_name,
      "source_item_id" => event.guid || event.id,
      "source_occurred_at" => timestamp(event.start_at)
    }
  end

  defp local_calendar_event_for_bundle(event) when is_map(event), do: stringify_keys(event)

  defp message_sender_handles(messages, chats) when is_list(messages) and is_list(chats) do
    chat_messages =
      Enum.map(chats, fn chat ->
        Map.get(chat, :latest_message) || Map.get(chat, "latest_message")
      end)

    (messages ++ chat_messages)
    |> Enum.map(&message_sender_handle/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp message_sender_handles(_messages, _chats), do: []

  defp message_sender_handle(message) when is_map(message) do
    Map.get(message, :sender_handle) || Map.get(message, "sender_handle")
  end

  defp message_sender_handle(_message), do: nil

  defp local_message_for_bundle(
         %Maraithon.LocalMessages.LocalMessage{} = message,
         people_by_handle
       )
       when is_map(people_by_handle) do
    message.sender_handle
    |> then(&Map.get(people_by_handle, &1))
    |> add_resolved_message_person(local_message_for_bundle(message))
  end

  defp local_message_for_bundle(message, _people_by_handle), do: local_message_for_bundle(message)

  defp local_message_for_bundle(%Maraithon.LocalMessages.LocalMessage{} = message) do
    %{
      "message_id" => message.guid || message.id,
      "guid" => message.guid,
      "local_id" => message.local_id,
      "source" => message.source || "imessage",
      "chat_key" => message.chat_key,
      "chat_display_name" => message.chat_display_name,
      "chat_style" => message.chat_style,
      "sender_handle" => message.sender_handle,
      "is_from_me" => message.is_from_me,
      "text" => truncate_string(message.text, 2_000),
      "sent_at" => timestamp(message.sent_at),
      "has_attachments" => message.has_attachments,
      "attachments" => message.attachments || %{},
      "source_item_id" => message.guid || message.id,
      "source_occurred_at" => timestamp(message.sent_at)
    }
  end

  defp local_message_for_bundle(message) when is_map(message), do: stringify_keys(message)

  defp local_chat_for_bundle(%{chat_key: _chat_key} = chat, people_by_handle)
       when is_map(people_by_handle) do
    chat
    |> local_chat_for_bundle()
    |> add_resolved_latest_sender(people_by_handle)
  end

  defp local_chat_for_bundle(chat, _people_by_handle), do: local_chat_for_bundle(chat)

  defp local_chat_for_bundle(%{chat_key: chat_key} = chat) do
    latest = Map.get(chat, :latest_message) || Map.get(chat, "latest_message")
    latest_message = if latest, do: local_message_for_bundle(latest), else: nil

    %{
      "chat_key" => chat_key,
      "chat_display_name" =>
        Map.get(chat, :chat_display_name) || Map.get(chat, "chat_display_name"),
      "message_count_last_7d" =>
        Map.get(chat, :message_count_last_7d) || Map.get(chat, "message_count_last_7d") || 0,
      "latest_message" => latest_message,
      "latest_snippet" => latest_message && Map.get(latest_message, "text"),
      "latest_sender" => latest_message && Map.get(latest_message, "sender_handle"),
      "latest_is_from_me" => latest_message && Map.get(latest_message, "is_from_me"),
      "latest_sent_at" => latest_message && Map.get(latest_message, "sent_at")
    }
  end

  defp local_chat_for_bundle(chat) when is_map(chat), do: stringify_keys(chat)

  defp add_resolved_message_person(nil, message), do: message

  defp add_resolved_message_person(%Maraithon.Crm.Person{} = person, message) do
    message
    |> Map.put("sender_display_name", person.display_name)
    |> Map.put("sender_person_id", person.id)
    |> maybe_put("sender_relationship", person.relationship)
  end

  defp add_resolved_latest_sender(chat, people_by_handle)
       when is_map(chat) and is_map(people_by_handle) do
    case Map.get(people_by_handle, Map.get(chat, "latest_sender")) do
      %Maraithon.Crm.Person{} = person ->
        chat
        |> Map.put("latest_sender_display_name", person.display_name)
        |> Map.put("latest_sender_person_id", person.id)

      nil ->
        chat
    end
  end

  defp voice_memo_for_bundle(%Maraithon.LocalVoiceMemos.LocalVoiceMemo{} = memo) do
    %{
      "memo_id" => memo.guid || memo.id,
      "guid" => memo.guid,
      "local_id" => memo.local_id,
      "source" => memo.source || "voice_memos",
      "title" => memo.title || "(untitled voice memo)",
      "snippet" => memo.snippet || "",
      "transcript" => truncate_string(memo.transcript, 4_000),
      "duration_seconds" => memo.duration_seconds,
      "created_at" => timestamp(memo.created_at),
      "has_transcript" => present_string?(memo.transcript),
      "transcript_engine" => memo.transcript_engine,
      "transcript_lang" => memo.transcript_lang,
      "source_item_id" => memo.guid || memo.id,
      "source_occurred_at" => timestamp(memo.created_at)
    }
  end

  defp voice_memo_for_bundle(memo) when is_map(memo), do: stringify_keys(memo)

  defp note_for_bundle(%Maraithon.LocalNotes.LocalNote{} = note) do
    %{
      "note_id" => note.guid || note.id,
      "guid" => note.guid,
      "local_id" => note.local_id,
      "source" => note.source || "notes",
      "title" => note.title || "(untitled note)",
      "snippet" => note.snippet || "",
      "body" => truncate_string(note.body, 4_000),
      "folder" => note.folder,
      "is_pinned" => note.is_pinned,
      "created_at" => timestamp(note.created_at),
      "modified_at" => timestamp(note.modified_at),
      "source_item_id" => note.guid || note.id,
      "source_occurred_at" => timestamp(note.modified_at || note.created_at)
    }
  end

  defp note_for_bundle(note) when is_map(note), do: stringify_keys(note)

  defp reminder_for_bundle(%Maraithon.LocalReminders.LocalReminder{} = reminder) do
    %{
      "reminder_id" => reminder.guid || reminder.id,
      "guid" => reminder.guid,
      "local_id" => reminder.local_id,
      "source" => reminder.source || "reminders",
      "title" => reminder.title || "(untitled reminder)",
      "notes" => truncate_string(reminder.notes, 2_000),
      "list_name" => reminder.list_name,
      "priority" => reminder.priority,
      "due_at" => timestamp(reminder.due_at),
      "is_completed" => reminder.is_completed,
      "has_alarm" => reminder.has_alarm,
      "url_attachment" => reminder.url_attachment,
      "created_at" => timestamp(reminder.created_at),
      "modified_at" => timestamp(reminder.modified_at),
      "source_item_id" => reminder.guid || reminder.id,
      "source_occurred_at" => timestamp(reminder.modified_at || reminder.created_at)
    }
  end

  defp reminder_for_bundle(reminder) when is_map(reminder), do: stringify_keys(reminder)

  defp file_for_bundle(%Maraithon.LocalFiles.LocalFile{} = file) do
    %{
      "file_id" => file.guid || file.id,
      "guid" => file.guid,
      "local_id" => file.local_id,
      "source" => file.source || "files",
      "filename" => file.filename,
      "path" => file.path,
      "extension" => file.extension,
      "mime_type" => file.mime_type,
      "byte_size" => file.byte_size,
      "text_content" => truncate_string(file.text_content, 3_000),
      "text_truncated" => file.text_truncated,
      "created_at" => timestamp(file.created_at),
      "modified_at" => timestamp(file.modified_at),
      "source_item_id" => file.guid || file.id,
      "source_occurred_at" => timestamp(file.modified_at || file.created_at)
    }
  end

  defp file_for_bundle(file) when is_map(file), do: stringify_keys(file)

  defp browser_visit_for_bundle(%Maraithon.LocalBrowserHistory.LocalVisit{} = visit) do
    %{
      "visit_id" => visit.guid || visit.id,
      "guid" => visit.guid,
      "local_id" => visit.local_id,
      "source" => visit.source || "browser_history",
      "browser" => visit.browser,
      "title" => visit.title,
      "url" => visit.url,
      "host" => visit.host,
      "last_visited_at" => timestamp(visit.last_visited_at),
      "visit_count" => visit.visit_count,
      "source_item_id" => visit.guid || visit.id,
      "source_occurred_at" => timestamp(visit.last_visited_at)
    }
  end

  defp browser_visit_for_bundle(visit) when is_map(visit), do: stringify_keys(visit)

  defp serialize_slack_channel(channel) when is_map(channel) do
    %{
      "id" => channel["id"],
      "name" => channel["name"],
      "is_private" => channel["is_private"] || false,
      "is_im" => channel["is_im"] || false,
      "is_mpim" => channel["is_mpim"] || false,
      "conversation_kind" => slack_conversation_kind(channel),
      "is_member" => channel["is_member"] || false
    }
  end

  defp put_slack_channel_user_fields(channel_payload, channel, user_directory)
       when is_map(channel_payload) and is_map(channel) do
    counterparty_id = channel["user"]

    channel_payload
    |> maybe_put("counterparty_user_id", counterparty_id)
    |> maybe_put(
      "counterparty_display_name",
      UserDirectory.display_name(user_directory, counterparty_id)
    )
  end

  defp serialize_slack_message(message, channel, team_id, workspace, user_directory)
       when is_map(message) do
    user_id = message["user"] || message["bot_id"]
    text = message["text"]

    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => channel["id"],
      "channel_name" => channel["name"] || slack_conversation_kind(channel),
      "conversation_kind" => slack_conversation_kind(channel),
      "is_dm" => channel["is_im"] || false,
      "is_mpim" => channel["is_mpim"] || false,
      "ts" => message["ts"],
      "thread_ts" => message["thread_ts"],
      "user" => user_id,
      "user_display_name" => UserDirectory.display_name(user_directory, user_id),
      "mentioned_users" => UserDirectory.mentioned_users(text, user_directory),
      "text_resolved" => UserDirectory.replace_mentions(text, user_directory),
      "bot_id" => message["bot_id"],
      "subtype" => message["subtype"],
      "text" => text,
      "reply_count" => message["reply_count"],
      "latest_reply" => message["latest_reply"],
      "reactions" => normalize_list(message["reactions"])
    }
  end

  defp serialize_slack_match(match, team_id, workspace, user_directory) when is_map(match) do
    user_id = match["user"] || match["bot_id"]
    text = match["text"]
    channel = match["channel"]

    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => slack_match_channel_id(channel),
      "channel_name" => slack_match_channel_name(channel),
      "ts" => match["ts"],
      "thread_ts" => match["thread_ts"],
      "user" => user_id,
      "user_display_name" => UserDirectory.display_name(user_directory, user_id),
      "mentioned_users" => UserDirectory.mentioned_users(text, user_directory),
      "text_resolved" => UserDirectory.replace_mentions(text, user_directory),
      "text" => text,
      "permalink" => match["permalink"]
    }
  end

  defp slack_user_directory(access_token, messages, channel, directory \\ %{}) do
    message_user_ids =
      messages
      |> normalize_list()
      |> Enum.flat_map(&slack_user_ids_from_message/1)

    user_ids = message_user_ids ++ slack_user_ids_from_channel(channel)
    missing_user_ids = missing_slack_user_ids(user_ids, directory)
    remaining_user_lookups = max(@slack_user_directory_limit - map_size(directory), 0)
    lookup_user_ids = Enum.take(missing_user_ids, remaining_user_lookups)

    resolved =
      if lookup_user_ids != [] do
        UserDirectory.resolve(access_token, lookup_user_ids,
          max_users: length(lookup_user_ids),
          max_concurrency: 8,
          timeout: @slack_user_directory_timeout_ms
        )
      else
        %{}
      end

    attempted = Map.new(lookup_user_ids, &{&1, nil})

    directory
    |> Map.merge(attempted)
    |> Map.merge(resolved)
  end

  defp missing_slack_user_ids(user_ids, directory) do
    user_ids
    |> UserDirectory.normalize_user_ids()
    |> Enum.reject(&Map.has_key?(directory, &1))
  end

  defp slack_user_ids_from_channel(channel) when is_map(channel) do
    [channel["user"]]
  end

  defp slack_user_ids_from_channel(_channel), do: []

  defp slack_user_ids_from_message(message) when is_map(message) do
    [
      message["user"],
      slack_message_channel_user(message["channel"])
    ] ++ UserDirectory.user_ids_from_text(message["text"])
  end

  defp slack_user_ids_from_message(_message), do: []

  defp slack_message_channel_user(%{} = channel), do: channel["user"]
  defp slack_message_channel_user(_channel), do: nil

  defp slack_match_channel_id(%{} = channel), do: channel["id"]
  defp slack_match_channel_id(channel) when is_binary(channel), do: channel
  defp slack_match_channel_id(_channel), do: nil

  defp slack_match_channel_name(%{} = channel), do: channel["name"]
  defp slack_match_channel_name(_channel), do: nil

  defp slack_user_ids_for_team(user_id, team_id) do
    pattern = ~r/^slack:#{Regex.escape(team_id)}:user:([^:]+)$/

    user_id
    |> OAuth.list_user_tokens()
    |> Enum.map(& &1.provider)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn provider ->
      case Regex.run(pattern, provider, capture: :all_but_first) do
        [slack_user_id] -> [slack_user_id]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp slack_search_after_date(oldest) when is_binary(oldest) do
    with {seconds, _rest} <- Integer.parse(oldest),
         {:ok, datetime} <- DateTime.from_unix(seconds, :second) do
      datetime
      |> DateTime.to_date()
      |> Date.to_iso8601()
    else
      _ -> Date.utc_today() |> Date.to_iso8601()
    end
  end

  defp slack_search_after_date(_oldest), do: Date.utc_today() |> Date.to_iso8601()

  defp slack_workspace_messages(workspace) when is_map(workspace) do
    workspace
    |> Map.get("channels", Map.get(workspace, "key_channels", []))
    |> normalize_list()
    |> Enum.flat_map(fn channel ->
      channel
      |> Map.get("messages", [])
      |> normalize_list()
    end)
  end

  defp slack_workspace_messages(_workspace), do: []

  defp slack_mentions_from_workspaces(workspaces) when is_list(workspaces) do
    workspaces
    |> Enum.flat_map(fn workspace ->
      workspace
      |> Map.get("mentions", [])
      |> normalize_list()
    end)
  end

  defp slack_channel_priority(channel, key_channels) when is_map(channel) do
    name = normalize_channel_name(channel["name"])

    cond do
      is_binary(name) and name in key_channels ->
        0

      is_binary(name) and String.starts_with?(name, "exec-") ->
        1

      is_binary(name) and String.starts_with?(name, "founders-") ->
        2

      channel["is_private"] == true and channel["is_im"] != true and channel["is_mpim"] != true ->
        3

      channel["is_im"] == true ->
        4

      channel["is_mpim"] == true ->
        5

      true ->
        6
    end
  end

  defp slack_channel_priority(_channel, _key_channels), do: 6

  defp maybe_take_slack_conversations(conversations, %{exhaustive_account_delta?: true}),
    do: conversations

  defp maybe_take_slack_conversations(conversations, plan),
    do: Enum.take(conversations, max(plan.slack_channel_limit, 0))

  defp slack_durable_event_delta?(
         %{
           exhaustive_account_delta?: true,
           deep_lookback?: false
         } = plan
       ),
       do: not slack_source_replay?(plan)

  defp slack_durable_event_delta?(_plan), do: false

  # Historical source replays are a correctness proof, not a low-latency
  # polling path. They establish every readable conversation, then use Slack's
  # paginated workspace search as the provider source stream. It includes
  # messages from channels, DMs, group DMs, and replies beneath older roots;
  # unlike one history request per conversation, it remains usable within
  # Slack's per-method rate limits. Persisted Events API observations are
  # deliberately excluded so a delayed local write cannot manufacture coverage.
  defp slack_source_replay?(%{
         account_delta_source: "slack",
         source_replay_window: %{lower: lower, upper: upper}
       })
       when is_integer(lower) and is_integer(upper) and lower >= 0 and upper > lower,
       do: true

  defp slack_source_replay?(_plan), do: false

  defp maybe_filter_slack_replay_messages(messages, plan) when is_list(messages) do
    case plan.source_replay_window do
      %{lower: lower, upper: upper} when is_integer(lower) and is_integer(upper) ->
        if slack_source_replay?(plan) do
          Enum.filter(messages, fn message ->
            ts = slack_ts_sort_value(message)
            ts >= lower and ts < upper
          end)
        else
          messages
        end

      _other ->
        messages
    end
  end

  defp maybe_filter_slack_replay_messages(messages, _plan), do: messages

  defp fetch_slack_conversation_history(
         access_token,
         channel_id,
         oldest,
         %{exhaustive_account_delta?: true}
       ) do
    fetch_all_slack_history(access_token, channel_id, oldest, nil, [], 0)
  end

  defp fetch_slack_conversation_history(access_token, channel_id, oldest, plan) do
    slack_module().get_conversation_history(access_token, channel_id,
      limit: plan.slack_message_limit,
      oldest: oldest
    )
  end

  defp fetch_all_slack_history(access_token, channel_id, oldest, cursor, acc, page_count)
       when page_count < @max_slack_pagination_pages do
    opts =
      [limit: @slack_history_page_limit, oldest: oldest, inclusive: true]
      |> maybe_put_cursor(cursor)

    case slack_module().get_conversation_history(access_token, channel_id, opts) do
      {:ok, response} ->
        messages = acc ++ normalize_list(response["messages"])
        next_cursor = slack_next_cursor(response)

        cond do
          next_cursor ->
            fetch_all_slack_history(
              access_token,
              channel_id,
              oldest,
              next_cursor,
              messages,
              page_count + 1
            )

          response["has_more"] == true ->
            {:error, :slack_history_pagination_incomplete}

          true ->
            {:ok,
             response
             |> Map.put("messages", dedupe_raw_slack_messages(messages))
             |> Map.put("has_more", false)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_slack_history(_access_token, _channel_id, _oldest, _cursor, _acc, _page_count),
    do: {:error, :slack_history_pagination_limit}

  defp slack_next_cursor(response) when is_map(response) do
    response
    |> get_in(["response_metadata", "next_cursor"])
    |> normalize_string()
  end

  defp slack_next_cursor(_response), do: nil

  defp slack_coverage_failure_counts(errors) when is_list(errors) do
    Enum.frequencies_by(errors, &slack_coverage_failure_code/1)
  end

  defp slack_coverage_failure_counts(_errors), do: %{}

  defp slack_coverage_failure_code({phase, _channel_id, reason}) when is_atom(phase),
    do: "#{phase}:#{slack_coverage_reason_code(reason)}"

  defp slack_coverage_failure_code({phase, _channel_id, _thread_ts, reason})
       when is_atom(phase),
       do: "#{phase}:#{slack_coverage_reason_code(reason)}"

  defp slack_coverage_failure_code(_error), do: "unknown_error"

  defp slack_coverage_reason_code({:slack_error, code})
       when code in @slack_loggable_api_error_codes,
       do: "slack_#{code}"

  defp slack_coverage_reason_code({:slack_error, _code}), do: "slack_error"

  defp slack_coverage_reason_code({:http_status, status, _body})
       when is_integer(status) and status >= 100 and status <= 599,
       do: "http_status_#{status}"

  defp slack_coverage_reason_code(reason), do: Redaction.error_class(reason)

  defp slack_workspace_failure_counts({:slack_workspace_incomplete, counts})
       when is_map(counts),
       do: counts

  defp slack_workspace_failure_counts(_reason), do: %{}

  defp dedupe_raw_slack_messages(messages) do
    messages
    |> normalize_list()
    |> Enum.uniq_by(&normalize_string(&1["ts"]))
  end

  defp list_all_slack_conversations(access_token, opts) when is_binary(access_token) do
    list_all_slack_conversations(access_token, opts, nil, [])
  end

  defp list_all_slack_conversations(access_token, opts, cursor, acc) do
    request_opts =
      opts
      |> Keyword.put(:exclude_archived, true)
      |> Keyword.put(:limit, @slack_conversations_page_limit)
      |> maybe_put_cursor(cursor)

    case slack_module().list_conversations(access_token, request_opts) do
      {:ok, response} ->
        channels =
          response
          |> Map.get("channels", [])
          |> normalize_list()

        next_cursor =
          response
          |> get_in(["response_metadata", "next_cursor"])
          |> normalize_string()

        acc = acc ++ channels

        if next_cursor do
          list_all_slack_conversations(access_token, opts, next_cursor, acc)
        else
          {:ok, acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_cursor(opts, nil), do: opts
  defp maybe_put_cursor(opts, cursor), do: Keyword.put(opts, :cursor, cursor)

  defp slack_conversation_kind(%{"is_im" => true}), do: "dm"
  defp slack_conversation_kind(%{"is_mpim" => true}), do: "group_dm"
  defp slack_conversation_kind(%{"is_private" => true}), do: "private_channel"
  defp slack_conversation_kind(_channel), do: "public_channel"

  defp slack_readable_conversation?(%{"is_im" => true}), do: true
  defp slack_readable_conversation?(%{"is_mpim" => true}), do: true
  defp slack_readable_conversation?(%{"is_member" => true}), do: true
  defp slack_readable_conversation?(_channel), do: false

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp event_calendar_providers(events) when is_list(events) do
    events
    |> Enum.map(&Map.get(&1, "google_provider"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, &message_sort_key/1, :desc)
  end

  defp dedupe_messages(messages) when is_list(messages) do
    Enum.uniq_by(messages, fn message ->
      message_id =
        Map.get(message, "message_id") ||
          Map.get(message, :message_id) ||
          Map.get(message, "id") ||
          Map.get(message, :id)

      provider = Map.get(message, "google_provider") || Map.get(message, :google_provider)

      if message_id, do: {provider, message_id}, else: :erlang.phash2(message)
    end)
  end

  defp sort_events(events) when is_list(events) do
    Enum.sort_by(events, &event_sort_key/1, :asc)
  end

  defp normalize_channel_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_channel_name(_value), do: nil

  defp configured_list(config, key) when is_map(config) and is_binary(key) do
    top_level = Map.get(config, key)
    org_level = get_in(config, ["org", key])

    [top_level, org_level]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.reject(&is_nil/1)
  end

  defp configured_list(_config, _key), do: []

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  defp timestamp(value) when is_binary(value), do: normalize_string(value)
  defp timestamp(_value), do: nil

  defp truncate_string(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    value
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp truncate_string(_value, _limit), do: nil

  defp message_sort_key(%{"internal_date" => %DateTime{} = value}),
    do: DateTime.to_unix(value, :microsecond)

  defp message_sort_key(_message), do: 0

  defp event_sort_key(%{"start" => %DateTime{} = value}),
    do: DateTime.to_unix(value, :microsecond)

  defp event_sort_key(%{"start" => %{"date" => value}}) when is_binary(value), do: value
  defp event_sort_key(_event), do: 0

  defp put_source_summary(telemetry, source, summary) do
    Map.update(telemetry, "sources", %{source => summary}, &Map.put(&1, source, summary))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp blank_string?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_string?(nil), do: true
  defp blank_string?(_value), do: false

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_keys/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value

  defp parse_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp gmail_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:gmail_module, Maraithon.Connectors.Gmail)
  end

  defp calendar_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:calendar_module, Maraithon.Tools.GoogleCalendarHelpers)
  end

  defp slack_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:slack_module, Maraithon.Connectors.Slack)
  end

  defp news_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:news_module, News)
  end

  defp weather_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:weather_module, Maraithon.Weather)
  end

  defp account_provider(%{"provider" => provider}) when is_binary(provider), do: provider
  defp account_provider(_source), do: nil

  defp account_email(%{"account_email" => account_email}) when is_binary(account_email),
    do: account_email

  defp account_email(_source), do: nil
end
