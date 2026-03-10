defmodule Maraithon.Runtime.Effects.LLMCallCommand do
  @moduledoc """
  Command implementation for `llm_call` effects.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.LLM
  alias Maraithon.Effects.Effect
  alias Maraithon.Spend

  require Logger

  @impl true
  def execute(%Effect{} = effect) do
    params = effect.params
    _timeout = params["timeout_ms"] || 120_000

    Logger.info("Starting LLM call for effect #{effect.id}",
      agent_id: effect.agent_id,
      effect_id: effect.id
    )

    try do
      provider = LLM.provider()
      result = provider.complete(params)

      case result do
        {:ok, data} ->
          data = ensure_usage(data)

          Logger.info("LLM call succeeded",
            effect_id: effect.id,
            model: data.model,
            tokens: data.usage.total_tokens,
            cost: data.usage.total_cost
          )

          {:ok, data}

        {:error, reason} ->
          Logger.warning("LLM call failed", effect_id: effect.id, reason: inspect(reason))
          result
      end
    catch
      :exit, {:timeout, _} ->
        Logger.warning("LLM call timed out", effect_id: effect.id)
        {:error, "timeout"}
    end
  end

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
