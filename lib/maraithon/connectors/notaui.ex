defmodule Maraithon.Connectors.Notaui do
  @moduledoc """
  Notaui MCP connector.

  Provides OAuth client-credentials auth and MCP tool calls so Maraithon agents
  can review and act on Notaui todos.
  """

  alias Maraithon.Connectors.Connector

  require Logger

  @default_base_url "https://api.notaui.com"
  @default_scope "tasks:read tasks:write projects:read projects:write tags:write"
  @default_timeout_ms 10_000
  @default_topic_prefix "notaui"
  @request_id_prefix "maraithon-notaui"

  @doc """
  Whether Notaui integration credentials are configured.
  """
  def enabled? do
    config = config()
    config.client_id != "" and config.client_secret != ""
  end

  @doc """
  Lists tasks from Notaui (`task.list` MCP tool).
  """
  def list_tasks(filter \\ %{}) when is_map(filter) do
    with {:ok, payload} <- call_tool("task.list", filter),
         true <- is_list(payload) do
      {:ok, payload}
    else
      false -> {:error, :invalid_task_list_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Completes a task in Notaui (`task.complete` MCP tool).
  """
  def complete_task(task_id, opts \\ %{}) when is_binary(task_id) and is_map(opts) do
    args = opts |> Map.put("task_id", task_id)
    call_tool("task.complete", args)
  end

  @doc """
  Updates a task in Notaui (`task.update` MCP tool).
  """
  def update_task(task_id, attrs \\ %{}) when is_binary(task_id) and is_map(attrs) do
    args = attrs |> Map.put("task_id", task_id)
    call_tool("task.update", args)
  end

  @doc """
  Pulls tasks from Notaui and publishes a snapshot event to PubSub.
  """
  def publish_task_snapshot(topic \\ nil, filter \\ %{}) when is_map(filter) do
    topic = topic || default_topic()

    with {:ok, tasks} <- list_tasks(filter) do
      event =
        Connector.build_event("notaui_task_snapshot", "notaui", %{
          task_count: length(tasks),
          tasks: tasks,
          filter: filter
        })

      Connector.publish(topic, event)

      {:ok, %{topic: topic, task_count: length(tasks), event_type: event.type}}
    end
  end

  @doc """
  Returns the default topic for Notaui task snapshots.
  """
  def default_topic do
    "#{config().topic_prefix}:tasks"
  end

  defp call_tool(tool_name, args) when is_binary(tool_name) and is_map(args) do
    with {:ok, token} <- fetch_access_token(),
         {:ok, body} <- mcp_tool_call(token, tool_name, args),
         {:ok, payload} <- decode_tool_payload(body) do
      {:ok, payload}
    end
  end

  defp fetch_access_token do
    cfg = config()

    if cfg.client_id == "" or cfg.client_secret == "" do
      {:error, :not_configured}
    else
      req = req_client(cfg)

      case Req.post(req,
             url: "/oauth/token",
             form: %{grant_type: "client_credentials", scope: cfg.scope},
             auth: {:basic, "#{cfg.client_id}:#{cfg.client_secret}"}
           ) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}}
        when is_binary(token) and token != "" ->
          {:ok, token}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Notaui OAuth token request failed", status: status, body: inspect(body))
          {:error, {:oauth_token_request_failed, status}}

        {:error, reason} ->
          Logger.warning("Notaui OAuth token request transport error", reason: inspect(reason))
          {:error, {:oauth_transport_error, reason}}
      end
    end
  end

  defp mcp_tool_call(access_token, tool_name, args) do
    cfg = config()

    payload = %{
      "jsonrpc" => "2.0",
      "id" => "#{@request_id_prefix}-#{System.unique_integer([:positive])}",
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => args
      }
    }

    req = req_client(cfg)

    case Req.post(req, url: "/mcp", json: payload, auth: {:bearer, access_token}) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Notaui MCP request failed", status: status, body: inspect(body))
        {:error, {:mcp_request_failed, status}}

      {:error, reason} ->
        Logger.warning("Notaui MCP transport error", reason: inspect(reason))
        {:error, {:mcp_transport_error, reason}}
    end
  end

  defp decode_tool_payload(%{"error" => %{"message" => message}})
       when is_binary(message) do
    {:error, {:mcp_error, message}}
  end

  defp decode_tool_payload(%{"result" => %{"content" => [%{"text" => text} | _]}})
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:invalid_tool_payload, reason}}
    end
  end

  defp decode_tool_payload(_), do: {:error, :invalid_mcp_response}

  defp req_client(cfg) do
    Req.new(
      base_url: cfg.base_url,
      connect_options: [timeout: cfg.timeout_ms],
      receive_timeout: cfg.timeout_ms,
      retry: false
    )
  end

  defp config do
    app_config = Application.get_env(:maraithon, :notaui, [])

    %{
      base_url: Keyword.get(app_config, :base_url, @default_base_url),
      client_id: Keyword.get(app_config, :client_id, ""),
      client_secret: Keyword.get(app_config, :client_secret, ""),
      scope: Keyword.get(app_config, :scope, @default_scope),
      timeout_ms: Keyword.get(app_config, :timeout_ms, @default_timeout_ms),
      topic_prefix: Keyword.get(app_config, :topic_prefix, @default_topic_prefix)
    }
  end
end
