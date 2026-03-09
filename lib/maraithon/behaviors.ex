defmodule Maraithon.Behaviors do
  @moduledoc """
  Registry of available agent behaviors.
  """

  @behaviors %{
    "codebase_advisor" => Maraithon.Behaviors.CodebaseAdvisor,
    "watchdog_summarizer" => Maraithon.Behaviors.WatchdogSummarizer,
    "repo_planner" => Maraithon.Behaviors.RepoPlanner,
    "prompt_agent" => Maraithon.Behaviors.PromptAgent,
    "inbox_calendar_advisor" => Maraithon.Behaviors.InboxCalendarAdvisor
  }

  @doc """
  Check if a behavior exists.
  """
  def exists?(name) when is_binary(name) do
    Map.has_key?(@behaviors, name)
  end

  @doc """
  Get a behavior module by name.
  """
  def get(name) when is_binary(name) do
    Map.get(@behaviors, name)
  end

  @doc """
  List all available behaviors.
  """
  def list do
    Map.keys(@behaviors)
  end

  @doc """
  Get behavior module, raising if not found.
  """
  def get!(name) when is_binary(name) do
    case get(name) do
      nil -> raise ArgumentError, "Unknown behavior: #{name}"
      module -> module
    end
  end
end
