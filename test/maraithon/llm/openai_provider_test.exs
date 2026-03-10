defmodule Maraithon.LLM.OpenAIProviderTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM.OpenAIProvider

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)
    original_openai = Application.get_env(:maraithon, :openai)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end

      if original_openai do
        Application.put_env(:maraithon, :openai, original_openai)
      else
        Application.delete_env(:maraithon, :openai)
      end
    end)

    :ok
  end

  describe "complete/1" do
    test "returns error when API key is not configured" do
      Application.put_env(:maraithon, Maraithon.Runtime, openai_api_key: nil)

      assert {:error, "OPENAI_API_KEY not configured"} =
               OpenAIProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end

    test "successfully completes with Bypass" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openai_api_key: "test_api_key",
        openai_model: "gpt-5.4",
        openai_reasoning_effort: "high"
      )

      Application.put_env(:maraithon, :openai,
        base_url: "http://localhost:#{bypass.port}/v1/responses"
      )

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["model"] == "gpt-5.4"
        assert params["max_output_tokens"] == 2048
        assert params["reasoning"] == %{"effort" => "high"}
        refute Map.has_key?(params, "temperature")

        assert params["input"] == [
                 %{
                   "role" => "system",
                   "content" => [%{"type" => "input_text", "text" => "You are concise."}]
                 },
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "Hello"}]
                 }
               ]

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_api_key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "resp_123",
            "status" => "completed",
            "model" => "gpt-5.4-2026-03-05",
            "output" => [
              %{"type" => "reasoning", "summary" => []},
              %{
                "type" => "message",
                "status" => "completed",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => "Hello from GPT-5.4"}
                ]
              }
            ],
            "usage" => %{
              "input_tokens" => 12,
              "output_tokens" => 18,
              "total_tokens" => 30
            }
          })
        )
      end)

      {:ok, result} =
        OpenAIProvider.complete(%{
          "messages" => [
            %{"role" => "system", "content" => "You are concise."},
            %{"role" => "user", "content" => "Hello"}
          ]
        })

      assert result.content == "Hello from GPT-5.4"
      assert result.model == "gpt-5.4-2026-03-05"
      assert result.tokens_in == 12
      assert result.tokens_out == 18
      assert result.finish_reason == "completed"
      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 18
    end

    test "supports overriding reasoning effort per request" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openai_api_key: "test_api_key",
        openai_model: "gpt-5.4",
        openai_reasoning_effort: "high"
      )

      Application.put_env(:maraithon, :openai,
        base_url: "http://localhost:#{bypass.port}/v1/responses"
      )

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["reasoning"] == %{"effort" => "medium"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "completed",
            "model" => "gpt-5.4-2026-03-05",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "ok"}]
              }
            ],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
          })
        )
      end)

      assert {:ok, _result} =
               OpenAIProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}],
                 "reasoning" => %{"effort" => "medium"}
               })
    end

    test "handles rate limiting" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, openai_api_key: "test_api_key")

      Application.put_env(:maraithon, :openai,
        base_url: "http://localhost:#{bypass.port}/v1/responses"
      )

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "message" => "Rate limit exceeded"
            }
          })
        )
      end)

      assert {:error, {:rate_limited, 7000}} =
               OpenAIProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end

    test "returns incomplete response error when no answer is produced" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, openai_api_key: "test_api_key")

      Application.put_env(:maraithon, :openai,
        base_url: "http://localhost:#{bypass.port}/v1/responses"
      )

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "incomplete",
            "model" => "gpt-5.4-2026-03-05",
            "output" => [%{"type" => "reasoning", "summary" => []}],
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "usage" => %{"input_tokens" => 10, "output_tokens" => 64, "total_tokens" => 74}
          })
        )
      end)

      assert {:error, {:incomplete_response, %{"reason" => "max_output_tokens"}}} =
               OpenAIProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end
  end
end
