defmodule Maraithon.InsightNotifications.Delivery do
  @moduledoc """
  Delivery record for pushing a specific insight over a channel.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Insights.Insight
  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ["pending", "sent", "failed", "feedback_helpful", "feedback_not_helpful"]
  @feedback ["helpful", "not_helpful"]

  schema "insight_deliveries" do
    field :channel, :string
    field :destination, :string
    field :score, :float
    field :threshold, :float
    field :status, :string, default: "pending"
    field :provider_message_id, :string
    field :sent_at, :utc_datetime_usec
    field :feedback, :string
    field :feedback_at, :utc_datetime_usec
    field :error_message, :string
    field :metadata, :map, default: %{}

    belongs_to :insight, Insight
    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:insight_id, :user_id, :channel, :destination, :score, :threshold, :status]
  @optional_fields [
    :provider_message_id,
    :sent_at,
    :feedback,
    :feedback_at,
    :error_message,
    :metadata
  ]

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:channel, min: 2, max: 64)
    |> validate_length(:destination, min: 1, max: 255)
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:threshold, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:feedback, @feedback)
    |> foreign_key_constraint(:insight_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:insight_id, :channel, :destination])
  end
end
