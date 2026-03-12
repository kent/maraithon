defmodule Maraithon.TelegramResponder do
  @moduledoc """
  Thin Telegram response wrapper so conversational routing stays independent from the Bot API.
  """

  alias Maraithon.Connectors.Telegram

  @confirmation_prefix "insmem"
  @action_prefix "tgact"

  def send(chat_id, text, opts \\ []) when is_binary(chat_id) and is_binary(text) do
    telegram_module().send_message(chat_id, text, opts)
  end

  def reply(chat_id, reply_to_message_id, text, opts \\ [])
      when is_binary(chat_id) and is_binary(text) do
    options =
      opts
      |> Keyword.put_new(:reply_to, reply_to_message_id)

    send(chat_id, text, options)
  end

  def answer_callback(callback_id, text) when is_binary(callback_id) and is_binary(text) do
    telegram_module().answer_callback_query(callback_id, text: text)
  end

  def confirmation_markup(conversation_id) when is_binary(conversation_id) do
    %{
      "inline_keyboard" => [
        [
          %{
            "text" => "Remember This",
            "callback_data" => callback_data(conversation_id, "confirm")
          },
          %{
            "text" => "Just This One",
            "callback_data" => callback_data(conversation_id, "reject")
          }
        ]
      ]
    }
  end

  def action_markup(prepared_action_id) when is_binary(prepared_action_id) do
    %{
      "inline_keyboard" => [
        [
          %{
            "text" => "Confirm",
            "callback_data" => action_callback_data(prepared_action_id, "confirm")
          },
          %{
            "text" => "Cancel",
            "callback_data" => action_callback_data(prepared_action_id, "reject")
          }
        ]
      ]
    }
  end

  def parse_confirmation_callback(""), do: {:error, :invalid_callback}

  def parse_confirmation_callback(value) when is_binary(value) do
    case Regex.run(~r/^#{@confirmation_prefix}:([0-9a-f\-]{36}):(confirm|reject)$/i, value,
           capture: :all_but_first
         ) do
      [conversation_id, decision] -> {:ok, conversation_id, String.downcase(decision)}
      _ -> {:error, :invalid_callback}
    end
  end

  def parse_confirmation_callback(_), do: {:error, :invalid_callback}

  def parse_action_callback(""), do: {:error, :invalid_callback}

  def parse_action_callback(value) when is_binary(value) do
    case Regex.run(~r/^#{@action_prefix}:([0-9a-f\-]{36}):(confirm|reject)$/i, value,
           capture: :all_but_first
         ) do
      [prepared_action_id, decision] ->
        {:ok, prepared_action_id, String.downcase(decision)}

      _ ->
        {:error, :invalid_callback}
    end
  end

  def parse_action_callback(_), do: {:error, :invalid_callback}

  defp callback_data(conversation_id, decision),
    do: "#{@confirmation_prefix}:#{conversation_id}:#{decision}"

  defp action_callback_data(prepared_action_id, decision),
    do: "#{@action_prefix}:#{prepared_action_id}:#{decision}"

  defp telegram_module do
    Application.get_env(:maraithon, :insights, [])
    |> Keyword.get(:telegram_module, Telegram)
  end
end
