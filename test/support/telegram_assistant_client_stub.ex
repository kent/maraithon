defmodule Maraithon.TestSupport.TelegramAssistantClientStub do
  @moduledoc false

  @behaviour Maraithon.TelegramAssistant.Client

  def next_step(payload) do
    case Application.get_env(:maraithon, :telegram_assistant, [])[:next_step] do
      fun when is_function(fun, 1) ->
        fun.(payload)

      _ ->
        {:error, :telegram_assistant_stub_not_configured}
    end
  end
end
