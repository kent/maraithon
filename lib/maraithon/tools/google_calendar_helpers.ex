defmodule Maraithon.Tools.GoogleCalendarHelpers do
  @moduledoc false

  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google

  @default_api_base "https://www.googleapis.com/calendar/v3"

  def list_events(user_id, opts \\ []) when is_binary(user_id) do
    calendar_id = Keyword.get(opts, :calendar_id, "primary")
    max_results = Keyword.get(opts, :max_results, 25)
    query = Keyword.get(opts, :query)
    time_min = Keyword.get(opts, :time_min, DateTime.utc_now() |> DateTime.to_iso8601())
    time_max = Keyword.get(opts, :time_max)
    provider = Keyword.get(opts, :provider, "google")

    with {:ok, access_token} <- OAuth.get_valid_access_token(user_id, provider),
         {:ok, events} <-
           fetch_events(access_token, calendar_id, max_results, query, time_min, time_max) do
      {:ok, events}
    end
  end

  def normalize_error(:no_token), do: {:error, "google_account_not_connected"}

  def normalize_error({:http_status, status, body}),
    do: {:error, "google_calendar_api_failed: #{status} #{body}"}

  def normalize_error(reason), do: {:error, "google_calendar_tool_failed: #{inspect(reason)}"}

  defp fetch_events(access_token, calendar_id, max_results, query, time_min, time_max) do
    params =
      %{}
      |> Map.put(:singleEvents, true)
      |> Map.put(:orderBy, "startTime")
      |> Map.put(:maxResults, max_results)
      |> maybe_put(:q, query)
      |> maybe_put(:timeMin, time_min)
      |> maybe_put(:timeMax, time_max)
      |> URI.encode_query()

    encoded_calendar_id = URI.encode(calendar_id)
    url = "#{api_base_url()}/calendars/#{encoded_calendar_id}/events?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, response} when is_map(response) ->
        {:ok, parse_events(response["items"] || [])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_events(items) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        event_id: item["id"],
        summary: item["summary"],
        description: item["description"],
        location: item["location"],
        status: item["status"],
        start: parse_event_time(item["start"]),
        end: parse_event_time(item["end"]),
        attendees: parse_attendees(item["attendees"]),
        organizer: get_in(item, ["organizer", "email"]),
        html_link: item["htmlLink"],
        created: item["created"],
        updated: item["updated"]
      }
    end)
  end

  defp parse_event_time(nil), do: nil

  defp parse_event_time(%{"dateTime" => date_time}) when is_binary(date_time) do
    case DateTime.from_iso8601(date_time) do
      {:ok, datetime, _offset} -> datetime
      _ -> date_time
    end
  end

  defp parse_event_time(%{"date" => date}) when is_binary(date) do
    %{date: date, all_day: true}
  end

  defp parse_event_time(_), do: nil

  defp parse_attendees(nil), do: []

  defp parse_attendees(attendees) when is_list(attendees) do
    Enum.map(attendees, fn attendee ->
      %{
        email: attendee["email"],
        display_name: attendee["displayName"],
        response_status: attendee["responseStatus"],
        organizer: attendee["organizer"] || false,
        self: attendee["self"] || false
      }
    end)
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp api_base_url do
    Application.get_env(:maraithon, :google_calendar, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end
end
