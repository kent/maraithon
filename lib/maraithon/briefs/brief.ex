defmodule Maraithon.Briefs.Brief do
  @moduledoc """
  Persisted chief-of-staff brief queued for Telegram delivery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @cadences ["morning", "end_of_day", "weekly_review", "travel_prep", "travel_update"]
  @statuses ["pending", "sent", "failed"]

  schema "briefs" do
    field :cadence, :string
    field :title, :string
    field :summary, :string
    field :body, :string
    field :status, :string, default: "pending"
    field :scheduled_for, :utc_datetime_usec
    field :dedupe_key, :string
    field :provider_message_id, :string
    field :sent_at, :utc_datetime_usec
    field :error_message, :string
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string
    belongs_to :agent, Agent, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :agent_id,
    :cadence,
    :title,
    :summary,
    :body,
    :status,
    :scheduled_for,
    :dedupe_key
  ]

  @optional_fields [
    :provider_message_id,
    :sent_at,
    :error_message,
    :metadata
  ]

  def changeset(brief, attrs) do
    brief
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:cadence, @cadences)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, min: 4, max: 180)
    |> validate_length(:summary, min: 8, max: 500)
    |> validate_length(:body, min: 12, max: 4000)
    |> validate_length(:dedupe_key, min: 4, max: 255)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:dedupe_key, name: :briefs_user_id_dedupe_key_index)
  end
end
