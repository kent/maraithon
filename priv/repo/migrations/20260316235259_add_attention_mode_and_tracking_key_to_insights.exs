defmodule Maraithon.Repo.Migrations.AddAttentionModeAndTrackingKeyToInsights do
  use Ecto.Migration

  def up do
    alter table(:insights) do
      add :attention_mode, :string, null: false, default: "act_now"
      add :tracking_key, :string
    end

    execute("UPDATE insights SET tracking_key = dedupe_key WHERE tracking_key IS NULL")

    execute("""
    UPDATE insights
    SET attention_mode = 'monitor'
    WHERE status IN ('new', 'snoozed')
      AND COALESCE(metadata #>> '{conversation_context,notification_posture}', '') = 'heads_up'
    """)

    alter table(:insights) do
      modify :tracking_key, :string, null: false
    end

    create index(:insights, [:user_id, :attention_mode, :status])
    create index(:insights, [:user_id, :tracking_key, :status])
  end

  def down do
    drop_if_exists index(:insights, [:user_id, :tracking_key, :status])
    drop_if_exists index(:insights, [:user_id, :attention_mode, :status])

    alter table(:insights) do
      remove :tracking_key
      remove :attention_mode
    end
  end
end
