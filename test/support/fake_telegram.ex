defmodule Maraithon.TestSupport.FakeTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(_chat_id, _text, _opts \\ []) do
    {:ok, %{"message_id" => 123}}
  end

  def send_chat_action(_chat_id, _action) do
    {:ok, true}
  end

  def answer_callback_query(_callback_query_id, _opts \\ []) do
    {:ok, true}
  end

  def edit_message_text(_chat_id, _message_id, _text, _opts \\ []) do
    {:ok, true}
  end
end
