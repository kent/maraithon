defmodule Maraithon.Crypto do
  @moduledoc """
  Shared cryptographic utilities for webhook signature verification.

  ## Supported Signature Formats

  - **HMAC-SHA256 hex** - Used by GitHub, WhatsApp (Meta)
  - **Slack v0** - Slack's custom signature format
  - **Linear** - HMAC-SHA256 hex without prefix

  ## Usage

      # Verify GitHub/WhatsApp style signature
      Crypto.verify_hmac_sha256(secret, payload, signature)

      # Verify Slack signature
      Crypto.verify_slack_signature(secret, timestamp, payload, signature)
  """

  @doc """
  Verifies an HMAC-SHA256 signature.

  The signature should be the hex-encoded HMAC, optionally prefixed with "sha256=".

  ## Examples

      iex> Crypto.verify_hmac_sha256("secret", "payload", "sha256=abc123...")
      :ok | {:error, :invalid_signature}
  """
  @spec verify_hmac_sha256(String.t(), binary(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_hmac_sha256(_secret, _payload, nil) do
    {:error, :missing_signature}
  end

  def verify_hmac_sha256(secret, payload, signature) do
    # Strip optional "sha256=" prefix
    signature = strip_prefix(signature, "sha256=")

    expected =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc """
  Verifies a Slack request signature.

  Slack uses a custom format: `v0=HMAC-SHA256(secret, "v0:{timestamp}:{body}")`

  Also validates that the timestamp is within 5 minutes to prevent replay attacks.

  ## Examples

      iex> Crypto.verify_slack_signature(secret, "1234567890", body, "v0=abc123...")
      :ok | {:error, :invalid_signature} | {:error, :timestamp_expired}
  """
  @spec verify_slack_signature(String.t(), String.t(), binary(), String.t()) ::
          :ok | {:error, atom()}
  def verify_slack_signature(secret, timestamp, payload, signature) do
    now = System.system_time(:second)

    case Integer.parse(timestamp) do
      {ts, _} when abs(now - ts) < 300 ->
        sig_basestring = "v0:#{timestamp}:#{payload}"

        expected =
          :crypto.mac(:hmac, :sha256, secret, sig_basestring)
          |> Base.encode16(case: :lower)

        expected_sig = "v0=#{expected}"

        if Plug.Crypto.secure_compare(expected_sig, signature) do
          :ok
        else
          {:error, :invalid_signature}
        end

      {_, _} ->
        {:error, :timestamp_expired}

      :error ->
        {:error, :invalid_timestamp}
    end
  end

  @doc """
  Generates an HMAC-SHA256 signature.

  Returns the hex-encoded signature without any prefix.
  """
  @spec hmac_sha256(String.t(), binary()) :: String.t()
  def hmac_sha256(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp strip_prefix(string, prefix) do
    if String.starts_with?(String.downcase(string), String.downcase(prefix)) do
      String.slice(string, String.length(prefix)..-1//1)
    else
      string
    end
  end
end
