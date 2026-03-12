defmodule Maraithon.TelegramConversations.Conversation do
  @moduledoc """
  Durable Telegram conversation root for replies, follow-ups, and general DM chat.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Insight
  alias Maraithon.TelegramConversations.Turn

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open awaiting_confirmation closed)

  schema "telegram_conversations" do
    field :user_id, :string
    field :chat_id, :string
    field :root_message_id, :string
    field :status, :string, default: "open"
    field :summary, :string
    field :last_intent, :string
    field :last_turn_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :linked_delivery, Delivery
    belongs_to :linked_insight, Insight
    has_many :turns, Turn

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :chat_id, :status]
  @optional_fields [
    :root_message_id,
    :linked_delivery_id,
    :linked_insight_id,
    :summary,
    :last_intent,
    :last_turn_at,
    :metadata
  ]

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:linked_delivery_id)
    |> foreign_key_constraint(:linked_insight_id)
    |> unique_constraint([:chat_id, :root_message_id])
  end
end
