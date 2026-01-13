defmodule Maraithon.Behaviors.PromptAgent do
  @moduledoc """
  A generic, prompt-driven agent behavior.

  Instead of writing Elixir code, define agent behavior through a prompt.
  The agent subscribes to event streams and processes them through the LLM.

  Config:
    - name: Agent name (for identification)
    - prompt: The system prompt defining who the agent is and how it thinks
    - subscribe: List of PubSub topics to subscribe to
    - tools: List of tool names the agent can use
    - memory_limit: Max events to remember (default: 50)

  Example:
    %{
      "name" => "guardian",
      "prompt" => "You are a code guardian. Watch for issues and speak up.",
      "subscribe" => ["repo:acme/widgets", "alerts:errors"],
      "tools" => ["read_file", "search_files", "http_get"],
      "memory_limit" => 100
    }
  """

  @behaviour Maraithon.Behaviors.Behavior

  @default_memory_limit 50

  require Logger

  @impl true
  def init(config) do
    name = config["name"] || "unnamed_agent"
    prompt = config["prompt"] || "You are a helpful assistant."
    subscribe = config["subscribe"] || []
    tools = config["tools"] || []
    memory_limit = config["memory_limit"] || @default_memory_limit

    Logger.info("PromptAgent initializing",
      name: name,
      subscriptions: length(subscribe),
      tools: length(tools)
    )

    %{
      name: name,
      prompt: prompt,
      subscriptions: subscribe,
      allowed_tools: tools,
      memory_limit: memory_limit,

      # Memory - rolling buffer of events
      memory: [],

      # Current processing state
      processing_event: nil,
      pending_tool_call: nil,

      # Stats
      events_seen: 0,
      actions_taken: 0,

      # Track last processed to avoid duplicates
      last_processed_message: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    # Check for new events: message, pubsub event, or just a wakeup
    cond do
      # Direct message to agent
      context.last_message && context.last_message != state.last_processed_message ->
        event = %{
          type: :message,
          content: context.last_message,
          timestamp: context.timestamp,
          source: "direct"
        }

        state = %{state | last_processed_message: context.last_message}
        process_event(state, event, context)

      # PubSub event
      context[:event] != nil ->
        event = %{
          type: :pubsub,
          topic: context.event.topic,
          content: context.event.payload,
          timestamp: context.timestamp,
          source: context.event.topic
        }

        process_event(state, event, context)

      # Regular wakeup - check if we should do something proactive
      true ->
        maybe_proactive_action(state, context)
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    handle_llm_response(response, state, context)
  end

  def handle_effect_result({:tool_call, result}, state, context) do
    handle_tool_result(result, state, context)
  end

  @impl true
  def next_wakeup(_state) do
    # Wake up periodically to allow proactive behavior
    # But not too often - we're mostly event-driven
    {:relative, :timer.minutes(5)}
  end

  # ===========================================================================
  # Event Processing
  # ===========================================================================

  defp process_event(state, event, context) do
    # Add event to memory
    state = add_to_memory(state, event)
    state = %{state | processing_event: event, events_seen: state.events_seen + 1}

    Logger.info("Processing event",
      agent: state.name,
      event_type: event.type,
      source: event.source
    )

    # Build prompt and ask LLM what to do
    prompt = build_thinking_prompt(state, event, context)

    params = %{
      "messages" => [
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => 2000,
      "temperature" => 0.7
    }

    {:effect, {:llm_call, params}, state}
  end

  defp maybe_proactive_action(state, context) do
    # If we have memory and haven't acted recently, maybe do something proactive
    if length(state.memory) > 0 do
      prompt = build_proactive_prompt(state, context)

      params = %{
        "messages" => [
          %{"role" => "user", "content" => prompt}
        ],
        "max_tokens" => 1000,
        "temperature" => 0.7
      }

      {:effect, {:llm_call, params}, state}
    else
      {:idle, state}
    end
  end

  # ===========================================================================
  # LLM Response Handling
  # ===========================================================================

  defp handle_llm_response(response, state, _context) do
    content = response.content

    # Parse the response to see if the agent wants to take action
    case parse_action(content, state.allowed_tools) do
      {:tool_call, tool, args} ->
        Logger.info("Agent requesting tool call",
          agent: state.name,
          tool: tool,
          args: inspect(args)
        )

        state = %{state | pending_tool_call: %{tool: tool, args: args}}
        {:effect, {:tool_call, tool, args}, state}

      {:respond, message} ->
        Logger.info("Agent responding",
          agent: state.name,
          message: String.slice(message, 0, 100)
        )

        state = %{state | processing_event: nil, actions_taken: state.actions_taken + 1}

        {:emit,
         {:agent_response,
          %{
            agent: state.name,
            response: message,
            event_type: get_in(state, [:processing_event, :type])
          }}, state}

      :observe ->
        # Agent chose to just observe, not act
        Logger.debug("Agent observing", agent: state.name)
        state = %{state | processing_event: nil}
        {:idle, state}
    end
  end

  defp handle_tool_result(result, state, _context) do
    tool_call = state.pending_tool_call

    case result do
      {:ok, tool_result} ->
        # Tool succeeded - ask LLM what to do with the result
        prompt = build_tool_result_prompt(state, tool_call, tool_result)

        params = %{
          "messages" => [
            %{"role" => "user", "content" => prompt}
          ],
          "max_tokens" => 1500,
          "temperature" => 0.7
        }

        state = %{state | pending_tool_call: nil}
        {:effect, {:llm_call, params}, state}

      {:error, reason} ->
        Logger.warning("Tool call failed",
          agent: state.name,
          tool: tool_call.tool,
          reason: inspect(reason)
        )

        state = %{state | pending_tool_call: nil, processing_event: nil}

        {:emit,
         {:agent_error,
          %{
            agent: state.name,
            error: "Tool #{tool_call.tool} failed: #{inspect(reason)}"
          }}, state}
    end
  end

  # ===========================================================================
  # Prompt Building
  # ===========================================================================

  defp build_thinking_prompt(state, event, _context) do
    memory_context = format_memory(state.memory)
    tools_list = format_tools(state.allowed_tools)

    """
    #{state.prompt}

    ## Your Tools
    #{tools_list}

    ## Recent Events You've Seen
    #{memory_context}

    ## Current Event
    Type: #{event.type}
    Source: #{event.source}
    Content:
    ```
    #{format_content(event.content)}
    ```

    ## Instructions
    Based on your purpose and what you've observed, decide what to do:

    1. If you want to use a tool, respond with:
       ACTION: tool_name
       ARGS: {"param": "value"}

    2. If you want to respond/communicate, respond with:
       RESPOND: Your message here

    3. If you just want to observe and remember this event, respond with:
       OBSERVE

    Think about whether this event requires action based on who you are and your purpose.
    """
  end

  defp build_proactive_prompt(state, context) do
    memory_context = format_memory(state.memory)

    """
    #{state.prompt}

    ## Recent Events You've Seen
    #{memory_context}

    ## Current Time
    #{DateTime.to_iso8601(context.timestamp)}

    ## Instructions
    You're doing a periodic check-in. Based on what you've observed recently,
    is there anything you should proactively communicate or do?

    If yes, respond with RESPOND: or ACTION:
    If nothing needs attention right now, respond with OBSERVE
    """
  end

  defp build_tool_result_prompt(state, tool_call, result) do
    """
    #{state.prompt}

    ## Tool Result
    You called: #{tool_call.tool}
    With args: #{Jason.encode!(tool_call.args)}

    Result:
    ```
    #{format_content(result)}
    ```

    ## Instructions
    Based on this result, what do you want to do?

    - RESPOND: Share findings or answer
    - ACTION: Call another tool
    - OBSERVE: Done processing, nothing to communicate
    """
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp add_to_memory(state, event) do
    memory = [event | state.memory] |> Enum.take(state.memory_limit)
    %{state | memory: memory}
  end

  defp format_memory([]), do: "(No recent events)"

  defp format_memory(memory) do
    memory
    |> Enum.reverse()
    # Show last 10 in prompt
    |> Enum.take(10)
    |> Enum.map(fn event ->
      time = if event[:timestamp], do: DateTime.to_iso8601(event.timestamp), else: "unknown"
      "- [#{time}] #{event.source}: #{truncate(format_content(event.content), 200)}"
    end)
    |> Enum.join("\n")
  end

  defp format_tools([]), do: "(No tools available)"
  defp format_tools(tools), do: Enum.join(tools, ", ")

  defp format_content(content) when is_binary(content), do: content
  defp format_content(content) when is_map(content), do: Jason.encode!(content, pretty: true)
  defp format_content(content), do: inspect(content)

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  defp parse_action(content, allowed_tools) do
    content = String.trim(content)

    cond do
      String.starts_with?(content, "ACTION:") ->
        parse_tool_action(content, allowed_tools)

      String.starts_with?(content, "RESPOND:") ->
        message = String.replace_prefix(content, "RESPOND:", "") |> String.trim()
        {:respond, message}

      String.starts_with?(content, "OBSERVE") ->
        :observe

      # Fallback: try to detect intent
      String.contains?(content, "ACTION:") ->
        parse_tool_action(content, allowed_tools)

      true ->
        # Default to treating the whole response as a message if it seems substantive
        if String.length(content) > 20 do
          {:respond, content}
        else
          :observe
        end
    end
  end

  defp parse_tool_action(content, allowed_tools) do
    # Extract tool name and args
    lines = String.split(content, "\n")

    action_line = Enum.find(lines, fn l -> String.starts_with?(l, "ACTION:") end)
    args_line = Enum.find(lines, fn l -> String.starts_with?(l, "ARGS:") end)

    if action_line do
      tool = String.replace_prefix(action_line, "ACTION:", "") |> String.trim()

      args =
        if args_line do
          args_str = String.replace_prefix(args_line, "ARGS:", "") |> String.trim()

          case Jason.decode(args_str) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end
        else
          %{}
        end

      if tool in allowed_tools do
        {:tool_call, tool, args}
      else
        {:respond, "I wanted to use #{tool} but it's not available to me."}
      end
    else
      :observe
    end
  end
end
