defmodule MaraithonWeb.AdminController do
  use MaraithonWeb, :controller

  alias Maraithon.Admin
  alias Maraithon.Connections

  def dashboard(conn, params) do
    with {:ok, activity_limit} <-
           parse_positive_integer_param(params["activity_limit"], 40, "activity_limit"),
         {:ok, failure_limit} <-
           parse_positive_integer_param(params["failure_limit"], 20, "failure_limit"),
         {:ok, log_limit} <- parse_positive_integer_param(params["log_limit"], 200, "log_limit") do
      snapshot =
        case Admin.safe_control_center_snapshot(
               activity_limit: activity_limit,
               failure_limit: failure_limit,
               log_limit: log_limit
             ) do
          {:ok, snapshot} -> snapshot
          {:degraded, snapshot} -> snapshot
        end

      json(conn, serialize_dashboard_snapshot(snapshot))
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
      case Admin.safe_agent_snapshot(
             id,
             event_limit: event_limit,
             effect_limit: effect_limit,
             job_limit: job_limit,
             log_limit: log_limit
           ) do
        {:ok, snapshot} ->
          json(conn, snapshot)

        {:degraded, snapshot} ->
          json(conn, snapshot)

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

  def fly_logs(conn, params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], 100, "limit"),
         {:ok, apps} <- parse_apps_param(params["app"]),
         {:ok, next_token} <- parse_next_token_param(params["next_token"], apps),
         {:ok, snapshot} <-
           Admin.fly_logs(
             [
               limit: limit,
               region: blank_to_nil(params["region"]),
               next_token: next_token
             ]
             |> maybe_put_apps(apps)
           ) do
      json(conn, snapshot)
    else
      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "fly_logs_unavailable", message: inspect(reason)})
    end
  end

  def connections(conn, params) do
    user_id = parse_user_id(params["user_id"])

    snapshot =
      case Connections.safe_dashboard_snapshot(user_id, return_to: "/?user_id=#{user_id}") do
        {:ok, snapshot} -> snapshot
        {:degraded, snapshot} -> snapshot
      end

    json(conn, serialize_connections_snapshot(snapshot))
  end

  def disconnect_connection(conn, %{"provider" => provider} = params) do
    user_id = parse_user_id(params["user_id"])

    case Connections.disconnect(user_id, provider) do
      {:ok, _deleted} ->
        json(conn, %{status: "disconnected", provider: provider, user_id: user_id})

      {:error, :no_token} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Connection not found"})

      {:error, :unsupported_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: "Unsupported provider"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "disconnect_failed", message: inspect(reason)})
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

  defp parse_apps_param(nil), do: {:ok, []}
  defp parse_apps_param(""), do: {:ok, []}

  defp parse_apps_param(value) when is_binary(value) do
    apps =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, apps}
  end

  defp parse_next_token_param(nil, _apps), do: {:ok, nil}
  defp parse_next_token_param("", _apps), do: {:ok, nil}
  defp parse_next_token_param(_next_token, []), do: {:error, "next_token requires an app"}
  defp parse_next_token_param(next_token, [_app]), do: {:ok, next_token}

  defp parse_next_token_param(_next_token, _apps),
    do: {:error, "next_token requires exactly one app"}

  defp maybe_put_apps(opts, []), do: opts
  defp maybe_put_apps(opts, apps), do: Keyword.put(opts, :apps, apps)

  defp parse_user_id(nil), do: Connections.default_user_id()
  defp parse_user_id(""), do: Connections.default_user_id()

  defp parse_user_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> Connections.default_user_id()
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp serialize_dashboard_snapshot(snapshot) do
    Map.update(snapshot, :agents, [], fn agents ->
      Enum.map(agents, &serialize_agent/1)
    end)
  end

  defp serialize_connections_snapshot(snapshot) do
    normalize_json(snapshot)
  end

  defp serialize_agent(agent) when is_map(agent) do
    %{
      id: agent.id,
      behavior: agent.behavior,
      config: Map.get(agent, :config, %{}),
      status: agent.status,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      inserted_at: Map.get(agent, :inserted_at),
      updated_at: Map.get(agent, :updated_at)
    }
  end

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(value) when value in [nil, true, false], do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {normalize_json_key(key), normalize_json(item)} end)
    |> Map.new()
  end

  defp normalize_json(value), do: value

  defp normalize_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_json_key(key), do: key
end
