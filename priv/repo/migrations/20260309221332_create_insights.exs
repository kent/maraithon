defmodule Maraithon.Repo.Migrations.CreateInsights do
  use Ecto.Migration

  def change do
    create table(:insights, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :category, :string, null: false
      add :title, :string, null: false
      add :summary, :string, null: false
      add :recommended_action, :string, null: false
      add :priority, :integer, null: false, default: 50
      add :confidence, :float, null: false, default: 0.5
      add :status, :string, null: false, default: "new"
      add :snoozed_until, :utc_datetime_usec
      add :due_at, :utc_datetime_usec
      add :source_id, :string
      add :source_occurred_at, :utc_datetime_usec
      add :dedupe_key, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:insights, [:user_id, :status])
    create index(:insights, [:agent_id])
    create index(:insights, [:due_at])
    create unique_index(:insights, [:user_id, :dedupe_key])
  end
end
