defmodule MaraithonWeb.SessionController do
  use MaraithonWeb, :controller

  alias Maraithon.Accounts
  alias Maraithon.Accounts.MagicLinkSender

  @session_key "user_session_token"

  def create_magic_link(conn, params) do
    email = extract_email(params)
    request_opts = request_metadata(conn)

    case Accounts.request_magic_link(email, request_opts) do
      {:ok, %{user: user, token: token}} ->
        link = url(~p"/auth/magic/#{token}")
        _ = MagicLinkSender.deliver(user.email, link)

        conn
        |> put_flash(:info, "Check your email for a sign-in link.")
        |> redirect(to: "/")

      {:error, :invalid_email} ->
        conn
        |> put_flash(:error, "Please enter a valid email address.")
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to send sign-in link right now.")
        |> redirect(to: "/")
    end
  end

  def consume_magic_link(conn, %{"token" => token}) do
    case Accounts.consume_magic_link(token, request_metadata(conn)) do
      {:ok, %{user: user, token: session_token}} ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, session_token)
        |> put_flash(:info, "Signed in as #{user.email}")
        |> redirect(to: post_sign_in_path(user.id))

      {:error, :invalid_or_expired_link} ->
        conn
        |> put_flash(:error, "Sign-in link is invalid or expired.")
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to sign in right now.")
        |> redirect(to: "/")
    end
  end

  def delete(conn, _params) do
    token = get_session(conn, @session_key)
    _ = maybe_revoke_session(token)

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: "/")
  end

  defp extract_email(%{"magic_link" => %{"email" => email}}), do: email
  defp extract_email(%{"email" => email}), do: email
  defp extract_email(_params), do: ""

  defp maybe_revoke_session(token) when is_binary(token) and token != "" do
    Accounts.revoke_session(token)
  end

  defp maybe_revoke_session(_token), do: :ok

  defp request_metadata(conn) do
    [
      ip: ip_to_string(conn.remote_ip),
      user_agent: List.first(get_req_header(conn, "user-agent"))
    ]
  end

  defp ip_to_string(nil), do: nil
  defp ip_to_string(ip), do: to_string(:inet.ntoa(ip))

  defp post_sign_in_path(user_id) do
    if Accounts.connected_accounts?(user_id), do: "/dashboard", else: "/connectors"
  end
end
