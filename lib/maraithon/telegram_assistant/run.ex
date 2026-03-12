defmodule Maraithon.TelegramAssistant.Run do
  @moduledoc """
  Persisted Telegram assistant orchestration run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.TelegramAssistant.Step
  alias Maraithon.TelegramConversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @trigger_types ~w(inbound_message reply agent_push brief insight_push follow_up scheduled_digest)
  @statuses ~w(running waiting_confirmation completed failed cancelled degraded)

  schema "telegram_assistant_runs" do
    field :chat_id, :string
    field :trigger_type, :string
    field :status, :string, default: "running"
    field :model_provider, :string
    field :model_name, :string
    field :prompt_snapshot, :map, default: %{}
    field :result_summary, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string

    belongs_to :user, User, type: :string
    belongs_to :conversation, Conversation
    has_many :steps, Step, foreign_key: :run_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :chat_id,
    :trigger_type,
    :status,
    :model_provider,
    :model_name,
    :prompt_snapshot,
    :started_at
  ]
  @optional_fields [:conversation_id, :result_summary, :finished_at, :error]

  def changeset(run, attrs) do
    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> validate_inclusion(:trigger_type, @trigger_types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
  end
end
