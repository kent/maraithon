defmodule MaraithonWeb.LiveUserAuth do
  @moduledoc """
  LiveView authentication hooks backed by persisted user sessions.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Maraithon.Accounts

  @session_key "user_session_token"

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case Map.get(session, @session_key) do
      token when is_binary(token) and token != "" ->
        case Accounts.get_user_by_session_token(token) do
          nil ->
            {:halt, socket |> put_flash(:error, "Sign in to continue.") |> redirect(to: "/")}

          user ->
            {:cont, assign(socket, :current_user, user)}
        end

      _ ->
        {:halt, socket |> put_flash(:error, "Sign in to continue.") |> redirect(to: "/")}
    end
  end
end
