defmodule MaraithonWeb.AgentBuilderLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor

  @user_email "builder@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  describe "rendering" do
    test "shows clear inputs, outputs, and readiness guidance", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Create an agent with a clear contract"
      assert html =~ "What goes in"
      assert html =~ "What comes out"
      assert html =~ "Permission readiness"
      assert html =~ "Prompt Agent"
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

      assert html =~ "Inbox + Calendar Advisor"
      assert html =~ "Google Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Blocked"
      assert html =~ "Resolve the highlighted blockers before launch."
    end
  end

  describe "creation" do
    test "creates a prompt agent and redirects to the dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

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

      assert {:error, {:live_redirect, %{to: "/dashboard?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end
  end
end
