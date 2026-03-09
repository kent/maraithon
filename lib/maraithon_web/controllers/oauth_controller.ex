defmodule MaraithonWeb.OAuthController do
  @moduledoc """
  OAuth flow controller for external service authentication.

  Handles OAuth authorization initiation and callback processing.
  """

  use MaraithonWeb, :controller

  alias Maraithon.Connectors.{Gmail, GoogleCalendar}
  alias Maraithon.Connectors.Linear, as: LinearConnector
  alias Maraithon.OAuth
  alias Maraithon.OAuth.{GitHub, Google, Linear, Notion, Slack}

  require Logger

  @oauth_state_salt "oauth_state"
  @oauth_state_max_age_seconds 600
  @google_supported_services ["calendar", "gmail", "contacts"]

  @doc """
  Initiates Google OAuth flow.

  GET /auth/google?scopes=calendar,gmail&user_id=xxx
  """
  def google(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         {:ok, services} <- google_services(params["scopes"]),
         {:ok, return_to} <- optional_return_to(params) do
      state = encode_google_state(user_id, services, return_to)
      auth_url = Google.authorize_url(Google.scopes_for(services), state)

      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Google OAuth callback.
  """
  def google_callback(conn, %{"code" => code, "state" => state}) do
    case decode_google_state(state) do
      {:ok, user_id, services, state_payload} ->
        handle_google_tokens(conn, code, user_id, services, state_payload)

      {:error, reason} ->
        Logger.warning("Invalid OAuth state", reason: inspect(reason))
        bad_request(conn, "Invalid state parameter")
    end
  end

  def google_callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.warning("Google OAuth error", error: error, description: description)

    bad_request(conn, "OAuth authorization failed", %{error: error, description: description})
  end

  def google_callback(conn, %{"error" => error}) do
    Logger.warning("Google OAuth error", error: error)

    bad_request(conn, "OAuth authorization failed", %{error: error, description: nil})
  end

  def google_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  @doc """
  Initiates GitHub OAuth flow.

  GET /auth/github?user_id=xxx
  """
  def github(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         {:ok, return_to} <- optional_return_to(params) do
      {code_verifier, code_challenge} = pkce_pair()

      state =
        encode_provider_state("github", user_id, %{
          "return_to" => return_to,
          "code_verifier" => code_verifier
        })

      auth_url =
        GitHub.authorize_url(
          GitHub.default_scopes(),
          state,
          code_challenge: code_challenge
        )

      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles GitHub OAuth callback.
  """
  def github_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "github") do
      {:ok, user_id, state_payload} ->
        handle_github_tokens(conn, code, user_id, state_payload)

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def github_callback(conn, %{"error" => error} = params) do
    handle_provider_error(conn, "github", params, error)
  end

  def github_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  @doc """
  Initiates Slack OAuth flow.

  GET /auth/slack?user_id=xxx
  """
  def slack(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         {:ok, return_to} <- optional_return_to(params) do
      state = encode_provider_state("slack", user_id, %{"return_to" => return_to})
      auth_url = Slack.authorize_url(Slack.default_scopes(), state)
      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Slack OAuth callback.
  """
  def slack_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "slack") do
      {:ok, user_id, state_payload} ->
        handle_slack_tokens(conn, code, user_id, state_payload)

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def slack_callback(conn, %{"error" => error} = params) do
    handle_provider_error(conn, "slack", params, error)
  end

  def slack_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  @doc """
  Initiates Linear OAuth flow.

  GET /auth/linear?user_id=xxx
  """
  def linear(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         {:ok, return_to} <- optional_return_to(params) do
      state = encode_provider_state("linear", user_id, %{"return_to" => return_to})
      auth_url = Linear.authorize_url(Linear.default_scopes(), state)
      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Linear OAuth callback.
  """
  def linear_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "linear") do
      {:ok, user_id, state_payload} ->
        handle_linear_tokens(conn, code, user_id, state_payload)

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def linear_callback(conn, %{"error" => error} = params) do
    handle_provider_error(conn, "linear", params, error)
  end

  def linear_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  @doc """
  Initiates Notion OAuth flow.

  GET /auth/notion?user_id=xxx
  """
  def notion(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         {:ok, return_to} <- optional_return_to(params) do
      state = encode_provider_state("notion", user_id, %{"return_to" => return_to})
      auth_url = Notion.authorize_url(state)

      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Notion OAuth callback.
  """
  def notion_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "notion") do
      {:ok, user_id, state_payload} ->
        handle_notion_tokens(conn, code, user_id, state_payload)

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def notion_callback(conn, %{"error" => error} = params) do
    handle_provider_error(conn, "notion", params, error)
  end

  def notion_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  defp handle_github_tokens(conn, code, user_id, state_payload) do
    with {:ok, tokens} <-
           GitHub.exchange_code(
             code,
             code_verifier: state_payload["code_verifier"]
           ),
         {:ok, viewer} <- GitHub.viewer(tokens.access_token) do
      token_data = %{
        access_token: tokens.access_token,
        scopes: split_scope_string(tokens.scope),
        metadata: %{
          login: viewer.login,
          name: viewer.name,
          email: viewer.email,
          avatar_url: viewer.avatar_url,
          html_url: viewer.html_url,
          github_id: viewer.id
        }
      }

      payload = %{
        status: "connected",
        user_id: user_id,
        login: viewer.login,
        html_url: viewer.html_url
      }

      store_tokens_and_respond(
        conn,
        user_id,
        "github",
        token_data,
        payload,
        success_message("github", viewer.login),
        state_payload["return_to"]
      )
    else
      {:error, reason} ->
        token_exchange_failed(
          conn,
          "GitHub token exchange failed",
          reason,
          "github",
          state_payload["return_to"]
        )
    end
  end

  defp handle_slack_tokens(conn, code, user_id, state_payload) do
    case Slack.exchange_code(code) do
      {:ok, tokens} ->
        token_data = %{
          access_token: tokens.access_token,
          scopes: split_scope_string(tokens.scope),
          metadata: %{
            team_id: tokens.team_id,
            team_name: tokens.team_name,
            bot_user_id: tokens.bot_user_id,
            app_id: tokens.app_id
          }
        }

        provider = "slack:#{tokens.team_id}"

        payload = %{
          status: "connected",
          user_id: user_id,
          team_id: tokens.team_id,
          team_name: tokens.team_name,
          topic: "slack:#{tokens.team_id}"
        }

        store_tokens_and_respond(
          conn,
          user_id,
          provider,
          token_data,
          payload,
          success_message("slack", tokens.team_name),
          state_payload["return_to"]
        )

      {:error, reason} ->
        token_exchange_failed(
          conn,
          "Slack token exchange failed",
          reason,
          "slack",
          state_payload["return_to"]
        )
    end
  end

  defp handle_linear_tokens(conn, code, user_id, state_payload) do
    case Linear.exchange_code(code) do
      {:ok, tokens} ->
        teams =
          case LinearConnector.get_teams(tokens.access_token) do
            {:ok, teams} -> teams
            _ -> []
          end

        token_data = %{
          access_token: tokens.access_token,
          expires_in: tokens.expires_in,
          scopes: split_scope_string(tokens.scope),
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

        store_tokens_and_respond(
          conn,
          user_id,
          "linear",
          token_data,
          payload,
          success_message("linear", Enum.join(team_keys, ", ")),
          state_payload["return_to"]
        )

      {:error, reason} ->
        token_exchange_failed(
          conn,
          "Linear token exchange failed",
          reason,
          "linear",
          state_payload["return_to"]
        )
    end
  end

  defp handle_notion_tokens(conn, code, user_id, state_payload) do
    case Notion.exchange_code(code) do
      {:ok, tokens} ->
        token_data = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_in: tokens.expires_in,
          metadata: %{
            workspace_id: tokens.workspace_id,
            workspace_name: tokens.workspace_name,
            workspace_icon: tokens.workspace_icon,
            owner: tokens.owner,
            bot_id: tokens.bot_id,
            duplicated_template_id: tokens.duplicated_template_id
          }
        }

        payload = %{
          status: "connected",
          user_id: user_id,
          workspace_id: tokens.workspace_id,
          workspace_name: tokens.workspace_name
        }

        store_tokens_and_respond(
          conn,
          user_id,
          "notion",
          token_data,
          payload,
          success_message("notion", tokens.workspace_name),
          state_payload["return_to"]
        )

      {:error, reason} ->
        token_exchange_failed(
          conn,
          "Notion token exchange failed",
          reason,
          "notion",
          state_payload["return_to"]
        )
    end
  end

  defp handle_google_tokens(conn, code, user_id, services, state_payload) do
    case Google.exchange_code(code) do
      {:ok, tokens} ->
        existing = OAuth.get_token(user_id, "google")
        granted_scopes = split_scope_string(tokens.scope)

        scopes =
          existing_google_scopes(existing)
          |> Enum.concat(
            if(granted_scopes == [], do: Google.scopes_for(services), else: granted_scopes)
          )
          |> Enum.uniq()

        services =
          existing_google_services(existing)
          |> Enum.concat(google_services_from_scopes(scopes))
          |> Enum.concat(services)
          |> Enum.uniq()
          |> Enum.sort()

        token_data = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token || (existing && existing.refresh_token),
          expires_in: tokens.expires_in,
          scopes: scopes,
          metadata: %{"services" => services}
        }

        watch_results = setup_watches(user_id, services, tokens.access_token)

        payload = %{
          status: "connected",
          user_id: user_id,
          services: services,
          watches: watch_results
        }

        store_tokens_and_respond(
          conn,
          user_id,
          "google",
          token_data,
          payload,
          success_message("google", Enum.join(services, ", ")),
          state_payload["return_to"]
        )

      {:error, reason} ->
        token_exchange_failed(
          conn,
          "Google token exchange failed",
          reason,
          "google",
          state_payload["return_to"]
        )
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

          "contacts" ->
            %{status: "connected"}

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
    |> Enum.reject(&(&1 == ""))
  end

  defp google_services(scopes) do
    case parse_scopes(scopes) do
      [] ->
        {:error, "scopes is required (e.g., scopes=calendar,gmail)"}

      services ->
        valid_services =
          services
          |> Enum.filter(&(&1 in @google_supported_services))
          |> Enum.uniq()

        if valid_services == [] do
          {:error, "No supported Google scopes requested"}
        else
          {:ok, valid_services}
        end
    end
  end

  defp required_param(params, key, message) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, message}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, message}
    end
  end

  defp optional_return_to(params) do
    case Map.get(params, "return_to") do
      nil -> {:ok, nil}
      value -> normalize_return_to(value)
    end
  end

  defp encode_google_state(user_id, services, return_to) do
    %{"user_id" => user_id, "services" => services, "provider" => "google"}
    |> maybe_put_state("return_to", return_to)
    |> sign_oauth_state()
  end

  defp decode_google_state(state) do
    with {:ok, %{"provider" => "google", "user_id" => user_id, "services" => services} = payload}
         when is_binary(user_id) and is_list(services) <- verify_oauth_state(state) do
      {:ok, user_id, services, payload}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp encode_provider_state(provider, user_id, extra) do
    %{"user_id" => user_id, "provider" => provider}
    |> Map.merge(extra)
    |> sign_oauth_state()
  end

  defp decode_provider_state(state, provider) do
    with {:ok, %{"provider" => ^provider, "user_id" => user_id} = payload}
         when is_binary(user_id) <- verify_oauth_state(state) do
      {:ok, user_id, payload}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp store_tokens_and_respond(
         conn,
         user_id,
         provider,
         token_data,
         payload,
         success_message,
         return_to
       ) do
    case OAuth.store_tokens(user_id, provider, token_data) do
      {:ok, _token} ->
        respond_success(conn, return_to, provider, success_message, payload)

      {:error, changeset} ->
        Logger.warning("Failed to store OAuth tokens",
          user_id: user_id,
          provider: provider,
          error: inspect(changeset)
        )

        respond_error(conn, return_to, provider, "Failed to store tokens", :internal_server_error)
    end
  end

  defp respond_success(conn, nil, _provider, _message, payload) do
    conn
    |> put_status(:ok)
    |> json(payload)
  end

  defp respond_success(conn, return_to, provider, message, _payload) do
    redirect(conn, to: oauth_result_url(return_to, provider, "connected", message))
  end

  defp respond_error(conn, nil, _provider, message, status) do
    error_response(conn, status, message)
  end

  defp respond_error(conn, return_to, provider, message, _status) do
    redirect(conn, to: oauth_result_url(return_to, provider, "error", message))
  end

  defp token_exchange_failed(conn, log_message, reason, provider, return_to) do
    Logger.warning(log_message, reason: inspect(reason))

    respond_error(
      conn,
      return_to,
      provider,
      "Failed to exchange authorization code",
      :bad_request
    )
  end

  defp topic_names(team_keys) do
    Enum.map(team_keys, fn key -> "linear:#{key}" end)
  end

  defp handle_provider_error(conn, provider, %{"state" => state} = params, error) do
    description = Map.get(params, "error_description")

    case decode_provider_state(state, provider) do
      {:ok, _user_id, %{"return_to" => return_to}} when is_binary(return_to) ->
        redirect(
          conn,
          to:
            oauth_result_url(
              return_to,
              provider,
              "error",
              provider_error_message(provider, error, description)
            )
        )

      _ ->
        Logger.warning("#{String.capitalize(provider)} OAuth error",
          error: error,
          description: description
        )

        bad_request(conn, "OAuth authorization failed", %{error: error, description: description})
    end
  end

  defp handle_provider_error(conn, provider, params, error) do
    description = Map.get(params, "error_description")

    Logger.warning("#{String.capitalize(provider)} OAuth error",
      error: error,
      description: description
    )

    bad_request(conn, "OAuth authorization failed", description || error)
  end

  defp split_scope_string(nil), do: []
  defp split_scope_string(""), do: []

  defp split_scope_string(scope_string) when is_binary(scope_string) do
    scope_string
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp existing_google_scopes(nil), do: []
  defp existing_google_scopes(token), do: token.scopes || []

  defp existing_google_services(nil), do: []

  defp existing_google_services(token) do
    case token.metadata do
      %{"services" => services} when is_list(services) -> services
      %{services: services} when is_list(services) -> services
      _ -> []
    end
  end

  defp google_services_from_scopes(scopes) do
    Enum.filter(@google_supported_services, fn service ->
      required = Google.scopes_for([service])
      Enum.all?(required, &(&1 in scopes))
    end)
  end

  defp oauth_result_url(return_to, provider, status, message) do
    uri = URI.parse(return_to)
    existing_params = URI.decode_query(uri.query || "")

    query =
      existing_params
      |> Map.merge(%{
        "oauth_provider" => provider,
        "oauth_status" => status,
        "oauth_message" => message
      })
      |> URI.encode_query()

    %URI{uri | query: query, fragment: nil}
    |> URI.to_string()
  end

  defp provider_error_message(provider, error, description) do
    label = provider_display_name(provider)

    if description in [nil, ""] do
      "#{label} authorization failed: #{error}"
    else
      "#{label} authorization failed: #{description}"
    end
  end

  defp success_message(provider, nil), do: "#{provider_display_name(provider)} connected"
  defp success_message(provider, ""), do: "#{provider_display_name(provider)} connected"

  defp success_message("google", services) do
    "Google Workspace connected (#{services})"
  end

  defp success_message(provider, details) do
    "#{provider_display_name(provider)} connected: #{details}"
  end

  defp provider_display_name("google"), do: "Google Workspace"
  defp provider_display_name("github"), do: "GitHub"
  defp provider_display_name("linear"), do: "Linear"
  defp provider_display_name("notion"), do: "Notion"
  defp provider_display_name("slack"), do: "Slack"
  defp provider_display_name(provider), do: provider

  defp pkce_pair do
    verifier = :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp normalize_return_to(value) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    cond do
      value == "" ->
        {:ok, nil}

      uri.scheme != nil or uri.host != nil ->
        {:error, "return_to must be a relative path"}

      is_nil(uri.path) or not String.starts_with?(uri.path, "/") or
          String.starts_with?(uri.path, "//") ->
        {:error, "return_to must be a relative path"}

      true ->
        {:ok, %URI{path: uri.path, query: uri.query} |> URI.to_string()}
    end
  end

  defp normalize_return_to(_value), do: {:error, "return_to must be a relative path"}

  defp bad_request(conn, message), do: error_response(conn, :bad_request, message)

  defp bad_request(conn, message, details),
    do: error_response(conn, :bad_request, message, details)

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

  defp maybe_put_state(payload, _key, nil), do: payload
  defp maybe_put_state(payload, _key, ""), do: payload
  defp maybe_put_state(payload, key, value), do: Map.put(payload, key, value)
end
