defmodule Maraithon.OAuth.Notion do
  @moduledoc """
  Notion OAuth helpers for user-authorized workspace access.
  """

  alias Maraithon.HTTP

  @default_auth_url "https://api.notion.com/v1/oauth/authorize"
  @default_token_url "https://api.notion.com/v1/oauth/token"
  @default_revoke_url "https://api.notion.com/v1/oauth/revoke"
  @default_api_base_url "https://api.notion.com/v1"
  @default_api_version "2025-09-03"

  @doc """
  Returns true when Notion OAuth is configured for interactive connects.
  """
  def configured? do
    config = get_config()
    config.client_id != "" and config.client_secret != "" and config.redirect_uri != ""
  end

  @doc """
  Generates the Notion OAuth authorization URL.
  """
  def authorize_url(state) when is_binary(state) do
    config = get_config()

    params =
      URI.encode_query(%{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        response_type: "code",
        owner: "user",
        state: state
      })

    "#{auth_url()}?#{params}"
  end

  @doc """
  Exchanges an authorization code for Notion access and refresh tokens.
  """
  def exchange_code(code) when is_binary(code) do
    config = get_config()

    headers = [
      {"authorization", "Basic #{basic_auth(config.client_id, config.client_secret)}"},
      {"accept", "application/json"}
    ]

    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: config.redirect_uri
    }

    case HTTP.post_json(token_url(), body, headers) do
      {:ok, %{"error" => error} = response} ->
        {:error, {:notion_error, error, response}}

      {:ok, %{} = response} ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Refreshes an expiring Notion access token.
  """
  def refresh_token(refresh_token) when is_binary(refresh_token) do
    config = get_config()

    headers = [
      {"authorization", "Basic #{basic_auth(config.client_id, config.client_secret)}"},
      {"accept", "application/json"}
    ]

    body = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token
    }

    case HTTP.post_json(token_url(), body, headers) do
      {:ok, %{"error" => error} = response} ->
        {:error, {:notion_error, error, response}}

      {:ok, %{} = response} ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  @doc """
  Revokes a Notion access token.
  """
  def revoke_token(token) when is_binary(token) do
    config = get_config()

    headers = [
      {"authorization", "Basic #{basic_auth(config.client_id, config.client_secret)}"},
      {"accept", "application/json"}
    ]

    case HTTP.post_json(revoke_url(), %{token: token}, headers) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:revocation_failed, reason}}
    end
  end

  @doc """
  Makes an authenticated request to the Notion API.
  """
  def api_request(method, path, access_token, body \\ nil)
      when method in [:get, :post] and is_binary(path) and is_binary(access_token) do
    url = "#{api_base_url()}#{path}"

    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"notion-version", api_version()},
      {"accept", "application/json"}
    ]

    case method do
      :get -> HTTP.get(url, headers)
      :post -> HTTP.post_json(url, body || %{}, headers)
    end
  end

  defp parse_token_response(response) do
    %{
      access_token: response["access_token"],
      refresh_token: response["refresh_token"],
      token_type: response["token_type"],
      expires_in: response["expires_in"],
      workspace_id: response["workspace_id"],
      workspace_name: response["workspace_name"],
      workspace_icon: response["workspace_icon"],
      owner: response["owner"],
      bot_id: response["bot_id"],
      duplicated_template_id: response["duplicated_template_id"]
    }
  end

  defp get_config do
    config = Application.get_env(:maraithon, :notion, [])

    %{
      client_id: Keyword.get(config, :client_id, ""),
      client_secret: Keyword.get(config, :client_secret, ""),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp auth_url do
    Application.get_env(:maraithon, :notion, [])
    |> Keyword.get(:auth_url, @default_auth_url)
  end

  defp token_url do
    Application.get_env(:maraithon, :notion, [])
    |> Keyword.get(:token_url, @default_token_url)
  end

  defp revoke_url do
    Application.get_env(:maraithon, :notion, [])
    |> Keyword.get(:revoke_url, @default_revoke_url)
  end

  defp api_base_url do
    Application.get_env(:maraithon, :notion, [])
    |> Keyword.get(:api_base_url, @default_api_base_url)
  end

  defp api_version do
    Application.get_env(:maraithon, :notion, [])
    |> Keyword.get(:api_version, @default_api_version)
  end

  defp basic_auth(client_id, client_secret) do
    Base.encode64("#{client_id}:#{client_secret}")
  end
end
