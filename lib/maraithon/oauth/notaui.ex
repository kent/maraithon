defmodule Maraithon.OAuth.Notaui do
  @moduledoc """
  Notaui OAuth helpers for user-authorized MCP access.
  """

  alias Maraithon.HTTP

  @default_issuer "https://api.notaui.com"
  @default_scopes ["tasks:read", "tasks:write", "projects:read", "projects:write", "tags:write"]

  @doc """
  Returns the default Notaui OAuth scopes.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Returns true when Notaui OAuth is configured for interactive connects.
  """
  def configured? do
    config = config()
    config.client_id != "" and config.client_secret != "" and config.redirect_uri != ""
  end

  @doc """
  Returns the normalized Notaui OAuth/MCP configuration.
  """
  def config do
    app_config = Application.get_env(:maraithon, :notaui, [])
    base_url = Keyword.get(app_config, :base_url, @default_issuer)

    %{
      issuer: Keyword.get(app_config, :issuer, base_url),
      auth_url: Keyword.get(app_config, :auth_url, join_url(base_url, "/oauth/authorize")),
      token_url: Keyword.get(app_config, :token_url, join_url(base_url, "/oauth/token")),
      revoke_url: Keyword.get(app_config, :revoke_url, ""),
      mcp_url: Keyword.get(app_config, :mcp_url, join_url(base_url, "/mcp")),
      register_url: Keyword.get(app_config, :register_url, join_url(base_url, "/oauth/register")),
      auth_server_metadata_url:
        Keyword.get(
          app_config,
          :auth_server_metadata_url,
          join_url(base_url, "/.well-known/oauth-authorization-server")
        ),
      protected_resource_metadata_url:
        Keyword.get(
          app_config,
          :protected_resource_metadata_url,
          join_url(base_url, "/.well-known/oauth-protected-resource")
        ),
      client_id: Keyword.get(app_config, :client_id, ""),
      client_secret: Keyword.get(app_config, :client_secret, ""),
      redirect_uri: Keyword.get(app_config, :redirect_uri, "")
    }
  end

  @doc """
  Generates the Notaui authorization URL.
  """
  def authorize_url(scopes \\ @default_scopes, state, opts \\ [])
      when is_binary(state) and is_list(scopes) do
    config = config()

    params =
      %{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        response_type: "code",
        scope: Enum.join(scopes, " "),
        state: state
      }
      |> maybe_put("code_challenge", Keyword.get(opts, :code_challenge))
      |> maybe_put(
        "code_challenge_method",
        if(Keyword.has_key?(opts, :code_challenge), do: "S256", else: nil)
      )
      |> URI.encode_query()

    "#{config.auth_url}?#{params}"
  end

  @doc """
  Exchanges an authorization code for access and refresh tokens.
  """
  def exchange_code(code, opts \\ []) when is_binary(code) do
    config = config()

    headers = [
      {"authorization", "Basic #{basic_auth(config.client_id, config.client_secret)}"},
      {"accept", "application/json"}
    ]

    params =
      %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: config.redirect_uri
      }
      |> maybe_put(:code_verifier, Keyword.get(opts, :code_verifier))

    case HTTP.post_form(config.token_url, params, headers) do
      {:ok, %{"error" => error} = response} ->
        {:error, {:notaui_error, error, response}}

      {:ok, %{} = response} ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Refreshes an expiring Notaui access token.
  """
  def refresh_token(refresh_token) when is_binary(refresh_token) do
    config = config()

    headers = [
      {"authorization", "Basic #{basic_auth(config.client_id, config.client_secret)}"},
      {"accept", "application/json"}
    ]

    params = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token
    }

    case HTTP.post_form(config.token_url, params, headers) do
      {:ok, %{"error" => error} = response} ->
        {:error, {:notaui_error, error, response}}

      {:ok, %{} = response} ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  @doc """
  Revokes a Notaui token when a revocation endpoint is configured.
  """
  def revoke_token(token) when is_binary(token) do
    case config().revoke_url do
      nil ->
        :ok

      "" ->
        :ok

      url ->
        cfg = config()

        headers = [
          {"authorization", "Basic #{basic_auth(cfg.client_id, cfg.client_secret)}"},
          {"accept", "application/json"}
        ]

        case HTTP.post_form(url, %{token: token}, headers) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:revocation_failed, reason}}
        end
    end
  end

  defp parse_token_response(response) do
    %{
      access_token: response["access_token"],
      refresh_token: response["refresh_token"],
      token_type: response["token_type"],
      expires_in: response["expires_in"],
      scope: response["scope"]
    }
  end

  defp basic_auth(client_id, client_secret) do
    Base.encode64("#{client_id}:#{client_secret}")
  end

  defp join_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    String.trim_trailing(base_url, "/") <> path
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
