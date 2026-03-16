defmodule Mix.Tasks.Maraithon.Admin do
  use Mix.Task

  alias Maraithon.CLI.Client

  @shortdoc "Inspect the Maraithon fleet over the production API"

  @switches [
    base_url: :string,
    token: :string,
    activity_limit: :string,
    failure_limit: :string,
    log_limit: :string,
    user_id: :string,
    reason: :string,
    app: :string,
    region: :string,
    limit: :string,
    next_token: :string
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
      ["dashboard"] ->
        params =
          %{}
          |> maybe_put_param("activity_limit", opts[:activity_limit])
          |> maybe_put_param("failure_limit", opts[:failure_limit])
          |> maybe_put_param("log_limit", opts[:log_limit])

        case Client.get("/api/v1/admin/dashboard", client_opts(opts, params)) do
          {:ok, body} ->
            Mix.shell().info(Jason.encode!(body, pretty: true))

          {:error, message} when is_binary(message) ->
            Mix.raise(message)

          {:error, {:http_status, status, body}} ->
            Mix.raise("Request failed with status #{status}: #{render_body(body)}")

          {:error, {:request_failed, exception}} ->
            Mix.raise("Request failed: #{Exception.message(exception)}")

          {:error, {:startup_failed, reason}} ->
            Mix.raise("Failed to start CLI client: #{inspect(reason)}")
        end

      ["fly-logs"] ->
        params =
          %{}
          |> maybe_put_param("app", opts[:app])
          |> maybe_put_param("region", opts[:region])
          |> maybe_put_param("limit", opts[:limit])
          |> maybe_put_param("next_token", opts[:next_token])

        case Client.get("/api/v1/admin/fly/logs", client_opts(opts, params)) do
          {:ok, body} ->
            Mix.shell().info(Jason.encode!(body, pretty: true))

          {:error, message} when is_binary(message) ->
            Mix.raise(message)

          {:error, {:http_status, status, body}} ->
            Mix.raise("Request failed with status #{status}: #{render_body(body)}")

          {:error, {:request_failed, exception}} ->
            Mix.raise("Request failed: #{Exception.message(exception)}")

          {:error, {:startup_failed, reason}} ->
            Mix.raise("Failed to start CLI client: #{inspect(reason)}")
        end

      ["refresh-insights"] ->
        payload =
          %{}
          |> maybe_put_param("user_id", opts[:user_id])
          |> maybe_put_param("reason", opts[:reason])

        case Client.post("/api/v1/admin/insights/refresh", client_opts(opts, %{}, payload)) do
          {:ok, body} ->
            Mix.shell().info(Jason.encode!(body, pretty: true))

          {:error, message} when is_binary(message) ->
            Mix.raise(message)

          {:error, {:http_status, status, body}} ->
            Mix.raise("Request failed with status #{status}: #{render_body(body)}")

          {:error, {:request_failed, exception}} ->
            Mix.raise("Request failed: #{Exception.message(exception)}")

          {:error, {:startup_failed, reason}} ->
            Mix.raise("Failed to start CLI client: #{inspect(reason)}")
        end

      ["help"] ->
        Mix.shell().info(usage())

      _ ->
        Mix.raise(usage())
    end
  end

  defp client_opts(opts, params, json \\ nil) do
    []
    |> maybe_put_opt(:base_url, opts[:base_url])
    |> maybe_put_opt(:token, opts[:token])
    |> maybe_put_opt(:params, params)
    |> maybe_put_opt(:json, json)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, %{} = map) when map_size(map) == 0, do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, _key, ""), do: map
  defp maybe_put_param(map, key, value), do: Map.put(map, key, value)

  defp render_body(body) when is_binary(body), do: body
  defp render_body(body), do: Jason.encode!(body, pretty: true)

  defp usage do
    """
    Usage:
      mix maraithon.admin dashboard [--activity-limit N] [--failure-limit N] [--log-limit N]
      mix maraithon.admin refresh-insights [--user-id USER_ID] [--reason TEXT]
      mix maraithon.admin fly-logs [--app APP] [--region REGION] [--limit N] [--next-token TOKEN]

    Shared configuration:
      --base-url URL     Override MARAITHON_BASE_URL
      --token TOKEN      Override MARAITHON_API_TOKEN
    """
  end
end
