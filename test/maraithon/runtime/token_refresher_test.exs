defmodule Maraithon.Runtime.TokenRefresherTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.OAuth
  alias Maraithon.Runtime.TokenRefresher

  test "refreshes tokens that are close to expiry" do
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

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "expiring_access_token",
        refresh_token: "valid_refresh_token",
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

    start_supervised!(
      {TokenRefresher,
       name: nil,
       observer: self(),
       interval_ms: :timer.minutes(5),
       lookahead_seconds: 300,
       batch_size: 10,
       initial_delay_ms: 10}
    )

    assert_receive {:oauth_refresh_cycle, %{attempted: 1, refreshed: 1, failed: 0}}, 2_000

    token = OAuth.get_token(user_id, "google")
    assert token.access_token == "new_refreshed_token"
  end
end
