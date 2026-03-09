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
end
