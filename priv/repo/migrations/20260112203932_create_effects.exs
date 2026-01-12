defmodule Maraithon.Repo.Migrations.CreateEffects do
  use Ecto.Migration

  def change do
    create table(:effects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :idempotency_key, :binary_id, null: false
      add :effect_type, :string, null: false
      add :params, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :claimed_by, :string
      add :claimed_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :retry_after, :utc_datetime_usec
      add :result, :map
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:effects, [:idempotency_key])
    create index(:effects, [:status, :inserted_at], where: "status = 'pending'")
    create index(:effects, [:agent_id, :inserted_at])
  end
end
