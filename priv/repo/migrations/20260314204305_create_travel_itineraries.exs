defmodule Maraithon.Repo.Migrations.CreateTravelItineraries do
  use Ecto.Migration

  def change do
    create table(:travel_itineraries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "collecting"
      add :title, :string
      add :destination_label, :string
      add :planning_timezone, :string, null: false
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :confidence, :float, null: false, default: 0.0
      add :briefed_for_local_date, :date
      add :last_evidence_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:travel_itineraries, [:user_id, :starts_at])
    create index(:travel_itineraries, [:user_id, :status])
    create index(:travel_itineraries, [:agent_id, :inserted_at])
    create index(:travel_itineraries, [:user_id, :briefed_for_local_date, :status])

    create table(:travel_itinerary_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :travel_itinerary_id,
          references(:travel_itineraries, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_type, :string, null: false
      add :status, :string, null: false, default: "active"
      add :source_provider, :string, null: false
      add :source_message_id, :string
      add :source_thread_id, :string
      add :fingerprint, :string, null: false
      add :vendor_name, :string
      add :title, :string
      add :confirmation_code, :string
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :location_label, :string
      add :confidence, :float, null: false, default: 0.0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:travel_itinerary_items, [:travel_itinerary_id, :item_type])
    create index(:travel_itinerary_items, [:travel_itinerary_id, :status])
    create index(:travel_itinerary_items, [:source_message_id])

    create unique_index(
             :travel_itinerary_items,
             [:travel_itinerary_id, :fingerprint],
             name: :travel_itinerary_items_itinerary_fingerprint_index
           )
  end
end
