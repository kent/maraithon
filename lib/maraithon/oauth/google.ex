defmodule Maraithon.OAuth.Google do
  @moduledoc """
  Google OAuth 2.0 helpers.

  Handles OAuth authorization flow, token exchange, and token refresh for Google APIs.

  ## Configuration

      config :maraithon, :google,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        redirect_uri: "https://your-domain.com/auth/google/callback"

  ## Supported Scopes

  - Calendar: `https://www.googleapis.com/auth/calendar.readonly`
  - Gmail: `https://www.googleapis.com/auth/gmail.readonly`
  """

  require Logger

  @google_auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @google_token_url "https://oauth2.googleapis.com/token"
  @google_revoke_url "https://oauth2.googleapis.com/revoke"

  @scope_calendar "https://www.googleapis.com/auth/calendar.readonly"
  @scope_gmail "https://www.googleapis.com/auth/gmail.readonly"

  @doc """
  Returns the Google OAuth scopes for the given service names.

  ## Examples

      iex> Maraithon.OAuth.Google.scopes_for(["calendar"])
      ["https://www.googleapis.com/auth/calendar.readonly"]

      iex> Maraithon.OAuth.Google.scopes_for(["calendar", "gmail"])
      ["https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/gmail.readonly"]
  """
  def scopes_for(services) when is_list(services) do
    services
    |> Enum.map(&scope_for/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp scope_for("calendar"), do: @scope_calendar
  defp scope_for("gmail"), do: @scope_gmail
  defp scope_for(_), do: nil

  @doc """
  Generates the Google OAuth authorization URL.

  ## Parameters

  - `scopes` - List of scope URLs
  - `state` - State parameter for CSRF protection (should include user_id)

  ## Returns

  The authorization URL to redirect the user to.
  """
  def authorize_url(scopes, state) when is_list(scopes) do
    config = get_config()

    params =
      URI.encode_query(%{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        response_type: "code",
        scope: Enum.join(scopes, " "),
        state: state,
        access_type: "offline",
        prompt: "consent"
      })

    "#{@google_auth_url}?#{params}"
  end

  @doc """
  Exchanges an authorization code for tokens.

  ## Parameters

  - `code` - The authorization code from Google

  ## Returns

  `{:ok, tokens}` or `{:error, reason}`

  Where tokens is a map with:
  - `access_token` - The access token
  - `refresh_token` - The refresh token (only on first authorization)
  - `expires_in` - Token lifetime in seconds
  - `scope` - Granted scopes
  """
  def exchange_code(code) do
    config = get_config()

    body =
      URI.encode_query(%{
        code: code,
        client_id: config.client_id,
        client_secret: config.client_secret,
        redirect_uri: config.redirect_uri,
        grant_type: "authorization_code"
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case :httpc.request(
           :post,
           {~c"#{@google_token_url}", headers, ~c"application/x-www-form-urlencoded",
            String.to_charlist(body)},
           [],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        tokens = Jason.decode!(List.to_string(response_body))
        {:ok, parse_token_response(tokens)}

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Google token exchange failed",
          status: status,
          body: List.to_string(response_body)
        )

        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        Logger.warning("Google token exchange HTTP error", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Refreshes an access token using a refresh token.

  ## Parameters

  - `refresh_token` - The refresh token

  ## Returns

  `{:ok, tokens}` or `{:error, reason}`
  """
  def refresh_token(refresh_token) do
    config = get_config()

    body =
      URI.encode_query(%{
        refresh_token: refresh_token,
        client_id: config.client_id,
        client_secret: config.client_secret,
        grant_type: "refresh_token"
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case :httpc.request(
           :post,
           {~c"#{@google_token_url}", headers, ~c"application/x-www-form-urlencoded",
            String.to_charlist(body)},
           [],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        tokens = Jason.decode!(List.to_string(response_body))
        {:ok, parse_token_response(tokens)}

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Google token refresh failed",
          status: status,
          body: List.to_string(response_body)
        )

        {:error, {:token_refresh_failed, status}}

      {:error, reason} ->
        Logger.warning("Google token refresh HTTP error", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Revokes an access or refresh token.

  ## Parameters

  - `token` - The token to revoke

  ## Returns

  `:ok` or `{:error, reason}`
  """
  def revoke_token(token) do
    url = "#{@google_revoke_url}?token=#{URI.encode(token)}"

    case :httpc.request(:post, {~c"#{url}", [], ~c"", ~c""}, [], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Google token revocation failed",
          status: status,
          body: List.to_string(response_body)
        )

        {:error, {:revocation_failed, status}}

      {:error, reason} ->
        Logger.warning("Google token revocation HTTP error", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Makes an authenticated request to a Google API.

  ## Parameters

  - `method` - HTTP method (:get, :post, etc.)
  - `url` - The API URL
  - `access_token` - The access token
  - `body` - Request body (optional, for POST/PUT/PATCH)
  - `headers` - Additional headers (optional)

  ## Returns

  `{:ok, response_body}` or `{:error, reason}`
  """
  def api_request(method, url, access_token, body \\ nil, extra_headers \\ []) do
    headers = [{"Authorization", "Bearer #{access_token}"} | extra_headers]

    request =
      case method do
        :get ->
          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)}

        method when method in [:post, :put, :patch] ->
          content_type = ~c"application/json"
          body_data = if body, do: Jason.encode!(body), else: ""

          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end), content_type,
           String.to_charlist(body_data)}

        :delete ->
          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)}
      end

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, status, _}, _, response_body}} when status in 200..299 ->
        {:ok, Jason.decode!(List.to_string(response_body))}

      {:ok, {{_, 401, _}, _, _}} ->
        {:error, :unauthorized}

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Google API request failed",
          status: status,
          url: url,
          body: List.to_string(response_body)
        )

        {:error, {:api_error, status, List.to_string(response_body)}}

      {:error, reason} ->
        Logger.warning("Google API HTTP error", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_config do
    config = Application.get_env(:maraithon, :google, [])

    %{
      client_id: Keyword.get(config, :client_id, ""),
      client_secret: Keyword.get(config, :client_secret, ""),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp parse_token_response(response) do
    %{
      access_token: response["access_token"],
      refresh_token: response["refresh_token"],
      expires_in: response["expires_in"],
      scope: response["scope"],
      token_type: response["token_type"]
    }
  end
end
