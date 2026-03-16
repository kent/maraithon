defmodule Maraithon.Travel.Extractor do
  @moduledoc """
  Deterministic travel email extraction for flights and hotels.
  """

  @flight_terms [
    "flight",
    "boarding",
    "airline",
    "record locator",
    "booking ref",
    "departure",
    "arrival",
    "gate"
  ]

  @hotel_terms [
    "hotel",
    "reservation",
    "check-in",
    "check in",
    "check-out",
    "check out",
    "room",
    "itinerary"
  ]

  @travel_terms Enum.uniq(@flight_terms ++ @hotel_terms ++ ["trip", "booking", "confirmation"])

  @month_numbers %{
    "jan" => 1,
    "january" => 1,
    "feb" => 2,
    "february" => 2,
    "mar" => 3,
    "march" => 3,
    "apr" => 4,
    "april" => 4,
    "may" => 5,
    "jun" => 6,
    "june" => 6,
    "jul" => 7,
    "july" => 7,
    "aug" => 8,
    "august" => 8,
    "sep" => 9,
    "sept" => 9,
    "september" => 9,
    "oct" => 10,
    "october" => 10,
    "nov" => 11,
    "november" => 11,
    "dec" => 12,
    "december" => 12
  }

  def candidate?(message) when is_map(message) do
    text = combined_text(message) |> String.downcase()

    Enum.any?(@travel_terms, &String.contains?(text, &1)) and
      (Enum.any?(@flight_terms, &String.contains?(text, &1)) or
         Enum.any?(@hotel_terms, &String.contains?(text, &1)))
  end

  def candidate?(_message), do: false

  def extract_items(message, opts \\ []) when is_map(message) do
    [
      extract_flight(message, opts),
      extract_hotel(message, opts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  def combined_text(message) when is_map(message) do
    [
      read_string(message, "subject"),
      read_string(message, "snippet"),
      read_string(message, "text_body"),
      html_to_text(read_string(message, "html_body"))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp extract_flight(message, opts) do
    text = combined_text(message)
    lines = text |> split_lines()
    route = parse_route(text)

    if is_nil(route) do
      nil
    else
      reference_time = read_datetime(message, "internal_date") || DateTime.utc_now()
      offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
      flight_line = find_match(lines, ~r/\b[A-Z]{2}\s?\d{1,4}(?:\s*\/\s*[A-Z]{2}\s?\d{1,4})*\b/)

      booking_ref =
        capture(
          text,
          ~r/(?:booking ref|record locator|confirmation code)[:#]?\s*([A-Z0-9-]{4,16})/i
        )

      departure_label = parse_date_line(lines, reference_time, offset_hours)

      vendor_name =
        detect_vendor_name(lines, route.origin_label, route.destination_label, message)

      start_at = departure_label && departure_label.datetime

      confidence =
        0.72
        |> maybe_add_confidence(route.origin_code && route.destination_code, 0.08)
        |> maybe_add_confidence(flight_line, 0.08)
        |> maybe_add_confidence(start_at, 0.08)
        |> maybe_add_confidence(booking_ref, 0.04)
        |> min(0.98)

      if is_nil(start_at) do
        nil
      else
        date_key = local_date_key(start_at, offset_hours)
        destination_slug = slugify(route.destination_label || route.destination_code || "trip")
        confirmation_key = booking_ref || "#{destination_slug}:#{date_key}"

        title =
          [vendor_name, normalize_whitespace(flight_line)]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" ")
          |> blank_to_fallback("#{route.origin_label} -> #{route.destination_label}")

        %{
          "item_type" => "flight",
          "status" => change_status(text),
          "source_provider" => "gmail",
          "source_message_id" => read_string(message, "message_id"),
          "source_thread_id" => read_string(message, "thread_id"),
          "fingerprint" => "flight:#{slugify(vendor_name)}:#{confirmation_key}",
          "vendor_name" => vendor_name,
          "title" => title,
          "confirmation_code" => booking_ref,
          "starts_at" => start_at,
          "ends_at" => nil,
          "location_label" => "#{route.origin_label} -> #{route.destination_label}",
          "confidence" => confidence,
          "metadata" => %{
            "trip_key" => "#{destination_slug}:#{date_key}",
            "destination_label" => route.destination_label,
            "origin_label" => route.origin_label,
            "origin_code" => route.origin_code,
            "destination_code" => route.destination_code,
            "flight_line" => normalize_whitespace(flight_line),
            "date_line" => departure_label && departure_label.label,
            "display_date" => departure_label && departure_label.display,
            "booking_ref" => booking_ref,
            "evidence_subject" => read_string(message, "subject"),
            "evidence_from" => read_string(message, "from")
          }
        }
      end
    end
  end

  defp extract_hotel(message, opts) do
    text = combined_text(message)
    lines = split_lines(text)

    if not Enum.any?(@hotel_terms, &String.contains?(String.downcase(text), &1)) do
      nil
    else
      reference_time = read_datetime(message, "internal_date") || DateTime.utc_now()
      offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
      property_name = hotel_property_name(lines, message)
      address = hotel_address(lines)
      check_in = parse_labeled_date(lines, "check-in", reference_time, offset_hours)
      check_out = parse_labeled_date(lines, "check-out", reference_time, offset_hours)

      itinerary_code =
        capture(
          text,
          ~r/(?:itinerary|confirmation|reservation)\s*(?:#|number|no\.?)[:#]?\s*([A-Z0-9-]{4,20})/i
        )

      room = capture(text, ~r/room[:#]?\s*([^\n\r]+)/i)

      phone =
        capture(text, ~r/(?:hotel phone|phone)[:#]?\s*(\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4})/i)

      city = extract_city_from_address(address) || extract_city_from_text(property_name || "")
      start_at = check_in && check_in.datetime
      end_at = check_out && check_out.datetime

      confidence =
        0.7
        |> maybe_add_confidence(property_name, 0.08)
        |> maybe_add_confidence(start_at, 0.1)
        |> maybe_add_confidence(end_at, 0.04)
        |> maybe_add_confidence(address, 0.04)
        |> maybe_add_confidence(itinerary_code, 0.04)
        |> min(0.98)

      if is_nil(start_at) or blank?(property_name) do
        nil
      else
        date_key = local_date_key(start_at, offset_hours)
        destination_slug = slugify(city || property_name)
        confirmation_key = itinerary_code || "#{destination_slug}:#{date_key}"

        %{
          "item_type" => "hotel",
          "status" => change_status(text),
          "source_provider" => "gmail",
          "source_message_id" => read_string(message, "message_id"),
          "source_thread_id" => read_string(message, "thread_id"),
          "fingerprint" => "hotel:#{slugify(property_name)}:#{confirmation_key}",
          "vendor_name" => property_name,
          "title" => property_name,
          "confirmation_code" => itinerary_code,
          "starts_at" => start_at,
          "ends_at" => end_at,
          "location_label" => city || property_name,
          "confidence" => confidence,
          "metadata" => %{
            "trip_key" => "#{destination_slug}:#{date_key}",
            "address" => address,
            "display_check_in" => check_in && check_in.display,
            "display_check_out" => check_out && check_out.display,
            "room" => room && normalize_whitespace(room),
            "hotel_phone" => phone,
            "destination_label" => city || property_name,
            "evidence_subject" => read_string(message, "subject"),
            "evidence_from" => read_string(message, "from")
          }
        }
      end
    end
  end

  defp change_status(text) do
    lowered = String.downcase(text)

    cond do
      String.contains?(lowered, "cancelled") or String.contains?(lowered, "canceled") ->
        "cancelled"

      String.contains?(lowered, "changed") or String.contains?(lowered, "updated") ->
        "updated"

      true ->
        "active"
    end
  end

  defp parse_route(text) when is_binary(text) do
    regex =
      ~r/([A-Za-z .'-]+?)\s+([A-Z]{3})\s*(?:->|→|to)\s*([A-Za-z .'-]+?)\s+([A-Z]{3})/

    case Regex.run(regex, text, capture: :all_but_first) do
      [origin_label, origin_code, destination_label, destination_code] ->
        %{
          origin_label: normalize_whitespace(origin_label),
          origin_code: origin_code,
          destination_label: normalize_whitespace(destination_label),
          destination_code: destination_code
        }

      _ ->
        nil
    end
  end

  defp detect_vendor_name(lines, origin_label, destination_label, message) do
    Enum.find_value(lines, fn line ->
      candidate = normalize_whitespace(line)

      cond do
        blank?(candidate) ->
          nil

        String.contains?(candidate, origin_label || "") and
            String.contains?(candidate, destination_label || "") ->
          nil

        Regex.match?(~r/\b[A-Z]{2}\s?\d{1,4}\b/, candidate) ->
          candidate
          |> String.replace(~r/\b[A-Z]{2}\s?\d{1,4}.*$/, "")
          |> normalize_whitespace()
          |> blank_to_nil()

        true ->
          nil
      end
    end) || sender_name(read_string(message, "from"))
  end

  defp hotel_property_name(lines, message) do
    Enum.find_value(lines, fn line ->
      normalized = normalize_whitespace(line)
      lowered = String.downcase(normalized)

      cond do
        blank?(normalized) ->
          nil

        Regex.match?(~r/^\d{1,5}\s+/, normalized) ->
          nil

        String.starts_with?(lowered, "check-") ->
          nil

        String.starts_with?(lowered, "room:") ->
          nil

        String.starts_with?(lowered, "itinerary") ->
          nil

        String.contains?(lowered, "reservation confirmed") ->
          nil

        String.contains?(lowered, "booking confirmed") ->
          nil

        String.contains?(lowered, "check-in") or
          String.contains?(lowered, "check in") or
          String.contains?(lowered, "check-out") or
            String.contains?(lowered, "check out") ->
          nil

        String.contains?(lowered, "hotel") or
          String.contains?(lowered, "marriott") or
          String.contains?(lowered, "inn") or
            String.contains?(lowered, "suites") ->
          normalized

        true ->
          nil
      end
    end) || subject_property(read_string(message, "subject"))
  end

  defp subject_property(subject) when is_binary(subject) do
    subject
    |> String.split(~r/[-|:]/)
    |> Enum.map(&normalize_whitespace/1)
    |> Enum.find(&(!blank?(&1) and String.length(&1) > 6))
  end

  defp hotel_address(lines) do
    Enum.find_value(lines, fn line ->
      normalized = normalize_whitespace(line)

      if Regex.match?(~r/^\d{1,5}\s+.+,\s*[A-Za-z .'-]+,\s*[A-Z]{2}\s+\d{5}/, normalized),
        do: normalized
    end)
  end

  defp extract_city_from_address(address) when is_binary(address) do
    case Regex.run(~r/,\s*([A-Za-z .'-]+),\s*[A-Z]{2}\s+\d{5}/, address, capture: :all_but_first) do
      [city] -> normalize_whitespace(city)
      _ -> nil
    end
  end

  defp extract_city_from_address(_address), do: nil

  defp extract_city_from_text(value) when is_binary(value) do
    case Regex.run(~r/\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\b/, value, capture: :all_but_first) do
      [city] -> city
      _ -> nil
    end
  end

  defp parse_labeled_date(lines, label, reference_time, offset_hours) do
    preferred =
      Enum.find_value(lines, fn line ->
        downcased = String.downcase(line)

        if String.starts_with?(downcased, label) or
             String.starts_with?(downcased, String.replace(label, "-", " ")) do
          parse_date_string(line, reference_time, offset_hours)
        end
      end)

    preferred ||
      Enum.find_value(lines, fn line ->
        downcased = String.downcase(line)

        if String.contains?(downcased, label) do
          parse_date_string(line, reference_time, offset_hours)
        end
      end)
  end

  defp parse_date_line(lines, reference_time, offset_hours) do
    preferred =
      Enum.find_value(lines, fn line ->
        downcased = String.downcase(line)

        if String.starts_with?(downcased, "departure") or String.starts_with?(downcased, "depart") do
          parse_date_string(line, reference_time, offset_hours)
        end
      end)

    preferred || Enum.find_value(lines, &parse_date_string(&1, reference_time, offset_hours))
  end

  defp parse_date_string(line, reference_time, offset_hours) when is_binary(line) do
    regex =
      ~r/(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*,\s*)?([A-Za-z]{3,9})\s+(\d{1,2})(?:,\s*(\d{4}))?(?:\s*(?:@|at)?\s*(\d{1,2}:\d{2}\s*[AP]M|Noon|Midnight))?/i

    case Regex.run(regex, line, capture: :all_but_first) do
      [month_name, day, year, time] ->
        build_date_info(month_name, day, year, time, reference_time, offset_hours, line)

      [month_name, day, year] ->
        build_date_info(month_name, day, year, nil, reference_time, offset_hours, line)

      [month_name, day] ->
        build_date_info(month_name, day, nil, nil, reference_time, offset_hours, line)

      _ ->
        nil
    end
  end

  defp build_date_info(month_name, day, year, time, reference_time, offset_hours, label) do
    with month when is_integer(month) <- month_number(month_name),
         {day_num, ""} <- Integer.parse(to_string(day)),
         year_num <- resolve_year(year, month, day_num, reference_time),
         {:ok, date} <- Date.new(year_num, month, day_num),
         {:ok, {hour, minute}} <- parse_time(time),
         {:ok, naive} <- NaiveDateTime.new(date, Time.new!(hour, minute, 0)),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      utc_datetime = DateTime.add(datetime, -offset_hours * 3600, :second)

      %{
        datetime: utc_datetime,
        display: label |> normalize_whitespace(),
        label: label |> normalize_whitespace()
      }
    else
      _ -> nil
    end
  end

  defp parse_time(nil), do: {:ok, {12, 0}}

  defp parse_time(time) when is_binary(time) do
    normalized = String.downcase(String.trim(time))

    cond do
      normalized == "noon" ->
        {:ok, {12, 0}}

      normalized == "midnight" ->
        {:ok, {0, 0}}

      true ->
        case Regex.run(~r/(\d{1,2}):(\d{2})\s*([ap]m)/, normalized, capture: :all_but_first) do
          [hour, minute, meridiem] ->
            {hour_num, ""} = Integer.parse(hour)
            {minute_num, ""} = Integer.parse(minute)

            normalized_hour =
              case {hour_num, meridiem} do
                {12, "am"} -> 0
                {12, "pm"} -> 12
                {value, "pm"} -> value + 12
                {value, _} -> value
              end

            {:ok, {normalized_hour, minute_num}}

          _ ->
            {:ok, {12, 0}}
        end
    end
  end

  defp resolve_year(year, month, day, reference_time) do
    case year do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> reference_time.year
        end

      _ ->
        candidate = Date.new!(reference_time.year, month, day)

        if Date.compare(candidate, Date.add(DateTime.to_date(reference_time), -30)) == :lt do
          reference_time.year + 1
        else
          reference_time.year
        end
    end
  end

  defp month_number(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@month_numbers, &1))
  end

  defp sender_name(value) when is_binary(value) do
    value
    |> String.split("<")
    |> List.first()
    |> normalize_whitespace()
    |> blank_to_nil()
  end

  defp sender_name(_value), do: nil

  defp split_lines(value) when is_binary(value) do
    value
    |> String.split(~r/[\r\n]+/)
    |> Enum.map(&normalize_whitespace/1)
    |> Enum.reject(&blank?/1)
  end

  defp split_lines(_value), do: []

  defp html_to_text(""), do: ""

  defp html_to_text(value) when is_binary(value) do
    value
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> normalize_whitespace_preserving_lines()
  end

  defp html_to_text(_value), do: ""

  defp normalize_whitespace(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_whitespace(_value), do: ""

  defp normalize_whitespace_preserving_lines(value) when is_binary(value) do
    value
    |> String.split("\n")
    |> Enum.map(&normalize_whitespace/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp blank_to_fallback(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp maybe_add_confidence(score, nil, _amount), do: score
  defp maybe_add_confidence(score, false, _amount), do: score
  defp maybe_add_confidence(score, "", _amount), do: score
  defp maybe_add_confidence(score, _present, amount), do: score + amount

  defp capture(text, regex) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value | _] -> normalize_whitespace(value)
      _ -> nil
    end
  end

  defp find_match(lines, regex) do
    lines
    |> Enum.filter(&Regex.match?(regex, &1))
    |> Enum.min_by(&String.length/1, fn -> nil end)
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> blank_to_fallback("trip")
  end

  defp local_date_key(datetime, offset_hours) do
    datetime
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp read_string(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp read_datetime(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      %DateTime{} = value -> value
      _ -> nil
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
end
