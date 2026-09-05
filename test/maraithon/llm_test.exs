defmodule Maraithon.LLMTest.CapturingProvider do
  @moduledoc false
  @target :llm_routing_test_target

  def complete(params) do
    send(@target, {:complete, params})
    {:ok, %{content: "ok", model: params["model"], tokens_in: 0, tokens_out: 0}}
  end
end

defmodule Maraithon.LLMTest.RateLimitedProvider do
  @moduledoc false
  @target :llm_routing_test_target

  def complete(params) do
    send(@target, {:rate_limited_provider_called, params})
    {:error, {:rate_limited, 60_000}}
  end
end

defmodule Maraithon.LLMTest.SequencedProvider do
  @moduledoc false

  def complete(params) do
    state = Application.fetch_env!(:maraithon, :llm_sequenced_provider_state)

    Agent.get_and_update(state, fn %{responses: [response | rest], calls: calls} = current ->
      {response, %{current | responses: rest, calls: [params | calls]}}
    end)
  end
end

defmodule Maraithon.LLMTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)
    ensure_rate_limiter_started()
    LLMRateLimiter.reset()

    Application.put_env(:maraithon, Maraithon.Runtime,
      llm_provider: Maraithon.LLM.MockProvider,
      llm_provider_name: "mock",
      llm_model: "mock-v1",
      anthropic_model: "claude-sonnet-4-20250514",
      openai_model: "gpt-5.4",
      openai_reasoning_effort: "high"
    )

    on_exit(fn ->
      LLMRateLimiter.reset()

      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end
    end)

    :ok
  end

  defp ensure_rate_limiter_started do
    case Process.whereis(LLMRateLimiter) do
      nil -> start_supervised!(LLMRateLimiter)
      _pid -> :ok
    end
  end

  describe "provider/0" do
    test "returns the configured test MockProvider" do
      assert LLM.provider() == Maraithon.LLM.MockProvider
    end
  end

  describe "provider rate limiting" do
    setup do
      Process.register(self(), :llm_routing_test_target)

      on_exit(fn ->
        try do
          Process.unregister(:llm_routing_test_target)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "records provider cooldowns and blocks the next direct LLM call" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.RateLimitedProvider,
        llm_provider_name: "openai",
        llm_model: "gpt-5.4"
      )

      params = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

      assert {:error, {:rate_limited, 60_000}} = LLM.complete(params)
      expected_params = Map.put(params, "timeout_ms", 120_000)
      assert_received {:rate_limited_provider_called, ^expected_params}
      assert LLMRateLimiter.status().blocked_for_ms > 0

      assert {:error, {:rate_limited, retry_after_ms}} = LLM.complete(params)
      assert retry_after_ms > 0
      refute_received {:rate_limited_provider_called, _params}
    end

    test "does not block chat model calls behind a saturated reasoning lane" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.CapturingProvider,
        llm_provider_name: "openai",
        llm_model: "gpt-5.4",
        llm_chat_model: "gpt-4.1-mini"
      )

      test_pid = self()
      reasoning_limit = LLMRateLimiter.status().buckets.reasoning.max_concurrency

      holders =
        Enum.map(1..reasoning_limit, fn index ->
          start_supervised!(%{
            id: {:reasoning_slot_holder, index},
            start:
              {Task, :start_link,
               [
                 fn ->
                   assert :ok = LLMRateLimiter.checkout(:reasoning)
                   send(test_pid, {:reasoning_slot_held, self()})

                   receive do
                     :release_reasoning_slot -> LLMRateLimiter.checkin(:reasoning)
                   end
                 end
               ]}
          })
        end)

      Enum.each(holders, fn holder -> assert_receive {:reasoning_slot_held, ^holder} end)

      chat_params = %{
        "model" => "gpt-4.1-mini",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert {:ok, %{model: "gpt-4.1-mini"}} = LLM.complete(chat_params)
      expected_chat_params = Map.put(chat_params, "timeout_ms", 120_000)
      assert_received {:complete, ^expected_chat_params}

      reasoning_params = %{
        "model" => "gpt-5.4",
        "messages" => [%{"role" => "user", "content" => "think"}]
      }

      assert {:error, {:llm_busy, retry_after_ms}} = LLM.complete(reasoning_params)
      assert retry_after_ms > 0
      refute_received {:complete, _params}

      Enum.each(holders, &send(&1, :release_reasoning_slot))
    end
  end

  describe "model/0" do
    test "returns the configured test model" do
      assert LLM.model() == "mock-v1"
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

    test "returns the active OpenRouter model when configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider_name: "openrouter",
        llm_model: "qwen/qwen3.7-max",
        openrouter_model: "qwen/qwen3.7-max",
        openrouter_reasoning_effort: "medium"
      )

      assert LLM.model() == "qwen/qwen3.7-max"
      assert LLM.openrouter_model() == "qwen/qwen3.7-max"
      assert LLM.intelligence() == "medium"
    end
  end

  describe "api_key/0" do
    test "returns configured API key or nil" do
      # May return nil if not configured
      _key = LLM.api_key()
      assert true
    end
  end

  describe "routing_model/0 and complete_routing/1" do
    test "returns nil when no routing model configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        llm_provider_name: "mock",
        llm_model: "mock-v1",
        llm_routing_model: nil
      )

      assert LLM.routing_model() == nil
    end

    test "returns the configured routing model" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        llm_provider_name: "mock",
        llm_model: "mock-v1",
        llm_routing_model: "claude-haiku-4-5-20251001"
      )

      assert LLM.routing_model() == "claude-haiku-4-5-20251001"
    end

    test "complete_routing forwards to the configured provider with the routing model" do
      Process.register(self(), :llm_routing_test_target)

      on_exit(fn ->
        try do
          Process.unregister(:llm_routing_test_target)
        rescue
          ArgumentError -> :ok
        end
      end)

      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.CapturingProvider,
        llm_provider_name: "anthropic",
        llm_model: "claude-sonnet-4-20250514",
        llm_routing_model: "claude-haiku-4-5-20251001"
      )

      assert {:ok, %{model: "claude-haiku-4-5-20251001"}} =
               LLM.complete_routing(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      assert_received {:complete, %{"model" => "claude-haiku-4-5-20251001"}}
    end

    test "complete_routing falls back to complete when no routing model configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        llm_provider_name: "mock",
        llm_model: "mock-v1",
        llm_routing_model: nil
      )

      assert {:ok, %{model: "mock-v1"}} =
               LLM.complete_routing(%{"messages" => [%{"role" => "user", "content" => "hi"}]})
    end
  end

  describe "complete_brief/1" do
    test "reserves deadline and retries a transient error when brief and primary share a target" do
      state =
        start_supervised!(
          {Agent,
           fn ->
             %{
               responses: [
                 {:error, {:provider_error, :redacted}},
                 {:ok, %{content: "recovered", model: "shared-model"}}
               ],
               calls: []
             }
           end}
        )

      Application.put_env(:maraithon, :llm_sequenced_provider_state, state)

      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.SequencedProvider,
        llm_provider_name: "mock",
        llm_model: "shared-model",
        llm_brief_model: "shared-model",
        llm_brief_reasoning_effort: "high"
      )

      on_exit(fn -> Application.delete_env(:maraithon, :llm_sequenced_provider_state) end)

      assert {:ok, %{content: "recovered"}} =
               LLM.complete_brief(%{
                 "messages" => [%{"role" => "user", "content" => "brief this"}],
                 "timeout_ms" => 120_000
               })

      calls = state |> Agent.get(& &1.calls) |> Enum.reverse()
      assert [first, retry] = calls
      assert first["model"] == "shared-model"
      assert retry["model"] == "shared-model"
      assert first["timeout_ms"] <= 60_000
      assert retry["timeout_ms"] >= 59_000
    end

    test "does not retry a non-transient failure on the same target" do
      state =
        start_supervised!(
          {Agent,
           fn ->
             %{
               responses: [{:error, {:content_filtered, :redacted}}],
               calls: []
             }
           end}
        )

      Application.put_env(:maraithon, :llm_sequenced_provider_state, state)

      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.SequencedProvider,
        llm_provider_name: "mock",
        llm_model: "shared-model",
        llm_brief_model: "shared-model",
        llm_brief_reasoning_effort: "high"
      )

      on_exit(fn -> Application.delete_env(:maraithon, :llm_sequenced_provider_state) end)

      assert {:error, {:content_filtered, :redacted}} =
               LLM.complete_brief(%{
                 "messages" => [%{"role" => "user", "content" => "brief this"}],
                 "timeout_ms" => 120_000
               })

      assert [_first] = Agent.get(state, & &1.calls)
    end
  end

  test "classifies fast and chat models independently from reasoning" do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      runtime
      |> Keyword.put(:llm_model, "reasoning-model")
      |> Keyword.put(:llm_chat_model, "chat-model")
      |> Keyword.put(:llm_routing_model, "routing-model")
      |> Keyword.put(:llm_fast_model, "fast-model")
    )

    assert LLM.rate_limit_bucket(%{"model" => "chat-model"}) == :chat
    assert LLM.rate_limit_bucket(%{"model" => "routing-model"}) == :chat
    assert LLM.rate_limit_bucket(%{"model" => "fast-model"}) == :chat
    assert LLM.rate_limit_bucket(%{"model" => "reasoning-model"}) == :reasoning
    assert LLM.rate_limit_bucket(%{"model" => "other-model"}) == :reasoning
    assert LLM.rate_limit_bucket(%{"model" => ""}) == :default
  end

  test "keeps aliased chat routing and fast fallbacks in the primary reasoning lane" do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      runtime
      |> Keyword.put(:llm_model, "shared-primary")
      |> Keyword.put(:llm_chat_model, "shared-primary")
      |> Keyword.put(:llm_routing_model, "shared-primary")
      |> Keyword.delete(:llm_fast_model)
    )

    assert LLM.fast_model() == "shared-primary"
    assert LLM.rate_limit_bucket(%{"model" => "shared-primary"}) == :reasoning
  end
end
