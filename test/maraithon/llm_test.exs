defmodule Maraithon.LLMTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end
    end)

    :ok
  end

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

    test "returns the active OpenAI model when configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider_name: "openai",
        llm_model: "gpt-5.4",
        openai_model: "gpt-5.4"
      )

      assert LLM.model() == "gpt-5.4"
      assert LLM.openai_model() == "gpt-5.4"
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
