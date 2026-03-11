defmodule Maraithon.Repo.Migrations.CreateBriefs do
  use Ecto.Migration

  def change do
    create table(:briefs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :cadence, :string, null: false
      add :title, :string, null: false
      add :summary, :text, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :scheduled_for, :utc_datetime_usec, null: false
      add :dedupe_key, :string, null: false
      add :provider_message_id, :string
      add :sent_at, :utc_datetime_usec
      add :error_message, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:briefs, [:user_id, :dedupe_key], name: :briefs_user_id_dedupe_key_index)
    create index(:briefs, [:status, :scheduled_for])
    create index(:briefs, [:user_id, :scheduled_for])
    create index(:briefs, [:agent_id, :inserted_at])
  end
end
