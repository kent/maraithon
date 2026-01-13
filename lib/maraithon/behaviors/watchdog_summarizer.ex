defmodule Maraithon.Behaviors.WatchdogSummarizer do
  @moduledoc """
  Demo behavior that periodically summarizes activity and checks URLs.

  Config:
    - check_url: URL to periodically check (optional)
    - wakeup_interval_ms: How often to wake up (default: 30 minutes)
  """

  @behaviour Maraithon.Behaviors.Behavior

  @default_wakeup_interval_ms :timer.minutes(30)

  require Logger

  @impl true
  def init(config) do
    %{
      check_url: config["check_url"],
      summaries: [],
      iteration: 0,
      wakeup_interval_ms: config["wakeup_interval_ms"] || @default_wakeup_interval_ms
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = %{state | iteration: state.iteration + 1}

    Logger.info("WatchdogSummarizer wakeup", iteration: state.iteration)

    cond do
      # Every 6th wakeup (3 hours), do a URL check if configured
      state.check_url && rem(state.iteration, 6) == 0 ->
        Logger.info("Checking URL", url: state.check_url)
        {:effect, {:tool_call, "http_get", %{"url" => state.check_url}}, state}

      # Every 2nd wakeup (1 hour), ask for a summary
      rem(state.iteration, 2) == 0 ->
        prompt = build_summary_prompt(context)

        params = %{
          "messages" => [
            %{"role" => "user", "content" => prompt}
          ],
          "max_tokens" => 500,
          "temperature" => 0.5
        }

        {:effect, {:llm_call, params}, state}

      # Otherwise, just note we're alive
      true ->
        note =
          "Iteration #{state.iteration}: All quiet at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

        {:emit, {:note_appended, note}, state}
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, _context) do
    summary = response.content
    state = %{state | summaries: [summary | state.summaries] |> Enum.take(100)}

    {:emit, {:note_appended, "Summary: #{String.slice(summary, 0, 200)}..."}, state}
  end

  def handle_effect_result({:tool_call, result}, state, _context) do
    status = result["status"] || "unknown"
    note = "URL check: status=#{status} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    {:emit, {:note_appended, note}, state}
  end

  @impl true
  def next_wakeup(state) do
    {:relative, state.wakeup_interval_ms}
  end

  # Private functions

  defp build_summary_prompt(context) do
    """
    You are a watchdog agent monitoring system activity.

    Current time: #{context.timestamp |> DateTime.to_iso8601()}
    Agent ID: #{context.agent_id}
    Budget remaining: LLM=#{context.budget.llm_calls}, Tools=#{context.budget.tool_calls}

    Please provide a brief status summary. Note:
    - How long you've been running
    - Any notable observations
    - Current system health assessment

    Keep it under 100 words.
    """
  end
end
