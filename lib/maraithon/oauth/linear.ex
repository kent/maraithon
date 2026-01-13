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

  ## Scopes

  Linear uses actor-based authorization. The OAuth flow grants access based on
  the authorizing user's permissions in their workspace.
  """

  require Logger

  @linear_auth_url "https://linear.app/oauth/authorize"
  @linear_token_url "https://api.linear.app/oauth/token"
  @linear_revoke_url "https://api.linear.app/oauth/revoke"
  @linear_api_url "https://api.linear.app/graphql"

  @default_scopes ["read", "write", "issues:create", "comments:create"]

  @doc """
  Returns the default Linear OAuth scopes.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Generates the Linear OAuth authorization URL.

  ## Parameters

  - `scopes` - List of OAuth scopes
  - `state` - State parameter for CSRF protection
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

    "#{@linear_auth_url}?#{params}"
  end

  @doc """
  Exchanges an authorization code for tokens.

  ## Returns

  `{:ok, tokens}` or `{:error, reason}`

  Where tokens includes:
  - `access_token` - API access token
  - `expires_in` - Token lifetime in seconds
  """
  def exchange_code(code) do
    config = get_config()

    body =
      Jason.encode!(%{
        code: code,
        client_id: config.client_id,
        client_secret: config.client_secret,
        redirect_uri: config.redirect_uri,
        grant_type: "authorization_code"
      })

    headers = [{"Content-Type", "application/json"}]

    case :httpc.request(
           :post,
           {~c"#{@linear_token_url}", headers, ~c"application/json", String.to_charlist(body)},
           [],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(List.to_string(response_body)) do
          {:ok, tokens} ->
            {:ok, parse_token_response(tokens)}

          {:error, _} ->
            Logger.warning("Linear token exchange returned invalid JSON")
            {:error, :invalid_json_response}
        end

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Linear token exchange failed",
          status: status,
          body: List.to_string(response_body)
        )

        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        Logger.warning("Linear token exchange HTTP error", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Revokes a Linear token.
  """
  def revoke_token(access_token) do
    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    case :httpc.request(
           :post,
           {~c"#{@linear_revoke_url}",
            Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end), ~c"application/json", ~c"{}"},
           [],
           []
         ) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:revocation_failed, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Verifies a Linear webhook signature.

  Linear signs webhooks using HMAC-SHA256 with the webhook secret.
  """
  def verify_signature(raw_body, signature) do
    webhook_secret = get_webhook_secret()

    if webhook_secret == "" do
      # No secret configured - only allow if explicitly enabled
      if allow_unsigned?() do
        :ok
      else
        {:error, :webhook_secret_not_configured}
      end
    else
      expected =
        :crypto.mac(:hmac, :sha256, webhook_secret, raw_body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, String.downcase(signature || "")) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  @doc """
  Makes a GraphQL request to the Linear API.
  """
  def graphql(access_token, query, variables \\ %{}) do
    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    body = Jason.encode!(%{query: query, variables: variables})

    case :httpc.request(
           :post,
           {~c"#{@linear_api_url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end),
            ~c"application/json", String.to_charlist(body)},
           [],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(List.to_string(response_body)) do
          {:ok, response} ->
            if response["errors"] do
              {:error, {:graphql_errors, response["errors"]}}
            else
              {:ok, response["data"]}
            end

          {:error, _} ->
            Logger.warning("Linear API returned invalid JSON")
            {:error, :invalid_json_response}
        end

      {:ok, {{_, 401, _}, _, _}} ->
        {:error, :unauthorized}

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Linear API request failed",
          status: status,
          body: List.to_string(response_body)
        )

        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
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
