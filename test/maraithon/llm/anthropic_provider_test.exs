defmodule Maraithon.LLM.AnthropicProviderTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM.AnthropicProvider

  setup do
    # Store original config
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)
    original_anthropic = Application.get_env(:maraithon, :anthropic)
    original_env = System.get_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end

      if original_anthropic do
        Application.put_env(:maraithon, :anthropic, original_anthropic)
      else
        Application.delete_env(:maraithon, :anthropic)
      end

      if original_env do
        System.put_env("ANTHROPIC_API_KEY", original_env)
      else
        System.delete_env("ANTHROPIC_API_KEY")
      end
    end)

    :ok
  end

  describe "complete/1" do
    test "returns error when API key not configured" do
      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: nil)
      System.delete_env("ANTHROPIC_API_KEY")

      params = %{
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "max_tokens" => 100
      }

      result = AnthropicProvider.complete(params)

      assert {:error, "ANTHROPIC_API_KEY not configured"} = result
    end

    test "successfully completes with Bypass" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        anthropic_api_key: "test_api_key",
        anthropic_model: "claude-3-haiku-20240307"
      )

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["model"] == "claude-3-haiku-20240307"
        assert params["messages"] == [%{"role" => "user", "content" => "Hello"}]
        assert params["max_tokens"] == 2048
        assert params["temperature"] == 0.7

        # Verify headers
        api_key = Plug.Conn.get_req_header(conn, "x-api-key")
        assert api_key == ["test_api_key"]

        version = Plug.Conn.get_req_header(conn, "anthropic-version")
        assert version == ["2023-06-01"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "msg_123",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Hello! How can I help you?"}],
            "model" => "claude-3-haiku-20240307",
            "stop_reason" => "end_turn",
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => 15
            }
          })
        )
      end)

      {:ok, result} =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert result.content == "Hello! How can I help you?"
      assert result.model == "claude-3-haiku-20240307"
      assert result.tokens_in == 10
      assert result.tokens_out == 15
      assert result.finish_reason == "end_turn"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 15
    end

    test "handles rate limiting with retry_after" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          429,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{
              "type" => "rate_limit_error",
              "message" => "Rate limited. Please retry after 30 seconds."
            }
          })
        )
      end)

      result =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert {:error, {:rate_limited, 30000}} = result
    end

    test "handles rate limiting with default retry" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          429,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{
              "type" => "rate_limit_error",
              "message" => "Too many requests"
            }
          })
        )
      end)

      result =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert {:error, {:rate_limited, 60000}} = result
    end

    test "handles API errors" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "Invalid message format"
            }
          })
        )
      end)

      result =
        AnthropicProvider.complete(%{
          "messages" => []
        })

      assert {:error, {:api_error, 400, _body}} = result
    end

    test "handles network errors" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      result =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert {:error, {:network_error, _reason}} = result
    end

    test "uses custom model and parameters" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["model"] == "claude-3-opus-20240229"
        assert params["max_tokens"] == 4096
        assert params["temperature"] == 0.5

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "Response"}],
            "model" => "claude-3-opus-20240229",
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
          })
        )
      end)

      {:ok, result} =
        AnthropicProvider.complete(%{
          "model" => "claude-3-opus-20240229",
          "max_tokens" => 4096,
          "temperature" => 0.5,
          "messages" => [%{"role" => "user", "content" => "Test"}]
        })

      assert result.model == "claude-3-opus-20240229"
    end

    test "handles empty content response" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "content" => [],
            "model" => "claude-3-haiku-20240307",
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
          })
        )
      end)

      {:ok, result} =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Test"}]
        })

      assert result.content == ""
    end

    test "handles missing usage data" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "Response"}],
            "model" => "claude-3-haiku-20240307",
            "stop_reason" => "end_turn"
          })
        )
      end)

      {:ok, result} =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Test"}]
        })

      assert result.tokens_in == 0
      assert result.tokens_out == 0
    end

    test "handles 429 with no error body structure" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(%{"message" => "rate limited"}))
      end)

      result =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      # Should use default 60000ms retry
      assert {:error, {:rate_limited, 60000}} = result
    end

    test "handles missing model in response" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "Response"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
          })
        )
      end)

      {:ok, result} =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Test"}]
        })

      assert result.model == "unknown"
    end

    test "handles missing stop_reason in response" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime, anthropic_api_key: "test_api_key")

      Application.put_env(:maraithon, :anthropic,
        base_url: "http://localhost:#{bypass.port}/v1/messages"
      )

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "Response"}],
            "model" => "claude-3-haiku-20240307",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
          })
        )
      end)

      {:ok, result} =
        AnthropicProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Test"}]
        })

      assert result.finish_reason == "unknown"
    end
  end
end
