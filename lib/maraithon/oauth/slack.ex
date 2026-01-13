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
    "channels:history",
    "channels:read",
    "chat:write",
    "users:read",
    "reactions:read"
  ]

  @doc """
  Returns the default Slack bot scopes.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Generates the Slack OAuth authorization URL.
  """
  def authorize_url(scopes \\ @default_scopes, state) do
    config = get_config()

    params =
      URI.encode_query(%{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        scope: Enum.join(scopes, ","),
        state: state
      })

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
      redirect_uri: config.redirect_uri
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
      token_type: response["token_type"],
      scope: response["scope"],
      team_id: response["team"]["id"],
      team_name: response["team"]["name"],
      bot_user_id: get_in(response, ["bot_user_id"]),
      app_id: response["app_id"],
      authed_user: response["authed_user"]
    }
  end
end
