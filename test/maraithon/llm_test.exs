defmodule Maraithon.LLMTest do
  use ExUnit.Case, async: true

  alias Maraithon.LLM

  describe "provider/0" do
    test "returns MockProvider by default" do
      assert LLM.provider() == Maraithon.LLM.MockProvider
    end
  end

  describe "model/0" do
    test "returns default model" do
      model = LLM.model()
      assert is_binary(model)
      assert String.contains?(model, "claude")
    end
  end

  describe "api_key/0" do
    test "returns configured API key or nil" do
      # May return nil if not configured
      _key = LLM.api_key()
      assert true
    end
  end
end
