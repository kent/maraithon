import Config

# Runtime configuration for Maraithon
# Environment variables are read here at startup

# =============================================================================
# Server Configuration
# =============================================================================

if System.get_env("PHX_SERVER") do
  config :maraithon, MaraithonWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

config :maraithon, MaraithonWeb.Endpoint, http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port]

# =============================================================================
# Maraithon Runtime Configuration
# =============================================================================

# LLM Provider Configuration
anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")
anthropic_model = System.get_env("ANTHROPIC_MODEL", "claude-sonnet-4-20250514")

llm_provider =
  if anthropic_api_key do
    Maraithon.LLM.AnthropicProvider
  else
    Maraithon.LLM.MockProvider
  end

# Timing configuration (can be overridden via env vars)
heartbeat_interval_ms =
  System.get_env("HEARTBEAT_INTERVAL_MS", "900000") |> String.to_integer()

checkpoint_interval_ms =
  System.get_env("CHECKPOINT_INTERVAL_MS", "600000") |> String.to_integer()

tool_allowed_paths =
  System.get_env("TOOL_ALLOWED_PATHS", "#{File.cwd!()},#{System.tmp_dir!()}")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

config :maraithon, Maraithon.Runtime,
  # LLM settings
  llm_provider: llm_provider,
  anthropic_api_key: anthropic_api_key,
  anthropic_model: anthropic_model,
  # Timing
  heartbeat_interval_ms: heartbeat_interval_ms,
  checkpoint_interval_ms: checkpoint_interval_ms,
  effect_poll_interval_ms: String.to_integer(System.get_env("EFFECT_POLL_INTERVAL_MS", "1000")),
  effect_claim_timeout_ms: String.to_integer(System.get_env("EFFECT_CLAIM_TIMEOUT_MS", "300000")),
  effect_batch_size: String.to_integer(System.get_env("EFFECT_BATCH_SIZE", "10")),
  scheduler_poll_interval_ms:
    String.to_integer(System.get_env("SCHEDULER_POLL_INTERVAL_MS", "5000")),
  scheduler_dispatch_timeout_ms:
    String.to_integer(System.get_env("SCHEDULER_DISPATCH_TIMEOUT_MS", "60000")),
  health_report_interval_ms:
    String.to_integer(System.get_env("HEALTH_REPORT_INTERVAL_MS", "60000")),
  tool_allowed_paths: tool_allowed_paths,
  # Timeouts
  llm_timeout_ms: String.to_integer(System.get_env("LLM_TIMEOUT_MS", "120000")),
  tool_timeout_ms: String.to_integer(System.get_env("TOOL_TIMEOUT_MS", "30000")),
  # Retries
  max_effect_attempts: String.to_integer(System.get_env("MAX_EFFECT_ATTEMPTS", "3"))

# =============================================================================
# Connector Configuration
# =============================================================================

# Security: Allow unsigned webhooks (DANGEROUS - only for local development)
# Set to "true" to allow webhooks without signature verification
allow_unsigned = System.get_env("ALLOW_UNSIGNED_WEBHOOKS", "false") == "true"

if config_env() == :prod and allow_unsigned do
  raise "ALLOW_UNSIGNED_WEBHOOKS=true is not allowed in production"
end

# GitHub Connector
config :maraithon, :github,
  webhook_secret: System.get_env("GITHUB_WEBHOOK_SECRET", ""),
  allow_unsigned: allow_unsigned

# Google OAuth & Connectors
config :maraithon, :google,
  client_id: System.get_env("GOOGLE_CLIENT_ID", ""),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET", ""),
  redirect_uri: System.get_env("GOOGLE_REDIRECT_URI", ""),
  calendar_webhook_url: System.get_env("GOOGLE_CALENDAR_WEBHOOK_URL", ""),
  pubsub_topic: System.get_env("GOOGLE_PUBSUB_TOPIC", "")

# Slack Connector
config :maraithon, :slack,
  client_id: System.get_env("SLACK_CLIENT_ID", ""),
  client_secret: System.get_env("SLACK_CLIENT_SECRET", ""),
  redirect_uri: System.get_env("SLACK_REDIRECT_URI", ""),
  signing_secret: System.get_env("SLACK_SIGNING_SECRET", ""),
  allow_unsigned: allow_unsigned

# WhatsApp Connector (Meta Business API)
config :maraithon, :whatsapp,
  verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN", ""),
  app_secret: System.get_env("WHATSAPP_APP_SECRET", ""),
  access_token: System.get_env("WHATSAPP_ACCESS_TOKEN", ""),
  phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID", ""),
  allow_unsigned: allow_unsigned

# Linear Connector
config :maraithon, :linear,
  client_id: System.get_env("LINEAR_CLIENT_ID", ""),
  client_secret: System.get_env("LINEAR_CLIENT_SECRET", ""),
  redirect_uri: System.get_env("LINEAR_REDIRECT_URI", ""),
  webhook_secret: System.get_env("LINEAR_WEBHOOK_SECRET", ""),
  allow_unsigned: allow_unsigned

# Telegram Connector
config :maraithon, :telegram,
  bot_token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
  webhook_secret_path: System.get_env("TELEGRAM_WEBHOOK_SECRET", ""),
  allow_unsigned: allow_unsigned

# =============================================================================
# Production Configuration
# =============================================================================

if config_env() == :prod do
  # Database URL (required in production)
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # For Cloud SQL connections via Unix socket
  socket_dir = System.get_env("CLOUD_SQL_SOCKET_DIR")

  repo_config =
    if socket_dir do
      # Cloud SQL with Unix socket (Cloud Run)
      # Parse DATABASE_URL to extract components
      uri = URI.parse(database_url)
      [username, password] = String.split(uri.userinfo || ":", ":")
      database = String.trim_leading(uri.path || "", "/")

      [
        username: username,
        password: password,
        database: database,
        socket: socket_dir <> "/.s.PGSQL.5432",
        pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
      ]
    else
      # Direct connection (local/testing)
      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      [
        url: database_url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
        socket_options: maybe_ipv6,
        ssl: System.get_env("DATABASE_SSL", "false") == "true"
      ]
    end

  config :maraithon, Maraithon.Repo, repo_config

  # Secret key base for sessions/signing
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "localhost")

  config :maraithon, MaraithonWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    secret_key_base: secret_key_base

  config :maraithon, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
