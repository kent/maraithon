defmodule Maraithon.Tools.LinearUpdateIssueState do
  @moduledoc """
  Updates a Linear issue state using the connected user's OAuth token.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, issue_id} <- ActionHelpers.required_string(args, "issue_id"),
         {:ok, state_id} <- ActionHelpers.required_string(args, "state_id"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, issue} <- Linear.update_issue_state(access_token, issue_id, state_id) do
      {:ok, %{source: "linear", issue_id: issue_id, issue: issue}}
    else
      {:error, :no_token} ->
        {:error, "linear_not_connected"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "linear_issue_update_failed: #{inspect(reason)}"}
    end
  end
end
