defmodule Maraithon.TelegramAssistant.PushReceipt do
  @moduledoc """
  Records proactive Telegram push decisions for dedupe and auditing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.TelegramConversations.Turn

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @origin_types ~w(insight brief agent_push assistant_digest)
  @decisions ~w(sent_now queued_digest suppressed merged)

  schema "telegram_push_receipts" do
    field :dedupe_key, :string
    field :origin_type, :string
    field :origin_id, :string
    field :decision, :string

    belongs_to :user, User, type: :string
    belongs_to :conversation_turn, Turn

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:user_id, :dedupe_key, :origin_type, :decision]
  @optional_fields [:origin_id, :conversation_turn_id]

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:dedupe_key, min: 3, max: 255)
    |> validate_inclusion(:origin_type, @origin_types)
    |> validate_inclusion(:decision, @decisions)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_turn_id)
    |> unique_constraint([:user_id, :dedupe_key])
  end
end
