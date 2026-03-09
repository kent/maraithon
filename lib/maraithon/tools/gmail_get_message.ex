defmodule Maraithon.Tools.GmailGetMessage do
  @moduledoc """
  Fetches a single Gmail message by message id for a connected Google account.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, message_id} <- ActionHelpers.required_string(args, "message_id"),
         {:ok, message} <- GmailHelpers.get_message(user_id, message_id) do
      {:ok,
       %{
         source: "gmail",
         message_id: message_id,
         message: message
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        GmailHelpers.normalize_error(reason)
    end
  end
end
