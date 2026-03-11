defmodule Maraithon.Repo.Migrations.CreateInsightPreferenceProfiles do
  use Ecto.Migration

  def change do
    create table(:insight_preference_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :rules, :map, null: false, default: %{}
      add :last_explicit_at, :utc_datetime_usec
      add :last_inferred_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:insight_preference_profiles, [:user_id])
  end
end
