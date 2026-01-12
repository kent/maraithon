defmodule Maraithon.LLM.AnthropicProvider do
  @moduledoc """
  Anthropic Claude API provider.
  """

  @behaviour Maraithon.LLM.Adapter

  require Logger

  @base_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  @impl true
  def complete(params) do
    api_key = Maraithon.LLM.api_key()

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      do_complete(params, api_key)
    end
  end

  defp do_complete(params, api_key) do
    model = params["model"] || Maraithon.LLM.model()
    messages = params["messages"] || []
    max_tokens = params["max_tokens"] || 2048
    temperature = params["temperature"] || 0.7

    body = %{
      model: model,
      messages: messages,
      max_tokens: max_tokens,
      temperature: temperature
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    timeout = params["timeout_ms"] || 120_000

    Logger.info("Calling Anthropic API",
      model: model,
      message_count: length(messages)
    )

    case Req.post(@base_url,
           json: body,
           headers: headers,
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: 429, body: body}} ->
        retry_after = extract_retry_after(body)
        Logger.warn("Rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warn("Anthropic API timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Anthropic API network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp parse_response(response) do
    content =
      case response["content"] do
        [%{"type" => "text", "text" => text} | _] -> text
        _ -> ""
      end

    {:ok,
     %{
       content: content,
       model: response["model"] || "unknown",
       tokens_in: get_in(response, ["usage", "input_tokens"]) || 0,
       tokens_out: get_in(response, ["usage", "output_tokens"]) || 0,
       finish_reason: response["stop_reason"] || "unknown"
     }}
  end

  defp extract_retry_after(body) do
    case body do
      %{"error" => %{"message" => msg}} ->
        case Regex.run(~r/retry after (\d+)/i, msg) do
          [_, seconds] -> String.to_integer(seconds) * 1000
          _ -> 60_000
        end

      _ ->
        60_000
    end
  end
end
