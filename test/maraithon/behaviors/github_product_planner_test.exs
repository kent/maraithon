defmodule Maraithon.Behaviors.GitHubProductPlannerTest do
  use Maraithon.DataCase, async: false

  import Plug.Conn

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.GitHubProductPlanner
  alias Maraithon.Insights
  alias Maraithon.OAuth

  @user_id "github-planner@example.com"
  @repo_full_name "acme/widgets"

  setup do
    {:ok, _user} = Accounts.get_or_create_user_by_email(@user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: @user_id,
        behavior: "github_product_planner",
        config: %{}
      })

    context = %{
      agent_id: agent.id,
      user_id: @user_id,
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    %{agent: agent, context: context}
  end

  describe "handle_wakeup/2" do
    test "builds an llm request from the github repo snapshot", %{context: context} do
      bypass = Bypass.open()
      github_config = Application.get_env(:maraithon, :github, [])

      Application.put_env(
        :maraithon,
        :github,
        Keyword.put(github_config, :api_base_url, "http://localhost:#{bypass.port}")
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :github, github_config)
      end)

      {:ok, _token} =
        OAuth.store_tokens(@user_id, "github", %{
          access_token: "github-token",
          scopes: ["repo"],
          metadata: %{login: "kent"}
        })

      expect_repo_snapshot_requests(bypass)

      state =
        GitHubProductPlanner.init(%{
          "user_id" => @user_id,
          "repo_full_name" => @repo_full_name,
          "base_branch" => "main",
          "feature_limit" => "3"
        })

      {:effect, {:llm_call, params}, state_after_wakeup} =
        GitHubProductPlanner.handle_wakeup(state, context)

      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert params["temperature"] == 0.3
      assert params["max_tokens"] == 1_800
      assert prompt =~ @repo_full_name
      assert prompt =~ "Acme Widgets"
      assert prompt =~ "Ship daily PM planning suggestions to Telegram"
      assert prompt =~ "Add a roadmap digest agent"
      assert prompt =~ "Build Telegram roadmap summaries"
      assert prompt =~ "README"
      assert state_after_wakeup.pending_snapshot.repo_full_name == @repo_full_name

      assert state_after_wakeup.pending_plan_date ==
               Date.to_iso8601(DateTime.to_date(context.timestamp))
    end

    test "skips planning when the repo already has a plan for today", %{
      agent: agent,
      context: context
    } do
      plan_date = Date.to_iso8601(DateTime.to_date(context.timestamp))

      {:ok, [_insight]} =
        Insights.record_many(@user_id, agent.id, [
          %{
            "source" => "github",
            "category" => "product_opportunity",
            "title" => "Existing daily roadmap idea",
            "summary" => "A prior run already created today's plan.",
            "recommended_action" => "Do not generate another one today.",
            "priority" => 88,
            "confidence" => 0.91,
            "dedupe_key" => "github_feature_plan:#{@repo_full_name}:#{plan_date}:existing:1"
          }
        ])

      state =
        GitHubProductPlanner.init(%{
          "user_id" => @user_id,
          "repo_full_name" => @repo_full_name,
          "base_branch" => "main",
          "feature_limit" => "3"
        })

      assert {:idle, returned_state} = GitHubProductPlanner.handle_wakeup(state, context)
      assert returned_state.pending_snapshot == nil
      assert returned_state.pending_plan_date == nil
    end
  end

  describe "handle_effect_result/3" do
    test "persists roadmap insights with telegram metadata", %{context: context} do
      latest_commit_at = DateTime.utc_now() |> DateTime.truncate(:second)

      state =
        GitHubProductPlanner.init(%{
          "user_id" => @user_id,
          "repo_full_name" => @repo_full_name,
          "base_branch" => "main",
          "feature_limit" => "3"
        })

      pending_snapshot = %{
        repo_full_name: @repo_full_name,
        base_branch: "main",
        latest_commit_sha: "abc123",
        latest_commit_at: latest_commit_at,
        latest_commit_message: "Build Telegram roadmap summaries"
      }

      llm_response = %{
        content:
          Jason.encode!([
            %{
              "title" => "Daily roadmap digest in Telegram",
              "summary" =>
                "Give founders one daily message with the next feature bets grounded in open work and recent commits.",
              "recommended_action" =>
                "Ship a daily digest that groups 2-3 recommendations by user impact and urgency.",
              "priority" => 93,
              "confidence" => 0.92,
              "why_now" =>
                "Recent commits and issues show the team is already investing in agent notifications and planning UX.",
              "follow_up_ideas" => [
                "Let operators convert a suggestion into a tracked issue.",
                "Show the evidence links directly in the Telegram card."
              ],
              "evidence" => [
                "Commit: Build Telegram roadmap summaries",
                "Issue: Add a roadmap digest agent"
              ],
              "telegram_fit_score" => 0.99,
              "telegram_fit_reason" => "A compact daily shortlist is ideal for Telegram."
            },
            %{
              "title" => "Repository health trendline",
              "summary" =>
                "Explain whether delivery pace and issue flow are improving so roadmap decisions have more context.",
              "recommended_action" =>
                "Add a lightweight trendline view to compare commit velocity, open issues, and shipped planner ideas.",
              "priority" => 84,
              "confidence" => 0.86,
              "why_now" =>
                "The planner now has enough repository context to make comparisons over time.",
              "follow_up_ideas" => ["Show trend direction in the dashboard."],
              "evidence" => ["Open PR: Build Telegram roadmap summaries"],
              "telegram_fit_score" => 0.95,
              "telegram_fit_reason" =>
                "Daily PM review should include trajectory, not just isolated ideas."
            }
          ])
      }

      {:emit, {:insights_recorded, payload}, returned_state} =
        GitHubProductPlanner.handle_effect_result(
          {:llm_call, llm_response},
          %{state | pending_snapshot: pending_snapshot, pending_plan_date: "2026-03-10"},
          context
        )

      insights = Insights.list_recent_for_user(@user_id, limit: 5)
      titles = Enum.map(insights, & &1.title)
      roadmap_insight = Enum.find(insights, &(&1.title == "Daily roadmap digest in Telegram"))

      assert payload.count == 2
      assert payload.user_id == @user_id
      assert payload.categories == ["product_opportunity"]
      assert returned_state.pending_snapshot == nil
      assert returned_state.pending_plan_date == nil
      assert "Daily roadmap digest in Telegram" in titles
      assert "Repository health trendline" in titles
      assert roadmap_insight.category == "product_opportunity"
      assert roadmap_insight.metadata["repo_full_name"] == @repo_full_name
      assert roadmap_insight.metadata["base_branch"] == "main"
      assert roadmap_insight.metadata["planner_type"] == "github_product_planner"
      assert roadmap_insight.metadata["latest_commit_sha"] == "abc123"
      assert roadmap_insight.metadata["telegram_fit_score"] == 0.99
      assert roadmap_insight.metadata["why_now"] =~ "Recent commits and issues"

      assert roadmap_insight.metadata["follow_up_ideas"] == [
               "Let operators convert a suggestion into a tracked issue.",
               "Show the evidence links directly in the Telegram card."
             ]
    end
  end

  defp expect_repo_snapshot_requests(bypass) do
    Bypass.expect_once(bypass, "GET", "/repos/acme/widgets", fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer github-token"]

      json_response(conn, 200, %{
        "name" => "widgets",
        "full_name" => "acme/widgets",
        "description" => "Acme Widgets",
        "homepage" => "https://acme.test/widgets",
        "language" => "Elixir",
        "stargazers_count" => 42,
        "open_issues_count" => 7,
        "default_branch" => "main",
        "topics" => ["agents", "planning", "telegram"]
      })
    end)

    Bypass.expect_once(bypass, "GET", "/repos/acme/widgets/commits", fn conn ->
      conn = fetch_query_params(conn)
      assert conn.params["sha"] == "main"
      assert conn.params["per_page"] == "8"

      json_response(conn, 200, [
        %{
          "sha" => "abc123",
          "html_url" => "https://github.com/acme/widgets/commit/abc123",
          "author" => %{"login" => "kent"},
          "commit" => %{
            "message" => "Build Telegram roadmap summaries\n\nMore details",
            "author" => %{"name" => "Kent", "date" => "2026-03-09T20:30:00Z"}
          }
        }
      ])
    end)

    Bypass.expect_once(bypass, "GET", "/repos/acme/widgets/issues", fn conn ->
      conn = fetch_query_params(conn)
      assert conn.params["state"] == "open"
      assert conn.params["per_page"] == "8"

      json_response(conn, 200, [
        %{
          "number" => 17,
          "title" => "Add a roadmap digest agent",
          "body" => "We need daily PM suggestions pushed to Telegram.",
          "labels" => [%{"name" => "product"}],
          "updated_at" => "2026-03-09T18:00:00Z",
          "html_url" => "https://github.com/acme/widgets/issues/17"
        }
      ])
    end)

    Bypass.expect_once(bypass, "GET", "/repos/acme/widgets/pulls", fn conn ->
      conn = fetch_query_params(conn)
      assert conn.params["state"] == "open"
      assert conn.params["base"] == "main"
      assert conn.params["per_page"] == "6"

      json_response(conn, 200, [
        %{
          "number" => 21,
          "title" => "Build Telegram roadmap summaries",
          "body" => "Adds a daily digest surface for PM suggestions.",
          "updated_at" => "2026-03-09T19:00:00Z",
          "html_url" => "https://github.com/acme/widgets/pull/21",
          "user" => %{"login" => "kent"},
          "head" => %{"ref" => "feature/telegram-roadmap"}
        }
      ])
    end)

    Bypass.expect_once(bypass, "GET", "/repos/acme/widgets/contents", fn conn ->
      conn = fetch_query_params(conn)
      assert conn.params["ref"] == "main"

      json_response(conn, 200, [
        %{"path" => "README.md", "type" => "file", "size" => 1_200},
        %{"path" => "lib", "type" => "dir", "size" => 0},
        %{"path" => "test", "type" => "dir", "size" => 0}
      ])
    end)

    Bypass.expect_once(bypass, "GET", "/repos/acme/widgets/readme", fn conn ->
      conn = fetch_query_params(conn)
      assert conn.params["ref"] == "main"

      json_response(conn, 200, %{
        "encoding" => "base64",
        "content" =>
          Base.encode64("""
          # README

          Ship daily PM planning suggestions to Telegram so operators can act on them quickly.
          """)
      })
    end)
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
