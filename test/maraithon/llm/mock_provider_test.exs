defmodule Maraithon.LLM.MockProviderTest do
  use ExUnit.Case, async: true

  alias Maraithon.LLM.MockProvider

  describe "complete/1" do
    test "returns a successful response" do
      params = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello, world!"}
        ]
      }

      {:ok, response} = MockProvider.complete(params)

      assert is_binary(response.content)
      assert response.model == "mock-v1"
      assert is_integer(response.tokens_in)
      assert is_integer(response.tokens_out)
      assert response.finish_reason == "stop"
      assert response.usage.input_tokens == response.tokens_in
      assert response.usage.output_tokens == response.tokens_out
      assert response.usage.total_tokens == response.tokens_in + response.tokens_out
    end

    test "returns code review response for review prompts" do
      params = %{
        "messages" => [
          %{"role" => "user", "content" => "Please review this code"}
        ]
      }

      {:ok, response} = MockProvider.complete(params)

      assert String.contains?(response.content, "Code Review")
    end

    test "returns summary response for summarize prompts" do
      params = %{
        "messages" => [
          %{"role" => "user", "content" => "Please summarize the report"}
        ]
      }

      {:ok, response} = MockProvider.complete(params)

      assert String.contains?(response.content, "Summary")
    end

    test "returns generic response for other prompts" do
      params = %{
        "messages" => [
          %{"role" => "user", "content" => "What is the weather?"}
        ]
      }

      {:ok, response} = MockProvider.complete(params)

      assert String.contains?(response.content, "Mock response")
    end

    test "handles empty messages" do
      params = %{"messages" => []}

      {:ok, response} = MockProvider.complete(params)

      assert is_binary(response.content)
    end

    test "handles missing messages key" do
      params = %{}

      {:ok, response} = MockProvider.complete(params)

      assert is_binary(response.content)
    end
  end
end
