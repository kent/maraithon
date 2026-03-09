defmodule MaraithonWeb.AdminController do
  use MaraithonWeb, :controller

  alias Maraithon.Admin
  alias Maraithon.Runtime
  alias Maraithon.Spend

  def dashboard(conn, params) do
    with {:ok, activity_limit} <-
           parse_positive_integer_param(params["activity_limit"], 40, "activity_limit"),
         {:ok, failure_limit} <-
           parse_positive_integer_param(params["failure_limit"], 20, "failure_limit"),
         {:ok, log_limit} <- parse_positive_integer_param(params["log_limit"], 200, "log_limit") do
      snapshot =
        Admin.dashboard_snapshot(
          activity_limit: activity_limit,
          failure_limit: failure_limit,
          log_limit: log_limit
        )

      json(conn, Map.put(snapshot, :total_spend, Spend.get_total_spend()))
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  def agent_inspection(conn, %{"id" => id} = params) do
    with {:ok, event_limit} <-
           parse_positive_integer_param(params["event_limit"], 50, "event_limit"),
         {:ok, effect_limit} <-
           parse_positive_integer_param(params["effect_limit"], 20, "effect_limit"),
         {:ok, job_limit} <- parse_positive_integer_param(params["job_limit"], 20, "job_limit"),
         {:ok, log_limit} <- parse_positive_integer_param(params["log_limit"], 80, "log_limit") do
      case Runtime.get_agent_status(id) do
        {:ok, agent_status} ->
          {:ok, events} = Runtime.get_events(id, limit: event_limit)

          inspection =
            Admin.agent_inspection(
              id,
              effect_limit: effect_limit,
              job_limit: job_limit,
              log_limit: log_limit
            )

          json(conn, %{
            agent: agent_status,
            spend: Spend.get_agent_spend(id),
            events: events,
            inspection: inspection
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "not_found", message: "Agent not found"})
      end
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  defp parse_positive_integer_param(nil, default, _field_name), do: {:ok, default}
  defp parse_positive_integer_param("", default, _field_name), do: {:ok, default}

  defp parse_positive_integer_param(value, _default, field_name) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be a positive integer"}
    end
  end
end
