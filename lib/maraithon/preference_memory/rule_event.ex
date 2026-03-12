defmodule Maraithon.PreferenceMemory.RuleEvent do
  @moduledoc """
  Append-only audit events for preference rule creation, confirmation, rejection, and usage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.PreferenceMemory.Rule
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types ~w(proposed auto_saved confirmed rejected updated applied reverted superseded)

  schema "insight_preference_rule_events" do
    field :user_id, :string
    field :event_type, :string
    field :payload, :map, default: %{}

    belongs_to :rule, Rule
    belongs_to :conversation, Conversation
    belongs_to :source_turn, Turn
    belongs_to :source_delivery, Delivery

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :event_type]
  @optional_fields [:rule_id, :conversation_id, :source_turn_id, :source_delivery_id, :payload]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:rule_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:source_turn_id)
    |> foreign_key_constraint(:source_delivery_id)
  end
end
