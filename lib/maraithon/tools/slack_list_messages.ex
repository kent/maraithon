defmodule Maraithon.Tools.SlackListMessages do
  @moduledoc """
  Reads recent messages from a Slack channel, DM, or MPIM conversation.
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.SlackHelpers

  @default_limit 30
  @max_limit 200

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         {:ok, channel} <- ActionHelpers.required_string(args, "channel"),
         {:ok, token} <- resolve_token(user_id, team_id, args),
         {:ok, response} <-
           Slack.get_conversation_history(token.access_token, channel,
             limit: resolve_limit(args),
             oldest: ActionHelpers.optional_string(args, "oldest"),
             latest: ActionHelpers.optional_string(args, "latest"),
             inclusive: resolve_inclusive(args)
           ) do
      messages =
        response["messages"]
        |> normalize_list()
        |> Enum.map(&serialize_message/1)

      {:ok,
       %{
         source: "slack",
         team_id: team_id,
         channel: channel,
         token_provider: token.provider,
         count: length(messages),
         has_more: response["has_more"] || false,
         messages: messages
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

  defp resolve_limit(args) do
    args
    |> ActionHelpers.optional_integer("limit")
    |> normalize_limit()
  end

  defp resolve_inclusive(args) do
    case ActionHelpers.optional_string(args, "inclusive") do
      value when value in ["true", "TRUE", "1"] -> true
      value when value in ["false", "FALSE", "0"] -> false
      _ -> nil
    end
  end

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)
  defp normalize_limit(_value), do: @default_limit

  defp serialize_message(message) when is_map(message) do
    %{
      ts: message["ts"],
      thread_ts: message["thread_ts"],
      user: message["user"],
      bot_id: message["bot_id"],
      subtype: message["subtype"],
      text: message["text"],
      reply_count: message["reply_count"],
      latest_reply: message["latest_reply"],
      reactions: normalize_list(message["reactions"])
    }
  end

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []
end
