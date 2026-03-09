defmodule MaraithonWeb.OAuthController do
  @moduledoc """
  OAuth flow controller for external service authentication.

  Handles OAuth authorization initiation and callback processing.
  """

  use MaraithonWeb, :controller

  alias Maraithon.OAuth
  alias Maraithon.OAuth.{Google, Slack, Linear}
  alias Maraithon.Connectors.{GoogleCalendar, Gmail}
  alias Maraithon.Connectors.Linear, as: LinearConnector

  require Logger

  @oauth_state_salt "oauth_state"
  @oauth_state_max_age_seconds 600

  @doc """
  Initiates Google OAuth flow.

  GET /auth/google?scopes=calendar,gmail&user_id=xxx

  Query parameters:
  - scopes: Comma-separated list of services (calendar, gmail)
  - user_id: Your application's user identifier

  Redirects user to Google's consent screen.
  """
  def google(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         {:ok, services} <- google_services(params["scopes"]) do
      scopes = Google.scopes_for(services)

      # State encodes user_id and requested services for the callback
      state = encode_google_state(user_id, services)
      auth_url = Google.authorize_url(scopes, state)

      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Google OAuth callback.

  GET /auth/google/callback?code=xxx&state=xxx

  Exchanges the authorization code for tokens, stores them,
  and sets up watches for the requested services.
  """
  def google_callback(conn, %{"code" => code, "state" => state}) do
    case decode_google_state(state) do
      {:ok, user_id, services} ->
        handle_google_tokens(conn, code, user_id, services)

      {:error, reason} ->
        Logger.warning("Invalid OAuth state", reason: inspect(reason))
        bad_request(conn, "Invalid state parameter")
    end
  end

  def google_callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.warning("Google OAuth error", error: error, description: description)

    bad_request(conn, "OAuth authorization failed", %{error: error, description: description})
  end

  def google_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  # ===========================================================================
  # Slack OAuth
  # ===========================================================================

  @doc """
  Initiates Slack OAuth flow.

  GET /auth/slack?user_id=xxx

  Redirects user to Slack's authorization page.
  """
  def slack(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required") do
      state = encode_provider_state("slack", user_id)
      auth_url = Slack.authorize_url(Slack.default_scopes(), state)
      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Slack OAuth callback.

  GET /auth/slack/callback?code=xxx&state=xxx
  """
  def slack_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "slack") do
      {:ok, user_id} ->
        handle_slack_tokens(conn, code, user_id)

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def slack_callback(conn, %{"error" => error}) do
    Logger.warning("Slack OAuth error", error: error)
    bad_request(conn, "OAuth authorization failed", error)
  end

  def slack_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

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

        payload = %{
          status: "connected",
          user_id: user_id,
          team_id: tokens.team_id,
          team_name: tokens.team_name,
          topic: "slack:#{tokens.team_id}"
        }

        store_tokens_and_respond(conn, user_id, provider, token_data, payload)

      {:error, reason} ->
        token_exchange_failed(conn, "Slack token exchange failed", reason)
    end
  end

  # ===========================================================================
  # Linear OAuth
  # ===========================================================================

  @doc """
  Initiates Linear OAuth flow.

  GET /auth/linear?user_id=xxx
  """
  def linear(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required") do
      state = encode_provider_state("linear", user_id)
      auth_url = Linear.authorize_url(Linear.default_scopes(), state)
      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Linear OAuth callback.

  GET /auth/linear/callback?code=xxx&state=xxx
  """
  def linear_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "linear") do
      {:ok, user_id} ->
        handle_linear_tokens(conn, code, user_id)

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def linear_callback(conn, %{"error" => error}) do
    Logger.warning("Linear OAuth error", error: error)
    bad_request(conn, "OAuth authorization failed", error)
  end

  def linear_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  defp handle_linear_tokens(conn, code, user_id) do
    case Linear.exchange_code(code) do
      {:ok, tokens} ->
        # Get team info
        teams =
          case LinearConnector.get_teams(tokens.access_token) do
            {:ok, teams} -> teams
            _ -> []
          end

        token_data = %{
          access_token: tokens.access_token,
          expires_in: tokens.expires_in,
          scopes: String.split(tokens.scope || "", ","),
          metadata: %{
            teams: Enum.map(teams, fn t -> %{id: t["id"], key: t["key"], name: t["name"]} end)
          }
        }

        team_keys = Enum.map(teams, & &1["key"])

        payload = %{
          status: "connected",
          user_id: user_id,
          teams: team_keys,
          topics: topic_names(team_keys)
        }

        store_tokens_and_respond(conn, user_id, "linear", token_data, payload)

      {:error, reason} ->
        token_exchange_failed(conn, "Linear token exchange failed", reason)
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

        # Set up watches for requested services
        watch_results = setup_watches(user_id, services, tokens.access_token)

        payload = %{
          status: "connected",
          user_id: user_id,
          services: services,
          watches: watch_results
        }

        store_tokens_and_respond(conn, user_id, "google", token_data, payload)

      {:error, reason} ->
        token_exchange_failed(conn, "Token exchange failed", reason)
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

  defp google_services(scopes) do
    case parse_scopes(scopes) do
      [] -> {:error, "scopes is required (e.g., scopes=calendar,gmail)"}
      services -> {:ok, services}
    end
  end

  defp required_param(params, key, message) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, message}
    end
  end

  defp encode_google_state(user_id, services) do
    sign_oauth_state(%{"user_id" => user_id, "services" => services, "provider" => "google"})
  end

  defp decode_google_state(state) do
    with {:ok, %{"provider" => "google", "user_id" => user_id, "services" => services}}
         when is_binary(user_id) and is_list(services) <- verify_oauth_state(state) do
      {:ok, user_id, services}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp encode_provider_state(provider, user_id) do
    sign_oauth_state(%{"user_id" => user_id, "provider" => provider})
  end

  defp decode_provider_state(state, provider) do
    with {:ok, %{"provider" => ^provider, "user_id" => user_id}} when is_binary(user_id) <-
           verify_oauth_state(state) do
      {:ok, user_id}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp store_tokens_and_respond(conn, user_id, provider, token_data, payload) do
    case OAuth.store_tokens(user_id, provider, token_data) do
      {:ok, _token} ->
        conn
        |> put_status(:ok)
        |> json(payload)

      {:error, changeset} ->
        Logger.warning("Failed to store OAuth tokens",
          user_id: user_id,
          provider: provider,
          error: inspect(changeset)
        )

        internal_server_error(conn, "Failed to store tokens")
    end
  end

  defp token_exchange_failed(conn, log_message, reason) do
    Logger.warning(log_message, reason: inspect(reason))
    bad_request(conn, "Failed to exchange authorization code")
  end

  defp topic_names(team_keys) do
    Enum.map(team_keys, fn key -> "linear:#{key}" end)
  end

  defp bad_request(conn, message), do: error_response(conn, :bad_request, message)

  defp bad_request(conn, message, details),
    do: error_response(conn, :bad_request, message, details)

  defp internal_server_error(conn, message),
    do: error_response(conn, :internal_server_error, message)

  defp error_response(conn, status, message, details \\ :none) do
    payload = %{error: message}

    payload =
      if details == :none do
        payload
      else
        Map.put(payload, :details, details)
      end

    conn
    |> put_status(status)
    |> json(payload)
  end

  defp sign_oauth_state(payload) when is_map(payload) do
    state_payload = Map.put_new(payload, "nonce", Ecto.UUID.generate())
    Phoenix.Token.sign(MaraithonWeb.Endpoint, @oauth_state_salt, state_payload)
  end

  defp verify_oauth_state(state) when is_binary(state) do
    Phoenix.Token.verify(
      MaraithonWeb.Endpoint,
      @oauth_state_salt,
      state,
      max_age: @oauth_state_max_age_seconds
    )
  end
end
