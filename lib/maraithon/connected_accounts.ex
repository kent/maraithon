defmodule Maraithon.ConnectedAccounts do
  @moduledoc """
  Provider-agnostic connected account read/write context.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Token
  alias Maraithon.Repo

  def list_for_user(user_id) when is_binary(user_id) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id)
    |> order_by([account], asc: account.provider)
    |> Repo.all()
  end

  def list_connected_provider(provider) when is_binary(provider) do
    ConnectedAccount
    |> where([account], account.provider == ^provider and account.status == "connected")
    |> order_by([account], asc: account.user_id)
    |> Repo.all()
  end

  def has_any?(user_id) when is_binary(user_id) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id)
    |> Repo.exists?()
  end

  def has_any?(_), do: false

  def get(user_id, provider) when is_binary(user_id) and is_binary(provider) do
    Repo.get_by(ConnectedAccount, user_id: user_id, provider: provider)
  end

  def get_connected_by_external_account(provider, external_account_id)
      when is_binary(provider) and is_binary(external_account_id) do
    Repo.get_by(ConnectedAccount,
      provider: provider,
      external_account_id: external_account_id,
      status: "connected"
    )
  end

  def upsert_from_oauth(user_id, provider, token_data)
      when is_binary(user_id) and is_binary(provider) do
    now = DateTime.utc_now()

    attrs = %{
      user_id: user_id,
      provider: provider,
      status: "connected",
      access_token: token_data[:access_token] || token_data["access_token"],
      refresh_token: token_data[:refresh_token] || token_data["refresh_token"],
      expires_at: token_data[:expires_at] || token_data["expires_at"],
      scopes: normalize_scopes(token_data[:scopes] || token_data["scopes"]),
      metadata: normalize_metadata(token_data[:metadata] || token_data["metadata"]),
      connected_at: now,
      last_refreshed_at: now,
      external_account_id:
        token_data[:external_account_id] || token_data["external_account_id"] ||
          metadata_external_account_id(token_data[:metadata] || token_data["metadata"])
    }

    case get(user_id, provider) do
      nil ->
        %ConnectedAccount{}
        |> ConnectedAccount.changeset(attrs)
        |> Repo.insert()

      account ->
        account
        |> ConnectedAccount.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_manual(user_id, provider, attrs \\ %{})
      when is_binary(user_id) and is_binary(provider) and is_map(attrs) do
    now = DateTime.utc_now()

    merged_attrs =
      attrs
      |> Map.take([
        :external_account_id,
        "external_account_id",
        :metadata,
        "metadata",
        :scopes,
        "scopes"
      ])
      |> normalize_attrs()
      |> Map.merge(%{
        user_id: user_id,
        provider: provider,
        status: "connected",
        connected_at: now,
        last_refreshed_at: now
      })

    case get(user_id, provider) do
      nil ->
        %ConnectedAccount{}
        |> ConnectedAccount.changeset(merged_attrs)
        |> Repo.insert()

      account ->
        account
        |> ConnectedAccount.changeset(merged_attrs)
        |> Repo.update()
    end
  end

  def mark_disconnected(user_id, provider) when is_binary(user_id) and is_binary(provider) do
    case get(user_id, provider) do
      nil ->
        :ok

      account ->
        account
        |> ConnectedAccount.changeset(%{
          status: "disconnected",
          access_token: nil,
          refresh_token: nil,
          expires_at: nil,
          last_refreshed_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  def mark_error(user_id, provider, reason) when is_binary(user_id) and is_binary(provider) do
    case get(user_id, provider) do
      nil ->
        :ok

      account ->
        now = DateTime.utc_now()

        metadata =
          account.metadata
          |> normalize_metadata()
          |> Map.put("last_error", %{
            "reason" => normalize_error_reason(reason),
            "at" => DateTime.to_iso8601(now)
          })

        account
        |> ConnectedAccount.changeset(%{
          status: "error",
          metadata: metadata,
          last_refreshed_at: now
        })
        |> Repo.update()
    end
  end

  def sync_from_oauth_tokens(user_id) when is_binary(user_id) do
    OAuth.list_user_tokens(user_id)
    |> Enum.map(&sync_token/1)
  end

  def sync_from_oauth_tokens(_), do: []

  defp sync_token(%Token{} = token) do
    upsert_from_oauth(token.user_id, token.provider, %{
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      scopes: token.scopes,
      metadata: token.metadata
    })
  end

  defp normalize_scopes(scopes) when is_list(scopes), do: scopes
  defp normalize_scopes(_), do: []

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp normalize_error_reason(reason) when is_binary(reason), do: reason
  defp normalize_error_reason(reason), do: inspect(reason)

  defp metadata_external_account_id(metadata) when is_map(metadata) do
    metadata["id"] || metadata[:id] || metadata["github_id"] || metadata[:github_id] ||
      metadata["workspace_id"] || metadata[:workspace_id]
  end

  defp metadata_external_account_id(_), do: nil

  defp normalize_attrs(attrs) do
    %{
      external_account_id: attrs[:external_account_id] || attrs["external_account_id"],
      metadata: normalize_metadata(attrs[:metadata] || attrs["metadata"]),
      scopes: normalize_scopes(attrs[:scopes] || attrs["scopes"])
    }
  end
end
