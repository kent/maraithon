defmodule Maraithon.Travel do
  @moduledoc """
  Travel itinerary persistence, extraction orchestration, and brief queueing.
  """

  import Ecto.Query

  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Gmail
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Repo
  alias Maraithon.Tools.GoogleCalendarHelpers
  alias Maraithon.Travel.{BriefRenderer, Extractor, Itinerary, Reconciler}

  @default_email_scan_limit 25
  @default_event_scan_limit 25
  @default_lookback_hours 24 * 30
  @default_min_confidence 0.8

  def sync_recent_trip_data(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event = Keyword.get(opts, :event)
    email_scan_limit = Keyword.get(opts, :email_scan_limit, @default_email_scan_limit)
    event_scan_limit = Keyword.get(opts, :event_scan_limit, @default_event_scan_limit)
    lookback_hours = Keyword.get(opts, :lookback_hours, @default_lookback_hours)
    timezone_offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
    min_confidence = Keyword.get(opts, :min_confidence, @default_min_confidence)

    with :ok <- ensure_runtime_prereqs(user_id),
         {:ok, messages} <- candidate_messages(user_id, email_scan_limit, lookback_hours, event),
         {:ok, events} <- calendar_events(user_id, event_scan_limit, lookback_hours, now, event),
         itineraries <-
           Reconciler.ingest(
             user_id,
             agent_id,
             Enum.flat_map(
               messages,
               &Extractor.extract_items(&1, timezone_offset_hours: timezone_offset_hours)
             ),
             events,
             now: now,
             timezone_offset_hours: timezone_offset_hours,
             min_confidence: min_confidence
           ) do
      queued =
        queue_due_briefs(user_id, agent_id, now,
          timezone_offset_hours: timezone_offset_hours,
          min_confidence: min_confidence
        )

      {:ok,
       %{
         scanned_messages: length(messages),
         itineraries: itineraries,
         queued_briefs: queued
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def note_brief_delivered(%Brief{} = brief) do
    case travel_delivery_ref(brief) do
      %{itinerary_id: itinerary_id, digest_hash: digest_hash} ->
        case get_itinerary_for_user(brief.user_id, itinerary_id) do
          %Itinerary{} = itinerary ->
            timezone_offset_hours =
              get_in(itinerary.metadata || %{}, ["timezone_offset_hours"]) || 0

            next_status =
              case {brief.cadence, active_items?(itinerary.items)} do
                {"travel_update", false} -> "cancelled"
                _ -> "brief_sent"
              end

            metadata =
              itinerary.metadata
              |> Kernel.||(%{})
              |> Map.put("last_sent_hash", digest_hash)
              |> Map.put("pending_update", false)

            itinerary
            |> Itinerary.changeset(%{
              status: next_status,
              briefed_for_local_date: local_trip_date(itinerary, timezone_offset_hours),
              metadata: metadata
            })
            |> Repo.update()

          _ ->
            :ok
        end

      nil ->
        :ok
    end
  end

  def list_recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 10)

    Itinerary
    |> where([itinerary], itinerary.user_id == ^user_id)
    |> order_by([itinerary], desc: itinerary.starts_at, desc: itinerary.updated_at)
    |> preload(:items)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_itinerary!(id) when is_binary(id) do
    Itinerary
    |> Repo.get!(id)
    |> Repo.preload(:items)
  end

  def get_itinerary_for_user(user_id, itinerary_id)
      when is_binary(user_id) and is_binary(itinerary_id) do
    Itinerary
    |> where([itinerary], itinerary.id == ^itinerary_id and itinerary.user_id == ^user_id)
    |> preload(:items)
    |> Repo.one()
  end

  def serialize_for_prompt(%Itinerary{} = itinerary) do
    itinerary = Repo.preload(itinerary, :items)

    %{
      id: itinerary.id,
      status: itinerary.status,
      title: itinerary.title,
      destination_label: itinerary.destination_label,
      starts_at: itinerary.starts_at,
      ends_at: itinerary.ends_at,
      confidence: itinerary.confidence,
      metadata:
        Map.take(itinerary.metadata || %{}, [
          "calendar_match",
          "trip_key",
          "timezone_offset_hours"
        ]),
      items:
        Enum.map(itinerary.items, fn item ->
          %{
            item_type: item.item_type,
            status: item.status,
            title: item.title,
            location_label: item.location_label,
            starts_at: item.starts_at,
            ends_at: item.ends_at,
            confirmation_code: item.confirmation_code,
            metadata:
              Map.take(item.metadata || %{}, [
                "display_date",
                "display_check_in",
                "display_check_out",
                "address",
                "room",
                "hotel_phone",
                "destination_label"
              ])
          }
        end)
    }
  end

  defp candidate_messages(user_id, email_scan_limit, lookback_hours, event) do
    with {:ok, messages} <- message_candidates(user_id, email_scan_limit, lookback_hours, event) do
      full_messages =
        messages
        |> Enum.filter(&Extractor.candidate?/1)
        |> Enum.take(email_scan_limit)
        |> Enum.map(&hydrate_message(user_id, &1))
        |> Enum.reject(&is_nil/1)

      {:ok, full_messages}
    end
  end

  defp calendar_events(user_id, event_scan_limit, lookback_hours, now, event) do
    case calendar_events_from_event(event, event_scan_limit) do
      {:ok, events} ->
        {:ok, events}

      :fallback ->
        time_min =
          now
          |> DateTime.add(-lookback_hours, :hour)
          |> DateTime.to_iso8601()

        time_max =
          now
          |> DateTime.add(14, :day)
          |> DateTime.to_iso8601()

        case calendar_module().list_events(user_id,
               max_results: event_scan_limit,
               time_min: time_min,
               time_max: time_max
             ) do
          {:ok, events} -> {:ok, events}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp queue_due_briefs(user_id, agent_id, now, opts) do
    timezone_offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)

    list_recent_for_user(user_id, limit: 20)
    |> Enum.map(&queue_due_brief(&1, agent_id, timezone_offset_hours, now))
    |> Enum.reject(&is_nil/1)
  end

  defp queue_due_brief(itinerary, agent_id, timezone_offset_hours, now) do
    itinerary = Repo.preload(itinerary, :items)

    cond do
      due_for_initial_brief?(itinerary, now, timezone_offset_hours) ->
        queue_initial_brief(itinerary, agent_id, timezone_offset_hours, now)

      itinerary.status == "changed_after_send" ->
        queue_update_brief(itinerary, agent_id, timezone_offset_hours, now)

      true ->
        nil
    end
  end

  defp queue_initial_brief(itinerary, agent_id, timezone_offset_hours, now) do
    rendered =
      BriefRenderer.render(itinerary, :travel_prep,
        timezone_offset_hours: timezone_offset_hours,
        reference_now: now
      )

    dedupe_key = initial_dedupe_key(itinerary, timezone_offset_hours)

    case Repo.get_by(Brief, user_id: itinerary.user_id, dedupe_key: dedupe_key) do
      nil ->
        record_travel_brief(itinerary, agent_id, "travel_prep", rendered, dedupe_key, now)

      %Brief{status: status} = brief when status in ["pending", "failed"] ->
        maybe_refresh_brief(
          brief,
          itinerary,
          agent_id,
          "travel_prep",
          rendered,
          dedupe_key,
          now
        )

      _ ->
        nil
    end
  end

  defp queue_update_brief(itinerary, agent_id, timezone_offset_hours, now) do
    rendered =
      BriefRenderer.render(itinerary, :travel_update,
        timezone_offset_hours: timezone_offset_hours,
        reference_now: now
      )

    initial_key = initial_dedupe_key(itinerary, timezone_offset_hours)

    case Repo.get_by(Brief, user_id: itinerary.user_id, dedupe_key: initial_key) do
      %Brief{status: status} = brief when status in ["pending", "failed"] ->
        maybe_refresh_brief(
          brief,
          itinerary,
          agent_id,
          "travel_prep",
          rendered,
          initial_key,
          now
        )

      _ ->
        update_key = "travel_update:#{itinerary.id}:#{rendered.digest_hash}"

        case Repo.get_by(Brief, user_id: itinerary.user_id, dedupe_key: update_key) do
          nil ->
            record_travel_brief(
              itinerary,
              agent_id,
              "travel_update",
              rendered,
              update_key,
              now
            )

          %Brief{} ->
            nil
        end
    end
  end

  defp due_for_initial_brief?(itinerary, now, timezone_offset_hours) do
    itinerary.status == "ready" and
      match?(%DateTime{}, itinerary.starts_at) and
      DateTime.compare(now, planned_brief_at(itinerary.starts_at, timezone_offset_hours)) != :lt and
      DateTime.compare(itinerary.starts_at, now) == :gt
  end

  def planned_brief_at(%DateTime{} = starts_at, timezone_offset_hours) do
    local_start = DateTime.add(starts_at, timezone_offset_hours * 3600, :second)
    local_date = local_start |> DateTime.to_date() |> Date.add(-1)

    target_hour =
      cond do
        local_start.hour < 8 -> 18
        local_start.hour < 12 -> 17
        local_start.hour < 18 -> 16
        true -> 12
      end

    naive = NaiveDateTime.new!(local_date, Time.new!(target_hour, 0, 0))
    {:ok, local_datetime} = DateTime.from_naive(naive, "Etc/UTC")
    DateTime.add(local_datetime, -timezone_offset_hours * 3600, :second)
  end

  defp local_trip_date(itinerary, timezone_offset_hours) do
    local_date(itinerary.starts_at || DateTime.utc_now(), timezone_offset_hours)
  end

  defp local_date(%DateTime{} = datetime, timezone_offset_hours) do
    datetime
    |> DateTime.add(timezone_offset_hours * 3600, :second)
    |> DateTime.to_date()
  end

  defp active_items?(items) do
    Enum.any?(items, &(&1.status not in ["cancelled", "superseded"]))
  end

  defp record_travel_brief(itinerary, agent_id, cadence, rendered, dedupe_key, now) do
    case Briefs.record(itinerary.user_id, agent_id, %{
           "cadence" => cadence,
           "title" => rendered.title,
           "summary" => rendered.summary,
           "body" => rendered.body,
           "scheduled_for" => now,
           "dedupe_key" => dedupe_key,
           "metadata" => travel_brief_metadata(itinerary, cadence, rendered.digest_hash)
         }) do
      {:ok, %Brief{} = brief} -> brief
      _ -> nil
    end
  end

  defp maybe_refresh_brief(
         %Brief{} = existing,
         itinerary,
         agent_id,
         cadence,
         rendered,
         dedupe_key,
         now
       ) do
    if travel_brief_refresh_needed?(existing, rendered) do
      record_travel_brief(itinerary, agent_id, cadence, rendered, dedupe_key, now)
    else
      nil
    end
  end

  defp travel_brief_refresh_needed?(%Brief{} = existing, rendered) do
    digest_changed? =
      get_in(existing.metadata || %{}, ["travel_digest_hash"]) != rendered.digest_hash

    digest_changed? or existing.title != rendered.title or existing.summary != rendered.summary or
      existing.body != rendered.body
  end

  defp travel_brief_metadata(itinerary, cadence, digest_hash) do
    %{
      "brief_type" => cadence,
      "travel_digest_hash" => digest_hash,
      "travel_itinerary_id" => itinerary.id
    }
  end

  defp initial_dedupe_key(itinerary, timezone_offset_hours) do
    "travel_prep:#{itinerary.id}:#{Date.to_iso8601(local_trip_date(itinerary, timezone_offset_hours))}"
  end

  defp travel_delivery_ref(%Brief{metadata: metadata}) when is_map(metadata) do
    itinerary_id = metadata["travel_itinerary_id"]
    digest_hash = metadata["travel_digest_hash"]

    if is_binary(itinerary_id) and is_binary(digest_hash) do
      %{itinerary_id: itinerary_id, digest_hash: digest_hash}
    end
  end

  defp travel_delivery_ref(_brief), do: nil

  defp ensure_runtime_prereqs(user_id) do
    telegram_ready? =
      case ConnectedAccounts.get(user_id, "telegram") do
        %{status: "connected"} -> true
        _ -> false
      end

    cond do
      not google_service_ready?(user_id, "gmail") -> {:error, :gmail_not_connected}
      not google_service_ready?(user_id, "calendar") -> {:error, :calendar_not_connected}
      not telegram_ready? -> {:error, :telegram_not_connected}
      true -> :ok
    end
  end

  defp google_service_ready?(user_id, service) do
    OAuth.list_user_tokens(user_id)
    |> Enum.filter(&google_provider?(&1.provider))
    |> Enum.any?(&google_token_supports_service?(&1, service))
  end

  defp google_token_supports_service?(token, service) when is_binary(service) do
    required_scopes = Google.scopes_for([service])

    Enum.any?(token.scopes || [], fn scope ->
      google_scope_matches?(scope, service) or scope in required_scopes
    end)
  end

  defp google_scope_matches?(scope, service)
       when is_binary(scope) and service in ["gmail", "calendar"] do
    normalized_scope = String.downcase(scope)
    normalized_service = String.downcase(service)

    normalized_scope == normalized_service or
      String.contains?(normalized_scope, "#{normalized_service}.readonly")
  end

  defp google_scope_matches?(_scope, _service), do: false

  defp message_candidates(user_id, email_scan_limit, lookback_hours, event) do
    case messages_from_event(event, email_scan_limit * 2) do
      {:ok, messages} ->
        {:ok, messages}

      :fallback ->
        query = "newer_than:#{max(div(lookback_hours, 24), 1)}d"

        gmail_module().fetch_messages(user_id,
          max_results: email_scan_limit * 2,
          label_ids: [],
          query: query
        )
    end
  end

  defp hydrate_message(user_id, message) do
    message_id = Map.get(message, :message_id) || Map.get(message, "message_id")

    if is_binary(message_id) do
      case gmail_module().fetch_message_content(user_id, message_id) do
        {:ok, detailed} -> detailed
        {:error, _reason} -> nil
      end
    end
  end

  defp messages_from_event(%{topic: "email:" <> _, payload: payload}, limit) do
    case Map.get(event_data(payload), "messages", []) do
      messages when is_list(messages) and messages != [] -> {:ok, Enum.take(messages, limit)}
      _ -> :fallback
    end
  end

  defp messages_from_event(_event, _limit), do: :fallback

  defp calendar_events_from_event(%{topic: "calendar:" <> _, payload: payload}, limit) do
    case Map.get(event_data(payload), "events", []) do
      events when is_list(events) -> {:ok, Enum.take(events, limit)}
      _ -> :fallback
    end
  end

  defp calendar_events_from_event(_event, _limit), do: :fallback

  defp event_data(payload) when is_map(payload) do
    payload
    |> Map.get(:data, Map.get(payload, "data", %{}))
    |> normalize_event_map()
  end

  defp event_data(_payload), do: %{}

  defp normalize_event_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_event_map(_value), do: %{}

  defp google_provider?(provider) when is_binary(provider) do
    provider == "google" or String.starts_with?(provider, "google:")
  end

  defp google_provider?(_provider), do: false

  defp gmail_module do
    Application.get_env(:maraithon, :travel, [])
    |> Keyword.get(:gmail_module, Gmail)
  end

  defp calendar_module do
    Application.get_env(:maraithon, :travel, [])
    |> Keyword.get(:calendar_module, GoogleCalendarHelpers)
  end
end
