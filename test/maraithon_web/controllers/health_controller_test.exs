defmodule MaraithonWeb.HealthControllerTest do
  use MaraithonWeb.ConnCase, async: true

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
end
