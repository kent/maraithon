defmodule Maraithon.Tools.GmailHelpers do
  @moduledoc false

  alias Maraithon.Connectors.Gmail
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google

  @default_api_base "https://gmail.googleapis.com/gmail/v1"

  def list_messages(user_id, opts \\ []) when is_binary(user_id) do
    max_results = Keyword.get(opts, :max_results, 10)
    query = Keyword.get(opts, :query)
    label_ids = Keyword.get(opts, :label_ids, ["INBOX"])
    provider = Keyword.get(opts, :provider, "google")

    with {:ok, access_token} <- OAuth.get_valid_access_token(user_id, provider),
         {:ok, message_ids} <- fetch_message_ids(access_token, max_results, query, label_ids) do
      messages =
        message_ids
        |> Enum.map(&Gmail.fetch_message(access_token, &1, access_token: true))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, message} -> message end)

      {:ok, messages}
    end
  end

  def get_message(user_id, message_id) when is_binary(user_id) and is_binary(message_id) do
    Gmail.fetch_message(user_id, message_id)
  end

  def normalize_error(:no_token), do: {:error, "google_account_not_connected"}

  def normalize_error({:http_status, status, body}),
    do: {:error, "gmail_api_failed: #{status} #{body}"}

  def normalize_error(reason), do: {:error, "gmail_tool_failed: #{inspect(reason)}"}

  defp fetch_message_ids(access_token, max_results, query, label_ids) do
    params =
      %{}
      |> Map.put(:maxResults, max_results)
      |> maybe_put(:q, query)
      |> maybe_put(:labelIds, encode_label_ids(label_ids))
      |> URI.encode_query()

    url = "#{api_base_url()}/users/me/messages?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        message_ids =
          messages
          |> Enum.take(max_results)
          |> Enum.map(fn message -> message["id"] end)
          |> Enum.filter(&is_binary/1)

        {:ok, message_ids}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp encode_label_ids([]), do: nil
  defp encode_label_ids(nil), do: nil
  defp encode_label_ids(ids) when is_list(ids), do: Enum.join(ids, ",")

  defp api_base_url do
    Application.get_env(:maraithon, :gmail, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end
end
