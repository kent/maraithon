defmodule Maraithon.TelegramAssistant.Client do
  @moduledoc """
  Behaviour for Telegram assistant model clients.
  """

  @callback next_step(map()) :: {:ok, map()} | {:error, term()}
end
