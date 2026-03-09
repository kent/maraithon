defmodule Mix.Tasks.Maraithon.Agent do
  use Mix.Task

  alias Maraithon.CLI.Client

  @shortdoc "Operate Maraithon agents over the production API"

  @switches [
    base_url: :string,
    token: :string,
    behavior: :string,
    name: :string,
    prompt: :string,
    subscriptions: :string,
    tools: :string,
    memory_limit: :string,
    budget_llm_calls: :string,
    budget_tool_calls: :string,
    config_json: :string,
    metadata_json: :string,
    reason: :string,
    limit: :string,
    types: :string,
    event_limit: :string,
    effect_limit: :string,
    job_limit: :string,
    log_limit: :string
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise(
        "Invalid options: #{Enum.map_join(invalid, ", ", fn {key, _value} -> "--#{key}" end)}"
      )
    end

    case argv do
      ["list"] ->
        call_and_print(:get, "/api/v1/agents", opts)

      ["show", id] ->
        call_and_print(:get, "/api/v1/agents/#{id}", opts)

      ["create"] ->
        payload = build_agent_payload(opts, :create)
        call_and_print(:post, "/api/v1/agents", Keyword.put(opts, :json, payload))

      ["update", id] ->
        payload = build_agent_payload(opts, :update)
        call_and_print(:patch, "/api/v1/agents/#{id}", Keyword.put(opts, :json, payload))

      ["start", id] ->
        call_and_print(:post, "/api/v1/agents/#{id}/start", opts)

      ["stop", id] ->
        payload = if reason = opts[:reason], do: %{"reason" => reason}, else: nil
        call_and_print(:post, "/api/v1/agents/#{id}/stop", maybe_put_json(opts, payload))

      ["delete", id] ->
        call_and_print(:delete, "/api/v1/agents/#{id}", opts)

      ["ask", id, message] ->
        metadata = parse_optional_json!(opts[:metadata_json], "metadata_json")

        payload =
          %{"message" => message}
          |> maybe_put_map("metadata", metadata)

        call_and_print(:post, "/api/v1/agents/#{id}/ask", Keyword.put(opts, :json, payload))

      ["events", id] ->
        params =
          %{}
          |> maybe_put_param("limit", opts[:limit])
          |> maybe_put_param("types", opts[:types])

        call_and_print(:get, "/api/v1/agents/#{id}/events", Keyword.put(opts, :params, params))

      ["inspect", id] ->
        params =
          %{}
          |> maybe_put_param("event_limit", opts[:event_limit])
          |> maybe_put_param("effect_limit", opts[:effect_limit])
          |> maybe_put_param("job_limit", opts[:job_limit])
          |> maybe_put_param("log_limit", opts[:log_limit])

        call_and_print(
          :get,
          "/api/v1/admin/agents/#{id}/inspection",
          Keyword.put(opts, :params, params)
        )

      ["help"] ->
        Mix.shell().info(usage())

      _ ->
        Mix.raise(usage())
    end
  end

  defp call_and_print(method, path, opts) do
    response =
      case method do
        :get -> Client.get(path, client_opts(opts))
        :post -> Client.post(path, client_opts(opts))
        :patch -> Client.patch(path, client_opts(opts))
        :delete -> Client.delete(path, client_opts(opts))
      end

    case response do
      {:ok, body} ->
        Mix.shell().info(render_body(body))

      {:error, message} when is_binary(message) ->
        Mix.raise(message)

      {:error, {:http_status, status, body}} ->
        Mix.raise("Request failed with status #{status}: #{render_body(body)}")

      {:error, {:request_failed, exception}} ->
        Mix.raise("Request failed: #{Exception.message(exception)}")

      {:error, {:startup_failed, reason}} ->
        Mix.raise("Failed to start CLI client: #{inspect(reason)}")
    end
  end

  defp client_opts(opts) do
    []
    |> maybe_put_opt(:base_url, opts[:base_url])
    |> maybe_put_opt(:token, opts[:token])
    |> maybe_put_opt(:json, opts[:json])
    |> maybe_put_opt(:params, opts[:params])
  end

  defp build_agent_payload(opts, mode) do
    behavior =
      case {mode, opts[:behavior]} do
        {:create, nil} -> Mix.raise("create requires --behavior")
        {:create, ""} -> Mix.raise("create requires --behavior")
        {_mode, value} -> value
      end

    config =
      %{}
      |> maybe_put_config("name", opts[:name])
      |> maybe_put_config("prompt", opts[:prompt])
      |> maybe_put_list_config("subscribe", opts[:subscriptions])
      |> maybe_put_list_config("tools", opts[:tools])
      |> maybe_put_integer_config("memory_limit", opts[:memory_limit], "memory_limit")
      |> merge_optional_json(parse_optional_json!(opts[:config_json], "config_json"))

    payload =
      %{}
      |> maybe_put_map("config", empty_to_nil(config))
      |> maybe_put_value("behavior", behavior)

    maybe_put_map(payload, "budget", build_budget(opts))
  end

  defp build_budget(opts) do
    case {opts[:budget_llm_calls], opts[:budget_tool_calls]} do
      {nil, nil} ->
        nil

      {"", ""} ->
        nil

      {llm_calls, tool_calls} when is_binary(llm_calls) and is_binary(tool_calls) ->
        %{
          "llm_calls" => parse_positive_integer!(llm_calls, "budget_llm_calls"),
          "tool_calls" => parse_positive_integer!(tool_calls, "budget_tool_calls")
        }

      _ ->
        Mix.raise("budget updates require both --budget-llm-calls and --budget-tool-calls")
    end
  end

  defp parse_optional_json!(nil, _field_name), do: nil
  defp parse_optional_json!("", _field_name), do: nil

  defp parse_optional_json!(value, field_name) do
    case Jason.decode(value) do
      {:ok, parsed} when is_map(parsed) -> parsed
      {:ok, _parsed} -> Mix.raise("--#{field_name} must decode to a JSON object")
      {:error, _reason} -> Mix.raise("--#{field_name} must be valid JSON")
    end
  end

  defp parse_positive_integer!(value, field_name) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> Mix.raise("--#{field_name} must be a positive integer")
    end
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, %{} = map) when map_size(map) == 0, do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_value(map, _key, nil), do: map
  defp maybe_put_value(map, _key, ""), do: map
  defp maybe_put_value(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, _key, ""), do: map
  defp maybe_put_param(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_config(map, _key, nil), do: map
  defp maybe_put_config(map, _key, ""), do: map
  defp maybe_put_config(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_list_config(map, _key, nil), do: map
  defp maybe_put_list_config(map, _key, ""), do: map

  defp maybe_put_list_config(map, key, value) do
    values =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(map, key, values)
  end

  defp maybe_put_integer_config(map, _key, nil, _field_name), do: map
  defp maybe_put_integer_config(map, _key, "", _field_name), do: map

  defp maybe_put_integer_config(map, key, value, field_name) do
    Map.put(map, key, parse_positive_integer!(value, field_name))
  end

  defp merge_optional_json(map, nil), do: map
  defp merge_optional_json(map, extra), do: Map.merge(map, extra)

  defp empty_to_nil(%{} = map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map

  defp render_body(body) when is_binary(body), do: body
  defp render_body(body), do: Jason.encode!(body, pretty: true)

  defp usage do
    """
    Usage:
      mix maraithon.agent list [--base-url URL] [--token TOKEN]
      mix maraithon.agent show AGENT_ID
      mix maraithon.agent create --behavior BEHAVIOR [--name NAME] [--prompt PROMPT]
      mix maraithon.agent update AGENT_ID [--behavior BEHAVIOR] [--name NAME] [--prompt PROMPT]
      mix maraithon.agent start AGENT_ID
      mix maraithon.agent stop AGENT_ID [--reason REASON]
      mix maraithon.agent delete AGENT_ID
      mix maraithon.agent ask AGENT_ID "message" [--metadata-json JSON]
      mix maraithon.agent events AGENT_ID [--limit N] [--types type1,type2]
      mix maraithon.agent inspect AGENT_ID [--event-limit N] [--effect-limit N] [--job-limit N] [--log-limit N]

    Shared configuration:
      --base-url URL     Override MARAITHON_BASE_URL
      --token TOKEN      Override MARAITHON_API_TOKEN

    Create/update options:
      --subscriptions a,b,c
      --tools x,y,z
      --memory-limit N
      --budget-llm-calls N
      --budget-tool-calls N
      --config-json JSON_OBJECT
    """
  end
end
