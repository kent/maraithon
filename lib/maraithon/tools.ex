defmodule Maraithon.Tools do
  @moduledoc """
  Tool registry and execution.
  """

  @tools %{
    "time" => Maraithon.Tools.Time,
    "http_get" => Maraithon.Tools.HttpGet,
    "read_file" => Maraithon.Tools.ReadFile,
    "list_files" => Maraithon.Tools.ListFiles,
    "file_tree" => Maraithon.Tools.FileTree,
    "search_files" => Maraithon.Tools.SearchFiles,
    "gmail_list_recent" => Maraithon.Tools.GmailListRecent,
    "gmail_search" => Maraithon.Tools.GmailSearch,
    "gmail_get_message" => Maraithon.Tools.GmailGetMessage,
    "gmail_send_message" => Maraithon.Tools.GmailSendMessage,
    "google_calendar_list_events" => Maraithon.Tools.GoogleCalendarListEvents,
    "github_create_issue_comment" => Maraithon.Tools.GitHubCreateIssueComment,
    "slack_post_message" => Maraithon.Tools.SlackPostMessage,
    "slack_list_conversations" => Maraithon.Tools.SlackListConversations,
    "slack_list_messages" => Maraithon.Tools.SlackListMessages,
    "slack_get_thread_replies" => Maraithon.Tools.SlackGetThreadReplies,
    "slack_search_messages" => Maraithon.Tools.SlackSearchMessages,
    "linear_create_comment" => Maraithon.Tools.LinearCreateComment,
    "linear_create_issue" => Maraithon.Tools.LinearCreateIssue,
    "linear_update_issue_state" => Maraithon.Tools.LinearUpdateIssueState,
    "notaui_list_tasks" => Maraithon.Tools.NotauiListTasks,
    "notaui_complete_task" => Maraithon.Tools.NotauiCompleteTask,
    "notaui_update_task" => Maraithon.Tools.NotauiUpdateTask
  }

  @doc """
  Execute a tool by name.
  """
  def execute(name, args) do
    case Map.get(@tools, name) do
      nil -> {:error, "unknown_tool: #{name}"}
      module -> module.execute(args)
    end
  end

  @doc """
  List available tools.
  """
  def list do
    Map.keys(@tools)
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    Map.has_key?(@tools, name)
  end
end
