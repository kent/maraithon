defmodule Maraithon.Accounts do
  @moduledoc """
  User identity and session management.
  """

  import Ecto.Query

  alias Maraithon.Accounts.{MagicLink, User, UserSession}
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo

  @magic_link_ttl_seconds 900
  @session_ttl_seconds 60 * 24 * 60 * 60

  def normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  def normalize_email(_), do: ""

  def get_user(id) when is_binary(id), do: Repo.get(User, id)
  def get_user(_), do: nil

  def get_user_by_email(email) when is_binary(email) do
    normalized = normalize_email(email)

    case normalized do
      "" -> nil
      value -> Repo.get_by(User, email: value)
    end
  end

  def get_or_create_user_by_email(email) when is_binary(email) do
    normalized = normalize_email(email)

    case normalized do
      "" ->
        {:error, :invalid_email}

      value ->
        case Repo.get(User, value) do
          nil ->
            %User{}
            |> User.changeset(%{
              id: value,
              email: value,
              is_admin: admin_email?(value)
            })
            |> Repo.insert()

          user ->
            maybe_promote_admin(user)
        end
    end
  end

  def ensure_primary_admin_user! do
    case primary_admin_email() do
      nil ->
        {:ok, :not_configured}

      primary ->
        case get_or_create_user_by_email(primary) do
          {:ok, user} -> {:ok, user}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, error}
  end

  def request_magic_link(email, opts \\ []) when is_binary(email) do
    with {:ok, user} <- get_or_create_user_by_email(email) do
      token = generate_token()
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, @magic_link_ttl_seconds, :second)

      attrs = %{
        user_id: user.id,
        token_hash: hash_token(token),
        expires_at: expires_at,
        sent_to_email: user.email,
        ip: Keyword.get(opts, :ip),
        user_agent: Keyword.get(opts, :user_agent)
      }

      case %MagicLink{} |> MagicLink.changeset(attrs) |> Repo.insert() do
        {:ok, _record} ->
          {:ok, %{user: user, token: token, expires_at: expires_at}}

        error ->
          error
      end
    end
  end

  def consume_magic_link(token, opts \\ []) when is_binary(token) do
    now = DateTime.utc_now()
    token_hash = hash_token(token)

    query =
      from(link in MagicLink,
        where: link.token_hash == ^token_hash,
        where: is_nil(link.used_at),
        where: link.expires_at > ^now,
        preload: [:user]
      )

    case Repo.one(query) do
      nil ->
        {:error, :invalid_or_expired_link}

      link ->
        Repo.transaction(fn ->
          case Repo.update(Ecto.Changeset.change(link, used_at: now)) do
            {:ok, _used_link} ->
              maybe_confirm_user(link.user)
              create_session_for_user(link.user, opts)

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, {:ok, session}} -> {:ok, session}
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def create_session_for_user(%User{} = user, opts \\ []) do
    token = generate_token()
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @session_ttl_seconds, :second)

    attrs = %{
      user_id: user.id,
      token_hash: hash_token(token),
      expires_at: expires_at,
      last_seen_at: now,
      ip: Keyword.get(opts, :ip),
      user_agent: Keyword.get(opts, :user_agent)
    }

    case %UserSession{} |> UserSession.changeset(attrs) |> Repo.insert() do
      {:ok, session} ->
        {:ok, %{user: user, token: token, session: session, expires_at: expires_at}}

      error ->
        error
    end
  end

  def get_user_by_session_token(token) when is_binary(token) do
    now = DateTime.utc_now()
    token_hash = hash_token(token)

    query =
      from(session in UserSession,
        join: user in User,
        on: user.id == session.user_id,
        where: session.token_hash == ^token_hash,
        where: is_nil(session.revoked_at),
        where: session.expires_at > ^now,
        select: user
      )

    Repo.one(query)
  end

  def get_active_session(token) when is_binary(token) do
    now = DateTime.utc_now()
    token_hash = hash_token(token)

    query =
      from(session in UserSession,
        where: session.token_hash == ^token_hash,
        where: is_nil(session.revoked_at),
        where: session.expires_at > ^now
      )

    Repo.one(query)
  end

  def revoke_session(token) when is_binary(token) do
    case get_active_session(token) do
      nil -> :ok
      session -> Repo.update(Ecto.Changeset.change(session, revoked_at: DateTime.utc_now()))
    end
  end

  def connected_accounts?(user_id) when is_binary(user_id) do
    if ConnectedAccounts.has_any?(user_id) do
      true
    else
      _ = ConnectedAccounts.sync_from_oauth_tokens(user_id)
      ConnectedAccounts.has_any?(user_id)
    end
  end

  def connected_accounts?(_), do: false

  def primary_admin_email do
    System.get_env("PRIMARY_ADMIN_EMAIL", "")
    |> normalize_email()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp maybe_promote_admin(%User{} = user) do
    if admin_email?(user.email) and not user.is_admin do
      user
      |> Ecto.Changeset.change(is_admin: true)
      |> Repo.update()
    else
      {:ok, user}
    end
  end

  defp maybe_confirm_user(%User{confirmed_at: nil} = user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp maybe_confirm_user(_user), do: :ok

  defp admin_email?(email) do
    case primary_admin_email() do
      nil -> false
      primary -> normalize_email(email) == primary
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token)
  end
end
