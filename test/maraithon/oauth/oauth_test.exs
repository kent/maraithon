defmodule Maraithon.OAuthTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth

  describe "store_tokens/3" do
    test "creates new token" do
      user_id = "user_#{System.unique_integer()}"

      token_data = %{
        access_token: "access_123",
        refresh_token: "refresh_123",
        expires_in: 3600,
        scopes: ["calendar.read"],
        metadata: %{email: "user@test.com"}
      }

      {:ok, token} = OAuth.store_tokens(user_id, "google", token_data)

      assert token.user_id == user_id
      assert token.provider == "google"
      assert token.access_token == "access_123"
      assert token.refresh_token == "refresh_123"
      assert token.scopes == ["calendar.read"]
      # Metadata keeps atom keys when passed with atoms
      assert token.metadata == %{email: "user@test.com"}
      assert token.expires_at != nil
    end

    test "updates existing token" do
      user_id = "user_#{System.unique_integer()}"
      initial_data = %{access_token: "old_token", refresh_token: "refresh_123"}
      {:ok, _} = OAuth.store_tokens(user_id, "google", initial_data)

      new_data = %{access_token: "new_token", refresh_token: "new_refresh"}
      {:ok, updated} = OAuth.store_tokens(user_id, "google", new_data)

      assert updated.access_token == "new_token"
      assert updated.refresh_token == "new_refresh"

      # Should not create a second token
      tokens = OAuth.list_user_tokens(user_id)
      assert length(tokens) == 1
    end

    test "preserves existing refresh token when update omits it" do
      user_id = "user_#{System.unique_integer()}"

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "old_token",
          refresh_token: "refresh_123",
          metadata: %{source: "initial"}
        })

      {:ok, updated} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "new_token",
          metadata: %{source: "updated"}
        })

      assert updated.access_token == "new_token"
      assert updated.refresh_token == "refresh_123"
      assert updated.metadata == %{source: "updated"}
    end

    test "stores token with expires_at" do
      user_id = "user_#{System.unique_integer()}"
      expires_at = DateTime.add(DateTime.utc_now(), 7200, :second)
      token_data = %{access_token: "access_123", expires_at: expires_at}

      {:ok, token} = OAuth.store_tokens(user_id, "google", token_data)

      assert DateTime.diff(token.expires_at, expires_at) == 0
    end

    test "stores token without expiration" do
      user_id = "user_#{System.unique_integer()}"
      token_data = %{access_token: "access_123"}

      {:ok, token} = OAuth.store_tokens(user_id, "google", token_data)

      assert token.expires_at == nil
    end

    test "stores exact provider without mutating existing google account providers" do
      user_id = "user_#{System.unique_integer()}"

      {:ok, _} =
        OAuth.store_tokens(user_id, "google:account@example.com", %{
          access_token: "account_token",
          refresh_token: "account_refresh"
        })

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "base_token",
          refresh_token: "base_refresh"
        })

      tokens = OAuth.list_user_tokens(user_id)
      providers = tokens |> Enum.map(& &1.provider) |> Enum.sort()

      assert providers == ["google", "google:account@example.com"]
    end
  end

  describe "get_token/2" do
    test "returns nil when token doesn't exist" do
      assert OAuth.get_token("nonexistent_user", "google") == nil
    end

    test "returns token when exists" do
      user_id = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user_id, "google", %{access_token: "test_token"})

      token = OAuth.get_token(user_id, "google")

      assert token != nil
      assert token.access_token == "test_token"
    end

    test "returns correct provider token" do
      user_id = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user_id, "google", %{access_token: "google_token"})
      {:ok, _} = OAuth.store_tokens(user_id, "linear", %{access_token: "linear_token"})

      google_token = OAuth.get_token(user_id, "google")
      linear_token = OAuth.get_token(user_id, "linear")

      assert google_token.access_token == "google_token"
      assert linear_token.access_token == "linear_token"
    end

    test "google provider lookup prefers healthy account token over reauth-required token" do
      user_id = "user_#{System.unique_integer()}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google:healthy@example.com", %{
          access_token: "healthy_access",
          refresh_token: "healthy_refresh"
        })

      {:ok, _} =
        OAuth.store_tokens(user_id, "google:stale@example.com", %{
          access_token: "stale_access",
          refresh_token: "stale_refresh"
        })

      {:ok, _} =
        ConnectedAccounts.mark_error(
          user_id,
          "google:stale@example.com",
          "oauth_reauth_required"
        )

      token = OAuth.get_token(user_id, "google")

      assert token.provider == "google:healthy@example.com"
      assert token.access_token == "healthy_access"
    end
  end

  describe "get_valid_access_token/2" do
    test "returns error when no token exists" do
      assert {:error, :no_token} = OAuth.get_valid_access_token("nonexistent", "google")
    end

    test "returns access_token when not expired" do
      user_id = "user_#{System.unique_integer()}"
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "valid_token",
          expires_at: expires_at
        })

      {:ok, token} = OAuth.get_valid_access_token(user_id, "google")

      assert token == "valid_token"
    end

    test "returns access_token when no expiration set" do
      user_id = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user_id, "google", %{access_token: "no_expiry_token"})

      {:ok, token} = OAuth.get_valid_access_token(user_id, "google")

      assert token == "no_expiry_token"
    end

    test "returns reauth_required when account is flagged for reconnect" do
      user_id = "user_#{System.unique_integer()}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google:needs-reauth@example.com", %{
          access_token: "expired_token",
          refresh_token: "refresh_token",
          expires_at: expires_at
        })

      {:ok, _} =
        ConnectedAccounts.mark_error(
          user_id,
          "google:needs-reauth@example.com",
          "oauth_reauth_required"
        )

      assert {:error, :reauth_required} =
               OAuth.get_valid_access_token(user_id, "google:needs-reauth@example.com")
    end
  end

  describe "refresh_if_expired/2" do
    test "returns error when no token exists" do
      assert {:error, :no_token} = OAuth.refresh_if_expired("nonexistent", "google")
    end

    test "returns existing token when not expired" do
      user_id = "user_#{System.unique_integer()}"
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, stored} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "valid_token",
          expires_at: expires_at
        })

      {:ok, token} = OAuth.refresh_if_expired(user_id, "google")

      assert token.id == stored.id
    end

    test "returns error when expired without refresh_token" do
      user_id = "user_#{System.unique_integer()}"
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "expired_token",
          expires_at: expires_at
        })

      {:error, :no_refresh_token} = OAuth.refresh_if_expired(user_id, "google")
    end
  end

  describe "refresh_if_expiring/3" do
    test "returns error when no token exists" do
      assert {:error, :no_token} = OAuth.refresh_if_expiring("nonexistent", "google", 300)
    end

    test "refreshes token before expiry when in lookahead window" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        token_url: "http://localhost:#{bypass.port}/token",
        client_id: "test_client",
        client_secret: "test_secret"
      )

      on_exit(fn ->
        Application.delete_env(:maraithon, :google)
      end)

      user_id = "user_#{System.unique_integer()}"
      expires_soon = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "expiring_token",
          refresh_token: "refresh_token_123",
          expires_at: expires_soon
        })

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_refreshed_token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      assert {:ok, refreshed} = OAuth.refresh_if_expiring(user_id, "google", 300)
      assert refreshed.access_token == "new_refreshed_token"
    end

    test "marks connected account as error when Google refresh token is invalid" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        token_url: "http://localhost:#{bypass.port}/token",
        client_id: "test_client",
        client_secret: "test_secret"
      )

      on_exit(fn ->
        Application.delete_env(:maraithon, :google)
      end)

      user_id = "user_#{System.unique_integer()}@example.com"
      Repo.insert!(%Maraithon.Accounts.User{id: user_id, email: user_id})
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "old_token",
          refresh_token: "invalid_refresh",
          expires_at: expired_at
        })

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Token has been expired or revoked."
          })
        )
      end)

      assert {:error, _reason} = OAuth.refresh_if_expiring(user_id, "google", 300)

      account = ConnectedAccounts.get(user_id, "google")
      assert account.status == "error"
      assert get_in(account.metadata, ["last_error", "reason"]) == "oauth_reauth_required"
    end
  end

  describe "revoke/2" do
    test "returns error when no token exists" do
      assert {:error, :no_token} = OAuth.revoke("nonexistent", "google")
    end

    test "deletes token from database" do
      user_id = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user_id, "linear", %{access_token: "token"})

      {:ok, _} = OAuth.revoke(user_id, "linear")

      assert OAuth.get_token(user_id, "linear") == nil
    end
  end

  describe "list_user_tokens/1" do
    test "returns empty list when no tokens" do
      assert OAuth.list_user_tokens("nonexistent") == []
    end

    test "returns all tokens for user" do
      user_id = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user_id, "google", %{access_token: "google_token"})
      {:ok, _} = OAuth.store_tokens(user_id, "linear", %{access_token: "linear_token"})

      tokens = OAuth.list_user_tokens(user_id)

      assert length(tokens) == 2
      providers = Enum.map(tokens, & &1.provider) |> Enum.sort()
      assert providers == ["google", "linear"]
    end

    test "does not return other users tokens" do
      user1 = "user_#{System.unique_integer()}"
      user2 = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user1, "google", %{access_token: "user1_token"})
      {:ok, _} = OAuth.store_tokens(user2, "google", %{access_token: "user2_token"})

      tokens = OAuth.list_user_tokens(user1)

      assert length(tokens) == 1
      assert hd(tokens).user_id == user1
    end
  end

  describe "list_provider_tokens/1" do
    test "returns empty list when no tokens" do
      assert OAuth.list_provider_tokens("nonexistent_provider") == []
    end

    test "returns all tokens for whatsapp provider" do
      user1 = "user_#{System.unique_integer()}"
      user2 = "user_#{System.unique_integer()}"

      {:ok, _} = OAuth.store_tokens(user1, "whatsapp", %{access_token: "token1"})
      {:ok, _} = OAuth.store_tokens(user2, "whatsapp", %{access_token: "token2"})

      tokens = OAuth.list_provider_tokens("whatsapp")

      # At least 2 tokens for whatsapp
      assert length(tokens) >= 2
    end
  end

  describe "list_expiring_tokens/1" do
    test "returns empty list when no expiring tokens" do
      assert OAuth.list_expiring_tokens(300) == []
    end

    test "returns tokens expiring within timeframe" do
      user_id = "user_#{System.unique_integer()}"
      # Token expiring in 60 seconds
      expires_soon = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "expiring_token",
          refresh_token: "refresh_token",
          expires_at: expires_soon
        })

      tokens = OAuth.list_expiring_tokens(300)

      assert length(tokens) >= 1
      expiring_token = Enum.find(tokens, &(&1.user_id == user_id))
      assert expiring_token != nil
    end

    test "does not return tokens without refresh_token" do
      user_id = "user_#{System.unique_integer()}"
      expires_soon = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "expiring_no_refresh",
          expires_at: expires_soon
        })

      tokens = OAuth.list_expiring_tokens(300)
      expiring_token = Enum.find(tokens, &(&1.user_id == user_id))

      # Should not be in the list since no refresh token
      assert expiring_token == nil
    end
  end

  describe "get_valid_access_token/2 - expired token with refresh" do
    test "returns error when expired without refresh token" do
      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "expired_token_no_refresh",
          expires_at: expired_at
        })

      # Should return error since no refresh token
      assert {:error, :no_refresh_token} = OAuth.get_valid_access_token(user_id, "google")
    end

    test "attempts refresh when expired with refresh token" do
      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "expired_token_with_refresh",
          refresh_token: "refresh_token_123",
          expires_at: expired_at
        })

      # Should attempt refresh (will fail due to no real API)
      result = OAuth.get_valid_access_token(user_id, "google")
      # Returns error from API call
      assert match?({:error, _}, result)
    end
  end

  describe "update token metadata" do
    test "preserves metadata when updating token" do
      user_id = "user_#{System.unique_integer()}"

      initial_data = %{
        access_token: "initial_token",
        metadata: %{email: "user@example.com", team_id: "T123"}
      }

      # Slack requires format slack:{team_id}
      {:ok, _} = OAuth.store_tokens(user_id, "slack:T123", initial_data)

      # Update with new token but same metadata structure
      update_data = %{
        access_token: "new_token",
        metadata: %{email: "user@example.com", team_id: "T123", extra: "data"}
      }

      {:ok, updated} = OAuth.store_tokens(user_id, "slack:T123", update_data)

      assert updated.access_token == "new_token"
      assert updated.metadata.extra == "data"
    end
  end

  describe "refresh_if_expired/2 - non-google provider" do
    test "returns error for linear provider (no refresh support)" do
      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "linear", %{
          access_token: "expired_token",
          refresh_token: "refresh_token",
          expires_at: expired_at
        })

      # Linear tokens don't have refresh support implemented
      assert {:error, {:unknown_provider, "linear"}} = OAuth.refresh_if_expired(user_id, "linear")
    end

    test "returns error for whatsapp provider (no refresh support)" do
      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "whatsapp", %{
          access_token: "expired_token",
          refresh_token: "refresh_token",
          expires_at: expired_at
        })

      # WhatsApp tokens don't have refresh support implemented
      assert {:error, {:unknown_provider, "whatsapp"}} =
               OAuth.refresh_if_expired(user_id, "whatsapp")
    end
  end

  describe "revoke/2 - google provider" do
    test "attempts to revoke google token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        revoke_url: "http://localhost:#{bypass.port}/revoke"
      )

      user_id = "user_#{System.unique_integer()}"
      {:ok, _} = OAuth.store_tokens(user_id, "google", %{access_token: "google_token_to_revoke"})

      # Mock the revoke endpoint
      Bypass.expect_once(bypass, "POST", "/revoke", fn conn ->
        conn
        |> Plug.Conn.resp(200, "")
      end)

      {:ok, _} = OAuth.revoke(user_id, "google")

      # Verify token is deleted
      assert OAuth.get_token(user_id, "google") == nil

      Application.delete_env(:maraithon, :google)
    end
  end

  describe "get_valid_access_token/2 - refresh success" do
    test "refreshes expired google token successfully" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        token_url: "http://localhost:#{bypass.port}/token",
        client_id: "test_client",
        client_secret: "test_secret"
      )

      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "old_expired_token",
          refresh_token: "valid_refresh_token",
          expires_at: expired_at,
          scopes: ["calendar.read"],
          metadata: %{test: "data"}
        })

      # Mock the token refresh endpoint
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_refreshed_token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      {:ok, token} = OAuth.get_valid_access_token(user_id, "google")

      assert token == "new_refreshed_token"

      # Verify token was updated in DB
      stored_token = OAuth.get_token(user_id, "google")
      assert stored_token.access_token == "new_refreshed_token"

      Application.delete_env(:maraithon, :google)
    end

    test "returns error when refresh fails" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        token_url: "http://localhost:#{bypass.port}/token",
        client_id: "test_client",
        client_secret: "test_secret"
      )

      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "old_token",
          refresh_token: "invalid_refresh",
          expires_at: expired_at
        })

      # Mock failed token refresh
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Token has been revoked"
          })
        )
      end)

      result = OAuth.get_valid_access_token(user_id, "google")

      # Should return an error
      assert match?({:error, _}, result)

      Application.delete_env(:maraithon, :google)
    end
  end

  describe "get_valid_access_token/2 - notaui refresh" do
    test "refreshes expired notaui token successfully" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :notaui,
        token_url: "http://localhost:#{bypass.port}/oauth/token",
        client_id: "test_client",
        client_secret: "test_secret",
        redirect_uri: "http://localhost:4000/auth/notaui/callback"
      )

      user_id = "user_#{System.unique_integer()}"
      expired_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        OAuth.store_tokens(user_id, "notaui", %{
          access_token: "old_notaui_token",
          refresh_token: "valid_refresh_token",
          expires_at: expired_at,
          scopes: ["tasks:read"],
          metadata: %{"mcp_url" => "https://api.notaui.com/mcp"}
        })

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Basic dGVzdF9jbGllbnQ6dGVzdF9zZWNyZXQ="]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "valid_refresh_token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_notaui_token",
            "refresh_token" => "new_notaui_refresh",
            "expires_in" => 3600,
            "scope" => "tasks:read tasks:write",
            "token_type" => "Bearer"
          })
        )
      end)

      assert {:ok, token} = OAuth.get_valid_access_token(user_id, "notaui")
      assert token == "new_notaui_token"

      stored_token = OAuth.get_token(user_id, "notaui")
      assert stored_token.access_token == "new_notaui_token"
      assert stored_token.refresh_token == "new_notaui_refresh"
      assert "tasks:write" in (stored_token.scopes || [])

      Application.delete_env(:maraithon, :notaui)
    end
  end
end
