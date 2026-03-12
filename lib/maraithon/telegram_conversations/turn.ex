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
  @turn_kinds ~w(user_message assistant_reply assistant_push approval_prompt action_result system_notice)
  @origin_types ~w(chat insight brief agent_push prepared_action system)

  schema "telegram_conversation_turns" do
    field :role, :string
    field :telegram_message_id, :string
    field :reply_to_message_id, :string
    field :text, :string
    field :intent, :string
    field :confidence, :float
    field :turn_kind, :string, default: "user_message"
    field :origin_type, :string
    field :origin_id, :string
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
    :turn_kind,
    :origin_type,
    :origin_id,
    :structured_data
  ]

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> put_default_turn_kind()
    |> put_default_origin_type()
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:turn_kind, @turn_kinds)
    |> validate_inclusion(:origin_type, @origin_types)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :telegram_message_id])
  end

  defp put_default_turn_kind(changeset) do
    case get_field(changeset, :turn_kind) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        put_change(changeset, :turn_kind, default_turn_kind(get_field(changeset, :role)))
    end
  end

  defp put_default_origin_type(changeset) do
    case get_field(changeset, :origin_type) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        put_change(changeset, :origin_type, default_origin_type(get_field(changeset, :role)))
    end
  end

  defp default_turn_kind("assistant"), do: "assistant_reply"
  defp default_turn_kind("system"), do: "system_notice"
  defp default_turn_kind(_role), do: "user_message"

  defp default_origin_type("assistant"), do: "chat"
  defp default_origin_type("system"), do: "system"
  defp default_origin_type(_role), do: "chat"
end
