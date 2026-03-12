defmodule Maraithon.OAuth.NotauiTest do
  use ExUnit.Case, async: false

  alias Maraithon.OAuth.Notaui

  setup do
    Application.put_env(:maraithon, :notaui,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/notaui/callback"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :notaui, [])
    end)

    :ok
  end

  describe "default_scopes/0" do
    test "returns default scopes" do
      assert "tasks:read" in Notaui.default_scopes()
      assert "tasks:write" in Notaui.default_scopes()
      assert "projects:read" in Notaui.default_scopes()
      assert "projects:write" in Notaui.default_scopes()
      assert "tags:write" in Notaui.default_scopes()
    end
  end

  describe "authorize_url/3" do
    test "generates valid authorization URL with PKCE" do
      url =
        Notaui.authorize_url(
          Notaui.default_scopes(),
          "test_state",
          code_challenge: "pkce_challenge"
        )

      assert url =~ "https://api.notaui.com/oauth/authorize?"
      assert url =~ "client_id=test_client_id"
      assert url =~ "redirect_uri="
      assert url =~ "response_type=code"
      assert url =~ "state=test_state"
      assert url =~ "code_challenge=pkce_challenge"
      assert url =~ "code_challenge_method=S256"
    end
  end

  describe "exchange_code/2" do
    test "successfully exchanges code for tokens" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :notaui,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/auth/notaui/callback",
        token_url: "http://localhost:#{bypass.port}/oauth/token"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        assert {"authorization", "Basic dGVzdF9jbGllbnRfaWQ6dGVzdF9jbGllbnRfc2VjcmV0"} in conn.req_headers
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "authorization_code"
        assert params["code"] == "valid_code"
        assert params["redirect_uri"] == "http://localhost:4000/auth/notaui/callback"
        assert params["code_verifier"] == "pkce_verifier"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "notaui_access_token",
            "refresh_token" => "notaui_refresh_token",
            "expires_in" => 3600,
            "scope" => "tasks:read tasks:write",
            "token_type" => "Bearer"
          })
        )
      end)

      {:ok, tokens} = Notaui.exchange_code("valid_code", code_verifier: "pkce_verifier")

      assert tokens.access_token == "notaui_access_token"
      assert tokens.refresh_token == "notaui_refresh_token"
      assert tokens.expires_in == 3600
      assert tokens.scope == "tasks:read tasks:write"
    end
  end

  describe "refresh_token/1" do
    test "refreshes a notaui access token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :notaui,
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        token_url: "http://localhost:#{bypass.port}/oauth/token"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "refresh-token-1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "notaui_refreshed",
            "refresh_token" => "refresh-token-2",
            "expires_in" => 7200,
            "scope" => "tasks:read tasks:write",
            "token_type" => "Bearer"
          })
        )
      end)

      assert {:ok, tokens} = Notaui.refresh_token("refresh-token-1")
      assert tokens.access_token == "notaui_refreshed"
      assert tokens.refresh_token == "refresh-token-2"
      assert tokens.expires_in == 7200
    end
  end
end
