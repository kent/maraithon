ExUnit.start()

require Logger

Path.expand("_build/test/lib/*/ebin", File.cwd!())
|> Path.wildcard()
|> Enum.each(&Code.prepend_path/1)

case Application.ensure_all_started(:bypass) do
  {:ok, _} ->
    :ok

  {:error, {:bypass, {_reason, _path}}} ->
    bypass_ebin = Path.expand("_build/test/lib/bypass/ebin", File.cwd!())

    if File.exists?(Path.join(bypass_ebin, "bypass.app")) do
      Code.prepend_path(bypass_ebin)
      {:ok, _} = Application.ensure_all_started(:bypass)
    else
      raise "Bypass is not available in the current build path"
    end
end

repo_config =
  :maraithon
  |> Application.get_env(Maraithon.Repo, [])
  |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)

Application.put_env(:maraithon, Maraithon.Repo, repo_config)
Application.put_env(:maraithon, :start_background_workers, false)

{:ok, _} = Application.ensure_all_started(:maraithon)

if Maraithon.Repo.config()[:pool] != Ecto.Adapters.SQL.Sandbox do
  :ok = Application.stop(:maraithon)
  {:ok, _} = Application.ensure_all_started(:maraithon)
end

case Logger.add_backend(Maraithon.LogBufferBackend) do
  :ok -> :ok
  {:error, :already_present} -> :ok
  {:error, {:already_present, Maraithon.LogBufferBackend}} -> :ok
  {:error, {:already_started, Maraithon.LogBufferBackend}} -> :ok
end

Logger.configure_backend(
  Maraithon.LogBufferBackend,
  Application.get_env(:logger, Maraithon.LogBufferBackend, [])
)

Ecto.Adapters.SQL.Sandbox.mode(Maraithon.Repo, :manual)
