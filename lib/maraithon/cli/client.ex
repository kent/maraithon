defmodule Maraithon.CLI.Client do
  @moduledoc """
  Thin Req-based client for operator CLI tasks.
  """

  @default_timeout_ms 30_000

  @type options :: Keyword.t()
  @type response :: {:ok, term()} | {:error, term()}

  def get(path, opts \\ []), do: request(:get, path, opts)
  def post(path, opts \\ []), do: request(:post, path, opts)
  def patch(path, opts \\ []), do: request(:patch, path, opts)
  def delete(path, opts \\ []), do: request(:delete, path, opts)

  def request(method, path, opts \\ []) when method in [:get, :post, :patch, :delete] do
    with :ok <- ensure_req_started(),
         {:ok, url} <- build_url(path, opts),
         {:ok, token} <- fetch_token(opts) do
      request_opts =
        [
          method: method,
          url: url,
          headers: [{"authorization", "Bearer " <> token}],
          receive_timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        ]
        |> maybe_put_json(Keyword.get(opts, :json))
        |> maybe_put_params(Keyword.get(opts, :params))

      case Req.request(request_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, exception} ->
          {:error, {:request_failed, exception}}
      end
    end
  end

  defp ensure_req_started do
    case Application.ensure_all_started(:req) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:startup_failed, reason}}
    end
  end

  defp build_url(path, opts) when is_binary(path) do
    with {:ok, base_url} <- fetch_base_url(opts) do
      {:ok, base_url <> normalize_path(path)}
    end
  end

  defp fetch_base_url(opts) do
    case Keyword.get(opts, :base_url) || System.get_env("MARAITHON_BASE_URL") do
      nil ->
        {:error, "Missing base URL. Set --base-url or MARAITHON_BASE_URL."}

      "" ->
        {:error, "Missing base URL. Set --base-url or MARAITHON_BASE_URL."}

      base_url ->
        {:ok, String.trim_trailing(base_url, "/")}
    end
  end

  defp fetch_token(opts) do
    case Keyword.get(opts, :token) || System.get_env("MARAITHON_API_TOKEN") do
      nil ->
        {:error, "Missing API token. Set --token or MARAITHON_API_TOKEN."}

      "" ->
        {:error, "Missing API token. Set --token or MARAITHON_API_TOKEN."}

      token ->
        {:ok, token}
    end
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  defp maybe_put_params(opts, nil), do: opts
  defp maybe_put_params(opts, params), do: Keyword.put(opts, :params, params)

  defp normalize_path("/" <> _rest = path), do: path
  defp normalize_path(path), do: "/" <> path
end
