defmodule Maraithon.ConnectedAccountsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    Application.put_env(:maraithon, :connected_accounts,
      telegram_module: CapturingTelegram,
      reconnect_base_url: "https://maraithon.test"
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :connected_accounts)
    end)

    :ok
  end

  test "mark_error/3 sends one Telegram reconnect alert for oauth_reauth_required" do
    user_id = "reauth-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    # Repeated error writes should not spam duplicate notifications.
    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    messages = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert [
             %{
               chat_id: "6114124042",
               text: text
             }
           ] = messages

    assert text =~ "founder@example.com"
    assert text =~ "https://maraithon.test/connectors/google"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert get_in(account.metadata, ["reauth_notification", "reason"]) == "oauth_reauth_required"
    assert is_binary(get_in(account.metadata, ["reauth_notification", "sent_at"]))
  end
end
