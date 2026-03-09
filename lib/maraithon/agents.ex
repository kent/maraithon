defmodule Maraithon.Agents do
  @moduledoc """
  Context for managing agent records in the database.
  """

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Agents.Agent

  @doc """
  List all agents.
  """
  def list_agents(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    Agent
    |> maybe_filter_user(user_id)
    |> order_by([agent], desc: agent.updated_at, desc: agent.inserted_at)
    |> Repo.all()
  end

  @doc """
  Get an agent by ID.
  """
  def get_agent(id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    Agent
    |> maybe_filter_user(user_id)
    |> Repo.get(id)
  end

  @doc """
  Get an agent by ID, raising if not found.
  """
  def get_agent!(id) do
    Repo.get!(Agent, id)
  end

  def get_agent_for_user(id, user_id) when is_binary(user_id) do
    Agent
    |> where([agent], agent.id == ^id and agent.user_id == ^user_id)
    |> Repo.one()
  end

  @doc """
  Create a new agent record.
  """
  def create_agent(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update an agent record.
  """
  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete an agent record.
  """
  def delete_agent(%Agent{} = agent) do
    Repo.delete(agent)
  end

  @doc """
  Count agents by status.
  """
  def count_by_status(status) do
    from(a in Agent, where: a.status == ^status, select: count(a.id))
    |> Repo.one()
  end

  @doc """
  List agents that should be resumed on startup.
  """
  def list_resumable_agents(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    from(a in Agent, where: a.status in ["running", "degraded"])
    |> maybe_filter_user(user_id)
    |> Repo.all()
  end

  @doc """
  Mark agent as running.
  """
  def mark_running(%Agent{} = agent) do
    update_agent(agent, %{status: "running", started_at: DateTime.utc_now()})
  end

  @doc """
  Mark agent as stopped.
  """
  def mark_stopped(%Agent{} = agent) do
    update_agent(agent, %{status: "stopped", stopped_at: DateTime.utc_now()})
  end

  @doc """
  Mark agent as degraded.
  """
  def mark_degraded(%Agent{} = agent) do
    update_agent(agent, %{status: "degraded"})
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [agent], agent.user_id == ^user_id)
  end
end
