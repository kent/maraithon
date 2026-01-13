# ==============================================================================
# CacheRawBody Plug Unit Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The CacheRawBody plug is critical for webhook signature verification.
# When services like GitHub, Slack, or WhatsApp send webhooks, they include
# a signature calculated from the raw HTTP body. To verify these signatures,
# we need the EXACT bytes that were sent - not a parsed/re-encoded version.
#
# Without this plug:
# 1. Webhook arrives with signature: HMAC-SHA256(raw_body, secret)
# 2. Phoenix parses JSON body automatically
# 3. We try to re-encode JSON to verify signature
# 4. Re-encoded JSON has different byte order, spacing, etc.
# 5. Signature verification FAILS
# 6. Legitimate webhooks get rejected!
#
# With this plug:
# 1. Webhook arrives with signature: HMAC-SHA256(raw_body, secret)
# 2. CacheRawBody intercepts and saves exact bytes to conn.assigns[:raw_body]
# 3. Phoenix parses JSON body normally
# 4. We verify signature using saved raw bytes
# 5. Signature matches!
# 6. Webhook is processed correctly
#
# Example: GitHub Webhook Flow
#
#   GitHub sends:
#   POST /webhooks/github
#   X-Hub-Signature-256: sha256=abc123...
#   Body: {"action":"opened","pull_request":{...}}
#
#   Our server:
#   1. CacheRawBody saves exact bytes
#   2. JSON parser reads body
#   3. WebhookController uses raw bytes to verify signature
#   4. If valid, event is published to agents
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the CacheRawBody plug breaks, users experience:
# - All webhook integrations failing
# - GitHub PR notifications not reaching agents
# - Slack messages not being processed
# - WhatsApp messages being rejected
# - Linear issue updates being lost
# - "Invalid signature" errors in logs
#
# This is a critical security and functionality component!
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the CacheRawBody plug which implements a custom
# body reader for Plug connections. It intercepts the body reading process
# to cache the raw bytes before they're parsed.
#
# How Plug Body Reading Works:
# ----------------------------
#
#   Normal Flow (without CacheRawBody):
#   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
#   │   Request   │────►│  Plug.Conn  │────►│ JSON Parser │
#   │   (bytes)   │     │ read_body/2 │     │             │
#   └─────────────┘     └─────────────┘     └─────────────┘
#                                                  │
#                                                  ▼
#                                           (bytes consumed,
#                                            raw form lost)
#
#   With CacheRawBody:
#   ┌─────────────┐     ┌───────────────┐     ┌─────────────┐
#   │   Request   │────►│ CacheRawBody  │────►│ JSON Parser │
#   │   (bytes)   │     │  read_body/2  │     │             │
#   └─────────────┘     └───────────────┘     └─────────────┘
#                              │
#                              ▼
#                       conn.assigns[:raw_body]
#                       (exact bytes preserved)
#
# Implementation:
# ---------------
# The plug provides a custom `read_body/2` function that:
# 1. Reads all chunks from the request body
# 2. Concatenates them into a single binary
# 3. Stores the binary in conn.assigns[:raw_body]
# 4. Returns the body for further processing
#
# This is configured in the router with:
#   plug Plug.Parsers, body_reader: {CacheRawBody, :read_body, []}
#
# Test Categories:
# ----------------
# - Small Bodies: Typical JSON payloads
# - Large Bodies: Multi-kilobyte payloads (chunked reading)
# - Empty Bodies: Edge case handling
# - JSON Bodies: Verify JSON-specific content preserved
# - Byte Preservation: Cryptographic verification of exact bytes
#
# Dependencies:
# -------------
# - Plug.Test (for creating test connections)
# - MaraithonWeb.Plugs.CacheRawBody (the plug being tested)
# - :crypto (for SHA256 hash verification)
#
# ==============================================================================

defmodule MaraithonWeb.Plugs.CacheRawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias MaraithonWeb.Plugs.CacheRawBody

  # ============================================================================
  # READ BODY TESTS
  # ============================================================================
  #
  # These tests verify the read_body/2 function correctly reads and caches
  # the raw HTTP body for signature verification.
  # ============================================================================

  describe "read_body/2" do
    @doc """
    Verifies that small JSON bodies are read and cached correctly.
    This is the most common case - typical webhook payloads are a few KB.
    """
    test "caches raw body in assigns for small bodies" do
      body = ~s({"key": "value"})
      conn = conn(:post, "/test", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    @doc """
    Verifies that larger bodies are read completely.
    Plug reads bodies in chunks, so we need to verify all chunks are
    concatenated correctly. 1000 bytes tests chunk handling.
    """
    test "reads entire body" do
      body = String.duplicate("x", 1000)
      conn = conn(:post, "/test", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    @doc """
    Verifies that empty bodies are handled gracefully.
    Some webhooks (like verification challenges) may have empty bodies.
    """
    test "handles empty body" do
      conn = conn(:post, "/test", "")

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == ""
      assert conn.assigns[:raw_body] == ""
    end

    @doc """
    Verifies that JSON bodies with various data types are preserved.
    Tests strings, numbers, arrays, and nested objects.
    """
    test "handles JSON body" do
      body = Jason.encode!(%{name: "test", values: [1, 2, 3]})
      conn = conn(:post, "/test", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    @doc """
    CRITICAL: Verifies exact byte preservation for signature verification.

    This test uses SHA256 hashing to prove the exact bytes are preserved.
    Even a single byte difference (like a changed escape sequence) would
    cause the hash to differ, which would cause signature verification
    to fail in production.

    The test uses a body with unicode escapes to catch potential
    encoding/decoding issues that could corrupt the raw bytes.
    """
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
