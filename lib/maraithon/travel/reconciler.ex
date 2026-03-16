defmodule Maraithon.Travel.Reconciler do
  @moduledoc false

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Travel
  alias Maraithon.Travel.{BriefRenderer, Itinerary, ItineraryItem}

  def ingest(user_id, agent_id, items, calendar_events, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_list(items) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
    min_confidence = Keyword.get(opts, :min_confidence, 0.8)

    items
    |> Enum.reduce(%{itinerary_ids: [], trip_keys: %{}}, fn item, acc ->
      trip_key = get_in(item, ["metadata", "trip_key"])

      itinerary =
        Map.get(acc.trip_keys, trip_key) ||
          find_by_fingerprint(user_id, item["fingerprint"]) ||
          find_by_trip_key(user_id, get_in(item, ["metadata", "trip_key"]), now) ||
          create_itinerary!(user_id, agent_id, offset_hours)

      upsert_item!(itinerary, item)

      %{
        itinerary_ids: [itinerary.id | acc.itinerary_ids],
        trip_keys: maybe_put_trip_key(acc.trip_keys, trip_key, itinerary)
      }
    end)
    |> Map.fetch!(:itinerary_ids)
    |> Enum.uniq()
    |> Enum.map(fn itinerary_id ->
      itinerary_id
      |> Travel.get_itinerary!()
      |> recompute_itinerary!(calendar_events, offset_hours, min_confidence, now)
    end)
  end

  def recompute_itinerary!(
        %Itinerary{} = itinerary,
        calendar_events,
        offset_hours,
        min_confidence,
        now
      ) do
    itinerary = Repo.preload(itinerary, :items)
    items = sort_items(itinerary.items)
    active_items = Enum.reject(items, &(&1.status in ["cancelled", "superseded"]))
    display_items = if active_items == [], do: items, else: active_items

    starts_at =
      Enum.min_by(display_items, &datetime_sort_key(&1.starts_at), fn -> nil end)
      |> maybe_datetime(:starts_at)

    ends_at =
      Enum.max_by(display_items, &datetime_sort_key(&1.ends_at || &1.starts_at), fn -> nil end)
      |> maybe_datetime(:ends_at)

    destination = destination_label(display_items)
    trip_key = item_trip_key(display_items)
    calendar_match? = calendar_match?(display_items, calendar_events)
    confidence = itinerary_confidence(active_items, calendar_match?)

    render =
      BriefRenderer.render(%{itinerary | items: display_items}, :travel_prep,
        timezone_offset_hours: offset_hours
      )

    current_hash = render.digest_hash
    last_sent_hash = get_in(itinerary.metadata || %{}, ["last_sent_hash"])
    future_trip? = is_nil(starts_at) or DateTime.compare(starts_at, now) == :gt

    status =
      cond do
        active_items == [] and is_binary(last_sent_hash) and future_trip? ->
          "changed_after_send"

        active_items == [] ->
          "cancelled"

        is_binary(last_sent_hash) and last_sent_hash != current_hash and future_trip? ->
          "changed_after_send"

        is_binary(last_sent_hash) ->
          "brief_sent"

        confidence >= min_confidence and not is_nil(starts_at) ->
          "ready"

        true ->
          "collecting"
      end

    metadata =
      itinerary.metadata
      |> Kernel.||(%{})
      |> Map.put("trip_key", trip_key)
      |> Map.put("calendar_match", calendar_match?)
      |> Map.put("current_hash", current_hash)
      |> Map.put("timezone_offset_hours", offset_hours)
      |> Map.put("pending_update", status == "changed_after_send")
      |> maybe_put("destination_label", destination)

    itinerary
    |> Itinerary.changeset(%{
      status: status,
      title: itinerary_title(display_items, destination),
      destination_label: destination,
      planning_timezone: timezone_label(offset_hours),
      starts_at: starts_at,
      ends_at: ends_at,
      confidence: confidence,
      last_evidence_at: latest_evidence_at(items),
      metadata: metadata
    })
    |> Repo.update!()
    |> Repo.preload(:items)
  end

  defp create_itinerary!(user_id, agent_id, offset_hours) do
    %Itinerary{}
    |> Itinerary.changeset(%{
      user_id: user_id,
      agent_id: agent_id,
      status: "collecting",
      planning_timezone: timezone_label(offset_hours),
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp upsert_item!(%Itinerary{} = itinerary, attrs) do
    itinerary = Repo.preload(itinerary, :items)

    case Enum.find(itinerary.items, &(&1.fingerprint == attrs["fingerprint"])) do
      nil ->
        %ItineraryItem{}
        |> ItineraryItem.changeset(Map.put(attrs, "travel_itinerary_id", itinerary.id))
        |> Repo.insert!()

      %ItineraryItem{} = existing ->
        existing
        |> ItineraryItem.changeset(Map.put(attrs, "travel_itinerary_id", itinerary.id))
        |> Repo.update!()
    end
  end

  defp find_by_fingerprint(user_id, fingerprint) when is_binary(fingerprint) do
    Itinerary
    |> join(:inner, [itinerary], item in assoc(itinerary, :items))
    |> where(
      [itinerary, item],
      itinerary.user_id == ^user_id and item.fingerprint == ^fingerprint
    )
    |> order_by([itinerary, _item], desc: itinerary.updated_at)
    |> preload(:items)
    |> limit(1)
    |> Repo.one()
  end

  defp find_by_fingerprint(_user_id, _fingerprint), do: nil

  defp find_by_trip_key(_user_id, nil, _now), do: nil

  defp find_by_trip_key(user_id, trip_key, now) do
    threshold = DateTime.add(now, -90, :day)

    Itinerary
    |> where([itinerary], itinerary.user_id == ^user_id)
    |> where([itinerary], is_nil(itinerary.starts_at) or itinerary.starts_at >= ^threshold)
    |> preload(:items)
    |> Repo.all()
    |> Enum.find(fn itinerary ->
      get_in(itinerary.metadata || %{}, ["trip_key"]) == trip_key
    end)
  end

  defp destination_label(items) do
    Enum.find_value(items, fn item ->
      get_in(item.metadata || %{}, ["destination_label"]) || item.location_label
    end)
  end

  defp itinerary_title(items, destination) do
    case Enum.find(items, &(&1.item_type == "flight" and &1.status != "cancelled")) do
      %ItineraryItem{} = flight ->
        blank_fallback(flight.location_label, destination_fallback(destination))

      _ ->
        destination_fallback(destination)
    end
  end

  defp item_trip_key(items) do
    Enum.find_value(items, fn item ->
      get_in(item.metadata || %{}, ["trip_key"])
    end)
  end

  defp itinerary_confidence(items, calendar_match?) do
    base =
      items
      |> Enum.map(&(&1.confidence || 0.0))
      |> Enum.max(fn -> 0.0 end)

    coverage_bonus =
      case {Enum.any?(items, &(&1.item_type == "flight")),
            Enum.any?(items, &(&1.item_type == "hotel"))} do
        {true, true} -> 0.06
        _ -> 0.0
      end

    calendar_bonus = if calendar_match?, do: 0.05, else: 0.0

    (base + coverage_bonus + calendar_bonus)
    |> min(0.99)
  end

  defp calendar_match?(items, events) when is_list(events) do
    destination_terms =
      items
      |> Enum.map(fn item ->
        [item.location_label, get_in(item.metadata || %{}, ["destination_label"])]
      end)
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)

    Enum.any?(events, fn event ->
      haystack =
        [event.summary, event.location, event.description]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.join(" ")

      Enum.any?(destination_terms, fn term ->
        term != "" and String.contains?(haystack, term)
      end)
    end)
  end

  defp calendar_match?(_items, _events), do: false

  defp sort_items(items) do
    Enum.sort_by(items, fn item ->
      type_rank =
        case item.item_type do
          "flight" -> 0
          "hotel" -> 1
          _ -> 2
        end

      {type_rank, datetime_sort_key(item.starts_at)}
    end)
  end

  defp latest_evidence_at(items) do
    items
    |> Enum.map(fn item ->
      get_in(item.metadata || %{}, ["evidence_at"]) || item.updated_at || item.inserted_at
    end)
    |> Enum.max_by(&datetime_sort_key/1, fn -> nil end)
  end

  defp datetime_sort_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp datetime_sort_key(_value), do: 0

  defp maybe_datetime(nil, _field), do: nil
  defp maybe_datetime(item, field), do: Map.get(item, field)

  defp timezone_label(offset_hours) when is_integer(offset_hours) and offset_hours >= 0,
    do: "UTC+#{offset_hours}"

  defp timezone_label(offset_hours) when is_integer(offset_hours), do: "UTC#{offset_hours}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_trip_key(map, key, %Itinerary{} = itinerary) when is_binary(key) and key != "",
    do: Map.put(map, key, itinerary)

  defp maybe_put_trip_key(map, _key, _itinerary), do: map

  defp destination_fallback(destination) when is_binary(destination) and destination != "",
    do: "Travel to #{destination}"

  defp destination_fallback(_destination), do: "Upcoming travel"

  defp blank_fallback(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp blank_fallback(_value, fallback), do: fallback
end
