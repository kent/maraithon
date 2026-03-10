defmodule Maraithon.Connections do
  @moduledoc """
  Admin-facing connection inventory for integrations.
  """

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.OAuth
  alias Maraithon.OAuth.{GitHub, Google, Linear, Notion, Slack, Token}

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

    tokens =
      OAuth.list_user_tokens(user_id)
      |> Enum.sort_by(&provider_sort_key/1)

    token_by_provider = Map.new(tokens, &{&1.provider, &1})
    slack_tokens = Enum.filter(tokens, &slack_provider?(&1.provider))
    telegram_account = ConnectedAccounts.get(user_id, "telegram")

    providers = [
      google_card(user_id, token_by_provider["google"], return_to),
      github_card(user_id, token_by_provider["github"], return_to),
      slack_card(user_id, slack_tokens, return_to),
      telegram_card(user_id, telegram_account, return_to),
      linear_card(user_id, token_by_provider["linear"], return_to),
      notion_card(user_id, token_by_provider["notion"], return_to)
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
  def disconnect(user_id, provider) when provider in ["github", "google", "linear", "notion"] do
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
  end

  def disconnect(user_id, "telegram") when is_binary(user_id) do
    ConnectedAccounts.mark_disconnected(user_id, "telegram")
  end

  def disconnect(_user_id, _provider), do: {:error, :unsupported_provider}

  defp fallback_snapshot(user_id, return_to, reason) do
    providers =
      [
        google_card(user_id, nil, return_to),
        github_card(user_id, nil, return_to),
        slack_card(user_id, [], return_to),
        telegram_card(user_id, nil, return_to),
        linear_card(user_id, nil, return_to),
        notion_card(user_id, nil, return_to)
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

  defp google_card(user_id, token, return_to) do
    services =
      Enum.map(@google_services, fn service ->
        required_scopes = Google.scopes_for([service.id])
        connected? = google_service_connected?(token, required_scopes)

        %{
          id: service.id,
          label: service.label,
          description: service.description,
          status: google_service_status(token, connected?),
          connect_url: auth_url("/auth/google", user_id, return_to, scopes: service.id)
        }
      end)

    configured? = Google.configured?()
    google_scopes = token_scope_set(token)

    status =
      cond do
        not configured? -> :not_configured
        is_nil(token) -> :disconnected
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
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url:
        auth_url("/auth/google", user_id, return_to, scopes: "gmail,calendar,contacts"),
      disconnect_label: "Disconnect Google",
      details:
        google_details(token, [
          "Granted #{MapSet.size(google_scopes)} Google OAuth scopes"
        ]),
      services: services
    }
    |> enrich_provider_setup()
  end

  defp github_card(user_id, token, return_to) do
    configured? = GitHub.configured?()

    %{
      id: "github",
      provider: "github",
      label: "GitHub",
      description: "Grant repo and org access so agents can inspect issues and comment back.",
      status: provider_status(configured?, token),
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
      services: []
    }
    |> enrich_provider_setup()
  end

  defp slack_card(user_id, tokens, return_to) do
    configured? = Slack.configured?()
    bot_token = slack_bot_token(tokens)
    user_tokens = slack_user_tokens(tokens)
    bot_scopes = token_scope_set(bot_token)

    workspace_names =
      tokens
      |> Enum.map(fn token -> metadata_value(token, ["team_name"]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    status =
      cond do
        not configured? -> :not_configured
        is_nil(bot_token) -> :disconnected
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
        status: slack_service_status(configured?, bot_token)
      },
      %{
        id: "dms",
        label: "Personal DMs",
        description: "Read DM and MPIM context to catch reply debt and private commitments.",
        status: slack_service_status(configured?, List.first(user_tokens))
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
      services: services
    }
    |> enrich_provider_setup()
  end

  defp linear_card(user_id, token, return_to) do
    configured? = Linear.configured?()

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
      status: provider_status(configured?, token),
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
      services: []
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

  defp notion_card(user_id, token, return_to) do
    configured? = Notion.configured?()

    %{
      id: "notion",
      provider: "notion",
      label: "Notion",
      description: "Store a workspace grant now so Notion data can feed future agents and tools.",
      status: provider_status(configured?, token),
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
      services: []
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

  defp google_service_status(nil, _connected?), do: :disconnected
  defp google_service_status(_token, true), do: :connected
  defp google_service_status(_token, false), do: :missing_scope

  defp provider_status(false, _token), do: :not_configured
  defp provider_status(true, nil), do: :disconnected
  defp provider_status(true, _token), do: :connected

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

  defp slack_service_status(false, _token), do: :not_configured
  defp slack_service_status(true, nil), do: :disconnected
  defp slack_service_status(true, _token), do: :connected

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

  defp provider_sort_key(%Token{provider: provider}) do
    cond do
      provider == "google" -> 0
      provider == "github" -> 1
      slack_provider?(provider) -> 2
      provider == "linear" -> 3
      provider == "notion" -> 4
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
