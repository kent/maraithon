defmodule Maraithon.HTTP do
  @moduledoc """
  Shared HTTP client for external API requests.

  Provides a consistent interface over `Req` with proper error handling and
  JSON decoding.

  ## Usage

      # POST with form-encoded body
      HTTP.post_form("https://api.example.com/token", %{code: "abc"})

      # POST with JSON body
      HTTP.post_json("https://api.example.com/data", %{key: "value"}, [{"Authorization", "Bearer token"}])

      # GET request
      HTTP.get("https://api.example.com/data", [{"Authorization", "Bearer token"}])
  """

  alias Req.Response

  require Logger

  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, map() | binary()} | {:error, term()}

  @doc """
  Makes a POST request with form-urlencoded body.
  """
  @spec post_form(String.t(), map(), headers()) :: response()
  def post_form(url, params, headers \\ []) when is_map(params) do
    request(:post, url, headers, form: params)
  end

  @doc """
  Makes a POST request with JSON body.
  """
  @spec post_json(String.t(), map(), headers()) :: response()
  def post_json(url, body, headers \\ []) when is_map(body) do
    request(:post, url, headers, json: body)
  end

  @doc """
  Makes a GET request.
  """
  @spec get(String.t(), headers()) :: response()
  def get(url, headers \\ []) do
    request(:get, url, headers, [])
  end

  @doc """
  Makes a DELETE request.
  """
  @spec delete(String.t(), headers()) :: response()
  def delete(url, headers \\ []) do
    request(:delete, url, headers, [])
  end

  @doc """
  Makes a DELETE request with JSON body.
  """
  @spec delete_json(String.t(), map(), headers()) :: response()
  def delete_json(url, body, headers \\ []) when is_map(body) do
    request(:delete, url, headers, json: body)
  end

  @doc """
  Makes a PUT request with JSON body.
  """
  @spec put_json(String.t(), map(), headers()) :: response()
  def put_json(url, body, headers \\ []) when is_map(body) do
    request(:put, url, headers, json: body)
  end

  @doc """
  Makes a PATCH request with JSON body.
  """
  @spec patch_json(String.t(), map(), headers()) :: response()
  def patch_json(url, body, headers \\ []) when is_map(body) do
    request(:patch, url, headers, json: body)
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp request(method, url, headers, req_opts) do
    req =
      Req.new(
        method: method,
        url: url,
        headers: normalize_headers(headers),
        retry: false,
        receive_timeout: 15_000
      )

    case Req.request(req, req_opts) do
      {:ok, %Response{status: status, body: body}} ->
        handle_response(status, body, url)

      {:error, reason} ->
        Logger.warning("HTTP request failed", url: url, reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  defp handle_response(status, body, _url) when status in 200..299, do: {:ok, body}

  defp handle_response(401, _body, _url) do
    {:error, :unauthorized}
  end

  defp handle_response(429, body, _url) do
    {:error, {:rate_limited, response_body_to_string(body)}}
  end

  defp handle_response(status, body, url) do
    body_string = response_body_to_string(body)
    Logger.warning("HTTP request failed", url: url, status: status, body: body_string)
    {:error, {:http_status, status, body_string}}
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn
      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp response_body_to_string(body) when is_binary(body), do: body
  defp response_body_to_string(body) when is_map(body) or is_list(body), do: inspect(body)
  defp response_body_to_string(body), do: to_string(body)
end
