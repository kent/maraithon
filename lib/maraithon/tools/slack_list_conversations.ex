defmodule Maraithon.Tools.SlackListConversations do
  @moduledoc """
  Lists Slack conversations for a connected workspace.
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.SlackHelpers

  @default_limit 40
  @max_limit 200

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         {:ok, token} <- resolve_token(user_id, team_id, args),
         {:ok, response} <-
           Slack.list_conversations(token.access_token,
             types: resolve_types(args),
             limit: resolve_limit(args),
             exclude_archived: resolve_exclude_archived(args)
           ) do
      channels =
        response["channels"]
        |> normalize_list()
        |> Enum.map(&serialize_conversation/1)

      {:ok,
       %{
         source: "slack",
         team_id: team_id,
         token_provider: token.provider,
         count: length(channels),
         conversations: channels
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        SlackHelpers.normalize_error(reason)
    end
  end

  defp resolve_token(user_id, team_id, args) do
    SlackHelpers.resolve_access_token(
      user_id,
      team_id,
      token_preference: ActionHelpers.optional_string(args, "token_preference"),
      slack_user_id: ActionHelpers.optional_string(args, "slack_user_id")
    )
  end

  defp resolve_types(args) do
    case ActionHelpers.optional_csv(args, "types") do
      [] -> ["public_channel", "private_channel", "im", "mpim"]
      values -> values
    end
  end

  defp resolve_limit(args) do
    args
    |> ActionHelpers.optional_integer("limit")
    |> normalize_limit()
  end

  defp resolve_exclude_archived(args) do
    case ActionHelpers.optional_string(args, "exclude_archived") do
      value when value in ["true", "TRUE", "1"] -> true
      _ -> false
    end
  end

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)
  defp normalize_limit(_value), do: @default_limit

  defp serialize_conversation(channel) when is_map(channel) do
    %{
      id: channel["id"],
      name: channel["name"],
      user: channel["user"],
      is_private: channel["is_private"] || false,
      is_im: channel["is_im"] || false,
      is_mpim: channel["is_mpim"] || false,
      is_archived: channel["is_archived"] || false,
      is_member: channel["is_member"] || false,
      num_members: channel["num_members"],
      topic: get_in(channel, ["topic", "value"]),
      purpose: get_in(channel, ["purpose", "value"]),
      latest_ts: get_in(channel, ["latest", "ts"]) || channel["latest"]
    }
  end

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []
end
