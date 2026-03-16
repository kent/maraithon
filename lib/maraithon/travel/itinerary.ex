defmodule Maraithon.Travel.Itinerary do
  @moduledoc """
  Persisted travel itinerary assembled from Gmail and Calendar evidence.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Agents.Agent
  alias Maraithon.Travel.ItineraryItem

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(collecting ready brief_sent changed_after_send cancelled)

  schema "travel_itineraries" do
    field :status, :string, default: "collecting"
    field :title, :string
    field :destination_label, :string
    field :planning_timezone, :string
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :confidence, :float, default: 0.0
    field :briefed_for_local_date, :date
    field :last_evidence_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string
    belongs_to :agent, Agent, type: :binary_id
    has_many :items, ItineraryItem, foreign_key: :travel_itinerary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :agent_id, :status, :planning_timezone]
  @optional_fields [
    :title,
    :destination_label,
    :starts_at,
    :ends_at,
    :confidence,
    :briefed_for_local_date,
    :last_evidence_at,
    :metadata
  ]

  def changeset(itinerary, attrs) do
    itinerary
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
  end
end
