defmodule MaraithonWeb.OAuthController do
  @moduledoc """
  OAuth flow controller for external service authentication.

  Handles OAuth authorization initiation and callback processing.
  """

  use MaraithonWeb, :controller

  alias Maraithon.OAuth
  alias Maraithon.OAuth.{Google, Slack}
  alias Maraithon.Connectors.{GoogleCalendar, Gmail}

  require Logger

  @doc """
  Initiates Google OAuth flow.

  GET /auth/google?scopes=calendar,gmail&user_id=xxx

  Query parameters:
  - scopes: Comma-separated list of services (calendar, gmail)
  - user_id: Your application's user identifier

  Redirects user to Google's consent screen.
  """
  def google(conn, params) do
    user_id = params["user_id"]
    services = parse_scopes(params["scopes"])

    if is_nil(user_id) or user_id == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "user_id is required"})
    else
      if Enum.empty?(services) do
        conn
        |> put_status(:bad_request)
        |> json(%{error: "scopes is required (e.g., scopes=calendar,gmail)"})
      else
        scopes = Google.scopes_for(services)

        # State encodes user_id and requested services for the callback
        state = encode_state(user_id, services)
        auth_url = Google.authorize_url(scopes, state)

        redirect(conn, external: auth_url)
      end
    end
  end

  @doc """
  Handles Google OAuth callback.

  GET /auth/google/callback?code=xxx&state=xxx

  Exchanges the authorization code for tokens, stores them,
  and sets up watches for the requested services.
  """
  def google_callback(conn, %{"code" => code, "state" => state}) do
    case decode_state(state) do
      {:ok, user_id, services} ->
        handle_google_tokens(conn, code, user_id, services)

      {:error, reason} ->
        Logger.warning("Invalid OAuth state", reason: inspect(reason))

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid state parameter"})
    end
  end

  def google_callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.warning("Google OAuth error", error: error, description: description)

    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "OAuth authorization failed",
      details: %{error: error, description: description}
    })
  end

  def google_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing code or state parameter"})
  end

  # ===========================================================================
  # Slack OAuth
  # ===========================================================================

  @doc """
  Initiates Slack OAuth flow.

  GET /auth/slack?user_id=xxx

  Redirects user to Slack's authorization page.
  """
  def slack(conn, params) do
    user_id = params["user_id"]

    if is_nil(user_id) or user_id == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "user_id is required"})
    else
      state = encode_slack_state(user_id)
      auth_url = Slack.authorize_url(Slack.default_scopes(), state)
      redirect(conn, external: auth_url)
    end
  end

  @doc """
  Handles Slack OAuth callback.

  GET /auth/slack/callback?code=xxx&state=xxx
  """
  def slack_callback(conn, %{"code" => code, "state" => state}) do
    case decode_slack_state(state) do
      {:ok, user_id} ->
        handle_slack_tokens(conn, code, user_id)

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid state parameter"})
    end
  end

  def slack_callback(conn, %{"error" => error}) do
    Logger.warning("Slack OAuth error", error: error)

    conn
    |> put_status(:bad_request)
    |> json(%{error: "OAuth authorization failed", details: error})
  end

  def slack_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing code or state parameter"})
  end

  defp handle_slack_tokens(conn, code, user_id) do
    case Slack.exchange_code(code) do
      {:ok, tokens} ->
        # Store the tokens - use team_id as part of the provider key
        token_data = %{
          access_token: tokens.access_token,
          scopes: String.split(tokens.scope || "", ","),
          metadata: %{
            team_id: tokens.team_id,
            team_name: tokens.team_name,
            bot_user_id: tokens.bot_user_id,
            app_id: tokens.app_id
          }
        }

        # Store with provider "slack:{team_id}" for multi-workspace support
        provider = "slack:#{tokens.team_id}"

        case OAuth.store_tokens(user_id, provider, token_data) do
          {:ok, _token} ->
            conn
            |> put_status(:ok)
            |> json(%{
              status: "connected",
              user_id: user_id,
              team_id: tokens.team_id,
              team_name: tokens.team_name,
              topic: "slack:#{tokens.team_id}"
            })

          {:error, changeset} ->
            Logger.warning("Failed to store Slack tokens", error: inspect(changeset))

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to store tokens"})
        end

      {:error, reason} ->
        Logger.warning("Slack token exchange failed", reason: inspect(reason))

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to exchange authorization code"})
    end
  end

  defp encode_slack_state(user_id) do
    Base.url_encode64(Jason.encode!(%{user_id: user_id, provider: "slack"}))
  end

  defp decode_slack_state(state) do
    with {:ok, json} <- Base.url_decode64(state),
         {:ok, data} <- Jason.decode(json) do
      {:ok, data["user_id"]}
    else
      _ -> {:error, :invalid_state}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp handle_google_tokens(conn, code, user_id, services) do
    case Google.exchange_code(code) do
      {:ok, tokens} ->
        # Store the tokens
        scopes = Google.scopes_for(services)

        token_data = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_in: tokens.expires_in,
          scopes: scopes,
          metadata: %{services: services}
        }

        case OAuth.store_tokens(user_id, "google", token_data) do
          {:ok, _token} ->
            # Set up watches for requested services
            watch_results = setup_watches(user_id, services, tokens.access_token)

            conn
            |> put_status(:ok)
            |> json(%{
              status: "connected",
              user_id: user_id,
              services: services,
              watches: watch_results
            })

          {:error, changeset} ->
            Logger.warning("Failed to store tokens", error: inspect(changeset))

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to store tokens"})
        end

      {:error, reason} ->
        Logger.warning("Token exchange failed", reason: inspect(reason))

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to exchange authorization code"})
    end
  end

  defp setup_watches(user_id, services, access_token) do
    Enum.reduce(services, %{}, fn service, acc ->
      result =
        case service do
          "calendar" ->
            case GoogleCalendar.setup_watch(user_id, access_token) do
              {:ok, watch} -> %{status: "active", watch_id: watch.id}
              {:error, reason} -> %{status: "failed", reason: inspect(reason)}
            end

          "gmail" ->
            case Gmail.setup_watch(user_id, access_token) do
              {:ok, watch} -> %{status: "active", history_id: watch.history_id}
              {:error, reason} -> %{status: "failed", reason: inspect(reason)}
            end

          _ ->
            %{status: "unsupported"}
        end

      Map.put(acc, service, result)
    end)
  end

  defp parse_scopes(nil), do: []
  defp parse_scopes(""), do: []

  defp parse_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp encode_state(user_id, services) do
    data = %{user_id: user_id, services: services}
    Base.url_encode64(Jason.encode!(data))
  end

  defp decode_state(state) do
    with {:ok, json} <- Base.url_decode64(state),
         {:ok, data} <- Jason.decode(json) do
      {:ok, data["user_id"], data["services"]}
    else
      _ -> {:error, :invalid_state}
    end
  end
end
