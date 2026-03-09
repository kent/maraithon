defmodule Maraithon.Tools.GoogleCalendarListEvents do
  @moduledoc """
  Lists Google Calendar events for a connected Google account.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GoogleCalendarHelpers

  def execute(args) when is_map(args) do
    max_results = resolve_max_results(args)
    calendar_id = ActionHelpers.optional_string(args, "calendar_id") || "primary"

    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, events} <-
           GoogleCalendarHelpers.list_events(user_id,
             calendar_id: calendar_id,
             query: ActionHelpers.optional_string(args, "query"),
             time_min: ActionHelpers.optional_string(args, "time_min"),
             time_max: ActionHelpers.optional_string(args, "time_max"),
             max_results: max_results
           ) do
      {:ok,
       %{
         source: "google_calendar",
         calendar_id: calendar_id,
         count: length(events),
         events: events
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        GoogleCalendarHelpers.normalize_error(reason)
    end
  end

  defp resolve_max_results(args) do
    args
    |> ActionHelpers.optional_integer("max_results")
    |> normalize_max_results()
  end

  defp normalize_max_results(value) when is_integer(value), do: value |> max(1) |> min(100)
  defp normalize_max_results(_), do: 25
end
