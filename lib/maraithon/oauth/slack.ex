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

  ## Scopes

  Common scopes:
  - `channels:history` - View messages in public channels
  - `channels:read` - View basic channel info
  - `chat:write` - Send messages
  - `users:read` - View users
  - `reactions:read` - View reactions
  - `im:history` - View DM messages
  """

  require Logger

  @slack_auth_url "https://slack.com/oauth/v2/authorize"
  @slack_token_url "https://slack.com/api/oauth.v2.access"
  @slack_revoke_url "https://slack.com/api/auth.revoke"

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

  ## Parameters

  - `scopes` - List of OAuth scopes (defaults to standard bot scopes)
  - `state` - State parameter for CSRF protection
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

    "#{@slack_auth_url}?#{params}"
  end

  @doc """
  Exchanges an authorization code for tokens.

  ## Returns

  `{:ok, tokens}` or `{:error, reason}`

  Where tokens includes:
  - `access_token` - Bot token
  - `team_id` - Workspace ID
  - `team_name` - Workspace name
  - `bot_user_id` - Bot's user ID
  """
  def exchange_code(code) do
    config = get_config()

    body =
      URI.encode_query(%{
        code: code,
        client_id: config.client_id,
        client_secret: config.client_secret,
        redirect_uri: config.redirect_uri
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case :httpc.request(
           :post,
           {~c"#{@slack_token_url}", headers, ~c"application/x-www-form-urlencoded",
            String.to_charlist(body)},
           [],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(List.to_string(response_body)) do
          {:ok, response} ->
            if response["ok"] do
              {:ok, parse_token_response(response)}
            else
              {:error, {:slack_error, response["error"]}}
            end

          {:error, _} ->
            Logger.warning("Slack token exchange returned invalid JSON")
            {:error, :invalid_json_response}
        end

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Slack token exchange failed",
          status: status,
          body: List.to_string(response_body)
        )

        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        Logger.warning("Slack token exchange HTTP error", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Revokes a Slack token.
  """
  def revoke_token(access_token) do
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case :httpc.request(
           :post,
           {~c"#{@slack_revoke_url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end),
            ~c"application/x-www-form-urlencoded", ~c""},
           [],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(List.to_string(response_body)) do
          {:ok, response} ->
            if response["ok"] do
              :ok
            else
              {:error, {:slack_error, response["error"]}}
            end

          {:error, _} ->
            Logger.warning("Slack token revocation returned invalid JSON")
            {:error, :invalid_json_response}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:revocation_failed, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Verifies a Slack request signature.

  Slack signs requests using HMAC-SHA256 with the signing secret.
  """
  def verify_signature(raw_body, timestamp, signature) do
    signing_secret = get_signing_secret()

    if signing_secret == "" do
      # No secret configured - allow in dev
      :ok
    else
      # Check timestamp is recent (within 5 minutes)
      now = System.system_time(:second)

      case Integer.parse(timestamp) do
        {ts, _} when abs(now - ts) < 300 ->
          # Compute expected signature
          sig_basestring = "v0:#{timestamp}:#{raw_body}"

          expected =
            :crypto.mac(:hmac, :sha256, signing_secret, sig_basestring)
            |> Base.encode16(case: :lower)

          expected_sig = "v0=#{expected}"

          if Plug.Crypto.secure_compare(expected_sig, signature) do
            :ok
          else
            {:error, :invalid_signature}
          end

        _ ->
          {:error, :timestamp_expired}
      end
    end
  end

  @doc """
  Makes an authenticated request to the Slack API.
  """
  def api_request(method, endpoint, access_token, body \\ nil) do
    url = "https://slack.com/api/#{endpoint}"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    request =
      case method do
        :get ->
          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)}

        :post ->
          content_type = ~c"application/json; charset=utf-8"
          body_data = if body, do: Jason.encode!(body), else: "{}"

          {~c"#{url}", Enum.map(headers, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end), content_type,
           String.to_charlist(body_data)}
      end

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(List.to_string(response_body)) do
          {:ok, response} ->
            if response["ok"] do
              {:ok, response}
            else
              {:error, {:slack_error, response["error"]}}
            end

          {:error, _} ->
            Logger.warning("Slack API returned invalid JSON", endpoint: endpoint)
            {:error, :invalid_json_response}
        end

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Slack API request failed",
          status: status,
          endpoint: endpoint,
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
    config = Application.get_env(:maraithon, :slack, [])

    %{
      client_id: Keyword.get(config, :client_id, ""),
      client_secret: Keyword.get(config, :client_secret, ""),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp get_signing_secret do
    Application.get_env(:maraithon, :slack, [])
    |> Keyword.get(:signing_secret, "")
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
