defmodule Maraithon.Travel.ItineraryItem do
  @moduledoc """
  One normalized flight or hotel item attached to a travel itinerary.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Travel.Itinerary

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @item_types ~w(flight hotel)
  @statuses ~w(active updated cancelled superseded)

  schema "travel_itinerary_items" do
    field :item_type, :string
    field :status, :string, default: "active"
    field :source_provider, :string
    field :source_message_id, :string
    field :source_thread_id, :string
    field :fingerprint, :string
    field :vendor_name, :string
    field :title, :string
    field :confirmation_code, :string
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :location_label, :string
    field :confidence, :float, default: 0.0
    field :metadata, :map, default: %{}

    belongs_to :itinerary, Itinerary, foreign_key: :travel_itinerary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :travel_itinerary_id,
    :item_type,
    :status,
    :source_provider,
    :fingerprint
  ]

  @optional_fields [
    :source_message_id,
    :source_thread_id,
    :vendor_name,
    :title,
    :confirmation_code,
    :starts_at,
    :ends_at,
    :location_label,
    :confidence,
    :metadata
  ]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:item_type, @item_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:fingerprint, min: 6, max: 255)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:travel_itinerary_id)
    |> unique_constraint(:fingerprint,
      name: :travel_itinerary_items_itinerary_fingerprint_index
    )
  end
end
