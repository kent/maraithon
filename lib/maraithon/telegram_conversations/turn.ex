defmodule Maraithon.TelegramConversations.Turn do
  @moduledoc """
  One inbound or outbound Telegram turn attached to a conversation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.TelegramConversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(user assistant system)

  schema "telegram_conversation_turns" do
    field :role, :string
    field :telegram_message_id, :string
    field :reply_to_message_id, :string
    field :text, :string
    field :intent, :string
    field :confidence, :float
    field :structured_data, :map, default: %{}

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:conversation_id, :role, :text]
  @optional_fields [
    :telegram_message_id,
    :reply_to_message_id,
    :intent,
    :confidence,
    :structured_data
  ]

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @roles)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :telegram_message_id])
  end
end
