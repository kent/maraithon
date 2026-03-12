defmodule Maraithon.TestSupport.CapturingTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    message_id =
      if pid = Process.whereis(:capturing_telegram_recorder) do
        Agent.get_and_update(pid, fn messages ->
          next_message_id =
            messages
            |> Enum.count(&(&1.type == :send))
            |> Kernel.+(1)
            |> Integer.to_string()

          updated_messages = [
            %{
              type: :send,
              chat_id: normalize_chat_id(chat_id),
              message_id: next_message_id,
              text: text,
              opts: opts
            }
            | messages
          ]

          {next_message_id, updated_messages}
        end)
      else
        "1"
      end

    {:ok, %{"message_id" => message_id}}
  end

  def answer_callback_query(_callback_query_id, opts \\ []) do
    if pid = Process.whereis(:capturing_telegram_recorder) do
      Agent.update(pid, fn messages ->
        [%{type: :callback, opts: opts} | messages]
      end)
    end

    {:ok, true}
  end

  def edit_message_text(chat_id, message_id, text, opts \\ []) do
    if pid = Process.whereis(:capturing_telegram_recorder) do
      Agent.update(pid, fn messages ->
        [
          %{
            type: :edit,
            chat_id: normalize_chat_id(chat_id),
            message_id: normalize_chat_id(message_id),
            text: text,
            opts: opts
          }
          | messages
        ]
      end)
    end

    {:ok, true}
  end

  defp normalize_chat_id(chat_id) when is_integer(chat_id), do: Integer.to_string(chat_id)
  defp normalize_chat_id(chat_id) when is_binary(chat_id), do: chat_id
  defp normalize_chat_id(chat_id), do: to_string(chat_id)
end
