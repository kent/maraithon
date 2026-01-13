defmodule MaraithonWeb.EventControllerTest do
  use MaraithonWeb.ConnCase, async: true

  describe "POST /api/v1/events" do
    test "publishes event to topic", %{conn: conn} do
      conn =
        post(conn, "/api/v1/events", %{
          topic: "test_topic",
          payload: %{foo: "bar"}
        })

      response = json_response(conn, 202)
      assert response["status"] == "published"
      assert response["topic"] == "test_topic"
    end

    test "returns error when topic is missing", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{payload: %{foo: "bar"}})

      assert json_response(conn, 400)["error"] == "topic is required"
    end

    test "returns error when topic is empty string", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: "", payload: %{}})

      assert json_response(conn, 400)["error"] == "topic is required"
    end

    test "uses empty payload when not provided", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: "test_topic"})

      response = json_response(conn, 202)
      assert response["status"] == "published"
    end
  end

  describe "GET /api/v1/events/topics" do
    test "returns not implemented message", %{conn: conn} do
      conn = get(conn, "/api/v1/events/topics")

      response = json_response(conn, 200)
      assert response["message"] =~ "not yet implemented"
    end
  end
end
