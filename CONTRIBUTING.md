# Contributing to Maraithon

Thank you for your interest in contributing to Maraithon! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 14+
- Git

### Setup

```bash
# Clone the repository
git clone https://github.com/kent/maraithon.git
cd maraithon

# Install dependencies
mix deps.get

# Setup database
mix ecto.setup

# Fast compile check
make build

# Start development server
mix phx.server
```

## Development Workflow

### Current Fast Loop

```bash
make build   # Phoenix compile
make deploy  # cached single-service test-app deploy
```

Maraithon is in manual-first, single-user test-app mode. Do not run or add
automated tests by default. The authoritative policy, including explicit
hardening commands, is [`docs/development-mode.md`](docs/development-mode.md).

### Code Quality

Use the narrowest compile/build check relevant to the change:

```bash
mix compile --warnings-as-errors  # No compiler warnings
mix format --check-formatted      # Check formatting when relevant
```

Do not run `mix precommit`, test suites, or smoke-test gates unless Kent
explicitly asks for hardening. Kent performs the routine product validation
manually after deployment.

## Code Style

### Formatting

We use the standard Elixir formatter. Format your code before committing:

```bash
mix format
```

### Conventions

- Use `Logger.warning/2` (not deprecated `Logger.warn`)
- Prefer pattern matching over conditionals where readable
- Use typespecs for public functions
- Keep modules focused and under 300 lines when possible
- Use `alias` for frequently used modules
- Prefer explicit imports over `use` when possible

### Module Organization

```elixir
defmodule Maraithon.Example do
  @moduledoc """
  Brief description of the module.
  """

  # 1. use/import/alias/require
  use GenServer
  alias Maraithon.Other
  require Logger

  # 2. Module attributes
  @default_timeout 5000

  # 3. Public API
  def start_link(opts), do: ...

  # 4. Callbacks (if applicable)
  @impl true
  def init(state), do: ...

  # 5. Private functions
  defp helper(), do: ...
end
```

## Project Structure

```
lib/
├── maraithon/
│   ├── agents/           # Agent schema and context
│   ├── behaviors/        # Agent behavior implementations
│   ├── connectors/       # External service connectors (GitHub, Slack, etc.)
│   ├── oauth/            # OAuth helpers for each provider
│   ├── runtime/          # Agent runtime (supervisor, scheduler, effects)
│   ├── crypto.ex         # Shared cryptographic utilities
│   ├── http.ex           # Shared HTTP client
│   └── ...
├── maraithon_web/
│   ├── controllers/      # API and webhook controllers
│   ├── router.ex         # Route definitions
│   └── ...
test/
├── maraithon/            # Unit tests
├── maraithon_web/        # Controller/integration tests
└── support/              # Test helpers
```

## Making Changes

### Branching

- Create feature branches from `main`
- Use descriptive branch names: `feature/add-discord-connector`, `fix/oauth-token-refresh`

### Commits

- Write clear, concise commit messages
- Use conventional commit format when applicable:
  - `feat: add Discord connector`
  - `fix: handle OAuth token expiration`
  - `docs: update API documentation`
  - `refactor: extract shared HTTP client`
  - `test: add connector unit tests`

### Pull Requests

1. Run the narrowest relevant compile/build check.
2. Update documentation when behavior or operating rules change.
3. Keep PRs focused—one feature or fix per PR.
4. Leave automated testing to an explicitly requested hardening pass.

### PR Checklist

- [ ] No compiler warnings (`mix compile --warnings-as-errors`)
- [ ] Code is formatted (`mix format`)
- [ ] Documentation updated (if applicable)
- [ ] Tests intentionally not run, or explicitly requested test results reported

## Adding New Connectors

Connectors integrate external services (webhooks) with Maraithon. To add a new connector:

1. Create `lib/maraithon/connectors/your_service.ex`
2. Implement the `Maraithon.Connectors.Connector` behaviour:

```elixir
defmodule Maraithon.Connectors.YourService do
  @behaviour Maraithon.Connectors.Connector

  @impl true
  def verify_signature(conn, raw_body) do
    # Verify webhook signature
  end

  @impl true
  def handle_webhook(conn, params) do
    # Parse webhook and return {:ok, topic, event}
  end
end
```

3. Add routes in `router.ex`
4. Add configuration in `runtime.exs`
5. Keep the implementation testable for a later hardening pass
6. Document in README

## Adding New Behaviors

Behaviors define how agents think and act. To add a new behavior:

1. Create `lib/maraithon/behaviors/your_behavior.ex`
2. Implement the `Maraithon.Behaviors.Behavior` behaviour
3. Register in `lib/maraithon/behaviors.ex`
4. Keep the implementation testable for a later hardening pass
5. Document usage

## Testing Guidelines

The existing unit and integration suites remain in the repository but are
dormant during the current manual-first mode. Do not delete or weaken them, and
do not add, update, or run tests unless Kent explicitly requests that work.

When hardening is requested, prefer focused tests first and treat every failure
as a real product defect or a deliberately obsolete expectation. Never skip or
game a failing check merely to make a run green.

## Security

- Never commit secrets or API keys
- Use `System.get_env/1` for configuration
- Report security vulnerabilities privately (do not open public issues)
- Follow OWASP guidelines for web security

## Getting Help

- Open an issue for bugs or feature requests
- Check existing issues before creating new ones
- Be respectful and constructive in discussions

## License

By contributing to Maraithon, you agree that your contributions will be licensed under the same license as the project.
