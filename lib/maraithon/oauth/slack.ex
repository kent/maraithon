defmodule Maraithon.OAuth.Slack do
  @moduledoc """
  Slack OAuth 2.0 helpers.

  Handles OAuth authorization flow for Slack workspace installation.

  ## Configuration

      config :maraithon, :slack,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        redirect_uri: "https://your-domain.com/auth/slack/callback",
        signing_secret: "your_signing_secret"
  """

  alias Maraithon.HTTP
  alias Maraithon.Crypto

  @default_auth_url "https://slack.com/oauth/v2/authorize"
  @default_token_url "https://slack.com/api/oauth.v2.access"
  @default_revoke_url "https://slack.com/api/auth.revoke"
  @default_api_base "https://slack.com/api"

  @default_scopes [
    "app_mentions:read",
    "channels:history",
    "channels:read",
    "groups:history",
    "groups:read",
    "im:history",
    "im:read",
    "mpim:history",
    "mpim:read",
    "chat:write",
    "users:read",
    "reactions:read"
  ]

  @default_user_scopes [
    "channels:history",
    "channels:read",
    "groups:history",
    "groups:read",
    "im:history",
    "im:read",
    "mpim:history",
    "mpim:read",
    "search:read",
    "users:read"
  ]

  @doc """
  Returns true when Slack OAuth is configured for interactive connects.
  """
  def configured? do
    config = get_config()
    config.client_id != "" and config.client_secret != "" and config.redirect_uri != ""
  end

  @doc """
  Returns the default Slack bot scopes.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Returns default Slack user scopes for personal-message access.
  """
  def default_user_scopes, do: @default_user_scopes

  @doc """
  Generates the Slack OAuth authorization URL with default bot + user scopes.
  """
  def authorize_url(state) when is_binary(state) do
    authorize_url(@default_scopes, state, user_scopes: @default_user_scopes)
  end

  @doc """
  Generates the Slack OAuth authorization URL with custom bot scopes.
  """
  def authorize_url(scopes, state) when is_list(scopes) and is_binary(state) do
    authorize_url(scopes, state, user_scopes: @default_user_scopes)
  end

  @doc """
  Generates the Slack OAuth authorization URL with custom bot and user scopes.
  """
  def authorize_url(scopes, state, opts) when is_list(scopes) and is_binary(state) do
    config = get_config()
    user_scopes = Keyword.get(opts, :user_scopes, @default_user_scopes)

    params =
      %{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        scope: Enum.join(scopes, ","),
        state: state
      }
      |> maybe_put("user_scope", join_scopes(user_scopes))
      |> URI.encode_query()

    "#{auth_url()}?#{params}"
  end

  @doc """
  Exchanges an authorization code for tokens.
  """
  def exchange_code(code) do
    config = get_config()

    params = %{
      code: code,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: config.redirect_uri,
      grant_type: "authorization_code"
    }

    case HTTP.post_form(token_url(), params) do
      {:ok, %{"ok" => true} = response} ->
        {:ok, parse_token_response(response)}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, {:slack_error, error}}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Refreshes a Slack access token using a refresh token.
  """
  def refresh_token(refresh_token) when is_binary(refresh_token) do
    config = get_config()

    params = %{
      refresh_token: refresh_token,
      client_id: config.client_id,
      client_secret: config.client_secret,
      grant_type: "refresh_token"
    }

    case HTTP.post_form(token_url(), params) do
      {:ok, %{"ok" => true} = response} ->
        {:ok, parse_token_response(response)}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, {:slack_error, error}}

      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  @doc """
  Revokes a Slack token.
  """
  def revoke_token(access_token) do
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case HTTP.post_form(revoke_url(), %{}, headers) do
      {:ok, %{"ok" => true}} ->
        :ok

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, {:slack_error, error}}

      {:error, reason} ->
        {:error, {:revocation_failed, reason}}
    end
  end

  @doc """
  Verifies a Slack request signature.

  Slack signs requests using HMAC-SHA256 with the signing secret.
  """
  def verify_signature(raw_body, timestamp, signature) do
    signing_secret = get_signing_secret()

    if signing_secret == "" do
      if allow_unsigned?() do
        :ok
      else
        {:error, :signing_secret_not_configured}
      end
    else
      Crypto.verify_slack_signature(signing_secret, timestamp, raw_body, signature)
    end
  end

  @doc """
  Makes an authenticated request to the Slack API.
  """
  def api_request(method, endpoint, access_token, body \\ nil) do
    url = "#{api_base_url()}/#{endpoint}"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    result =
      case method do
        :get -> HTTP.get(url, headers)
        :post -> HTTP.post_json(url, body || %{}, headers)
      end

    case result do
      {:ok, %{"ok" => true} = response} ->
        {:ok, response}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, {:slack_error, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_config do
    config = Application.get_env(:maraithon, :slack, [])

    %{
      client_id: Keyword.get(config, :client_id, ""),
      client_secret: Keyword.get(config, :client_secret, ""),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp auth_url do
    config = Application.get_env(:maraithon, :slack, [])
    Keyword.get(config, :auth_url, @default_auth_url)
  end

  defp token_url do
    config = Application.get_env(:maraithon, :slack, [])
    Keyword.get(config, :token_url, @default_token_url)
  end

  defp revoke_url do
    config = Application.get_env(:maraithon, :slack, [])
    Keyword.get(config, :revoke_url, @default_revoke_url)
  end

  defp api_base_url do
    config = Application.get_env(:maraithon, :slack, [])
    Keyword.get(config, :api_base_url, @default_api_base)
  end

  defp get_signing_secret do
    Application.get_env(:maraithon, :slack, [])
    |> Keyword.get(:signing_secret, "")
  end

  defp allow_unsigned? do
    Application.get_env(:maraithon, :slack, [])
    |> Keyword.get(:allow_unsigned, false)
  end

  defp parse_token_response(response) do
    %{
      access_token: response["access_token"],
      refresh_token: response["refresh_token"],
      expires_in: response["expires_in"],
      token_type: response["token_type"],
      scope: response["scope"],
      team_id: get_in(response, ["team", "id"]),
      team_name: get_in(response, ["team", "name"]),
      bot_user_id: get_in(response, ["bot_user_id"]),
      app_id: response["app_id"],
      authed_user: parse_authed_user(response["authed_user"])
    }
  end

  defp parse_authed_user(nil), do: nil

  defp parse_authed_user(authed_user) when is_map(authed_user) do
    %{
      id: authed_user["id"],
      access_token: authed_user["access_token"],
      refresh_token: authed_user["refresh_token"],
      expires_in: authed_user["expires_in"],
      token_type: authed_user["token_type"],
      scope: authed_user["scope"]
    }
  end

  defp parse_authed_user(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp join_scopes(nil), do: nil

  defp join_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  defp join_scopes(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
