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

# Run tests
mix test

# Start development server
mix phx.server
```

## Development Workflow

### Running Tests

```bash
# Run all tests
mix test

# Run tests with coverage (once configured)
mix coveralls

# Run a specific test file
mix test test/path/to/test.exs

# Run tests matching a pattern
mix test --only tag_name
```

### Code Quality

Before submitting a PR, ensure your code passes all checks:

```bash
# Run the full precommit suite
mix precommit

# Or run individual checks:
mix compile --warnings-as-errors  # No compiler warnings
mix format --check-formatted       # Code is formatted
mix test                           # Tests pass
```

### Smoke Tests

Run the smoke test script to verify the application works end-to-end:

```bash
./scripts/smoke_test.sh
```

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

- Create feature branches from `master`
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

1. Ensure all tests pass
2. Run `mix precommit` before pushing
3. Update documentation if needed
4. Add tests for new functionality
5. Keep PRs focused - one feature/fix per PR

### PR Checklist

- [ ] Tests pass (`mix test`)
- [ ] No compiler warnings (`mix compile --warnings-as-errors`)
- [ ] Code is formatted (`mix format`)
- [ ] Documentation updated (if applicable)
- [ ] Smoke tests pass (`./scripts/smoke_test.sh`)

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
5. Add tests
6. Document in README

## Adding New Behaviors

Behaviors define how agents think and act. To add a new behavior:

1. Create `lib/maraithon/behaviors/your_behavior.ex`
2. Implement the `Maraithon.Behaviors.Behavior` behaviour
3. Register in `lib/maraithon/behaviors.ex`
4. Add tests
5. Document usage

## Testing Guidelines

### Unit Tests

Test individual functions in isolation:

```elixir
defmodule Maraithon.CryptoTest do
  use ExUnit.Case, async: true

  describe "verify_hmac_sha256/3" do
    test "returns :ok for valid signature" do
      # ...
    end

    test "returns error for invalid signature" do
      # ...
    end
  end
end
```

### Integration Tests

Test components working together:

```elixir
defmodule MaraithonWeb.WebhookControllerTest do
  use MaraithonWeb.ConnCase

  test "processes valid GitHub webhook" do
    # ...
  end
end
```

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
