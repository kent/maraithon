defmodule MaraithonWeb.AgentController do
  use MaraithonWeb, :controller

  alias Maraithon.Runtime
  alias Maraithon.Agents
  alias Maraithon.Spend

  require Logger

  def create(conn, params) do
    Logger.info("Creating agent", agent_params: params)

    case Runtime.start_agent(params) do
      {:ok, agent} ->
        conn
        |> put_status(:created)
        |> json(agent_payload(agent))

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", details: format_errors(changeset)})
    end
  end

  def index(conn, _params) do
    agents = Agents.list_agents()
    json(conn, %{agents: Enum.map(agents, &agent_summary/1)})
  end

  def show(conn, %{"id" => id}) do
    case Runtime.get_agent_status(id) do
      {:ok, status} ->
        json(conn, status)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Agent not found"})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Runtime.update_agent(id, params) do
      {:ok, agent} ->
        json(conn, agent_payload(agent))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Agent not found"})

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", details: format_errors(changeset)})
    end
  end

  def ask(conn, %{"id" => id} = params) do
    message = params["message"] || ""
    metadata = params["metadata"] || %{}

    case Runtime.send_message(id, message, metadata) do
      {:ok, result} ->
        conn
        |> put_status(:accepted)
        |> json(%{accepted: true, message_id: result.message_id})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:error, :agent_stopped} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "agent_stopped", message: "Agent is not running"})

      {:error, :mailbox_full} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "mailbox_full", message: "Agent is overloaded"})
    end
  end

  def start(conn, %{"id" => id}) do
    case Runtime.start_existing_agent(id) do
      {:ok, agent} ->
        json(conn, agent_payload(agent))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Agent not found"})

      {:error, :already_running} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "already_running", message: "Agent is already running"})

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", details: format_errors(changeset)})
    end
  end

  def stop(conn, %{"id" => id} = params) do
    reason = params["reason"] || "manual_stop"

    case Runtime.stop_agent(id, reason) do
      {:ok, result} ->
        json(conn, %{
          id: id,
          status: "stopped",
          stopped_at: result.stopped_at
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  def events(conn, %{"id" => id} = params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], 100, "limit") do
      opts = [after_seq: params["after_seq"], limit: limit, types: parse_types(params["types"])]

      case Runtime.get_events(id, opts) do
        {:ok, events} ->
          json(conn, %{
            events: events,
            has_more: length(events) == opts[:limit]
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "not_found"})
      end
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  def spend(conn, %{"id" => id}) do
    case Agents.get_agent(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      _agent ->
        spend = Spend.get_agent_spend(id)

        json(conn, %{
          agent_id: id,
          total_cost_usd: spend.total_cost,
          input_tokens: spend.input_tokens,
          output_tokens: spend.output_tokens,
          llm_calls: spend.llm_calls
        })
    end
  end

  def total_spend(conn, _params) do
    spend = Spend.get_total_spend()

    json(conn, %{
      total_cost_usd: spend.total_cost,
      input_tokens: spend.input_tokens,
      output_tokens: spend.output_tokens,
      llm_calls: spend.llm_calls
    })
  end

  def delete(conn, %{"id" => id}) do
    case Runtime.delete_agent(id) do
      :ok ->
        json(conn, %{id: id, deleted: true})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Agent not found"})
    end
  end

  # Private helpers

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp format_errors(error), do: inspect(error)

  defp agent_summary(agent) do
    %{
      id: agent.id,
      behavior: agent.behavior,
      status: agent.status,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      updated_at: agent.updated_at
    }
  end

  defp agent_payload(agent) do
    %{
      id: agent.id,
      behavior: agent.behavior,
      status: agent.status,
      config: agent.config,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at
    }
  end

  defp parse_positive_integer_param(nil, default, _field_name), do: {:ok, default}
  defp parse_positive_integer_param("", default, _field_name), do: {:ok, default}

  defp parse_positive_integer_param(value, _default, field_name) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be a positive integer"}
    end
  end

  defp parse_types(nil), do: nil
  defp parse_types(types) when is_binary(types), do: String.split(types, ",")
  defp parse_types(types) when is_list(types), do: types
end
