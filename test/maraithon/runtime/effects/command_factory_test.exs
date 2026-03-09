defmodule Maraithon.Runtime.Effects.CommandFactoryTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.Effects.CommandFactory
  alias Maraithon.Runtime.Effects.{LLMCallCommand, ToolCallCommand}

  describe "fetch/1" do
    test "returns command for llm_call" do
      assert {:ok, LLMCallCommand} = CommandFactory.fetch("llm_call")
    end

    test "returns command for tool_call" do
      assert {:ok, ToolCallCommand} = CommandFactory.fetch("tool_call")
    end

    test "returns error for unknown effect type" do
      assert {:error, :unknown_effect_type} = CommandFactory.fetch("unknown")
    end
  end

  describe "supported_types/0" do
    test "lists all registered effect types" do
      assert Enum.sort(CommandFactory.supported_types()) == ["llm_call", "tool_call"]
    end
  end
end
