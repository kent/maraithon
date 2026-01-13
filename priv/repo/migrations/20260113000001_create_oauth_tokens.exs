defmodule Maraithon.Repo.Migrations.CreateOauthTokens do
  use Ecto.Migration

  def change do
    create table(:oauth_tokens) do
      add :user_id, :string, null: false
      add :provider, :string, null: false
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :expires_at, :utc_datetime
      add :scopes, {:array, :string}, default: []
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:oauth_tokens, [:user_id, :provider])
    create index(:oauth_tokens, [:provider])
    create index(:oauth_tokens, [:expires_at])
  end
end
