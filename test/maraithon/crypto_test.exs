defmodule Maraithon.CryptoTest do
  use ExUnit.Case, async: true

  alias Maraithon.Crypto

  describe "hmac_sha256/2" do
    test "generates correct HMAC-SHA256 signature" do
      secret = "test_secret"
      payload = "test payload"

      result = Crypto.hmac_sha256(secret, payload)

      # Verify it's a 64-character hex string (256 bits = 32 bytes = 64 hex chars)
      assert String.length(result) == 64
      assert Regex.match?(~r/^[a-f0-9]+$/, result)
    end

    test "same inputs produce same output" do
      secret = "my_secret"
      payload = "my payload"

      result1 = Crypto.hmac_sha256(secret, payload)
      result2 = Crypto.hmac_sha256(secret, payload)

      assert result1 == result2
    end

    test "different secrets produce different signatures" do
      payload = "same payload"

      sig1 = Crypto.hmac_sha256("secret1", payload)
      sig2 = Crypto.hmac_sha256("secret2", payload)

      refute sig1 == sig2
    end

    test "different payloads produce different signatures" do
      secret = "same_secret"

      sig1 = Crypto.hmac_sha256(secret, "payload1")
      sig2 = Crypto.hmac_sha256(secret, "payload2")

      refute sig1 == sig2
    end
  end

  describe "verify_hmac_sha256/3" do
    test "returns :ok for valid signature" do
      secret = "webhook_secret"
      payload = ~s({"event": "test"})
      signature = Crypto.hmac_sha256(secret, payload)

      assert :ok = Crypto.verify_hmac_sha256(secret, payload, signature)
    end

    test "returns :ok for valid signature with sha256= prefix" do
      secret = "webhook_secret"
      payload = ~s({"event": "test"})
      signature = "sha256=" <> Crypto.hmac_sha256(secret, payload)

      assert :ok = Crypto.verify_hmac_sha256(secret, payload, signature)
    end

    test "returns :ok for uppercase signature" do
      secret = "webhook_secret"
      payload = "test"
      signature = Crypto.hmac_sha256(secret, payload) |> String.upcase()

      assert :ok = Crypto.verify_hmac_sha256(secret, payload, signature)
    end

    test "returns error for invalid signature" do
      secret = "webhook_secret"
      payload = "test payload"
      invalid_signature = "invalid_signature_here"

      assert {:error, :invalid_signature} =
               Crypto.verify_hmac_sha256(secret, payload, invalid_signature)
    end

    test "returns error for tampered payload" do
      secret = "webhook_secret"
      original_payload = "original"
      signature = Crypto.hmac_sha256(secret, original_payload)
      tampered_payload = "tampered"

      assert {:error, :invalid_signature} =
               Crypto.verify_hmac_sha256(secret, tampered_payload, signature)
    end

    test "returns error for nil signature" do
      assert {:error, :missing_signature} =
               Crypto.verify_hmac_sha256("secret", "payload", nil)
    end

    test "returns error for wrong secret" do
      payload = "test"
      signature = Crypto.hmac_sha256("correct_secret", payload)

      assert {:error, :invalid_signature} =
               Crypto.verify_hmac_sha256("wrong_secret", payload, signature)
    end
  end

  describe "verify_slack_signature/4" do
    test "returns :ok for valid Slack signature" do
      secret = "slack_signing_secret"
      timestamp = to_string(System.system_time(:second))
      payload = ~s({"type": "event_callback"})

      # Build signature the way Slack does
      sig_basestring = "v0:#{timestamp}:#{payload}"

      expected =
        :crypto.mac(:hmac, :sha256, secret, sig_basestring)
        |> Base.encode16(case: :lower)

      signature = "v0=#{expected}"

      assert :ok = Crypto.verify_slack_signature(secret, timestamp, payload, signature)
    end

    test "returns error for expired timestamp" do
      secret = "slack_signing_secret"
      # 10 minutes ago (Slack allows 5 minutes)
      old_timestamp = to_string(System.system_time(:second) - 600)
      payload = "test"

      sig_basestring = "v0:#{old_timestamp}:#{payload}"

      expected =
        :crypto.mac(:hmac, :sha256, secret, sig_basestring)
        |> Base.encode16(case: :lower)

      signature = "v0=#{expected}"

      assert {:error, :timestamp_expired} =
               Crypto.verify_slack_signature(secret, old_timestamp, payload, signature)
    end

    test "returns error for invalid timestamp format" do
      assert {:error, :invalid_timestamp} =
               Crypto.verify_slack_signature("secret", "not_a_number", "payload", "v0=sig")
    end

    test "returns error for invalid signature" do
      timestamp = to_string(System.system_time(:second))

      assert {:error, :invalid_signature} =
               Crypto.verify_slack_signature("secret", timestamp, "payload", "v0=invalid")
    end

    test "returns error for tampered payload" do
      secret = "slack_signing_secret"
      timestamp = to_string(System.system_time(:second))
      original_payload = "original"

      sig_basestring = "v0:#{timestamp}:#{original_payload}"

      expected =
        :crypto.mac(:hmac, :sha256, secret, sig_basestring)
        |> Base.encode16(case: :lower)

      signature = "v0=#{expected}"

      assert {:error, :invalid_signature} =
               Crypto.verify_slack_signature(secret, timestamp, "tampered", signature)
    end

    test "accepts timestamp within 5 minute window" do
      secret = "slack_signing_secret"
      # 4 minutes ago (within the 5 minute window)
      recent_timestamp = to_string(System.system_time(:second) - 240)
      payload = "test"

      sig_basestring = "v0:#{recent_timestamp}:#{payload}"

      expected =
        :crypto.mac(:hmac, :sha256, secret, sig_basestring)
        |> Base.encode16(case: :lower)

      signature = "v0=#{expected}"

      assert :ok = Crypto.verify_slack_signature(secret, recent_timestamp, payload, signature)
    end
  end
end
