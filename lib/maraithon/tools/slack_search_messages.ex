defmodule Maraithon.Tools.SlackSearchMessages do
  @moduledoc """
  Searches Slack messages using a user token (best for cross-channel context lookups).
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.SlackHelpers

  @default_count 20
  @max_count 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         {:ok, query} <- ActionHelpers.required_string(args, "query"),
         {:ok, token} <- resolve_token(user_id, team_id, args),
         {:ok, response} <-
           Slack.search_messages(token.access_token, query,
             count: resolve_count(args),
             page: ActionHelpers.optional_integer(args, "page"),
             sort: ActionHelpers.optional_string(args, "sort"),
             sort_dir: ActionHelpers.optional_string(args, "sort_dir")
           ) do
      matches =
        get_in(response, ["messages", "matches"])
        |> normalize_list()
        |> Enum.map(&serialize_match/1)

      {:ok,
       %{
         source: "slack",
         team_id: team_id,
         query: query,
         token_provider: token.provider,
         count: length(matches),
         total: get_in(response, ["messages", "total"]),
         matches: matches
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        SlackHelpers.normalize_error(reason)
    end
  end

  defp resolve_token(user_id, team_id, args) do
    preference = ActionHelpers.optional_string(args, "token_preference")

    SlackHelpers.resolve_access_token(
      user_id,
      team_id,
      token_preference: preference || "user",
      slack_user_id: ActionHelpers.optional_string(args, "slack_user_id")
    )
  end

  defp resolve_count(args) do
    args
    |> ActionHelpers.optional_integer("count")
    |> normalize_count()
  end

  defp normalize_count(value) when is_integer(value), do: value |> max(1) |> min(@max_count)
  defp normalize_count(_value), do: @default_count

  defp serialize_match(match) when is_map(match) do
    %{
      ts: match["ts"],
      channel_id: get_in(match, ["channel", "id"]),
      channel_name: get_in(match, ["channel", "name"]),
      user: match["user"],
      text: match["text"],
      permalink: match["permalink"]
    }
  end

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []
end
