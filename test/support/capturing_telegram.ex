defmodule Maraithon.TestSupport.CapturingTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    message_id = next_message_id()

    record_event(%{
      type: :send,
      chat_id: normalize_chat_id(chat_id),
      message_id: message_id,
      text: text,
      opts: opts
    })

    {:ok, %{"message_id" => message_id}}
  end

  def send_chat_action(chat_id, action) do
    record_event(%{
      type: :chat_action,
      chat_id: normalize_chat_id(chat_id),
      action: to_string(action)
    })

    {:ok, true}
  end

  def answer_callback_query(_callback_query_id, opts \\ []) do
    record_event(%{type: :callback, opts: opts})

    {:ok, true}
  end

  def edit_message_text(chat_id, message_id, text, opts \\ []) do
    event = %{
      type: :edit,
      chat_id: normalize_chat_id(chat_id),
      message_id: normalize_chat_id(message_id),
      text: text,
      opts: opts
    }

    case edit_result() do
      {:error, reason} ->
        notify_watcher({:capturing_telegram_edit_failed, event, reason})
        {:error, reason}

      _ ->
        record_event(event)
        {:ok, true}
    end
  end

  defp next_message_id do
    if pid = Process.whereis(:capturing_telegram_recorder) do
      Agent.get(pid, fn messages ->
        messages
        |> Enum.count(&(&1.type == :send))
        |> Kernel.+(1)
        |> Integer.to_string()
      end)
    else
      "1"
    end
  end

  defp edit_result do
    Application.get_env(:maraithon, :capturing_telegram, [])
    |> Keyword.get(:edit_result, :ok)
  end

  defp record_event(event) do
    if pid = Process.whereis(:capturing_telegram_recorder) do
      Agent.update(pid, fn messages -> [event | messages] end)
    end

    notify_watcher({:capturing_telegram_event, event})
    :ok
  end

  defp notify_watcher(message) do
    if pid = Process.whereis(:capturing_telegram_watcher) do
      send(pid, message)
    end
  end

  defp normalize_chat_id(chat_id) when is_integer(chat_id), do: Integer.to_string(chat_id)
  defp normalize_chat_id(chat_id) when is_binary(chat_id), do: chat_id
  defp normalize_chat_id(chat_id), do: to_string(chat_id)
end
