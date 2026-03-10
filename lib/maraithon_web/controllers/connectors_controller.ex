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

  defp provider_label("google"), do: "Google"
  defp provider_label("github"), do: "GitHub"
  defp provider_label("slack"), do: "Slack"
  defp provider_label("telegram"), do: "Telegram"
  defp provider_label("linear"), do: "Linear"
  defp provider_label("notion"), do: "Notion"
  defp provider_label(provider), do: provider

  defp token_for_provider(tokens, "slack") when is_list(tokens) do
    Enum.find(tokens, fn token ->
      is_binary(token.provider) and String.match?(token.provider, ~r/^slack:[^:]+$/)
    end)
  end

  defp token_for_provider(tokens, provider) when is_list(tokens) and is_binary(provider) do
    Enum.find(tokens, &(&1.provider == provider))
  end
end
