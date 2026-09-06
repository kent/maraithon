defmodule Maraithon.Todos.Todo do
  @moduledoc """
  Persisted user-scoped todo items that can be managed by conversational operators.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open done dismissed snoozed)
  @attention_modes ~w(act_now monitor)
  @kinds ~w(general gmail_triage)
  @directions ~w(owed_by_me owed_to_me fyi)
  @agent_actionabilities ~w(needs_you can_prepare can_execute)

  schema "todos" do
    field :user_id, :string
    field :source, :string
    field :source_account_id, :id
    field :source_account_label, :string
    field :kind, :string, default: "general"
    field :attention_mode, :string, default: "act_now"
    field :title, :string
    field :summary, :string
    field :next_action, :string
    field :due_at, :utc_datetime_usec
    field :notes, :string
    field :action_plan, :string
    field :action_draft, :map, default: %{}
    field :owner_user_id, :string
    field :owner_label, :string
    field :priority, :integer, default: 50
    field :status, :string, default: "open"
    field :snoozed_until, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :model_selected_at, :utc_datetime_usec
    field :first_user_opened_at, :utc_datetime_usec
    field :source_item_id, :string
    field :source_occurred_at, :utc_datetime_usec
    field :dedupe_key, :string
    field :metadata, :map, default: %{}
    field :agent_actionability, :string, default: "needs_you"
    field :agent_action_label, :string
    field :agent_action_requires_approval, :boolean, default: true

    belongs_to :project, Maraithon.Projects.Project

    # SPEC 05: two-sided waiting-on tracker. `direction` names who owes
    # whom (self-owned action items default to owed_by_me), and the
    # counterparty fields identify the other side of the loop.
    field :direction, :string, default: "owed_by_me"
    field :counterparty_person_id, :binary_id
    field :counterparty_label, :string

    # SPEC 05: nudge/follow-up state, set when a follow-up referencing this
    # todo is actually delivered (see Maraithon.Todos.record_nudge_sent/3).
    field :last_nudged_at, :utc_datetime
    field :nudge_count, :integer, default: 0
    field :next_nudge_at, :utc_datetime
    field :follow_up_channel, :string

    # SPEC 05: bulk-stamped by CrossSourceCompletion after each cycle so the
    # backstop candidate rotation advances (never-checked items sort first).
    # Purely DB-backed; never part of any agent snapshot.
    field :last_completion_checked_at, :utc_datetime
    field :last_staleness_triage_checked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :owner_user_id,
    :source,
    :kind,
    :title,
    :summary,
    :next_action,
    :dedupe_key
  ]

  @optional_fields [
    :attention_mode,
    :source_account_id,
    :source_account_label,
    :due_at,
    :notes,
    :action_plan,
    :action_draft,
    :owner_label,
    :priority,
    :status,
    :snoozed_until,
    :closed_at,
    :model_selected_at,
    :first_user_opened_at,
    :source_item_id,
    :source_occurred_at,
    :metadata,
    :project_id,
    :agent_actionability,
    :agent_action_label,
    :agent_action_requires_approval,
    :direction,
    :counterparty_person_id,
    :counterparty_label,
    :last_nudged_at,
    :nudge_count,
    :next_nudge_at,
    :follow_up_channel,
    :last_completion_checked_at
  ]

  @doc "The earliest instant after which new evidence may automatically close this todo."
  def completion_evidence_after(%__MODULE__{} = todo) do
    [todo.source_occurred_at || todo.inserted_at, reopened_at(todo)]
    |> Enum.filter(&is_struct(&1, DateTime))
    |> Enum.max(DateTime, fn -> nil end)
  end

  def reopened_at(%__MODULE__{metadata: metadata}) do
    with value when is_binary(value) <- Map.get(metadata || %{}, "completion_reopened_at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _ -> nil
    end
  end

  def changeset(todo, attrs) do
    todo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> default_owner_to_user()
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:attention_mode, @attention_modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:agent_actionability, @agent_actionabilities)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:nudge_count, greater_than_or_equal_to: 0)
    |> validate_length(:counterparty_label, max: 255)
    |> validate_length(:follow_up_channel, max: 50)
    |> validate_length(:agent_action_label, max: 255)
    |> validate_length(:source, min: 2, max: 100)
    |> validate_length(:title, min: 4, max: 240)
    |> validate_length(:summary, min: 4, max: 2_000)
    |> validate_length(:next_action, min: 4, max: 1_000)
    |> validate_length(:notes, max: 8_000)
    |> validate_length(:action_plan, max: 8_000)
    |> validate_length(:owner_user_id, max: 320)
    |> validate_length(:owner_label, max: 255)
    |> validate_length(:source_account_label, max: 255)
    |> validate_length(:dedupe_key, min: 4, max: 255)
    |> validate_change(:action_draft, fn :action_draft, value ->
      if is_map(value), do: [], else: [action_draft: "must be a map"]
    end)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:source_account_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:counterparty_person_id)
    |> unique_constraint(:dedupe_key, name: :todos_user_id_dedupe_key_index)
  end

  defp default_owner_to_user(changeset) do
    case get_field(changeset, :owner_user_id) do
      nil -> put_change(changeset, :owner_user_id, get_field(changeset, :user_id))
      "" -> put_change(changeset, :owner_user_id, get_field(changeset, :user_id))
      _owner_user_id -> changeset
    end
  end
end
