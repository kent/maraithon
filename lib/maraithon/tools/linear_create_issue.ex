defmodule Maraithon.Tools.LinearCreateIssue do
  @moduledoc """
  Creates a Linear issue using the connected user's OAuth token.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         {:ok, title} <- ActionHelpers.required_string(args, "title"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, issue} <- Linear.create_issue(access_token, team_id, title, build_opts(args)) do
      {:ok, %{source: "linear", team_id: team_id, issue: issue}}
    else
      {:error, :no_token} ->
        {:error, "linear_not_connected"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "linear_issue_create_failed: #{inspect(reason)}"}
    end
  end

  defp build_opts(args) do
    []
    |> ActionHelpers.maybe_put(:description, ActionHelpers.optional_string(args, "description"))
    |> ActionHelpers.maybe_put(:priority, ActionHelpers.optional_integer(args, "priority"))
    |> ActionHelpers.maybe_put(:assignee_id, ActionHelpers.optional_string(args, "assignee_id"))
    |> ActionHelpers.maybe_put(:project_id, ActionHelpers.optional_string(args, "project_id"))
    |> ActionHelpers.maybe_put(:state_id, ActionHelpers.optional_string(args, "state_id"))
    |> maybe_put_label_ids(ActionHelpers.optional_csv(args, "label_ids"))
  end

  defp maybe_put_label_ids(opts, []), do: opts
  defp maybe_put_label_ids(opts, label_ids), do: Keyword.put(opts, :label_ids, label_ids)
end
