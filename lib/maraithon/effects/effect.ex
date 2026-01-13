defmodule Maraithon.Effects.Effect do
  @moduledoc """
  Schema for effect outbox records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "effects" do
    field :agent_id, :binary_id
    field :idempotency_key, :binary_id
    field :effect_type, :string
    field :params, :map, default: %{}
    field :status, :string, default: "pending"
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :retry_after, :utc_datetime_usec
    field :result, :map
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :agent_id, :idempotency_key, :effect_type]
  @optional_fields [
    :params,
    :status,
    :claimed_by,
    :claimed_at,
    :attempts,
    :max_attempts,
    :retry_after,
    :result,
    :error
  ]

  def changeset(effect, attrs) do
    effect
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["pending", "claimed", "completed", "failed", "cancelled"])
    |> unique_constraint(:idempotency_key)
  end
end
