defmodule Maraithon.ToolsTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools

  describe "execute/2" do
    test "executes time tool" do
      {:ok, result} = Tools.execute("time", %{})

      assert is_binary(result.utc)
      assert is_integer(result.unix)
    end

    test "returns error for unknown tool" do
      {:error, message} = Tools.execute("nonexistent_tool", %{})

      assert message =~ "unknown_tool"
    end
  end

  describe "list/0" do
    test "returns list of available tools" do
      tools = Tools.list()

      assert is_list(tools)
      assert "time" in tools
      assert "read_file" in tools
      assert "list_files" in tools
      assert "file_tree" in tools
      assert "search_files" in tools
      assert "gmail_list_recent" in tools
      assert "gmail_search" in tools
      assert "gmail_get_message" in tools
      assert "google_calendar_list_events" in tools
      assert "github_create_issue_comment" in tools
      assert "slack_post_message" in tools
      assert "slack_list_conversations" in tools
      assert "slack_list_messages" in tools
      assert "slack_get_thread_replies" in tools
      assert "slack_search_messages" in tools
      assert "linear_create_comment" in tools
      assert "linear_create_issue" in tools
      assert "linear_update_issue_state" in tools
      assert "notaui_list_tasks" in tools
      assert "notaui_complete_task" in tools
      assert "notaui_update_task" in tools
    end
  end

  describe "exists?/1" do
    test "returns true for existing tool" do
      assert Tools.exists?("time")
      assert Tools.exists?("read_file")
      assert Tools.exists?("gmail_list_recent")
      assert Tools.exists?("google_calendar_list_events")
      assert Tools.exists?("github_create_issue_comment")
      assert Tools.exists?("slack_list_messages")
      assert Tools.exists?("notaui_list_tasks")
    end

    test "returns false for non-existing tool" do
      refute Tools.exists?("nonexistent_tool")
    end
  end
end
