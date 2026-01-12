defmodule Maraithon.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :behavior, :string, null: false
      add :config, :map, null: false, default: %{}
      add :status, :string, null: false, default: "stopped"
      add :started_at, :utc_datetime_usec
      add :stopped_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agents, [:status])
  end
end
