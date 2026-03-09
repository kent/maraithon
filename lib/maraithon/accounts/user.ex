defmodule Maraithon.Accounts.User do
  @moduledoc """
  Application user identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "users" do
    field :email, :string
    field :is_admin, :boolean, default: false
    field :confirmed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :email]
  @optional_fields [:is_admin, :confirmed_at]

  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 320)
    |> validate_length(:id, max: 320)
    |> unique_constraint(:email)
  end
end
