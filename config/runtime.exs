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

config :maraithon, MaraithonWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port]

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

config :maraithon, Maraithon.Runtime,
  # LLM settings
  llm_provider: llm_provider,
  anthropic_api_key: anthropic_api_key,
  anthropic_model: anthropic_model,
  # Timing
  heartbeat_interval_ms: heartbeat_interval_ms,
  checkpoint_interval_ms: checkpoint_interval_ms,
  effect_poll_interval_ms: String.to_integer(System.get_env("EFFECT_POLL_INTERVAL_MS", "1000")),
  scheduler_poll_interval_ms: String.to_integer(System.get_env("SCHEDULER_POLL_INTERVAL_MS", "5000")),
  # Timeouts
  llm_timeout_ms: String.to_integer(System.get_env("LLM_TIMEOUT_MS", "120000")),
  tool_timeout_ms: String.to_integer(System.get_env("TOOL_TIMEOUT_MS", "30000")),
  # Retries
  max_effect_attempts: String.to_integer(System.get_env("MAX_EFFECT_ATTEMPTS", "3"))

# =============================================================================
# Connector Configuration
# =============================================================================

# GitHub Connector
config :maraithon, :github,
  webhook_secret: System.get_env("GITHUB_WEBHOOK_SECRET", "")

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
