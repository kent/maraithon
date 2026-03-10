defmodule Maraithon.Tools.SlackHelpers do
  @moduledoc false

  alias Maraithon.OAuth

  def resolve_access_token(user_id, team_id, opts \\ [])
      when is_binary(user_id) and is_binary(team_id) do
    preference = normalize_preference(Keyword.get(opts, :token_preference, "auto"))
    slack_user_id = Keyword.get(opts, :slack_user_id)
    candidates = token_candidates(user_id, team_id, preference, slack_user_id)

    resolve_from_candidates(user_id, candidates, preference)
  end

  def normalize_error(:no_token), do: {:error, "slack_workspace_not_connected"}
  def normalize_error(:no_user_token), do: {:error, "slack_user_scope_not_connected"}

  def normalize_error({:slack_error, error}) when is_binary(error),
    do: {:error, "slack_api_error: #{error}"}

  def normalize_error(reason), do: {:error, "slack_tool_failed: #{inspect(reason)}"}

  defp resolve_from_candidates(user_id, candidates, preference) do
    initial_error =
      case preference do
        :user -> :no_user_token
        _ -> :no_token
      end

    Enum.reduce_while(candidates, {:error, initial_error}, fn provider, _acc ->
      case OAuth.get_valid_access_token(user_id, provider) do
        {:ok, token} ->
          {:halt, {:ok, %{access_token: token, provider: provider}}}

        {:error, :no_token} ->
          {:cont, {:error, initial_error}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp token_candidates(user_id, team_id, preference, slack_user_id) do
    bot_provider = "slack:#{team_id}"
    user_providers = user_token_providers(user_id, team_id, slack_user_id)

    case preference do
      :user -> user_providers
      :bot -> [bot_provider]
      :auto -> user_providers ++ [bot_provider]
    end
    |> Enum.uniq()
  end

  defp user_token_providers(user_id, team_id, slack_user_id) do
    providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&String.starts_with?(&1, "slack:#{team_id}:user:"))

    if is_binary(slack_user_id) and String.trim(slack_user_id) != "" do
      prioritized = "slack:#{team_id}:user:#{String.trim(slack_user_id)}"
      [prioritized | Enum.reject(providers, &(&1 == prioritized))]
    else
      providers
    end
  end

  defp normalize_preference(value) when value in [:auto, :bot, :user], do: value

  defp normalize_preference(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "user" -> :user
      "bot" -> :bot
      _ -> :auto
    end
  end

  defp normalize_preference(_value), do: :auto
end
