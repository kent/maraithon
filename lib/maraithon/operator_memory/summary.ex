defmodule Maraithon.OperatorMemory.Summary do
  @moduledoc """
  Compact long-term memory summaries derived from Telegram interactions and active rules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @summary_types ~w(telegram_behavior content_preferences action_style interrupt_policy)

  schema "operator_memory_summaries" do
    field :user_id, :string
    field :summary_type, :string
    field :content, :string
    field :source_window_start, :utc_datetime_usec
    field :source_window_end, :utc_datetime_usec
    field :confidence, :float, default: 0.0

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :summary_type, :content]
  @optional_fields [:source_window_start, :source_window_end, :confidence]

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:summary_type, @summary_types)
    |> validate_length(:content, min: 4, max: 5000)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :summary_type])
  end
end
