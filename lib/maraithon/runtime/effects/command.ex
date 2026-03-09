defmodule Maraithon.Runtime.Effects.Command do
  @moduledoc """
  Command behavior for effect execution.

  This is the GoF Command pattern boundary: each effect type is encapsulated
  in its own executable command module.
  """

  alias Maraithon.Effects.Effect

  @callback execute(effect :: Effect.t()) :: {:ok, map()} | {:error, term()}
end
