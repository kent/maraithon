```
                                    ╭──────────────────────────────────────────────────────────────╮
                                    │                                                              │
 ███╗   ███╗ █████╗ ██████╗  █████╗ │ ██╗████████╗██╗  ██╗ ██████╗ ███╗   ██╗                      │
 ████╗ ████║██╔══██╗██╔══██╗██╔══██╗│ ██║╚══██╔══╝██║  ██║██╔═══██╗████╗  ██║                      │
 ██╔████╔██║███████║██████╔╝███████║│ ██║   ██║   ███████║██║   ██║██╔██╗ ██║                      │
 ██║╚██╔╝██║██╔══██║██╔══██╗██╔══██║│ ██║   ██║   ██╔══██║██║   ██║██║╚██╗██║                      │
 ██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██║│ ██║   ██║   ██║  ██║╚██████╔╝██║ ╚████║                      │
 ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝│ ╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝                      │
                                    │                                                              │
                                    │    Long-lived, autonomous AI agents powered by OTP          │
                                    ╰──────────────────────────────────────────────────────────────╯

     ┌─────────┐      Events       ┌─────────────────┐      LLM       ┌─────────────┐
     │ GitHub  │ ─────────────────►│                 │ ◄────────────► │  Claude /   │
     │ Slack   │                   │    MARAITHON    │                │  Anthropic  │
     │ Linear  │ ◄─────────────────│     AGENT       │ ◄────────────► │             │
     │ Gmail   │      Actions      │                 │     Tools      │             │
     └─────────┘                   └─────────────────┘                └─────────────┘
                                          │
                                          │ State
                                          ▼
                                   ┌─────────────┐
                                   │  PostgreSQL │
                                   │   + Events  │
                                   └─────────────┘
```

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

### What Makes This Powerful

**Traditional Approach:**
```
Cron job runs → Agent wakes up → Checks for changes → Does work → Dies
```

**Maraithon Approach:**
```
Event happens → Agent receives it instantly → Responds → Stays alive
```

Your agent is **always watching**, **always remembering**, and **always ready**. No polling. No cold starts. No missed events.

## Architecture

```
╔══════════════════════════════════════════════════════════════════════════════════════╗
║                                    MARAITHON                                          ║
╠══════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                       ║
║   ┌──────────────────┐          ┌──────────────────────────────┐    ┌─────────────┐  ║
║   │   CONNECTORS     │          │        AGENT RUNTIME         │    │    TOOLS    │  ║
║   │                  │          │                              │    │             │  ║
║   │  ┌────────────┐  │  events  │   ╭────────────────────╮     │    │ read_file   │  ║
║   │  │  GitHub    │──┼─────────►│   │  GenStateMachine   │     │    │ search_files│  ║
║   │  └────────────┘  │          │   │  ┌──────┐ ┌──────┐ │     │    │ http_get    │  ║
║   │  ┌────────────┐  │          │   │  │ idle │►│ work │ │     │    │ file_tree   │  ║
║   │  │  Slack     │──┼─────────►│   │  └──────┘ └──┬───┘ │     │    │ bash        │  ║
║   │  └────────────┘  │          │   │       ▲      │     │     │    │ edit_file   │  ║
║   │  ┌────────────┐  │          │   │       └──────┘     │     │    │ write_file  │  ║
║   │  │  Linear    │──┼─────────►│   ╰────────────────────╯     │◄───┤             │  ║
║   │  └────────────┘  │          │                              │    │ custom...   │  ║
║   │  ┌────────────┐  │          │   ┌────────────────────┐     │    │             │  ║
║   │  │  Gmail     │──┼─────────►│   │   Event Sourcing   │     │    └─────────────┘  ║
║   │  └────────────┘  │          │   │   ┌─┬─┬─┬─┬─┬─┬─┐  │     │                     ║
║   │  ┌────────────┐  │          │   │   │E│E│E│E│E│E│E│  │     │    ┌─────────────┐  ║
║   │  │  WhatsApp  │──┼─────────►│   │   └─┴─┴─┴─┴─┴─┴─┘  │     │    │     LLM     │  ║
║   │  └────────────┘  │          │   └────────────────────┘     │    │             │  ║
║   │  ┌────────────┐  │          │                              │    │  ┌───────┐  │  ║
║   │  │  Telegram  │──┼─────────►│   ┌────────────────────┐     │◄──►│  │Claude │  │  ║
║   │  └────────────┘  │          │   │   OTP Supervisor   │     │    │  └───────┘  │  ║
║   │  ┌────────────┐  │          │   │   ┌─────┐ ┌─────┐  │     │    │             │  ║
║   │  │  Calendar  │──┼─────────►│   │   │Agent│ │Agent│  │     │    └─────────────┘  ║
║   │  └────────────┘  │          │   │   └─────┘ └─────┘  │     │                     ║
║   │                  │          │   └────────────────────┘     │                     ║
║   └──────────────────┘          └──────────────────────────────┘                     ║
║                                              │                                        ║
║                                              ▼                                        ║
║                                    ┌──────────────────┐                              ║
║                                    │    PostgreSQL    │                              ║
║                                    │  ┌────────────┐  │                              ║
║                                    │  │   agents   │  │                              ║
║                                    │  │   events   │  │                              ║
║                                    │  │   tokens   │  │                              ║
║                                    │  │   jobs     │  │                              ║
║                                    │  └────────────┘  │                              ║
║                                    └──────────────────┘                              ║
╚══════════════════════════════════════════════════════════════════════════════════════╝
```

**Connectors** receive webhooks from external services and publish normalized events to PubSub. Built-in connectors for GitHub, Google Calendar, Gmail, Slack, WhatsApp, Linear, and Telegram.

**Agent Runtime** manages agent lifecycle, state persistence, LLM calls, and tool execution. Built on OTP for fault tolerance and supervision.

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

### Linear (Available)

```bash
# Configure Linear OAuth
export LINEAR_CLIENT_ID="your_client_id"
export LINEAR_CLIENT_SECRET="your_client_secret"
export LINEAR_REDIRECT_URI="https://your-domain.com/auth/linear/callback"
export LINEAR_WEBHOOK_SECRET="your_webhook_secret"

# User authorizes via OAuth
# Visit: /auth/linear?user_id=user_123

# Create agent subscribed to Linear issues
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "When new issues are created, analyze them and suggest implementation plans.",
      "subscribe": ["linear:eng"]
    }
  }'
```

**Supported events**: `issue_created`, `issue_updated`, `issue_removed`, `comment_created`, `comment_updated`, `project_created`, `cycle_created`

### Telegram (Available)

```bash
# Configure Telegram bot
export TELEGRAM_BOT_TOKEN="123456789:ABC..."
export TELEGRAM_WEBHOOK_SECRET="random_secret_string"

# Set webhook (call once)
# Telegram.set_webhook("https://your-domain.com/webhooks/telegram/your_secret")

# Create agent subscribed to Telegram messages
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "You are a helpful assistant. Respond to user messages.",
      "subscribe": ["telegram:123456789:-100123456"]
    }
  }'
```

**Supported events**: `message`, `photo`, `document`, `voice`, `video`, `location`, `callback_query`, `edited_message`, `member_joined`, `member_left`

### Connector Status

| Connector | Status | Topic Format |
|-----------|--------|--------------|
| GitHub | Available | `github:{owner}/{repo}` |
| Google Calendar | Available | `calendar:{user_id}` |
| Gmail | Available | `email:{user_id}` |
| Slack | Available | `slack:{team_id}:{channel_id}` |
| WhatsApp | Available | `whatsapp:{phone_number_id}` |
| Linear | Available | `linear:{team_key}` |
| Telegram | Available | `telegram:{bot_id}:{chat_id}` |
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

`/api/v1/*` endpoints can be protected with bearer auth by setting `API_BEARER_TOKEN`.
When enabled, include: `Authorization: Bearer <API_BEARER_TOKEN>`.

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
| `POST /webhooks/linear` | Linear webhooks |
| `POST /webhooks/telegram/:secret` | Telegram bot updates |

### OAuth

| Endpoint | Description |
|----------|-------------|
| `GET /auth/google` | Initiate Google OAuth flow |
| `GET /auth/google/callback` | Google OAuth callback |
| `GET /auth/slack` | Initiate Slack OAuth flow |
| `GET /auth/slack/callback` | Slack OAuth callback |
| `GET /auth/linear` | Initiate Linear OAuth flow |
| `GET /auth/linear/callback` | Linear OAuth callback |

## Configuration

```bash
# Required for LLM
export ANTHROPIC_API_KEY="sk-..."

# Required for production security
export ADMIN_USERNAME="admin"
export ADMIN_PASSWORD="replace-with-long-random-password"
export API_BEARER_TOKEN="replace-with-long-random-token"

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

# Linear (required for Linear connector)
export LINEAR_CLIENT_ID="your_client_id"
export LINEAR_CLIENT_SECRET="your_client_secret"
export LINEAR_REDIRECT_URI="https://your-domain.com/auth/linear/callback"
export LINEAR_WEBHOOK_SECRET="your_webhook_secret"

# Telegram (required for Telegram connector)
export TELEGRAM_BOT_TOKEN="123456789:ABC..."
export TELEGRAM_WEBHOOK_SECRET="random_secret_path"
```

## Use Cases

```
╔═══════════════════════════════════════════════════════════════════════════════════════╗
║                                                                                        ║
║   "Agents don't just respond to requests.                                              ║
║    They live in your world and act on your behalf."                                    ║
║                                                                                        ║
╚═══════════════════════════════════════════════════════════════════════════════════════╝
```

### GitHub Issue Planner
```json
{
  "prompt": "When new issues are created, analyze the codebase and generate implementation plans.",
  "subscribe": ["github:acme/api"],
  "tools": ["read_file", "search_files", "file_tree"]
}
```
Agent watches a repo. When an issue is opened → reads relevant code → generates a plan → posts as a comment.

### Personal Assistant
```json
{
  "prompt": "You're my assistant. Keep me organized and respond via Telegram.",
  "subscribe": ["calendar:user_123", "email:user_123", "telegram:bot:chat_123"]
}
```
Agent connected to your calendar, email, and Telegram. Knows your schedule. Reminds you of meetings. Summarizes important emails. All through a chat interface.

### DevOps On-Call
```json
{
  "prompt": "Monitor Linear for urgent issues. Triage and notify the team on Slack.",
  "subscribe": ["linear:eng", "slack:T123:C456"]
}
```
Agent watches Linear for P0 issues. When one appears → analyzes the issue → posts to Slack with context → assigns the right engineer.

### Customer Support Bot
```json
{
  "prompt": "Answer customer questions on WhatsApp. Escalate complex issues.",
  "subscribe": ["whatsapp:1234567890"]
}
```
Agent responds to WhatsApp messages instantly. Uses context from previous conversations. Hands off to humans when needed.

### Team Standup
```json
{
  "prompt": "Every morning, summarize yesterday's GitHub and Linear activity for the team.",
  "subscribe": ["github:acme/api", "linear:eng", "slack:T123:C456"]
}
```
Agent collects commits, merged PRs, and completed issues. Posts a formatted summary to Slack each morning.

## Why OTP?

Traditional AI agents are stateless scripts that wake up, do a thing, and die. Maraithon agents are **OTP processes**:

```
  Traditional Agent                          Maraithon Agent
  ═════════════════                          ════════════════

  ┌─────────────────┐                        ┌─────────────────────────────────┐
  │   Cron Trigger  │                        │         OTP Supervisor          │
  └────────┬────────┘                        │  ┌─────────────────────────────┐│
           │                                 │  │        Agent Process        ││
           ▼                                 │  │                             ││
  ┌─────────────────┐                        │  │  ┌─────┐    ┌──────────┐   ││
  │  Script Starts  │                        │  │  │State│◄──►│ Messages │   ││
  └────────┬────────┘                        │  │  └─────┘    └──────────┘   ││
           │                                 │  │                             ││
           ▼                                 │  │  ╭─────────────────────╮    ││
  ┌─────────────────┐     No                 │  │  │    Always Alive     │    ││
  │  Check Changes  │───► Memory             │  │  │   Instant Response  │    ││
  └────────┬────────┘                        │  │  │   Auto-Recover      │    ││
           │                                 │  │  ╰─────────────────────╯    ││
           ▼                                 │  │                             ││
  ┌─────────────────┐                        │  └─────────────────────────────┘│
  │    Do Work      │                        │                ▲                │
  └────────┬────────┘                        │                │ Restart        │
           │                                 │         ┌──────┴──────┐         │
           ▼                                 │         │   Crash?    │         │
  ┌─────────────────┐                        │         │  No Problem │         │
  │   Script Dies   │ ◄── State Lost         │         └─────────────┘         │
  └─────────────────┘                        └─────────────────────────────────┘
```

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

---

```
                         ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
                         █                                               █
                         █   Built with Elixir, Phoenix, and OTP         █
                         █   Powered by Claude / Anthropic               █
                         █                                               █
                         █       🏃 Agents that never stop running       █
                         █                                               █
                         ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
```
