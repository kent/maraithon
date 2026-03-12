defmodule Maraithon.Repo.Migrations.CreateTelegramConversationalMemory do
  use Ecto.Migration

  def change do
    create table(:telegram_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :chat_id, :string, null: false
      add :root_message_id, :string

      add :linked_delivery_id,
          references(:insight_deliveries, type: :binary_id, on_delete: :nilify_all)

      add :linked_insight_id, references(:insights, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false, default: "open"
      add :summary, :text
      add :last_intent, :string
      add :last_turn_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:telegram_conversations, [:user_id, :status])
    create index(:telegram_conversations, [:chat_id, :status])
    create index(:telegram_conversations, [:linked_delivery_id])
    create index(:telegram_conversations, [:linked_insight_id])
    create unique_index(:telegram_conversations, [:chat_id, :root_message_id])

    create table(:telegram_conversation_turns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:telegram_conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false
      add :telegram_message_id, :string
      add :reply_to_message_id, :string
      add :text, :text, null: false
      add :intent, :string
      add :confidence, :float
      add :structured_data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:telegram_conversation_turns, [:conversation_id, :inserted_at])
    create unique_index(:telegram_conversation_turns, [:conversation_id, :telegram_message_id])

    create table(:insight_preference_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "active"
      add :source, :string, null: false
      add :kind, :string, null: false
      add :label, :string, null: false
      add :instruction, :text, null: false
      add :applies_to, {:array, :string}, null: false, default: []
      add :filters, :map, null: false, default: %{}
      add :confidence, :float, null: false, default: 0.0
      add :evidence, :map, null: false, default: %{}
      add :confirmed_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:insight_preference_rules, [:user_id, :status])
    create index(:insight_preference_rules, [:user_id, :kind])

    create unique_index(:insight_preference_rules, [:user_id, :label, :kind, :status],
             name: :insight_preference_rules_user_identity_index
           )

    create table(:insight_preference_rule_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :rule_id,
          references(:insight_preference_rules, type: :binary_id, on_delete: :nilify_all)

      add :conversation_id,
          references(:telegram_conversations, type: :binary_id, on_delete: :nilify_all)

      add :source_turn_id,
          references(:telegram_conversation_turns, type: :binary_id, on_delete: :nilify_all)

      add :source_delivery_id,
          references(:insight_deliveries, type: :binary_id, on_delete: :nilify_all)

      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:insight_preference_rule_events, [:user_id, :inserted_at])
    create index(:insight_preference_rule_events, [:rule_id, :inserted_at])
    create index(:insight_preference_rule_events, [:conversation_id])
    create index(:insight_preference_rule_events, [:source_turn_id])

    create table(:operator_memory_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :summary_type, :string, null: false
      add :content, :text, null: false
      add :source_window_start, :utc_datetime_usec
      add :source_window_end, :utc_datetime_usec
      add :confidence, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operator_memory_summaries, [:user_id, :summary_type])
  end
end
