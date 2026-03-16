defmodule Maraithon.Travel.BriefRenderer do
  @moduledoc """
  Renders Telegram-ready travel prep and update briefs.
  """

  def render(itinerary, mode, opts \\ []) when is_map(itinerary) do
    offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
    reference_now = Keyword.get(opts, :reference_now)
    items = sort_items(Map.get(itinerary, :items) || Map.get(itinerary, "items") || [])
    active_items = Enum.reject(items, &(&1.status == "superseded"))
    trip_date = local_trip_date(itinerary, offset_hours)
    prep_day_label = prep_day_label(itinerary, offset_hours, reference_now)

    title_prefix =
      if mode == :travel_update, do: "Travel update", else: "Travel #{prep_day_label}"

    destination = itinerary.destination_label || "your trip"

    intro =
      case {mode, cancelled_trip?(active_items)} do
        {:travel_update, true} ->
          "I detected a change in your travel details. One or more reservations now look cancelled. Here is the latest state I found:"

        {:travel_update, false} ->
          "I detected a change in your travel details. Here is the latest itinerary I found:"

        _ ->
          "Here are your travel details for #{prep_day_label} (#{trip_date}):"
      end

    sections =
      [
        render_flight_section(active_items),
        render_hotel_section(active_items)
      ]
      |> Enum.reject(&is_nil/1)

    body =
      ([intro] ++ sections)
      |> Enum.join("\n\n")
      |> String.trim()

    snapshot = digest_snapshot(itinerary, active_items, trip_date, destination)

    %{
      title: "#{title_prefix}: #{destination}",
      summary: summary_line(active_items, destination, mode),
      body: body,
      digest_hash: digest_hash(snapshot),
      local_trip_date: trip_date
    }
  end

  def digest_hash(snapshot) when is_map(snapshot) do
    snapshot
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp render_flight_section(items) do
    flights =
      items
      |> Enum.filter(&(&1.item_type == "flight"))
      |> Enum.reject(&(&1.status == "cancelled"))

    case flights do
      [] ->
        nil

      flights ->
        lines =
          flights
          |> Enum.flat_map(fn flight ->
            [
              "FLIGHT",
              flight.title || flight.vendor_name || "Flight",
              flight.location_label,
              get_in(flight.metadata || %{}, ["display_date"]),
              confirmation_line(flight.confirmation_code, "Booking Ref")
            ]
            |> Enum.reject(&blank?/1)
          end)

        Enum.join(lines, "\n")
    end
  end

  defp render_hotel_section(items) do
    hotels =
      items
      |> Enum.filter(&(&1.item_type == "hotel"))
      |> Enum.reject(&(&1.status == "cancelled"))

    case hotels do
      [] ->
        nil

      hotels ->
        lines =
          hotels
          |> Enum.flat_map(fn hotel ->
            metadata = hotel.metadata || %{}

            [
              "HOTEL",
              hotel.title || hotel.vendor_name || "Hotel",
              metadata["address"],
              prefixed_line("Check-in", metadata["display_check_in"]),
              prefixed_line("Check-out", metadata["display_check_out"]),
              prefixed_line("Room", metadata["room"]),
              confirmation_line(hotel.confirmation_code, "Itinerary #"),
              prefixed_line("Hotel Phone", metadata["hotel_phone"])
            ]
            |> Enum.reject(&blank?/1)
          end)

        Enum.join(lines, "\n")
    end
  end

  defp local_trip_date(itinerary, offset_hours) do
    itinerary.starts_at
    |> Kernel.||(DateTime.utc_now())
    |> DateTime.add(offset_hours * 3600, :second)
    |> Calendar.strftime("%b %-d")
  end

  defp prep_day_label(itinerary, offset_hours, %DateTime{} = reference_now) do
    if trip_local_date(itinerary, offset_hours) == local_date(reference_now, offset_hours) do
      "today"
    else
      "tomorrow"
    end
  end

  defp prep_day_label(_itinerary, _offset_hours, _reference_now), do: "tomorrow"

  defp summary_line(items, destination, mode) do
    has_flight? = Enum.any?(items, &(&1.item_type == "flight" and &1.status != "cancelled"))
    has_hotel? = Enum.any?(items, &(&1.item_type == "hotel" and &1.status != "cancelled"))

    prefix =
      case mode do
        :travel_update -> "Updated"
        _ -> "Ready"
      end

    cond do
      has_flight? and has_hotel? ->
        "#{prefix} flight and hotel details for #{destination}."

      has_flight? ->
        "#{prefix} flight details for #{destination}."

      has_hotel? ->
        "#{prefix} hotel details for #{destination}."

      true ->
        "#{prefix} travel details for #{destination}."
    end
  end

  defp digest_snapshot(itinerary, items, trip_date, destination) do
    %{
      trip_date: trip_date,
      destination: destination,
      title: itinerary.title,
      status: itinerary.status,
      items:
        Enum.map(items, fn item ->
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
                "hotel_phone"
              ])
          }
        end)
    }
  end

  defp sort_items(items) do
    Enum.sort_by(items, fn item ->
      type_rank =
        case item.item_type do
          "flight" -> 0
          "hotel" -> 1
          _ -> 2
        end

      {type_rank, item.starts_at || item.inserted_at}
    end)
  end

  defp cancelled_trip?(items) do
    items != [] and Enum.all?(items, &(&1.status == "cancelled"))
  end

  defp trip_local_date(itinerary, offset_hours) do
    itinerary.starts_at
    |> Kernel.||(DateTime.utc_now())
    |> local_date(offset_hours)
  end

  defp local_date(%DateTime{} = datetime, offset_hours) do
    datetime
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_date()
  end

  defp confirmation_line(nil, _label), do: nil
  defp confirmation_line("", _label), do: nil
  defp confirmation_line(value, label), do: "#{label}: #{value}"

  defp prefixed_line(_label, nil), do: nil
  defp prefixed_line(_label, ""), do: nil

  defp prefixed_line(label, value) do
    if String.starts_with?(String.downcase(value), String.downcase("#{label}:")) do
      value
    else
      "#{label}: #{value}"
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false
end
