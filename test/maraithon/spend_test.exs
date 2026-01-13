defmodule Maraithon.SpendTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Spend
  alias Maraithon.Agents
  alias Maraithon.Events

  describe "calculate_cost/3" do
    test "calculates cost for known model" do
      result = Spend.calculate_cost("claude-sonnet-4-20250514", 1_000_000, 500_000)

      assert result.input_cost == 3.0
      assert result.output_cost == 7.5
      assert result.total_cost == 10.5
      assert result.input_tokens == 1_000_000
      assert result.output_tokens == 500_000
    end

    test "calculates cost for unknown model using default pricing" do
      result = Spend.calculate_cost("unknown-model", 1_000_000, 1_000_000)

      # Default pricing is same as claude-sonnet-4
      assert result.input_cost == 3.0
      assert result.output_cost == 15.0
      assert result.total_cost == 18.0
    end

    test "handles small token counts" do
      result = Spend.calculate_cost("claude-sonnet-4-20250514", 1000, 500)

      # Prices per million tokens: $3 input, $15 output
      # 1000 tokens = 0.001 million tokens
      # 500 tokens = 0.0005 million tokens
      assert result.input_cost == 0.003
      assert result.output_cost == 0.0075
      assert result.total_cost == 0.0105
    end

    test "calculates correctly for opus model" do
      result = Spend.calculate_cost("claude-3-opus-20240229", 1_000_000, 1_000_000)

      # Opus: $15 input, $75 output per million
      assert result.input_cost == 15.0
      assert result.output_cost == 75.0
      assert result.total_cost == 90.0
    end

    test "calculates correctly for haiku model" do
      result = Spend.calculate_cost("claude-3-haiku-20240307", 1_000_000, 1_000_000)

      # Haiku: $0.25 input, $1.25 output per million
      assert result.input_cost == 0.25
      assert result.output_cost == 1.25
      assert result.total_cost == 1.5
    end
  end

  describe "get_agent_spend/1" do
    setup do
      {:ok, agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})
      %{agent_id: agent.id}
    end

    test "returns zero spend for agent with no events", %{agent_id: agent_id} do
      spend = Spend.get_agent_spend(agent_id)

      assert spend.total_cost == 0.0
      assert spend.input_tokens == 0
      assert spend.output_tokens == 0
      assert spend.llm_calls == 0
    end

    test "aggregates spend from effect_completed events", %{agent_id: agent_id} do
      # Create an effect_completed event with usage data
      Events.append(agent_id, "effect_completed", %{
        "result" => %{
          "usage" => %{
            "total_cost" => 0.005,
            "input_tokens" => 1000,
            "output_tokens" => 500
          }
        }
      })

      Events.append(agent_id, "effect_completed", %{
        "result" => %{
          "usage" => %{
            "total_cost" => 0.01,
            "input_tokens" => 2000,
            "output_tokens" => 1000
          }
        }
      })

      spend = Spend.get_agent_spend(agent_id)

      assert spend.total_cost == 0.015
      assert spend.input_tokens == 3000
      assert spend.output_tokens == 1500
      assert spend.llm_calls == 2
    end

    test "ignores events without usage data", %{agent_id: agent_id} do
      Events.append(agent_id, "effect_completed", %{
        "result" => %{"success" => true}
      })

      Events.append(agent_id, "effect_completed", %{
        "result" => %{
          "usage" => %{
            "total_cost" => 0.005,
            "input_tokens" => 1000,
            "output_tokens" => 500
          }
        }
      })

      spend = Spend.get_agent_spend(agent_id)

      assert spend.llm_calls == 1
      assert spend.total_cost == 0.005
    end
  end

  describe "get_total_spend/0" do
    test "returns zero when no effect_completed events exist" do
      spend = Spend.get_total_spend()

      assert spend.total_cost == 0.0
      assert spend.input_tokens == 0
      assert spend.output_tokens == 0
      assert spend.llm_calls == 0
    end

    test "aggregates spend across all agents" do
      {:ok, agent1} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})
      {:ok, agent2} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})

      Events.append(agent1.id, "effect_completed", %{
        "result" => %{
          "usage" => %{
            "total_cost" => 0.01,
            "input_tokens" => 1000,
            "output_tokens" => 500
          }
        }
      })

      Events.append(agent2.id, "effect_completed", %{
        "result" => %{
          "usage" => %{
            "total_cost" => 0.02,
            "input_tokens" => 2000,
            "output_tokens" => 1000
          }
        }
      })

      spend = Spend.get_total_spend()

      assert spend.total_cost == 0.03
      assert spend.input_tokens == 3000
      assert spend.output_tokens == 1500
      assert spend.llm_calls == 2
    end
  end
end
