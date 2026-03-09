defmodule Maraithon.Repo.Migrations.AddUserAuthAndConnectedAccountModels do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :string, primary_key: true
      add :email, :string, null: false
      add :is_admin, :boolean, null: false, default: false
      add :confirmed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create index(:users, [:is_admin])

    create table(:user_magic_links) do
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      add :sent_to_email, :string, null: false
      add :ip, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_magic_links, [:user_id])
    create index(:user_magic_links, [:expires_at])
    create unique_index(:user_magic_links, [:token_hash])

    create table(:user_sessions) do
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :ip, :string
      add :user_agent, :string
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_sessions, [:user_id])
    create index(:user_sessions, [:expires_at])
    create unique_index(:user_sessions, [:token_hash])

    create table(:connected_accounts) do
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_account_id, :string
      add :status, :string, null: false, default: "disconnected"
      add :access_token, :binary
      add :refresh_token, :binary
      add :expires_at, :utc_datetime_usec
      add :scopes, {:array, :string}, default: []
      add :metadata, :map, default: %{}
      add :connected_at, :utc_datetime_usec
      add :last_refreshed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connected_accounts, [:user_id, :provider])
    create index(:connected_accounts, [:provider])
    create index(:connected_accounts, [:status])

    alter table(:agents) do
      add :user_id, :string
    end

    create index(:agents, [:user_id])
  end
end
