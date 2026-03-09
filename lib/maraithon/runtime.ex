defmodule Maraithon.Runtime do
  @moduledoc """
  Runtime facade for managing agents.
  Provides the main API for starting, stopping, and interacting with agents.
  """

  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Events

  require Logger

  @doc """
  Start a new agent with the given parameters.
  """
  def start_agent(params) do
    attrs = %{
      behavior: params["behavior"] || params[:behavior],
      config: params["config"] || params[:config] || %{},
      status: "running",
      started_at: DateTime.utc_now()
    }

    # Add budget to config if provided
    attrs =
      if budget = params["budget"] || params[:budget] do
        put_in(attrs, [:config, "budget"], budget)
      else
        put_in(attrs, [:config, "budget"], default_budget())
      end

    with {:ok, agent} <- Agents.create_agent(attrs),
         {:ok, _pid} <- start_agent_process(agent) do
      Logger.info("Started agent #{agent.id}", agent_id: agent.id, behavior: agent.behavior)
      {:ok, agent}
    else
      {:error, reason} = error ->
        Logger.error("Failed to start agent: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stop an agent by ID.
  """
  def stop_agent(id, reason \\ "manual_stop") do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        # Ask agent to stop across the cluster, then stop local process if present.
        Dispatch.dispatch(id, {:control, :stop, reason})
        stop_agent_process(id)

        # Update database
        {:ok, agent} = Agents.mark_stopped(agent)

        Logger.info("Stopped agent #{id}", agent_id: id, reason: reason)
        {:ok, %{stopped_at: agent.stopped_at}}
    end
  end

  @doc """
  Get detailed status of an agent.
  """
  def get_agent_status(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        status = build_status(agent)
        {:ok, status}
    end
  end

  @doc """
  Send a message to an agent.
  """
  def send_message(id, message, metadata \\ %{}) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["running", "degraded"] ->
        message_id = Ecto.UUID.generate()
        :ok = Dispatch.dispatch(id, {:message, message, metadata, message_id})
        {:ok, %{message_id: message_id}}

      _agent ->
        {:error, :agent_stopped}
    end
  end

  @doc """
  Get events for an agent.
  """
  def get_events(id, opts \\ []) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      _agent ->
        events = Events.list_events(id, opts)
        {:ok, events}
    end
  end

  @doc """
  Resume all agents that were running before a restart.
  Called during application startup.
  """
  def resume_all_agents do
    agents = Agents.list_resumable_agents()
    Logger.info("Resuming #{length(agents)} agents")

    Enum.each(agents, fn agent ->
      case start_agent_process(agent) do
        {:ok, _pid} ->
          Logger.info("Resumed agent #{agent.id}", agent_id: agent.id)

        {:error, reason} ->
          Logger.error("Failed to resume agent #{agent.id}: #{inspect(reason)}",
            agent_id: agent.id
          )
      end
    end)
  end

  # Private functions

  defp start_agent_process(agent) do
    AgentSupervisor.start_agent(agent)
  end

  defp stop_agent_process(id) do
    case lookup_agent_process(id) do
      {:ok, pid} ->
        AgentSupervisor.stop_agent(pid)

      :not_running ->
        :ok
    end
  end

  defp lookup_agent_process(id) do
    case Registry.lookup(AgentRegistry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> lookup_global_agent_process(id)
    end
  end

  defp lookup_global_agent_process(id) do
    case :global.whereis_name({:maraithon_agent, id}) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> :not_running
    end
  end

  defp build_status(agent) do
    base = %{
      id: agent.id,
      status: agent.status,
      behavior: agent.behavior,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      config: agent.config
    }

    # Add runtime info if process is running
    case lookup_agent_process(agent.id) do
      {:ok, pid} ->
        runtime_info = get_runtime_info(pid)
        Map.merge(base, %{runtime: runtime_info})

      :not_running ->
        base
    end
  end

  defp get_runtime_info(pid) do
    try do
      # This would call into the agent process for live stats
      # For now, return basic process info
      info = Process.info(pid, [:message_queue_len, :memory])

      %{
        pid: inspect(pid),
        message_queue_len: info[:message_queue_len],
        memory_bytes: info[:memory]
      }
    rescue
      _ -> %{}
    end
  end

  defp default_budget do
    %{
      "llm_calls" => 500,
      "tool_calls" => 1000
    }
  end
end
