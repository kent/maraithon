defmodule Maraithon.OAuth.GitHub do
  @moduledoc """
  GitHub OAuth helpers for user-authorized repository access.
  """

  alias Maraithon.HTTP

  @default_auth_url "https://github.com/login/oauth/authorize"
  @default_token_url "https://github.com/login/oauth/access_token"
  @default_api_base_url "https://api.github.com"

  @default_scopes ["repo", "read:org", "notifications", "user:email"]

  @github_api_version "2022-11-28"

  @doc """
  Returns the default GitHub scopes used by the admin control center.
  """
  def default_scopes, do: @default_scopes

  @doc """
  Returns true when GitHub OAuth is configured for interactive connects.
  """
  def configured? do
    config = get_config()
    config.client_id != "" and config.client_secret != "" and config.redirect_uri != ""
  end

  @doc """
  Generates the GitHub OAuth authorization URL.
  """
  def authorize_url(scopes \\ @default_scopes, state, opts \\ []) when is_list(scopes) do
    config = get_config()

    params =
      %{
        client_id: config.client_id,
        redirect_uri: config.redirect_uri,
        scope: Enum.join(scopes, " "),
        state: state
      }
      |> maybe_put("allow_signup", Keyword.get(opts, :allow_signup, "false"))
      |> maybe_put("code_challenge", Keyword.get(opts, :code_challenge))
      |> maybe_put(
        "code_challenge_method",
        if(Keyword.has_key?(opts, :code_challenge), do: "S256", else: nil)
      )
      |> URI.encode_query()

    "#{auth_url()}?#{params}"
  end

  @doc """
  Exchanges an authorization code for an access token.
  """
  def exchange_code(code, opts \\ []) when is_binary(code) do
    config = get_config()

    params =
      %{
        client_id: config.client_id,
        client_secret: config.client_secret,
        code: code,
        redirect_uri: config.redirect_uri
      }
      |> maybe_put(:code_verifier, Keyword.get(opts, :code_verifier))

    headers = [{"accept", "application/json"}]

    case HTTP.post_form(token_url(), params, headers) do
      {:ok, %{"error" => error} = response} ->
        {:error, {:github_error, error, response}}

      {:ok, %{} = response} ->
        {:ok, parse_token_response(response)}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Revokes a GitHub OAuth access token for the configured OAuth app.
  """
  def revoke_token(access_token) when is_binary(access_token) do
    config = get_config()

    if config.client_id == "" or config.client_secret == "" do
      {:error, :oauth_app_not_configured}
    else
      headers = [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Basic #{basic_auth(config.client_id, config.client_secret)}"},
        {"x-github-api-version", @github_api_version}
      ]

      case HTTP.delete_json(
             "#{api_base_url()}/applications/#{config.client_id}/token",
             %{access_token: access_token},
             headers
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:revocation_failed, reason}}
      end
    end
  end

  @doc """
  Fetches the connected GitHub user profile.
  """
  def viewer(access_token) when is_binary(access_token) do
    with {:ok, %{} = user} <- api_request(:get, "/user", access_token) do
      {:ok,
       %{
         id: user["id"],
         login: user["login"],
         name: user["name"],
         email: user["email"] || primary_email(access_token),
         avatar_url: user["avatar_url"],
         html_url: user["html_url"]
       }}
    end
  end

  @doc """
  Makes an authenticated request to the GitHub REST API.
  """
  def api_request(method, path, access_token, body \\ nil)
      when method in [:get, :post, :delete] and is_binary(path) and is_binary(access_token) do
    request(method, path, body, [
      {"authorization", "Bearer #{access_token}"}
    ])
  end

  @doc """
  Makes an unauthenticated request to the GitHub REST API.
  Useful for public repository access when the user has not linked GitHub.
  """
  def public_api_request(method, path, body \\ nil) when method in [:get, :post, :delete] do
    request(method, path, body, [])
  end

  defp primary_email(access_token) do
    case api_request(:get, "/user/emails", access_token) do
      {:ok, emails} when is_list(emails) ->
        emails
        |> Enum.find_value(fn
          %{"verified" => true, "primary" => true, "email" => email} -> email
          %{"verified" => true, "email" => email} -> email
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp parse_token_response(response) do
    %{
      access_token: response["access_token"],
      scope: response["scope"],
      token_type: response["token_type"]
    }
  end

  defp get_config do
    config = Application.get_env(:maraithon, :github, [])

    %{
      client_id: Keyword.get(config, :client_id, ""),
      client_secret: Keyword.get(config, :client_secret, ""),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp auth_url do
    Application.get_env(:maraithon, :github, [])
    |> Keyword.get(:auth_url, @default_auth_url)
  end

  defp token_url do
    Application.get_env(:maraithon, :github, [])
    |> Keyword.get(:token_url, @default_token_url)
  end

  defp api_base_url do
    Application.get_env(:maraithon, :github, [])
    |> Keyword.get(:api_base_url, @default_api_base_url)
  end

  defp request(method, path, body, extra_headers) do
    url = "#{api_base_url()}#{path}"

    headers =
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", @github_api_version}
      ] ++ extra_headers

    case method do
      :get -> HTTP.get(url, headers)
      :post -> HTTP.post_json(url, body || %{}, headers)
      :delete -> HTTP.delete(url, headers)
    end
  end

  defp basic_auth(client_id, client_secret) do
    Base.encode64("#{client_id}:#{client_secret}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
