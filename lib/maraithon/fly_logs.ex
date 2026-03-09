defmodule Maraithon.FlyLogs do
  @moduledoc """
  Fetches Fly.io app and machine logs over the Fly REST API.

  This is intended for operator-facing troubleshooting surfaces such as the
  admin dashboard and CLI.
  """

  @default_limit 100
  @max_limit 250
  @max_concurrency 4

  @type log_entry :: %{
          id: String.t() | nil,
          app: String.t(),
          timestamp: String.t() | nil,
          level: String.t(),
          message: String.t(),
          raw_message: String.t(),
          metadata: map()
        }

  @type snapshot :: %{
          available: boolean(),
          apps: [String.t()],
          logs: [log_entry()],
          next_tokens: %{optional(String.t()) => String.t()},
          errors: [map()]
        }

  @spec recent_logs(Keyword.t()) :: {:ok, snapshot()} | {:error, term()}
  def recent_logs(opts \\ []) do
    config = config()
    requested_apps = normalize_apps(Keyword.get(opts, :apps, config.apps))

    cond do
      config.api_token == "" ->
        {:ok, unavailable_snapshot(requested_apps, "FLY_API_TOKEN is not configured")}

      requested_apps == [] ->
        {:ok, unavailable_snapshot([], "FLY_LOG_APPS is not configured")}

      true ->
        with :ok <- ensure_req_started(),
             :ok <- validate_next_token_opts(requested_apps, Keyword.get(opts, :next_token)) do
          fetch_logs(config, requested_apps, opts)
        end
    end
  end

  def configured_apps do
    config().apps
  end

  def available? do
    current = config()
    current.api_token != "" and current.apps != []
  end

  defp fetch_logs(config, apps, opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    region = normalize_blank(Keyword.get(opts, :region)) || config.region
    next_token = normalize_blank(Keyword.get(opts, :next_token))

    results =
      apps
      |> Task.async_stream(
        fn app -> fetch_app_logs(config, app, region, next_token) end,
        ordered: false,
        timeout: config.receive_timeout_ms,
        max_concurrency: min(length(apps), @max_concurrency)
      )
      |> Enum.map(&normalize_task_result/1)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    logs =
      successes
      |> Enum.flat_map(fn {:ok, %{logs: app_logs}} -> app_logs end)
      |> Enum.sort_by(&log_sort_key/1, :desc)
      |> Enum.take(limit)

    next_tokens =
      successes
      |> Enum.reduce(%{}, fn {:ok, %{app: app, next_token: token}}, acc ->
        if is_binary(token) and token != "" do
          Map.put(acc, app, token)
        else
          acc
        end
      end)

    errors =
      failures
      |> Enum.map(fn {:error, %{app: app, reason: reason}} ->
        %{
          app: app,
          message: format_fetch_error(reason)
        }
      end)

    {:ok,
     %{
       available: true,
       apps: apps,
       logs: logs,
       next_tokens: next_tokens,
       errors: errors
     }}
  end

  defp fetch_app_logs(config, app, region, next_token) do
    request_opts =
      [
        url: "#{String.trim_trailing(config.api_base_url, "/")}/apps/#{app}/logs",
        headers: [{"authorization", config.api_token}],
        receive_timeout: config.receive_timeout_ms
      ]
      |> maybe_put_params(build_params(region, next_token))

    case Req.get(request_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{
           app: app,
           logs: normalize_logs(app, body),
           next_token: get_in(body, ["meta", "next_token"])
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{app: app, reason: {:http_status, status, body}}}

      {:error, exception} ->
        {:error, %{app: app, reason: {:request_failed, exception}}}
    end
  end

  defp build_params(region, next_token) do
    %{}
    |> maybe_put_param("region", region)
    |> maybe_put_param("next_token", next_token)
  end

  defp normalize_logs(app, %{"data" => data}) when is_list(data) do
    Enum.map(data, &normalize_log(app, &1))
  end

  defp normalize_logs(_app, _body), do: []

  defp normalize_log(app, %{"id" => id, "attributes" => attributes}) do
    raw_message = to_string(Map.get(attributes, "message", ""))
    outer_level = normalize_level(Map.get(attributes, "level"))
    outer_timestamp = normalize_blank(Map.get(attributes, "timestamp"))

    base_metadata =
      %{
        "app" => app,
        "instance" => attributes["instance"],
        "region" => attributes["region"],
        "provider" => get_in(attributes, ["meta", "event", "provider"]),
        "platform_level" => outer_level
      }
      |> compact_map()

    case decode_structured_message(raw_message) do
      {:ok, decoded} ->
        %{
          id: id,
          app: app,
          timestamp: normalize_blank(decoded["timestamp"]) || outer_timestamp,
          level: normalize_level(decoded["severity"]) || outer_level,
          message: strip_ansi(decoded["message"] || raw_message),
          raw_message: raw_message,
          metadata: Map.merge(base_metadata, normalize_inner_metadata(decoded))
        }

      :error ->
        %{
          id: id,
          app: app,
          timestamp: outer_timestamp,
          level: outer_level,
          message: strip_ansi(raw_message),
          raw_message: raw_message,
          metadata: base_metadata
        }
    end
  end

  defp decode_structured_message(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{"message" => _message} = decoded} -> {:ok, decoded}
      _ -> :error
    end
  end

  defp normalize_inner_metadata(decoded) do
    decoded
    |> Map.drop(["message", "timestamp", "severity", "logging.googleapis.com/labels"])
    |> Enum.reduce(%{}, fn
      {_key, value}, acc when is_nil(value) or value == "" or value == %{} ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, normalize_metadata_value(value))
    end)
  end

  defp normalize_metadata_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: value

  defp normalize_metadata_value(value), do: inspect(value, limit: 10, printable_limit: 200)

  defp ensure_req_started do
    case Application.ensure_all_started(:req) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:startup_failed, reason}}
    end
  end

  defp validate_next_token_opts(_apps, nil), do: :ok
  defp validate_next_token_opts([_single_app], _token), do: :ok

  defp validate_next_token_opts(_apps, _token),
    do: {:error, "next_token requires exactly one selected app"}

  defp normalize_task_result({:ok, result}), do: result

  defp normalize_task_result({:exit, reason}) do
    {:error, %{app: "unknown", reason: {:task_exit, reason}}}
  end

  defp normalize_apps(apps) when is_list(apps) do
    apps
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_apps(app) when is_binary(app), do: normalize_apps([app])
  defp normalize_apps(_), do: []

  defp normalize_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp normalize_level(nil), do: "info"

  defp normalize_level(level) when is_binary(level) do
    case level |> String.trim() |> String.downcase() do
      "" -> nil
      value -> value
    end
  end

  defp normalize_level(level), do: level |> to_string() |> normalize_level()

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_put_params(opts, params) when params == %{}, do: opts
  defp maybe_put_params(opts, params), do: Keyword.put(opts, :params, params)

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp strip_ansi(message) when is_binary(message) do
    message
    |> then(&Regex.replace(~r/\e\[[\d;]*m/u, &1, ""))
    |> String.trim()
  end

  defp strip_ansi(message), do: to_string(message)

  defp log_sort_key(%{timestamp: timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.from_unix!(0)
    end
  end

  defp log_sort_key(_), do: DateTime.from_unix!(0)

  defp format_fetch_error({:http_status, status, body}) do
    "Fly API returned #{status}: #{format_body(body)}"
  end

  defp format_fetch_error({:request_failed, exception}) do
    "Fly API request failed: #{Exception.message(exception)}"
  end

  defp format_fetch_error({:task_exit, reason}) do
    "Fly log fetch task exited: #{inspect(reason)}"
  end

  defp format_fetch_error({:startup_failed, reason}) do
    "Req failed to start: #{inspect(reason)}"
  end

  defp format_fetch_error(reason), do: inspect(reason)

  defp format_body(body) when is_binary(body), do: body
  defp format_body(body), do: inspect(body, limit: 10, printable_limit: 300)

  defp unavailable_snapshot(apps, message) do
    %{
      available: false,
      apps: apps,
      logs: [],
      next_tokens: %{},
      errors: [%{app: nil, message: message}]
    }
  end

  defp config do
    raw = Application.get_env(:maraithon, __MODULE__, [])

    %{
      api_token: normalize_blank(Keyword.get(raw, :api_token)) || "",
      api_base_url: Keyword.get(raw, :api_base_url, "https://api.fly.io/api/v1"),
      apps: normalize_apps(Keyword.get(raw, :apps, [])),
      region: normalize_blank(Keyword.get(raw, :region)),
      receive_timeout_ms: Keyword.get(raw, :receive_timeout_ms, 15_000)
    }
  end
end
