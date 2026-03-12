defmodule Maraithon.TelegramAssistantTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.{PreparedAction, PushReceipt, Run, Step}
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.TestSupport.CapturingTelegram
  alias Maraithon.TestSupport.TelegramAssistantClientStub

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_briefs = Application.get_env(:maraithon, :briefs, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights,
        telegram_module: CapturingTelegram,
        default_sender_name: "Kent"
      )
    )

    Application.put_env(
      :maraithon,
      :briefs,
      Keyword.merge(original_briefs, telegram_module: CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true,
        client_module: TelegramAssistantClientStub
      )
    )

    assert Maraithon.TelegramAssistant.enabled?()
    assert Maraithon.TelegramAssistant.unified_push_enabled?()

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :briefs, original_briefs)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    user_id = "telegram-assistant@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "Kent's Gmail agent", "prompt" => "Do things"}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "router uses the assistant tool loop and persists the run audit", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the deck to Sarah",
          "summary" => "You still owe Sarah the deck in Gmail.",
          "recommended_action" => "Reply in the thread with the deck.",
          "priority" => 96,
          "confidence" => 0.93,
          "dedupe_key" => "telegram-assistant:open-work:1",
          "metadata" => %{"account" => "kent@example.com"}
        }
      ])

    start_supervised!(%{
      id: :telegram_assistant_sequence,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        assert Enum.any?(payload.tools, &(&1["name"] == "get_open_work_summary"))

        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 3}}
           ],
           "summary" => "Need a fresh work summary."
         }}
      else
        [history_entry] = payload.tool_history
        assert history_entry["tool"] == "get_open_work_summary"

        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "Right now you owe Sarah the deck in Gmail. That is the highest-priority open loop I can see.",
           "message_class" => "assistant_reply",
           "tool_calls" => [],
           "summary" => "Returned the summarized open work."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9101, text: "What do I owe today?"}
      })

    reply = last_telegram_message(:send)
    assert reply.text =~ "owe Sarah the deck"

    run =
      Repo.one!(
        from run in Run,
          where: run.user_id == ^user_id,
          order_by: [desc: run.inserted_at],
          limit: 1
      )

    assert run.status == "completed"
    assert run.trigger_type == "inbound_message"
    assert get_in(run.prompt_snapshot, ["open_insights"]) != []

    steps =
      Step
      |> where([step], step.run_id == ^run.id)
      |> order_by([step], asc: step.sequence)
      |> Repo.all()

    assert Enum.any?(steps, &(&1.step_type == "context_fetch"))
    assert Enum.any?(steps, &(&1.step_type == "tool_call"))
    assert Enum.any?(steps, &(&1.step_type == "llm_response"))

    turn =
      Repo.one!(
        from turn in Turn,
          join: conversation in assoc(turn, :conversation),
          where: conversation.user_id == ^user_id and turn.turn_kind == "assistant_reply",
          order_by: [desc: turn.inserted_at],
          limit: 1
      )

    assert turn.text =~ "Sarah"
  end

  test "assistant prepares a destructive agent action and executes it after text confirmation", %{
    user_id: user_id,
    agent: agent
  } do
    start_supervised!(%{
      id: :telegram_assistant_sequence_delete,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_delete]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_delete, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{
               "tool" => "prepare_agent_action",
               "arguments" => %{"action" => "delete", "agent_id" => agent.id}
             }
           ],
           "summary" => "Prepare deletion."
         }}
      else
        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "Delete agent Kent's Gmail agent. This removes its saved definition and runtime history dependencies. Reply `yes` or use the buttons to delete it, or `no` to cancel.",
           "message_class" => "approval_prompt",
           "tool_calls" => [],
           "summary" => "Ask for confirmation."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9102, text: "Delete Kent's Gmail agent"}
      })

    approval = last_telegram_message(:send)
    assert approval.text =~ "Delete agent Kent's Gmail agent"

    prepared_action =
      Repo.one!(
        from prepared_action in PreparedAction,
          where: prepared_action.user_id == ^user_id,
          order_by: [desc: prepared_action.inserted_at],
          limit: 1
      )

    assert prepared_action.status == "awaiting_confirmation"
    assert prepared_action.action_type == "agent_delete"

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert conversation.status == "awaiting_confirmation"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9103, text: "yes"}
      })

    assert Agents.get_agent(agent.id) == nil
    assert Repo.get!(PreparedAction, prepared_action.id).status == "executed"

    result_message = last_telegram_message(:send)
    assert result_message.text == "Deleted the agent."
  end

  test "insight dispatch goes through the unified push broker and records receipts", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send Sarah the deck",
          "summary" => "Explicit promise still appears open.",
          "recommended_action" => "Reply with the deck today.",
          "priority" => 98,
          "confidence" => 0.94,
          "dedupe_key" => "telegram-assistant:push-broker:1",
          "metadata" => %{"account" => "kent@example.com"}
        }
      ])

    assert %{sent: 1, failed: 0} = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    assert delivery.status == "sent"
    assert is_binary(delivery.provider_message_id)

    receipt =
      Repo.one!(
        from receipt in PushReceipt,
          where: receipt.user_id == ^user_id,
          order_by: [desc: receipt.inserted_at],
          limit: 1
      )

    assert receipt.origin_type == "insight"
    assert receipt.decision == "sent_now"

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.linked_delivery_id == ^delivery.id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert get_in(conversation.metadata, ["mode"]) == "push_thread"

    turn =
      Repo.one!(
        from turn in Turn,
          where: turn.conversation_id == ^conversation.id,
          order_by: [desc: turn.inserted_at],
          limit: 1
      )

    assert turn.turn_kind == "assistant_push"
    assert turn.origin_type == "insight"
    assert turn.origin_id == delivery.id
  end

  defp set_assistant(fun) when is_function(fun, 1) do
    config = Application.get_env(:maraithon, :telegram_assistant, [])
    Application.put_env(:maraithon, :telegram_assistant, Keyword.put(config, :next_step, fun))
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end
end
