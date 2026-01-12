defmodule Maraithon.Repo.Migrations.CreateSnapshots do
  use Ecto.Migration

  def change do
    create table(:snapshots) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :sequence_num, :bigint, null: false
      add :state_name, :string, null: false
      add :state_data, :map, null: false
      add :budget, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:snapshots, [:agent_id, :sequence_num])
    # Descending index for efficient "get latest snapshot" queries
    execute "CREATE INDEX snapshots_agent_id_sequence_num_desc ON snapshots (agent_id, sequence_num DESC)",
            "DROP INDEX snapshots_agent_id_sequence_num_desc"
  end
end
