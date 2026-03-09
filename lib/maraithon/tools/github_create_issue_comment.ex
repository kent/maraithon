defmodule Maraithon.Tools.GitHubCreateIssueComment do
  @moduledoc """
  Creates a GitHub issue or PR comment using a connected user's OAuth token
  when `user_id` is provided, falling back to the configured GitHub API token.
  """

  alias Maraithon.Connectors.GitHub
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, owner} <- ActionHelpers.required_string(args, "owner"),
         {:ok, repo} <- ActionHelpers.required_string(args, "repo"),
         {:ok, issue_number} <- ActionHelpers.required_integer(args, "issue_number"),
         {:ok, body} <- ActionHelpers.required_string(args, "body"),
         {:ok, access_token} <- resolve_access_token(args),
         {:ok, comment} <-
           GitHub.create_issue_comment(owner, repo, issue_number, body,
             access_token: access_token
           ) do
      {:ok,
       %{
         source: "github",
         owner: owner,
         repo: repo,
         issue_number: issue_number,
         comment: comment
       }}
    else
      {:error, :no_token} ->
        {:error, "github_account_not_connected"}

      {:error, :api_token_not_configured} ->
        {:error, "github_api_token_not_configured"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "github_comment_failed: #{inspect(reason)}"}
    end
  end

  defp resolve_access_token(args) do
    case ActionHelpers.optional_string(args, "user_id") do
      nil -> {:ok, nil}
      user_id -> OAuth.get_valid_access_token(user_id, "github")
    end
  end
end
