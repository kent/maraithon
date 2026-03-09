defmodule Maraithon.Tools.SlackPostMessage do
  @moduledoc """
  Posts a message to a Slack workspace/channel connected through OAuth.
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         {:ok, channel} <- ActionHelpers.required_string(args, "channel"),
         {:ok, text} <- ActionHelpers.required_string(args, "text"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "slack:#{team_id}"),
         {:ok, response} <-
           Slack.post_message(
             access_token,
             channel,
             text,
             thread_ts: ActionHelpers.optional_string(args, "thread_ts")
           ) do
      {:ok,
       %{
         source: "slack",
         team_id: team_id,
         channel: channel,
         ts: response["ts"],
         ok: response["ok"]
       }}
    else
      {:error, :no_token} ->
        {:error, "slack_workspace_not_connected"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "slack_post_failed: #{inspect(reason)}"}
    end
  end
end
