defmodule Maraithon.Spend do
  @moduledoc """
  Token usage and cost tracking for LLM calls.

  Pricing as of 2024 (per million tokens):
  - claude-3-5-sonnet: $3 input, $15 output
  - claude-3-opus: $15 input, $75 output
  - claude-3-haiku: $0.25 input, $1.25 output
  - claude-sonnet-4: $3 input, $15 output (default)
  """

  import Ecto.Query
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Events.Event

  # Pricing per million tokens (in USD)
  @pricing %{
    # Claude 3.5 / Claude 4 models
    "claude-sonnet-4-20250514" => %{input: 3.0, output: 15.0},
    "claude-3-5-sonnet-20241022" => %{input: 3.0, output: 15.0},
    "claude-3-5-sonnet-20240620" => %{input: 3.0, output: 15.0},
    "claude-3-opus-20240229" => %{input: 15.0, output: 75.0},
    "claude-3-haiku-20240307" => %{input: 0.25, output: 1.25},
    # GPT-5.4 family
    "gpt-5.4" => %{input: 2.5, output: 15.0},
    "gpt-5.4-2026-03-05" => %{input: 2.5, output: 15.0},
    # Fallback for unknown models
    "default" => %{input: 3.0, output: 15.0}
  }

  @doc """
  Calculate the cost of an LLM call in USD.
  """
  def calculate_cost(model, input_tokens, output_tokens) do
    pricing = Map.get(@pricing, model, @pricing["default"])

    input_cost = input_tokens / 1_000_000 * pricing.input
    output_cost = output_tokens / 1_000_000 * pricing.output

    %{
      input_cost: Float.round(input_cost, 6),
      output_cost: Float.round(output_cost, 6),
      total_cost: Float.round(input_cost + output_cost, 6),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      model: model
    }
  end

  @doc """
  Get total spend for an agent from their events.
  """
  def get_agent_spend(agent_id) do
    events =
      from(e in Event,
        where: e.agent_id == ^agent_id,
        where: e.event_type == "effect_completed",
        select: e.payload
      )
      |> Repo.all()

    Enum.reduce(events, initial_spend(), fn payload, acc ->
      # Usage is nested under result from LLM calls
      case get_in(payload, ["result", "usage"]) do
        %{} = usage ->
          %{
            total_cost: acc.total_cost + (usage["total_cost"] || 0),
            input_tokens: acc.input_tokens + (usage["input_tokens"] || 0),
            output_tokens: acc.output_tokens + (usage["output_tokens"] || 0),
            llm_calls: acc.llm_calls + 1
          }

        _ ->
          acc
      end
    end)
  end

  @doc """
  Get total spend across all agents.
  """
  def get_total_spend(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    events =
      total_spend_query(user_id)
      |> Repo.all()

    Enum.reduce(events, initial_spend(), fn payload, acc ->
      # Usage is nested under result from LLM calls
      case get_in(payload, ["result", "usage"]) do
        %{} = usage ->
          %{
            total_cost: acc.total_cost + (usage["total_cost"] || 0),
            input_tokens: acc.input_tokens + (usage["input_tokens"] || 0),
            output_tokens: acc.output_tokens + (usage["output_tokens"] || 0),
            llm_calls: acc.llm_calls + 1
          }

        _ ->
          acc
      end
    end)
  end

  defp initial_spend do
    %{
      total_cost: 0.0,
      input_tokens: 0,
      output_tokens: 0,
      llm_calls: 0
    }
  end

  defp total_spend_query(nil) do
    from(e in Event,
      where: e.event_type == "effect_completed",
      select: e.payload
    )
  end

  defp total_spend_query("") do
    total_spend_query(nil)
  end

  defp total_spend_query(user_id) when is_binary(user_id) do
    from(e in Event,
      join: a in Agent,
      on: a.id == e.agent_id,
      where: e.event_type == "effect_completed" and a.user_id == ^user_id,
      select: e.payload
    )
  end
end
