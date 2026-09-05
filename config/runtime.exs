import Config

# Runtime configuration for Maraithon
# Environment variables are read here at startup

# =============================================================================
# Security Configuration
# =============================================================================

admin_username = System.get_env("ADMIN_USERNAME", "")
admin_password = System.get_env("ADMIN_PASSWORD", "")
api_bearer_token = System.get_env("API_BEARER_TOKEN", "")
primary_admin_email = System.get_env("PRIMARY_ADMIN_EMAIL", "")
runtime_environment = config_env()

process_role =
  case System.get_env("MARAITHON_PROCESS_ROLE", "") |> String.trim() |> String.downcase() do
    "web" ->
      :web

    "runtime" ->
      :runtime

    "maintenance" ->
      :maintenance

    "combined" ->
      :combined

    "" ->
      :combined

    invalid ->
      raise """
      Invalid MARAITHON_PROCESS_ROLE=#{inspect(invalid)}.
      Expected one of: web, runtime, maintenance, combined.
      """
  end

config :maraithon, process_role: process_role

# Production process ownership follows the selected role. A blank role keeps
# the single-service default; development and test retain their explicit worker
# setting (including the test suite's disabled workers).
if runtime_environment == :prod do
  config :maraithon, start_background_workers: process_role in [:runtime, :combined]
end

if config_env() == :prod do
  if primary_admin_email == "" do
    raise """
    PRIMARY_ADMIN_EMAIL must be set in production.
    This user is granted DB-backed browser admin access.
    """
  end

  if api_bearer_token == "" do
    raise """
    API_BEARER_TOKEN must be set in production.
    This token protects /api/v1 endpoints.
    """
  end
end

config :maraithon, :admin_auth,
  username: admin_username,
  password: admin_password

config :maraithon, :api_auth, bearer_token: api_bearer_token

config :maraithon, :support, email: System.get_env("SUPPORT_EMAIL", "support@maraithon.app")

privacy_retention_integer = fn env_name, default, min, max ->
  value = System.get_env(env_name, Integer.to_string(default))

  case Integer.parse(String.trim(value)) do
    {parsed, ""} when parsed >= min and parsed <= max ->
      parsed

    _invalid ->
      raise "#{env_name} must be an integer between #{min} and #{max}"
  end
end

config :maraithon, Maraithon.PrivacyRetention,
  effects_days: privacy_retention_integer.("PRIVACY_RETENTION_EFFECTS_DAYS", 30, 7, 365),
  directives_days: privacy_retention_integer.("PRIVACY_RETENTION_DIRECTIVES_DAYS", 30, 7, 365),
  events_days: privacy_retention_integer.("PRIVACY_RETENTION_EVENTS_DAYS", 90, 30, 365),
  run_steps_days: privacy_retention_integer.("PRIVACY_RETENTION_RUN_STEPS_DAYS", 30, 7, 365),
  agent_runs_days: privacy_retention_integer.("PRIVACY_RETENTION_AGENT_RUNS_DAYS", 30, 7, 365),
  assistant_runs_days:
    privacy_retention_integer.("PRIVACY_RETENTION_ASSISTANT_RUNS_DAYS", 30, 7, 365),
  assistant_steps_days:
    privacy_retention_integer.("PRIVACY_RETENTION_ASSISTANT_STEPS_DAYS", 30, 7, 365),
  prepared_actions_days:
    privacy_retention_integer.("PRIVACY_RETENTION_PREPARED_ACTIONS_DAYS", 30, 7, 365),
  operator_events_days:
    privacy_retention_integer.("PRIVACY_RETENTION_OPERATOR_EVENTS_DAYS", 90, 30, 365),
  background_jobs_days:
    privacy_retention_integer.("PRIVACY_RETENTION_BACKGROUND_JOBS_DAYS", 30, 7, 365),
  scheduled_jobs_days:
    privacy_retention_integer.("PRIVACY_RETENTION_SCHEDULED_JOBS_DAYS", 30, 7, 365),
  ingress_receipts_days:
    privacy_retention_integer.("PRIVACY_RETENTION_INGRESS_RECEIPTS_DAYS", 90, 30, 365),
  work_results_days:
    privacy_retention_integer.("PRIVACY_RETENTION_WORK_RESULTS_DAYS", 30, 7, 365),
  conversation_days:
    privacy_retention_integer.("PRIVACY_RETENTION_CONVERSATION_DAYS", 90, 30, 365),
  snapshot_quarantine_days:
    privacy_retention_integer.("PRIVACY_RETENTION_SNAPSHOT_REPORT_DAYS", 30, 1, 30),
  erasure_receipts_days: privacy_retention_integer.("PRIVACY_ERASURE_RECEIPT_DAYS", 365, 30, 730),
  batch_size: privacy_retention_integer.("PRIVACY_RETENTION_BATCH_SIZE", 100, 1, 500),
  per_tenant: privacy_retention_integer.("PRIVACY_RETENTION_PER_TENANT", 5, 1, 50),
  alert_grace_hours:
    privacy_retention_integer.("PRIVACY_RETENTION_ALERT_GRACE_HOURS", 24, 1, 168),
  critical_grace_hours:
    privacy_retention_integer.("PRIVACY_RETENTION_CRITICAL_GRACE_HOURS", 168, 24, 720)

# Public verification key only. The matching Ed25519 private key must remain in
# the external incident-operator system and must never be present in this app.
config :maraithon, Maraithon.Runtime.AgentTerminations,
  external_attestation_public_key: System.get_env("AGENT_TERMINATION_ATTESTATION_PUBLIC_KEY", "")

# App Store review demo account. When both are set, the reviewer email skips
# Postmark delivery and the listed code acts as the magic code (see
# Accounts.app_review_bypass_config/0). Leave unset in dev/test — the bypass
# no-ops unless both are present. Rotate by changing the env vars.
config :maraithon, :app_review_bypass,
  email: System.get_env("APP_REVIEW_BYPASS_EMAIL"),
  code: System.get_env("APP_REVIEW_BYPASS_CODE")

admin_default_user_id =
  case System.get_env("ADMIN_DEFAULT_USER_ID", admin_username) do
    "" -> "operator"
    value -> value
  end

config :maraithon, :admin_control, default_user_id: admin_default_user_id

# =============================================================================
# Server Configuration
# =============================================================================

if System.get_env("PHX_SERVER") do
  config :maraithon, MaraithonWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

config :maraithon, MaraithonWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: port,
    websocket_options: [
      max_frame_size: 8_000_000,
      max_fragmented_message_size: 8_000_000
    ]
  ]

# =============================================================================
# Maraithon Runtime Configuration
# =============================================================================

# LLM Provider Configuration
default_openai_model = "gpt-5.4"
default_openrouter_model = "moonshotai/kimi-k3"
default_qwen_model = "qwen/qwen3.7-max"

llm_model_selector =
  System.get_env("LLM_MODEL", "")
  |> String.trim()

selected_llm_provider =
  case String.downcase(llm_model_selector) do
    "" ->
      nil

    "openai" ->
      "openai"

    "gpt" ->
      "openai"

    "kimi" ->
      "openrouter"

    "kimi-k3" ->
      "openrouter"

    "qwen" ->
      "openrouter"

    "qwen-max" ->
      "openrouter"

    "openrouter" ->
      "openrouter"

    "openrouter:" <> _model ->
      "openrouter"

    "openai:" <> _model ->
      "openai"

    "anthropic:" <> _model ->
      "anthropic"

    "claude-" <> _rest ->
      "anthropic"

    "gpt-" <> _rest ->
      "openai"

    "o1" <> _rest ->
      "openai"

    "o3" <> _rest ->
      "openai"

    "o4" <> _rest ->
      "openai"

    value ->
      cond do
        String.starts_with?(value, "qwen/") -> "openrouter"
        String.starts_with?(value, "~") -> "openrouter"
        String.contains?(value, "/") -> "openrouter"
        true -> nil
      end
  end

selected_llm_model =
  case String.downcase(llm_model_selector) do
    "" -> nil
    "openai" -> default_openai_model
    "gpt" -> default_openai_model
    "kimi" -> default_openrouter_model
    "kimi-k3" -> default_openrouter_model
    "qwen" -> default_qwen_model
    "qwen-max" -> default_qwen_model
    "openrouter" -> default_openrouter_model
    "openrouter:" <> model -> String.trim(model)
    "openai:" <> model -> String.trim(model)
    "anthropic:" <> model -> String.trim(model)
    _other -> llm_model_selector
  end

anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")

anthropic_model =
  if selected_llm_provider == "anthropic" and selected_llm_model not in [nil, ""] do
    selected_llm_model
  else
    System.get_env("ANTHROPIC_MODEL", "claude-sonnet-4-20250514")
  end

openai_api_key = System.get_env("OPENAI_API_KEY")

openai_model =
  if selected_llm_provider == "openai" and selected_llm_model not in [nil, ""] do
    selected_llm_model
  else
    System.get_env("OPENAI_MODEL", default_openai_model)
  end

openai_reasoning_effort = System.get_env("OPENAI_REASONING_EFFORT", "high")
openrouter_api_key = System.get_env("OPENROUTER_API_KEY")

openrouter_model =
  if selected_llm_provider == "openrouter" and selected_llm_model not in [nil, ""] do
    selected_llm_model
  else
    System.get_env("OPENROUTER_MODEL", default_openrouter_model)
  end

openrouter_reasoning_effort = System.get_env("OPENROUTER_REASONING_EFFORT", "high")
openrouter_http_referer = System.get_env("OPENROUTER_HTTP_REFERER", "https://maraithon.app")
openrouter_app_title = System.get_env("OPENROUTER_APP_TITLE", "Maraithon")

anthropic_routing_model =
  case System.get_env("ANTHROPIC_ROUTING_MODEL", "") |> String.trim() do
    "" ->
      if selected_llm_provider == "anthropic" and selected_llm_model not in [nil, ""] do
        selected_llm_model
      else
        "claude-haiku-4-5-20251001"
      end

    value ->
      value
  end

openai_routing_model =
  case System.get_env("OPENAI_ROUTING_MODEL", "") |> String.trim() do
    "" ->
      if selected_llm_provider == "openai" and selected_llm_model not in [nil, ""] do
        selected_llm_model
      else
        "gpt-4o-mini"
      end

    value ->
      value
  end

openrouter_routing_model =
  case System.get_env("OPENROUTER_ROUTING_MODEL", "") |> String.trim() do
    "" ->
      # OpenRouter has no provider-wide routing default. When an explicit fast
      # model is configured, use it for bounded `complete_routing/1` calls
      # instead of silently sending classifiers through the primary model.
      case System.get_env("OPENROUTER_FAST_MODEL", "") |> String.trim() do
        "" -> openrouter_model
        value -> value
      end

    value ->
      value
  end

anthropic_chat_model =
  case System.get_env("ANTHROPIC_CHAT_MODEL", "") |> String.trim() do
    "" ->
      if selected_llm_provider == "anthropic" and selected_llm_model not in [nil, ""] do
        selected_llm_model
      else
        "claude-sonnet-4-20250514"
      end

    value ->
      value
  end

openai_chat_model =
  case System.get_env("OPENAI_CHAT_MODEL", "") |> String.trim() do
    "" ->
      if selected_llm_provider == "openai" and selected_llm_model not in [nil, ""] do
        selected_llm_model
      else
        "gpt-4.1"
      end

    value ->
      value
  end

openrouter_chat_model =
  case System.get_env("OPENROUTER_CHAT_MODEL", "") |> String.trim() do
    "" -> openrouter_model
    value -> value
  end

llm_model_fallbacks =
  System.get_env("LLM_MODEL_FALLBACKS", "")
  |> then(&binary_part(&1, 0, min(byte_size(&1), 8_192)))
  |> String.split(",", trim: true)
  |> Enum.take(16)
  |> Enum.map(&String.trim/1)
  |> Enum.filter(&(byte_size(&1) <= 255))
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()
  |> Enum.take(8)

configured_llm_provider = System.get_env("LLM_PROVIDER", "") |> String.trim() |> String.downcase()

proactive_check_in_interval_ms =
  String.to_integer(System.get_env("PROACTIVE_CHECK_IN_INTERVAL_MS", "600000"))

todo_completion_sweep_interval_ms =
  String.to_integer(System.get_env("TODO_COMPLETION_SWEEP_INTERVAL_MS", "60000"))

optional_boolean_env = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    value -> String.downcase(String.trim(value)) in ~w(true 1 yes)
  end
end

boolean_env = fn name, default ->
  case optional_boolean_env.(name) do
    nil -> default
    value -> value
  end
end

llm_provider_name =
  cond do
    configured_llm_provider == "mock" and config_env() == :test ->
      "mock"

    configured_llm_provider == "mock" ->
      raise """
      LLM_PROVIDER=mock is only allowed in test.
      Configure LLM_PROVIDER=openai with OPENAI_API_KEY, LLM_PROVIDER=openrouter with OPENROUTER_API_KEY, or LLM_PROVIDER=anthropic with ANTHROPIC_API_KEY.
      """

    selected_llm_provider in ["anthropic", "openai", "openrouter"] ->
      selected_llm_provider

    configured_llm_provider in ["anthropic", "openai", "openrouter"] ->
      configured_llm_provider

    openai_api_key not in [nil, ""] ->
      "openai"

    openrouter_api_key not in [nil, ""] ->
      "openrouter"

    anthropic_api_key not in [nil, ""] ->
      "anthropic"

    true ->
      "unconfigured"
  end

llm_provider =
  case llm_provider_name do
    "anthropic" -> Maraithon.LLM.AnthropicProvider
    "openai" -> Maraithon.LLM.OpenAIProvider
    "openrouter" -> Maraithon.LLM.OpenRouterProvider
    "mock" -> Maraithon.LLM.MockProvider
    _ -> nil
  end

llm_model =
  case llm_provider_name do
    "anthropic" -> anthropic_model
    "openai" -> openai_model
    "openrouter" -> openrouter_model
    "mock" -> "mock-v1"
    _ -> openai_model
  end

llm_routing_model =
  case llm_provider_name do
    "anthropic" -> anthropic_routing_model
    "openai" -> openai_routing_model
    "openrouter" -> openrouter_routing_model
    "mock" -> "mock-v1"
    _ -> nil
  end

llm_chat_model =
  case llm_provider_name do
    "anthropic" -> anthropic_chat_model
    "openai" -> openai_chat_model
    "openrouter" -> openrouter_chat_model
    "mock" -> "mock-v1"
    _ -> nil
  end

# Fast tier: lowest-latency model for turns that clearly do not need full
# intelligence. Unset means the fast tier falls back to the chat model.
llm_fast_model =
  case llm_provider_name do
    "anthropic" -> System.get_env("ANTHROPIC_FAST_MODEL", "") |> String.trim()
    "openai" -> System.get_env("OPENAI_FAST_MODEL", "") |> String.trim()
    "openrouter" -> System.get_env("OPENROUTER_FAST_MODEL", "") |> String.trim()
    "mock" -> "mock-v1"
    _ -> nil
  end
  |> case do
    "" -> nil
    value -> value
  end

llm_api_key =
  case llm_provider_name do
    "anthropic" -> anthropic_api_key
    "openai" -> openai_api_key
    "openrouter" -> openrouter_api_key
    _ -> nil
  end

# Brief tier: the highest-intelligence model available, used for per-todo
# chief-of-staff briefs (why it matters, the situation, the ready-to-send
# reply). Provider-specific `<PROVIDER>_BRIEF_MODEL` wins, then the generic
# `LLM_BRIEF_MODEL`; unset means the primary model at brief reasoning effort.
llm_brief_model =
  [
    case llm_provider_name do
      "anthropic" -> System.get_env("ANTHROPIC_BRIEF_MODEL", "")
      "openai" -> System.get_env("OPENAI_BRIEF_MODEL", "")
      "openrouter" -> System.get_env("OPENROUTER_BRIEF_MODEL", "")
      "mock" -> "mock-v1"
      _ -> ""
    end,
    System.get_env("LLM_BRIEF_MODEL", "")
  ]
  |> Enum.map(&String.trim/1)
  |> Enum.find(&(&1 != ""))

llm_brief_reasoning_effort =
  case System.get_env("LLM_BRIEF_REASONING_EFFORT", "high") |> String.trim() do
    "" -> "high"
    value -> value
  end

config :maraithon, :openrouter,
  base_url:
    System.get_env(
      "OPENROUTER_BASE_URL",
      "https://openrouter.ai/api/v1/chat/completions"
    ),
  http_referer: openrouter_http_referer,
  app_title: openrouter_app_title

# Voice transcription (Telegram voice/audio message capture — SPEC 02).
# Reuses the OpenAI API key already configured for the LLM providers above
# unless a dedicated TRANSCRIPTION_API_KEY is set — Whisper transcription is
# a separate OpenAI product from chat completions, so it stays usable even
# when LLM_PROVIDER is anthropic/openrouter, as long as either key is set.
transcription_api_key =
  case System.get_env("TRANSCRIPTION_API_KEY", "") |> String.trim() do
    "" -> openai_api_key
    value -> value
  end

config :maraithon, Maraithon.Transcription, provider: Maraithon.Transcription.OpenAIWhisper

config :maraithon, Maraithon.Transcription.OpenAIWhisper,
  api_key: transcription_api_key,
  model: System.get_env("TRANSCRIPTION_MODEL", "whisper-1"),
  base_url:
    System.get_env("TRANSCRIPTION_BASE_URL", "https://api.openai.com/v1/audio/transcriptions"),
  receive_timeout_ms: String.to_integer(System.get_env("TRANSCRIPTION_TIMEOUT_MS", "60000"))

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

# A capable production revision remains dark unless the operator deliberately
# enables the second, non-rolling cutover deployment.
exact_agent_runtime_enabled =
  if config_env() == :prod do
    System.get_env("EXACT_AGENT_RUNTIME_ENABLED", "false")
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("true")
  else
    config_env() == :test
  end

multinode_coordination_enabled =
  if config_env() == :prod do
    System.get_env("MULTINODE_COORDINATION_ENABLED", "false")
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("true")
  else
    false
  end

config :maraithon, Maraithon.Runtime,
  exact_agent_runtime_enabled: exact_agent_runtime_enabled,
  multinode_coordination_enabled: multinode_coordination_enabled,
  # LLM settings
  llm_provider_name: llm_provider_name,
  llm_provider: llm_provider,
  llm_model: llm_model,
  llm_model_selector: selected_llm_model,
  llm_routing_model: llm_routing_model,
  llm_chat_model: llm_chat_model,
  llm_fast_model: llm_fast_model,
  llm_brief_model: llm_brief_model,
  llm_brief_reasoning_effort: llm_brief_reasoning_effort,
  llm_api_key: llm_api_key,
  anthropic_api_key: anthropic_api_key,
  anthropic_model: anthropic_model,
  anthropic_routing_model: anthropic_routing_model,
  anthropic_chat_model: anthropic_chat_model,
  openai_api_key: openai_api_key,
  openai_model: openai_model,
  openai_routing_model: openai_routing_model,
  openai_chat_model: openai_chat_model,
  openrouter_api_key: openrouter_api_key,
  openrouter_model: openrouter_model,
  openrouter_routing_model: openrouter_routing_model,
  openrouter_chat_model: openrouter_chat_model,
  openrouter_reasoning_effort: openrouter_reasoning_effort,
  openrouter_http_referer: openrouter_http_referer,
  openrouter_app_title: openrouter_app_title,
  llm_model_fallbacks: llm_model_fallbacks,
  openai_reasoning_effort: openai_reasoning_effort,
  openai_stream_replies: System.get_env("OPENAI_STREAM_REPLIES", "true") == "true",
  # LLM concurrency per bucket. The old default of 1 serialized every model
  # call on the node, so interactive chat queued behind chief-of-staff and
  # briefing work and burned llm_busy retries. The shared 429 cooldown in
  # LLMRateLimiter still guards against provider retry storms.
  llm_max_concurrency: String.to_integer(System.get_env("LLM_MAX_CONCURRENCY", "3")),
  llm_chat_max_concurrency: String.to_integer(System.get_env("LLM_CHAT_MAX_CONCURRENCY", "4")),
  llm_reasoning_max_concurrency:
    String.to_integer(System.get_env("LLM_REASONING_MAX_CONCURRENCY", "3")),
  # Independent source accounts may acquire and reason concurrently. The
  # exact fairness table keeps this bounded per user, and each account still
  # has its own ordered acquisition partition.
  source_fanout_tenant_max_concurrency:
    String.to_integer(System.get_env("SOURCE_FANOUT_TENANT_MAX_CONCURRENCY", "3")),
  # Timing
  heartbeat_interval_ms: heartbeat_interval_ms,
  checkpoint_interval_ms: checkpoint_interval_ms,
  effect_poll_interval_ms: String.to_integer(System.get_env("EFFECT_POLL_INTERVAL_MS", "1000")),
  # Bounded reuse of a successful exact-protocol storage proof (0 = re-verify per call).
  protocol_storage_verification_cache_ms:
    String.to_integer(System.get_env("PROTOCOL_STORAGE_VERIFICATION_CACHE_MS", "300000")),
  # Telegram asks the provider for one delivery connection. This short grace
  # also lets concurrently admitted requests become visible before the DB head
  # is selected; it is not a substitute for the provider serialization contract.
  telegram_ingress_ordering_grace_ms:
    String.to_integer(
      System.get_env(
        "TELEGRAM_INGRESS_ORDERING_GRACE_MS",
        if(config_env() == :test, do: "0", else: "1000")
      )
    ),
  effect_claim_timeout_ms:
    String.to_integer(System.get_env("EFFECT_CLAIM_TIMEOUT_MS", "1500000")),
  effect_batch_size: String.to_integer(System.get_env("EFFECT_BATCH_SIZE", "10")),
  scheduler_poll_interval_ms:
    String.to_integer(System.get_env("SCHEDULER_POLL_INTERVAL_MS", "5000")),
  scheduler_dispatch_timeout_ms:
    String.to_integer(System.get_env("SCHEDULER_DISPATCH_TIMEOUT_MS", "60000")),
  briefing_cron_interval_ms:
    String.to_integer(System.get_env("BRIEFING_CRON_INTERVAL_MS", "60000")),
  insight_notify_interval_ms:
    String.to_integer(System.get_env("INSIGHT_NOTIFY_INTERVAL_MS", "60000")),
  insight_notify_batch_size: String.to_integer(System.get_env("INSIGHT_NOTIFY_BATCH_SIZE", "20")),
  bootstrap_retry_interval_ms:
    String.to_integer(System.get_env("BOOTSTRAP_RETRY_INTERVAL_MS", "5000")),
  health_report_interval_ms:
    String.to_integer(System.get_env("HEALTH_REPORT_INTERVAL_MS", "60000")),
  agent_watcher_poll_interval_ms:
    String.to_integer(System.get_env("AGENT_WATCHER_POLL_INTERVAL_MS", "2000")),
  agent_crash_loop_max: String.to_integer(System.get_env("AGENT_CRASH_LOOP_MAX", "3")),
  agent_crash_loop_window_ms:
    String.to_integer(System.get_env("AGENT_CRASH_LOOP_WINDOW_MS", "600000")),
  agent_reresume_backoffs:
    System.get_env("AGENT_RERESUME_BACKOFFS", "5000,15000,30000")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1),
  dogfood_user_id: System.get_env("DOGFOOD_USER_ID") || System.get_env("PRIMARY_ADMIN_EMAIL"),
  dogfood_digest_hour: String.to_integer(System.get_env("DOGFOOD_DIGEST_HOUR", "7")),
  dogfood_digest_minute: String.to_integer(System.get_env("DOGFOOD_DIGEST_MINUTE", "30")),
  # A named PostgreSQL timezone is required; fixed UTC offsets are not DST-safe.
  dogfood_digest_timezone: System.get_env("DOGFOOD_DIGEST_TIMEZONE", "America/Toronto"),
  proactive_check_in_interval_ms: proactive_check_in_interval_ms,
  proactive_check_in_initial_delay_ms:
    String.to_integer(
      System.get_env(
        "PROACTIVE_CHECK_IN_INITIAL_DELAY_MS",
        Integer.to_string(proactive_check_in_interval_ms)
      )
    ),
  proactive_check_in_batch_size:
    String.to_integer(System.get_env("PROACTIVE_CHECK_IN_BATCH_SIZE", "25")),
  todo_completion_sweep_interval_ms: todo_completion_sweep_interval_ms,
  todo_completion_sweep_initial_delay_ms:
    String.to_integer(
      System.get_env(
        "TODO_COMPLETION_SWEEP_INITIAL_DELAY_MS",
        Integer.to_string(todo_completion_sweep_interval_ms)
      )
    ),
  oauth_refresh_interval_ms:
    String.to_integer(System.get_env("OAUTH_REFRESH_INTERVAL_MS", "300000")),
  oauth_refresh_lookahead_seconds:
    String.to_integer(System.get_env("OAUTH_REFRESH_LOOKAHEAD_SECONDS", "900")),
  oauth_refresh_batch_size: String.to_integer(System.get_env("OAUTH_REFRESH_BATCH_SIZE", "100")),
  tool_allowed_paths: tool_allowed_paths,
  # Timeouts
  llm_timeout_ms: String.to_integer(System.get_env("LLM_TIMEOUT_MS", "120000")),
  llm_primary_max_tokens: String.to_integer(System.get_env("LLM_PRIMARY_MAX_TOKENS", "32000")),
  tool_timeout_ms: String.to_integer(System.get_env("TOOL_TIMEOUT_MS", "30000")),
  # Retries
  max_effect_attempts: String.to_integer(System.get_env("MAX_EFFECT_ATTEMPTS", "3"))

config :maraithon, :apns,
  team_id: System.get_env("APNS_TEAM_ID"),
  key_id: System.get_env("APNS_KEY_ID"),
  private_key: System.get_env("APNS_PRIVATE_KEY"),
  topic: System.get_env("APNS_TOPIC"),
  environment: System.get_env("APNS_ENVIRONMENT")

config :maraithon, :mobile_push, enabled: boolean_env.("MOBILE_PUSH_ENABLED", true)

config :maraithon, :telegram_assistant,
  chat_reasoning_effort: System.get_env("TELEGRAM_CHAT_REASONING_EFFORT", "none"),
  telegram_full_chat_enabled: optional_boolean_env.("TELEGRAM_FULL_CHAT_ENABLED"),
  telegram_unified_push_enabled: optional_boolean_env.("TELEGRAM_UNIFIED_PUSH_ENABLED"),
  telegram_proactive_checkins_enabled: boolean_env.("TELEGRAM_PROACTIVE_CHECKINS_ENABLED", false),
  proactive_delivery_planner_enabled: boolean_env.("PROACTIVE_DELIVERY_PLANNER_ENABLED", true),
  proactive_candidate_ttl_minutes:
    String.to_integer(System.get_env("PROACTIVE_CANDIDATE_TTL_MINUTES", "120"))

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
  client_id: System.get_env("GITHUB_CLIENT_ID", ""),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET", ""),
  redirect_uri: System.get_env("GITHUB_REDIRECT_URI", ""),
  api_token: System.get_env("GITHUB_ACCESS_TOKEN", ""),
  api_base_url: System.get_env("GITHUB_API_BASE_URL", "https://api.github.com"),
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

# Notion Connector
config :maraithon, :notion,
  client_id: System.get_env("NOTION_CLIENT_ID", ""),
  client_secret: System.get_env("NOTION_CLIENT_SECRET", ""),
  redirect_uri: System.get_env("NOTION_REDIRECT_URI", ""),
  api_base_url: System.get_env("NOTION_API_BASE_URL", "https://api.notion.com/v1"),
  api_version: System.get_env("NOTION_API_VERSION", "2025-09-03")

# Notaui MCP Connector
notaui_issuer =
  System.get_env("NOTAUI_ISSUER", System.get_env("NOTAUI_BASE_URL", "https://api.notaui.com"))

config :maraithon, :notaui,
  issuer: notaui_issuer,
  base_url: notaui_issuer,
  auth_url: System.get_env("NOTAUI_AUTH_URL", "#{notaui_issuer}/oauth/authorize"),
  token_url: System.get_env("NOTAUI_TOKEN_URL", "#{notaui_issuer}/oauth/token"),
  revoke_url: System.get_env("NOTAUI_REVOKE_URL", ""),
  mcp_url: System.get_env("NOTAUI_MCP_URL", "#{notaui_issuer}/mcp"),
  register_url: System.get_env("NOTAUI_REGISTER_URL", "#{notaui_issuer}/oauth/register"),
  auth_server_metadata_url:
    System.get_env(
      "NOTAUI_AUTH_SERVER_METADATA_URL",
      "#{notaui_issuer}/.well-known/oauth-authorization-server"
    ),
  protected_resource_metadata_url:
    System.get_env(
      "NOTAUI_PROTECTED_RESOURCE_METADATA_URL",
      "#{notaui_issuer}/.well-known/oauth-protected-resource"
    ),
  client_id: System.get_env("NOTAUI_CLIENT_ID", ""),
  client_secret: System.get_env("NOTAUI_CLIENT_SECRET", ""),
  redirect_uri: System.get_env("NOTAUI_REDIRECT_URI", ""),
  scope:
    System.get_env(
      "NOTAUI_SCOPE",
      "tasks:read tasks:write projects:read projects:write tags:write"
    ),
  timeout_ms: String.to_integer(System.get_env("NOTAUI_TIMEOUT_MS", "10000")),
  topic_prefix: System.get_env("NOTAUI_TOPIC_PREFIX", "notaui")

# Telegram Connector. TELEGRAM_WEBHOOK_SECRET_TOKEN is registered with Telegram
# as setWebhook.secret_token and arrives in X-Telegram-Bot-Api-Secret-Token.
# Keep the legacy key as a rollout fallback until operators have rotated it away.
config :maraithon, :telegram,
  bot_token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
  bot_username: System.get_env("TELEGRAM_BOT_USERNAME", ""),
  webhook_secret_token:
    System.get_env(
      "TELEGRAM_WEBHOOK_SECRET_TOKEN",
      System.get_env("TELEGRAM_WEBHOOK_SECRET", "")
    )

fly_log_apps =
  System.get_env("FLY_LOG_APPS", System.get_env("FLY_APP_NAME", ""))
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

fly_log_region =
  case System.get_env("FLY_LOG_REGION", "") do
    "" -> nil
    value -> value
  end

config :maraithon, Maraithon.FlyLogs,
  api_token: System.get_env("FLY_API_TOKEN", ""),
  api_base_url: System.get_env("FLY_API_BASE_URL", "https://api.fly.io/api/v1"),
  apps: fly_log_apps,
  region: fly_log_region,
  receive_timeout_ms: String.to_integer(System.get_env("FLY_LOG_TIMEOUT_MS", "3000"))

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

  direct_database_url = System.get_env("DIRECT_DATABASE_URL") || database_url

  database_tls_mode =
    case System.get_env("DATABASE_TLS_MODE", "verify_peer")
         |> String.trim()
         |> String.downcase() do
      mode when mode in ["verify", "verify_peer"] ->
        :verify_peer

      mode when mode in ["private_network_override", "insecure_override"] ->
        confirmation = System.get_env("DATABASE_TLS_INSECURE_CONFIRMATION", "")
        reason = System.get_env("DATABASE_TLS_INSECURE_REASON", "") |> String.trim()

        unless confirmation == "I_ACKNOWLEDGE_DATABASE_TLS_IS_NOT_VERIFIED" do
          raise """
          DATABASE_TLS_INSECURE_CONFIRMATION must contain the exact audited
          confirmation when DATABASE_TLS_MODE requests an insecure override.
          """
        end

        unless Regex.match?(~r/\A[a-z0-9][a-z0-9._:-]{2,127}\z/, reason) do
          raise """
          DATABASE_TLS_INSECURE_REASON must be a content-free reason code using
          3-128 lowercase ASCII letters, digits, dots, colons, underscores, or hyphens.
          """
        end

        IO.warn(
          "Database TLS peer verification is disabled by audited private-network override " <>
            "(reason_code=#{reason})"
        )

        {:insecure_override, reason}

      value ->
        raise """
        DATABASE_TLS_MODE must be verify_peer or private_network_override,
        got an unsupported value: #{inspect(value)}
        """
    end

  case System.get_env("DATABASE_SSL") do
    nil ->
      :ok

    value ->
      case value |> String.trim() |> String.downcase() do
        enabled when enabled in ["true", "1"] ->
          if database_tls_mode != :verify_peer do
            raise "DATABASE_SSL conflicts with DATABASE_TLS_MODE"
          end

        disabled when disabled in ["false", "0"] ->
          if database_tls_mode == :verify_peer do
            raise """
            DATABASE_SSL=false cannot disable verified production TLS. Use the
            explicit DATABASE_TLS_MODE private-network override and confirmation.
            """
          end

        _invalid ->
          raise "DATABASE_SSL must be true or false when set"
      end
  end

  database_ca_path = System.get_env("DATABASE_TLS_CA_CERT_PATH", "") |> String.trim()

  database_ca_options =
    case database_tls_mode do
      :verify_peer ->
        if database_ca_path == "" do
          cacerts =
            try do
              :public_key.cacerts_get()
            rescue
              _error ->
                raise "could not load the operating-system CA trust store for database TLS"
            catch
              _kind, _reason ->
                raise "could not load the operating-system CA trust store for database TLS"
            end

          if cacerts == [] do
            raise "the operating-system CA trust store is empty; database TLS cannot be verified"
          end

          {[cacerts: cacerts], :operating_system}
        else
          unless Path.type(database_ca_path) == :absolute and File.regular?(database_ca_path) do
            raise "DATABASE_TLS_CA_CERT_PATH must name an absolute readable CA certificate file"
          end

          {[cacertfile: String.to_charlist(database_ca_path)], :custom_file}
        end

      {:insecure_override, _reason} ->
        {[], :insecure_override}
    end

  verified_database_options = fn url, env_name ->
    uri = URI.parse(url)

    unless is_binary(uri.host) and uri.host != "" do
      raise "#{env_name} must contain a database hostname"
    end

    query = if uri.query, do: Enum.to_list(URI.query_decoder(uri.query)), else: []

    if Enum.any?(query, fn {key, value} ->
         case String.downcase(key) do
           "ssl" -> String.downcase(value) != "true"
           "sslmode" -> String.downcase(value) != "verify-full"
           _key -> false
         end
       end) do
      raise "#{env_name} contains a TLS query option that does not verify peer and hostname"
    end

    case database_tls_mode do
      :verify_peer ->
        {ca_options, _ca_source} = database_ca_options

        [
          ssl:
            [
              verify: :verify_peer,
              server_name_indication: String.to_charlist(uri.host),
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ]
            ] ++ ca_options
        ]

      {:insecure_override, _reason} ->
        [ssl: false]
    end
  end

  database_tls_options = verified_database_options.(database_url, "DATABASE_URL")

  direct_database_tls_options =
    verified_database_options.(direct_database_url, "DIRECT_DATABASE_URL")

  database_pool_mode =
    case System.get_env("DATABASE_POOL_MODE", "") |> String.trim() |> String.downcase() do
      "" ->
        if String.contains?(database_url, ".pooler.") or
             String.contains?(database_url, "pgbouncer") do
          :transaction
        else
          :session
        end

      "transaction" ->
        :transaction

      "session" ->
        :session

      value ->
        raise "DATABASE_POOL_MODE must be \"transaction\" or \"session\", got: #{inspect(value)}"
    end

  # For Cloud SQL connections via Unix socket. A local socket has no TLS peer
  # or hostname to authenticate, so it is available only through the same
  # explicit, audited private-network override as any other unverified path.
  socket_dir = System.get_env("CLOUD_SQL_SOCKET_DIR")

  if socket_dir && database_tls_mode == :verify_peer do
    raise """
    CLOUD_SQL_SOCKET_DIR bypasses database TLS peer verification. Remove it for
    verified TCP or use the explicit private-network override and confirmation.
    """
  end

  pool_size = String.to_integer(System.get_env("POOL_SIZE", "8"))
  queue_target = String.to_integer(System.get_env("DB_QUEUE_TARGET_MS", "250"))
  queue_interval = String.to_integer(System.get_env("DB_QUEUE_INTERVAL_MS", "2000"))
  query_timeout = String.to_integer(System.get_env("DB_QUERY_TIMEOUT_MS", "15000"))
  connect_timeout = String.to_integer(System.get_env("DB_CONNECT_TIMEOUT_MS", "30000"))

  postgrex_pool_options =
    if database_pool_mode == :transaction do
      # Fly Managed Postgres attaches apps through PgBouncer. Transaction pooling
      # requires unnamed prepared statements with Postgrex/Ecto.
      [prepare: :unnamed]
    else
      []
    end

  common_repo_options = [
    pool_size: pool_size,
    queue_target: queue_target,
    queue_interval: queue_interval,
    timeout: query_timeout,
    connect_timeout: connect_timeout
  ]

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
        socket: socket_dir <> "/.s.PGSQL.5432"
      ]
      |> Kernel.++(common_repo_options)
      |> Kernel.++(postgrex_pool_options)
    else
      # Direct connection (local/testing)
      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      [url: database_url, socket_options: maybe_ipv6]
      |> Kernel.++(database_tls_options)
      |> Kernel.++(common_repo_options)
      |> Kernel.++(postgrex_pool_options)
    end

  {_ca_options, database_ca_source} = database_ca_options

  database_tls_audit = %{
    mode:
      case database_tls_mode do
        :verify_peer -> :verify_peer
        {:insecure_override, _reason} -> :insecure_override
      end,
    ca_source: database_ca_source,
    repo_transport: if(socket_dir, do: :unix_socket, else: :tcp),
    insecure_override_reason:
      case database_tls_mode do
        :verify_peer -> nil
        {:insecure_override, reason} -> reason
      end
  }

  config :maraithon, Maraithon.Repo, repo_config
  config :maraithon, :direct_database_url, direct_database_url

  config :maraithon,
         :direct_database_options,
         [url: direct_database_url] ++ direct_database_tls_options

  config :maraithon, :database_tls_audit, database_tls_audit
  config :maraithon, :database_pool_mode, database_pool_mode

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

# =============================================================================
# Observability — Pydantic Logfire (OpenTelemetry / OTLP)
# =============================================================================
# Opt-in: when LOGFIRE_WRITE_TOKEN is set, traces export to Logfire. When it is
# absent (default dev/test), the exporter stays :none and nothing is sent.
#
# otlp_endpoint is a base URL — the exporter appends /v1/traces. The auth header
# value is the raw write token with NO "Bearer " prefix (Logfire-specific).
if logfire_token = System.get_env("LOGFIRE_WRITE_TOKEN") do
  config :opentelemetry,
    traces_exporter: :otlp,
    span_processor: :batch

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: System.get_env("LOGFIRE_ENDPOINT", "https://logfire-us.pydantic.dev"),
    otlp_headers: [{"authorization", logfire_token}]
end
