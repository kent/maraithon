defmodule Maraithon.GitHubRepoSnapshot do
  @moduledoc """
  Fetches a compact GitHub repository snapshot suitable for planning prompts.
  """

  alias Maraithon.OAuth
  alias Maraithon.OAuth.GitHub

  @recent_commit_limit 8
  @open_issue_limit 8
  @open_pr_limit 6
  @root_entry_limit 20
  @readme_excerpt_bytes 8_000

  def fetch(user_id, repo_full_name, branch \\ nil)
      when is_binary(user_id) and is_binary(repo_full_name) do
    with {:ok, owner, repo} <- parse_repo_full_name(repo_full_name),
         {access_mode, requester} = requester_for_user(user_id),
         {:ok, repo_data} <- requester.(:get, "/repos/#{owner}/#{repo}", nil) do
      branch = normalize_branch(branch, repo_data["default_branch"])

      with {:ok, commits} <- fetch_commits(owner, repo, branch, requester),
           {:ok, issues} <- fetch_issues(owner, repo, requester),
           {:ok, pulls} <- fetch_pulls(owner, repo, branch, requester),
           {:ok, root_entries} <- fetch_root_entries(owner, repo, branch, requester),
           {:ok, readme} <- fetch_readme(owner, repo, branch, requester) do
        {:ok,
         %{
           repo_full_name: "#{owner}/#{repo}",
           owner: owner,
           repo_name: repo,
           access_mode: access_mode,
           base_branch: branch,
           repo: repo_snapshot(repo_data),
           readme_excerpt: readme,
           root_entries: root_entries,
           recent_commits: commits,
           open_issues: issues,
           open_pull_requests: pulls,
           latest_commit_sha: latest_commit_sha(commits),
           latest_commit_at: latest_commit_at(commits),
           latest_commit_message: latest_commit_message(commits)
         }}
      end
    end
  end

  def parse_repo_full_name(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, owner, repo}
      _ -> {:error, :invalid_repo_full_name}
    end
  end

  def parse_repo_full_name(_), do: {:error, :invalid_repo_full_name}

  defp requester_for_user(user_id) do
    case OAuth.get_valid_access_token(user_id, "github") do
      {:ok, access_token} ->
        {"oauth",
         fn method, path, body -> GitHub.api_request(method, path, access_token, body) end}

      _ ->
        {"public", fn method, path, body -> GitHub.public_api_request(method, path, body) end}
    end
  end

  defp fetch_commits(owner, repo, branch, requester) do
    params = URI.encode_query(%{sha: branch, per_page: @recent_commit_limit})

    with {:ok, commits} when is_list(commits) <-
           requester.(:get, "/repos/#{owner}/#{repo}/commits?#{params}", nil) do
      {:ok,
       Enum.map(commits, fn commit ->
         %{
           sha: commit["sha"],
           message:
             commit
             |> get_in(["commit", "message"])
             |> first_line(),
           author:
             get_in(commit, ["author", "login"]) ||
               get_in(commit, ["commit", "author", "name"]),
           committed_at:
             get_in(commit, ["commit", "author", "date"]) ||
               get_in(commit, ["commit", "committer", "date"]),
           html_url: commit["html_url"]
         }
       end)}
    end
  end

  defp fetch_issues(owner, repo, requester) do
    params = URI.encode_query(%{state: "open", per_page: @open_issue_limit, sort: "updated"})

    case requester.(:get, "/repos/#{owner}/#{repo}/issues?#{params}", nil) do
      {:ok, issues} when is_list(issues) ->
        parsed =
          issues
          |> Enum.reject(&Map.has_key?(&1, "pull_request"))
          |> Enum.map(fn issue ->
            %{
              number: issue["number"],
              title: issue["title"],
              body_excerpt: truncate_text(issue["body"], 280),
              labels: Enum.map(issue["labels"] || [], & &1["name"]),
              updated_at: issue["updated_at"],
              html_url: issue["html_url"]
            }
          end)

        {:ok, parsed}

      {:error, {:http_status, 404, _}} ->
        {:ok, []}

      other ->
        other
    end
  end

  defp fetch_pulls(owner, repo, branch, requester) do
    params = URI.encode_query(%{state: "open", base: branch, per_page: @open_pr_limit})

    case requester.(:get, "/repos/#{owner}/#{repo}/pulls?#{params}", nil) do
      {:ok, pulls} when is_list(pulls) ->
        {:ok,
         Enum.map(pulls, fn pr ->
           %{
             number: pr["number"],
             title: pr["title"],
             body_excerpt: truncate_text(pr["body"], 280),
             author: get_in(pr, ["user", "login"]),
             head_branch: get_in(pr, ["head", "ref"]),
             updated_at: pr["updated_at"],
             html_url: pr["html_url"]
           }
         end)}

      {:error, {:http_status, 404, _}} ->
        {:ok, []}

      other ->
        other
    end
  end

  defp fetch_root_entries(owner, repo, branch, requester) do
    params = URI.encode_query(%{ref: branch})

    case requester.(:get, "/repos/#{owner}/#{repo}/contents?#{params}", nil) do
      {:ok, entries} when is_list(entries) ->
        {:ok,
         entries
         |> Enum.take(@root_entry_limit)
         |> Enum.map(fn entry ->
           %{
             path: entry["path"],
             type: entry["type"],
             size: entry["size"]
           }
         end)}

      {:error, {:http_status, 404, _}} ->
        {:ok, []}

      other ->
        other
    end
  end

  defp fetch_readme(owner, repo, branch, requester) do
    params = URI.encode_query(%{ref: branch})

    case requester.(:get, "/repos/#{owner}/#{repo}/readme?#{params}", nil) do
      {:ok, %{"encoding" => "base64", "content" => content}} ->
        readme =
          content
          |> String.replace("\n", "")
          |> Base.decode64!()
          |> truncate_text(@readme_excerpt_bytes)

        {:ok, readme}

      {:ok, %{"content" => content}} when is_binary(content) ->
        {:ok, truncate_text(content, @readme_excerpt_bytes)}

      {:error, {:http_status, 404, _}} ->
        {:ok, nil}

      other ->
        other
    end
  end

  defp repo_snapshot(repo_data) do
    %{
      name: repo_data["name"],
      description: repo_data["description"],
      homepage: repo_data["homepage"],
      language: repo_data["language"],
      stargazers_count: repo_data["stargazers_count"],
      open_issues_count: repo_data["open_issues_count"],
      default_branch: repo_data["default_branch"],
      topics: repo_data["topics"] || []
    }
  end

  defp normalize_branch(value, default_branch) when is_binary(value) do
    case String.trim(value) do
      "" -> default_branch || "main"
      branch -> branch
    end
  end

  defp normalize_branch(_, default_branch), do: default_branch || "main"

  defp latest_commit_sha([commit | _]), do: commit.sha
  defp latest_commit_sha(_), do: nil

  defp latest_commit_at([commit | _]), do: parse_datetime(commit.committed_at)
  defp latest_commit_at(_), do: nil

  defp latest_commit_message([commit | _]), do: commit.message
  defp latest_commit_message(_), do: nil

  defp first_line(nil), do: nil

  defp first_line(value) when is_binary(value) do
    value
    |> String.split("\n", parts: 2)
    |> List.first()
    |> truncate_text(140)
  end

  defp truncate_text(nil, _limit), do: nil

  defp truncate_text(value, limit) when is_binary(value) and byte_size(value) > limit do
    String.slice(value, 0, limit) <> "..."
  end

  defp truncate_text(value, _limit), do: value

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end
end
