defmodule Maraithon.Runtime.Effects.LLMCallCommand do
  @moduledoc """
  Command implementation for `llm_call` effects.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.LLM
  alias Maraithon.Effects.Effect

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
          Logger.info("LLM call succeeded",
            effect_id: effect.id,
            model: data.model,
            tokens: data.usage.total_tokens,
            cost: data.usage.total_cost
          )

          result

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
end
