defmodule MaraithonWeb.ConnectorsHTMLTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.ConnectorsHTML

  test "connection_primary_action/1 uses reconnect wording for connected telegram" do
    assert ConnectorsHTML.connection_primary_action(%{provider: "telegram", status: :connected}) ==
             "Reconnect Telegram"

    assert ConnectorsHTML.connection_primary_action(%{
             provider: "telegram",
             status: :disconnected
           }) == "Link Telegram"
  end

  test "connection_status_label/1 supports needs_refresh status" do
    assert ConnectorsHTML.connection_status_label(:needs_refresh) == "refresh required"
  end
end
