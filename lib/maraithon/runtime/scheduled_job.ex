defmodule Maraithon.Runtime.ScheduledJob do
  @moduledoc """
  Schema for scheduled job records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scheduled_jobs" do
    field :agent_id, :binary_id
    field :job_type, :string
    field :fire_at, :utc_datetime_usec
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:agent_id, :job_type, :fire_at]
  @optional_fields [:payload, :status, :delivered_at]

  def changeset(job, attrs) do
    job
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["pending", "delivered", "cancelled"])
  end
end
