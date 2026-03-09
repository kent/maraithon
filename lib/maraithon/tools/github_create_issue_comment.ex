defmodule Maraithon.Tools.GitHubCreateIssueComment do
  @moduledoc """
  Creates a GitHub issue or PR comment using the configured GitHub API token.
  """

  alias Maraithon.Connectors.GitHub
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, owner} <- ActionHelpers.required_string(args, "owner"),
         {:ok, repo} <- ActionHelpers.required_string(args, "repo"),
         {:ok, issue_number} <- ActionHelpers.required_integer(args, "issue_number"),
         {:ok, body} <- ActionHelpers.required_string(args, "body"),
         {:ok, comment} <- GitHub.create_issue_comment(owner, repo, issue_number, body) do
      {:ok,
       %{source: "github", owner: owner, repo: repo, issue_number: issue_number, comment: comment}}
    else
      {:error, :api_token_not_configured} ->
        {:error, "github_api_token_not_configured"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "github_comment_failed: #{inspect(reason)}"}
    end
  end
end
