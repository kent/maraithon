defmodule Maraithon.OAuth.TokenTest do
  use ExUnit.Case, async: true

  alias Maraithon.OAuth.Token

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        user_id: "user_123",
        provider: "google",
        access_token: "test_access_token"
      }

      changeset = Token.changeset(%Token{}, attrs)

      assert changeset.valid?
    end

    test "valid changeset with all fields" do
      attrs = %{
        user_id: "user_123",
        provider: "google",
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_at: DateTime.utc_now(),
        scopes: ["calendar.readonly", "gmail.readonly"],
        metadata: %{"extra" => "data"}
      }

      changeset = Token.changeset(%Token{}, attrs)

      assert changeset.valid?
    end

    test "requires user_id" do
      attrs = %{
        provider: "google",
        access_token: "test_access_token"
      }

      changeset = Token.changeset(%Token{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "requires provider" do
      attrs = %{
        user_id: "user_123",
        access_token: "test_access_token"
      }

      changeset = Token.changeset(%Token{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).provider
    end

    test "requires access_token" do
      attrs = %{
        user_id: "user_123",
        provider: "google"
      }

      changeset = Token.changeset(%Token{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).access_token
    end

    test "validates provider - google" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "google",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "validates provider - google with account suffix" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "google:founder@example.com",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "validates provider - slack with team_id" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "slack:T12345",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "validates provider - whatsapp" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "whatsapp",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "validates provider - linear" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "linear",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "validates provider - github" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "github",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "validates provider - notion" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "notion",
          access_token: "token"
        })

      assert changeset.valid?
    end

    test "rejects invalid provider" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "user_123",
          provider: "invalid_provider",
          access_token: "token"
        })

      refute changeset.valid?
      assert "invalid provider" in errors_on(changeset).provider
    end

    test "validates user_id length" do
      changeset =
        Token.changeset(%Token{}, %{
          user_id: "",
          provider: "google",
          access_token: "token"
        })

      refute changeset.valid?
    end
  end

  describe "expired?/2" do
    test "returns false when expires_at is nil" do
      token = %Token{expires_at: nil}

      refute Token.expired?(token)
    end

    test "returns true when token is expired" do
      token = %Token{expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)}

      assert Token.expired?(token)
    end

    test "returns true when token expires within buffer" do
      # Expires in 30 seconds, buffer is 60
      token = %Token{expires_at: DateTime.add(DateTime.utc_now(), 30, :second)}

      assert Token.expired?(token, 60)
    end

    test "returns false when token is not expired" do
      # Expires in 2 hours
      token = %Token{expires_at: DateTime.add(DateTime.utc_now(), 7200, :second)}

      refute Token.expired?(token)
    end

    test "respects custom buffer seconds" do
      # Expires in 120 seconds
      token = %Token{expires_at: DateTime.add(DateTime.utc_now(), 120, :second)}

      # Not expired with default 60 second buffer
      refute Token.expired?(token, 60)
      # Expired with 150 second buffer
      assert Token.expired?(token, 150)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
