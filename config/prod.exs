import Config

# Note: SSL is handled by Cloud Run, not the app
# Health check endpoint excluded from any SSL checks

# Production logging - JSON format for Cloud Logging
config :logger, :default_formatter,
  format: {Maraithon.LogFormatter, :format},
  metadata: [:request_id, :agent_id, :effect_id, :job_id]

config :logger,
  level: :info,
  backends: [:console, Maraithon.LogBufferBackend]

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
