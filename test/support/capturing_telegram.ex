defmodule Maraithon.TestSupport.CapturingTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    if pid = Process.whereis(:capturing_telegram_recorder) do
      Agent.update(pid, fn messages ->
        [
          %{chat_id: normalize_chat_id(chat_id), text: text, opts: opts}
          | messages
        ]
      end)
    end

    {:ok, %{"message_id" => 123}}
  end

  def answer_callback_query(_callback_query_id, _opts \\ []) do
    {:ok, true}
  end

  defp normalize_chat_id(chat_id) when is_integer(chat_id), do: Integer.to_string(chat_id)
  defp normalize_chat_id(chat_id) when is_binary(chat_id), do: chat_id
  defp normalize_chat_id(chat_id), do: to_string(chat_id)
end
