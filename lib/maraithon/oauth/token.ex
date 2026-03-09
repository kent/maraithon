defmodule Maraithon.OAuth.Token do
  @moduledoc """
  Ecto schema for OAuth tokens.

  Stores OAuth tokens for external service providers (Google, etc.)
  Each user can have one token per provider.

  ## Security

  Access tokens and refresh tokens are encrypted at rest using AES-256-GCM.
  The encryption key is derived from the `CLOAK_KEY` environment variable.
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
    # Tokens encrypted at rest
    field :access_token, Maraithon.Encrypted.Binary
    field :refresh_token, Maraithon.Encrypted.Binary
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
    |> validate_provider()
    |> unique_constraint([:user_id, :provider])
  end

  # Validates the provider field
  # Allowed formats: "google", "github", "notion", "slack:{team_id}", "whatsapp", "linear"
  defp validate_provider(changeset) do
    validate_change(changeset, :provider, fn :provider, provider ->
      cond do
        provider == "google" -> []
        provider == "github" -> []
        provider == "notion" -> []
        provider == "whatsapp" -> []
        provider == "linear" -> []
        String.starts_with?(provider, "slack:") -> []
        true -> [provider: "invalid provider"]
      end
    end)
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
