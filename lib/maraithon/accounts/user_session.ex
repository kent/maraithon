defmodule Maraithon.Accounts.UserSession do
  @moduledoc """
  Persistent user session backing record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "user_sessions" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ip, :string
    field :user_agent, :string
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, Maraithon.Accounts.User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :token_hash, :expires_at, :last_seen_at]
  @optional_fields [:ip, :user_agent, :revoked_at]

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:token_hash)
  end
end
