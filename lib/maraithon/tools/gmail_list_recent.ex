defmodule Maraithon.Tools.GmailListRecent do
  @moduledoc """
  Lists recent Gmail messages for a connected Google account.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailHelpers

  def execute(args) when is_map(args) do
    max_results = resolve_max_results(args)

    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, messages} <- GmailHelpers.list_messages(user_id, max_results: max_results) do
      {:ok,
       %{
         source: "gmail",
         count: length(messages),
         messages: messages
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        GmailHelpers.normalize_error(reason)
    end
  end

  defp resolve_max_results(args) do
    args
    |> ActionHelpers.optional_integer("max_results")
    |> normalize_max_results()
  end

  defp normalize_max_results(value) when is_integer(value), do: value |> max(1) |> min(50)
  defp normalize_max_results(_), do: 10
end
