defmodule Maraithon.BriefsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo

  setup do
    Application.put_env(:maraithon, :briefs,
      telegram_module: Maraithon.TestSupport.CapturingTelegram
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :briefs)
    end)

    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    user_id = "briefs-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "777123",
        metadata: %{"username" => "briefs"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "dispatches pending briefs to Telegram", %{user_id: user_id, agent: agent} do
    scheduled_for = DateTime.utc_now()

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief: 2 loops worth watching",
               "summary" => "Two high-signal loops look open this morning.",
               "body" => "- [Gmail] Send the deck\n- [Slack] Post owners and next steps",
               "scheduled_for" => scheduled_for,
               "dedupe_key" => "brief:morning:test"
             })

    assert %{sent: 1, failed: 0, skipped: 0} = Briefs.dispatch_telegram_batch(batch_size: 10)

    updated = Repo.get!(Brief, brief.id)
    assert updated.status == "sent"
    assert updated.provider_message_id == "123"

    [message] = Agent.get(:capturing_telegram_recorder, & &1)
    assert message.type == :send
    assert message.chat_id == "777123"
    assert message.text =~ "Morning brief"
    assert get_in(message.opts, [:reply_markup, "inline_keyboard"]) != nil
  end
end
