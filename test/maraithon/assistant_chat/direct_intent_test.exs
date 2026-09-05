defmodule Maraithon.AssistantChat.DirectIntentTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantChat.DirectIntent

  test "classifies tiny social turns as fast chat replies" do
    assert {:ok,
            %{type: :fast_chat_reply, kind: :greeting, reply: "Ready. What needs attention?"}} =
             DirectIntent.classify("Hey")

    assert {:ok, %{type: :fast_chat_reply, kind: :acknowledgement, reply: "Got it."}} =
             DirectIntent.classify("sounds good")

    assert {:ok, %{type: :fast_chat_reply, kind: :thanks, reply: "Anytime."}} =
             DirectIntent.classify("Thank you!")
  end

  test "classifies safe arithmetic as a deterministic calculation" do
    assert {:ok,
            %{
              type: :simple_calculation,
              expression: "2+2",
              result: "4",
              reply: "2+2 = 4."
            }} = DirectIntent.classify("What's 2+2?")

    assert {:ok,
            %{
              type: :simple_calculation,
              expression: "12 * (3 + 4)",
              result: "84"
            }} = DirectIntent.classify("calculate 12 * (3 + 4)")

    assert {:ok, %{type: :simple_calculation, result: "0.3"}} =
             DirectIntent.classify("0.1 + 0.2")

    assert {:ok, %{type: :simple_calculation, expression: "1000 + 2", result: "1002"}} =
             DirectIntent.classify("1,000 + 2")

    operand = "1234567890123456789012345678901234567890"

    assert {:ok, %{type: :simple_calculation, result: result}} =
             DirectIntent.classify("#{operand}+1")

    assert result == "1234567890123456789012345678901234567891"
  end

  test "rejects unsafe or semantic arithmetic-looking prompts" do
    for text <- [
          "What's 2+2 for my todos?",
          "Calculate the best person to follow up with",
          "What is 10 / 0?",
          "2 + apples",
          "1,2 + 3",
          "1.2,3 + 4",
          "1e1000000 + 1",
          "What is 2026-05-28?",
          "05/28/2026"
        ] do
      assert DirectIntent.classify(text) == :nomatch
    end
  end

  test "does not classify context-bearing prompts as fast chat" do
    for text <- [
          "Hey what todos need my attention?",
          "Thanks, which contacts are stale?",
          "Ok who should I follow up with?",
          "Hello, what meetings are on my calendar?"
        ] do
      assert DirectIntent.classify(text) == :nomatch
    end
  end
end
