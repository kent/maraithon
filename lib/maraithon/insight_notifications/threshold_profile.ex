defmodule Maraithon.InsightNotifications.ThresholdProfile do
  @moduledoc """
  Per-user threshold model for deciding whether an insight should be pushed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  schema "insight_threshold_profiles" do
    field :score_threshold, :float, default: 0.78
    field :helpful_count, :integer, default: 0
    field :not_helpful_count, :integer, default: 0
    field :last_feedback_at, :utc_datetime_usec

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :score_threshold]
  @optional_fields [:helpful_count, :not_helpful_count, :last_feedback_at]

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:score_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:helpful_count, greater_than_or_equal_to: 0)
    |> validate_number(:not_helpful_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end
end
