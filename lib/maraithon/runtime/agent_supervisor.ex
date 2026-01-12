defmodule Maraithon.Runtime.AgentSupervisor do
  @moduledoc """
  Dynamic supervisor for agent processes.
  """

  alias Maraithon.Runtime.Agent

  @doc """
  Start an agent process under the supervisor.
  """
  def start_agent(agent) do
    spec = {Agent, agent}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stop an agent process.
  """
  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
