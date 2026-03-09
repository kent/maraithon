defmodule Maraithon.Repo.Migrations.AddInsightTelegramNotificationsAndThresholds do
  use Ecto.Migration

  def change do
    create table(:insight_threshold_profiles) do
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :score_threshold, :float, null: false, default: 0.78
      add :helpful_count, :integer, null: false, default: 0
      add :not_helpful_count, :integer, null: false, default: 0
      add :last_feedback_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:insight_threshold_profiles, [:user_id])

    create table(:insight_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :insight_id, references(:insights, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :channel, :string, null: false
      add :destination, :string, null: false
      add :score, :float, null: false
      add :threshold, :float, null: false
      add :status, :string, null: false, default: "pending"
      add :provider_message_id, :string
      add :sent_at, :utc_datetime_usec
      add :feedback, :string
      add :feedback_at, :utc_datetime_usec
      add :error_message, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:insight_deliveries, [:insight_id, :channel, :destination])
    create index(:insight_deliveries, [:channel, :status, :inserted_at])
    create index(:insight_deliveries, [:user_id, :status])
  end
end
