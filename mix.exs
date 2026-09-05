defmodule Maraithon.MixProject do
  use Mix.Project

  def project do
    [
      app: :maraithon,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      # Test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        test: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        precommit: :test,
        "maraithon.assistant.eval": :test,
        "maraithon.verify_telegram_chat": :test
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Maraithon.Application, []},
      # :inets is needed by opentelemetry_exporter's HTTP (httpc) transport;
      # listing it here avoids the :inets_not_started boot race on the OTLP exporter.
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_view, "~> 1.1.33"},
      {:phoenix_html, "~> 4.1"},
      {:plug, "~> 1.19.5"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:ecto_sql, "~> 3.13.4"},
      {:postgrex, "~> 0.22.4"},
      {:decimal, "~> 3.1.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4.5"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.12.5"},
      # Maraithon-specific deps
      # gen_statem wrapper
      {:gen_state_machine, "~> 3.0"},
      # HTTP client for LLM calls
      {:finch, "~> 0.21.0"},
      # High-level HTTP client
      {:req, "~> 0.6.3"},
      # Low-level pinned-address transport for the HTTP GET tool
      {:mint, "~> 1.10.0"},
      # Struct definitions
      {:typed_struct, "~> 0.3"},
      # Config validation
      {:nimble_options, "~> 1.1"},
      # Security
      # Encryption at rest
      {:cloak, "~> 1.1"},
      # Ecto integration for Cloak
      {:cloak_ecto, "~> 1.3"},
      # pgvector Ecto type for embedding-based search
      {:pgvector, "~> 0.3"},
      # Testing
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind app", "esbuild app"],
      "assets.deploy": ["tailwind app --minify", "esbuild app --minify", "phx.digest"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test --no-start"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test",
        "maraithon.assistant.eval --fail-on-issues"
      ]
    ]
  end
end
