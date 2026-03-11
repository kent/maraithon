defmodule Maraithon.OnboardingProof do
  @moduledoc """
  Builds a small "instant proof of value" preview from recently connected data.

  The preview is intentionally lightweight and onboarding-focused: it scans a
  small slice of Gmail, Calendar, and Slack data, then asks the LLM to choose
  the three strongest examples of value Maraithon would have surfaced.
  """

  alias Maraithon.Connectors.{Gmail, GoogleCalendar, Slack}
  alias Maraithon.LLM
  alias Maraithon.OAuth

  require Logger

  @max_items 3
  @gmail_sample_limit 8
  @gmail_sent_limit 6
  @calendar_sample_limit 10
  @slack_sample_limit 12
  @slack_workspace_limit 2

  @type preview_item :: %{
          title: String.t(),
          summary: String.t(),
          rationale: String.t(),
          recommended_action: String.t(),
          source: String.t(),
          account_label: String.t(),
          suggested_behavior: String.t(),
          confidence: float()
        }

  @type preview :: %{
          items: [preview_item()],
          sources: [String.t()],
          generated_at: DateTime.t()
        }

  @doc """
  Returns up to three onboarding preview cards for the given user.
  """
  @spec preview(String.t(), keyword()) :: {:ok, preview()} | {:error, term()}
  def preview(user_id, opts \\ []) when is_binary(user_id) do
    sources = Keyword.get_lazy(opts, :sources, fn -> fetch_sources(user_id, opts) end)

    case Enum.reject(sources, &(source_items(&1) == [])) do
      [] ->
        {:ok, %{items: [], sources: [], generated_at: DateTime.utc_now()}}

      active_sources ->
        with {:ok, items} <- generate_preview_items(active_sources, opts) do
          {:ok,
           %{
             items: items |> Enum.take(@max_items),
             sources: Enum.map(active_sources, &source_label/1),
             generated_at: DateTime.utc_now()
           }}
        end
    end
  end

  @doc """
  Returns true when the user has at least one proof-capable connection.
  """
  @spec eligible?(String.t()) :: boolean()
  def eligible?(user_id) when is_binary(user_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.any?(fn token ->
      google_provider?(token.provider) or slack_provider?(token.provider)
    end)
  end

  def eligible?(_), do: false

  defp fetch_sources(user_id, opts) do
    tasks =
      [
        {:gmail, fn -> fetch_gmail_source(user_id, opts) end},
        {:calendar, fn -> fetch_calendar_source(user_id, opts) end}
      ] ++ slack_source_tasks(user_id, opts)

    tasks
    |> Task.async_stream(fn {_key, fetcher} -> fetcher.() end,
      max_concurrency: 4,
      timeout: 8_000,
      ordered: false
    )
    |> Enum.reduce([], fn
      {:ok, {:ok, nil}}, acc ->
        acc

      {:ok, {:ok, source}}, acc ->
        [source | acc]

      {:ok, {:error, reason}}, acc ->
        Logger.warning("Onboarding proof source fetch failed", reason: inspect(reason))
        acc

      {:exit, reason}, acc ->
        Logger.warning("Onboarding proof source fetch exited", reason: inspect(reason))
        acc
    end)
    |> Enum.reverse()
  end

  defp fetch_gmail_source(user_id, opts) do
    gmail_fetcher = Keyword.get(opts, :gmail_fetcher, &default_gmail_fetcher/1)
    gmail_token = latest_google_token(user_id)

    if is_nil(gmail_token) do
      {:ok, nil}
    else
      account_label = google_account_label(gmail_token, user_id)

      with {:ok, %{inbox: inbox, sent: sent}} <- gmail_fetcher.(user_id) do
        {:ok,
         %{
           "source" => "gmail",
           "label" => "Gmail",
           "account_label" => account_label,
           "items" => %{
             "inbox" => Enum.take(inbox, @gmail_sample_limit),
             "sent" => Enum.take(sent, @gmail_sent_limit)
           }
         }}
      end
    end
  end

  defp fetch_calendar_source(user_id, opts) do
    calendar_fetcher = Keyword.get(opts, :calendar_fetcher, &default_calendar_fetcher/1)
    google_token = latest_google_token(user_id)

    if is_nil(google_token) do
      {:ok, nil}
    else
      account_label = google_account_label(google_token, user_id)

      with {:ok, events} <- calendar_fetcher.(user_id) do
        {:ok,
         %{
           "source" => "calendar",
           "label" => "Calendar",
           "account_label" => account_label,
           "items" => Enum.take(events, @calendar_sample_limit)
         }}
      end
    end
  end

  defp slack_source_tasks(user_id, opts) do
    opts
    |> slack_workspace_tokens(user_id)
    |> Enum.map(fn token ->
      {:slack, fn -> fetch_slack_source(user_id, token, opts) end}
    end)
  end

  defp fetch_slack_source(user_id, token, opts) do
    slack_fetcher = Keyword.get(opts, :slack_fetcher, &default_slack_fetcher/2)
    team_label = slack_team_label(token)

    with {:ok, messages} <- slack_fetcher.(user_id, token) do
      {:ok,
       %{
         "source" => "slack",
         "label" => "Slack",
         "account_label" => team_label,
         "items" => Enum.take(messages, @slack_sample_limit)
       }}
    end
  end

  defp default_gmail_fetcher(user_id) do
    newer_than = "newer_than:7d"

    with {:ok, inbox} <-
           Gmail.fetch_messages(user_id, max_results: @gmail_sample_limit, query: newer_than),
         {:ok, sent} <-
           Gmail.fetch_messages(user_id,
             max_results: @gmail_sent_limit,
             label_ids: ["SENT"],
             query: newer_than
           ) do
      {:ok,
       %{
         inbox: Enum.map(inbox, &compact_gmail_message/1),
         sent: Enum.map(sent, &compact_gmail_message/1)
       }}
    end
  end

  defp default_calendar_fetcher(user_id) do
    with {:ok, events} <- GoogleCalendar.sync_calendar_events(user_id) do
      events =
        events
        |> Enum.filter(&recent_or_upcoming_event?/1)
        |> Enum.map(&compact_calendar_event/1)

      {:ok, events}
    end
  end

  defp default_slack_fetcher(user_id, token) do
    provider = token.provider

    since =
      Date.utc_today()
      |> Date.add(-7)
      |> Date.to_iso8601()

    with {:ok, access_token} <- OAuth.get_valid_access_token(user_id, provider),
         {:ok, response} <-
           Slack.search_messages(access_token, "after:#{since}",
             count: @slack_sample_limit,
             sort: "timestamp",
             sort_dir: "desc"
           ) do
      messages =
        response
        |> get_in(["messages", "matches"])
        |> List.wrap()
        |> Enum.map(&compact_slack_match/1)
        |> Enum.reject(&blank_map?/1)

      {:ok, messages}
    end
  end

  defp generate_preview_items(sources, opts) do
    llm_complete = Keyword.get(opts, :llm_complete, &default_llm_complete/1)

    with {:ok, response} <- llm_complete.(build_prompt(sources)),
         {:ok, items} <- decode_items(response) do
      normalized =
        items
        |> Enum.map(&normalize_item/1)
        |> Enum.reject(&is_nil/1)

      {:ok, normalized}
    else
      {:error, reason} ->
        Logger.warning("Onboarding proof generation failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp default_llm_complete(prompt) when is_binary(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 1_400,
      "temperature" => 0.1,
      "reasoning_effort" => "medium"
    }

    with {:ok, response} <- LLM.provider().complete(params) do
      {:ok, response.content}
    end
  end

  defp build_prompt(sources) do
    """
    You are generating a product onboarding preview for Maraithon.

    Goal:
    Using ONLY the recent connected activity below, return up to 3 examples of
    things Maraithon would have caught this week. These should feel immediately
    valuable to a founder or operator after connecting Gmail, Calendar, and Slack.

    Prioritize:
    - reply debt and unresolved follow-up in Gmail
    - explicit promises or likely missed commitments
    - important meetings that likely create next steps, owners, or recap work
    - Slack messages that imply open loops in channels or DMs

    Exclude:
    - receipts, invoices, payment confirmations, automated notifications
    - newsletters, marketing, and low-signal chatter
    - generic calendar holds without obvious follow-up consequence

    Rules:
    - Never invent facts not present in the data.
    - If the data is suggestive but not conclusive, say Maraithon "would have watched"
      or "would have checked whether" instead of overstating certainty.
    - Prefer concrete counterparties, artifacts, owners, or follow-up obligations.
    - Suggested behavior must be one of:
      founder_followthrough_agent, inbox_calendar_advisor, slack_followthrough_agent

    Return ONLY valid JSON array. Each item must include:
    title, summary, rationale, recommended_action, source, account_label, suggested_behavior, confidence

    Connected activity JSON:
    #{Jason.encode!(sources)}
    """
  end

  defp decode_items(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, items} when is_list(items) -> {:ok, items}
      _ -> {:error, :invalid_json}
    end
  end

  defp normalize_item(item) when is_map(item) do
    title = read_string(item, "title", nil)
    summary = read_string(item, "summary", nil)
    rationale = read_string(item, "rationale", nil)
    recommended_action = read_string(item, "recommended_action", nil)
    source = normalize_source(read_string(item, "source", nil))
    account_label = read_string(item, "account_label", nil)
    suggested_behavior = normalize_behavior(read_string(item, "suggested_behavior", nil))
    confidence = clamp_float(read_float(item, "confidence", 0.78), 0.0, 1.0)

    if Enum.all?(
         [
           title,
           summary,
           rationale,
           recommended_action,
           source,
           account_label,
           suggested_behavior
         ],
         &present?/1
       ) do
      %{
        title: title,
        summary: summary,
        rationale: rationale,
        recommended_action: recommended_action,
        source: source,
        account_label: account_label,
        suggested_behavior: suggested_behavior,
        confidence: confidence
      }
    end
  end

  defp normalize_item(_), do: nil

  defp normalize_source("google_calendar"), do: "calendar"
  defp normalize_source("gmail"), do: "gmail"
  defp normalize_source("calendar"), do: "calendar"
  defp normalize_source("slack"), do: "slack"
  defp normalize_source(_), do: nil

  defp normalize_behavior("founder_followthrough_agent"), do: "founder_followthrough_agent"
  defp normalize_behavior("inbox_calendar_advisor"), do: "inbox_calendar_advisor"
  defp normalize_behavior("slack_followthrough_agent"), do: "slack_followthrough_agent"
  defp normalize_behavior(_), do: nil

  defp compact_gmail_message(message) when is_map(message) do
    compact_map(%{
      "subject" => read_string(message, "subject"),
      "snippet" => read_string(message, "snippet"),
      "from" => read_string(message, "from"),
      "to" => read_string(message, "to"),
      "labels" => read_list(message, "labels"),
      "date" =>
        to_iso8601(read_datetime(message, "internal_date") || read_datetime(message, "date")),
      "thread_id" => read_string(message, "thread_id"),
      "message_id" => read_string(message, "message_id")
    })
  end

  defp compact_calendar_event(event) when is_map(event) do
    compact_map(%{
      "summary" => read_string(event, "summary"),
      "description" => read_string(event, "description"),
      "organizer" => read_string(event, "organizer"),
      "attendee_count" => event |> read_list("attendees") |> length(),
      "start" => to_iso8601(read_datetime(event, "start")),
      "end" => to_iso8601(read_datetime(event, "end")),
      "status" => read_string(event, "status"),
      "html_link" => read_string(event, "html_link")
    })
  end

  defp compact_slack_match(match) when is_map(match) do
    compact_map(%{
      "text" => read_string(match, "text"),
      "user" => read_string(match, "username"),
      "channel" =>
        read_string(
          read_map(match, "channel"),
          "name",
          read_string(read_map(match, "channel"), "id")
        ),
      "permalink" => read_string(match, "permalink"),
      "ts" => read_string(match, "ts")
    })
  end

  defp recent_or_upcoming_event?(event) when is_map(event) do
    case read_datetime(event, "start") || read_datetime(event, "end") do
      %DateTime{} = datetime ->
        cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
        DateTime.compare(datetime, cutoff) in [:eq, :gt]

      _ ->
        false
    end
  end

  defp slack_workspace_tokens(opts, user_id) do
    tokens =
      user_id
      |> OAuth.list_user_tokens()
      |> Enum.filter(&slack_user_provider?(&1.provider))
      |> Enum.sort_by(&datetime_sort_key(&1.updated_at), :desc)
      |> Enum.take(@slack_workspace_limit)

    Keyword.get(opts, :slack_tokens, tokens)
  end

  defp latest_google_token(user_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.filter(&google_provider?(&1.provider))
    |> Enum.sort_by(&datetime_sort_key(&1.updated_at), :desc)
    |> List.first()
  end

  defp google_account_label(nil, fallback), do: fallback

  defp google_account_label(token, fallback) do
    metadata = token.metadata || %{}

    read_string(metadata, "account_email", nil) ||
      google_provider_account(token.provider) ||
      fallback
  end

  defp slack_team_label(token) do
    metadata = token.metadata || %{}
    read_string(metadata, "team_name", nil) || read_string(metadata, "team_id", "Slack")
  end

  defp google_provider_account("google:" <> account), do: account
  defp google_provider_account(_), do: nil

  defp google_provider?(provider) when is_binary(provider),
    do: provider == "google" or String.starts_with?(provider, "google:")

  defp google_provider?(_), do: false

  defp slack_provider?(provider) when is_binary(provider),
    do: String.starts_with?(provider, "slack:")

  defp slack_provider?(_), do: false

  defp slack_user_provider?(provider) when is_binary(provider),
    do: Regex.match?(~r/^slack:[^:]+:user:[^:]+$/, provider)

  defp slack_user_provider?(_), do: false

  defp source_items(%{"items" => items}) when is_list(items), do: items
  defp source_items(%{"items" => %{} = items}), do: Map.values(items) |> List.flatten()
  defp source_items(_), do: []

  defp source_label(%{"label" => label, "account_label" => account}) when is_binary(account),
    do: "#{label} · #{account}"

  defp source_label(%{"label" => label}), do: label

  defp blank_map?(map) when is_map(map), do: Enum.all?(map, fn {_key, value} -> blank?(value) end)
  defp blank_map?(_), do: true

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, value}, acc when value in [nil, "", []] ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp read_string(map, key, default \\ "") when is_map(map) do
    case fetch_attr(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      value when is_atom(value) ->
        Atom.to_string(value)

      _ ->
        default
    end
  end

  defp read_list(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp read_map(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_float(map, key, default) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_datetime(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_attr(map, key) when is_map(map) and is_binary(key) do
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

  defp to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp to_iso8601(_), do: nil

  defp clamp_float(value, min, _max) when value < min, do: min
  defp clamp_float(value, _min, max) when value > max, do: max
  defp clamp_float(value, _min, _max), do: value

  defp present?(value), do: not blank?(value)
  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_list(value), do: value == []
  defp blank?(_), do: false

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_), do: 0
end
