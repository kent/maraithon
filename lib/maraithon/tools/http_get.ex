defmodule Maraithon.Tools.HttpGet do
  @moduledoc """
  HTTP GET tool for fetching URLs.
  """

  require Logger

  def execute(args) do
    url = args["url"]

    unless url do
      {:error, "url is required"}
    else
      fetch_url(url)
    end
  end

  defp fetch_url(url) do
    Logger.info("HTTP GET", url: url)

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} ->
        {:ok,
         %{
           status: status,
           body: truncate(body, 5000),
           url: url
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp truncate(body, max_length) when is_binary(body) do
    if String.length(body) > max_length do
      String.slice(body, 0, max_length) <> "... (truncated)"
    else
      body
    end
  end

  defp truncate(body, _max_length), do: inspect(body)
end
