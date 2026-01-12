defmodule Maraithon.Repo.Migrations.CreateScheduledJobs do
  use Ecto.Migration

  def change do
    create table(:scheduled_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :job_type, :string, null: false
      add :fire_at, :utc_datetime_usec, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:scheduled_jobs, [:fire_at, :status], where: "status = 'pending'")
    create index(:scheduled_jobs, [:agent_id, :status])
  end
end
