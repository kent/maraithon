defmodule Maraithon.TestSupport.ActionDraftLLM do
  @moduledoc false

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.Spend

  def complete(params) do
    prompt =
      params
      |> Map.get("messages", [])
      |> List.last()
      |> case do
        %{"content" => content} -> content
        _ -> ""
      end

    content =
      cond do
        String.contains?(prompt, "\"subject\":\"...\",\"body\":\"...\"") ->
          ~s({"subject":"Re: Quick follow-up","body":"Hi there,\\n\\nFollowing up on this now. I will send the remaining detail by end of day.\\n\\nBest,\\nMaraithon"})

        String.contains?(prompt, "\"text\":\"...\"") ->
          ~s({"text":"Following up on this now. Owner is me, next step is in progress, ETA today."})

        true ->
          ~s({"text":"Fallback draft"})
      end

    {:ok,
     %{
       content: content,
       model: "test-action-draft",
       tokens_in: 100,
       tokens_out: 40,
       finish_reason: "stop",
       usage: Spend.calculate_cost("test-action-draft", 100, 40)
     }}
  end
end
