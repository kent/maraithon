defmodule Maraithon.LLM do
  @moduledoc """
  LLM provider interface and configuration.
  """

  @doc """
  Get the configured LLM provider module.
  """
  def provider do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
    |> Keyword.get(:llm_provider, Maraithon.LLM.MockProvider)
  end

  @doc """
  Get the configured model.
  """
  def model do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
    |> Keyword.get(:anthropic_model, "claude-sonnet-4-20250514")
  end

  @doc """
  Get the API key.
  """
  def api_key do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
    |> Keyword.get(:anthropic_api_key)
  end
end
