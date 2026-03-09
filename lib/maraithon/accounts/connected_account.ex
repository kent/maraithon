defmodule Maraithon.Accounts.ConnectedAccount do
  @moduledoc """
  Provider-agnostic connected account and token record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "connected_accounts" do
    field :provider, :string
    field :external_account_id, :string
    field :status, :string, default: "disconnected"
    field :access_token, Maraithon.Encrypted.Binary
    field :refresh_token, Maraithon.Encrypted.Binary
    field :expires_at, :utc_datetime_usec
    field :scopes, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :connected_at, :utc_datetime_usec
    field :last_refreshed_at, :utc_datetime_usec

    belongs_to :user, Maraithon.Accounts.User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :provider]

  @optional_fields [
    :external_account_id,
    :status,
    :access_token,
    :refresh_token,
    :expires_at,
    :scopes,
    :metadata,
    :connected_at,
    :last_refreshed_at
  ]

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:provider, min: 1, max: 80)
    |> validate_inclusion(:status, ["connected", "disconnected", "error"])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :provider])
  end
end
