defmodule Maraithon.Connectors.Notaui do
  @moduledoc """
  Notaui MCP connector.

  Uses a user OAuth grant when `user_id` is provided and falls back to
  client-credentials auth for app-level MCP automation.
  """

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Connector
  alias Maraithon.OAuth

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
  Discovers the accessible Notaui accounts for a newly-authorized bearer token.
  """
  def discover_accounts(access_token) when is_binary(access_token) and access_token != "" do
    with {:ok, body} <- mcp_tool_call(access_token, "account.list", %{}, []),
         {:ok, payload} <- decode_tool_payload(body),
         {:ok, accounts} <- normalize_account_payload(payload) do
      {:ok, build_account_snapshot(accounts)}
    end
  end

  @doc """
  Lists tasks from Notaui (`task.list` MCP tool).
  """
  def list_tasks(user_id, filter) when is_binary(user_id) and is_map(filter) do
    with {:ok, payload} <- call_tool(user_id, "task.list", filter),
         true <- is_list(payload) do
      {:ok, payload}
    else
      false -> {:error, :invalid_task_list_response}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_tasks(filter \\ %{}) when is_map(filter) do
    with {:ok, payload} <- call_tool(nil, "task.list", filter),
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
  def complete_task(user_id, task_id, opts)
      when is_binary(user_id) and is_binary(task_id) and is_map(opts) do
    args = opts |> Map.put("task_id", task_id)
    call_tool(user_id, "task.complete", args)
  end

  def complete_task(task_id, opts \\ %{}) when is_binary(task_id) and is_map(opts) do
    args = opts |> Map.put("task_id", task_id)
    call_tool(nil, "task.complete", args)
  end

  @doc """
  Updates a task in Notaui (`task.update` MCP tool).
  """
  def update_task(user_id, task_id, attrs)
      when is_binary(user_id) and is_binary(task_id) and is_map(attrs) do
    args = attrs |> Map.put("task_id", task_id)
    call_tool(user_id, "task.update", args)
  end

  def update_task(task_id, attrs \\ %{}) when is_binary(task_id) and is_map(attrs) do
    args = attrs |> Map.put("task_id", task_id)
    call_tool(nil, "task.update", args)
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

  defp call_tool(user_id, tool_name, args)
       when (is_binary(user_id) or is_nil(user_id)) and is_binary(tool_name) and is_map(args) do
    with {:ok, request_context} <- build_request_context(user_id, args),
         {:ok, body} <-
           mcp_tool_call(
             request_context.access_token,
             tool_name,
             request_context.arguments,
             request_context.headers
           ),
         {:ok, payload} <- decode_tool_payload(body) do
      {:ok, payload}
    end
  end

  defp build_request_context(nil, args) when is_map(args) do
    with {:ok, token} <- fetch_access_token(nil) do
      {:ok,
       %{
         access_token: token,
         arguments: strip_account_context(args),
         headers: []
       }}
    end
  end

  defp build_request_context(user_id, args) when is_binary(user_id) and is_map(args) do
    account_id = requested_account_id(args)

    with {:ok, token} <- fetch_access_token(user_id),
         {:ok, header_account_id} <- resolve_account_header(user_id, account_id) do
      {:ok,
       %{
         access_token: token,
         arguments: strip_account_context(args),
         headers: maybe_account_header(header_account_id)
       }}
    end
  end

  defp fetch_access_token(user_id) when is_binary(user_id) do
    OAuth.get_valid_access_token(user_id, "notaui")
  end

  defp fetch_access_token(nil) do
    cfg = config()

    if cfg.client_id == "" or cfg.client_secret == "" do
      {:error, :not_configured}
    else
      req = req_client(cfg)

      case Req.post(req,
             url: cfg.token_url,
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

  defp mcp_tool_call(access_token, tool_name, args, headers) do
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

    case Req.post(
           req,
           url: cfg.mcp_url,
           json: payload,
           auth: {:bearer, access_token},
           headers: headers
         ) do
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

  defp normalize_account_payload(payload) when is_list(payload), do: normalize_accounts(payload)

  defp normalize_account_payload(payload) when is_map(payload) do
    accounts =
      fetch_map_value(payload, "accounts") ||
        fetch_map_value(payload, "items") ||
        fetch_map_value(payload, "data")

    if is_list(accounts) do
      normalize_accounts(accounts)
    else
      {:error, :invalid_account_list_response}
    end
  end

  defp normalize_account_payload(_payload), do: {:error, :invalid_account_list_response}

  defp normalize_accounts(accounts) when is_list(accounts) do
    normalized =
      accounts
      |> Enum.map(&normalize_account/1)
      |> Enum.reject(&is_nil/1)

    if accounts == [] or normalized != [] do
      {:ok, normalized}
    else
      {:error, :invalid_account_list_response}
    end
  end

  defp normalize_account(account) when is_map(account) do
    id =
      (fetch_map_value(account, "id") ||
         fetch_map_value(account, "account_id") ||
         fetch_map_value(account, "accountId") ||
         fetch_map_value(account, "workspace_id") ||
         fetch_map_value(account, "workspaceId"))
      |> normalize_text()

    label =
      (fetch_map_value(account, "label") ||
         fetch_map_value(account, "name") ||
         fetch_map_value(account, "title") ||
         fetch_map_value(account, "workspace_name") ||
         fetch_map_value(account, "workspaceName"))
      |> normalize_text()

    if is_binary(id) and id != "" do
      %{
        "id" => id,
        "label" => label || id,
        "is_default" =>
          truthy?(
            fetch_map_value(account, "is_default") ||
              fetch_map_value(account, "isDefault") ||
              fetch_map_value(account, "default") ||
              fetch_map_value(account, "default_account") ||
              fetch_map_value(account, "defaultAccount")
          )
      }
    end
  end

  defp normalize_account(_account), do: nil

  defp build_account_snapshot(accounts) when is_list(accounts) do
    sorted_accounts =
      Enum.sort_by(accounts, fn account ->
        {String.downcase(account["label"] || account["id"]), account["id"]}
      end)

    default_account =
      Enum.find(sorted_accounts, &truthy?(&1["is_default"])) ||
        case sorted_accounts do
          [account] -> account
          [first | _] -> first
          [] -> nil
        end

    default_account_id = default_account && default_account["id"]

    %{
      "accounts" =>
        Enum.map(sorted_accounts, fn account ->
          Map.put(account, "is_default", account["id"] == default_account_id)
        end),
      "account_count" => length(sorted_accounts),
      "default_account_id" => default_account_id,
      "default_account_label" => default_account && default_account["label"],
      "discovery_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "discovery_error" => nil
    }
  end

  defp requested_account_id(args) when is_map(args) do
    args
    |> fetch_map_value("account_id")
    |> normalize_text()
  end

  defp strip_account_context(args) when is_map(args) do
    args
    |> Map.delete("account_id")
    |> Map.delete(:account_id)
  end

  defp resolve_account_header(_user_id, nil), do: {:ok, nil}

  defp resolve_account_header(user_id, account_id)
       when is_binary(user_id) and is_binary(account_id) do
    connected_account = ConnectedAccounts.get(user_id, "notaui")
    default_account_id = default_account_id(connected_account)

    cond do
      account_id == default_account_id ->
        {:ok, nil}

      MapSet.member?(known_account_ids(connected_account), account_id) ->
        {:ok, account_id}

      true ->
        {:error, :unknown_account_id}
    end
  end

  defp maybe_account_header(nil), do: []
  defp maybe_account_header(""), do: []
  defp maybe_account_header(account_id), do: [{"x-notaui-account-id", account_id}]

  defp default_account_id(nil), do: nil

  defp default_account_id(connected_account) do
    metadata = normalize_metadata(connected_account.metadata)

    normalize_text(fetch_map_value(metadata, "default_account_id")) ||
      normalize_text(connected_account.external_account_id)
  end

  defp known_account_ids(nil), do: MapSet.new()

  defp known_account_ids(connected_account) do
    metadata = normalize_metadata(connected_account.metadata)
    accounts = fetch_map_value(metadata, "accounts")

    ids =
      [
        connected_account.external_account_id,
        fetch_map_value(metadata, "default_account_id")
      ] ++
        Enum.map(List.wrap(accounts), fn account ->
          account
          |> fetch_map_value("id")
          |> normalize_text()
        end)

    ids
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp req_client(cfg) do
    Req.new(
      connect_options: [timeout: cfg.timeout_ms],
      receive_timeout: cfg.timeout_ms,
      retry: false
    )
  end

  defp config do
    app_config = Application.get_env(:maraithon, :notaui, [])
    base_url = Keyword.get(app_config, :base_url, @default_base_url)

    %{
      issuer: Keyword.get(app_config, :issuer, base_url),
      client_id: Keyword.get(app_config, :client_id, ""),
      client_secret: Keyword.get(app_config, :client_secret, ""),
      scope: Keyword.get(app_config, :scope, @default_scope),
      timeout_ms: Keyword.get(app_config, :timeout_ms, @default_timeout_ms),
      topic_prefix: Keyword.get(app_config, :topic_prefix, @default_topic_prefix),
      token_url: Keyword.get(app_config, :token_url, join_url(base_url, "/oauth/token")),
      mcp_url: Keyword.get(app_config, :mcp_url, join_url(base_url, "/mcp"))
    }
  end

  defp join_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    String.trim_trailing(base_url, "/") <> path
  end

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE", "yes", "YES"], do: true
  defp truthy?(_value), do: false
end
