defmodule Maraithon.Insights.RefreshTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Insights
  alias Maraithon.Insights.Refresh

  defmodule RuntimeStub do
    def send_message(agent_id, message, metadata) do
      send(self(), {:refresh_message, agent_id, message, metadata})

      case Process.get(:refresh_fail_agent_id) do
        ^agent_id -> {:error, :agent_stopped}
        _ -> {:ok, %{message_id: "msg-" <> String.slice(agent_id, 0, 8)}}
      end
    end
  end

  setup do
    user_id = "refresh-user@example.com"

    {:ok, founder_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{},
        status: "running"
      })

    {:ok, chief_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "running"
      })

    {:ok, slack_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "slack_followthrough_agent",
        config: %{},
        status: "degraded"
      })

    {:ok, github_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "github_product_planner",
        config: %{},
        status: "stopped"
      })

    {:ok, prompt_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        status: "running"
      })

    %{
      user_id: user_id,
      founder_agent: founder_agent,
      chief_agent: chief_agent,
      slack_agent: slack_agent,
      github_agent: github_agent,
      prompt_agent: prompt_agent
    }
  end

  test "queue_for_user/2 targets only running insight-producing agents", %{
    user_id: user_id,
    founder_agent: founder_agent,
    chief_agent: chief_agent,
    slack_agent: slack_agent,
    github_agent: github_agent,
    prompt_agent: prompt_agent
  } do
    founder_agent_id = founder_agent.id
    chief_agent_id = chief_agent.id
    slack_agent_id = slack_agent.id

    Process.put(:refresh_fail_agent_id, slack_agent.id)
    on_exit(fn -> Process.delete(:refresh_fail_agent_id) end)

    {:ok, result} =
      Refresh.queue_for_user(user_id,
        runtime_module: RuntimeStub,
        requested_by: "admin_api",
        reason: "rebuild_after_logic_change"
      )

    assert result.user_id == user_id
    assert result.eligible_count == 4
    assert result.queued_count == 2

    assert Enum.any?(result.queued, fn queued ->
             queued.agent_id == founder_agent.id and
               queued.behavior == "founder_followthrough_agent"
           end)

    assert Enum.any?(result.queued, fn queued ->
             queued.agent_id == chief_agent.id and queued.behavior == "ai_chief_of_staff"
           end)

    assert Enum.any?(result.skipped, fn skipped ->
             skipped.agent_id == slack_agent.id and skipped.reason == "agent_stopped"
           end)

    assert Enum.any?(result.skipped, fn skipped ->
             skipped.agent_id == github_agent.id and skipped.reason == "agent_not_running"
           end)

    refute Enum.any?(result.queued, &(&1.agent_id == prompt_agent.id))
    refute Enum.any?(result.skipped, &(&1.agent_id == prompt_agent.id))

    assert_receive {:refresh_message, ^founder_agent_id, "refresh_insights", founder_metadata}
    assert founder_metadata["action"] == "refresh_insights"
    assert founder_metadata["reset_open_insights"] == true
    assert founder_metadata["target_user_id"] == user_id

    assert_receive {:refresh_message, ^chief_agent_id, "refresh_insights", chief_metadata}
    assert chief_metadata["requested_by"] == "admin_api"

    assert_receive {:refresh_message, ^slack_agent_id, "refresh_insights", slack_metadata}
    assert slack_metadata["reason"] == "rebuild_after_logic_change"
  end

  test "reset_open_insights_for_agent/3 dismisses existing open insights for one agent", %{
    user_id: user_id,
    founder_agent: founder_agent,
    slack_agent: slack_agent
  } do
    {:ok, [new_insight]} =
      Insights.record_many(user_id, founder_agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply to finance",
          "summary" => "A response is still outstanding.",
          "recommended_action" => "Reply now.",
          "dedupe_key" => "refresh:new"
        }
      ])

    {:ok, [snoozed_insight]} =
      Insights.record_many(user_id, founder_agent.id, [
        %{
          "source" => "slack",
          "category" => "commitment_unresolved",
          "title" => "Send the recap",
          "summary" => "The recap still appears open.",
          "recommended_action" => "Send the recap.",
          "dedupe_key" => "refresh:snoozed"
        }
      ])

    {:ok, _} =
      Insights.snooze(user_id, snoozed_insight.id, DateTime.add(DateTime.utc_now(), -60, :second))

    {:ok, [acknowledged_insight]} =
      Insights.record_many(user_id, founder_agent.id, [
        %{
          "source" => "calendar",
          "category" => "meeting_follow_up",
          "title" => "Send the board notes",
          "summary" => "Board notes were requested.",
          "recommended_action" => "Send the notes.",
          "dedupe_key" => "refresh:ack"
        }
      ])

    {:ok, _} = Insights.acknowledge(user_id, acknowledged_insight.id)

    {:ok, [other_agent_insight]} =
      Insights.record_many(user_id, slack_agent.id, [
        %{
          "source" => "slack",
          "category" => "reply_urgent",
          "title" => "Reply in Slack",
          "summary" => "Slack thread still needs you.",
          "recommended_action" => "Reply in Slack.",
          "dedupe_key" => "refresh:other-agent"
        }
      ])

    assert 2 =
             Refresh.reset_open_insights_for_agent(
               user_id,
               founder_agent.id,
               "founder_followthrough_agent"
             )

    assert Repo.reload(new_insight).status == "dismissed"
    assert Repo.reload(snoozed_insight).status == "dismissed"
    assert Repo.reload(acknowledged_insight).status == "acknowledged"
    assert Repo.reload(other_agent_insight).status == "new"
  end
end
