defmodule Maraithon.OnboardingProofTest do
  use ExUnit.Case, async: true

  alias Maraithon.OnboardingProof

  test "normalizes up to three preview items from the llm response" do
    sources = [
      %{
        "source" => "gmail",
        "label" => "Gmail",
        "account_label" => "kent@voteagora.com",
        "items" => %{
          "inbox" => [
            %{"subject" => "Deck follow-up", "snippet" => "Can you send the deck today?"}
          ],
          "sent" => [%{"subject" => "Re: Deck", "snippet" => "I'll send it this afternoon."}]
        }
      },
      %{
        "source" => "slack",
        "label" => "Slack",
        "account_label" => "Agora",
        "items" => [%{"text" => "I’ll send owners and next steps after the planning meeting."}]
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       Jason.encode!([
         %{
           "title" => "You promised the deck to Sarah",
           "summary" =>
             "A real email thread shows a promised deck with no visible follow-through yet.",
           "rationale" =>
             "This is exactly the kind of founder promise that slips unless someone is watching sent and inbox together.",
           "recommended_action" =>
             "Watch the thread, verify delivery, and nudge if nothing is sent by end of day.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "founder_followthrough_agent",
           "confidence" => 0.92
         },
         %{
           "title" => "Planning meeting likely created follow-up work",
           "summary" => "Slack shows a promise to send owners and next steps after planning.",
           "rationale" =>
             "Planning meetings are high-retention moments because users feel the pain immediately when owners never get circulated.",
           "recommended_action" =>
             "Track the promise and check whether the thread gets a real update.",
           "source" => "slack",
           "account_label" => "Agora",
           "suggested_behavior" => "slack_followthrough_agent",
           "confidence" => 0.84
         },
         %{
           "title" => "Inbox reply debt preview",
           "summary" => "The inbox sample contains a direct ask that looks unresolved.",
           "rationale" =>
             "Reply debt is a reliable proof-of-value wedge because users instantly recognize the missed loop.",
           "recommended_action" =>
             "Flag the thread and escalate only if no response is sent after the promised window.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "inbox_calendar_advisor",
           "confidence" => 0.8
         },
         %{
           "title" => "Should be dropped because only three items are allowed",
           "summary" => "This item should not survive normalization.",
           "rationale" => "The UI intentionally limits the preview to the top three catches.",
           "recommended_action" => "Drop it.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "founder_followthrough_agent",
           "confidence" => 0.78
         }
       ])}
    end

    assert {:ok, preview} =
             OnboardingProof.preview("user@example.com",
               sources: sources,
               llm_complete: llm_complete
             )

    assert length(preview.items) == 3
    assert Enum.at(preview.items, 0).title == "You promised the deck to Sarah"
    assert Enum.at(preview.items, 1).source == "slack"
    assert Enum.at(preview.items, 2).suggested_behavior == "inbox_calendar_advisor"
    assert preview.sources == ["Gmail · kent@voteagora.com", "Slack · Agora"]
  end

  test "returns an empty preview when no connected data is available" do
    assert {:ok, preview} = OnboardingProof.preview("user@example.com", sources: [])
    assert preview.items == []
    assert preview.sources == []
  end
end
