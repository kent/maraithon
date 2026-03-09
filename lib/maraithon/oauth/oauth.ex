defmodule Maraithon.OAuth do
  @moduledoc """
  OAuth token management context.

  Handles storing, retrieving, and refreshing OAuth tokens for external providers.
  """

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.OAuth.Token

  require Logger

  @doc """
  Stores OAuth tokens for a user and provider.

  If a token already exists for this user/provider, it will be updated.
  """
  def store_tokens(user_id, provider, %{} = token_data) do
    attrs = %{
      user_id: user_id,
      provider: provider,
      access_token: token_data.access_token,
      refresh_token: Map.get(token_data, :refresh_token),
      expires_at: calculate_expiry(token_data),
      scopes: Map.get(token_data, :scopes, []),
      metadata: Map.get(token_data, :metadata, %{})
    }

    case get_token(user_id, provider) do
      nil ->
        %Token{}
        |> Token.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> Token.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Gets the OAuth token for a user and provider.

  Returns nil if no token exists.
  """
  def get_token(user_id, provider) do
    Repo.get_by(Token, user_id: user_id, provider: provider)
  end

  @doc """
  Gets a valid access token for a user and provider.

  Automatically refreshes the token if it's expired.
  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  def get_valid_access_token(user_id, provider) do
    case get_token(user_id, provider) do
      nil ->
        {:error, :no_token}

      token ->
        if Token.expired?(token) do
          refresh_and_get_token(token)
        else
          {:ok, token.access_token}
        end
    end
  end

  @doc """
  Refreshes the token if it's expired.

  Returns the updated token or an error.
  """
  def refresh_if_expired(user_id, provider) do
    case get_token(user_id, provider) do
      nil ->
        {:error, :no_token}

      token ->
        if Token.expired?(token) do
          do_refresh(token)
        else
          {:ok, token}
        end
    end
  end

  @doc """
  Revokes and deletes the token for a user and provider.
  """
  def revoke(user_id, provider) do
    case get_token(user_id, provider) do
      nil ->
        {:error, :no_token}

      token ->
        # Try to revoke with the provider first
        revoke_provider_token(token)

        # Delete from database
        Repo.delete(token)
    end
  end

  @doc """
  Lists all tokens for a user.
  """
  def list_user_tokens(user_id) do
    Token
    |> where([t], t.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Lists all tokens for a provider (admin use).
  """
  def list_provider_tokens(provider) do
    Token
    |> where([t], t.provider == ^provider)
    |> Repo.all()
  end

  @doc """
  Lists all tokens expiring within the given seconds.
  Useful for proactive token refresh.
  """
  def list_expiring_tokens(seconds \\ 300) do
    cutoff = DateTime.add(DateTime.utc_now(), seconds, :second)

    Token
    |> where([t], not is_nil(t.expires_at))
    |> where([t], t.expires_at < ^cutoff)
    |> where([t], not is_nil(t.refresh_token))
    |> Repo.all()
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp calculate_expiry(%{expires_in: expires_in}) when is_integer(expires_in) do
    DateTime.add(DateTime.utc_now(), expires_in, :second)
  end

  defp calculate_expiry(%{expires_at: expires_at}) when not is_nil(expires_at) do
    expires_at
  end

  defp calculate_expiry(_), do: nil

  defp refresh_and_get_token(token) do
    case do_refresh(token) do
      {:ok, updated_token} ->
        {:ok, updated_token.access_token}

      error ->
        error
    end
  end

  defp do_refresh(%Token{refresh_token: nil}) do
    {:error, :no_refresh_token}
  end

  defp do_refresh(%Token{provider: "google"} = token) do
    case Maraithon.OAuth.Google.refresh_token(token.refresh_token) do
      {:ok, new_tokens} ->
        store_tokens(token.user_id, "google", %{
          access_token: new_tokens.access_token,
          refresh_token: token.refresh_token,
          expires_in: new_tokens.expires_in,
          scopes: token.scopes,
          metadata: token.metadata
        })

      {:error, reason} ->
        Logger.warning("Failed to refresh Google token",
          user_id: token.user_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp do_refresh(%Token{provider: "notion"} = token) do
    case Maraithon.OAuth.Notion.refresh_token(token.refresh_token) do
      {:ok, new_tokens} ->
        store_tokens(token.user_id, "notion", %{
          access_token: new_tokens.access_token,
          refresh_token: new_tokens.refresh_token || token.refresh_token,
          expires_in: new_tokens.expires_in,
          scopes: token.scopes,
          metadata:
            token.metadata
            |> Map.merge(%{
              "workspace_id" => new_tokens.workspace_id || token.metadata["workspace_id"],
              "workspace_name" => new_tokens.workspace_name || token.metadata["workspace_name"],
              "workspace_icon" => new_tokens.workspace_icon || token.metadata["workspace_icon"],
              "bot_id" => new_tokens.bot_id || token.metadata["bot_id"]
            })
        })

      {:error, reason} ->
        Logger.warning("Failed to refresh Notion token",
          user_id: token.user_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp do_refresh(%Token{provider: provider}) do
    {:error, {:unknown_provider, provider}}
  end

  defp revoke_provider_token(%Token{provider: "google", access_token: access_token}) do
    Maraithon.OAuth.Google.revoke_token(access_token)
  end

  defp revoke_provider_token(%Token{provider: "github", access_token: access_token}) do
    Maraithon.OAuth.GitHub.revoke_token(access_token)
  end

  defp revoke_provider_token(%Token{provider: "linear", access_token: access_token}) do
    Maraithon.OAuth.Linear.revoke_token(access_token)
  end

  defp revoke_provider_token(%Token{provider: "notion", access_token: access_token}) do
    Maraithon.OAuth.Notion.revoke_token(access_token)
  end

  defp revoke_provider_token(%Token{provider: provider, access_token: access_token}) do
    if is_binary(provider) and String.starts_with?(provider, "slack:") do
      Maraithon.OAuth.Slack.revoke_token(access_token)
    else
      :ok
    end
  end
end
