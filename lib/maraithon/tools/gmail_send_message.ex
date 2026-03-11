defmodule Maraithon.Tools.GmailSendMessage do
  @moduledoc """
  Sends a Gmail message using the connected user's OAuth grant.
  """

  alias Maraithon.Connectors.Gmail
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, to} <- ActionHelpers.required_string(args, "to"),
         {:ok, subject} <- ActionHelpers.required_string(args, "subject"),
         {:ok, body} <- ActionHelpers.required_string(args, "body"),
         {:ok, result} <-
           Gmail.send_message(user_id, %{
             account: ActionHelpers.optional_string(args, "account"),
             to: to,
             subject: subject,
             body: body,
             thread_id: ActionHelpers.optional_string(args, "thread_id"),
             reply_to_message_id: ActionHelpers.optional_string(args, "reply_to_message_id")
           }) do
      {:ok, Map.put(result, :source, "gmail")}
    else
      {:error, :no_token} ->
        {:error, "google_account_not_connected"}

      {:error, :reauth_required} ->
        {:error, "google_account_reauth_required"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "gmail_send_failed: #{inspect(reason)}"}
    end
  end
end
