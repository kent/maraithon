defmodule Maraithon.LLM.Adapter do
  @moduledoc """
  Behaviour for LLM providers.
  """

  @type message :: %{String.t() => String.t()}
  @type params :: %{
          optional(String.t()) => any(),
          required(String.t()) => any()
        }

  @type response :: %{
          content: String.t(),
          model: String.t(),
          tokens_in: integer(),
          tokens_out: integer(),
          finish_reason: String.t()
        }

  @callback complete(params()) :: {:ok, response()} | {:error, term()}
end
