defmodule MaraithonWeb.ConnectorsController do
  use MaraithonWeb, :controller

  alias Maraithon.Connections

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    return_to = ~p"/connectors"

    {snapshot, degraded?} =
      case Connections.safe_dashboard_snapshot(user_id, return_to: return_to) do
        {:ok, snapshot} -> {snapshot, false}
        {:degraded, snapshot} -> {snapshot, true}
      end

    conn =
      conn
      |> maybe_put_oauth_flash(params)
      |> maybe_put_degraded_flash(degraded?)

    render(conn, :index,
      page_title: "Connectors",
      current_path: ~p"/connectors",
      current_user: conn.assigns.current_user,
      connection_user_id: user_id,
      providers: snapshot.providers,
      connected_count: snapshot.connected_count,
      connection_errors: snapshot.errors
    )
  end

  def show(conn, %{"provider" => provider} = params) do
    user_id = conn.assigns.current_user.id
    return_to = ~p"/connectors/#{provider}"

    {snapshot, degraded?} =
      case Connections.safe_dashboard_snapshot(user_id, return_to: return_to) do
        {:ok, snapshot} -> {snapshot, false}
        {:degraded, snapshot} -> {snapshot, true}
      end

    case Enum.find(snapshot.providers, &(&1.provider == provider)) do
      nil ->
        conn
        |> put_flash(:error, "Unknown connector: #{provider}")
        |> redirect(to: ~p"/connectors")

      provider_card ->
        conn =
          conn
          |> maybe_put_oauth_flash(params)
          |> maybe_put_degraded_flash(degraded?)

        render(conn, :show,
          page_title: "#{provider_card.label} Connector",
          current_path: ~p"/connectors",
          current_user: conn.assigns.current_user,
          provider: provider_card,
          token: token_for_provider(snapshot.raw_tokens, provider),
          connection_errors: snapshot.errors
        )
    end
  end

  def disconnect(conn, %{"provider" => provider}) do
    user_id = conn.assigns.current_user.id
    return_to = parse_return_to(conn.params)
    provider_key = disconnect_provider_key(provider, conn.params)
    account_label = normalize_account_label(conn.params["account_label"])

    conn =
      case Connections.disconnect(user_id, provider_key) do
        {:ok, _deleted} ->
          put_flash(conn, :info, disconnect_success_message(provider_key, account_label))

        {:error, :no_token} ->
          put_flash(conn, :error, "#{provider_label(provider_key)} is not connected")

        {:error, :unsupported_provider} ->
          put_flash(conn, :error, "Unsupported provider")

        {:error, reason} ->
          put_flash(
            conn,
            :error,
            "Failed to disconnect #{provider_label(provider_key)}: #{inspect(reason)}"
          )
      end

    redirect(conn, to: return_to)
  end

  def legacy_redirect(conn, _params) do
    redirect(conn, to: ~p"/connectors")
  end

  defp maybe_put_oauth_flash(conn, %{"oauth_status" => "connected", "oauth_message" => message})
       when is_binary(message) do
    put_flash(conn, :info, message)
  end

  defp maybe_put_oauth_flash(conn, %{"oauth_status" => "error", "oauth_message" => message})
       when is_binary(message) do
    put_flash(conn, :error, message)
  end

  defp maybe_put_oauth_flash(conn, _params), do: conn

  defp maybe_put_degraded_flash(conn, true) do
    put_flash(conn, :error, "Connection inventory is temporarily degraded.")
  end

  defp maybe_put_degraded_flash(conn, false), do: conn

  defp parse_return_to(%{"return_to" => return_to}) when is_binary(return_to) do
    if String.starts_with?(return_to, "/connectors"), do: return_to, else: ~p"/connectors"
  end

  defp parse_return_to(_params), do: ~p"/connectors"

  defp provider_label("github"), do: "GitHub"
  defp provider_label("google"), do: "Google"
  defp provider_label("google:" <> _), do: "Google"
  defp provider_label("slack"), do: "Slack"
  defp provider_label("slack:" <> _), do: "Slack"
  defp provider_label("telegram"), do: "Telegram"
  defp provider_label("linear"), do: "Linear"
  defp provider_label("notaui"), do: "Notaui"
  defp provider_label("notion"), do: "Notion"
  defp provider_label(provider), do: provider

  defp disconnect_provider_key(provider, params) when is_binary(provider) and is_map(params) do
    case Map.get(params, "provider_key") do
      value when is_binary(value) ->
        key = String.trim(value)
        if provider_key_matches_provider?(provider, key), do: key, else: provider

      _ ->
        provider
    end
  end

  defp provider_key_matches_provider?(provider, key)
       when is_binary(provider) and is_binary(key) do
    key == provider or String.starts_with?(key, "#{provider}:")
  end

  defp provider_key_matches_provider?(_provider, _key), do: false

  defp normalize_account_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      label -> label
    end
  end

  defp normalize_account_label(_value), do: nil

  defp disconnect_success_message("google:" <> _provider_key, account_label)
       when is_binary(account_label) do
    "Google account #{account_label} disconnected"
  end

  defp disconnect_success_message(provider, _account_label) do
    "#{provider_label(provider)} disconnected"
  end

  defp token_for_provider(tokens, "slack") when is_list(tokens) do
    Enum.find(tokens, fn token ->
      is_binary(token.provider) and String.match?(token.provider, ~r/^slack:[^:]+$/)
    end)
  end

  defp token_for_provider(tokens, "google") when is_list(tokens) do
    tokens
    |> Enum.filter(fn token ->
      provider = token.provider
      provider == "google" or (is_binary(provider) and String.starts_with?(provider, "google:"))
    end)
    |> Enum.max_by(&token_timestamp_sort_value(&1.updated_at), fn -> nil end)
  end

  defp token_for_provider(tokens, provider) when is_list(tokens) and is_binary(provider) do
    Enum.find(tokens, &(&1.provider == provider))
  end

  defp token_timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp token_timestamp_sort_value(%NaiveDateTime{} = value) do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, datetime} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp token_timestamp_sort_value(_value), do: 0
end
