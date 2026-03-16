defmodule Maraithon.ChiefOfStaff.SourceScope do
  @moduledoc """
  Resolves the connected Google and Slack sources available to an AI Chief of Staff agent.
  """

  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Token

  def resolve(user_id) when is_binary(user_id) do
    tokens = OAuth.list_user_tokens(user_id)
    accounts = ConnectedAccounts.list_for_user(user_id)

    %{
      "google_accounts" => google_accounts_from_tokens(tokens, accounts),
      "slack_workspaces" => slack_workspaces_from_tokens(tokens),
      "telegram_connected" => telegram_connected?(accounts)
    }
  end

  def resolve(_user_id) do
    %{
      "google_accounts" => [],
      "slack_workspaces" => [],
      "telegram_connected" => false
    }
  end

  def normalize(scope) when is_map(scope) do
    %{
      "google_accounts" =>
        normalize_google_accounts(
          Map.get(scope, "google_accounts", Map.get(scope, :google_accounts, []))
        ),
      "slack_workspaces" =>
        normalize_slack_workspaces(
          Map.get(scope, "slack_workspaces", Map.get(scope, :slack_workspaces, []))
        ),
      "telegram_connected" =>
        truthy?(Map.get(scope, "telegram_connected", Map.get(scope, :telegram_connected, false)))
    }
  end

  def normalize(_scope), do: resolve(nil)

  def google_accounts(scope) do
    scope
    |> normalize()
    |> Map.get("google_accounts", [])
  end

  def google_account_providers(scope, service \\ nil) do
    scope
    |> google_accounts()
    |> Enum.filter(&google_account_supports_service?(&1, service))
    |> Enum.map(&Map.get(&1, "provider"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def google_account_emails(scope, service \\ nil) do
    scope
    |> google_accounts()
    |> Enum.filter(&google_account_supports_service?(&1, service))
    |> Enum.map(&Map.get(&1, "account_email"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def google_account_for_provider(scope, provider) when is_binary(provider) do
    scope
    |> google_accounts()
    |> Enum.find(&(Map.get(&1, "provider") == provider))
  end

  def google_account_for_provider(_scope, _provider), do: nil

  def google_account_for_email(scope, account_email) when is_binary(account_email) do
    normalized_email = normalize_string(account_email)

    scope
    |> google_accounts()
    |> Enum.find(&(normalize_string(Map.get(&1, "account_email")) == normalized_email))
  end

  def google_account_for_email(_scope, _account_email), do: nil

  def google_account_for_email_topic(scope, "email:" <> account_email),
    do: google_account_for_email(scope, account_email)

  def google_account_for_email_topic(_scope, _topic), do: nil

  def slack_workspaces(scope) do
    scope
    |> normalize()
    |> Map.get("slack_workspaces", [])
  end

  def slack_team_ids(scope, service \\ nil) do
    scope
    |> slack_workspaces()
    |> Enum.filter(&slack_workspace_supports_service?(&1, service))
    |> Enum.map(&Map.get(&1, "team_id"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def subscriptions(scope, user_id) when is_binary(user_id) do
    google_topics =
      google_account_emails(scope, "gmail")
      |> Enum.map(&"email:#{&1}")

    calendar_topics =
      case google_account_providers(scope, "calendar") do
        [] -> []
        _providers -> ["calendar:#{user_id}"]
      end

    slack_topics =
      slack_team_ids(scope)
      |> Enum.map(&"slack:#{&1}")

    (google_topics ++ calendar_topics ++ slack_topics)
    |> Enum.uniq()
  end

  def subscriptions(_scope, _user_id), do: []

  defp google_accounts_from_tokens(tokens, accounts) do
    account_by_provider =
      accounts
      |> Enum.map(&{&1.provider, &1})
      |> Map.new()

    tokens
    |> Enum.filter(&google_provider?(&1.provider))
    |> Enum.map(fn token ->
      account = Map.get(account_by_provider, token.provider)
      account_email = google_account_email(token, account)
      services = google_services(token, account)

      %{
        "provider" => token.provider,
        "account_email" => account_email,
        "services" => services
      }
    end)
    |> Enum.filter(fn account ->
      Map.get(account, "services", []) != [] and
        is_binary(Map.get(account, "provider")) and
        Map.get(account, "provider") != ""
    end)
    |> Enum.uniq_by(&Map.get(&1, "provider"))
    |> Enum.sort_by(fn account ->
      {Map.get(account, "account_email") || "~", Map.get(account, "provider")}
    end)
  end

  defp slack_workspaces_from_tokens(tokens) do
    tokens
    |> Enum.filter(&slack_provider?(&1.provider))
    |> Enum.reduce(%{}, fn token, acc ->
      team_id = slack_team_id(token)

      if is_binary(team_id) and team_id != "" do
        Map.update(
          acc,
          team_id,
          %{
            "team_id" => team_id,
            "team_name" => slack_team_name(token),
            "services" => slack_services(token.provider)
          },
          fn workspace ->
            %{
              "team_id" => team_id,
              "team_name" => workspace["team_name"] || slack_team_name(token),
              "services" =>
                Enum.uniq((workspace["services"] || []) ++ slack_services(token.provider))
                |> Enum.sort()
            }
          end
        )
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.sort_by(fn workspace ->
      {Map.get(workspace, "team_name") || "~", Map.get(workspace, "team_id")}
    end)
  end

  defp normalize_google_accounts(accounts) when is_list(accounts) do
    accounts
    |> Enum.map(fn
      account when is_map(account) ->
        %{
          "provider" => normalize_string(Map.get(account, "provider")),
          "account_email" => normalize_string(Map.get(account, "account_email")),
          "services" => normalize_services(Map.get(account, "services", []))
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn account ->
      is_binary(account["provider"]) and account["provider"] != ""
    end)
    |> Enum.uniq_by(&Map.get(&1, "provider"))
    |> Enum.sort_by(fn account ->
      {Map.get(account, "account_email") || "~", Map.get(account, "provider")}
    end)
  end

  defp normalize_google_accounts(_accounts), do: []

  defp normalize_slack_workspaces(workspaces) when is_list(workspaces) do
    workspaces
    |> Enum.map(fn
      workspace when is_map(workspace) ->
        %{
          "team_id" => normalize_string(Map.get(workspace, "team_id")),
          "team_name" => normalize_string(Map.get(workspace, "team_name")),
          "services" => normalize_services(Map.get(workspace, "services", []))
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn workspace ->
      is_binary(workspace["team_id"]) and workspace["team_id"] != ""
    end)
    |> Enum.uniq_by(&Map.get(&1, "team_id"))
    |> Enum.sort_by(fn workspace ->
      {Map.get(workspace, "team_name") || "~", Map.get(workspace, "team_id")}
    end)
  end

  defp normalize_slack_workspaces(_workspaces), do: []

  defp google_account_supports_service?(_account, nil), do: true

  defp google_account_supports_service?(account, service) when is_binary(service) do
    service in Map.get(account, "services", [])
  end

  defp google_account_supports_service?(_account, _service), do: false

  defp slack_workspace_supports_service?(_workspace, nil), do: true

  defp slack_workspace_supports_service?(workspace, service) when is_binary(service) do
    service in Map.get(workspace, "services", [])
  end

  defp slack_workspace_supports_service?(_workspace, _service), do: false

  defp google_account_email(%Token{} = token, account) do
    metadata = token.metadata || %{}
    account_metadata = (account && account.metadata) || %{}

    normalize_string(metadata["account_email"]) ||
      normalize_string(metadata["email"]) ||
      normalize_string(account_metadata["account_email"]) ||
      normalize_string(account_metadata["email"]) ||
      google_provider_account(token.provider)
  end

  defp google_services(%Token{} = token, account) do
    token.metadata
    |> services_from_metadata()
    |> case do
      [] ->
        services =
          token.scopes
          |> List.wrap()
          |> Enum.flat_map(&google_services_from_scope/1)
          |> Kernel.++(
            account
            |> account_scopes()
            |> Enum.flat_map(&google_services_from_scope/1)
          )
          |> Enum.uniq()
          |> Enum.sort()

        if services == [] and google_provider?(token.provider) do
          ["calendar", "gmail"]
        else
          services
        end

      services ->
        services
    end
  end

  defp services_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.get("services", [])
    |> normalize_services()
  end

  defp services_from_metadata(_metadata), do: []

  defp account_scopes(%{scopes: scopes}) when is_list(scopes), do: scopes
  defp account_scopes(_account), do: []

  defp normalize_services(services) when is_list(services) do
    services
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1 in ["gmail", "calendar", "channels", "dms"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_services(_services), do: []

  defp google_services_from_scope(scope) when is_binary(scope) do
    normalized = String.downcase(scope)

    []
    |> maybe_append("gmail", String.contains?(normalized, "gmail"))
    |> maybe_append("calendar", String.contains?(normalized, "calendar"))
  end

  defp google_services_from_scope(_scope), do: []

  defp slack_services("slack:" <> rest) when is_binary(rest) do
    parts = String.split(rest, ":", parts: 3)

    case parts do
      [_team_id] -> ["channels"]
      [_team_id, "user", _slack_user_id] -> ["dms"]
      _ -> []
    end
  end

  defp slack_services(_provider), do: []

  defp slack_team_id(%Token{} = token) do
    metadata = token.metadata || %{}

    normalize_string(metadata["team_id"]) ||
      case Regex.run(~r/^slack:([^:]+)(?::user:[^:]+)?$/, token.provider, capture: :all_but_first) do
        [team_id] -> team_id
        _ -> nil
      end
  end

  defp slack_team_name(%Token{} = token) do
    token.metadata
    |> Kernel.||(%{})
    |> Map.get("team_name")
    |> normalize_string()
  end

  defp telegram_connected?(accounts) when is_list(accounts) do
    Enum.any?(accounts, fn account ->
      account.provider == "telegram" and account.status == "connected"
    end)
  end

  defp telegram_connected?(_accounts), do: false

  defp google_provider?(provider) when is_binary(provider) do
    provider == "google" or String.starts_with?(provider, "google:")
  end

  defp google_provider?(_provider), do: false

  defp slack_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "slack:")
  end

  defp slack_provider?(_provider), do: false

  defp google_provider_account("google:" <> account) when is_binary(account) do
    account = normalize_string(account)

    if account && String.starts_with?(account, "sub-") do
      nil
    else
      account
    end
  end

  defp google_provider_account(_provider), do: nil

  defp maybe_append(list, _value, false), do: list
  defp maybe_append(list, value, true), do: [value | list]

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false
end
