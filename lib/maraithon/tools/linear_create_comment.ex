defmodule Maraithon.Tools.LinearCreateComment do
  @moduledoc """
  Creates a Linear comment using the connected user's OAuth token.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, issue_id} <- ActionHelpers.required_string(args, "issue_id"),
         {:ok, body} <- ActionHelpers.required_string(args, "body"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, comment} <- Linear.create_comment(access_token, issue_id, body) do
      {:ok, %{source: "linear", issue_id: issue_id, comment: comment}}
    else
      {:error, :no_token} ->
        {:error, "linear_not_connected"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "linear_comment_failed: #{inspect(reason)}"}
    end
  end
end
