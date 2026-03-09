ExUnit.start()

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

Ecto.Adapters.SQL.Sandbox.mode(Maraithon.Repo, :manual)
