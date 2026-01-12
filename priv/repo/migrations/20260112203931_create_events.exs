defmodule Maraithon.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :sequence_num, :bigint, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :idempotency_key, :binary_id

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:events, [:agent_id, :sequence_num])
    create index(:events, [:agent_id, :inserted_at])
    create index(:events, [:idempotency_key], where: "idempotency_key IS NOT NULL")
  end
end
