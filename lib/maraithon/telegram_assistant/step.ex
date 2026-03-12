defmodule Maraithon.TelegramAssistant.Step do
  @moduledoc """
  Persisted step within a Telegram assistant run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.TelegramAssistant.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @step_types ~w(llm_request llm_response context_fetch tool_call agent_query prepared_action telegram_send telegram_edit push_decision)
  @statuses ~w(running completed failed skipped)

  schema "telegram_assistant_steps" do
    field :sequence, :integer
    field :step_type, :string
    field :status, :string
    field :request_payload, :map, default: %{}
    field :response_payload, :map, default: %{}
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :run, Run

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:run_id, :sequence, :step_type, :status, :request_payload, :started_at]
  @optional_fields [:response_payload, :error, :finished_at]

  def changeset(step, attrs) do
    step
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:step_type, @step_types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :sequence])
  end
end
