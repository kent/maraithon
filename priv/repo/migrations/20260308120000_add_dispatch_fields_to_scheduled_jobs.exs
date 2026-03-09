defmodule Maraithon.Repo.Migrations.AddDispatchFieldsToScheduledJobs do
  use Ecto.Migration

  def change do
    alter table(:scheduled_jobs) do
      add :claimed_by, :string
      add :claimed_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :dispatched_at, :utc_datetime_usec
    end

    create index(:scheduled_jobs, [:status, :claimed_at], where: "status = 'dispatched'")
  end
end
