defmodule Maraithon.Events do
  @moduledoc """
  Event store for agent events.
  """

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Events.Event

  @doc """
  Append an event to the log.
  """
  def append(agent_id, event_type, payload, opts \\ []) do
    sequence_num = opts[:sequence_num] || next_sequence_num(agent_id)
    idempotency_key = opts[:idempotency_key]

    attrs = %{
      agent_id: agent_id,
      sequence_num: sequence_num,
      event_type: event_type,
      payload: payload,
      idempotency_key: idempotency_key
    }

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List events for an agent.
  """
  def list_events(agent_id, opts \\ []) do
    after_seq = opts[:after_seq]
    limit = opts[:limit] || 100
    types = opts[:types]

    query =
      from(e in Event,
        where: e.agent_id == ^agent_id,
        order_by: [asc: e.sequence_num],
        limit: ^limit
      )

    query =
      if after_seq do
        from(e in query, where: e.sequence_num > ^after_seq)
      else
        query
      end

    query =
      if types && types != [] do
        from(e in query, where: e.event_type in ^types)
      else
        query
      end

    Repo.all(query)
    |> Enum.map(&format_event/1)
  end

  @doc """
  Get the latest sequence number for an agent.
  """
  def latest_sequence_num(agent_id) do
    from(e in Event,
      where: e.agent_id == ^agent_id,
      select: max(e.sequence_num)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Get events after a specific sequence number (for replay).
  """
  def get_events_after(agent_id, sequence_num) do
    from(e in Event,
      where: e.agent_id == ^agent_id,
      where: e.sequence_num > ^sequence_num,
      order_by: [asc: e.sequence_num]
    )
    |> Repo.all()
  end

  # Private functions

  defp next_sequence_num(agent_id) do
    latest_sequence_num(agent_id) + 1
  end

  defp format_event(event) do
    %{
      id: event.id,
      sequence_num: event.sequence_num,
      event_type: event.event_type,
      payload: event.payload,
      created_at: event.inserted_at
    }
  end
end
