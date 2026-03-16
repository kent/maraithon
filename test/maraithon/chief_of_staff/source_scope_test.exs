defmodule Maraithon.ChiefOfStaff.SourceScopeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google

  test "resolves all connected Google accounts and Slack workspaces for chief of staff" do
    user_id = "chief-scope@example.com"
    _user = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _founder_google} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-founder-token",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "founder@example.com"}
      })

    {:ok, _ops_google} =
      OAuth.store_tokens(user_id, "google:ops@example.com", %{
        access_token: "google-ops-token",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "ops@example.com"}
      })

    {:ok, _slack_bot} =
      OAuth.store_tokens(user_id, "slack:T12345", %{
        access_token: "xoxb-agora-token",
        scopes: ["channels:read"],
        metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
      })

    {:ok, _slack_user} =
      OAuth.store_tokens(user_id, "slack:T12345:user:U12345", %{
        access_token: "xoxp-agora-token",
        scopes: ["im:read", "search:read"],
        metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
      })

    {:ok, _slack_two_bot} =
      OAuth.store_tokens(user_id, "slack:T67890", %{
        access_token: "xoxb-vote-token",
        scopes: ["channels:read"],
        metadata: %{"team_id" => "T67890", "team_name" => "Vote Agora"}
      })

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    scope = SourceScope.resolve(user_id)

    assert scope["google_accounts"] == [
             %{
               "account_email" => "founder@example.com",
               "provider" => "google:founder@example.com",
               "services" => ["calendar", "gmail"]
             },
             %{
               "account_email" => "ops@example.com",
               "provider" => "google:ops@example.com",
               "services" => ["calendar", "gmail"]
             }
           ]

    assert scope["slack_workspaces"] == [
             %{
               "services" => ["channels", "dms"],
               "team_id" => "T12345",
               "team_name" => "Agora"
             },
             %{
               "services" => ["channels"],
               "team_id" => "T67890",
               "team_name" => "Vote Agora"
             }
           ]

    assert scope["telegram_connected"] == true

    assert SourceScope.subscriptions(scope, user_id) == [
             "email:founder@example.com",
             "email:ops@example.com",
             "calendar:chief-scope@example.com",
             "slack:T12345",
             "slack:T67890"
           ]
  end
end
