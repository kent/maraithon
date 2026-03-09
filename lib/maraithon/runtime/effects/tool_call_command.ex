defmodule Maraithon.Runtime.Effects.ToolCallCommand do
  @moduledoc """
  Command implementation for `tool_call` effects.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.Effects.Effect
  alias Maraithon.Tools

  @impl true
  def execute(%Effect{} = effect) do
    tool_name = effect.params["tool"]
    args = effect.params["args"] || %{}

    case Tools.execute(tool_name, args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
