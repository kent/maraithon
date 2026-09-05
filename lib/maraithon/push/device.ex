defmodule Maraithon.Push.Device do
  @moduledoc """
  A mobile device registered for push notifications.

  One row per APNs device token. A token has exactly one owner: registering
  a token that already exists moves it to the registering user (phones
  change hands between accounts, not the other way around).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @platforms ["ios"]
  @statuses ["active", "disabled"]

  schema "mobile_push_devices" do
    field :device_token, :string
    field :platform, :string, default: "ios"
    field :app_version, :string
    field :environment, :string
    field :status, :string, default: "active"
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_token]
  @optional_fields [:platform, :app_version, :environment, :status, :last_seen_at]

  def changeset(device, attrs) do
    device
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> update_change(:device_token, &String.trim/1)
    |> validate_length(:device_token, min: 16, max: 512)
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:environment, ["sandbox", "production"])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:device_token)
  end
end
