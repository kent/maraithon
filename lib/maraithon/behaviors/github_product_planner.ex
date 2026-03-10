defmodule Maraithon.Behaviors.GitHubProductPlanner do
  @moduledoc """
  Daily PM-style planner that reviews a GitHub repository and proposes the
  next 2-3 feature opportunities for Telegram delivery.
  """

  @behaviour Maraithon.Behaviors.Behavior

  import Ecto.Query

  alias Maraithon.GitHubRepoSnapshot
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.Repo

  require Logger

  @default_base_branch "main"
  @default_feature_limit 3
  @default_wakeup_interval_ms :timer.hours(24)
  @default_telegram_fit_score 0.98
  @max_follow_up_ideas 3
  @max_evidence_points 4

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      repo_full_name: normalize_string(config["repo_full_name"]),
      base_branch: normalize_string(config["base_branch"]) || @default_base_branch,
      feature_limit: to_feature_limit(config["feature_limit"], @default_feature_limit),
      wakeup_interval_ms:
        to_positive_integer(config["wakeup_interval_ms"], @default_wakeup_interval_ms),
      pending_snapshot: nil,
      pending_plan_date: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = ensure_user_id(state, context)
    plan_date = DateTime.to_date(context.timestamp) |> Date.to_iso8601()

    cond do
      is_nil(state.user_id) ->
        Logger.warning("GitHubProductPlanner skipped wakeup: user_id missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      is_nil(state.repo_full_name) ->
        Logger.warning("GitHubProductPlanner skipped wakeup: repo_full_name missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      already_planned_for_date?(state.user_id, state.repo_full_name, plan_date) ->
        {:idle, state}

      true ->
        case GitHubRepoSnapshot.fetch(state.user_id, state.repo_full_name, state.base_branch) do
          {:ok, snapshot} ->
            params = %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => build_llm_prompt(snapshot, context.timestamp, state.feature_limit)
                }
              ],
              "max_tokens" => 1_800,
              "temperature" => 0.3
            }

            {:effect, {:llm_call, params},
             %{state | pending_snapshot: snapshot, pending_plan_date: plan_date}}

          {:error, reason} ->
            Logger.warning("GitHubProductPlanner failed to fetch repo snapshot",
              repo_full_name: state.repo_full_name,
              reason: inspect(reason)
            )

            {:emit,
             {:planning_error, %{repo_full_name: state.repo_full_name, reason: inspect(reason)}},
             state}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    snapshot = state.pending_snapshot || %{}

    plan_date =
      state.pending_plan_date || DateTime.to_date(context.timestamp) |> Date.to_iso8601()

    insights =
      parse_llm_response(response.content, snapshot, state, plan_date)
      |> Enum.take(state.feature_limit)

    case Insights.record_many(state.user_id, context.agent_id, insights) do
      {:ok, stored} ->
        {:emit,
         {:insights_recorded,
          %{
            count: length(stored),
            user_id: state.user_id,
            categories: stored |> Enum.map(& &1.category) |> Enum.uniq()
          }}, %{state | pending_snapshot: nil, pending_plan_date: nil}}

      {:error, reason} ->
        Logger.warning("GitHubProductPlanner failed to persist insights", reason: inspect(reason))

        {:emit,
         {:planning_error,
          %{
            repo_full_name: state.repo_full_name,
            reason: inspect(reason)
          }}, %{state | pending_snapshot: nil, pending_plan_date: nil}}
    end
  end

  def handle_effect_result({:tool_call, _result}, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state), do: {:relative, state.wakeup_interval_ms}

  defp ensure_user_id(state, context) do
    case state.user_id do
      nil -> %{state | user_id: normalize_string(context[:user_id])}
      _ -> state
    end
  end

  defp already_planned_for_date?(user_id, repo_full_name, plan_date) do
    prefix = "#{dedupe_prefix(repo_full_name, plan_date)}:%"

    Insight
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.category == "product_opportunity")
    |> where([i], like(i.dedupe_key, ^prefix))
    |> Repo.exists?()
  end

  defp parse_llm_response(content, snapshot, state, plan_date) when is_binary(content) do
    with {:ok, decoded} <- decode_json_payload(content),
         list when is_list(list) <- extract_feature_list(decoded) do
      list
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {item, index}, acc ->
        case feature_to_insight(item, index, snapshot, state, plan_date) do
          nil -> acc
          insight -> [insight | acc]
        end
      end)
      |> Enum.reverse()
    else
      _ ->
        []
    end
  end

  defp parse_llm_response(_content, _snapshot, _state, _plan_date), do: []

  defp feature_to_insight(item, index, snapshot, _state, plan_date) when is_map(item) do
    title = read_string(item, "title", nil)
    summary = read_string(item, "summary", nil)
    recommended_action = read_string(item, "recommended_action", nil)

    if Enum.any?([title, summary, recommended_action], &is_nil/1) do
      nil
    else
      priority = clamp(read_integer(item, "priority", 82), 60, 95)
      confidence = clamp(read_float(item, "confidence", 0.82), 0.55, 0.99)
      why_now = read_string(item, "why_now", nil)

      follow_up_ideas =
        read_string_list(item, "follow_up_ideas")
        |> Enum.take(@max_follow_up_ideas)

      evidence =
        read_string_list(item, "evidence")
        |> Enum.take(@max_evidence_points)

      telegram_fit_score =
        clamp(
          read_float(item, "telegram_fit_score", @default_telegram_fit_score),
          0.0,
          1.0
        )

      metadata =
        %{
          "repo_full_name" => snapshot.repo_full_name,
          "base_branch" => snapshot.base_branch,
          "planner_date" => plan_date,
          "planner_type" => "github_product_planner",
          "latest_commit_sha" => snapshot.latest_commit_sha,
          "latest_commit_message" => snapshot.latest_commit_message,
          "telegram_fit_score" => telegram_fit_score,
          "telegram_fit_reason" =>
            read_string(
              item,
              "telegram_fit_reason",
              "Daily roadmap suggestions are a high-signal Telegram workflow for this agent."
            ),
          "why_now" =>
            why_now ||
              "This opportunity is grounded in the latest branch state, open work, and recent shipping activity.",
          "follow_up_ideas" => follow_up_ideas,
          "evidence" => evidence
        }
        |> compact_map()

      %{
        "source" => "github",
        "category" => "product_opportunity",
        "title" => title,
        "summary" => summary,
        "recommended_action" => recommended_action,
        "priority" => priority,
        "confidence" => confidence,
        "source_id" => snapshot.latest_commit_sha || "#{snapshot.repo_full_name}:#{plan_date}",
        "source_occurred_at" => snapshot.latest_commit_at,
        "dedupe_key" =>
          "#{dedupe_prefix(snapshot.repo_full_name, plan_date)}:#{slugify(title)}:#{index}",
        "metadata" => metadata
      }
    end
  end

  defp feature_to_insight(_item, _index, _snapshot, _state, _plan_date), do: nil

  defp build_llm_prompt(snapshot, timestamp, feature_limit) do
    snapshot_json = Jason.encode!(snapshot)

    """
    You are a senior product manager reviewing the current mainline branch of a software repository.
    Current time: #{DateTime.to_iso8601(timestamp)}
    Target feature count: #{feature_limit}

    Repository snapshot JSON:
    #{snapshot_json}

    Task:
    - Propose the next #{feature_limit} highest-leverage product features this team should build next.
    - Think like a PM, not an implementation planner: prioritize end-user value, marketability, adoption, and workflow impact.
    - Use the repo description, README, root structure, recent commits, open issues, and open pull requests as evidence.
    - Avoid suggesting pure refactors, chores, or already-in-flight work unless they unlock a real user-facing feature.
    - Make each recommendation concrete enough that a founder or PM could forward it to engineering without rewriting it.
    - Summaries should explain the user/problem/value in 1-2 sentences.
    - Recommended actions should describe the first scoped milestone to validate or ship.
    - why_now should explain why this is timely based on current repo activity.
    - follow_up_ideas should be a short list of concrete supporting ideas.
    - evidence should cite the repo signals that support the recommendation.
    - Set telegram_fit_score high only if the recommendation is worth interrupting the operator about today.

    Return ONLY valid JSON.
    Preferred shape: an array.
    Each item must include:
    title, summary, recommended_action, priority, confidence, why_now, follow_up_ideas, evidence, telegram_fit_score, telegram_fit_reason
    """
  end

  defp dedupe_prefix(repo_full_name, plan_date) do
    "github_feature_plan:#{repo_full_name}:#{plan_date}"
  end

  defp decode_json_payload(content) do
    case Jason.decode(content) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} ->
        case Regex.run(~r/```json\s*(\[.*\]|\{.*\})\s*```/s, content, capture: :all_but_first) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp extract_feature_list(list) when is_list(list), do: list

  defp extract_feature_list(map) when is_map(map) do
    case fetch_attr(map, "features") do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp extract_feature_list(_), do: nil

  defp to_feature_limit(value, _default) when value in [2, 3], do: value

  defp to_feature_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in [2, 3] -> parsed
      _ -> default
    end
  end

  defp to_feature_limit(_value, default), do: default

  defp to_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp to_positive_integer(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_), do: nil

  defp read_string(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          normalized -> normalized
        end

      _ ->
        default
    end
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_float(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_string_list(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      value when is_binary(value) ->
        value
        |> String.split(~r/\r?\n|;/, trim: true)
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
          _ -> nil
        end)
    end
  end

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, []}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp slugify(nil), do: "feature"

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "feature"
      slug -> slug
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
