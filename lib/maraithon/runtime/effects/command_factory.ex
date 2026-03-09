defmodule Maraithon.Runtime.Effects.CommandFactory do
  @moduledoc """
  Factory for resolving effect execution commands by effect type.

  This is a GoF Factory Method style registry used by EffectRunner.
  """

  alias Maraithon.Runtime.Effects.{LLMCallCommand, ToolCallCommand}

  @commands %{
    "llm_call" => LLMCallCommand,
    "tool_call" => ToolCallCommand
  }

  @doc """
  Fetch a command module for the given effect type.
  """
  def fetch(effect_type) when is_binary(effect_type) do
    case Map.get(@commands, effect_type) do
      nil -> {:error, :unknown_effect_type}
      command_module -> {:ok, command_module}
    end
  end

  @doc """
  List all supported effect types.
  """
  def supported_types do
    Map.keys(@commands)
  end
end
