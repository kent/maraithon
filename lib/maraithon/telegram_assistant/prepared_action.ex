defmodule Maraithon.TelegramAssistant.PreparedAction do
  @moduledoc """
  Durable Telegram action awaiting confirmation or recording execution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(awaiting_confirmation confirmed executed rejected expired failed)

  schema "telegram_prepared_actions" do
    field :chat_id, :string
    field :action_type, :string
    field :target_type, :string
    field :target_id, :string
    field :payload, :map, default: %{}
    field :preview_text, :string
    field :status, :string, default: "awaiting_confirmation"
    field :expires_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :executed_at, :utc_datetime_usec
    field :error, :string

    belongs_to :user, User, type: :string
    belongs_to :conversation, Conversation
    belongs_to :run, Run

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :chat_id,
    :run_id,
    :action_type,
    :target_type,
    :payload,
    :preview_text,
    :status,
    :expires_at
  ]
  @optional_fields [:conversation_id, :target_id, :confirmed_at, :executed_at, :error]

  def changeset(prepared_action, attrs) do
    prepared_action
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> validate_length(:action_type, min: 2, max: 100)
    |> validate_length(:target_type, min: 2, max: 100)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:run_id)
  end
end
