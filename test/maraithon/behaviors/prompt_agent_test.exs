defmodule Maraithon.Behaviors.PromptAgentTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.PromptAgent

  @context %{
    agent_id: "test-agent",
    timestamp: DateTime.utc_now(),
    budget: %{llm_calls: 100, tool_calls: 100},
    last_message: nil,
    event: nil
  }

  describe "init/1" do
    test "initializes with default values" do
      state = PromptAgent.init(%{})

      assert state.name == "unnamed_agent"
      assert state.prompt == "You are a helpful assistant."
      assert state.subscriptions == []
      assert state.allowed_tools == []
      assert state.memory_limit == 50
      assert state.memory == []
      assert state.processing_event == nil
      assert state.pending_tool_call == nil
      assert state.events_seen == 0
      assert state.actions_taken == 0
    end

    test "initializes with custom config" do
      state =
        PromptAgent.init(%{
          "name" => "guardian",
          "prompt" => "You are a code guardian.",
          "subscribe" => ["repo:acme/widgets"],
          "tools" => ["read_file", "search_files"],
          "memory_limit" => 100
        })

      assert state.name == "guardian"
      assert state.prompt == "You are a code guardian."
      assert state.subscriptions == ["repo:acme/widgets"]
      assert state.allowed_tools == ["read_file", "search_files"]
      assert state.memory_limit == 100
    end
  end

  describe "handle_wakeup/2" do
    test "processes direct message when present" do
      state = PromptAgent.init(%{"name" => "test"})
      context = Map.put(@context, :last_message, "Hello agent")

      {:effect, {:llm_call, params}, new_state} = PromptAgent.handle_wakeup(state, context)

      assert new_state.events_seen == 1
      assert new_state.last_processed_message == "Hello agent"
      assert length(new_state.memory) == 1
      assert is_map(params)
      assert params["max_tokens"] == 2000
    end

    test "does not reprocess same message" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | last_processed_message: "Hello agent"}
      context = Map.put(@context, :last_message, "Hello agent")

      {:idle, new_state} = PromptAgent.handle_wakeup(state, context)

      assert new_state.events_seen == 0
    end

    test "processes pubsub event when present" do
      state = PromptAgent.init(%{"name" => "test"})
      event = %{topic: "repo:acme/widgets", payload: %{action: "push"}}
      context = Map.put(@context, :event, event)

      {:effect, {:llm_call, params}, new_state} = PromptAgent.handle_wakeup(state, context)

      assert new_state.events_seen == 1
      assert length(new_state.memory) == 1
      assert is_map(params)
    end

    test "returns idle when no events and empty memory" do
      state = PromptAgent.init(%{"name" => "test"})

      {:idle, _state} = PromptAgent.handle_wakeup(state, @context)
    end

    test "does proactive action when has memory" do
      state = PromptAgent.init(%{"name" => "test"})
      memory_event = %{type: :message, content: "hello", timestamp: DateTime.utc_now(), source: "direct"}
      state = %{state | memory: [memory_event]}

      {:effect, {:llm_call, params}, _state} = PromptAgent.handle_wakeup(state, @context)

      assert params["max_tokens"] == 1000
    end
  end

  describe "handle_effect_result/3 for LLM responses" do
    test "parses RESPOND action" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "RESPOND: Hello, I received your message!"}

      {:emit, {:agent_response, payload}, new_state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)

      assert payload.agent == "test"
      assert payload.response == "Hello, I received your message!"
      assert new_state.actions_taken == 1
      assert new_state.processing_event == nil
    end

    test "parses OBSERVE action" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "OBSERVE"}

      {:idle, new_state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)

      assert new_state.processing_event == nil
    end

    test "parses ACTION for allowed tool" do
      state = PromptAgent.init(%{"name" => "test", "tools" => ["read_file"]})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "ACTION: read_file\nARGS: {\"path\": \"/tmp/test.txt\"}"}

      {:effect, {:tool_call, tool, args}, new_state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)

      assert tool == "read_file"
      assert args == %{"path" => "/tmp/test.txt"}
      assert new_state.pending_tool_call == %{tool: "read_file", args: args}
    end

    test "returns respond when tool not allowed" do
      state = PromptAgent.init(%{"name" => "test", "tools" => ["time"]})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "ACTION: read_file\nARGS: {}"}

      {:emit, {:agent_response, payload}, _state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)

      assert payload.response =~ "not available to me"
    end

    test "treats substantial text as response" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "Here is a detailed explanation of what I found in the codebase."}

      {:emit, {:agent_response, payload}, _state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)

      assert payload.response =~ "detailed explanation"
    end

    test "treats short text as observe" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "OK"}

      {:idle, _state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)
    end

    test "parses ACTION embedded in response" do
      state = PromptAgent.init(%{"name" => "test", "tools" => ["search_files"]})
      state = %{state | processing_event: %{type: :message}}
      response = %{content: "Let me check that.\nACTION: search_files\nARGS: {\"pattern\": \"TODO\"}"}

      {:effect, {:tool_call, tool, _args}, _state} =
        PromptAgent.handle_effect_result({:llm_call, response}, state, @context)

      assert tool == "search_files"
    end
  end

  describe "handle_effect_result/3 for tool results" do
    test "handles successful tool result" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | pending_tool_call: %{tool: "read_file", args: %{"path" => "/tmp/test.txt"}}}
      result = {:ok, "file contents here"}

      {:effect, {:llm_call, params}, new_state} =
        PromptAgent.handle_effect_result({:tool_call, result}, state, @context)

      assert new_state.pending_tool_call == nil
      assert params["max_tokens"] == 1500
    end

    test "handles failed tool result" do
      state = PromptAgent.init(%{"name" => "test"})
      state = %{state | pending_tool_call: %{tool: "read_file", args: %{}}, processing_event: %{}}
      result = {:error, :enoent}

      {:emit, {:agent_error, payload}, new_state} =
        PromptAgent.handle_effect_result({:tool_call, result}, state, @context)

      assert payload.agent == "test"
      assert payload.error =~ "read_file failed"
      assert new_state.pending_tool_call == nil
      assert new_state.processing_event == nil
    end
  end

  describe "next_wakeup/1" do
    test "returns 5 minute interval" do
      state = PromptAgent.init(%{})

      {:relative, interval} = PromptAgent.next_wakeup(state)

      assert interval == :timer.minutes(5)
    end
  end

  describe "memory management" do
    test "adds events to memory" do
      state = PromptAgent.init(%{"name" => "test", "memory_limit" => 3})
      context = Map.put(@context, :last_message, "msg1")

      {:effect, _, state} = PromptAgent.handle_wakeup(state, context)
      assert length(state.memory) == 1

      context = %{context | last_message: "msg2"}
      state = %{state | last_processed_message: nil}
      {:effect, _, state} = PromptAgent.handle_wakeup(state, context)
      assert length(state.memory) == 2

      context = %{context | last_message: "msg3"}
      state = %{state | last_processed_message: nil}
      {:effect, _, state} = PromptAgent.handle_wakeup(state, context)
      assert length(state.memory) == 3

      context = %{context | last_message: "msg4"}
      state = %{state | last_processed_message: nil}
      {:effect, _, state} = PromptAgent.handle_wakeup(state, context)
      # Should be limited to 3
      assert length(state.memory) == 3
    end
  end
end
