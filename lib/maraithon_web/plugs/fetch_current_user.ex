defmodule MaraithonWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the current user from the persisted session token.
  """

  import Plug.Conn

  alias Maraithon.Accounts

  @session_key "user_session_token"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      token when is_binary(token) and token != "" ->
        case Accounts.get_user_by_session_token(token) do
          nil ->
            conn
            |> delete_session(@session_key)
            |> assign(:current_user, nil)

          user ->
            assign(conn, :current_user, user)
        end

      _ ->
        assign(conn, :current_user, nil)
    end
  end
end
