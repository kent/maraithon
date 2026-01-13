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

  alias Maraithon.HTTP

  @default_auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @default_token_url "https://oauth2.googleapis.com/token"
  @default_revoke_url "https://oauth2.googleapis.com/revoke"

  @scope_calendar "https://www.googleapis.com/auth/calendar.readonly"
  @scope_gmail "https://www.googleapis.com/auth/gmail.readonly"

  @doc """
  Returns the Google OAuth scopes for the given service names.
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
      {:ok, response} when is_map(response) ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Refreshes an access token using a refresh token.
  """
  def refresh_token(refresh_token) do
    config = get_config()

    params = %{
      refresh_token: refresh_token,
      client_id: config.client_id,
      client_secret: config.client_secret,
      grant_type: "refresh_token"
    }

    case HTTP.post_form(token_url(), params) do
      {:ok, response} when is_map(response) ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  @doc """
  Revokes an access or refresh token.
  """
  def revoke_token(token) do
    url = "#{revoke_url()}?token=#{URI.encode(token)}"

    case HTTP.post_form(url, %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:revocation_failed, reason}}
    end
  end

  @doc """
  Makes an authenticated request to a Google API.
  """
  def api_request(method, url, access_token, body \\ nil, extra_headers \\ []) do
    headers = [{"Authorization", "Bearer #{access_token}"} | extra_headers]

    case method do
      :get ->
        HTTP.get(url, headers)

      :post ->
        HTTP.post_json(url, body || %{}, headers)

      :put ->
        HTTP.put_json(url, body || %{}, headers)

      :patch ->
        HTTP.patch_json(url, body || %{}, headers)

      :delete ->
        HTTP.delete(url, headers)
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

  defp auth_url do
    config = Application.get_env(:maraithon, :google, [])
    Keyword.get(config, :auth_url, @default_auth_url)
  end

  defp token_url do
    config = Application.get_env(:maraithon, :google, [])
    Keyword.get(config, :token_url, @default_token_url)
  end

  defp revoke_url do
    config = Application.get_env(:maraithon, :google, [])
    Keyword.get(config, :revoke_url, @default_revoke_url)
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
