defmodule Maraithon.PreferenceMemory.Rule do
  @moduledoc """
  Durable per-user preference rule inferred or explicitly provided by the operator.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active pending_confirmation rejected superseded)
  @sources ~w(telegram_explicit telegram_inferred feedback_inference web system explicit_telegram)
  @kinds ~w(content_filter urgency_boost quiet_hours routing_preference action_preference style_preference)

  schema "insight_preference_rules" do
    field :user_id, :string
    field :status, :string, default: "active"
    field :source, :string
    field :kind, :string
    field :label, :string
    field :instruction, :string
    field :applies_to, {:array, :string}, default: []
    field :filters, :map, default: %{}
    field :confidence, :float, default: 0.0
    field :evidence, :map, default: %{}
    field :confirmed_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :status, :source, :kind, :label, :instruction]
  @optional_fields [:applies_to, :filters, :confidence, :evidence, :confirmed_at, :last_used_at]

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_length(:label, min: 2, max: 180)
    |> validate_length(:instruction, min: 4, max: 1000)
    |> foreign_key_constraint(:user_id)
  end
end
