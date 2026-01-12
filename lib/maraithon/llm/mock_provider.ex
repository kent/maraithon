defmodule Maraithon.LLM.MockProvider do
  @moduledoc """
  Mock LLM provider for testing.
  """

  @behaviour Maraithon.LLM.Adapter

  require Logger

  @impl true
  def complete(params) do
    Logger.debug("MockProvider.complete called", params: inspect(params))

    # Simulate some latency
    Process.sleep(100)

    messages = params["messages"] || []
    last_message = List.last(messages) || %{}
    user_content = last_message["content"] || ""

    response = %{
      content: generate_mock_response(user_content),
      model: "mock-v1",
      tokens_in: String.length(user_content),
      tokens_out: 50,
      finish_reason: "stop"
    }

    {:ok, response}
  end

  defp generate_mock_response(prompt) do
    cond do
      String.contains?(prompt, "review") ->
        """
        **Code Review Summary**

        The code looks generally well-structured. Here are some observations:

        1. Consider adding more documentation
        2. Some functions could be broken into smaller pieces
        3. Test coverage could be improved

        Overall: Good code with room for minor improvements.
        """

      String.contains?(prompt, "summarize") ->
        """
        **Summary**

        Based on my analysis, the key points are:
        - The system is functioning normally
        - No critical issues detected
        - Activity levels are within expected ranges
        """

      true ->
        """
        Mock response generated at #{DateTime.utc_now() |> DateTime.to_iso8601()}.

        This is a placeholder response from the mock LLM provider.
        In production, this would be a real response from Claude.
        """
    end
  end
end
