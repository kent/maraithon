defmodule Maraithon.Runtime.Effects.LLMCallCommand do
  @moduledoc """
  Command implementation for `llm_call` effects.

  Retries short transient provider errors (network blips, 5xx API errors, and
  very short rate limits) up to `@max_retry_attempts` times. Provider timeouts
  return to the durable effect queue because one real timeout consumes the full
  provider deadline. On the final durable attempt after an exact timeout, the
  command selects one distinct configured fallback model before starting work.
  Long provider rate limits are surfaced to the effect runner so the durable
  queue can retry later without blocking worker tasks or stampeding fallback
  models in the same provider bucket.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.LLM
  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Effects.Effect
  alias Maraithon.Spend
  alias Maraithon.Tracing
  alias Maraithon.Redaction
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  require Logger

  # Total attempts including the first call. 3 = first try + 2 retries.
  @max_retry_attempts 3
  # Busy-slot waits are cheap; allow up to ~5 minutes of patience overall.
  @max_busy_retry_attempts 20
  @busy_retry_floor_ms 3_000
  @busy_retry_cap_ms 15_000
  # Hard ceiling on a single retry-after to keep the effect process from
  # blocking on the provider for an unreasonable stretch.
  @max_retry_after_ms 120_000
  @max_inline_rate_limit_retry_ms 5_000
  # Fallback when the provider gives a non-integer retry-after.
  @default_rate_limited_backoff_ms 30_000
  @fallback_max_tokens 8_000
  @fallback_reasoning_effort "medium"
  @default_primary_max_tokens 32_000
  @max_usage_tokens 10_000_000
  @max_usage_cost_usd 1_000_000

  @impl true
  def prepare(%Effect{} = effect) do
    bounded =
      with {:ok, canonical_params} <-
             effect.params
             |> cap_primary_tokens()
             |> cap_primary_model()
             |> RequestBudget.validate() do
        canonical_params
        |> cap_primary_tokens()
        |> cap_primary_model()
        |> maybe_use_durable_timeout_fallback(effect)
        |> RequestBudget.validate()
      end

    case bounded do
      {:ok, params} ->
        {:ok, params}

      {:error, reason} = error ->
        Logger.warning("LLM effect request rejected",
          effect_reference: Redaction.fingerprint(effect.id),
          failure_code: Redaction.error_class(reason)
        )

        error
    end
  end

  @impl true
  def execute_prepared(%Effect{} = effect, params) when is_map(params),
    do: do_execute(effect, params)

  def execute_prepared(%Effect{}, _prepared), do: {:error, :invalid_request}

  @impl true
  def execute(%Effect{} = effect) do
    with {:ok, params} <- prepare(effect) do
      execute_prepared(effect, params)
    end
  end

  defp do_execute(effect, params) do
    timeout = request_timeout(params["timeout_ms"], effect)
    deadline = System.monotonic_time(:millisecond) + timeout

    Logger.info("Starting LLM call",
      effect_reference: Redaction.fingerprint(effect.id)
    )

    try do
      result =
        if durable_timeout_recovery_claim?(effect),
          do: call_once(params, deadline),
          else: run_with_retry(params, effect, 1, deadline)

      case result do
        {:ok, data} ->
          case prepare_success(data) do
            {:ok, prepared} ->
              Logger.info("LLM call succeeded",
                effect_reference: Redaction.fingerprint(effect.id),
                model: prepared.model,
                input_tokens: prepared.usage.input_tokens,
                output_tokens: prepared.usage.output_tokens,
                cost_usd: prepared.usage.total_cost
              )

              {:ok, prepared}

            {:error, :invalid_effect_result} = error ->
              Logger.warning("LLM call returned an invalid success payload",
                effect_reference: Redaction.fingerprint(effect.id),
                failure_code: "invalid_effect_result"
              )

              error
          end

        {:error, reason} = error ->
          Logger.warning("LLM call failed",
            effect_reference: Redaction.fingerprint(effect.id),
            failure_code: Redaction.error_class(reason)
          )

          error
      end
    catch
      :exit, {:timeout, _} ->
        Logger.warning("LLM call timed out",
          effect_reference: Redaction.fingerprint(effect.id),
          failure_code: "timeout"
        )

        {:error, :timeout}
    end
  end

  defp call_once(params, deadline) do
    case remaining_ms(deadline) do
      remaining when remaining > 0 ->
        result =
          params
          |> Map.put("timeout_ms", remaining)
          |> LLM.complete()

        case result do
          {:error, reason} = error ->
            record_provider_limit(reason)
            error

          other ->
            other
        end

      _expired ->
        {:error, :command_deadline_exceeded}
    end
  end

  defp run_with_retry(params, effect, attempt, deadline) do
    with remaining when remaining > 0 <- remaining_ms(deadline) do
      params = Map.put(params, "timeout_ms", remaining)

      case LLM.complete(params) do
        {:ok, _data} = ok ->
          ok

        {:error, :timeout} = error ->
          error

        {:error, {:incomplete_response, _summary} = reason}
        when attempt < @max_retry_attempts ->
          case expand_incomplete_response_budget(params) do
            {:ok, expanded, max_tokens} ->
              Logger.info("LLM incomplete response retry scheduled",
                effect_reference: Redaction.fingerprint(effect.id),
                attempt: attempt,
                max_tokens: max_tokens,
                failure_code: "incomplete_response"
              )

              run_with_retry(expanded, effect, attempt + 1, deadline)

            :at_capacity ->
              {:error, reason}
          end

        {:error, reason} ->
          record_provider_limit(reason)

          case retry_backoff_ms(reason, attempt) do
            nil ->
              # Same-model retries are spent. For transient errors that look
              # like model-scoped capacity issues, try configured fallback
              # models with a lighter request before failing the effect.
              maybe_try_model_fallbacks(params, effect, reason, deadline)

            sleep_ms ->
              Logger.info("LLM call retry scheduled",
                effect_reference: Redaction.fingerprint(effect.id),
                attempt: attempt,
                retry_after_ms: sleep_ms,
                failure_code: Redaction.error_class(reason)
              )

              case sleep_with_deadline(sleep_ms, deadline) do
                :ok -> run_with_retry(params, effect, attempt + 1, deadline)
                :timeout -> {:error, reason}
              end
          end
      end
    else
      _expired -> {:error, :command_deadline_exceeded}
    end
  end

  defp maybe_try_model_fallbacks(params, effect, original_reason, deadline) do
    fallback_models = fallback_models(params)

    cond do
      provider_deferral_error?(original_reason) ->
        {:error, original_reason}

      not transient_capacity_error?(original_reason) ->
        {:error, original_reason}

      fallback_models == [] ->
        {:error, original_reason}

      true ->
        try_fallback_models(params, effect, original_reason, fallback_models, [], deadline)
    end
  end

  defp try_fallback_models(
         _params,
         _effect,
         original_reason,
         [],
         fallback_errors,
         _deadline
       ) do
    Tracing.record_error(
      {:llm_fallbacks_failed, Redaction.error_class(original_reason),
       Enum.reverse(fallback_errors)}
    )

    {:error, {:llm_fallbacks_failed, original_reason, Enum.reverse(fallback_errors)}}
  end

  defp try_fallback_models(
         params,
         effect,
         original_reason,
         [fallback_model | rest],
         errors,
         deadline
       ) do
    Logger.info("LLM primary exhausted; falling back to alternate model",
      effect_reference: Redaction.fingerprint(effect.id),
      model: fallback_model,
      failure_code: Redaction.error_class(original_reason)
    )

    remaining = remaining_ms(deadline)

    case remaining do
      value when value <= 0 ->
        {:error, original_reason}

      value ->
        fallback_params =
          params
          |> fallback_params(fallback_model)
          |> Map.put("timeout_ms", value)

        run_fallback_model(fallback_params, effect, original_reason, rest, errors, deadline)
    end
  end

  defp run_fallback_model(
         fallback_params,
         effect,
         original_reason,
         rest,
         errors,
         deadline
       ) do
    fallback_model = fallback_params["model"]

    case LLM.complete(fallback_params) do
      {:ok, _data} = ok ->
        ok

      {:error, :timeout} = error ->
        error

      {:error, fallback_reason} ->
        record_provider_limit(fallback_reason)

        Logger.warning("LLM fallback model failed",
          effect_reference: Redaction.fingerprint(effect.id),
          model: fallback_model,
          failure_code: Redaction.error_class(fallback_reason)
        )

        try_fallback_models(
          fallback_params,
          effect,
          original_reason,
          rest,
          [
            %{model: fallback_model, reason: Redaction.error_summary(fallback_reason)} | errors
          ],
          deadline
        )
    end
  end

  # Claimed effects carry the number of already-persisted counted attempts.
  # Preserve two full primary timeout windows; only the final allowed claim may
  # switch models, and only from attempt-fenced server-written provenance.
  defp maybe_use_durable_timeout_fallback(params, %Effect{} = effect) when is_map(params) do
    if durable_timeout_recovery_claim?(effect) do
      case fallback_models(params) do
        [fallback_model | _rest] ->
          Logger.info("Selected alternate model for durable LLM timeout retry",
            effect_reference: Redaction.fingerprint(effect.id),
            attempt: effect.attempts + 1,
            model: fallback_model,
            failure_code: "timeout"
          )

          fallback_params(params, fallback_model)

        [] ->
          params
      end
    else
      params
    end
  end

  defp maybe_use_durable_timeout_fallback(params, _effect), do: params

  defp durable_timeout_recovery_claim?(%Effect{
         attempts: attempts,
         max_attempts: max_attempts,
         last_failure_code: "timeout",
         last_failure_attempt: failure_attempt,
         claimed_by: claimed_by,
         claimed_at: %DateTime{}
       })
       when is_binary(claimed_by) and is_integer(attempts) and is_integer(max_attempts) and
              is_integer(failure_attempt) and max_attempts > 1 and
              attempts == max_attempts - 1 and failure_attempt == attempts,
       do: true

  defp durable_timeout_recovery_claim?(_effect), do: false

  defp fallback_models(params) do
    current_model = normalize_model(Map.get(params, "model") || LLM.model())

    [LLM.chat_model(), LLM.routing_model() | configured_model_fallbacks()]
    |> Enum.map(&normalize_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == current_model))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp fallback_params(params, fallback_model) do
    params
    |> Map.put("model", fallback_model)
    |> cap_fallback_tokens()
    |> Map.delete("reasoning")
    |> Map.delete(:reasoning)
    |> Map.put("reasoning_effort", @fallback_reasoning_effort)
  end

  defp cap_primary_model(params) when is_map(params) do
    case Map.get(params, "model") do
      nil ->
        params

      model when is_binary(model) and byte_size(model) <= 255 ->
        if String.valid?(model),
          do: Map.put(params, "model", String.trim(model)),
          else: Map.delete(params, "model")

      _invalid ->
        Map.delete(params, "model")
    end
  end

  defp cap_primary_model(params), do: params

  defp cap_primary_tokens(params) when is_map(params) do
    cap = primary_max_tokens()

    params
    |> cap_token_key("max_tokens", cap)
    |> cap_token_key("max_output_tokens", cap)
  end

  defp cap_primary_tokens(params), do: params

  defp expand_incomplete_response_budget(params) do
    cap = primary_max_tokens()
    current = params["max_tokens"] || params["max_output_tokens"] || 2_048

    if is_integer(current) and current > 0 and current < cap do
      expanded = min(current * 2, cap)

      params =
        ["max_tokens", "max_output_tokens"]
        |> Enum.reduce(params, fn key, acc ->
          if Map.has_key?(acc, key), do: Map.put(acc, key, expanded), else: acc
        end)
        |> then(fn expanded_params ->
          if Map.has_key?(expanded_params, "max_tokens") or
               Map.has_key?(expanded_params, "max_output_tokens"),
             do: expanded_params,
             else: Map.put(expanded_params, "max_tokens", expanded)
        end)

      {:ok, params, expanded}
    else
      :at_capacity
    end
  end

  defp cap_fallback_tokens(params) do
    params
    |> cap_token_key("max_tokens", @fallback_max_tokens)
    |> cap_token_key("max_output_tokens", @fallback_max_tokens)
  end

  defp cap_token_key(params, key, cap) do
    case Map.fetch(params, key) do
      :error ->
        params

      {:ok, value} when is_integer(value) and value > cap ->
        params
        |> Map.put(key, cap)
        |> note_token_cap(key, :above_cap, cap)

      {:ok, value} when is_integer(value) and value > 0 ->
        params

      {:ok, value} when is_binary(value) and byte_size(value) > 16 ->
        params
        |> Map.put(key, cap)
        |> note_token_cap(key, :oversized_binary, cap)

      {:ok, value} when is_binary(value) ->
        if not String.valid?(value) do
          Map.delete(params, key)
        else
          case Integer.parse(String.trim(value)) do
            {parsed, ""} when parsed > cap ->
              params
              |> Map.put(key, cap)
              |> note_token_cap(key, :above_cap, cap)

            {parsed, ""} when parsed > 0 ->
              Map.put(params, key, parsed)

            _other ->
              Map.delete(params, key)
          end
        end

      {:ok, _invalid} ->
        Map.delete(params, key)
    end
  end

  defp note_token_cap(params, key, reason, cap) do
    Logger.info("Capped oversized LLM effect request",
      token_key: key,
      failure_code: to_string(reason),
      cap: cap
    )

    params
  end

  defp primary_max_tokens do
    :maraithon
    |> Application.get_env(Maraithon.Runtime, [])
    |> Keyword.get(:llm_primary_max_tokens, @default_primary_max_tokens)
    |> positive_integer(@default_primary_max_tokens)
    |> min(@default_primary_max_tokens)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) and byte_size(value) <= 16 do
    if String.valid?(value) do
      case Integer.parse(String.trim(value)) do
        {parsed, ""} when parsed > 0 -> parsed
        _other -> default
      end
    else
      default
    end
  end

  defp positive_integer(_value, default), do: default

  @doc false
  def normalize_model_fallbacks(value), do: normalize_string_list(value)

  defp configured_model_fallbacks do
    :maraithon
    |> Application.get_env(Maraithon.Runtime, [])
    |> Keyword.get(:llm_model_fallbacks, [])
    |> normalize_string_list()
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.take(16)
    |> Enum.map(&normalize_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> Maraithon.PromptBudget.truncate_utf8(8_192)
    |> String.split(",", trim: true)
    |> Enum.take(16)
    |> normalize_string_list()
  end

  defp normalize_string_list(_value), do: []

  defp normalize_model(value) when is_binary(value) and byte_size(value) <= 255 do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> nil
        model -> model
      end
    end
  end

  defp normalize_model(_value), do: nil

  defp transient_capacity_error?({:rate_limited, _}), do: true
  defp transient_capacity_error?(:timeout), do: true
  defp transient_capacity_error?({:network_error, _}), do: true

  defp transient_capacity_error?({:api_error, status, _}) when status in [500, 502, 503, 504],
    do: true

  defp transient_capacity_error?(_), do: false

  defp provider_deferral_error?({:rate_limited, _retry_after}), do: true
  defp provider_deferral_error?({:llm_busy, _retry_after}), do: true
  defp provider_deferral_error?(_reason), do: false

  defp record_provider_limit({:rate_limited, retry_after_ms}) do
    LLMRateLimiter.record_rate_limit(retry_after_ms)
  end

  defp record_provider_limit(_reason), do: :ok

  # llm_busy is the local concurrency gate (one slot per bucket), not a
  # provider limit: another effect simply holds the slot, sometimes for
  # minutes. Giving up immediately silently dropped whole briefings, so
  # busy gets its own patient retry lane ahead of the global attempt cap.
  defp retry_backoff_ms({:llm_busy, retry_after}, attempt)
       when attempt < @max_busy_retry_attempts do
    retry_after
    |> case do
      ms when is_integer(ms) and ms > 0 -> ms
      _other -> @busy_retry_floor_ms
    end
    |> max(@busy_retry_floor_ms)
    |> min(@busy_retry_cap_ms)
  end

  defp retry_backoff_ms(:llm_busy, attempt) when attempt < @max_busy_retry_attempts,
    do: @busy_retry_floor_ms

  defp retry_backoff_ms(_reason, attempt) when attempt >= @max_retry_attempts, do: nil

  defp retry_backoff_ms({:rate_limited, retry_after}, _attempt)
       when is_integer(retry_after) and retry_after > 0,
       do: inline_rate_limit_backoff_ms(retry_after)

  defp retry_backoff_ms({:rate_limited, _}, _attempt),
    do: inline_rate_limit_backoff_ms(@default_rate_limited_backoff_ms)

  defp retry_backoff_ms({:network_error, _reason}, attempt), do: 2_000 * attempt

  defp retry_backoff_ms({:api_error, status, _body}, attempt)
       when status in [500, 502, 503, 504],
       do: 2_000 * attempt

  defp retry_backoff_ms(_reason, _attempt), do: nil

  defp inline_rate_limit_backoff_ms(retry_after_ms)
       when retry_after_ms <= @max_inline_rate_limit_retry_ms do
    min(retry_after_ms, @max_retry_after_ms)
  end

  defp inline_rate_limit_backoff_ms(_retry_after_ms), do: nil

  defp request_timeout(value, effect) when is_integer(value) and value > 0,
    do: min(value, request_timeout_cap(effect))

  defp request_timeout(_value, _effect), do: 120_000

  defp request_timeout_cap(%Effect{claimed_by: claimed_by, claimed_at: %DateTime{}})
       when is_binary(claimed_by),
       do: 120_000

  # Operator-only direct callers are not durable claims; retain their existing
  # single-call ceiling rather than silently shortening high-reasoning work.
  defp request_timeout_cap(_effect), do: 300_000

  defp remaining_ms(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp sleep_with_deadline(sleep_ms, deadline) do
    remaining = remaining_ms(deadline)

    if sleep_ms > 0 and sleep_ms < remaining do
      Process.sleep(sleep_ms)
      :ok
    else
      :timeout
    end
  end

  defp prepare_success(%{content: content} = data)
       when is_map(data) and not is_struct(data) and is_binary(content) do
    model = Map.get(data, :model) || "unknown"
    tokens_in = Map.get(data, :tokens_in, 0)
    tokens_out = Map.get(data, :tokens_out, 0)

    if valid_model?(model) and valid_token_count?(tokens_in) and valid_token_count?(tokens_out) do
      prepared =
        data
        |> Map.put(:model, model)
        |> Map.put(:tokens_in, tokens_in)
        |> Map.put(:tokens_out, tokens_out)
        |> ensure_usage()

      case prepared do
        %{usage: %{input_tokens: input, output_tokens: output, total_cost: cost}}
        when is_integer(input) and input >= 0 and input <= @max_usage_tokens and
               is_integer(output) and output >= 0 and output <= @max_usage_tokens ->
          if valid_usage_cost?(cost),
            do: {:ok, prepared},
            else: {:error, :invalid_effect_result}

        _invalid_usage ->
          {:error, :invalid_effect_result}
      end
    else
      {:error, :invalid_effect_result}
    end
  rescue
    _error -> {:error, :invalid_effect_result}
  end

  defp prepare_success(_data), do: {:error, :invalid_effect_result}

  defp valid_model?(model) when is_binary(model) and byte_size(model) <= 255,
    do: String.valid?(model)

  defp valid_model?(_model), do: false

  defp valid_token_count?(value),
    do: is_integer(value) and value >= 0 and value <= @max_usage_tokens

  defp valid_usage_cost?(value),
    do: is_number(value) and value >= 0 and value <= @max_usage_cost_usd

  defp ensure_usage(%{usage: %{} = usage} = data) do
    model = Map.get(data, :model, "unknown")
    tokens_in = Map.get(data, :tokens_in, 0)
    tokens_out = Map.get(data, :tokens_out, 0)

    normalized_usage =
      usage
      |> normalize_usage_value(:input_tokens, tokens_in)
      |> normalize_usage_value(:output_tokens, tokens_out)
      |> normalize_usage_value(:total_tokens, tokens_in + tokens_out)
      |> normalize_usage_value(
        :total_cost,
        Spend.calculate_cost(model, tokens_in, tokens_out).total_cost
      )

    %{data | usage: normalized_usage}
  end

  defp ensure_usage(data) do
    model = Map.get(data, :model, "unknown")
    tokens_in = Map.get(data, :tokens_in, 0)
    tokens_out = Map.get(data, :tokens_out, 0)

    Map.put(data, :usage, Spend.calculate_cost(model, tokens_in, tokens_out))
  end

  defp normalize_usage_value(usage, key, fallback) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      nil -> Map.put(usage, key, fallback)
      _value -> usage
    end
  end
end
