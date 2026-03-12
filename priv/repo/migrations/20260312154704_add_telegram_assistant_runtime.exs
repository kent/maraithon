defmodule Maraithon.Repo.Migrations.AddTelegramAssistantRuntime do
  use Ecto.Migration

  def up do
    alter table(:telegram_conversation_turns) do
      add :turn_kind, :string, null: false, default: "user_message"
      add :origin_type, :string
      add :origin_id, :string
    end

    execute("""
    UPDATE telegram_conversation_turns
    SET
      turn_kind = CASE role
        WHEN 'assistant' THEN 'assistant_reply'
        WHEN 'system' THEN 'system_notice'
        ELSE 'user_message'
      END,
      origin_type = CASE role
        WHEN 'assistant' THEN 'chat'
        WHEN 'system' THEN 'system'
        ELSE 'chat'
      END
    """)

    create index(:telegram_conversation_turns, [:turn_kind])
    create index(:telegram_conversation_turns, [:origin_type, :origin_id])

    create table(:telegram_assistant_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :chat_id, :string, null: false

      add :conversation_id,
          references(:telegram_conversations, type: :binary_id, on_delete: :nilify_all)

      add :trigger_type, :string, null: false
      add :status, :string, null: false, default: "running"
      add :model_provider, :string, null: false
      add :model_name, :string, null: false
      add :prompt_snapshot, :map, null: false, default: %{}
      add :result_summary, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:telegram_assistant_runs, [:user_id, :started_at])
    create index(:telegram_assistant_runs, [:chat_id, :started_at])
    create index(:telegram_assistant_runs, [:conversation_id, :started_at])
    create index(:telegram_assistant_runs, [:status, :started_at])

    create table(:telegram_assistant_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id,
          references(:telegram_assistant_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sequence, :integer, null: false
      add :step_type, :string, null: false
      add :status, :string, null: false
      add :request_payload, :map, null: false, default: %{}
      add :response_payload, :map, null: false, default: %{}
      add :error, :text
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:telegram_assistant_steps, [:run_id, :sequence])
    create index(:telegram_assistant_steps, [:run_id, :step_type])
    create index(:telegram_assistant_steps, [:status])

    create table(:telegram_prepared_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :chat_id, :string, null: false

      add :conversation_id,
          references(:telegram_conversations, type: :binary_id, on_delete: :nilify_all)

      add :run_id,
          references(:telegram_assistant_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :action_type, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :string
      add :payload, :map, null: false, default: %{}
      add :preview_text, :text, null: false
      add :status, :string, null: false, default: "awaiting_confirmation"
      add :expires_at, :utc_datetime_usec, null: false
      add :confirmed_at, :utc_datetime_usec
      add :executed_at, :utc_datetime_usec
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:telegram_prepared_actions, [:user_id, :status])
    create index(:telegram_prepared_actions, [:chat_id, :status])
    create index(:telegram_prepared_actions, [:conversation_id])
    create index(:telegram_prepared_actions, [:run_id])

    create table(:telegram_push_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :dedupe_key, :string, null: false
      add :origin_type, :string, null: false
      add :origin_id, :string
      add :decision, :string, null: false

      add :conversation_turn_id,
          references(:telegram_conversation_turns, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:telegram_push_receipts, [:user_id, :dedupe_key])
    create index(:telegram_push_receipts, [:user_id, :origin_type])
    create index(:telegram_push_receipts, [:conversation_turn_id])
  end

  def down do
    drop index(:telegram_push_receipts, [:conversation_turn_id])
    drop index(:telegram_push_receipts, [:user_id, :origin_type])
    drop unique_index(:telegram_push_receipts, [:user_id, :dedupe_key])
    drop table(:telegram_push_receipts)

    drop index(:telegram_prepared_actions, [:run_id])
    drop index(:telegram_prepared_actions, [:conversation_id])
    drop index(:telegram_prepared_actions, [:chat_id, :status])
    drop index(:telegram_prepared_actions, [:user_id, :status])
    drop table(:telegram_prepared_actions)

    drop index(:telegram_assistant_steps, [:status])
    drop index(:telegram_assistant_steps, [:run_id, :step_type])
    drop unique_index(:telegram_assistant_steps, [:run_id, :sequence])
    drop table(:telegram_assistant_steps)

    drop index(:telegram_assistant_runs, [:status, :started_at])
    drop index(:telegram_assistant_runs, [:conversation_id, :started_at])
    drop index(:telegram_assistant_runs, [:chat_id, :started_at])
    drop index(:telegram_assistant_runs, [:user_id, :started_at])
    drop table(:telegram_assistant_runs)

    drop index(:telegram_conversation_turns, [:origin_type, :origin_id])
    drop index(:telegram_conversation_turns, [:turn_kind])

    alter table(:telegram_conversation_turns) do
      remove :origin_id
      remove :origin_type
      remove :turn_kind
    end
  end
end
