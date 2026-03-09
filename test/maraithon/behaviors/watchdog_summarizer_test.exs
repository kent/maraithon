defmodule Maraithon.Behaviors.WatchdogSummarizerTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.WatchdogSummarizer

  @context %{
    agent_id: "test-agent",
    timestamp: DateTime.utc_now(),
    budget: %{llm_calls: 100, tool_calls: 100}
  }

  describe "init/1" do
    test "initializes with default values" do
      state = WatchdogSummarizer.init(%{})

      assert state.check_url == nil
      assert state.summaries == []
      assert state.iteration == 0
      assert state.wakeup_interval_ms == :timer.minutes(30)
    end

    test "initializes with custom config" do
      state =
        WatchdogSummarizer.init(%{
          "check_url" => "https://example.com",
          "wakeup_interval_ms" => 60_000
        })

      assert state.check_url == "https://example.com"
      assert state.wakeup_interval_ms == 60_000
    end
  end

  describe "handle_wakeup/2" do
    test "emits note on odd iterations" do
      state = WatchdogSummarizer.init(%{})
      state = %{state | iteration: 0}

      {:emit, {:note_appended, note}, new_state} =
        WatchdogSummarizer.handle_wakeup(state, @context)

      assert new_state.iteration == 1
      assert note =~ "Iteration 1"
    end

    test "requests LLM call on even iterations" do
      state = WatchdogSummarizer.init(%{})
      state = %{state | iteration: 1}

      {:effect, {:llm_call, params}, new_state} =
        WatchdogSummarizer.handle_wakeup(state, @context)

      assert new_state.iteration == 2
      assert is_map(params)
      assert params["max_tokens"] == 500
    end

    test "requests URL check every 6th iteration when url configured" do
      state = WatchdogSummarizer.init(%{"check_url" => "https://example.com"})
      state = %{state | iteration: 5}

      {:effect, {:tool_call, tool, args}, new_state} =
        WatchdogSummarizer.handle_wakeup(state, @context)

      assert new_state.iteration == 6
      assert tool == "http_get"
      assert args["url"] == "https://example.com"
    end
  end

  describe "handle_effect_result/3" do
    test "handles LLM response" do
      state = WatchdogSummarizer.init(%{})
      response = %{content: "System status: All good"}

      {:emit, {:note_appended, note}, new_state} =
        WatchdogSummarizer.handle_effect_result({:llm_call, response}, state, @context)

      assert note =~ "Summary:"
      assert length(new_state.summaries) == 1
    end

    test "keeps only last 100 summaries" do
      state = WatchdogSummarizer.init(%{})
      state = %{state | summaries: Enum.map(1..100, &"summary #{&1}")}
      response = %{content: "New summary"}

      {:emit, _, new_state} =
        WatchdogSummarizer.handle_effect_result({:llm_call, response}, state, @context)

      assert length(new_state.summaries) == 100
      assert hd(new_state.summaries) == "New summary"
    end

    test "handles tool call result" do
      state = WatchdogSummarizer.init(%{})
      result = %{"status" => 200}

      {:emit, {:note_appended, note}, _state} =
        WatchdogSummarizer.handle_effect_result({:tool_call, result}, state, @context)

      assert note =~ "URL check"
      assert note =~ "status=200"
    end
  end

  describe "next_wakeup/1" do
    test "returns relative wakeup interval" do
      state = WatchdogSummarizer.init(%{"wakeup_interval_ms" => 60_000})

      assert {:relative, 60_000} = WatchdogSummarizer.next_wakeup(state)
    end
  end
end
