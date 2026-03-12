defmodule Maraithon.OAuth do
  @moduledoc """
  OAuth token management context.

  Handles storing, retrieving, and refreshing OAuth tokens for external providers.
  """

  import Ecto.Query
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.OAuth.Token

  require Logger

  @doc """
  Stores OAuth tokens for a user and provider.

  If a token already exists for this user/provider, it will be updated.
  """
  def store_tokens(user_id, provider, %{} = token_data) do
    existing = get_exact_token(user_id, provider)

    attrs = %{
      user_id: user_id,
      provider: provider,
      access_token: token_field(token_data, :access_token),
      refresh_token: merge_refresh_token(token_data, existing),
      expires_at: calculate_expiry(token_data) || existing_field(existing, :expires_at),
      scopes: merge_scopes(token_data, existing),
      metadata: merge_metadata(token_data, existing)
    }

    result =
      case existing do
        nil ->
          %Token{}
          |> Token.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> Token.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, token} = ok ->
        _ =
          ConnectedAccounts.upsert_from_oauth(user_id, provider, %{
            access_token: token.access_token,
            refresh_token: token.refresh_token,
            expires_at: token.expires_at,
            scopes: token.scopes,
            metadata: token.metadata,
            external_account_id: token_field(token_data, :external_account_id)
          })

        ok

      error ->
        error
    end
  end

  @doc """
  Gets the OAuth token for a user and provider.

  Returns nil if no token exists.
  """
  def get_token(user_id, "google") do
    case get_exact_token(user_id, "google") do
      %Token{} = token ->
        if reauth_required_account?(user_id, token.provider) do
          latest_google_account_token(user_id)
        else
          token
        end

      nil ->
        latest_google_account_token(user_id)
    end
  end

  def get_token(user_id, provider) do
    get_exact_token(user_id, provider)
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
        if reauth_required_account?(token.user_id, token.provider) do
          {:error, :reauth_required}
        else
          if Token.expired?(token) do
            refresh_and_get_token(token)
          else
            {:ok, token.access_token}
          end
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
        if reauth_required_account?(token.user_id, token.provider) do
          {:error, :reauth_required}
        else
          if Token.expired?(token) do
            do_refresh(token)
          else
            {:ok, token}
          end
        end
    end
  end

  @doc """
  Refreshes the token when it expires within the given window.

  Returns the updated token or an error.
  """
  def refresh_if_expiring(user_id, provider, within_seconds \\ 300) do
    case get_token(user_id, provider) do
      nil ->
        {:error, :no_token}

      token ->
        if reauth_required_account?(token.user_id, token.provider) do
          {:error, :reauth_required}
        else
          if token_expiring_within?(token, within_seconds) do
            do_refresh(token)
          else
            {:ok, token}
          end
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
        case Repo.delete(token) do
          {:ok, _deleted} = ok ->
            _ = ConnectedAccounts.mark_disconnected(user_id, provider)
            ok

          error ->
            error
        end
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

  defp get_exact_token(user_id, provider) when is_binary(user_id) and is_binary(provider) do
    Repo.get_by(Token, user_id: user_id, provider: provider)
  end

  defp get_exact_token(_user_id, _provider), do: nil

  defp token_expiring_within?(%Token{expires_at: nil}, _within_seconds), do: false

  defp token_expiring_within?(%Token{expires_at: expires_at}, within_seconds)
       when is_integer(within_seconds) and within_seconds >= 0 do
    cutoff = DateTime.add(DateTime.utc_now(), within_seconds, :second)
    DateTime.compare(expires_at, cutoff) != :gt
  end

  defp token_expiring_within?(_token, _within_seconds), do: false

  defp refresh_and_get_token(token) do
    case do_refresh(token) do
      {:ok, updated_token} ->
        {:ok, updated_token.access_token}

      error ->
        error
    end
  end

  defp do_refresh(%Token{refresh_token: nil} = token) do
    _ = ConnectedAccounts.mark_error(token.user_id, token.provider, "oauth_missing_refresh_token")
    {:error, :no_refresh_token}
  end

  defp do_refresh(%Token{provider: "google"} = token) do
    refresh_google_token(token, "google")
  end

  defp do_refresh(%Token{provider: "google:" <> _ = provider} = token) do
    refresh_google_token(token, provider)
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
        if reauth_required_refresh_error?(reason) do
          _ = ConnectedAccounts.mark_error(token.user_id, "notion", "oauth_reauth_required")
        end

        Logger.warning("Failed to refresh Notion token",
          user_id: token.user_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp do_refresh(%Token{provider: "notaui"} = token) do
    case Maraithon.OAuth.Notaui.refresh_token(token.refresh_token) do
      {:ok, new_tokens} ->
        scopes =
          case split_scope_string(new_tokens.scope) do
            [] -> token.scopes
            values -> values
          end

        metadata =
          token.metadata
          |> put_metadata_if_present("token_type", new_tokens.token_type)

        store_tokens(token.user_id, "notaui", %{
          access_token: new_tokens.access_token,
          refresh_token: new_tokens.refresh_token || token.refresh_token,
          expires_in: new_tokens.expires_in,
          scopes: scopes,
          metadata: metadata
        })

      {:error, reason} ->
        if reauth_required_refresh_error?(reason) do
          _ = ConnectedAccounts.mark_error(token.user_id, "notaui", "oauth_reauth_required")
        end

        Logger.warning("Failed to refresh Notaui token",
          user_id: token.user_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp do_refresh(%Token{provider: provider} = token) when is_binary(provider) do
    if String.starts_with?(provider, "slack:") do
      case Maraithon.OAuth.Slack.refresh_token(token.refresh_token) do
        {:ok, new_tokens} ->
          scopes =
            case split_scope_string(new_tokens.scope) do
              [] -> token.scopes
              values -> values
            end

          metadata =
            token.metadata
            |> put_metadata_if_present(
              "team_id",
              new_tokens.team_id || metadata_value(token.metadata, "team_id")
            )
            |> put_metadata_if_present(
              "team_name",
              new_tokens.team_name || metadata_value(token.metadata, "team_name")
            )
            |> put_metadata_if_present(
              "bot_user_id",
              new_tokens.bot_user_id || metadata_value(token.metadata, "bot_user_id")
            )
            |> put_metadata_if_present(
              "app_id",
              new_tokens.app_id || metadata_value(token.metadata, "app_id")
            )

          store_tokens(token.user_id, provider, %{
            access_token: new_tokens.access_token,
            refresh_token: new_tokens.refresh_token || token.refresh_token,
            expires_in: new_tokens.expires_in,
            scopes: scopes,
            metadata: metadata
          })

        {:error, reason} ->
          if reauth_required_refresh_error?(reason) do
            _ = ConnectedAccounts.mark_error(token.user_id, provider, "oauth_reauth_required")
          end

          Logger.warning("Failed to refresh Slack token",
            user_id: token.user_id,
            provider: provider,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      {:error, {:unknown_provider, provider}}
    end
  end

  defp do_refresh(%Token{provider: provider}) do
    {:error, {:unknown_provider, provider}}
  end

  defp refresh_google_token(token, provider) do
    case Maraithon.OAuth.Google.refresh_token(token.refresh_token) do
      {:ok, new_tokens} ->
        scopes =
          case split_scope_string(new_tokens.scope) do
            [] -> token.scopes
            values -> values
          end

        store_tokens(token.user_id, provider, %{
          access_token: new_tokens.access_token,
          refresh_token: refresh_token_or_existing(new_tokens.refresh_token, token.refresh_token),
          expires_in: new_tokens.expires_in,
          scopes: scopes,
          metadata: token.metadata
        })

      {:error, reason} ->
        if reauth_required_refresh_error?(reason) do
          _ = ConnectedAccounts.mark_error(token.user_id, provider, "oauth_reauth_required")
        end

        Logger.warning("Failed to refresh Google token",
          user_id: token.user_id,
          provider: provider,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp token_field(token_data, key) when is_map(token_data) and is_atom(key) do
    case Map.fetch(token_data, key) do
      {:ok, value} -> value
      :error -> Map.get(token_data, Atom.to_string(key))
    end
  end

  defp merge_refresh_token(token_data, existing) do
    token_field(token_data, :refresh_token) || existing_field(existing, :refresh_token)
  end

  defp merge_scopes(token_data, existing) do
    case token_field(token_data, :scopes) do
      scopes when is_list(scopes) -> scopes
      _ -> existing_field(existing, :scopes) || []
    end
  end

  defp merge_metadata(token_data, existing) do
    case token_field(token_data, :metadata) do
      metadata when is_map(metadata) -> metadata
      _ -> existing_field(existing, :metadata) || %{}
    end
  end

  defp existing_field(nil, _field), do: nil
  defp existing_field(%Token{} = token, field), do: Map.get(token, field)

  defp refresh_token_or_existing(new_refresh_token, _existing_refresh_token)
       when is_binary(new_refresh_token) and new_refresh_token != "" do
    new_refresh_token
  end

  defp refresh_token_or_existing(_new_refresh_token, existing_refresh_token),
    do: existing_refresh_token

  defp reauth_required_refresh_error?(reason) do
    text = inspect(reason) |> String.downcase()

    String.contains?(text, "invalid_grant") or String.contains?(text, "expired or revoked") or
      String.contains?(text, "has been revoked") or
      String.contains?(text, "invalid_refresh_token") or String.contains?(text, "token_revoked")
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

  defp revoke_provider_token(%Token{provider: "notaui", access_token: access_token}) do
    Maraithon.OAuth.Notaui.revoke_token(access_token)
  end

  defp revoke_provider_token(%Token{provider: provider, access_token: access_token}) do
    cond do
      is_binary(provider) and String.starts_with?(provider, "google:") ->
        Maraithon.OAuth.Google.revoke_token(access_token)

      is_binary(provider) and String.starts_with?(provider, "slack:") ->
        Maraithon.OAuth.Slack.revoke_token(access_token)

      true ->
        :ok
    end
  end

  defp split_scope_string(nil), do: []
  defp split_scope_string(""), do: []

  defp split_scope_string(scope_string) when is_binary(scope_string) do
    scope_string
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    metadata[key] || metadata[String.to_atom(key)]
  rescue
    ArgumentError -> metadata[key]
  end

  defp metadata_value(_metadata, _key), do: nil

  defp put_metadata_if_present(metadata, _key, nil), do: metadata
  defp put_metadata_if_present(metadata, key, value), do: Map.put(metadata, key, value)

  defp latest_google_account_token(user_id) when is_binary(user_id) do
    account_by_provider =
      ConnectedAccounts.list_for_user(user_id)
      |> Map.new(&{&1.provider, &1})

    Token
    |> where([t], t.user_id == ^user_id)
    |> where([t], like(t.provider, "google:%"))
    |> Repo.all()
    |> Enum.max_by(
      fn token ->
        account = Map.get(account_by_provider, token.provider)
        google_token_rank(token, account)
      end,
      fn -> nil end
    )
  end

  defp latest_google_account_token(_user_id), do: nil

  defp google_token_rank(%Token{} = token, account) do
    account_score =
      cond do
        reauth_required_account?(token.user_id, token.provider) -> 0
        account && account.status == "connected" -> 3
        account && account.status == "error" -> 1
        true -> 2
      end

    freshness_score = token_freshness_score(token.expires_at)

    refresh_score = if is_nil(token.refresh_token), do: 0, else: 1
    updated_score = token_timestamp_sort_value(token.updated_at)

    {account_score, freshness_score, refresh_score, updated_score}
  end

  defp google_token_rank(_token, _account), do: {0, 0, 0, 0}

  defp token_freshness_score(nil), do: 2

  defp token_freshness_score(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: 2, else: 0
  end

  defp token_freshness_score(%NaiveDateTime{} = expires_at) do
    case DateTime.from_naive(expires_at, "Etc/UTC") do
      {:ok, datetime} -> token_freshness_score(datetime)
      {:error, _reason} -> 0
    end
  end

  defp token_freshness_score(_expires_at), do: 0

  defp reauth_required_account?(user_id, provider)
       when is_binary(user_id) and is_binary(provider) do
    case ConnectedAccounts.get(user_id, provider) do
      %{status: "error", metadata: metadata} ->
        metadata
        |> account_error_reason()
        |> reauth_required_reason?()

      _ ->
        false
    end
  end

  defp reauth_required_account?(_user_id, _provider), do: false

  defp account_error_reason(metadata) when is_map(metadata) do
    metadata
    |> fetch_map_value("last_error")
    |> case do
      value when is_map(value) -> fetch_map_value(value, "reason")
      _ -> nil
    end
    |> normalize_text()
  end

  defp account_error_reason(_metadata), do: nil

  defp reauth_required_reason?(reason) when is_binary(reason) do
    reason in ["oauth_reauth_required", "oauth_missing_refresh_token"]
  end

  defp reauth_required_reason?(_reason), do: false

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp token_timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp token_timestamp_sort_value(%NaiveDateTime{} = value) do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, datetime} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp token_timestamp_sort_value(_value), do: 0
end
