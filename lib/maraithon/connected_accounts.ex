defmodule Maraithon.ConnectedAccounts do
  @moduledoc """
  Provider-agnostic connected account read/write context.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.Telegram
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Token
  alias Maraithon.Repo

  require Logger

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
    normalized_external_account_id = normalize_destination(external_account_id)

    case normalized_external_account_id do
      nil ->
        nil

      value ->
        if provider == "telegram" do
          find_connected_by_metadata_identifier(provider, value) ||
            find_connected_by_external_id(provider, value)
        else
          find_connected_by_external_id(provider, value) ||
            find_connected_by_metadata_identifier(provider, value)
        end
    end
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
        normalized_reason = normalize_error_reason(reason)

        metadata =
          account.metadata
          |> normalize_metadata()
          |> Map.put("last_error", %{
            "reason" => normalized_reason,
            "at" => DateTime.to_iso8601(now)
          })

        result =
          account
          |> ConnectedAccount.changeset(%{
            status: "error",
            metadata: metadata,
            last_refreshed_at: now
          })
          |> Repo.update()

        case result do
          {:ok, updated_account} = ok ->
            maybe_send_reauth_notification(updated_account, normalized_reason)
            ok

          error ->
            error
        end
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
      metadata["workspace_id"] || metadata[:workspace_id] ||
      metadata["default_account_id"] || metadata[:default_account_id]
  end

  defp metadata_external_account_id(_), do: nil

  defp find_connected_by_metadata_identifier(provider, external_account_id)
       when is_binary(provider) and is_binary(external_account_id) do
    ConnectedAccount
    |> where([account], account.provider == ^provider and account.status == "connected")
    |> order_by([account], desc: account.updated_at, desc: account.inserted_at, desc: account.id)
    |> Repo.all()
    |> Enum.find(fn account ->
      metadata_identifiers(account.metadata)
      |> Enum.member?(external_account_id)
    end)
  end

  defp find_connected_by_metadata_identifier(_provider, _external_account_id), do: nil

  defp find_connected_by_external_id(provider, external_account_id)
       when is_binary(provider) and is_binary(external_account_id) do
    Repo.get_by(ConnectedAccount,
      provider: provider,
      external_account_id: external_account_id,
      status: "connected"
    )
  end

  defp find_connected_by_external_id(_provider, _external_account_id), do: nil

  defp metadata_identifiers(metadata) when is_map(metadata) do
    metadata
    |> normalize_metadata()
    |> then(fn value ->
      [
        fetch_map_value(value, "chat_id"),
        fetch_map_value(value, "telegram_user_id"),
        fetch_map_value(value, "id"),
        fetch_map_value(value, "github_id"),
        fetch_map_value(value, "workspace_id"),
        fetch_map_value(value, "default_account_id"),
        fetch_map_value(value, "account_email"),
        fetch_map_value(value, "email")
      ] ++
        metadata_account_ids(value)
    end)
    |> Enum.map(&normalize_destination/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp metadata_identifiers(_metadata), do: []

  defp metadata_account_ids(metadata) when is_map(metadata) do
    metadata
    |> fetch_map_value("accounts")
    |> List.wrap()
    |> Enum.map(fn
      account when is_map(account) -> fetch_map_value(account, "id")
      _ -> nil
    end)
  end

  defp metadata_account_ids(_metadata), do: []

  defp normalize_attrs(attrs) do
    %{
      external_account_id: attrs[:external_account_id] || attrs["external_account_id"],
      metadata: normalize_metadata(attrs[:metadata] || attrs["metadata"]),
      scopes: normalize_scopes(attrs[:scopes] || attrs["scopes"])
    }
  end

  defp maybe_send_reauth_notification(%ConnectedAccount{} = account, reason)
       when is_binary(reason) do
    if reauth_required_reason?(reason) and reauth_notification_pending?(account.metadata, reason) do
      case telegram_destination(account.user_id) do
        nil ->
          :ok

        destination ->
          send_reauth_notification(account, destination, reason)
      end
    else
      :ok
    end
  end

  defp maybe_send_reauth_notification(_account, _reason), do: :ok

  defp send_reauth_notification(%ConnectedAccount{} = account, destination, reason) do
    module = telegram_module()
    reconnect_url = reconnect_url(account.provider)
    message = reauth_notification_message(account, reconnect_url)

    case module.send_message(destination, message, parse_mode: "HTML") do
      {:ok, _result} ->
        mark_reauth_notification_sent(account, destination, reason)

      {:error, notification_error} ->
        Logger.warning("Failed to send reauth Telegram notification",
          user_id: account.user_id,
          provider: account.provider,
          reason: inspect(notification_error)
        )

        :ok
    end
  rescue
    notification_error ->
      Logger.warning("Reauth Telegram notification crashed",
        user_id: account.user_id,
        provider: account.provider,
        reason: Exception.message(notification_error)
      )

      :ok
  end

  defp reauth_required_reason?("oauth_reauth_required"), do: true
  defp reauth_required_reason?("oauth_missing_refresh_token"), do: true
  defp reauth_required_reason?(_reason), do: false

  defp reauth_notification_pending?(metadata, reason) do
    notification =
      metadata
      |> normalize_metadata()
      |> fetch_map_value("reauth_notification")

    sent_at = is_map(notification) && fetch_map_value(notification, "sent_at")
    sent_reason = is_map(notification) && fetch_map_value(notification, "reason")

    not (is_binary(sent_at) and sent_at != "" and sent_reason == reason)
  end

  defp telegram_destination(user_id) when is_binary(user_id) do
    if telegram_notifications_enabled?() do
      case get(user_id, "telegram") do
        %ConnectedAccount{status: "connected"} = account ->
          value =
            account.external_account_id ||
              fetch_map_value(normalize_metadata(account.metadata), "chat_id")

          normalize_destination(value)

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp telegram_destination(_user_id), do: nil

  defp telegram_notifications_enabled? do
    module = telegram_module()

    if function_exported?(module, :configured?, 0) do
      module.configured?()
    else
      true
    end
  end

  defp telegram_module do
    Application.get_env(:maraithon, :connected_accounts, [])
    |> Keyword.get(:telegram_module, Telegram)
  end

  defp reconnect_url(provider) when is_binary(provider) do
    base =
      Application.get_env(:maraithon, :connected_accounts, [])
      |> Keyword.get_lazy(:reconnect_base_url, fn -> MaraithonWeb.Endpoint.url() end)
      |> to_string()
      |> String.trim_trailing("/")

    root = provider_root(provider)
    path = if root == "", do: "/connectors", else: "/connectors/#{root}"
    if base == "", do: path, else: base <> path
  end

  defp reconnect_url(_provider), do: "/connectors"

  defp provider_root(provider) when is_binary(provider) do
    provider
    |> String.split(":", parts: 2)
    |> List.first()
    |> case do
      nil -> ""
      "" -> ""
      value -> value
    end
  end

  defp provider_root(_provider), do: ""

  defp reauth_notification_message(%ConnectedAccount{} = account, reconnect_url) do
    provider_label = provider_label(account.provider)
    account_label = account_label(account)

    """
    <b>Maraithon action required</b>
    #{html_escape(provider_label)} account #{html_escape(account_label)} needs re-authentication.
    <a href="#{html_escape(reconnect_url)}">Reconnect in Maraithon</a>
    """
    |> String.trim()
  end

  defp provider_label("google"), do: "Google"
  defp provider_label("google:" <> _), do: "Google"
  defp provider_label("slack"), do: "Slack"
  defp provider_label("slack:" <> _), do: "Slack"
  defp provider_label("telegram"), do: "Telegram"
  defp provider_label("github"), do: "GitHub"
  defp provider_label("linear"), do: "Linear"
  defp provider_label("notion"), do: "Notion"
  defp provider_label(provider) when is_binary(provider), do: provider
  defp provider_label(_provider), do: "Connector"

  defp account_label(%ConnectedAccount{} = account) do
    metadata = normalize_metadata(account.metadata)

    normalize_destination(
      fetch_map_value(metadata, "account_email") || fetch_map_value(metadata, "email")
    ) || provider_suffix(account.provider) || provider_label(account.provider)
  end

  defp account_label(_account), do: "account"

  defp provider_suffix(provider) when is_binary(provider) do
    case String.split(provider, ":", parts: 2) do
      [_root, suffix] -> normalize_destination(suffix)
      _ -> nil
    end
  end

  defp provider_suffix(_provider), do: nil

  defp mark_reauth_notification_sent(%ConnectedAccount{} = account, destination, reason) do
    metadata =
      account.metadata
      |> normalize_metadata()
      |> Map.put("reauth_notification", %{
        "reason" => reason,
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "destination" => to_string(destination)
      })

    _ =
      account
      |> ConnectedAccount.changeset(%{metadata: metadata})
      |> Repo.update()

    :ok
  end

  defp normalize_destination(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      destination -> destination
    end
  end

  defp normalize_destination(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_destination(_value), do: nil

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

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp html_escape(_value), do: ""
end
