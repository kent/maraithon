defmodule Mix.Tasks.Maraithon.Connection do
  use Mix.Task

  alias Maraithon.CLI.Client

  @shortdoc "Inspect and manage Maraithon OAuth connections over the production API"

  @switches [
    base_url: :string,
    token: :string,
    user_id: :string,
    service: :string
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
        call_and_print(:get, "/api/v1/admin/connections", with_user_id(opts))

      ["disconnect", provider] ->
        call_and_print(
          :delete,
          "/api/v1/admin/connections/#{provider}",
          with_user_id(opts)
        )

      ["auth-url", provider] ->
        print_auth_url(provider, opts)

      ["help"] ->
        Mix.shell().info(usage())

      _ ->
        Mix.raise(usage())
    end
  end

  defp print_auth_url(provider, opts) do
    case Client.get("/api/v1/admin/connections", client_opts(with_user_id(opts))) do
      {:ok, %{"providers" => providers}} ->
        provider_data =
          Enum.find(providers, fn candidate -> candidate["provider"] == provider end) ||
            Mix.raise("Unknown provider #{provider}")

        auth_url =
          case opts[:service] do
            nil ->
              provider_data["connect_url"]

            service ->
              (provider_data["services"] || [])
              |> Enum.find(fn candidate -> candidate["id"] == service end)
              |> case do
                nil -> Mix.raise("Unknown service #{service} for provider #{provider}")
                service_data -> service_data["connect_url"]
              end
          end

        Mix.shell().info(auth_url)

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

  defp call_and_print(method, path, opts) do
    response =
      case method do
        :get -> Client.get(path, client_opts(opts))
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

  defp with_user_id(opts) do
    case opts[:user_id] do
      nil -> opts
      "" -> opts
      user_id -> Keyword.put(opts, :params, %{"user_id" => user_id})
    end
  end

  defp client_opts(opts) do
    []
    |> maybe_put_opt(:base_url, opts[:base_url])
    |> maybe_put_opt(:token, opts[:token])
    |> maybe_put_opt(:params, opts[:params])
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, %{} = map) when map_size(map) == 0, do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp render_body(body) when is_binary(body), do: body
  defp render_body(body), do: Jason.encode!(body, pretty: true)

  defp usage do
    """
    Usage:
      mix maraithon.connection list [--user-id USER_ID]
      mix maraithon.connection auth-url PROVIDER [--user-id USER_ID] [--service SERVICE]
      mix maraithon.connection disconnect PROVIDER [--user-id USER_ID]

    Shared configuration:
      --base-url URL     Override MARAITHON_BASE_URL
      --token TOKEN      Override MARAITHON_API_TOKEN
    """
  end
end
