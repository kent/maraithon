defmodule Maraithon.OperatorMemory do
  @moduledoc """
  Long-running summarized memory for Telegram behavior, content preferences, and action style.
  """

  import Ecto.Query

  alias Maraithon.OperatorMemory.Summary
  alias Maraithon.PreferenceMemory
  alias Maraithon.PreferenceMemory.RuleEvent
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations.Turn

  @summary_types ~w(content_preferences telegram_behavior action_style interrupt_policy)

  def summaries_for_prompt(user_id) when is_binary(user_id) do
    Summary
    |> where([s], s.user_id == ^user_id)
    |> order_by([s], asc: s.summary_type)
    |> Repo.all()
    |> Enum.map(fn summary ->
      %{
        type: summary.summary_type,
        content: summary.content,
        confidence: summary.confidence,
        source_window_start: summary.source_window_start,
        source_window_end: summary.source_window_end
      }
    end)
  end

  def summaries_for_prompt(_user_id), do: []

  def refresh_user_summaries(user_id, opts \\ []) when is_binary(user_id) do
    llm_complete = Keyword.get(opts, :llm_complete) || configured_llm_complete()
    rules = PreferenceMemory.active_rules(user_id)

    base_payload = %{
      rules: rules,
      recent_feedback_examples: recent_feedback_examples(user_id),
      recent_rule_events: recent_rule_events(user_id),
      recent_conversation_turns: recent_conversation_turns(user_id)
    }

    Enum.each(@summary_types, fn summary_type ->
      content =
        case summarize(summary_type, base_payload, llm_complete) do
          {:ok, value} when is_binary(value) and value != "" -> value
          _ -> fallback_summary(summary_type, rules)
        end

      attrs = %{
        user_id: user_id,
        summary_type: summary_type,
        content: content,
        source_window_start: DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second),
        source_window_end: DateTime.utc_now(),
        confidence: if(content == fallback_summary(summary_type, rules), do: 0.6, else: 0.85)
      }

      upsert_summary(attrs)
    end)

    :ok
  end

  defp recent_feedback_examples(user_id) do
    PreferenceMemory.active_rules(user_id)
    |> Enum.map(&Map.take(&1, ["label", "instruction", "kind", "confidence"]))
  end

  defp recent_rule_events(user_id) do
    RuleEvent
    |> where([event], event.user_id == ^user_id)
    |> order_by([event], desc: event.inserted_at)
    |> limit(12)
    |> Repo.all()
    |> Enum.map(fn event ->
      %{
        event_type: event.event_type,
        payload: event.payload,
        inserted_at: event.inserted_at
      }
    end)
  end

  defp recent_conversation_turns(user_id) do
    Turn
    |> join(:inner, [turn], conversation in assoc(turn, :conversation))
    |> where([turn, conversation], conversation.user_id == ^user_id)
    |> order_by([turn, _conversation], desc: turn.inserted_at)
    |> limit(12)
    |> Repo.all()
    |> Enum.map(fn turn ->
      %{
        role: turn.role,
        text: turn.text,
        intent: turn.intent,
        confidence: turn.confidence,
        inserted_at: turn.inserted_at
      }
    end)
  end

  defp summarize(summary_type, payload, llm_complete) do
    prompt = """
    Summarize durable operator memory for Maraithon.

    Return ONLY valid JSON:
    {"content":"..."}

    Summary type: #{summary_type}
    Memory JSON:
    #{Jason.encode!(payload)}

    Rules:
    - Be concise and stable.
    - Summaries should generalize durable behavior, not one-off cases.
    - Focus on what would help a future LLM call make better choices.
    """

    with {:ok, response} <- llm_complete.(prompt),
         {:ok, %{"content" => content}} <- Jason.decode(response) do
      {:ok, String.trim(content)}
    else
      _ -> {:error, :summary_unavailable}
    end
  end

  defp fallback_summary(summary_type, rules) do
    case summary_type do
      "content_preferences" ->
        summarize_by_kind(rules, "content_filter", "No durable content-filter preferences yet.")

      "interrupt_policy" ->
        summarize_by_kind(rules, "quiet_hours", "No durable interruption policy yet.")

      "action_style" ->
        summarize_by_kind(rules, "style_preference", "No durable action-style preferences yet.")

      "telegram_behavior" ->
        rules
        |> Enum.take(3)
        |> Enum.map_join(" ", &Map.get(&1, "instruction"))
        |> case do
          "" -> "No durable Telegram behavior summary yet."
          content -> content
        end
    end
  end

  defp summarize_by_kind(rules, kind, empty_text) do
    rules
    |> Enum.filter(&(Map.get(&1, "kind") == kind))
    |> Enum.map_join(" ", &Map.get(&1, "instruction"))
    |> case do
      "" -> empty_text
      content -> content
    end
  end

  defp upsert_summary(attrs) do
    case Repo.get_by(Summary,
           user_id: Map.fetch!(attrs, :user_id),
           summary_type: Map.fetch!(attrs, :summary_type)
         ) do
      nil ->
        %Summary{}
        |> Summary.changeset(attrs)
        |> Repo.insert()

      %Summary{} = summary ->
        summary
        |> Summary.changeset(attrs)
        |> Repo.update()
    end
  end

  defp configured_llm_complete do
    config = Application.get_env(:maraithon, :operator_memory, [])

    case Keyword.get(config, :llm_complete) do
      fun when is_function(fun, 1) -> fun
      _ -> fn _prompt -> {:error, :no_llm} end
    end
  end
end
