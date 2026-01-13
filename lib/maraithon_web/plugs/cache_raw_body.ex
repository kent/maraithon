defmodule MaraithonWeb.Plugs.CacheRawBody do
  @moduledoc """
  Custom body reader that caches the raw request body for signature verification.

  Webhook signature verification requires the exact bytes received, not a re-encoded
  version. This module provides a body reader function that caches the raw body in
  `conn.assigns[:raw_body]` before returning it to Plug.Parsers.

  ## Usage

  Configure Plug.Parsers in your endpoint:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {MaraithonWeb.Plugs.CacheRawBody, :read_body, []},
        json_decoder: Phoenix.json_library()

  Then access the raw body in controllers:

      raw_body = conn.assigns[:raw_body]
  """

  @doc """
  Reads the request body and caches it in conn.assigns[:raw_body].

  This function is designed to be used with Plug.Parsers' :body_reader option.
  """
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.assign(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, partial, conn} ->
        # Handle chunked bodies by accumulating
        read_body_chunked(conn, opts, partial)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body_chunked(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        full_body = acc <> body
        conn = Plug.Conn.assign(conn, :raw_body, full_body)
        {:ok, full_body, conn}

      {:more, partial, conn} ->
        read_body_chunked(conn, opts, acc <> partial)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
