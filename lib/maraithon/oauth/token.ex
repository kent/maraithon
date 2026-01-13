defmodule Maraithon.OAuth.Token do
  @moduledoc """
  Ecto schema for OAuth tokens.

  Stores OAuth tokens for external service providers (Google, etc.)
  Each user can have one token per provider.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: String.t(),
          provider: String.t(),
          access_token: binary(),
          refresh_token: binary() | nil,
          expires_at: DateTime.t() | nil,
          scopes: [String.t()],
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "oauth_tokens" do
    field :user_id, :string
    field :provider, :string
    field :access_token, :binary
    field :refresh_token, :binary
    field :expires_at, :utc_datetime
    field :scopes, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields ~w(user_id provider access_token)a
  @optional_fields ~w(refresh_token expires_at scopes metadata)a

  @doc """
  Creates a changeset for inserting or updating an OAuth token.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:user_id, min: 1, max: 255)
    |> validate_inclusion(:provider, ["google"])
    |> unique_constraint([:user_id, :provider])
  end

  @doc """
  Returns true if the token is expired or will expire within the given seconds.
  """
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, buffer_seconds \\ 60) do
    now = DateTime.utc_now()
    buffer = DateTime.add(now, buffer_seconds, :second)
    DateTime.compare(expires_at, buffer) == :lt
  end
end
