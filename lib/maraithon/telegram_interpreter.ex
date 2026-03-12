defmodule Maraithon.TelegramInterpreter do
  @moduledoc """
  Model-driven interpretation of Telegram replies and general chat.
  """

  alias Maraithon.Insights
  alias Maraithon.LLM
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  require Logger

  @default_result %{
    "intent" => "unknown",
    "confidence" => 0.0,
    "scope" => "thread_local",
    "needs_clarification" => false,
    "clarifying_question" => nil,
    "assistant_reply" =>
      "I’m not fully sure what you mean yet. Can you clarify what you want me to change or do?",
    "candidate_rules" => [],
    "candidate_action" => nil,
    "feedback_target" => %{"delivery_id" => nil, "insight_id" => nil},
    "memory_summary_updates" => [],
    "explanation" => "Low-confidence fallback."
  }

  def interpret(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    llm_complete = Keyword.get(opts, :llm_complete) || configured_llm_complete()

    prompt = build_prompt(user_id, attrs)

    with {:ok, response} <- llm_complete.(prompt),
         {:ok, %{} = parsed} <- decode_json(response) do
      {:ok, normalize_result(parsed, attrs)}
    else
      {:error, reason} ->
        Logger.warning("Telegram interpretation failed", reason: inspect(reason))
        {:ok, fallback_result(attrs)}
    end
  end

  def build_prompt(user_id, attrs) do
    conversation = Map.get(attrs, :conversation) || %{}
    delivery = Map.get(attrs, :delivery)
    insight = Map.get(attrs, :insight)
    text = Map.get(attrs, :text, "")
    recent_turns = Map.get(attrs, :recent_turns, [])

    open_insights =
      Insights.list_open_for_user(user_id, limit: 8)
      |> Enum.map(
        &%{
          id: &1.id,
          source: &1.source,
          title: &1.title,
          summary: &1.summary,
          recommended_action: &1.recommended_action,
          priority: &1.priority,
          confidence: &1.confidence
        }
      )

    """
    You are Maraithon's Telegram conversation interpreter.

    Return ONLY valid JSON:
    {
      "intent":"feedback_specific|feedback_general|preference_create|preference_update|preference_reject|action_execute|action_redraft|action_cancel|question_about_insight|clarification_answer|general_chat|unknown",
      "confidence":0.0,
      "scope":"thread_local|durable|general",
      "needs_clarification":false,
      "clarifying_question":null,
      "assistant_reply":"short Telegram reply",
      "candidate_rules":[
        {
          "id":"snake_case_id",
          "kind":"content_filter|urgency_boost|quiet_hours|routing_preference|action_preference|style_preference",
          "label":"short label",
          "instruction":"durable instruction",
          "applies_to":["gmail","calendar","slack","telegram"],
          "confidence":0.0,
          "filters":{},
          "evidence":[]
        }
      ],
      "candidate_action":{
        "action":"draft|send|redraft|cancel|done|dismiss|snooze|explain|status",
        "confidence":0.0,
        "requires_confirmation":true,
        "reason":"why"
      },
      "feedback_target":{"delivery_id":null,"insight_id":null},
      "memory_summary_updates":[],
      "explanation":"short reasoning"
    }

    Current user memory JSON:
    #{Jason.encode!(PreferenceMemory.prompt_context(user_id))}

    Operator summaries JSON:
    #{Jason.encode!(OperatorMemory.summaries_for_prompt(user_id))}

    Open insights JSON:
    #{Jason.encode!(open_insights)}

    Conversation JSON:
    #{Jason.encode!(%{id: Map.get(conversation, :id) || Map.get(conversation, "id"), status: Map.get(conversation, :status) || Map.get(conversation, "status"), summary: Map.get(conversation, :summary) || Map.get(conversation, "summary")})}

    Recent turns JSON:
    #{Jason.encode!(Enum.map(recent_turns, fn turn -> %{role: Map.get(turn, :role) || Map.get(turn, "role"), text: Map.get(turn, :text) || Map.get(turn, "text"), intent: Map.get(turn, :intent) || Map.get(turn, "intent"), confidence: Map.get(turn, :confidence) || Map.get(turn, "confidence")} end))}

    Linked delivery JSON:
    #{Jason.encode!(delivery_payload(delivery))}

    Linked insight JSON:
    #{Jason.encode!(insight_payload(insight))}

    Operator message:
    #{text}

    Rules:
    - Use reasoning, not keyword heuristics.
    - Distinguish one-off thread feedback from durable preferences.
    - Ask clarifying questions if ambiguity remains.
    - If the user is clearly asking to send or rewrite something, use candidate_action.
    - If the user is asking why a suggestion mattered, use intent question_about_insight.
    - If the user is asking generally what they owe, use general_chat and answer from open insights.
    - If you infer a durable preference from feedback, assistant_reply should explicitly acknowledge the lesson in plain language and say how Maraithon will treat similar items next time.
    - Auto-save safety is enforced by the app, but your confidence must reflect your certainty.
    """
  end

  defp configured_llm_complete do
    case Application.get_env(:maraithon, :telegram_interpreter, [])[:llm_complete] do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        &default_llm_complete/1
    end
  end

  defp default_llm_complete(prompt) when is_binary(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 1200,
      "temperature" => 0.1,
      "reasoning_effort" => "medium"
    }

    with {:ok, response} <- LLM.provider().complete(params) do
      {:ok, response.content}
    end
  end

  defp decode_json(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_json}
    end
  end

  defp normalize_result(result, attrs) do
    feedback_target =
      result
      |> Map.get("feedback_target", %{})
      |> Map.put_new("delivery_id", delivery_id(attrs))
      |> Map.put_new("insight_id", insight_id(attrs))

    @default_result
    |> Map.merge(result)
    |> Map.put("confidence", normalize_confidence(Map.get(result, "confidence")))
    |> Map.put("candidate_rules", normalize_rules(Map.get(result, "candidate_rules")))
    |> Map.put("feedback_target", feedback_target)
  end

  defp normalize_rules(rules) when is_list(rules), do: rules
  defp normalize_rules(_), do: []

  defp normalize_confidence(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> 0.0
    end
  end

  defp normalize_confidence(_), do: 0.0

  defp fallback_result(attrs) do
    case {delivery_id(attrs), insight_id(attrs)} do
      {delivery_id, insight_id} when is_binary(delivery_id) or is_binary(insight_id) ->
        @default_result
        |> Map.put("intent", "question_about_insight")
        |> Map.put("confidence", 0.35)
        |> Map.put(
          "assistant_reply",
          "I can help with this item. Tell me if you want me to explain it, draft a reply, or learn a rule from it."
        )
        |> Map.put("feedback_target", %{"delivery_id" => delivery_id, "insight_id" => insight_id})

      _ ->
        @default_result
        |> Map.put("intent", "general_chat")
        |> Map.put("confidence", 0.25)
        |> Map.put(
          "assistant_reply",
          "I can help review what you owe, explain a suggestion, or learn a preference. Tell me what you want to change."
        )
    end
  end

  defp delivery_payload(%{id: id} = delivery) do
    %{
      id: id,
      status: Map.get(delivery, :status),
      metadata: Map.get(delivery, :metadata),
      score: Map.get(delivery, :score),
      threshold: Map.get(delivery, :threshold)
    }
  end

  defp delivery_payload(_), do: %{}

  defp insight_payload(%{id: id} = insight) do
    %{
      id: id,
      source: Map.get(insight, :source),
      category: Map.get(insight, :category),
      title: Map.get(insight, :title),
      summary: Map.get(insight, :summary),
      recommended_action: Map.get(insight, :recommended_action),
      priority: Map.get(insight, :priority),
      confidence: Map.get(insight, :confidence),
      metadata: Map.get(insight, :metadata)
    }
  end

  defp insight_payload(_), do: %{}

  defp delivery_id(attrs) do
    case Map.get(attrs, :delivery) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp insight_id(attrs) do
    case Map.get(attrs, :insight) do
      %{id: id} -> id
      _ -> nil
    end
  end
end
