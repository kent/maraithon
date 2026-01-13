defmodule MaraithonWeb.Plugs.CacheRawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias MaraithonWeb.Plugs.CacheRawBody

  describe "read_body/2" do
    test "caches raw body in assigns for small bodies" do
      body = ~s({"key": "value"})
      conn = conn(:post, "/test", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    test "reads entire body" do
      body = String.duplicate("x", 1000)
      conn = conn(:post, "/test", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    test "handles empty body" do
      conn = conn(:post, "/test", "")

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == ""
      assert conn.assigns[:raw_body] == ""
    end

    test "handles JSON body" do
      body = Jason.encode!(%{name: "test", values: [1, 2, 3]})
      conn = conn(:post, "/test", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    test "preserves exact bytes for signature verification" do
      # Create a body with specific byte representation
      body = ~s({"message":"Hello\\u0000World"})
      conn = conn(:post, "/test", body)

      {:ok, read_body, _conn} = CacheRawBody.read_body(conn, [])

      # Ensure exact bytes are preserved
      assert byte_size(read_body) == byte_size(body)
      assert :crypto.hash(:sha256, read_body) == :crypto.hash(:sha256, body)
    end
  end
end
