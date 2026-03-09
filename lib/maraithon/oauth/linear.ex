defmodule Maraithon.OAuth.Linear do
  @moduledoc """
  Linear OAuth 2.0 helpers.

  Handles OAuth authorization flow for Linear workspace access.

  ## Configuration

      config :maraithon, :linear,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        redirect_uri: "https://your-domain.com/auth/linear/callback",
        webhook_secret: "your_webhook_secret"
  """

  alias Maraithon.HTTP
  alias Maraithon.Crypto

  @default_auth_url "https://linear.app/oauth/authorize"
  @default_token_url "https://api.linear.app/oauth/token"
  @default_revoke_url "https://api.linear.app/oauth/revoke"
  @default_api_url "https://api.linear.app/graphql"

  @default_scopes ["read", "write", "issues:create", "comments:create"]

  @doc """
  Returns the default Linear OAuth scopes.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Returns true when Linear OAuth is configured for interactive connects.
  """
  def configured? do
    config = get_config()
    config.client_id != "" and config.client_secret != "" and config.redirect_uri != ""
  end

  @doc """
  Generates the Linear OAuth authorization URL.
  """
  def authorize_url(scopes \\ @default_scopes, state) do
    config = get_config()

    params =
      URI.encode_query(%{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        response_type: "code",
        scope: Enum.join(scopes, ","),
        state: state,
        prompt: "consent"
      })

    "#{auth_url()}?#{params}"
  end

  @doc """
  Exchanges an authorization code for tokens.
  """
  def exchange_code(code) do
    config = get_config()

    body = %{
      code: code,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: config.redirect_uri,
      grant_type: "authorization_code"
    }

    case HTTP.post_json(token_url(), body) do
      {:ok, response} when is_map(response) ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Revokes a Linear token.
  """
  def revoke_token(access_token) do
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case HTTP.post_json(revoke_url(), %{}, headers) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:revocation_failed, reason}}
    end
  end

  @doc """
  Verifies a Linear webhook signature.

  Linear signs webhooks using HMAC-SHA256 with the webhook secret.
  """
  def verify_signature(raw_body, signature) do
    webhook_secret = get_webhook_secret()

    if webhook_secret == "" do
      if allow_unsigned?() do
        :ok
      else
        {:error, :webhook_secret_not_configured}
      end
    else
      Crypto.verify_hmac_sha256(webhook_secret, raw_body, signature)
    end
  end

  @doc """
  Makes a GraphQL request to the Linear API.
  """
  def graphql(access_token, query, variables \\ %{}) do
    headers = [{"Authorization", "Bearer #{access_token}"}]
    body = %{query: query, variables: variables}

    case HTTP.post_json(api_url(), body, headers) do
      {:ok, %{"errors" => errors}} ->
        {:error, {:graphql_errors, errors}}

      {:ok, %{"data" => data}} ->
        {:ok, data}

      {:ok, response} when is_map(response) ->
        # Handle responses without explicit data key
        {:ok, response}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, {:api_error, reason}}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_config do
    config = Application.get_env(:maraithon, :linear, [])

    %{
      client_id: Keyword.get(config, :client_id, ""),
      client_secret: Keyword.get(config, :client_secret, ""),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp auth_url do
    config = Application.get_env(:maraithon, :linear, [])
    Keyword.get(config, :auth_url, @default_auth_url)
  end

  defp token_url do
    config = Application.get_env(:maraithon, :linear, [])
    Keyword.get(config, :token_url, @default_token_url)
  end

  defp revoke_url do
    config = Application.get_env(:maraithon, :linear, [])
    Keyword.get(config, :revoke_url, @default_revoke_url)
  end

  defp api_url do
    config = Application.get_env(:maraithon, :linear, [])
    Keyword.get(config, :api_url, @default_api_url)
  end

  defp get_webhook_secret do
    Application.get_env(:maraithon, :linear, [])
    |> Keyword.get(:webhook_secret, "")
  end

  defp allow_unsigned? do
    Application.get_env(:maraithon, :linear, [])
    |> Keyword.get(:allow_unsigned, false)
  end

  defp parse_token_response(response) do
    %{
      access_token: response["access_token"],
      token_type: response["token_type"],
      expires_in: response["expires_in"],
      scope: response["scope"]
    }
  end
end
