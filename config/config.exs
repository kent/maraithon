# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Never render webhook credentials or auth material in Phoenix parameter logs.
# Secret-bearing Telegram request paths are separately redacted before telemetry.
config :phoenix, :filter_parameters, ["password", "secret", "token", "credential"]

config :maraithon,
  ecto_repos: [Maraithon.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Local development keeps the historical single-node topology. Production
  # runtime config requires an explicit fail-closed service role.
  process_role: :combined

# Build-time asset pipeline. Tailwind stays on 3.4 so compiled output matches
# the classes the templates were written against (the old CDN runtime was v3).
config :esbuild,
  version: "0.25.4",
  app: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => Enum.join([Path.expand("../deps", __DIR__), Mix.Project.build_path()], ":")
    }
  ]

config :tailwind,
  version: "3.4.17",
  app: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Use a custom Postgrex types module so pgvector types are registered.
config :maraithon, Maraithon.Repo,
  types: Maraithon.PostgrexTypes,
  migration_lock: :pg_advisory_lock

# Maraithon runtime configuration
config :maraithon, Maraithon.Runtime,
  # Fail closed until the mandatory non-rolling exact-runtime cutover.
  exact_agent_runtime_enabled: false,
  # Separate stopped-fleet/manual DB cutover; never a rolling feature flag.
  multinode_coordination_enabled: false,
  # Intervals
  heartbeat_interval_ms: :timer.minutes(15),
  checkpoint_interval_ms: :timer.minutes(10),
  effect_poll_interval_ms: :timer.seconds(1),
  # Must stay above the longest permitted LLM effect; otherwise a healthy
  # request can be reclaimed and executed twice while its first claim runs.
  effect_claim_timeout_ms: :timer.minutes(25),
  effect_batch_size: 10,
  scheduler_poll_interval_ms: :timer.seconds(5),
  scheduler_dispatch_timeout_ms: :timer.minutes(1),
  recurring_job_reconcile_interval_ms: :timer.minutes(1),
  privacy_erasure_discovery_interval_ms: :timer.minutes(1),
  privacy_erasure_discovery_initial_delay_ms: :timer.seconds(10),
  privacy_retention_interval_ms: :timer.minutes(15),
  privacy_retention_initial_delay_ms: :timer.seconds(20),
  provider_job_max_concurrency: 4,
  model_job_max_concurrency: 3,
  source_fanout_tenant_max_concurrency: 3,
  briefing_cron_interval_ms: :timer.minutes(1),
  brief_notify_interval_ms: :timer.minutes(1),
  insight_notify_interval_ms: :timer.minutes(1),
  assistant_run_recovery_interval_ms: :timer.minutes(1),
  run_reaper_poll_interval_ms: :timer.minutes(1),
  health_report_interval_ms: :timer.minutes(1),
  proactive_check_in_interval_ms: :timer.minutes(10),
  proactive_check_in_initial_delay_ms: :timer.minutes(10),
  proactive_check_in_batch_size: 25,
  todo_completion_sweep_interval_ms: :timer.minutes(1),
  todo_completion_sweep_initial_delay_ms: :timer.minutes(1),
  oauth_refresh_interval_ms: :timer.minutes(5),
  oauth_refresh_lookahead_seconds: 15 * 60,
  oauth_refresh_batch_size: 100,
  tool_allowed_paths: [File.cwd!(), System.tmp_dir!()],
  # Timeouts
  llm_timeout_ms: :timer.seconds(120),
  tool_timeout_ms: :timer.seconds(30),
  # Retries
  max_effect_attempts: 3,
  # LLM provider
  llm_provider: nil,
  llm_provider_name: "unconfigured",
  llm_model: "gpt-5.4",
  anthropic_model: "claude-sonnet-4-20250514",
  openai_model: "gpt-5.4",
  openrouter_model: "moonshotai/kimi-k3",
  openrouter_reasoning_effort: "high",
  openai_reasoning_effort: "high",
  llm_primary_max_tokens: 32_000

# Conservative maximum content-retention windows. Runtime overrides are
# strictly range-checked by Maraithon.PrivacyRetention; invalid values fail the
# durable handler closed rather than silently falling back.
config :maraithon, Maraithon.PrivacyRetention,
  effects_days: 30,
  directives_days: 30,
  events_days: 90,
  run_steps_days: 30,
  agent_runs_days: 30,
  assistant_runs_days: 30,
  assistant_steps_days: 30,
  prepared_actions_days: 30,
  operator_events_days: 90,
  background_jobs_days: 30,
  scheduled_jobs_days: 30,
  ingress_receipts_days: 90,
  work_results_days: 30,
  conversation_days: 90,
  snapshot_quarantine_days: 30,
  erasure_receipts_days: 365,
  batch_size: 100,
  per_tenant: 5,
  alert_grace_hours: 24,
  critical_grace_hours: 168

config :maraithon, :telegram_assistant,
  chat_reasoning_effort: "none",
  telegram_proactive_checkins_enabled: false,
  proactive_delivery_planner_enabled: true,
  proactive_candidate_ttl_minutes: 120

# Configure the endpoint
config :maraithon, MaraithonWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MaraithonWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Maraithon.PubSub,
  live_view: [signing_salt: "CbxGKvU2"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger,
  backends: [:console, Maraithon.LogBufferBackend]

config :logger, Maraithon.LogBufferBackend, level: :debug

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :maraithon, Maraithon.LogBuffer, max_entries: 500

config :maraithon, Maraithon.FlyLogs,
  api_token: "",
  api_base_url: "https://api.fly.io/api/v1",
  apps: [],
  region: nil,
  receive_timeout_ms: 3_000

config :maraithon, Maraithon.WebSearch,
  enabled: true,
  base_url: "https://duckduckgo.com/html/",
  limit: 3

# OpenTelemetry — traces export is disabled by default and turned on in
# config/runtime.exs only when LOGFIRE_WRITE_TOKEN is present.
#
# The sampler drops root-level Ecto query spans (background-poller noise)
# while keeping Ecto queries that are children of a real trace — see
# Maraithon.Telemetry.OtelSampler. Wrapped in :parent_based so children
# follow their parent's decision.
config :opentelemetry,
  traces_exporter: :none,
  sampler: {:parent_based, %{root: {Maraithon.Telemetry.OtelSampler, %{}}}},
  resource: %{service: %{name: "maraithon"}}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
