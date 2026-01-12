defmodule Maraithon.Events.Event do
  @moduledoc """
  Schema for event records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "events" do
    field :agent_id, :binary_id
    field :sequence_num, :integer
    field :event_type, :string
    field :payload, :map, default: %{}
    field :idempotency_key, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:agent_id, :sequence_num, :event_type]
  @optional_fields [:payload, :idempotency_key]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
