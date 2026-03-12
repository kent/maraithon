defmodule MaraithonWeb.OAuthController do
  @moduledoc """
  OAuth flow controller for external service authentication.

  Handles OAuth authorization initiation and callback processing.
  """

  use MaraithonWeb, :controller

  alias Maraithon.Connectors.{Gmail, GoogleCalendar}
  alias Maraithon.Connectors.Linear, as: LinearConnector
  alias Maraithon.Connectors.Notaui, as: NotauiConnector
  alias Maraithon.OAuth
  alias Maraithon.OAuth.{GitHub, Google, Linear, Notaui, Notion, Slack}

  require Logger

  @oauth_state_salt "oauth_state"
  @oauth_state_max_age_seconds 600
  @google_supported_services ["calendar", "gmail", "contacts"]

  @doc """
  Initiates Google OAuth flow.

  GET /auth/google?scopes=calendar,gmail&user_id=xxx
  """
  def google(conn, params) do
    with {:ok, user_id} <- resolve_user_id(conn, params),
         {:ok, services} <- google_services(params["scopes"]),
         {:ok, return_to} <- optional_return_to(params) do
      state = encode_google_state(user_id, services, return_to)
      auth_url = Google.authorize_url(google_authorize_scopes(services), state)

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
        case ensure_user_matches(conn, user_id) do
          :ok -> handle_google_tokens(conn, code, user_id, services, state_payload)
          {:error, reason} -> bad_request(conn, reason)
        end

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
    with {:ok, user_id} <- resolve_user_id(conn, params),
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
        case ensure_user_matches(conn, user_id) do
          :ok -> handle_github_tokens(conn, code, user_id, state_payload)
          {:error, reason} -> bad_request(conn, reason)
        end

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
    with {:ok, user_id} <- resolve_user_id(conn, params),
         {:ok, return_to} <- optional_return_to(params) do
      state = encode_provider_state("slack", user_id, %{"return_to" => return_to})

      auth_url =
        Slack.authorize_url(
          Slack.default_scopes(),
          state,
          user_scopes: Slack.default_user_scopes()
        )

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
        case ensure_user_matches(conn, user_id) do
          :ok -> handle_slack_tokens(conn, code, user_id, state_payload)
          {:error, reason} -> bad_request(conn, reason)
        end

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
    with {:ok, user_id} <- resolve_user_id(conn, params),
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
        case ensure_user_matches(conn, user_id) do
          :ok -> handle_linear_tokens(conn, code, user_id, state_payload)
          {:error, reason} -> bad_request(conn, reason)
        end

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
    with {:ok, user_id} <- resolve_user_id(conn, params),
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
        case ensure_user_matches(conn, user_id) do
          :ok -> handle_notion_tokens(conn, code, user_id, state_payload)
          {:error, reason} -> bad_request(conn, reason)
        end

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def notion_callback(conn, %{"error" => error} = params) do
    handle_provider_error(conn, "notion", params, error)
  end

  def notion_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

  @doc """
  Initiates Notaui OAuth flow.

  GET /auth/notaui?user_id=xxx
  """
  def notaui(conn, params) do
    with {:ok, user_id} <- resolve_user_id(conn, params),
         {:ok, return_to} <- optional_return_to(params) do
      {code_verifier, code_challenge} = pkce_pair()

      state =
        encode_provider_state("notaui", user_id, %{
          "return_to" => return_to,
          "code_verifier" => code_verifier
        })

      auth_url =
        Notaui.authorize_url(
          Notaui.default_scopes(),
          state,
          code_challenge: code_challenge
        )

      redirect(conn, external: auth_url)
    else
      {:error, reason} -> bad_request(conn, reason)
    end
  end

  @doc """
  Handles Notaui OAuth callback.
  """
  def notaui_callback(conn, %{"code" => code, "state" => state}) do
    case decode_provider_state(state, "notaui") do
      {:ok, user_id, state_payload} ->
        case ensure_user_matches(conn, user_id) do
          :ok -> handle_notaui_tokens(conn, code, user_id, state_payload)
          {:error, reason} -> bad_request(conn, reason)
        end

      {:error, _reason} ->
        bad_request(conn, "Invalid state parameter")
    end
  end

  def notaui_callback(conn, %{"error" => error} = params) do
    handle_provider_error(conn, "notaui", params, error)
  end

  def notaui_callback(conn, _params), do: bad_request(conn, "Missing code or state parameter")

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
        provider = "slack:#{tokens.team_id}"

        bot_token_data = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_in: tokens.expires_in,
          scopes: split_scope_string(tokens.scope),
          metadata: %{
            team_id: tokens.team_id,
            team_name: tokens.team_name,
            bot_user_id: tokens.bot_user_id,
            app_id: tokens.app_id,
            authed_user_id: tokens.authed_user && tokens.authed_user.id
          }
        }

        with {:ok, _token} <- OAuth.store_tokens(user_id, provider, bot_token_data),
             :ok <- store_slack_user_token(user_id, tokens) do
          payload = %{
            status: "connected",
            user_id: user_id,
            team_id: tokens.team_id,
            team_name: tokens.team_name,
            topic: "slack:#{tokens.team_id}",
            user_scopes_connected: slack_user_token_present?(tokens)
          }

          respond_success(
            conn,
            state_payload["return_to"],
            "slack",
            success_message("slack", tokens.team_name),
            payload
          )
        else
          {:error, changeset} ->
            Logger.warning("Failed to store Slack OAuth tokens",
              user_id: user_id,
              provider: provider,
              error: inspect(changeset)
            )

            respond_error(
              conn,
              state_payload["return_to"],
              "slack",
              "Failed to store tokens",
              :internal_server_error
            )
        end

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

  defp store_slack_user_token(user_id, tokens) do
    authed_user = tokens.authed_user
    user_access_token = authed_user && authed_user.access_token
    authed_user_id = authed_user && authed_user.id

    if is_binary(user_access_token) and is_binary(authed_user_id) and is_binary(tokens.team_id) do
      provider = "slack:#{tokens.team_id}:user:#{authed_user_id}"

      user_token_data = %{
        access_token: user_access_token,
        refresh_token: authed_user.refresh_token,
        expires_in: authed_user.expires_in,
        scopes: split_scope_string(authed_user.scope),
        metadata: %{
          team_id: tokens.team_id,
          team_name: tokens.team_name,
          slack_user_id: authed_user_id,
          token_type: authed_user.token_type
        }
      }

      case OAuth.store_tokens(user_id, provider, user_token_data) do
        {:ok, _token} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp slack_user_token_present?(tokens) do
    authed_user = tokens.authed_user
    is_map(authed_user) and is_binary(authed_user.access_token) and is_binary(authed_user.id)
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

  defp handle_notaui_tokens(conn, code, user_id, state_payload) do
    case Notaui.exchange_code(code, code_verifier: state_payload["code_verifier"]) do
      {:ok, tokens} ->
        scopes = split_scope_string(tokens.scope)

        token_data = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_in: tokens.expires_in,
          scopes: scopes,
          metadata: notaui_base_metadata(tokens.token_type)
        }

        case OAuth.store_tokens(user_id, "notaui", token_data) do
          {:ok, _token} ->
            {payload, message} = notaui_post_connect_result(user_id, token_data, scopes)
            respond_success(conn, state_payload["return_to"], "notaui", message, payload)

          {:error, changeset} ->
            Logger.warning("Failed to store OAuth tokens",
              user_id: user_id,
              provider: "notaui",
              error: inspect(changeset)
            )

            respond_error(
              conn,
              state_payload["return_to"],
              "notaui",
              "Failed to store tokens",
              :internal_server_error
            )
        end

      {:error, reason} ->
        token_exchange_failed(
          conn,
          "Notaui token exchange failed",
          reason,
          "notaui",
          state_payload["return_to"]
        )
    end
  end

  defp notaui_post_connect_result(user_id, token_data, scopes)
       when is_binary(user_id) and is_map(token_data) and is_list(scopes) do
    case NotauiConnector.discover_accounts(token_data.access_token) do
      {:ok, snapshot} ->
        enriched_token_data = %{
          access_token: token_data.access_token,
          refresh_token: token_data.refresh_token,
          expires_in: token_data.expires_in,
          scopes: scopes,
          external_account_id: snapshot["default_account_id"],
          metadata: Map.merge(token_data.metadata, snapshot)
        }

        case OAuth.store_tokens(user_id, "notaui", enriched_token_data) do
          {:ok, _token} ->
            {
              notaui_payload(user_id, scopes, snapshot, discovery_status(snapshot)),
              notaui_success_message(snapshot, scopes)
            }

          {:error, changeset} ->
            Logger.warning("Failed to store Notaui account discovery metadata",
              user_id: user_id,
              error: inspect(changeset)
            )

            degraded_metadata = notaui_discovery_error_metadata(:metadata_store_failed)
            _ = persist_notaui_metadata(user_id, token_data, scopes, degraded_metadata)

            {
              notaui_payload(user_id, scopes, degraded_metadata, "error"),
              "Notaui connected, but account discovery metadata could not be saved."
            }
        end

      {:error, reason} ->
        Logger.warning("Notaui account discovery failed",
          user_id: user_id,
          reason: inspect(reason)
        )

        degraded_metadata = notaui_discovery_error_metadata(reason)
        _ = persist_notaui_metadata(user_id, token_data, scopes, degraded_metadata)

        {
          notaui_payload(user_id, scopes, degraded_metadata, "error"),
          "Notaui connected, but account discovery needs attention."
        }
    end
  end

  defp persist_notaui_metadata(user_id, token_data, scopes, metadata)
       when is_binary(user_id) and is_map(token_data) and is_list(scopes) and is_map(metadata) do
    OAuth.store_tokens(user_id, "notaui", %{
      access_token: token_data.access_token,
      refresh_token: token_data.refresh_token,
      expires_in: token_data.expires_in,
      scopes: scopes,
      external_account_id: metadata["default_account_id"],
      metadata: Map.merge(token_data.metadata, metadata)
    })
  end

  defp notaui_base_metadata(token_type) do
    config = Notaui.config()

    %{}
    |> maybe_put_map_value("token_type", token_type)
    |> maybe_put_map_value("issuer", config.issuer)
    |> maybe_put_map_value("mcp_url", config.mcp_url)
  end

  defp notaui_discovery_error_metadata(reason) do
    %{
      "accounts" => [],
      "account_count" => 0,
      "default_account_id" => nil,
      "default_account_label" => nil,
      "discovery_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "discovery_error" => %{"reason" => notaui_discovery_error_reason(reason)}
    }
  end

  defp notaui_discovery_error_reason({:mcp_request_failed, status})
       when is_integer(status),
       do: "mcp_request_failed_#{status}"

  defp notaui_discovery_error_reason({:mcp_error, _message}), do: "mcp_error"
  defp notaui_discovery_error_reason({:mcp_transport_error, _reason}), do: "mcp_transport_error"
  defp notaui_discovery_error_reason({:invalid_tool_payload, _reason}), do: "invalid_tool_payload"
  defp notaui_discovery_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp notaui_discovery_error_reason(_reason), do: "account_discovery_failed"

  defp notaui_payload(user_id, scopes, metadata, account_discovery)
       when is_binary(user_id) and is_list(scopes) and is_map(metadata) do
    %{
      status: "connected",
      user_id: user_id,
      scopes: scopes,
      account_count: metadata["account_count"] || 0,
      default_account_id: metadata["default_account_id"],
      default_account_label: metadata["default_account_label"],
      account_discovery: account_discovery
    }
  end

  defp discovery_status(%{"account_count" => 0}), do: "empty"
  defp discovery_status(_metadata), do: "ok"

  defp notaui_success_message(%{"account_count" => 0}, _scopes) do
    "Notaui connected, but no accessible accounts were discovered."
  end

  defp notaui_success_message(snapshot, scopes) when is_map(snapshot) and is_list(scopes) do
    detail =
      snapshot["default_account_label"] || snapshot["default_account_id"] ||
        Enum.join(scopes, ", ")

    success_message("notaui", detail)
  end

  defp handle_google_tokens(conn, code, user_id, services, state_payload) do
    case Google.exchange_code(code) do
      {:ok, tokens} ->
        account_identity = google_account_identity(tokens.access_token)
        provider = google_provider(account_identity)
        existing = existing_google_token_for_provider(user_id, provider)
        granted_scopes = split_scope_string(tokens.scope)

        scopes =
          existing_google_scopes(existing)
          |> Enum.concat(
            if(granted_scopes == [], do: google_authorize_scopes(services), else: granted_scopes)
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
          metadata:
            %{"services" => services}
            |> maybe_put_map_value("account_email", account_identity[:email])
            |> maybe_put_map_value("account_name", account_identity[:name])
            |> maybe_put_map_value("account_sub", account_identity[:sub])
            |> maybe_put_map_value("account_picture", account_identity[:picture])
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
          provider,
          token_data,
          payload,
          success_message("google", google_success_details(account_identity, services)),
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

  defp resolve_user_id(conn, params) do
    with {:ok, user_id} <- required_param(params, "user_id", "user_id is required"),
         :ok <- ensure_user_matches(conn, user_id) do
      {:ok, user_id}
    end
  end

  defp ensure_user_matches(conn, _user_id) do
    if conn.assigns[:current_user] do
      :ok
    else
      {:error, "Authentication required"}
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

  defp google_authorize_scopes(services) when is_list(services) do
    services
    |> Google.scopes_for()
    |> Kernel.++(Google.identity_scopes())
    |> Enum.uniq()
  end

  defp google_account_identity(access_token) when is_binary(access_token) do
    case Google.userinfo(access_token) do
      {:ok, profile} ->
        %{
          email: normalize_google_email(profile.email),
          name: normalize_optional_text(profile.name),
          sub: normalize_optional_text(profile.sub),
          picture: normalize_optional_text(profile.picture)
        }

      {:error, reason} ->
        Logger.warning("Google account identity lookup failed", reason: inspect(reason))
        %{}
    end
  end

  defp google_account_identity(_), do: %{}

  defp google_provider(%{email: email}) when is_binary(email) and email != "",
    do: "google:#{email}"

  defp google_provider(%{sub: sub}) when is_binary(sub) and sub != "" do
    "google:sub-#{sanitize_google_provider_value(sub)}"
  end

  defp google_provider(_), do: "google"

  defp existing_google_token_for_provider(user_id, provider)
       when is_binary(user_id) and is_binary(provider) do
    OAuth.list_user_tokens(user_id)
    |> Enum.find(&(&1.provider == provider))
  end

  defp existing_google_token_for_provider(_user_id, _provider), do: nil

  defp google_success_details(account_identity, services) when is_map(account_identity) do
    services_label = Enum.join(services, ", ")

    case account_identity[:email] do
      email when is_binary(email) and email != "" ->
        "#{email} · #{services_label}"

      _ ->
        services_label
    end
  end

  defp normalize_google_email(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      email -> email
    end
  end

  defp normalize_google_email(_), do: nil

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_optional_text(_), do: nil

  defp sanitize_google_provider_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> case do
      "" -> "account"
      normalized -> normalized
    end
  end

  defp maybe_put_map_value(map, _key, nil), do: map
  defp maybe_put_map_value(map, _key, ""), do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)

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
  defp provider_display_name("notaui"), do: "Notaui"
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
