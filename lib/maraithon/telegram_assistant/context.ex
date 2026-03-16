defmodule Maraithon.TelegramAssistant.Context do
  @moduledoc """
  Builds the compact Telegram assistant context snapshot for one run.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Insights.Detail
  alias Maraithon.OAuth
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Travel

  def build(attrs) when is_map(attrs) do
    user_id = fetch_string!(attrs, :user_id)
    conversation = Map.get(attrs, :conversation)
    linked_delivery = Map.get(attrs, :linked_delivery)
    linked_insight = Map.get(attrs, :linked_insight)
    linked_travel = linked_travel_itinerary(conversation, user_id)

    %{
      user: %{id: user_id},
      chat: %{id: fetch_string!(attrs, :chat_id)},
      conversation: serialize_conversation(conversation),
      linked_item: serialize_linked_item(linked_delivery, linked_insight, linked_travel),
      recent_turns: serialize_recent_turns(conversation),
      preference_memory: PreferenceMemory.prompt_context(user_id),
      operator_memory: OperatorMemory.summaries_for_prompt(user_id),
      open_insights: serialize_open_insights(user_id),
      connected_accounts: serialize_connected_accounts(user_id),
      active_agents: serialize_agents(user_id),
      defaults: tool_defaults(user_id)
    }
  end

  def prompt_snapshot(context) when is_map(context), do: context

  defp serialize_conversation(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      status: conversation.status,
      summary: conversation.summary,
      mode: get_in(conversation.metadata || %{}, ["mode"]),
      linked_delivery_id: conversation.linked_delivery_id,
      linked_insight_id: conversation.linked_insight_id,
      travel_itinerary_id: get_in(conversation.metadata || %{}, ["travel_itinerary_id"]),
      latest_prepared_action_id:
        get_in(conversation.metadata || %{}, ["latest_prepared_action_id"])
    }
  end

  defp serialize_conversation(_conversation), do: %{}

  defp serialize_recent_turns(%Conversation{} = conversation) do
    TelegramConversations.recent_turns(conversation, limit: 8)
    |> Enum.map(fn turn ->
      %{
        role: turn.role,
        turn_kind: turn.turn_kind,
        origin_type: turn.origin_type,
        text: turn.text,
        intent: turn.intent,
        inserted_at: turn.inserted_at
      }
    end)
  end

  defp serialize_recent_turns(_conversation), do: []

  defp serialize_linked_item(%Delivery{} = delivery, linked_insight, linked_travel) do
    insight = linked_insight || Repo.preload(delivery, :insight).insight
    deliveries = insight_deliveries(insight, delivery.user_id)
    detail = insight && Detail.build(insight, deliveries)

    %{
      delivery: serialize_delivery(delivery),
      insight: serialize_insight(insight),
      detail: detail && serialize_detail(detail),
      travel: linked_travel && Travel.serialize_for_prompt(linked_travel)
    }
  end

  defp serialize_linked_item(_delivery, nil, nil), do: %{}

  defp serialize_linked_item(_delivery, nil, linked_travel) do
    %{
      delivery: nil,
      insight: nil,
      detail: nil,
      travel: Travel.serialize_for_prompt(linked_travel)
    }
  end

  defp serialize_linked_item(_delivery, insight, linked_travel) do
    deliveries = insight_deliveries(insight, insight.user_id)
    detail = Detail.build(insight, deliveries)

    %{
      delivery: nil,
      insight: serialize_insight(insight),
      detail: serialize_detail(detail),
      travel: linked_travel && Travel.serialize_for_prompt(linked_travel)
    }
  end

  defp serialize_open_insights(user_id) do
    Insights.list_open_with_details_for_user(user_id, limit: 6)
    |> Enum.map(fn %{insight: insight, detail: detail} ->
      %{
        id: insight.id,
        source: insight.source,
        category: insight.category,
        title: insight.title,
        summary: insight.summary,
        recommended_action: insight.recommended_action,
        priority: insight.priority,
        confidence: insight.confidence,
        detail: serialize_detail(detail)
      }
    end)
  end

  defp serialize_connected_accounts(user_id) do
    ConnectedAccounts.list_for_user(user_id)
    |> Enum.map(fn account ->
      %{
        provider: account.provider,
        status: account.status,
        scopes: account.scopes,
        metadata: redact_account_metadata(account.metadata || %{})
      }
    end)
  end

  defp serialize_agents(user_id) do
    Agents.list_agents(user_id: user_id)
    |> Enum.map(fn agent ->
      %{
        id: agent.id,
        behavior: agent.behavior,
        status: agent.status,
        name: get_in(agent.config || %{}, ["name"]),
        subscriptions: get_in(agent.config || %{}, ["subscribe"]) || [],
        tools: get_in(agent.config || %{}, ["tools"]) || [],
        updated_at: agent.updated_at
      }
    end)
  end

  defp tool_defaults(user_id) do
    oauth_providers = OAuth.list_user_tokens(user_id) |> Enum.map(& &1.provider)
    slack_team_ids = extract_slack_team_ids(oauth_providers)

    %{
      default_slack_team_id: List.first(slack_team_ids),
      slack_team_ids: slack_team_ids,
      linear_connected: Enum.member?(oauth_providers, "linear"),
      provider_ids: oauth_providers
    }
  end

  defp serialize_delivery(%Delivery{} = delivery) do
    %{
      id: delivery.id,
      channel: delivery.channel,
      score: delivery.score,
      threshold: delivery.threshold,
      status: delivery.status,
      sent_at: delivery.sent_at,
      feedback: delivery.feedback,
      metadata: Map.take(delivery.metadata || %{}, ["telegram_message_id", "telegram_action"])
    }
  end

  defp serialize_delivery(_delivery), do: nil

  defp serialize_insight(nil), do: nil

  defp serialize_insight(insight) do
    %{
      id: insight.id,
      source: insight.source,
      category: insight.category,
      title: insight.title,
      summary: insight.summary,
      recommended_action: insight.recommended_action,
      priority: insight.priority,
      confidence: insight.confidence,
      status: insight.status,
      metadata: redact_insight_metadata(insight.metadata || %{})
    }
  end

  defp serialize_detail(detail) when is_map(detail) do
    %{
      promise_text: detail[:promise_text],
      requested_by: detail[:requested_by],
      evidence_checked: detail[:evidence_checked],
      delivery_evidence: detail[:delivery_evidence],
      open_loop_reason: detail[:open_loop_reason],
      data_gaps: detail[:data_gaps]
    }
  end

  defp insight_deliveries(nil, _user_id), do: []

  defp insight_deliveries(insight, user_id)
       when is_binary(insight.id) and is_binary(user_id) do
    Delivery
    |> where([delivery], delivery.insight_id == ^insight.id and delivery.user_id == ^user_id)
    |> order_by([delivery], desc_nulls_last: delivery.sent_at, desc: delivery.inserted_at)
    |> Repo.all()
  end

  defp redact_account_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop(["access_token", "refresh_token", "token", "bot_token"])
    |> Map.take([
      "chat_id",
      "username",
      "email",
      "account_email",
      "workspace_id",
      "workspace_name",
      "team_id",
      "default_team_id",
      "login",
      "name",
      "connected_via"
    ])
  end

  defp redact_account_metadata(_metadata), do: %{}

  defp redact_insight_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [
      "account",
      "thread_id",
      "subject",
      "to",
      "from",
      "detail",
      "record",
      "context_brief",
      "source_ref"
    ])
  end

  defp redact_insight_metadata(_metadata), do: %{}

  defp extract_slack_team_ids(providers) when is_list(providers) do
    providers
    |> Enum.flat_map(fn
      "slack:" <> rest ->
        case String.split(rest, ":") do
          [team_id | _] when team_id != "" -> [team_id]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp linked_travel_itinerary(%Conversation{} = conversation, user_id) do
    case get_in(conversation.metadata || %{}, ["travel_itinerary_id"]) do
      itinerary_id when is_binary(itinerary_id) ->
        Travel.get_itinerary_for_user(user_id, itinerary_id)

      _ ->
        nil
    end
  end

  defp linked_travel_itinerary(_conversation, _user_id), do: nil

  defp fetch_string!(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    cond do
      is_binary(value) and value != "" -> value
      is_integer(value) -> Integer.to_string(value)
      true -> raise ArgumentError, "missing required context key #{inspect(key)}"
    end
  end
end
