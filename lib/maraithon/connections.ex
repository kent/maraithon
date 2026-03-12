defmodule Maraithon.Connections do
  @moduledoc """
  Admin-facing connection inventory for integrations.
  """

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.OAuth
  alias Maraithon.OAuth.{GitHub, Google, Linear, Notaui, Notion, Slack, Token}

  @google_services [
    %{
      id: "gmail",
      label: "Gmail",
      description: "Watch inbox changes and thread context."
    },
    %{
      id: "calendar",
      label: "Google Calendar",
      description: "Track upcoming events and schedule changes."
    },
    %{
      id: "contacts",
      label: "Google Contacts",
      description: "Read your People/Contacts graph for context."
    }
  ]

  @doc """
  Returns the default control-center user id used for OAuth grants.
  """
  def default_user_id do
    Application.get_env(:maraithon, :admin_control, [])
    |> Keyword.get(:default_user_id, "operator")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "operator"
      value -> value
    end
  end

  @doc """
  Returns a safe snapshot of connectable integrations for the given user.
  """
  def safe_dashboard_snapshot(user_id, opts \\ []) when is_binary(user_id) do
    return_to = Keyword.get(opts, :return_to, "/")

    case safe_fetch(fn -> dashboard_snapshot(user_id, return_to: return_to) end) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, reason} ->
        {:degraded, fallback_snapshot(user_id, return_to, reason)}
    end
  end

  @doc """
  Returns the connection dashboard snapshot for the given user.
  """
  def dashboard_snapshot(user_id, opts \\ []) when is_binary(user_id) do
    return_to = Keyword.get(opts, :return_to, "/")
    connected_accounts = ConnectedAccounts.list_for_user(user_id)

    tokens =
      OAuth.list_user_tokens(user_id)
      |> Enum.sort_by(&provider_sort_key/1)

    account_by_provider = Map.new(connected_accounts, &{&1.provider, &1})
    token_by_provider = Map.new(tokens, &{&1.provider, &1})
    google_tokens = Enum.filter(tokens, &google_provider?(&1.provider))
    slack_tokens = Enum.filter(tokens, &slack_provider?(&1.provider))
    telegram_account = ConnectedAccounts.get(user_id, "telegram")

    providers = [
      google_card(user_id, google_tokens, account_by_provider, return_to),
      github_card(user_id, token_by_provider["github"], account_by_provider["github"], return_to),
      slack_card(user_id, slack_tokens, account_by_provider, return_to),
      linear_card(user_id, token_by_provider["linear"], account_by_provider["linear"], return_to),
      notion_card(user_id, token_by_provider["notion"], account_by_provider["notion"], return_to),
      notaui_card(user_id, token_by_provider["notaui"], account_by_provider["notaui"], return_to),
      telegram_card(user_id, telegram_account, return_to)
    ]

    %{
      user_id: user_id,
      providers: providers,
      raw_tokens: Enum.map(tokens, &serialize_token/1),
      connected_count: Enum.count(providers, &(&1.status in [:connected, :partial])),
      degraded: false,
      errors: []
    }
  end

  @doc """
  Disconnects a provider grant for the given control-center user.
  """
  def disconnect(user_id, "google") when is_binary(user_id) do
    google_providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&google_provider?/1)
      |> Enum.uniq()

    case google_providers do
      [] ->
        {:error, :no_token}

      providers ->
        revoke_many(user_id, providers)
    end
  end

  def disconnect(user_id, "google:" <> _ = provider) when is_binary(user_id) do
    OAuth.revoke(user_id, provider)
  end

  def disconnect(user_id, "slack") when is_binary(user_id) do
    slack_providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&slack_provider?/1)
      |> Enum.uniq()

    case slack_providers do
      [] ->
        {:error, :no_token}

      providers ->
        revoke_many(user_id, providers)
    end
  end

  def disconnect(user_id, "telegram") when is_binary(user_id) do
    ConnectedAccounts.mark_disconnected(user_id, "telegram")
  end

  def disconnect(user_id, provider)
      when is_binary(user_id) and is_binary(provider) and
             provider in ["github", "linear", "notaui", "notion"] do
    OAuth.revoke(user_id, provider)
  end

  def disconnect(_user_id, _provider), do: {:error, :unsupported_provider}

  defp revoke_many(user_id, providers) when is_binary(user_id) and is_list(providers) do
    errors =
      Enum.reduce(providers, [], fn provider, acc ->
        case OAuth.revoke(user_id, provider) do
          {:ok, _deleted} -> acc
          {:error, :no_token} -> acc
          {:error, reason} -> [{provider, reason} | acc]
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, %{revoked: length(providers)}}
      failures -> {:error, {:partial_disconnect, failures}}
    end
  end

  defp fallback_snapshot(user_id, return_to, reason) do
    providers =
      [
        google_card(user_id, [], %{}, return_to),
        github_card(user_id, nil, nil, return_to),
        slack_card(user_id, [], %{}, return_to),
        linear_card(user_id, nil, nil, return_to),
        notion_card(user_id, nil, nil, return_to),
        notaui_card(user_id, nil, nil, return_to),
        telegram_card(user_id, nil, return_to)
      ]
      |> Enum.map(&mark_unavailable/1)

    %{
      user_id: user_id,
      providers: providers,
      raw_tokens: [],
      connected_count: 0,
      degraded: true,
      errors: [
        %{
          message: "Connection inventory is temporarily unavailable.",
          details: Exception.message(reason)
        }
      ]
    }
  end

  defp google_card(user_id, tokens, account_by_provider, return_to)
       when is_list(tokens) and is_map(account_by_provider) do
    configured? = Google.configured?()
    primary_token = primary_google_token(tokens)
    account_entries = google_account_entries(user_id, tokens, account_by_provider, return_to)
    granted_scope_count = tokens |> Enum.flat_map(&token_scopes/1) |> Enum.uniq() |> length()
    reauth_required? = Enum.any?(account_entries, &(&1.status == :needs_refresh))

    services =
      Enum.map(@google_services, fn service ->
        required_scopes = Google.scopes_for([service.id])

        connected? =
          Enum.any?(tokens, fn token ->
            google_service_connected?(token, required_scopes) and
              token_account_status(token, account_by_provider) != :needs_refresh
          end)

        %{
          id: service.id,
          label: service.label,
          description: service.description,
          status: google_service_status(configured?, tokens, connected?),
          connect_url: auth_url("/auth/google", user_id, return_to, scopes: service.id)
        }
      end)

    status =
      cond do
        not configured? -> :not_configured
        tokens == [] -> :disconnected
        reauth_required? -> :needs_refresh
        Enum.all?(services, &(&1.status == :connected)) -> :connected
        true -> :partial
      end

    %{
      id: "google",
      provider: "google",
      label: "Google Workspace",
      description: "Server-side OAuth for Gmail, Calendar, and Contacts.",
      status: status,
      configured?: configured?,
      updated_at: latest_updated_at(tokens),
      disconnectable?: tokens != [],
      connect_url:
        auth_url("/auth/google", user_id, return_to, scopes: "gmail,calendar,contacts"),
      disconnect_label: "Disconnect Google",
      details:
        google_details(primary_token, [
          if(account_entries != [],
            do:
              "Connected accounts: #{account_entries |> Enum.map(& &1.account) |> Enum.join(", ")}"
          ),
          "Granted #{granted_scope_count} Google OAuth scopes"
        ]),
      services: services,
      accounts: account_entries
    }
    |> enrich_provider_setup()
  end

  defp github_card(user_id, token, account, return_to) do
    configured? = GitHub.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/github",
        &github_account_label/1
      )

    %{
      id: "github",
      provider: "github",
      label: "GitHub",
      description: "Grant repo and org access so agents can inspect issues and comment back.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/github", user_id, return_to),
      disconnect_label: "Disconnect GitHub",
      details:
        provider_details(token, [
          metadata_value(token, ["login"]) && "@#{metadata_value(token, ["login"])}",
          metadata_value(token, ["email"]),
          "Scopes: #{Enum.join(token_scopes(token), ", ")}"
        ]),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp slack_card(user_id, tokens, account_by_provider, return_to)
       when is_list(tokens) and is_map(account_by_provider) do
    configured? = Slack.configured?()
    bot_token = slack_bot_token(tokens)
    user_tokens = slack_user_tokens(tokens)
    first_user_token = List.first(user_tokens)
    bot_scopes = token_scope_set(bot_token)
    account_entries = slack_account_entries(user_id, tokens, account_by_provider, return_to)
    reauth_required? = Enum.any?(account_entries, &(&1.status == :needs_refresh))

    workspace_names =
      tokens
      |> Enum.map(fn token -> metadata_value(token, ["team_name"]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    status =
      cond do
        not configured? -> :not_configured
        is_nil(bot_token) -> :disconnected
        reauth_required? -> :needs_refresh
        user_tokens == [] -> :partial
        true -> :connected
      end

    details =
      provider_details(bot_token, [
        if(workspace_names != [], do: "Workspaces: #{Enum.join(workspace_names, ", ")}"),
        "Bot scopes: #{MapSet.size(bot_scopes)} granted",
        if(user_tokens != [], do: "Personal Slack access connected for DM scans."),
        if(user_tokens == [],
          do:
            "Reconnect Slack with user scopes enabled to scan personal DMs and private follow-through."
        )
      ])

    services = [
      %{
        id: "channels",
        label: "Channels",
        description: "Track commitments and unresolved action loops in channel conversations.",
        status:
          slack_service_status(
            configured?,
            bot_token,
            bot_token && Map.get(account_by_provider, bot_token.provider)
          )
      },
      %{
        id: "dms",
        label: "Personal DMs",
        description: "Read DM and MPIM context to catch reply debt and private commitments.",
        status:
          slack_service_status(
            configured?,
            first_user_token,
            first_user_token && Map.get(account_by_provider, first_user_token.provider)
          )
      }
    ]

    %{
      id: "slack",
      provider: "slack",
      label: "Slack",
      description:
        "Install Maraithon in Slack to track open loops in channels and personal messages.",
      status: status,
      configured?: configured?,
      updated_at: latest_updated_at(tokens),
      disconnectable?: tokens != [],
      connect_url: auth_url("/auth/slack", user_id, return_to),
      disconnect_label: "Disconnect Slack",
      details: details,
      services: services,
      accounts: account_entries
    }
    |> enrich_provider_setup()
  end

  defp linear_card(user_id, token, account, return_to) do
    configured? = Linear.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/linear",
        &linear_account_label/1
      )

    team_names =
      token
      |> metadata_value(["teams"])
      |> normalize_list()
      |> Enum.map(fn
        %{"key" => key, "name" => name} when is_binary(key) and is_binary(name) ->
          "#{name} (#{key})"

        %{"key" => key} when is_binary(key) ->
          key

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    %{
      id: "linear",
      provider: "linear",
      label: "Linear",
      description: "Connect your Linear workspace for issue review and issue/comment actions.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/linear", user_id, return_to),
      disconnect_label: "Disconnect Linear",
      details:
        provider_details(token, [
          if(team_names != [], do: "Teams: #{Enum.join(team_names, ", ")}"),
          "Scopes: #{Enum.join(token_scopes(token), ", ")}"
        ]),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp telegram_card(user_id, account, return_to) do
    configured? = Telegram.configured?()
    metadata = if account, do: account.metadata || %{}, else: %{}
    chat_id = account && (account.external_account_id || metadata["chat_id"])
    username = metadata["username"]

    status =
      cond do
        not configured? -> :not_configured
        account && account.status == "connected" -> :connected
        true -> :disconnected
      end

    %{
      id: "telegram",
      provider: "telegram",
      label: "Telegram Bot",
      description: "Receive urgent Maraithon insights with inline helpful/not-helpful feedback.",
      status: status,
      configured?: configured?,
      updated_at: account && account.updated_at,
      disconnectable?: account && account.status == "connected",
      connect_url: auth_url("/connectors/telegram", user_id, return_to),
      disconnect_label: "Disconnect Telegram",
      details:
        if account && account.status == "connected" do
          [
            telegram_chat_detail(chat_id),
            if(is_binary(username) and username != "", do: "@#{username}"),
            "Last updated #{format_datetime(account.updated_at)}"
          ]
          |> Enum.reject(&is_nil/1)
        else
          ["Not linked yet. Send /start #{user_id} to your bot chat."]
        end,
      services: []
    }
    |> enrich_provider_setup()
  end

  defp notion_card(user_id, token, account, return_to) do
    configured? = Notion.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/notion",
        &notion_account_label/1
      )

    %{
      id: "notion",
      provider: "notion",
      label: "Notion",
      description: "Store a workspace grant now so Notion data can feed future agents and tools.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/notion", user_id, return_to),
      disconnect_label: "Disconnect Notion",
      details:
        provider_details(token, [
          metadata_value(token, ["workspace_name"]),
          metadata_value(token, ["workspace_id"]) &&
            "Workspace ID: #{metadata_value(token, ["workspace_id"])}"
        ]),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp notaui_card(user_id, token, account, return_to) do
    configured? = Notaui.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/notaui",
        &notaui_account_label/1
      )

    %{
      id: "notaui",
      provider: "notaui",
      label: "Notaui",
      description:
        "Connect your Notaui workspace so Maraithon can read and update tasks over MCP.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/notaui", user_id, return_to),
      disconnect_label: "Disconnect Notaui",
      details: provider_details(token, notaui_details(token, account)),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp auth_url(path, user_id, return_to, extra_params \\ []) do
    params =
      [{"user_id", user_id}, {"return_to", return_to}]
      |> Kernel.++(Enum.map(extra_params, fn {key, value} -> {Atom.to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    "#{path}?#{URI.encode_query(params)}"
  end

  defp google_service_connected?(nil, _required_scopes), do: false

  defp google_service_connected?(token, required_scopes) do
    MapSet.subset?(MapSet.new(required_scopes), token_scope_set(token))
  end

  defp google_service_status(false, _tokens, _connected?), do: :not_configured
  defp google_service_status(true, [], _connected?), do: :disconnected
  defp google_service_status(true, _tokens, true), do: :connected
  defp google_service_status(true, _tokens, false), do: :missing_scope

  defp provider_status(false, _token, _account), do: :not_configured
  defp provider_status(true, nil, _account), do: :disconnected

  defp provider_status(true, _token, account) do
    if reauth_required_account?(account), do: :needs_refresh, else: :connected
  end

  defp google_details(nil, items), do: provider_details(nil, items)

  defp google_details(token, items) do
    granted =
      @google_services
      |> Enum.filter(fn service ->
        google_service_connected?(token, Google.scopes_for([service.id]))
      end)
      |> Enum.map(& &1.label)

    provider_details(token, [
      if(granted != [], do: "Enabled: #{Enum.join(granted, ", ")}")
      | items
    ])
  end

  defp provider_details(nil, _items), do: ["Not connected yet."]

  defp provider_details(token, items) do
    connected_at = "Last updated #{format_datetime(token.updated_at)}"

    [connected_at | items]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == "Scopes: "))
  end

  defp telegram_chat_detail(chat_id) when is_binary(chat_id) and chat_id != "",
    do: "Chat ID #{chat_id}"

  defp telegram_chat_detail(_chat_id), do: "Chat connected"

  defp serialize_token(%Token{} = token) do
    %{
      provider: token.provider,
      updated_at: token.updated_at,
      expires_at: token.expires_at,
      scopes: token.scopes,
      metadata: token.metadata
    }
  end

  defp token_scopes(nil), do: []
  defp token_scopes(%Token{scopes: scopes}) when is_list(scopes), do: scopes
  defp token_scopes(_token), do: []

  defp token_scope_set(token) do
    token
    |> token_scopes()
    |> MapSet.new()
  end

  defp metadata_value(nil, _path), do: nil

  defp metadata_value(%Token{metadata: metadata}, path) when is_list(path) do
    get_in(metadata, path) || get_in(metadata, Enum.map(path, &string_or_existing_atom/1))
  rescue
    ArgumentError -> nil
  end

  defp string_or_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_value), do: []

  defp google_account_entries(user_id, tokens, account_by_provider, return_to)
       when is_binary(user_id) and is_list(tokens) and is_map(account_by_provider) do
    reconnect_url =
      auth_url("/auth/google", user_id, return_to, scopes: "gmail,calendar,contacts")

    tokens
    |> Enum.filter(&google_provider?(&1.provider))
    |> Enum.map(fn token ->
      status = token_account_status(token, account_by_provider)

      %{
        provider: token.provider,
        account: google_account_label(token),
        updated_at: token_or_account_updated_at(token, account_by_provider),
        status: status,
        status_note: token_account_status_note(token, account_by_provider),
        reconnect_url: reconnect_url,
        needs_reconnect?: status == :needs_refresh
      }
    end)
    |> Enum.sort_by(&timestamp_sort_value(&1.updated_at), :desc)
  end

  defp primary_google_token(tokens) when is_list(tokens) do
    Enum.find(tokens, &(&1.provider == "google")) ||
      Enum.max_by(tokens, &timestamp_sort_value(&1.updated_at), fn -> nil end)
  end

  defp google_account_label(%Token{} = token) do
    normalize_text(metadata_value(token, ["account_email"])) ||
      normalize_text(metadata_value(token, ["email"])) ||
      google_provider_suffix(token.provider) ||
      "Google account"
  end

  defp google_account_label(_token), do: "Google account"

  defp google_provider_suffix("google"), do: nil

  defp google_provider_suffix(provider) when is_binary(provider) do
    case String.split(provider, ":", parts: 2) do
      ["google", suffix] ->
        normalize_text(suffix)

      _ ->
        nil
    end
  end

  defp google_provider_suffix(_provider), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp normalize_metadata_map(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata_map(_metadata), do: %{}

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp google_provider?("google"), do: true

  defp google_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "google:")
  end

  defp google_provider?(_provider), do: false

  defp slack_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "slack:")
  end

  defp slack_provider?(_provider), do: false

  defp slack_bot_token(tokens) when is_list(tokens) do
    Enum.find(tokens, &slack_bot_provider?(&1.provider))
  end

  defp slack_user_tokens(tokens) when is_list(tokens) do
    Enum.filter(tokens, &slack_user_provider?(&1.provider))
  end

  defp slack_bot_provider?(provider) when is_binary(provider) do
    Regex.match?(~r/^slack:[^:]+$/, provider)
  end

  defp slack_bot_provider?(_provider), do: false

  defp slack_user_provider?(provider) when is_binary(provider) do
    Regex.match?(~r/^slack:[^:]+:user:[^:]+$/, provider)
  end

  defp slack_user_provider?(_provider), do: false

  defp slack_account_entries(user_id, tokens, account_by_provider, return_to)
       when is_binary(user_id) and is_list(tokens) and is_map(account_by_provider) do
    reconnect_url = auth_url("/auth/slack", user_id, return_to)

    tokens
    |> Enum.filter(&slack_provider?(&1.provider))
    |> Enum.map(fn token ->
      status = token_account_status(token, account_by_provider)

      %{
        provider: token.provider,
        account: slack_account_label(token),
        updated_at: token_or_account_updated_at(token, account_by_provider),
        status: status,
        status_note: token_account_status_note(token, account_by_provider),
        reconnect_url: reconnect_url,
        needs_reconnect?: status == :needs_refresh
      }
    end)
    |> Enum.sort_by(&timestamp_sort_value(&1.updated_at), :desc)
  end

  defp slack_service_status(false, _token, _account), do: :not_configured
  defp slack_service_status(true, nil, _account), do: :disconnected

  defp slack_service_status(true, _token, account) do
    if reauth_required_account?(account), do: :needs_refresh, else: :connected
  end

  defp single_oauth_account_entry(
         user_id,
         %Token{} = token,
         account,
         return_to,
         connect_path,
         label_fun
       )
       when is_binary(user_id) and is_binary(return_to) and is_binary(connect_path) and
              is_function(label_fun, 1) do
    account_by_provider = %{token.provider => account}
    status = token_account_status(token, account_by_provider)

    %{
      provider: token.provider,
      account: label_fun.(token),
      updated_at: token_or_account_updated_at(token, account_by_provider),
      status: status,
      status_note: token_account_status_note(token, account_by_provider),
      reconnect_url: auth_url(connect_path, user_id, return_to),
      needs_reconnect?: status == :needs_refresh
    }
  end

  defp single_oauth_account_entry(
         _user_id,
         _token,
         _account,
         _return_to,
         _connect_path,
         _label_fun
       ),
       do: nil

  defp maybe_single_account_entry(nil), do: []
  defp maybe_single_account_entry(entry), do: [entry]

  defp token_account_status(%Token{} = token, account_by_provider)
       when is_map(account_by_provider) do
    account = Map.get(account_by_provider, token.provider)

    cond do
      reauth_required_account?(account) -> :needs_refresh
      token_expired_without_refresh?(token) -> :needs_refresh
      true -> :connected
    end
  end

  defp token_account_status(_token, _account_by_provider), do: :disconnected

  defp token_account_status_note(%Token{} = token, account_by_provider)
       when is_map(account_by_provider) do
    account = Map.get(account_by_provider, token.provider)
    reason = account_error_reason(account)

    cond do
      reauth_required_account?(account) and reason == "oauth_missing_refresh_token" ->
        "No refresh token is stored for this account. Reconnect required."

      reauth_required_account?(account) ->
        "Token refresh failed and the account must be re-authenticated."

      token_expired_without_refresh?(token) ->
        "Token is expired and cannot be refreshed automatically."

      true ->
        "Healthy"
    end
  end

  defp token_account_status_note(_token, _account_by_provider), do: "Healthy"

  defp token_or_account_updated_at(%Token{} = token, account_by_provider)
       when is_map(account_by_provider) do
    account = Map.get(account_by_provider, token.provider)
    account_updated_at = account && account.updated_at

    [token.updated_at, account_updated_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp token_or_account_updated_at(%Token{} = token, _account_by_provider), do: token.updated_at
  defp token_or_account_updated_at(_token, _account_by_provider), do: nil

  defp reauth_required_account?(%ConnectedAccount{status: "error"} = account) do
    account_error_reason(account) in ["oauth_reauth_required", "oauth_missing_refresh_token"]
  end

  defp reauth_required_account?(_account), do: false

  defp account_error_reason(nil), do: nil

  defp account_error_reason(%ConnectedAccount{metadata: metadata}) do
    metadata
    |> normalize_metadata_map()
    |> fetch_map_value("last_error")
    |> case do
      value when is_map(value) -> fetch_map_value(value, "reason")
      _ -> nil
    end
    |> normalize_text()
  end

  defp token_expired_without_refresh?(%Token{expires_at: nil}), do: false

  defp token_expired_without_refresh?(%Token{expires_at: expires_at, refresh_token: refresh_token})
       when not is_nil(expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt and not present?(refresh_token)
  rescue
    ArgumentError -> false
  end

  defp token_expired_without_refresh?(_token), do: false

  defp slack_account_label(%Token{} = token) do
    team = normalize_text(metadata_value(token, ["team_name"])) || "Slack workspace"

    if slack_user_provider?(token.provider) do
      slack_user_id = normalize_text(metadata_value(token, ["slack_user_id"])) || "user"
      "#{team} · DM user #{slack_user_id}"
    else
      "#{team} · Bot"
    end
  end

  defp slack_account_label(_token), do: "Slack account"

  defp github_account_label(%Token{} = token) do
    login =
      token
      |> metadata_value(["login"])
      |> normalize_text()

    email =
      token
      |> metadata_value(["email"])
      |> normalize_text()

    cond do
      present?(login) and present?(email) -> "@#{login} (#{email})"
      present?(login) -> "@#{login}"
      present?(email) -> email
      true -> "GitHub account"
    end
  end

  defp github_account_label(_token), do: "GitHub account"

  defp linear_account_label(%Token{} = token) do
    first_team_name =
      token
      |> metadata_value(["teams"])
      |> normalize_list()
      |> Enum.find_value(fn
        %{"name" => name} when is_binary(name) and name != "" -> name
        _ -> nil
      end)

    normalize_text(first_team_name) || "Linear workspace"
  end

  defp linear_account_label(_token), do: "Linear workspace"

  defp notion_account_label(%Token{} = token) do
    normalize_text(metadata_value(token, ["workspace_name"])) ||
      normalize_text(metadata_value(token, ["workspace_id"])) || "Notion workspace"
  end

  defp notion_account_label(_token), do: "Notion workspace"

  defp notaui_account_label(%Token{} = token) do
    normalize_text(metadata_value(token, ["default_account_label"])) ||
      normalize_text(metadata_value(token, ["default_account_id"])) ||
      normalize_text(metadata_value(token, ["subject"])) ||
      "Notaui workspace"
  end

  defp notaui_account_label(_token), do: "Notaui workspace"

  defp notaui_details(token, account) do
    [
      notaui_default_account_detail(token, account),
      notaui_account_count_detail(token, account),
      notaui_discovery_detail(token, account),
      provider_snapshot_value(account, token, "issuer") &&
        "Issuer: #{provider_snapshot_value(account, token, "issuer")}",
      provider_snapshot_value(account, token, "mcp_url") &&
        "MCP: #{provider_snapshot_value(account, token, "mcp_url")}",
      "Scopes: #{Enum.join(token_scopes(token), ", ")}"
    ]
  end

  defp notaui_default_account_detail(token, account) do
    default_label =
      provider_snapshot_value(account, token, "default_account_label") ||
        provider_snapshot_value(account, token, "default_account_id")

    if present?(default_label), do: "Default account: #{default_label}"
  end

  defp notaui_account_count_detail(token, account) do
    case provider_snapshot_value(account, token, "account_count") |> normalize_integer() do
      count when is_integer(count) and count > 0 ->
        "Discovered #{count} accessible account#{plural_suffix(count)}"

      0 ->
        "No accessible Notaui accounts were discovered yet."

      _ ->
        nil
    end
  end

  defp notaui_discovery_detail(token, account) do
    if provider_snapshot_value(account, token, "discovery_error") do
      "Account discovery needs attention. Reconnect Notaui if account access looks incomplete."
    end
  end

  defp provider_snapshot_value(account, token, key) when is_binary(key) do
    account_metadata_value(account, key) || metadata_value(token, [key])
  end

  defp account_metadata_value(%ConnectedAccount{metadata: metadata}, key) when is_binary(key) do
    metadata
    |> normalize_metadata_map()
    |> fetch_map_value(key)
  end

  defp account_metadata_value(_account, _key), do: nil

  defp latest_updated_at([]), do: nil

  defp latest_updated_at(tokens) when is_list(tokens) do
    tokens
    |> Enum.map(& &1.updated_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp timestamp_sort_value(%NaiveDateTime{} = value) do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, datetime} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp timestamp_sort_value(_value), do: 0

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  defp provider_sort_key(%Token{provider: provider}) do
    cond do
      google_provider?(provider) -> 0
      provider == "github" -> 1
      slack_provider?(provider) -> 2
      provider == "linear" -> 3
      provider == "notion" -> 4
      provider == "notaui" -> 5
      true -> 99
    end
  end

  defp mark_unavailable(provider) do
    provider
    |> Map.put(:status, :unknown)
    |> Map.update!(:details, fn details ->
      ["Token store temporarily unavailable." | details]
    end)
    |> Map.update!(:services, fn services ->
      Enum.map(services, &Map.put(&1, :status, :unknown))
    end)
    |> Map.update(:accounts, [], fn accounts ->
      Enum.map(accounts, &Map.put(&1, :status, :unknown))
    end)
  end

  defp enrich_provider_setup(provider) do
    setup = provider_setup(provider.provider)
    required_envs = Enum.filter(setup.env_requirements, & &1.required?)

    setup_status =
      cond do
        required_envs == [] -> :configured
        Enum.all?(required_envs, & &1.present?) -> :configured
        true -> :incomplete
      end

    Map.merge(provider, %{
      logo: setup.logo,
      permissions: setup.permissions,
      callback_urls: setup.callback_urls,
      env_requirements: setup.env_requirements,
      setup_notes: setup.setup_notes,
      setup_status: setup_status
    })
  end

  defp provider_setup("google") do
    oauth_callback = callback_url("/auth/google/callback")
    calendar_webhook = callback_url("/webhooks/google/calendar")
    gmail_webhook = callback_url("/webhooks/google/gmail")

    %{
      logo: :google,
      permissions: [
        "Gmail read-only mailbox access",
        "Google Calendar read-only event access",
        "Google Contacts read-only People API access"
      ],
      callback_urls: [
        %{label: "OAuth callback", url: oauth_callback, required?: true},
        %{label: "Calendar webhook callback", url: calendar_webhook, required?: false},
        %{label: "Gmail Pub/Sub push callback", url: gmail_webhook, required?: false}
      ],
      env_requirements: [
        env_requirement(
          "GOOGLE_CLIENT_ID",
          config_value(:google, :client_id),
          "Google OAuth client ID",
          true
        ),
        env_requirement(
          "GOOGLE_CLIENT_SECRET",
          config_value(:google, :client_secret),
          "Google OAuth client secret",
          true
        ),
        env_requirement(
          "GOOGLE_REDIRECT_URI",
          config_value(:google, :redirect_uri),
          "Must match the Google OAuth redirect URI",
          true,
          oauth_callback
        ),
        env_requirement(
          "GOOGLE_CALENDAR_WEBHOOK_URL",
          config_value(:google, :calendar_webhook_url),
          "Used when registering Calendar watches",
          false,
          calendar_webhook
        ),
        env_requirement(
          "GOOGLE_PUBSUB_TOPIC",
          config_value(:google, :pubsub_topic),
          "Pub/Sub topic used for Gmail push delivery",
          false
        )
      ],
      setup_notes: [
        "Register the OAuth redirect URI in Google Cloud Console.",
        "Set the OAuth consent screen publishing status to Production to avoid short-lived testing refresh tokens.",
        "If you want Calendar watches, point GOOGLE_CALENDAR_WEBHOOK_URL at the calendar webhook callback.",
        "If you want Gmail push, grant Gmail Pub/Sub push access to the Gmail webhook callback."
      ]
    }
  end

  defp provider_setup("github") do
    %{
      logo: :github,
      permissions: [
        "repo",
        "read:org",
        "notifications",
        "user:email"
      ],
      callback_urls: [
        %{label: "OAuth callback", url: callback_url("/auth/github/callback"), required?: true},
        %{label: "Webhook callback", url: callback_url("/webhooks/github"), required?: false}
      ],
      env_requirements: [
        env_requirement(
          "GITHUB_CLIENT_ID",
          config_value(:github, :client_id),
          "GitHub OAuth app client ID",
          true
        ),
        env_requirement(
          "GITHUB_CLIENT_SECRET",
          config_value(:github, :client_secret),
          "GitHub OAuth app client secret",
          true
        ),
        env_requirement(
          "GITHUB_REDIRECT_URI",
          config_value(:github, :redirect_uri),
          "Must match the GitHub OAuth callback URL",
          true,
          callback_url("/auth/github/callback")
        ),
        env_requirement(
          "GITHUB_WEBHOOK_SECRET",
          config_value(:github, :webhook_secret),
          "Used to verify repository webhooks",
          false
        ),
        env_requirement(
          "GITHUB_ACCESS_TOKEN",
          config_value(:github, :api_token),
          "Optional fallback token for repo actions when no user grant is provided",
          false
        )
      ],
      setup_notes: [
        "Create a GitHub OAuth App and register the OAuth callback URL.",
        "For repo events, add a repository or org webhook pointing at the GitHub webhook callback.",
        "Agents can use a per-user GitHub grant or the optional fallback access token."
      ]
    }
  end

  defp provider_setup("slack") do
    oauth_callback = callback_url("/auth/slack/callback")
    events_callback = callback_url("/webhooks/slack")

    %{
      logo: :slack,
      permissions: [
        "Read channel and thread history",
        "Read DM and MPIM history with user scopes",
        "Post messages back into channels",
        "Process Slack Events API webhooks for near-real-time updates"
      ],
      callback_urls: [
        %{label: "OAuth callback", url: oauth_callback, required?: true},
        %{label: "Events callback", url: events_callback, required?: true}
      ],
      env_requirements: [
        env_requirement(
          "SLACK_CLIENT_ID",
          config_value(:slack, :client_id),
          "Slack app client ID",
          true
        ),
        env_requirement(
          "SLACK_CLIENT_SECRET",
          config_value(:slack, :client_secret),
          "Slack app client secret",
          true
        ),
        env_requirement(
          "SLACK_REDIRECT_URI",
          config_value(:slack, :redirect_uri),
          "Must match the Slack OAuth callback URL",
          true,
          oauth_callback
        ),
        env_requirement(
          "SLACK_SIGNING_SECRET",
          config_value(:slack, :signing_secret),
          "Used to verify Slack Events API signatures",
          true
        )
      ],
      setup_notes: [
        "Enable OAuth token rotation in your Slack app so refresh tokens are issued.",
        "Install the app to each workspace and request both bot scopes and user scopes for DM scanning.",
        "Configure Event Subscriptions with the events callback URL and enable message events for channels and DMs.",
        "After install, reconnect once if scopes change so Maraithon stores the updated grant."
      ]
    }
  end

  defp provider_setup("linear") do
    %{
      logo: :linear,
      permissions: [
        "read",
        "write",
        "issues:create",
        "comments:create"
      ],
      callback_urls: [
        %{label: "OAuth callback", url: callback_url("/auth/linear/callback"), required?: true},
        %{label: "Webhook callback", url: callback_url("/webhooks/linear"), required?: false}
      ],
      env_requirements: [
        env_requirement(
          "LINEAR_CLIENT_ID",
          config_value(:linear, :client_id),
          "Linear OAuth client ID",
          true
        ),
        env_requirement(
          "LINEAR_CLIENT_SECRET",
          config_value(:linear, :client_secret),
          "Linear OAuth client secret",
          true
        ),
        env_requirement(
          "LINEAR_REDIRECT_URI",
          config_value(:linear, :redirect_uri),
          "Must match the Linear OAuth callback URL",
          true,
          callback_url("/auth/linear/callback")
        ),
        env_requirement(
          "LINEAR_WEBHOOK_SECRET",
          config_value(:linear, :webhook_secret),
          "Used to verify Linear webhooks",
          false
        )
      ],
      setup_notes: [
        "Register the redirect URI in Linear.",
        "If you want inbound issue events, configure a Linear webhook pointed at the webhook callback."
      ]
    }
  end

  defp provider_setup("notion") do
    %{
      logo: :notion,
      permissions: [
        "Workspace permissions are configured in the Notion integration dashboard."
      ],
      callback_urls: [
        %{label: "OAuth callback", url: callback_url("/auth/notion/callback"), required?: true}
      ],
      env_requirements: [
        env_requirement(
          "NOTION_CLIENT_ID",
          config_value(:notion, :client_id),
          "Notion public integration client ID",
          true
        ),
        env_requirement(
          "NOTION_CLIENT_SECRET",
          config_value(:notion, :client_secret),
          "Notion public integration client secret",
          true
        ),
        env_requirement(
          "NOTION_REDIRECT_URI",
          config_value(:notion, :redirect_uri),
          "Must match the Notion OAuth callback URL",
          true,
          callback_url("/auth/notion/callback")
        )
      ],
      setup_notes: [
        "Create a public Notion integration and register the callback URL.",
        "Workspace-level permissions are chosen in Notion, not in the query string."
      ]
    }
  end

  defp provider_setup("notaui") do
    oauth_callback = callback_url("/auth/notaui/callback")

    %{
      logo: :notaui,
      permissions: [
        "Read and update Notaui tasks",
        "Read and update Notaui projects",
        "Write Notaui tags",
        "Call Notaui MCP tools with a user bearer token"
      ],
      callback_urls: [
        %{label: "OAuth callback", url: oauth_callback, required?: true}
      ],
      env_requirements: [
        env_requirement(
          "NOTAUI_CLIENT_ID",
          config_value(:notaui, :client_id),
          "Notaui OAuth client ID",
          true
        ),
        env_requirement(
          "NOTAUI_CLIENT_SECRET",
          config_value(:notaui, :client_secret),
          "Notaui OAuth client secret",
          true
        ),
        env_requirement(
          "NOTAUI_REDIRECT_URI",
          config_value(:notaui, :redirect_uri),
          "Must match the Notaui OAuth callback URL",
          true,
          oauth_callback
        ),
        env_requirement(
          "NOTAUI_SCOPE",
          config_value(:notaui, :scope),
          "Requested OAuth scopes for the Notaui connector",
          false,
          "tasks:read tasks:write projects:read projects:write tags:write"
        ),
        env_requirement(
          "NOTAUI_AUTH_URL",
          config_value(:notaui, :auth_url),
          "Override for the Notaui authorization endpoint",
          false,
          "https://api.notaui.com/oauth/authorize"
        ),
        env_requirement(
          "NOTAUI_TOKEN_URL",
          config_value(:notaui, :token_url),
          "Override for the Notaui token endpoint",
          false,
          "https://api.notaui.com/oauth/token"
        ),
        env_requirement(
          "NOTAUI_MCP_URL",
          config_value(:notaui, :mcp_url),
          "Bearer-token MCP endpoint used after connect",
          false,
          "https://api.notaui.com/mcp"
        ),
        env_requirement(
          "NOTAUI_ISSUER",
          config_value(:notaui, :issuer),
          "Issuer used for Notaui OAuth metadata and diagnostics",
          false,
          "https://api.notaui.com"
        ),
        env_requirement(
          "NOTAUI_REGISTER_URL",
          config_value(:notaui, :register_url),
          "Optional Notaui OAuth dynamic registration endpoint",
          false,
          "https://api.notaui.com/oauth/register"
        ),
        env_requirement(
          "NOTAUI_AUTH_SERVER_METADATA_URL",
          config_value(:notaui, :auth_server_metadata_url),
          "Optional Notaui OAuth authorization-server metadata endpoint",
          false,
          "https://api.notaui.com/.well-known/oauth-authorization-server"
        ),
        env_requirement(
          "NOTAUI_PROTECTED_RESOURCE_METADATA_URL",
          config_value(:notaui, :protected_resource_metadata_url),
          "Optional Notaui protected-resource metadata endpoint",
          false,
          "https://api.notaui.com/.well-known/oauth-protected-resource"
        )
      ],
      setup_notes: [
        "Register the OAuth callback URL exactly as shown above in Notaui.",
        "Use authorization code + PKCE (S256) for the browser connect flow.",
        "Configure token endpoint auth as client_secret_basic.",
        "After connect, Maraithon discovers accessible Notaui accounts with account.list and stores a default account.",
        "When Maraithon targets a non-default Notaui account it sends X-Notaui-Account-ID with the MCP request."
      ]
    }
  end

  defp provider_setup("telegram") do
    secret_path = config_value(:telegram, :webhook_secret_path)

    webhook_path =
      if present?(secret_path),
        do: "/webhooks/telegram/#{secret_path}",
        else: "/webhooks/telegram/{TELEGRAM_WEBHOOK_SECRET}"

    %{
      logo: :telegram,
      permissions: [
        "Read incoming bot messages for link commands",
        "Send push notifications for high-priority insights",
        "Read inline button feedback to tune thresholds"
      ],
      callback_urls: [
        %{label: "Webhook callback", url: callback_url(webhook_path), required?: true}
      ],
      env_requirements: [
        env_requirement(
          "TELEGRAM_BOT_TOKEN",
          config_value(:telegram, :bot_token),
          "Telegram bot token from BotFather",
          true
        ),
        env_requirement(
          "TELEGRAM_WEBHOOK_SECRET",
          config_value(:telegram, :webhook_secret_path),
          "Secret path segment used by the webhook endpoint",
          true
        )
      ],
      setup_notes: [
        "Set your webhook to the callback URL shown above.",
        "Users link their chat with: /start their-email@example.com",
        "Only insights above each user's threshold are pushed."
      ]
    }
  end

  defp callback_url(path) do
    MaraithonWeb.Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp config_value(namespace, key) do
    Application.get_env(:maraithon, namespace, [])
    |> Keyword.get(key, "")
  end

  defp env_requirement(name, value, description, required?, recommended_value \\ nil) do
    %{
      name: name,
      description: description,
      required?: required?,
      present?: present?(value),
      recommended_value: recommended_value
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)

  defp safe_fetch(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, error}
  end

  defp format_datetime(nil), do: "never"
  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
end
