defmodule MaraithonWeb.ConnectorsController do
  use MaraithonWeb, :controller

  alias Maraithon.Connections

  def index(conn, params) do
    user_id = normalize_user_id(params["user_id"])
    return_to = ~p"/connectors?user_id=#{user_id}"

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
      connection_user_id: user_id,
      providers: snapshot.providers,
      raw_connections: snapshot.raw_tokens,
      connection_errors: snapshot.errors
    )
  end

  def disconnect(conn, %{"provider" => provider} = params) do
    user_id = normalize_user_id(params["user_id"])

    conn =
      case Connections.disconnect(user_id, provider) do
        {:ok, _deleted} ->
          put_flash(conn, :info, "#{provider_label(provider)} disconnected")

        {:error, :no_token} ->
          put_flash(conn, :error, "#{provider_label(provider)} is not connected")

        {:error, :unsupported_provider} ->
          put_flash(conn, :error, "Unsupported provider")

        {:error, reason} ->
          put_flash(
            conn,
            :error,
            "Failed to disconnect #{provider_label(provider)}: #{inspect(reason)}"
          )
      end

    redirect(conn, to: ~p"/connectors?user_id=#{user_id}")
  end

  def legacy_redirect(conn, params) do
    user_id =
      case Map.get(params, "user_id") do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    if is_nil(user_id) do
      redirect(conn, to: ~p"/connectors")
    else
      redirect(conn, to: ~p"/connectors?user_id=#{user_id}")
    end
  end

  defp normalize_user_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> Connections.default_user_id()
      user_id -> user_id
    end
  end

  defp normalize_user_id(_value), do: Connections.default_user_id()

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

  defp provider_label("google"), do: "Google"
  defp provider_label("github"), do: "GitHub"
  defp provider_label("linear"), do: "Linear"
  defp provider_label("notion"), do: "Notion"
  defp provider_label(provider), do: provider
end
