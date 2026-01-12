defmodule Maraithon.Repo do
  use Ecto.Repo,
    otp_app: :maraithon,
    adapter: Ecto.Adapters.Postgres
end
