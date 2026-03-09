defmodule Maraithon.Agents.Agent do
  @moduledoc """
  Schema for agent records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :user_id, :string
    field :behavior, :string
    field :config, :map, default: %{}
    field :status, :string, default: "stopped"
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:behavior]
  @optional_fields [:user_id, :config, :status, :started_at, :stopped_at]

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["stopped", "running", "degraded", "terminated"])
    |> validate_behavior()
  end

  defp validate_behavior(changeset) do
    validate_change(changeset, :behavior, fn :behavior, behavior ->
      if Maraithon.Behaviors.exists?(behavior) do
        []
      else
        [behavior: "unknown behavior: #{behavior}"]
      end
    end)
  end
end
