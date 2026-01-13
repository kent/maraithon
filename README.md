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

### Google Calendar (Available)

```bash
# Configure Google OAuth
export GOOGLE_CLIENT_ID="your_client_id"
export GOOGLE_CLIENT_SECRET="your_client_secret"
export GOOGLE_REDIRECT_URI="https://your-domain.com/auth/google/callback"
export GOOGLE_CALENDAR_WEBHOOK_URL="https://your-domain.com/webhooks/google/calendar"

# User authorizes via OAuth
# Visit: /auth/google?scopes=calendar&user_id=user_123

# Create agent subscribed to user's calendar
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Help me manage my schedule. Alert me about upcoming meetings.",
      "subscribe": ["calendar:user_123"]
    }
  }'
```

**Supported events**: `calendar_sync`, `calendar_event_created`, `calendar_event_updated`, `calendar_event_deleted`

### Gmail (Available)

```bash
# Additional config for Gmail (requires Cloud Pub/Sub)
export GOOGLE_PUBSUB_TOPIC="projects/your-project/topics/gmail-push"

# User authorizes via OAuth
# Visit: /auth/google?scopes=gmail&user_id=user_123
# Or both: /auth/google?scopes=calendar,gmail&user_id=user_123

# Create agent subscribed to user's email
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Summarize important emails and flag urgent ones.",
      "subscribe": ["email:user_123"]
    }
  }'
```

**Supported events**: `email_sync`, `email_received`, `email_changed`

### Slack (Available)

```bash
# Configure Slack app
export SLACK_CLIENT_ID="your_client_id"
export SLACK_CLIENT_SECRET="your_client_secret"
export SLACK_REDIRECT_URI="https://your-domain.com/auth/slack/callback"
export SLACK_SIGNING_SECRET="your_signing_secret"

# Install app to workspace via OAuth
# Visit: /auth/slack?user_id=user_123

# Create agent subscribed to workspace
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Monitor team discussions and summarize important updates.",
      "subscribe": ["slack:T01234567:C01234567"]
    }
  }'
```

**Supported events**: `message`, `message_changed`, `message_deleted`, `reaction_added`, `reaction_removed`, `app_mention`, `member_joined`, `member_left`

### WhatsApp (Available)

```bash
# Configure WhatsApp (Meta Business API)
export WHATSAPP_VERIFY_TOKEN="your_verify_token"
export WHATSAPP_APP_SECRET="your_app_secret"
export WHATSAPP_ACCESS_TOKEN="your_access_token"
export WHATSAPP_PHONE_NUMBER_ID="your_phone_number_id"

# Create agent subscribed to WhatsApp messages
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "You are a helpful assistant. Respond to user messages.",
      "subscribe": ["whatsapp:1234567890"]
    }
  }'
```

**Supported events**: `message_received`, `image_received`, `audio_received`, `document_received`, `location_received`, `message_status`

### Connector Status

| Connector | Status | Topic Format |
|-----------|--------|--------------|
| GitHub | Available | `github:{owner}/{repo}` |
| Google Calendar | Available | `calendar:{user_id}` |
| Gmail | Available | `email:{user_id}` |
| Slack | Available | `slack:{team_id}:{channel_id}` |
| WhatsApp | Available | `whatsapp:{phone_number_id}` |
| Linear | Planned | `linear:{team}` |
| Discord | Planned | `discord:{server}:{channel}` |

### Building Custom Connectors

```elixir
defmodule MyApp.Connectors.Custom do
  @behaviour Maraithon.Connectors.Connector

  @impl true
  def verify_signature(conn, raw_body) do
    # Verify webhook signature
  end

  @impl true
  def handle_webhook(conn, params) do
    # Parse webhook, return normalized event
    {:ok, "custom:topic", %{type: "event_type", ...}}
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
| `POST /webhooks/google/calendar` | Google Calendar push notifications |
| `POST /webhooks/google/gmail` | Gmail push notifications (via Pub/Sub) |
| `POST /webhooks/slack` | Slack Events API |
| `GET /webhooks/whatsapp` | WhatsApp webhook verification |
| `POST /webhooks/whatsapp` | WhatsApp message events |

### OAuth

| Endpoint | Description |
|----------|-------------|
| `GET /auth/google` | Initiate Google OAuth flow |
| `GET /auth/google/callback` | Google OAuth callback |
| `GET /auth/slack` | Initiate Slack OAuth flow |
| `GET /auth/slack/callback` | Slack OAuth callback |

## Configuration

```bash
# Required for LLM
export ANTHROPIC_API_KEY="sk-..."

# Optional
export ANTHROPIC_MODEL="claude-sonnet-4-20250514"
export GITHUB_WEBHOOK_SECRET="your_secret"
export DATABASE_URL="postgres://..."

# Google OAuth (required for Calendar/Gmail)
export GOOGLE_CLIENT_ID="your_client_id"
export GOOGLE_CLIENT_SECRET="your_client_secret"
export GOOGLE_REDIRECT_URI="https://your-domain.com/auth/google/callback"
export GOOGLE_CALENDAR_WEBHOOK_URL="https://your-domain.com/webhooks/google/calendar"
export GOOGLE_PUBSUB_TOPIC="projects/your-project/topics/gmail-push"

# Slack (required for Slack connector)
export SLACK_CLIENT_ID="your_client_id"
export SLACK_CLIENT_SECRET="your_client_secret"
export SLACK_REDIRECT_URI="https://your-domain.com/auth/slack/callback"
export SLACK_SIGNING_SECRET="your_signing_secret"

# WhatsApp (required for WhatsApp connector)
export WHATSAPP_VERIFY_TOKEN="your_verify_token"
export WHATSAPP_APP_SECRET="your_app_secret"
export WHATSAPP_ACCESS_TOKEN="your_access_token"
export WHATSAPP_PHONE_NUMBER_ID="your_phone_number_id"
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
