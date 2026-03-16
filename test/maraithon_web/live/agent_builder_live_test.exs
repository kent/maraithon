defmodule MaraithonWeb.AgentBuilderLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor

  @user_email "builder@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  describe "rendering" do
    test "highlights the Agents tab and links back to the agents workspace", %{conn: conn} do
      {:ok, view, html} = live(conn, "/agents/new")

      assert has_element?(view, "a[href='/agents'].bg-indigo-700", "Agents")
      assert html =~ "Back to agents"
    end

    test "shows clear inputs, outputs, and readiness guidance", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Create an agent with a clear contract"
      assert html =~ "What goes in"
      assert html =~ "What comes out"
      assert html =~ "Permission readiness"
      assert html =~ "Prompt Agent"
      assert html =~ "Focused setup"
      refute html =~ "Advanced JSON overrides"
    end

    test "shows blockers when inbox advisor permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element(
          "button[phx-click=choose_behavior][phx-value-behavior=\"inbox_calendar_advisor\"]"
        )
        |> render_click()

      html = render(view)

      assert html =~ "Founder Followthrough Agent"
      assert html =~ "Google Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Slack Channels"
      assert html =~ "Slack Personal DMs"
      assert html =~ "Blocked"
      assert html =~ "Resolve the highlighted blockers before launch."
    end

    test "shows blockers when AI Chief of Staff permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element("button[phx-click=choose_behavior][phx-value-behavior=\"ai_chief_of_staff\"]")
        |> render_click()

      html = render(view)

      assert html =~ "AI Chief of Staff"
      assert html =~ "Google Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Slack Channels"
      assert html =~ "Slack Personal DMs"
      assert html =~ "Telegram"
      assert html =~ "Blocked"
    end

    test "shows blockers when github product planner permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element(
          "button[phx-click=choose_behavior][phx-value-behavior=\"github_product_planner\"]"
        )
        |> render_click()

      html = render(view)

      assert html =~ "GitHub Product Planner"
      assert html =~ "GitHub"
      assert html =~ "Telegram"
      assert html =~ "Blocked"
      assert html =~ "owner/repo"
    end

    test "shows blockers when slack followthrough permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element(
          "button[phx-click=choose_behavior][phx-value-behavior=\"slack_followthrough_agent\"]"
        )
        |> render_click()

      html = render(view)

      assert html =~ "Slack Followthrough Agent"
      assert html =~ "Slack Channels"
      assert html =~ "Slack Personal DMs"
      assert html =~ "Blocked"
    end

    test "shows blockers when personal assistant permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element(
          "button[phx-click=choose_behavior][phx-value-behavior=\"personal_assistant_agent\"]"
        )
        |> render_click()

      html = render(view)

      assert html =~ "Personal Assistant Agent"
      assert html =~ "Google Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Telegram"
      assert html =~ "Blocked"
    end

    test "uses simple mode by default and reveals advanced controls on demand", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new?behavior=inbox_calendar_advisor")

      html = render(view)

      assert html =~ "Focused setup"
      assert html =~ "Coverage and spend"
      assert html =~ "Balanced"
      refute has_element?(view, "label[for=launch_email_scan_limit]")
      refute has_element?(view, "#launch_morning_brief_hour_local")
      refute html =~ "Advanced JSON overrides"

      html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      assert html =~ "Chief-of-Staff Briefing"
      assert html =~ "Email scan limit"
      assert html =~ "Advanced JSON overrides"
    end
  end

  describe "creation" do
    test "creates a prompt agent from simple mode using cost defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "prompt_agent",
            builder_mode: "simple",
            cost_profile: "lean",
            name: "lean-builder-agent",
            prompt: "Watch repo issues and summarize changes.",
            subscriptions: "github:acme/repo",
            tools: "read_file,search_files"
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.behavior == "prompt_agent"
      assert agent.config["name"] == "lean-builder-agent"
      assert agent.config["memory_limit"] == 20
      assert agent.config["budget"]["llm_calls"] == 80
      assert agent.config["budget"]["tool_calls"] == 120

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates a prompt agent and redirects to the agents workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "prompt_agent",
            name: "builder-agent",
            prompt: "Watch repo issues and summarize changes.",
            subscriptions: "github:acme/repo",
            tools: "read_file,search_files",
            memory_limit: "25",
            budget_llm_calls: "120",
            budget_tool_calls: "240",
            config_json: ""
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.behavior == "prompt_agent"
      assert agent.config["name"] == "builder-agent"
      assert agent.config["prompt"] == "Watch repo issues and summarize changes."
      assert agent.config["subscribe"] == ["github:acme/repo"]
      assert agent.config["tools"] == ["read_file", "search_files"]
      assert agent.config["memory_limit"] == 25
      assert agent.config["budget"]["llm_calls"] == 120
      assert agent.config["budget"]["tool_calls"] == 240

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates a github product planner and redirects to the agents workspace", %{conn: conn} do
      github_config = Application.get_env(:maraithon, :github, [])
      telegram_config = Application.get_env(:maraithon, :telegram, [])

      Application.put_env(
        :maraithon,
        :github,
        Keyword.merge(github_config,
          client_id: "github-client",
          client_secret: "github-secret",
          redirect_uri: "http://localhost/auth/github/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :telegram,
        Keyword.merge(telegram_config,
          bot_token: "telegram-bot-token",
          webhook_secret_path: "telegram-secret"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :github, github_config)
        Application.put_env(:maraithon, :telegram, telegram_config)
      end)

      {:ok, _token} =
        OAuth.store_tokens(@user_email, "github", %{
          access_token: "builder-github-token",
          scopes: ["repo"],
          metadata: %{login: "kent"}
        })

      {:ok, _account} =
        ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, view, _html} = live(conn, "/agents/new?behavior=github_product_planner")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "github_product_planner",
            name: "pm-planner",
            repo_full_name: "acme/widgets",
            base_branch: "main",
            feature_limit: "3",
            wakeup_interval_ms: "86400000",
            budget_llm_calls: "40",
            budget_tool_calls: "10",
            config_json: ""
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.behavior == "github_product_planner"
      assert agent.config["name"] == "pm-planner"
      assert agent.config["user_id"] == @user_email
      assert agent.config["repo_full_name"] == "acme/widgets"
      assert agent.config["base_branch"] == "main"
      assert agent.config["feature_limit"] == 3
      assert agent.config["wakeup_interval_ms"] == 86_400_000
      assert agent.config["budget"]["llm_calls"] == 40
      assert agent.config["budget"]["tool_calls"] == 10

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates a personal assistant agent when Google and Telegram are connected", %{
      conn: conn
    } do
      google_config = Application.get_env(:maraithon, :google, [])
      telegram_config = Application.get_env(:maraithon, :telegram, [])

      Application.put_env(
        :maraithon,
        :google,
        Keyword.merge(google_config,
          client_id: "google-client",
          client_secret: "google-secret",
          redirect_uri: "http://localhost/auth/google/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :telegram,
        Keyword.merge(telegram_config,
          bot_token: "telegram-bot-token",
          webhook_secret_path: "telegram-secret"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :google, google_config)
        Application.put_env(:maraithon, :telegram, telegram_config)
      end)

      {:ok, _token} =
        OAuth.store_tokens(@user_email, "google", %{
          access_token: "builder-google-token",
          scopes: Google.scopes_for(["gmail", "calendar"]),
          metadata: %{email: @user_email}
        })

      {:ok, _account} =
        ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, view, _html} = live(conn, "/agents/new?behavior=personal_assistant_agent")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "personal_assistant_agent",
            name: "travel-assistant",
            email_scan_limit: "25",
            event_scan_limit: "25",
            lookback_hours: "720",
            min_confidence: "0.8",
            timezone_offset_hours: "-5",
            wakeup_interval_ms: "1800000",
            budget_llm_calls: "40",
            budget_tool_calls: "10",
            config_json: ""
          }
        )
        |> render_submit()

      agents = Agents.list_agents(user_id: @user_email)
      agent = Enum.find(agents, &(&1.behavior == "personal_assistant_agent"))

      assert agent
      assert agent.config["name"] == "travel-assistant"
      assert agent.config["user_id"] == @user_email
      assert agent.config["email_scan_limit"] == 25
      assert agent.config["event_scan_limit"] == 25
      assert agent.config["lookback_hours"] == 720
      assert agent.config["min_confidence"] == 0.8
      assert agent.config["timezone_offset_hours"] == -5
      assert agent.config["wakeup_interval_ms"] == 1_800_000
      assert agent.config["subscribe"] == ["email:#{@user_email}", "calendar:#{@user_email}"]

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates an AI Chief of Staff agent when Google, Slack, and Telegram are connected", %{
      conn: conn
    } do
      google_config = Application.get_env(:maraithon, :google, [])
      slack_config = Application.get_env(:maraithon, :slack, [])
      telegram_config = Application.get_env(:maraithon, :telegram, [])

      Application.put_env(
        :maraithon,
        :google,
        Keyword.merge(google_config,
          client_id: "google-client",
          client_secret: "google-secret",
          redirect_uri: "http://localhost/auth/google/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :slack,
        Keyword.merge(slack_config,
          client_id: "slack-client",
          client_secret: "slack-secret",
          redirect_uri: "http://localhost/auth/slack/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :telegram,
        Keyword.merge(telegram_config,
          bot_token: "telegram-bot-token",
          webhook_secret_path: "telegram-secret"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :google, google_config)
        Application.put_env(:maraithon, :slack, slack_config)
        Application.put_env(:maraithon, :telegram, telegram_config)
      end)

      {:ok, _google_token} =
        OAuth.store_tokens(@user_email, "google", %{
          access_token: "builder-google-token",
          scopes: Google.scopes_for(["gmail", "calendar"]),
          metadata: %{email: @user_email}
        })

      {:ok, _slack_bot} =
        OAuth.store_tokens(@user_email, "slack:T12345", %{
          access_token: "xoxb-test-token",
          scopes: ["channels:read", "im:read"],
          metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
        })

      {:ok, _slack_user} =
        OAuth.store_tokens(@user_email, "slack:T12345:user:U99999", %{
          access_token: "xoxp-test-token",
          scopes: ["search:read", "im:read"],
          metadata: %{
            "team_id" => "T12345",
            "team_name" => "Agora",
            "slack_user_id" => "U99999"
          }
        })

      {:ok, _telegram_account} =
        ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, view, _html} = live(conn, "/agents/new?behavior=ai_chief_of_staff")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "ai_chief_of_staff",
            name: "chief-of-staff",
            team_id: "T12345",
            timezone_offset_hours: "-8",
            morning_brief_hour_local: "8",
            end_of_day_brief_hour_local: "18",
            weekly_review_day_local: "5",
            weekly_review_hour_local: "16",
            brief_max_items: "3",
            budget_llm_calls: "200",
            budget_tool_calls: "400",
            config_json: ""
          }
        )
        |> render_submit()

      agents = Agents.list_agents(user_id: @user_email)
      agent = Enum.find(agents, &(&1.behavior == "ai_chief_of_staff"))

      assert agent
      assert agent.config["name"] == "chief-of-staff"
      assert agent.config["user_id"] == @user_email
      assert agent.config["enabled_skills"] == ["followthrough", "travel_logistics", "briefing"]
      assert agent.config["source_policy"] == "all_connected"
      assert agent.config["include_future_sources"] == true
      assert agent.config["team_id"] == "T12345"
      assert agent.config["timezone_offset_hours"] == -8

      assert agent.config["subscribe"] == [
               "email:#{@user_email}",
               "calendar:#{@user_email}",
               "slack:T12345"
             ]

      assert get_in(agent.config, ["source_scope", "google_accounts"]) == [
               %{
                 "account_email" => @user_email,
                 "provider" => "google",
                 "services" => ["calendar", "gmail"]
               }
             ]

      assert get_in(agent.config, ["source_scope", "slack_workspaces"]) == [
               %{
                 "services" => ["channels", "dms"],
                 "team_id" => "T12345",
                 "team_name" => "Agora"
               }
             ]

      assert get_in(agent.config, ["skill_configs", "briefing", "assistant_behavior"]) ==
               "ai_chief_of_staff"

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end
  end
end
