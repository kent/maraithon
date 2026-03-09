defmodule MaraithonWeb.Plugs.RequireApiToken do
  @moduledoc """
  Protects API endpoints with a bearer token when configured.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected_token =
      Application.get_env(:maraithon, :api_auth, [])
      |> Keyword.get(:bearer_token, "")

    if expected_token == "" do
      conn
    else
      case bearer_token(conn) do
        {:ok, provided_token} ->
          if secure_equal?(provided_token, expected_token) do
            conn
          else
            unauthorized(conn)
          end

        _ ->
          unauthorized(conn)
      end
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_, _), do: false

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
