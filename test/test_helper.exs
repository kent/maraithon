ExUnit.start()
{:ok, _} = Application.ensure_all_started(:bypass)
Ecto.Adapters.SQL.Sandbox.mode(Maraithon.Repo, :manual)
