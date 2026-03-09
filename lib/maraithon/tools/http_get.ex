defmodule Maraithon.Tools.HttpGet do
  @moduledoc """
  HTTP GET tool for fetching URLs.
  """

  require Logger

  @max_response_body_chars 5_000
  @max_url_length 2_048
  @receive_timeout_ms 10_000
  @connect_timeout_ms 5_000

  def execute(args) do
    with {:ok, url} <- extract_url(args),
         :ok <- validate_url(url) do
      fetch_url(url)
    end
  end

  defp fetch_url(url) do
    Logger.info("HTTP GET", url: url)

    case Req.get(url,
           receive_timeout: @receive_timeout_ms,
           connect_options: [timeout: @connect_timeout_ms]
         ) do
      {:ok, %{status: status, body: body}} ->
        {:ok,
         %{
           status: status,
           body: truncate(body, @max_response_body_chars),
           url: url
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp extract_url(%{"url" => url}) when is_binary(url) do
    case String.trim(url) do
      "" -> {:error, "url is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp extract_url(_args), do: {:error, "url is required"}

  defp validate_url(url) do
    cond do
      byte_size(url) > @max_url_length ->
        {:error, "url is too long"}

      true ->
        validate_parsed_uri(URI.parse(url))
    end
  end

  defp validate_parsed_uri(%URI{userinfo: userinfo}) when is_binary(userinfo) do
    {:error, "url must not include credentials"}
  end

  defp validate_parsed_uri(%URI{scheme: nil}) do
    {:error, "url must include scheme (http or https)"}
  end

  defp validate_parsed_uri(%URI{scheme: scheme}) when scheme not in ["http", "https"] do
    {:error, "url scheme must be http or https"}
  end

  defp validate_parsed_uri(%URI{host: host}) when host in [nil, ""] do
    {:error, "url host is required"}
  end

  defp validate_parsed_uri(%URI{port: port})
       when is_integer(port) and (port < 1 or port > 65_535) do
    {:error, "url port is invalid"}
  end

  defp validate_parsed_uri(%URI{}), do: :ok

  defp truncate(body, max_length) when is_binary(body) do
    if String.length(body) > max_length do
      String.slice(body, 0, max_length) <> "... (truncated)"
    else
      body
    end
  end

  defp truncate(body, _max_length), do: inspect(body)
end
