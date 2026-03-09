defmodule MaraithonWeb.HealthControllerTest do
  use MaraithonWeb.ConnCase, async: false

  setup do
    previous_admin_auth = Application.get_env(:maraithon, :admin_auth)
    previous_api_auth = Application.get_env(:maraithon, :api_auth)

    on_exit(fn ->
      restore_env(:admin_auth, previous_admin_auth)
      restore_env(:api_auth, previous_api_auth)
    end)

    :ok
  end

  describe "GET /health" do
    test "returns ok status", %{conn: conn} do
      conn = get(conn, "/health")

      assert json_response(conn, 200) == %{"status" => "ok", "service" => "maraithon"}
    end
  end

  describe "GET /api/v1/health" do
    test "returns detailed health info", %{conn: conn} do
      conn = get(conn, "/api/v1/health")

      response = json_response(conn, 200)
      assert response["status"] in ["healthy", "unhealthy"]
      assert is_map(response["checks"])
      assert Map.has_key?(response, "version")
      assert Map.has_key?(response, "timestamp")
    end
  end

  describe "admin dashboard auth" do
    test "requires basic auth when configured", %{conn: conn} do
      Application.put_env(:maraithon, :admin_auth, username: "admin", password: "secret")

      conn = get(conn, "/settings")

      assert response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Application\""]
    end

    test "allows access with valid basic auth", %{conn: conn} do
      Application.put_env(:maraithon, :admin_auth, username: "admin", password: "secret")

      auth_value = "Basic " <> Base.encode64("admin:secret")

      conn =
        conn
        |> put_req_header("authorization", auth_value)
        |> get("/settings")

      assert html_response(conn, 200) =~ "Settings"
    end
  end

  describe "api token auth" do
    test "requires bearer token when configured", %{conn: conn} do
      Application.put_env(:maraithon, :api_auth, bearer_token: "api-secret")

      conn = get(conn, "/api/v1/health")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "allows bearer token when configured", %{conn: conn} do
      Application.put_env(:maraithon, :api_auth, bearer_token: "api-secret")

      conn =
        conn
        |> put_req_header("authorization", "Bearer api-secret")
        |> get("/api/v1/health")

      assert response = json_response(conn, 200)
      assert response["status"] in ["healthy", "unhealthy"]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)
end
