defmodule Maraithon.VaultTest do
  use ExUnit.Case, async: true

  alias Maraithon.Vault

  describe "encrypt/decrypt" do
    test "encrypts and decrypts data" do
      plaintext = "secret data"

      {:ok, ciphertext} = Vault.encrypt(plaintext)
      assert ciphertext != plaintext

      {:ok, decrypted} = Vault.decrypt(ciphertext)
      assert decrypted == plaintext
    end

    test "encrypts same plaintext to different ciphertext" do
      plaintext = "secret data"

      {:ok, ciphertext1} = Vault.encrypt(plaintext)
      {:ok, ciphertext2} = Vault.encrypt(plaintext)

      # Due to random IV, same plaintext should produce different ciphertext
      assert ciphertext1 != ciphertext2

      # But both should decrypt to the same plaintext
      {:ok, decrypted1} = Vault.decrypt(ciphertext1)
      {:ok, decrypted2} = Vault.decrypt(ciphertext2)
      assert decrypted1 == plaintext
      assert decrypted2 == plaintext
    end

    test "handles empty string" do
      {:ok, ciphertext} = Vault.encrypt("")
      {:ok, decrypted} = Vault.decrypt(ciphertext)
      assert decrypted == ""
    end

    test "handles binary data" do
      binary = :crypto.strong_rand_bytes(32)
      {:ok, ciphertext} = Vault.encrypt(binary)
      {:ok, decrypted} = Vault.decrypt(ciphertext)
      assert decrypted == binary
    end
  end
end
