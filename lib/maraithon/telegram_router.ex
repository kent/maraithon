defmodule Maraithon.TelegramRouter do
  @moduledoc """
  Orchestrates Telegram freeform chat, reply-thread learning, and action requests.
  """

  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications.Actions
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramInterpreter
  alias Maraithon.TelegramResponder

  require Logger

  @clarification_limit 3
  @general_chat_window_seconds 5 * 60
  @general_chat_rate_limit 20

  def handle_message(data) when is_map(data) do
    with chat_id when is_binary(chat_id) <- read_id_string(data, "chat_id"),
         text when is_binary(text) <- read_string(data, "text"),
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id) do
      reply_to_message_id =
        data
        |> fetch("reply_to")
        |> read_nested_id_string("message_id")

      source_message_id = read_id_string(data, "message_id")
      linked_delivery = linked_delivery(chat_id, reply_to_message_id)
      linked_insight = linked_delivery && linked_delivery.insight

      if general_chat_rate_limited?(chat_id, reply_to_message_id, linked_delivery) do
        send_ephemeral_reply(
          chat_id,
          source_message_id,
          "You’re sending messages quickly. Reply to the exact item you want me to act on, or wait a moment and try again."
        )
      else
        {:ok, conversation} =
          TelegramConversations.start_or_continue(user_id, chat_id, %{
            "reply_to_message_id" => reply_to_message_id,
            "root_message_id" => source_message_id || reply_to_message_id,
            "linked_delivery_id" => linked_delivery && linked_delivery.id,
            "linked_insight_id" => linked_insight && linked_insight.id
          })

        {:ok, {_conversation, user_turn}} =
          TelegramConversations.append_turn(conversation, %{
            "role" => "user",
            "telegram_message_id" => source_message_id,
            "reply_to_message_id" => reply_to_message_id,
            "text" => text
          })

        cond do
          awaiting_confirmation?(conversation) and affirmative?(text) ->
            confirm_pending_rules(conversation, user_turn, chat_id, source_message_id)

          awaiting_confirmation?(conversation) and negative?(text) ->
            reject_pending_rules(conversation, user_turn, chat_id, source_message_id)

          true ->
            interpret_and_respond(
              user_id,
              chat_id,
              text,
              source_message_id,
              conversation,
              user_turn,
              linked_delivery,
              linked_insight
            )
        end
      end
    else
      nil ->
        :ok

      _ ->
        :ok
    end
  end

  def handle_edited_message(data) when is_map(data) do
    with chat_id when is_binary(chat_id) <- read_id_string(data, "chat_id"),
         message_id when is_binary(message_id) <- read_id_string(data, "message_id"),
         text when is_binary(text) <- read_string(data, "text") do
      _ = TelegramConversations.update_turn_text(chat_id, message_id, text)
      :ok
    else
      _ -> :ok
    end
  end

  def handle_callback_query(data) when is_map(data) do
    callback_data = read_string(data, "data", "")
    callback_id = read_string(data, "callback_id")
    chat_id = read_id_string(data, "chat_id")
    message_id = read_id_string(data, "message_id")

    case TelegramResponder.parse_confirmation_callback(callback_data) do
      {:ok, conversation_id, "confirm"} ->
        handle_confirmation_callback(conversation_id, :confirm, chat_id, message_id, callback_id)

      {:ok, conversation_id, "reject"} ->
        handle_confirmation_callback(conversation_id, :reject, chat_id, message_id, callback_id)

      {:error, :invalid_callback} ->
        :ignored
    end
  end

  defp interpret_and_respond(
         user_id,
         chat_id,
         text,
         source_message_id,
         conversation,
         user_turn,
         linked_delivery,
         linked_insight
       ) do
    recent_turns = TelegramConversations.recent_turns(conversation, limit: 8)

    {:ok, interpretation} =
      TelegramInterpreter.interpret(user_id, %{
        text: text,
        conversation: conversation,
        recent_turns: recent_turns,
        delivery: linked_delivery,
        insight: linked_insight
      })

    conversation = maybe_clear_clarification(conversation, interpretation)

    case route_interpretation(
           user_id,
           chat_id,
           source_message_id,
           conversation,
           user_turn,
           linked_delivery,
           linked_insight,
           interpretation
         ) do
      {:ok, reply_text, reply_opts} ->
        send_assistant_turn(
          conversation,
          chat_id,
          source_message_id,
          reply_text,
          interpretation,
          reply_opts
        )

      :ok ->
        :ok
    end
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         conversation,
         _user_turn,
         _delivery,
         _insight,
         %{"needs_clarification" => true} = interpretation
       ) do
    ask_clarifying_question(conversation, interpretation)
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         _conversation,
         _user_turn,
         %Delivery{} = delivery,
         insight,
         %{"intent" => "question_about_insight"} = interpretation
       ) do
    {:ok, explain_insight(delivery, insight, interpretation), []}
  end

  defp route_interpretation(
         user_id,
         _chat_id,
         _source_message_id,
         conversation,
         user_turn,
         _delivery,
         _insight,
         %{"intent" => "preference_reject"} = interpretation
       ) do
    pending = pending_rule_ids(conversation)

    if pending == [] do
      {:ok,
       Map.get(
         interpretation,
         "assistant_reply",
         "I don’t have a pending rule to reject right now."
       ), []}
    else
      {:ok, _} =
        PreferenceMemory.reject_rules(user_id, pending,
          conversation_id: conversation.id,
          source_turn_id: user_turn.id
        )

      _ = TelegramConversations.close(conversation, %{"metadata" => %{"pending_rule_ids" => []}})
      {:ok, "Understood. I kept that as local feedback only and did not save a durable rule.", []}
    end
  end

  defp route_interpretation(
         user_id,
         _chat_id,
         _source_message_id,
         conversation,
         user_turn,
         _delivery,
         _insight,
         %{"candidate_rules" => rules} = interpretation
       )
       when is_list(rules) and rules != [] do
    {:ok, saved} =
      PreferenceMemory.save_interpreted_rules(
        user_id,
        rules,
        "telegram_inferred",
        conversation_id: conversation.id,
        source_turn_id: user_turn.id
      )

    active = Enum.filter(saved, &(Map.get(&1, "status") == "active"))
    pending = Enum.filter(saved, &(Map.get(&1, "status") == "pending_confirmation"))

    cond do
      pending != [] ->
        {:ok, _conversation} =
          TelegramConversations.mark_awaiting_confirmation(conversation, %{
            "metadata" => %{"pending_rule_ids" => Enum.map(pending, &Map.get(&1, "rule_id"))}
          })

        text =
          Map.get(interpretation, "assistant_reply") ||
            "I think this should become a saved rule. Should I remember it?"

        {:ok, text, [reply_markup: TelegramResponder.confirmation_markup(conversation.id)]}

      active != [] ->
        {:ok,
         Map.get(interpretation, "assistant_reply") ||
           "Understood. I saved that as a durable preference.", []}

      true ->
        {:ok,
         Map.get(interpretation, "assistant_reply") ||
           "I captured that as local feedback, but I did not save a durable rule yet.", []}
    end
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         _conversation,
         _user_turn,
         %Delivery{} = delivery,
         _insight,
         %{"candidate_action" => %{"action" => action}}
       )
       when action in [
              "draft",
              "redraft",
              "cancel",
              "done",
              "dismiss",
              "snooze",
              "explain",
              "send",
              "status",
              "create_task"
            ] do
    case action do
      "explain" ->
        {:ok, explain_insight(delivery, delivery.insight, %{"assistant_reply" => nil}), []}

      "status" ->
        {:ok, Actions.render_message(delivery), []}

      "send" ->
        with {:ok, updated_delivery, _notice} <- ensure_draft_then_send(delivery) do
          {:ok, Actions.render_message(updated_delivery), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end

      "redraft" ->
        with {:ok, updated_delivery, _notice} <- Actions.perform_action(delivery, "regenerate") do
          {:ok, Actions.render_message(updated_delivery), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end

      "create_task" ->
        with {:ok, result} <- create_linear_task(delivery) do
          {:ok, render_task_created(result), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end

      other ->
        with {:ok, updated_delivery, _notice} <- Actions.perform_action(delivery, other) do
          {:ok, Actions.render_message(updated_delivery), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end
    end
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         _conversation,
         _user_turn,
         _delivery,
         _insight,
         interpretation
       ) do
    reply =
      Map.get(interpretation, "assistant_reply") ||
        Map.get(interpretation, "clarifying_question") ||
        "I’m not sure yet. Can you clarify what you want me to learn or do?"

    {:ok, reply, []}
  end

  defp confirm_pending_rules(conversation, user_turn, chat_id, source_message_id) do
    pending = pending_rule_ids(conversation)

    {:ok, _} =
      PreferenceMemory.confirm_rules(conversation.user_id, pending,
        conversation_id: conversation.id,
        source_turn_id: user_turn.id
      )

    _ = TelegramConversations.close(conversation, %{"metadata" => %{"pending_rule_ids" => []}})

    send_assistant_turn(
      conversation,
      chat_id,
      source_message_id,
      "Understood. I saved that as a durable rule and will use it in future reasoning.",
      %{"intent" => "preference_create", "confidence" => 1.0},
      []
    )
  end

  defp reject_pending_rules(conversation, user_turn, chat_id, source_message_id) do
    pending = pending_rule_ids(conversation)

    {:ok, _} =
      PreferenceMemory.reject_rules(conversation.user_id, pending,
        conversation_id: conversation.id,
        source_turn_id: user_turn.id
      )

    _ = TelegramConversations.close(conversation, %{"metadata" => %{"pending_rule_ids" => []}})

    send_assistant_turn(
      conversation,
      chat_id,
      source_message_id,
      "Understood. I treated that as local feedback only and did not save a durable rule.",
      %{"intent" => "preference_reject", "confidence" => 1.0},
      []
    )
  end

  defp handle_confirmation_callback(conversation_id, decision, chat_id, message_id, callback_id) do
    case Repo.get(TelegramConversations.Conversation, conversation_id) do
      nil ->
        TelegramResponder.answer_callback(callback_id, "Conversation not found")

      conversation ->
        pending = pending_rule_ids(conversation)

        case decision do
          :confirm ->
            {:ok, _} =
              PreferenceMemory.confirm_rules(conversation.user_id, pending,
                conversation_id: conversation.id
              )

            _ =
              TelegramConversations.close(conversation, %{
                "metadata" => %{"pending_rule_ids" => []}
              })

            TelegramResponder.answer_callback(callback_id, "Saved")

            send_assistant_turn(
              conversation,
              chat_id,
              message_id,
              "Saved as a durable rule.",
              %{"intent" => "preference_create", "confidence" => 1.0},
              []
            )

          :reject ->
            {:ok, _} =
              PreferenceMemory.reject_rules(conversation.user_id, pending,
                conversation_id: conversation.id
              )

            _ =
              TelegramConversations.close(conversation, %{
                "metadata" => %{"pending_rule_ids" => []}
              })

            TelegramResponder.answer_callback(callback_id, "Not saved")

            send_assistant_turn(
              conversation,
              chat_id,
              message_id,
              "Okay, I kept that as local feedback only.",
              %{"intent" => "preference_reject", "confidence" => 1.0},
              []
            )
        end
    end

    :ok
  end

  defp send_assistant_turn(
         conversation,
         chat_id,
         reply_to_message_id,
         text,
         interpretation,
         reply_opts
       ) do
    case TelegramResponder.reply(chat_id, reply_to_message_id, text, reply_opts) do
      {:ok, result} ->
        {:ok, _} =
          TelegramConversations.append_turn(conversation, %{
            "role" => "assistant",
            "telegram_message_id" => normalize_id(Map.get(result, "message_id")),
            "reply_to_message_id" => reply_to_message_id,
            "text" => text,
            "intent" => Map.get(interpretation, "intent"),
            "confidence" => Map.get(interpretation, "confidence"),
            "structured_data" => interpretation
          })

        :ok

      {:error, reason} ->
        Logger.warning("Failed Telegram assistant reply", reason: inspect(reason))
        :ok
    end
  end

  defp linked_delivery(chat_id, reply_to_message_id) when is_binary(reply_to_message_id) do
    case TelegramConversations.find_by_reply(chat_id, reply_to_message_id) do
      %{linked_delivery: %Delivery{} = delivery} ->
        Repo.preload(delivery, :insight)

      %{linked_delivery_id: delivery_id} when is_binary(delivery_id) ->
        delivery_id
        |> Actions.fetch_delivery_for_chat(chat_id)
        |> case do
          {:ok, delivery} -> delivery
          _ -> nil
        end

      _ ->
        case Actions.find_delivery_by_provider_message(chat_id, reply_to_message_id) do
          {:ok, delivery} -> delivery
          _ -> nil
        end
    end
  end

  defp linked_delivery(_chat_id, _reply_to_message_id), do: nil

  defp pending_rule_ids(%{metadata: %{"pending_rule_ids" => ids}, user_id: user_id})
       when is_list(ids) do
    case Enum.filter(ids, &is_binary/1) do
      [] -> pending_rule_ids(user_id)
      scoped_ids -> scoped_ids
    end
  end

  defp pending_rule_ids(%{user_id: user_id}), do: pending_rule_ids(user_id)

  defp pending_rule_ids(user_id) when is_binary(user_id) do
    PreferenceMemory.pending_rules(user_id)
    |> Enum.map(&Map.get(&1, "rule_id"))
    |> Enum.filter(&is_binary/1)
  end

  defp pending_rule_ids(_), do: []

  defp awaiting_confirmation?(conversation), do: conversation.status == "awaiting_confirmation"

  defp affirmative?(text) when is_binary(text) do
    String.downcase(String.trim(text)) in ["yes", "y", "remember that", "save it", "do that"]
  end

  defp negative?(text) when is_binary(text) do
    String.downcase(String.trim(text)) in [
      "no",
      "n",
      "just this one",
      "don't save that",
      "do not save"
    ]
  end

  defp ensure_draft_then_send(delivery) do
    case Actions.action_state_for_delivery(delivery) do
      %{"status" => "drafted"} ->
        Actions.perform_action(delivery, "send")

      _ ->
        with {:ok, drafted_delivery, _notice} <- Actions.perform_action(delivery, "draft") do
          {:ok, drafted_delivery, "Draft ready for approval"}
        end
    end
  end

  defp general_chat_rate_limited?(chat_id, reply_to_message_id, linked_delivery)
       when is_binary(chat_id) do
    is_nil(reply_to_message_id) and is_nil(linked_delivery) and
      TelegramConversations.recent_user_turn_count(chat_id, @general_chat_window_seconds) >=
        @general_chat_rate_limit
  end

  defp general_chat_rate_limited?(_chat_id, _reply_to_message_id, _linked_delivery), do: false

  defp maybe_clear_clarification(conversation, %{"needs_clarification" => true}), do: conversation

  defp maybe_clear_clarification(%{metadata: metadata} = conversation, interpretation) do
    if Map.get(metadata || %{}, "pending_clarification") == true and
         Map.get(interpretation, "intent") != "unknown" do
      case TelegramConversations.update_metadata(conversation, %{
             "pending_clarification" => false,
             "last_clarifying_question" => nil
           }) do
        {:ok, updated_conversation} -> updated_conversation
        _ -> conversation
      end
    else
      conversation
    end
  end

  defp ask_clarifying_question(conversation, interpretation) do
    depth = clarification_depth(conversation) + 1

    if depth > @clarification_limit do
      {:ok,
       "I still can’t safely infer the right action. Reply to the exact item you mean, or tell me the precise rule or action you want.",
       []}
    else
      question =
        Map.get(interpretation, "clarifying_question") ||
          Map.get(interpretation, "assistant_reply") ||
          "Can you clarify what you want me to learn or do?"

      _ =
        TelegramConversations.update_metadata(conversation, %{
          "pending_clarification" => true,
          "clarification_depth" => depth,
          "last_clarifying_question" => question
        })

      {:ok, question, []}
    end
  end

  defp clarification_depth(%{metadata: %{"clarification_depth" => value}})
       when is_integer(value) and value >= 0,
       do: value

  defp clarification_depth(_conversation), do: 0

  defp explain_insight(%Delivery{} = delivery, insight, interpretation) do
    metadata = (insight || delivery.insight).metadata || %{}
    why_now = Map.get(metadata, "why_now") || Map.get(metadata, "context_brief")

    evidence_lines =
      metadata
      |> Map.get("record", %{})
      |> Map.get("evidence", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.take(3)

    evidence_text =
      case evidence_lines do
        [] -> "I didn’t find completion evidence after the original commitment."
        lines -> Enum.map_join(lines, "\n", fn line -> "- #{line}" end)
      end

    why_now_text =
      case why_now do
        value when is_binary(value) and value != "" -> value
        _ -> "This still appears open based on the source evidence I checked."
      end

    extra_reply =
      case Map.get(interpretation, "assistant_reply") do
        value when is_binary(value) and value != "" -> "\n\n#{value}"
        _ -> ""
      end

    """
    I surfaced this because it still looks like an open loop.

    Why now:
    #{why_now_text}

    Evidence checked:
    #{evidence_text}

    Recommended action:
    #{(insight || delivery.insight).recommended_action}#{extra_reply}
    """
    |> String.trim()
  end

  defp create_linear_task(%Delivery{} = delivery) do
    case ConnectedAccounts.get(delivery.user_id, "linear") do
      %{metadata: metadata} ->
        team_id =
          get_in(metadata || %{}, ["default_team_id"]) || get_in(metadata || %{}, ["team_id"])

        if is_binary(team_id) and String.trim(team_id) != "" do
          Maraithon.Tools.execute("linear_create_issue", %{
            "user_id" => delivery.user_id,
            "team_id" => team_id,
            "title" => delivery.insight.title,
            "description" =>
              Enum.join(
                [
                  delivery.insight.summary,
                  "",
                  "Recommended action:",
                  delivery.insight.recommended_action
                ],
                "\n"
              )
          })
        else
          {:error, "linear_default_team_missing"}
        end

      _ ->
        {:error, "linear_not_connected"}
    end
  end

  defp render_task_created(%{"issue" => %{"identifier" => identifier, "url" => url}})
       when is_binary(identifier) and is_binary(url) do
    "Created Linear task #{identifier}: #{url}"
  end

  defp render_task_created(%{"issue" => %{"identifier" => identifier}})
       when is_binary(identifier),
       do: "Created Linear task #{identifier}."

  defp render_task_created(_result), do: "Created a Linear task."

  defp action_failure_text(reason) when is_binary(reason) do
    case reason do
      "google_account_reauth_required" ->
        "I couldn't send that yet because Google needs reconnecting: #{connector_url("google")}"

      "slack_workspace_reauth_required" ->
        "I couldn't complete that because Slack needs reconnecting: #{connector_url("slack")}"

      "linear_not_connected" ->
        "I couldn't create a task because Linear isn't connected yet: #{connector_url("linear")}"

      "linear_default_team_missing" ->
        "I couldn't create a task because I don't know which Linear team to use yet."

      other ->
        "I couldn't do that yet: #{other}"
    end
  end

  defp action_failure_text(reason), do: "I couldn't do that yet: #{inspect(reason)}"

  defp connector_url(provider), do: "#{base_app_url()}/connectors/#{provider}"

  defp base_app_url do
    System.get_env("APP_BASE_URL") ||
      Application.get_env(:maraithon, :app_base_url, "https://maraithon.com")
  end

  defp send_ephemeral_reply(chat_id, reply_to_message_id, text) do
    _ = TelegramResponder.reply(chat_id, reply_to_message_id, text)
    :ok
  end

  defp read_string(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    fetch(map, key) |> normalize_id()
  end

  defp read_nested_id_string(%{} = map, key) when is_binary(key), do: read_id_string(map, key)
  defp read_nested_id_string(_, _key), do: nil

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end
end
