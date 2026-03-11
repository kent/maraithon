defmodule Maraithon.PreferenceMemory.Profile do
  @moduledoc """
  Durable per-user preference memory for insight selection and delivery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "insight_preference_profiles" do
    field :rules, :map, default: %{}
    field :last_explicit_at, :utc_datetime_usec
    field :last_inferred_at, :utc_datetime_usec

    belongs_to :user, Maraithon.Accounts.User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id]
  @optional_fields [:rules, :last_explicit_at, :last_inferred_at]

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_change(:rules, fn :rules, value ->
      if is_map(value), do: [], else: [rules: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end
end
