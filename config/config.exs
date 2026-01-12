# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :maraithon,
  ecto_repos: [Maraithon.Repo],
  generators: [timestamp_type: :utc_datetime]

# Maraithon runtime configuration
config :maraithon, Maraithon.Runtime,
  # Intervals
  heartbeat_interval_ms: :timer.minutes(15),
  checkpoint_interval_ms: :timer.minutes(10),
  effect_poll_interval_ms: :timer.seconds(1),
  scheduler_poll_interval_ms: :timer.seconds(5),
  # Timeouts
  llm_timeout_ms: :timer.seconds(120),
  tool_timeout_ms: :timer.seconds(30),
  # Retries
  max_effect_attempts: 3,
  # LLM provider
  llm_provider: Maraithon.LLM.MockProvider,
  anthropic_model: "claude-sonnet-4-20250514"

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

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
