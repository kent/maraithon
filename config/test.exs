import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :maraithon, Maraithon.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD") || "",
  hostname: "localhost",
  database: "maraithon_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :maraithon, MaraithonWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vvoIwP8nNJp8lGFZ9RR6Y7P31JfQ2raSNyk9Yev1qEa74gLVB0jW7aP8eFztubBE",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Allow insecure vault in test (uses deterministic key, NOT for production)
config :maraithon, allow_insecure_vault: true

# Disable background workers that poll the database (Scheduler, EffectRunner)
# Tests should start these explicitly if needed
config :maraithon, start_background_workers: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
