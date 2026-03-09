defmodule Maraithon.Runtime.Dispatch do
  @moduledoc """
  Cluster-safe message dispatch for agent processes.
  """

  @topic_prefix "runtime:agent"

  @doc """
  Build the PubSub topic used for an agent.
  """
  def agent_topic(agent_id) when is_binary(agent_id) do
    "#{@topic_prefix}:#{agent_id}"
  end

  @doc """
  Subscribe the current process to an agent topic.
  """
  def subscribe(agent_id) when is_binary(agent_id) do
    Phoenix.PubSub.subscribe(Maraithon.PubSub, agent_topic(agent_id))
  end

  @doc """
  Dispatch a message to an agent across the cluster.
  """
  def dispatch(agent_id, message) when is_binary(agent_id) do
    Phoenix.PubSub.broadcast(
      Maraithon.PubSub,
      agent_topic(agent_id),
      {:agent_dispatch, message}
    )
  end
end
