defmodule Maraithon.Accounts.MagicLink do
  @moduledoc """
  Single-use magic sign-in link record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "user_magic_links" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :sent_to_email, :string
    field :ip, :string
    field :user_agent, :string

    belongs_to :user, Maraithon.Accounts.User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :token_hash, :expires_at, :sent_to_email]
  @optional_fields [:used_at, :ip, :user_agent]

  def changeset(magic_link, attrs) do
    magic_link
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:token_hash)
  end
end
