defmodule Maraithon.HTTP do
  @moduledoc """
  Shared HTTP client for external API requests.

  Provides a consistent interface over `:httpc` with proper error handling,
  JSON encoding/decoding, and charlist conversion.

  ## Usage

      # POST with form-encoded body
      HTTP.post_form("https://api.example.com/token", %{code: "abc"})

      # POST with JSON body
      HTTP.post_json("https://api.example.com/data", %{key: "value"}, [{"Authorization", "Bearer token"}])

      # GET request
      HTTP.get("https://api.example.com/data", [{"Authorization", "Bearer token"}])
  """

  require Logger

  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, map() | binary()} | {:error, term()}

  @doc """
  Makes a POST request with form-urlencoded body.
  """
  @spec post_form(String.t(), map(), headers()) :: response()
  def post_form(url, params, headers \\ []) when is_map(params) do
    body = URI.encode_query(params)
    headers = [{"Content-Type", "application/x-www-form-urlencoded"} | headers]

    request(:post, url, headers, body, "application/x-www-form-urlencoded")
  end

  @doc """
  Makes a POST request with JSON body.
  """
  @spec post_json(String.t(), map(), headers()) :: response()
  def post_json(url, body, headers \\ []) when is_map(body) do
    headers = [{"Content-Type", "application/json"} | headers]
    encoded_body = Jason.encode!(body)

    request(:post, url, headers, encoded_body, "application/json")
  end

  @doc """
  Makes a GET request.
  """
  @spec get(String.t(), headers()) :: response()
  def get(url, headers \\ []) do
    request(:get, url, headers, nil, nil)
  end

  @doc """
  Makes a DELETE request.
  """
  @spec delete(String.t(), headers()) :: response()
  def delete(url, headers \\ []) do
    request(:delete, url, headers, nil, nil)
  end

  @doc """
  Makes a PUT request with JSON body.
  """
  @spec put_json(String.t(), map(), headers()) :: response()
  def put_json(url, body, headers \\ []) when is_map(body) do
    headers = [{"Content-Type", "application/json"} | headers]
    encoded_body = Jason.encode!(body)

    request(:put, url, headers, encoded_body, "application/json")
  end

  @doc """
  Makes a PATCH request with JSON body.
  """
  @spec patch_json(String.t(), map(), headers()) :: response()
  def patch_json(url, body, headers \\ []) when is_map(body) do
    headers = [{"Content-Type", "application/json"} | headers]
    encoded_body = Jason.encode!(body)

    request(:patch, url, headers, encoded_body, "application/json")
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp request(method, url, headers, body, content_type) do
    httpc_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    httpc_request =
      case method do
        m when m in [:get, :delete] ->
          {to_charlist(url), httpc_headers}

        m when m in [:post, :put, :patch] ->
          {to_charlist(url), httpc_headers, to_charlist(content_type), to_charlist(body || "")}
      end

    case :httpc.request(method, httpc_request, [], []) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        handle_response(status, resp_body, url)

      {:error, reason} ->
        Logger.warning("HTTP request failed", url: url, reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  defp handle_response(status, body, _url) when status in 200..299 do
    body_string = List.to_string(body)

    case Jason.decode(body_string) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        # Return raw body if not JSON
        {:ok, body_string}
    end
  end

  defp handle_response(401, _body, _url) do
    {:error, :unauthorized}
  end

  defp handle_response(429, body, _url) do
    {:error, {:rate_limited, List.to_string(body)}}
  end

  defp handle_response(status, body, url) do
    body_string = List.to_string(body)
    Logger.warning("HTTP request failed", url: url, status: status, body: body_string)
    {:error, {:http_status, status, body_string}}
  end
end
