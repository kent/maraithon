defmodule Maraithon.HTTPTest do
  use ExUnit.Case, async: true

  alias Maraithon.HTTP

  describe "get/2" do
    test "successfully fetches JSON response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": "ok", "value": 42}))
      end)

      {:ok, response} = HTTP.get("http://localhost:#{bypass.port}/test")

      assert response["status"] == "ok"
      assert response["value"] == 42
    end

    test "returns raw body for non-JSON response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/html", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, "<html><body>Hello</body></html>")
      end)

      {:ok, response} = HTTP.get("http://localhost:#{bypass.port}/html")

      assert response == "<html><body>Hello</body></html>"
    end

    test "returns error for 401 unauthorized" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/unauthorized", fn conn ->
        Plug.Conn.resp(conn, 401, "Unauthorized")
      end)

      {:error, :unauthorized} = HTTP.get("http://localhost:#{bypass.port}/unauthorized")
    end

    test "returns error for 429 rate limited" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/rate-limited", fn conn ->
        Plug.Conn.resp(conn, 429, "Too many requests")
      end)

      {:error, {:rate_limited, body}} = HTTP.get("http://localhost:#{bypass.port}/rate-limited")
      assert body == "Too many requests"
    end

    test "returns error for other status codes" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/error", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      {:error, {:http_status, 500, body}} = HTTP.get("http://localhost:#{bypass.port}/error")
      assert body == "Internal Server Error"
    end

    test "passes headers" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/headers", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer token123"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"authenticated": true}))
      end)

      {:ok, response} = HTTP.get(
        "http://localhost:#{bypass.port}/headers",
        [{"Authorization", "Bearer token123"}]
      )

      assert response["authenticated"] == true
    end
  end

  describe "post_json/3" do
    test "posts JSON body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"name" => "test", "value" => 123}

        content_type = Plug.Conn.get_req_header(conn, "content-type")
        assert content_type == ["application/json"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"created": true}))
      end)

      {:ok, response} = HTTP.post_json(
        "http://localhost:#{bypass.port}/api",
        %{name: "test", value: 123}
      )

      assert response["created"] == true
    end
  end

  describe "post_form/3" do
    test "posts form-encoded body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/form", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body) == %{"username" => "test", "password" => "secret"}

        content_type = Plug.Conn.get_req_header(conn, "content-type")
        assert hd(content_type) =~ "application/x-www-form-urlencoded"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"logged_in": true}))
      end)

      {:ok, response} = HTTP.post_form(
        "http://localhost:#{bypass.port}/form",
        %{username: "test", password: "secret"}
      )

      assert response["logged_in"] == true
    end
  end

  describe "put_json/3" do
    test "sends PUT request with JSON body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "PUT", "/resource/1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"name" => "updated"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"updated": true}))
      end)

      {:ok, response} = HTTP.put_json(
        "http://localhost:#{bypass.port}/resource/1",
        %{name: "updated"}
      )

      assert response["updated"] == true
    end
  end

  describe "patch_json/3" do
    test "sends PATCH request with JSON body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "PATCH", "/resource/1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"status" => "active"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"patched": true}))
      end)

      {:ok, response} = HTTP.patch_json(
        "http://localhost:#{bypass.port}/resource/1",
        %{status: "active"}
      )

      assert response["patched"] == true
    end
  end

  describe "delete/2" do
    test "sends DELETE request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "/resource/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"deleted": true}))
      end)

      {:ok, response} = HTTP.delete("http://localhost:#{bypass.port}/resource/1")

      assert response["deleted"] == true
    end

    test "passes headers on delete" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "/resource/1", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer admin"]

        Plug.Conn.resp(conn, 204, "")
      end)

      {:ok, ""} = HTTP.delete(
        "http://localhost:#{bypass.port}/resource/1",
        [{"Authorization", "Bearer admin"}]
      )
    end
  end

  describe "module structure" do
    test "exports expected functions" do
      functions = Maraithon.HTTP.__info__(:functions)

      assert {:get, 1} in functions
      assert {:get, 2} in functions
      assert {:post_json, 2} in functions
      assert {:post_json, 3} in functions
      assert {:post_form, 2} in functions
      assert {:post_form, 3} in functions
      assert {:put_json, 2} in functions
      assert {:put_json, 3} in functions
      assert {:patch_json, 2} in functions
      assert {:patch_json, 3} in functions
      assert {:delete, 1} in functions
      assert {:delete, 2} in functions
    end
  end
end
