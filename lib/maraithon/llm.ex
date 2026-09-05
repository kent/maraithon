defmodule Maraithon.LLM do
  @moduledoc """
  LLM provider interface and configuration.
  """

  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  require Logger

  @brief_retry_reserve_ms 60_000
  @minimum_brief_retry_ms 1_000

  defp runtime_config do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
  end

  @doc """
  Get the configured LLM provider module.
  """
  def provider do
    runtime_config()
    |> Keyword.get(:llm_provider)
  end

  @doc """
  Get the configured provider name.
  """
  def provider_name do
    runtime_config()
    |> Keyword.get(:llm_provider_name, "unconfigured")
  end

  @doc """
  Get the active model.
  """
  def model do
    runtime_config()
    |> Keyword.get(:llm_model)
  end

  @doc """
  Get the active fast/routing model.

  Returns nil when no routing model is configured. Callers should fall back
  to `complete/1` (which uses the main model) when this is nil.
  """
  def routing_model do
    runtime_config()
    |> Keyword.get(:llm_routing_model)
  end

  @doc """
  Get the active chat-tier model. This is the model used by the user-facing
  Telegram assistant runner — favors low latency over deep reasoning. The
  reasoning-tier `model/0` stays for chief of staff and complex agent work.

  Falls back to `model/0` when not configured.
  """
  def chat_model do
    runtime_config()
    |> Keyword.get(:llm_chat_model)
    |> case do
      nil -> model()
      "" -> model()
      other -> other
    end
  end

  @doc """
  Get the active fast-tier model — the lowest-latency option for turns that
  clearly do not need full intelligence (acknowledgements, quick wording).

  Falls back to `chat_model/0` when not configured.
  """
  def fast_model do
    runtime_config()
    |> Keyword.get(:llm_fast_model)
    |> case do
      nil -> chat_model()
      "" -> chat_model()
      other -> other
    end
  end

  @doc """
  Get the brief-tier model: the highest-intelligence option, used for
  per-todo chief-of-staff briefs. Falls back to `model/0` when unset.
  """
  def brief_model do
    runtime_config()
    |> Keyword.get(:llm_brief_model)
    |> case do
      nil -> model()
      "" -> model()
      other -> other
    end
  end

  @doc """
  Reasoning effort for brief-tier calls. Defaults to "high".
  """
  def brief_reasoning_effort do
    runtime_config()
    |> Keyword.get(:llm_brief_reasoning_effort)
    |> case do
      value when value in [nil, ""] -> "high"
      value -> value
    end
  end

  @doc """
  Get the active reasoning/intelligence setting for model calls.
  """
  def intelligence do
    case provider_name() do
      "openai" -> openai_reasoning_effort()
      "openrouter" -> openrouter_reasoning_effort()
      _ -> runtime_config() |> Keyword.get(:llm_intelligence, openai_reasoning_effort())
    end
  end

  @doc """
  Get the active API key.
  """
  def api_key do
    runtime_config()
    |> Keyword.get(:llm_api_key)
  end

  def anthropic_model do
    runtime_config()
    |> Keyword.get(:anthropic_model, "claude-sonnet-4-20250514")
  end

  def anthropic_api_key do
    runtime_config()
    |> Keyword.get(:anthropic_api_key)
  end

  def openai_model do
    runtime_config()
    |> Keyword.get(:openai_model, "gpt-5.4")
  end

  def openai_api_key do
    runtime_config()
    |> Keyword.get(:openai_api_key)
  end

  def openai_reasoning_effort do
    runtime_config()
    |> Keyword.get(:openai_reasoning_effort, "high")
  end

  def openrouter_model do
    runtime_config()
    |> Keyword.get(:openrouter_model, "moonshotai/kimi-k3")
  end

  def openrouter_api_key do
    runtime_config()
    |> Keyword.get(:openrouter_api_key)
  end

  def openrouter_reasoning_effort do
    runtime_config()
    |> Keyword.get(:openrouter_reasoning_effort, "high")
  end

  def openrouter_http_referer do
    runtime_config()
    |> Keyword.get(:openrouter_http_referer, "https://maraithon.app")
  end

  def openrouter_app_title do
    runtime_config()
    |> Keyword.get(:openrouter_app_title, "Maraithon")
  end

  @doc """
  Complete a model request with the configured provider.
  """
  def complete(params) when is_map(params) do
    case provider() do
      nil ->
        {:error,
         {:llm_provider_not_configured,
          "No LLM provider is configured. Set LLM_PROVIDER=openai with OPENAI_API_KEY, LLM_PROVIDER=openrouter with OPENROUTER_API_KEY, or LLM_PROVIDER=anthropic with ANTHROPIC_API_KEY."}}

      module ->
        with {:ok, bounded_params} <- RequestBudget.validate(params) do
          run_provider_request(module, bounded_params, &module.complete/1)
        end
    end
  end

  @doc """
  Complete a request using the routing/fast model when configured.

  This is for cheap, latency-sensitive calls such as intent classification.
  Falls back to the primary model when no routing model is configured or
  when the caller already pinned a model in the params.
  """
  def complete_routing(params) when is_map(params) do
    case routing_model() do
      nil ->
        complete(params)

      _ when is_map_key(params, "model") ->
        complete(params)

      routing ->
        complete(Map.put(params, "model", routing))
    end
  end

  @doc """
  Complete a request using the chat-tier model. Used by the Telegram
  assistant chat runner so user-facing answers stay fast. Reasoning-heavy
  callers should keep using `complete/1`.
  """
  def complete_chat(params) when is_map(params) do
    cond do
      is_map_key(params, "model") -> complete(params)
      true -> complete(Map.put(params, "model", chat_model()))
    end
  end

  @doc """
  Complete a request on the brief tier: the highest-intelligence model at
  brief reasoning effort. Used for per-todo chief-of-staff briefs where depth
  matters more than latency.

  If the brief model rejects the request (unknown model, unsupported
  reasoning effort), the call retries once on the primary model at "high".
  When both tiers resolve to the same target, transient provider, network, or
  timeout failures still receive one retry. The first call reserves a bounded
  part of the caller's deadline for that recovery attempt.
  """
  def complete_brief(params) when is_map(params) do
    primary = model()
    brief = brief_model()
    deadline = System.monotonic_time(:millisecond) + request_timeout_ms(params)

    brief_params =
      params
      |> Map.put_new("model", brief)
      |> Map.put_new("reasoning_effort", brief_reasoning_effort())
      |> Map.put("timeout_ms", first_brief_attempt_timeout(deadline))

    case complete(brief_params) do
      {:ok, _response} = ok ->
        ok

      {:error, reason} = error ->
        fallback_params =
          params
          |> Map.put("model", primary)
          |> Map.put("reasoning_effort", "high")

        if distinct_brief_target?(brief_params, fallback_params) or transient_failure?(reason) do
          retry_brief(fallback_params, error, reason, deadline)
        else
          error
        end
    end
  end

  @doc false
  def transient_failure?(:timeout), do: true
  def transient_failure?(:llm_timeout), do: true
  def transient_failure?(:provider_error), do: true
  def transient_failure?(:network_error), do: true
  def transient_failure?({:llm_timeout, _timeout_ms}), do: true
  def transient_failure?({:provider_error, _detail}), do: true
  def transient_failure?({:network_error, _detail}), do: true
  def transient_failure?({:invalid_response, _detail}), do: true

  def transient_failure?({:api_error, status})
      when is_integer(status) and status >= 500 and status <= 599,
      do: true

  def transient_failure?({:api_error, status, _detail})
      when is_integer(status) and status >= 500 and status <= 599,
      do: true

  def transient_failure?(_reason), do: false

  @doc """
  Stream-complete a request, calling on_chunk for each output_text delta.

  Falls back to `complete/1` when the configured provider does not
  implement `stream_complete/2` or when the streaming feature is disabled.
  """
  def stream_complete(params, on_chunk) when is_map(params) and is_function(on_chunk, 1) do
    cond do
      not stream_replies_enabled?() ->
        complete(params)

      is_nil(provider()) ->
        complete(params)

      function_exported?(provider(), :stream_complete, 2) ->
        with {:ok, bounded_params} <- RequestBudget.validate(params) do
          module = provider()
          run_provider_request(module, bounded_params, &module.stream_complete(&1, on_chunk))
        end

      true ->
        complete(params)
    end
  end

  @doc """
  Stream-complete via the chat-tier model.
  """
  def stream_complete_chat(params, on_chunk)
      when is_map(params) and is_function(on_chunk, 1) do
    if is_map_key(params, "model") do
      stream_complete(params, on_chunk)
    else
      stream_complete(Map.put(params, "model", chat_model()), on_chunk)
    end
  end

  defp stream_replies_enabled? do
    runtime_config()
    |> Keyword.get(:openai_stream_replies, true)
  end

  defp run_provider_request(module, params, fun) when is_function(fun, 1) do
    timeout_ms =
      case params["timeout_ms"] do
        value when is_integer(value) and value > 0 -> min(value, 300_000)
        _value -> 120_000
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if provider_backpressure_enabled?(module) do
      params
      |> rate_limit_bucket()
      |> with_provider_slot(deadline, params, fun)
    else
      fun.(params)
    end
  end

  defp retry_brief(params, original_error, original_reason, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms >= @minimum_brief_retry_ms do
      Logger.info("Retrying brief model call",
        model: params["model"],
        failure_code: Maraithon.Redaction.error_class(original_reason)
      )

      case complete(Map.put(params, "timeout_ms", remaining_ms)) do
        {:ok, _response} = ok -> ok
        {:error, _retry_reason} -> original_error
      end
    else
      original_error
    end
  end

  defp first_brief_attempt_timeout(deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 1)

    if remaining_ms >= @brief_retry_reserve_ms + @minimum_brief_retry_ms do
      remaining_ms - @brief_retry_reserve_ms
    else
      remaining_ms
    end
  end

  defp distinct_brief_target?(brief_params, fallback_params) do
    brief_params["model"] != fallback_params["model"] or
      brief_params["reasoning_effort"] != fallback_params["reasoning_effort"]
  end

  defp request_timeout_ms(params) do
    case params["timeout_ms"] do
      value when is_integer(value) and value > 0 -> min(value, 300_000)
      _value -> 120_000
    end
  end

  defp provider_backpressure_enabled?(Maraithon.LLM.OpenAIProvider), do: true
  defp provider_backpressure_enabled?(Maraithon.LLM.AnthropicProvider), do: true
  defp provider_backpressure_enabled?(Maraithon.LLM.OpenRouterProvider), do: true

  defp provider_backpressure_enabled?(_module) do
    provider_name() in ["openai", "anthropic", "openrouter"]
  end

  defp with_provider_slot(bucket, deadline, params, fun) when is_function(fun, 1) do
    checkout_timeout = max(deadline - System.monotonic_time(:millisecond), 1)

    case LLMRateLimiter.checkout_with_timeout(bucket, checkout_timeout) do
      :ok ->
        try do
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining > 0 do
            params
            |> Map.put("timeout_ms", remaining)
            |> fun.()
            |> tap(&record_provider_rate_limit/1)
          else
            {:error, :timeout}
          end
        after
          LLMRateLimiter.checkin(bucket)
        end

      {:error, _reason} = error ->
        # A timed-out GenServer.call is still queued. Sender ordering ensures
        # this compensating checkin runs after any late checkout.
        LLMRateLimiter.checkin(bucket)
        error
    end
  end

  @doc false
  def execution_bucket(params) when is_map(params) do
    case RequestBudget.validate(params) do
      {:ok, bounded_params} -> rate_limit_bucket(bounded_params)
      {:error, _reason} -> :default
    end
  end

  def execution_bucket(_params), do: :default

  @doc false
  def rate_limit_bucket(params) when is_map(params) do
    params_model = params["model"] || params[:model] || model()
    chat_model = chat_model()
    routing_model = routing_model()
    fast_model = fast_model()
    primary_model = model()

    cond do
      non_empty(params_model) == nil ->
        :default

      non_empty(params_model) == non_empty(chat_model) and
          non_empty(params_model) != non_empty(primary_model) ->
        :chat

      non_empty(params_model) == non_empty(routing_model) and
          non_empty(routing_model) != non_empty(primary_model) ->
        :chat

      non_empty(params_model) == non_empty(fast_model) and
          non_empty(fast_model) != non_empty(primary_model) ->
        :chat

      true ->
        :reasoning
    end
  end

  def rate_limit_bucket(_params), do: :default

  defp non_empty(value) when is_binary(value) and byte_size(value) <= 255 do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end
  end

  defp non_empty(_value), do: nil

  defp record_provider_rate_limit({:error, {:rate_limited, retry_after_ms}}) do
    LLMRateLimiter.record_rate_limit_async(retry_after_ms)
  end

  defp record_provider_rate_limit(_result), do: :ok
end
