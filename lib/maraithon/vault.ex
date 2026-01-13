defmodule Maraithon.Vault do
  @moduledoc """
  Cloak vault for encrypting sensitive data at rest.

  This vault is used to encrypt OAuth tokens and other sensitive data
  stored in the database.

  ## Configuration

  Set the encryption key via environment variable:

      export CLOAK_KEY="base64-encoded-32-byte-key"

  Generate a key with:

      :crypto.strong_rand_bytes(32) |> Base.encode64()

  ## Usage

  The vault is automatically used by encrypted Ecto types defined in
  `Maraithon.Encrypted` modules.
  """

  use Cloak.Vault, otp_app: :maraithon

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: decode_env!("CLOAK_KEY"), iv_length: 12
        }
      )

    {:ok, config}
  end

  defp decode_env!(var) do
    case System.get_env(var) do
      nil ->
        # Check if we should allow fallback (dev/test only)
        if Application.get_env(:maraithon, :allow_insecure_vault, false) do
          # Development/test fallback - NOT SECURE
          # Use a deterministic key so encryption is consistent across restarts
          :crypto.hash(:sha256, "maraithon-dev-key-do-not-use-in-production")
        else
          raise """
          Environment variable #{var} is not set.

          Generate a key with:
            :crypto.strong_rand_bytes(32) |> Base.encode64()

          Then set it:
            export #{var}="your-base64-key"

          For development/testing, you can set allow_insecure_vault: true in config.
          """
        end

      value ->
        Base.decode64!(value)
    end
  end
end
