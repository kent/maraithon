defmodule Maraithon.TelegramAssistant.Client.LLMJson do
  @moduledoc """
  JSON-contract model client for the Telegram assistant loop.
  """

  @behaviour Maraithon.TelegramAssistant.Client

  alias Maraithon.LLM

  @max_tool_calls_per_step 3
  @fallback_response %{
    "status" => "final",
    "assistant_message" =>
      "I need a moment to recover. Ask again or tell me exactly what you want me to inspect.",
    "message_class" => "system_notice",
    "tool_calls" => [],
    "summary" => "Fallback response used because the model output was invalid."
  }

  @impl true
  def next_step(payload) when is_map(payload) do
    prompt = build_prompt(payload)

    params = %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => 1800,
      "temperature" => 0.2,
      "reasoning_effort" => "medium"
    }

    with {:ok, response} <- LLM.provider().complete(params),
         {:ok, decoded} <- decode_json(response.content) do
      {:ok, normalize(decoded)}
    end
  end

  def build_prompt(payload) do
    """
    Return ONLY valid JSON with this exact shape:
    {
      "status":"tool_calls|final",
      "assistant_message":"short Telegram-ready text or empty string if requesting tools",
      "message_class":"assistant_reply|approval_prompt|action_result|system_notice",
      "tool_calls":[
        {"tool":"tool_name","arguments":{}}
      ],
      "summary":"short reasoning summary"
    }

    Rules:
    - Use tool calls when you need connected-account data, agent data, or action execution.
    - Never invent tool names. Use only the tools listed below.
    - Use at most #{@max_tool_calls_per_step} tool calls in one response.
    - If a tool returns an awaiting-confirmation action, the next final response should be an `approval_prompt`.
    - If a non-destructive agent control tool already executed, return `action_result`.
    - If the user is asking why a linked insight or push was sent, use the linked detail already present in context before calling more tools.
    - The assistant is a single operator assistant for one linked user. No cross-user access.
    - Keep replies concise and operational.

    Context snapshot JSON:
    #{Jason.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Available tools JSON:
    #{Jason.encode!(Map.get(payload, :tools) || Map.get(payload, "tools") || [])}

    Tool/result history JSON:
    #{Jason.encode!(Map.get(payload, :tool_history) || Map.get(payload, "tool_history") || [])}

    Iteration JSON:
    #{Jason.encode!(%{iteration: Map.get(payload, :iteration) || Map.get(payload, "iteration") || 1, llm_turns: Map.get(payload, :llm_turns) || Map.get(payload, "llm_turns") || 0, tool_steps: Map.get(payload, :tool_steps) || Map.get(payload, "tool_steps") || 0})}
    """
  end

  defp system_prompt do
    """
    You are Maraithon, a Telegram operator assistant. You can inspect connected systems, inspect and control agents, and prepare safe actions for confirmation.
    """
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

  defp normalize(%{} = parsed) do
    status =
      case Map.get(parsed, "status") || Map.get(parsed, "type") do
        "tool_calls" -> "tool_calls"
        _ -> "final"
      end

    %{
      "status" => status,
      "assistant_message" => normalize_message(Map.get(parsed, "assistant_message")),
      "message_class" => normalize_message_class(Map.get(parsed, "message_class")),
      "tool_calls" => normalize_tool_calls(Map.get(parsed, "tool_calls")),
      "summary" => normalize_message(Map.get(parsed, "summary"))
    }
  end

  defp normalize(_parsed), do: @fallback_response

  defp normalize_message_class(value)
       when value in ["assistant_reply", "approval_prompt", "action_result", "system_notice"],
       do: value

  defp normalize_message_class(_value), do: "assistant_reply"

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.take(@max_tool_calls_per_step)
    |> Enum.flat_map(fn
      %{"tool" => tool, "arguments" => arguments} when is_binary(tool) and is_map(arguments) ->
        [%{"tool" => tool, "arguments" => arguments}]

      %{"name" => tool, "arguments" => arguments} when is_binary(tool) and is_map(arguments) ->
        [%{"tool" => tool, "arguments" => arguments}]

      _ ->
        []
    end)
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp normalize_message(value) when is_binary(value), do: String.trim(value)
  defp normalize_message(_value), do: ""
end
