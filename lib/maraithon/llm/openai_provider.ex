defmodule Maraithon.LLM.OpenAIProvider do
  @moduledoc """
  OpenAI Responses API provider.
  """

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.Spend

  require Logger

  @default_base_url "https://api.openai.com/v1/responses"
  @default_retry_after_ms 60_000
  @reasoning_efforts ~w(low medium high xhigh)

  @impl true
  def complete(params) do
    api_key = Maraithon.LLM.openai_api_key()

    unless api_key do
      {:error, "OPENAI_API_KEY not configured"}
    else
      do_complete(params, api_key)
    end
  end

  defp do_complete(params, api_key) do
    model = params["model"] || Maraithon.LLM.openai_model()
    timeout = params["timeout_ms"] || 120_000

    body = %{
      model: model,
      input: build_input(params["messages"] || []),
      max_output_tokens: params["max_tokens"] || params["max_output_tokens"] || 2048,
      reasoning: %{
        effort: reasoning_effort(params)
      }
    }

    Logger.info("Calling OpenAI Responses API",
      model: model,
      message_count: length(params["messages"] || []),
      reasoning_effort: body.reasoning.effort
    )

    case Req.post(base_url(),
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: 429, headers: headers, body: body}} ->
        retry_after = extract_retry_after(headers, body)
        Logger.warning("Rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenAI API timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OpenAI API network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp parse_response(response) do
    model = response["model"] || "unknown"
    content = extract_output_text(response["output"] || [])
    finish_reason = response["status"] || "unknown"
    input_tokens = get_in(response, ["usage", "input_tokens"]) || 0
    output_tokens = get_in(response, ["usage", "output_tokens"]) || 0
    usage = Spend.calculate_cost(model, input_tokens, output_tokens)

    cond do
      content != "" ->
        Logger.info("LLM call completed",
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: usage.total_cost
        )

        {:ok,
         %{
           content: content,
           model: model,
           tokens_in: input_tokens,
           tokens_out: output_tokens,
           finish_reason: finish_reason,
           usage: usage
         }}

      response["status"] == "incomplete" ->
        {:error,
         {:incomplete_response, response["incomplete_details"] || %{status: "incomplete"}}}

      true ->
        {:error, {:invalid_response, response}}
    end
  end

  defp extract_output_text(output) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => content} when is_list(content) -> content
      _ -> []
    end)
    |> Enum.map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp build_input(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{
      role: normalize_role(role),
      content: [%{type: "input_text", text: normalize_content(content)}]
    }
  end

  defp normalize_message(%{role: role, content: content}) do
    %{
      role: normalize_role(role),
      content: [%{type: "input_text", text: normalize_content(content)}]
    }
  end

  defp normalize_message(message) when is_binary(message) do
    %{
      role: "user",
      content: [%{type: "input_text", text: message}]
    }
  end

  defp normalize_message(_message) do
    %{
      role: "user",
      content: [%{type: "input_text", text: ""}]
    }
  end

  defp normalize_role(role) when role in ["system", "user", "assistant"], do: role
  defp normalize_role(role) when role in [:system, :user, :assistant], do: Atom.to_string(role)
  defp normalize_role(_role), do: "user"

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  defp normalize_content(content), do: inspect(content)

  defp reasoning_effort(%{"reasoning_effort" => effort}), do: validate_reasoning_effort(effort)

  defp reasoning_effort(%{"reasoning" => %{"effort" => effort}}),
    do: validate_reasoning_effort(effort)

  defp reasoning_effort(_params),
    do: validate_reasoning_effort(Maraithon.LLM.openai_reasoning_effort())

  defp validate_reasoning_effort(effort) when is_binary(effort) do
    normalized = String.downcase(String.trim(effort))

    if normalized in @reasoning_efforts do
      normalized
    else
      "high"
    end
  end

  defp validate_reasoning_effort(_effort), do: "high"

  defp extract_retry_after(headers, body) do
    case header_value(headers, "retry-after-ms") || header_value(headers, "retry-after") do
      nil ->
        extract_retry_after_from_body(body)

      value ->
        parse_retry_after(value)
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {^name, value} ->
        value

      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 1_000 -> parsed
      {parsed, ""} when parsed > 0 -> parsed * 1_000
      _ -> @default_retry_after_ms
    end
  end

  defp parse_retry_after(_value), do: @default_retry_after_ms

  defp extract_retry_after_from_body(%{"error" => %{"message" => message}})
       when is_binary(message) do
    case Regex.run(~r/retry after (\d+)/i, message) do
      [_, seconds] -> String.to_integer(seconds) * 1_000
      _ -> @default_retry_after_ms
    end
  end

  defp extract_retry_after_from_body(_body), do: @default_retry_after_ms

  defp base_url do
    Application.get_env(:maraithon, :openai, [])
    |> Keyword.get(:base_url, @default_base_url)
  end
end
