# Maraithon

A framework for building long-lived, autonomous AI agents powered by OTP.

## The Vision

Most AI agents are request-response: you ask, they answer, done. Maraithon agents are different—they're **always alive**, maintaining continuous presence in your digital world.

```
Agent = Prompt + State + Subscriptions + Tools
```

- **Prompt**: Who the agent is and how it thinks
- **State**: What it remembers, what it's seen (persists across restarts)
- **Subscriptions**: Event streams it's watching (GitHub, Slack, calendars, etc.)
- **Tools**: Actions it can take

An agent doesn't wake up on a schedule. It's **subscribed** to the world and reacts instantly to events.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Maraithon                                │
├─────────────────────────────────────────────────────────────────┤
│  Connectors          │  Agent Runtime        │  Tools           │
│  ─────────           │  ─────────────        │  ─────           │
│  GitHub      ──┐     │  GenStateMachine      │  read_file       │
│  Slack (soon)  ├──►  │  Event Sourcing       │  search_files    │
│  Calendar      │     │  Effect Outbox        │  http_get        │
│  Email         │     │  PubSub               │  file_tree       │
│  Custom    ────┘     │  Supervision          │  custom...       │
└─────────────────────────────────────────────────────────────────┘
```

**Connectors** receive webhooks from external services and publish normalized events to PubSub.

**Agent Runtime** manages agent lifecycle, state persistence, LLM calls, and tool execution.

**Tools** are actions agents can take to interact with the world.

## Quick Start

```bash
# Setup
mix setup
mix phx.server

# Create a prompt-driven agent
curl -X POST http://localhost:4000/api/v1/agents \
  -H "Content-Type: application/json" \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "name": "my-agent",
      "prompt": "You are a helpful assistant that watches for events and responds thoughtfully.",
      "subscribe": ["my-topic"],
      "tools": ["read_file", "http_get"]
    }
  }'

# Send an event
curl -X POST http://localhost:4000/api/v1/events \
  -H "Content-Type: application/json" \
  -d '{"topic": "my-topic", "payload": {"message": "Hello!"}}'

# Check agent events
curl http://localhost:4000/api/v1/agents/{id}/events
```

## Behaviors

Agents are defined by **behaviors**—modules that implement how agents think and act.

### PromptAgent (Generic)

Define agent behavior through a prompt, no code required:

```json
{
  "behavior": "prompt_agent",
  "config": {
    "name": "issue-planner",
    "prompt": "When you see new GitHub issues, generate implementation plans.",
    "subscribe": ["github:acme/widgets"],
    "tools": ["read_file", "search_files"],
    "memory_limit": 100
  }
}
```

### Custom Behaviors

Build specialized behaviors in Elixir:

- `CodebaseAdvisor` - Reviews code and suggests improvements
- `RepoPlanner` - Generates implementation plans from codebase context
- `WatchdogSummarizer` - Monitors and summarizes activity

## Connectors

Connectors bridge external services to agents via webhooks.

### GitHub (Available)

```bash
# Configure webhook secret
export GITHUB_WEBHOOK_SECRET="your_secret"

# Create agent subscribed to a repo
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Analyze new issues and suggest solutions.",
      "subscribe": ["github:owner/repo"]
    }
  }'

# Configure GitHub webhook:
# URL: https://your-domain.com/webhooks/github
# Content type: application/json
# Secret: your_secret
```

**Supported events**: `issue_opened`, `issue_closed`, `pr_opened`, `pr_merged`, `push`, `comment_created`, and more.

### Future Connectors

| Connector | Status | Topic Format |
|-----------|--------|--------------|
| GitHub | Available | `github:{owner}/{repo}` |
| Slack | Planned | `slack:{workspace}:{channel}` |
| Google Calendar | Planned | `calendar:{user_id}` |
| Gmail | Planned | `email:{user_id}` |
| Linear | Planned | `linear:{team}` |
| Discord | Planned | `discord:{server}:{channel}` |

### Building Custom Connectors

```elixir
defmodule MyApp.Connectors.Slack do
  @behaviour Maraithon.Connectors.Connector

  @impl true
  def verify_signature(conn, raw_body) do
    # Verify Slack signature
  end

  @impl true
  def handle_webhook(conn, params) do
    # Parse webhook, return normalized event
    {:ok, "slack:workspace:channel", %{type: "message", ...}}
  end
end
```

## API Reference

### Agents

| Endpoint | Description |
|----------|-------------|
| `POST /api/v1/agents` | Create agent |
| `GET /api/v1/agents` | List agents |
| `GET /api/v1/agents/:id` | Get agent details |
| `POST /api/v1/agents/:id/ask` | Send message to agent |
| `POST /api/v1/agents/:id/stop` | Stop agent |
| `GET /api/v1/agents/:id/events` | Get agent events |
| `GET /api/v1/agents/:id/spend` | Get agent LLM spend |

### Events

| Endpoint | Description |
|----------|-------------|
| `POST /api/v1/events` | Publish event to topic |

### Webhooks

| Endpoint | Description |
|----------|-------------|
| `POST /webhooks/github` | GitHub webhook receiver |

## Configuration

```bash
# Required for LLM
export ANTHROPIC_API_KEY="sk-..."

# Optional
export ANTHROPIC_MODEL="claude-sonnet-4-20250514"
export GITHUB_WEBHOOK_SECRET="your_secret"
export DATABASE_URL="postgres://..."
```

## Use Cases

### GitHub Issue Planner
Agent watches a repo, generates implementation plans for new issues.

### Personal Assistant
Agent connected to calendar, email, and chat—always aware of your schedule.

### Code Guardian
Agent monitors PRs and commits, flags security issues or code smells.

### Team Digest
Agent summarizes daily activity across GitHub, Slack, and Linear.

## Why OTP?

Traditional AI agents are stateless scripts that wake up, do a thing, and die. Maraithon agents are **OTP processes**:

- **Always alive** - No cold starts, instant response
- **Supervised** - Crash? Restart automatically with recovered state
- **Event-driven** - React to webhooks, messages, timers instantly
- **Persistent** - State survives restarts via event sourcing
- **Observable** - LiveView dashboard, event logs, spend tracking

## Development

```bash
# Install dependencies
mix deps.get

# Setup database
mix ecto.setup

# Run server
mix phx.server

# Run tests
mix test
```

## License

MIT
