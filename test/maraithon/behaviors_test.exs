defmodule Maraithon.BehaviorsTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors

  describe "exists?/1" do
    test "returns true for existing behaviors" do
      assert Behaviors.exists?("prompt_agent")
      assert Behaviors.exists?("codebase_advisor")
      assert Behaviors.exists?("watchdog_summarizer")
      assert Behaviors.exists?("repo_planner")
    end

    test "returns false for non-existing behaviors" do
      refute Behaviors.exists?("nonexistent")
    end
  end

  describe "get/1" do
    test "returns module for existing behavior" do
      assert Behaviors.get("prompt_agent") == Maraithon.Behaviors.PromptAgent
      assert Behaviors.get("codebase_advisor") == Maraithon.Behaviors.CodebaseAdvisor
    end

    test "returns nil for non-existing behavior" do
      assert Behaviors.get("nonexistent") == nil
    end
  end

  describe "get!/1" do
    test "returns module for existing behavior" do
      assert Behaviors.get!("prompt_agent") == Maraithon.Behaviors.PromptAgent
    end

    test "raises for non-existing behavior" do
      assert_raise ArgumentError, ~r/Unknown behavior/, fn ->
        Behaviors.get!("nonexistent")
      end
    end
  end

  describe "list/0" do
    test "returns list of available behaviors" do
      behaviors = Behaviors.list()

      assert is_list(behaviors)
      assert "prompt_agent" in behaviors
      assert "codebase_advisor" in behaviors
      assert "watchdog_summarizer" in behaviors
      assert "repo_planner" in behaviors
    end
  end
end
