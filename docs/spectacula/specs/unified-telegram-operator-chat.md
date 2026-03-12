# Unified Telegram Operator Chat

Status: Draft v1
Purpose: Define a single-user Telegram chat assistant for Maraithon that can converse freely, use connected-account and agent context, execute actions safely, and serve as the unified push channel for running agents.
Supersedes: `docs/plans/telegram_conversational_memory_spec.md` for the implementation contract of the Telegram chat surface.

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon already has a partial Telegram interaction layer, but it is not yet a full operator chat product.

Today the Telegram surface can:

- link a Telegram DM to a Maraithon user
- accept freeform DM messages
- persist Telegram conversations and turns
- explain a linked insight
- learn some durable preferences
- perform a narrow set of insight-adjacent actions

That is not the same as "chat with Maraithon."

The user wants Telegram to become the primary conversational control plane for a single operator:

- one unified Maraithon assistant in Telegram
- aware of recent Telegram turns, open work, connected accounts, learned memory, and active agents
- able to retrieve raw context from connected systems when needed
- able to control the user's running agents
- able to draft and execute external actions when safe
- able to proactively push the best content from any running agent through the same Telegram relationship

The current implementation is too shallow for that goal. It still behaves like a reply interpreter around notifications, not a full assistant with tools, memory, and operational authority.

### 1.2 Goals

- Turn Telegram DM into a real single-user Maraithon chat surface.
- Keep one unified assistant identity rather than separate per-agent bots.
- Give the assistant access to all connected-account context the user has authorized:
  Gmail, Google Calendar, Slack, Linear, Notaui, GitHub, and future connected providers.
- Include current Maraithon context in every run:
  open insights, operator memory, preference memory, recent Telegram turns, connected accounts, and active agents.
- Let the assistant inspect, control, and, where practical, create or update agents using existing builder/runtime contracts.
- Route proactive content from running agents through one Telegram push broker so the operator sees a coherent stream instead of disconnected per-feature senders.
- Preserve strict system-owned safety around identity, permissions, confirmations, and external side effects.

### 1.3 Non-Goals

- Group chats, shared team chats, or multi-user Telegram conversations in v1.
- A general consumer chatbot unrelated to Maraithon workflows.
- Unlimited autonomous external writes without operator confirmation.
- Exposing low-level filesystem or arbitrary HTTP tools to Telegram chat in v1.
- Replacing the web app for high-density inspection UI. Telegram can control and inspect the system, but dense multi-panel analysis remains better on the web.

### 1.4 Product Decisions From This Request

- Scope is single-user Telegram DM only.
- The assistant should use all connected context that belongs to the linked user.
- Telegram should expose one unified Maraithon assistant, not multiple agent personas.
- The unified assistant should have access to the user's running agents.
- Proactive pushes are allowed when the system judges they are useful, subject to rate limits and interruption policy.
- Agent and external action control should be as broad as possible, with safety gates where needed.

## 2. Current State and Gap Analysis

### 2.1 Existing Telegram Surface

Relevant modules and artifacts:

- [`lib/maraithon/insight_notifications.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex)
- [`lib/maraithon/telegram_router.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_router.ex)
- [`lib/maraithon/telegram_interpreter.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_interpreter.ex)
- [`lib/maraithon/telegram_conversations.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_conversations.ex)
- [`lib/maraithon/telegram_responder.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_responder.ex)
- [`lib/maraithon/preference_memory.ex`](/Users/kent/bliss/maraithon/lib/maraithon/preference_memory.ex)
- [`lib/maraithon/operator_memory.ex`](/Users/kent/bliss/maraithon/lib/maraithon/operator_memory.ex)
- [`lib/maraithon/tools.ex`](/Users/kent/bliss/maraithon/lib/maraithon/tools.ex)
- [`lib/maraithon/runtime.ex`](/Users/kent/bliss/maraithon/lib/maraithon/runtime.ex)
- [`lib/maraithon/agent_builder.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex)
- [`test/maraithon/telegram_router_test.exs`](/Users/kent/bliss/maraithon/test/maraithon/telegram_router_test.exs)

### 2.2 What Already Works

| Capability | Current state |
|---|---|
| Telegram chat linking | Implemented through `/start` or `/link` style flows in `InsightNotifications` |
| General DM persistence | Implemented via `TelegramConversations.start_or_continue/3` and `append_turn/2` |
| Reply-thread linking | Implemented through `reply_to_message_id`, conversation turns, and Telegram delivery lookup |
| Preference memory | Implemented through `PreferenceMemory`, with confirmation handling in `TelegramRouter` |
| Insight explanation | Implemented through `TelegramRouter.explain_insight/3` using `Maraithon.Insights.Detail` |
| Limited action execution | Implemented for narrow insight actions and some write actions via `InsightNotifications.Actions` |
| Telegram-native tests | There is meaningful integration coverage using [`capturing_telegram.ex`](/Users/kent/bliss/maraithon/test/support/capturing_telegram.ex) |

### 2.3 Current Architectural Limitations

The existing Telegram stack is still constrained in several important ways:

1. `TelegramInterpreter` is a one-shot JSON classifier, not a multi-step assistant run with tools.
2. The LLM interface currently reduces OpenAI Responses and Anthropic results down to plain text via `complete/1`; it does not expose a structured tool-calling loop.
3. Tool access is not mediated by a Telegram-specific policy surface. The global tool registry includes local file and generic HTTP tools that should not be exposed to Telegram chat.
4. Agent access is incomplete. `Runtime.send_message/3` exists, but there is no synchronous request/response broker for Telegram chat and no conversational CRUD contract over `AgentBuilder`.
5. Proactive Telegram content is fragmented across direct senders such as `InsightNotifications` and `Briefs`, rather than going through one arbitration layer.
6. Pending confirmations are represented too loosely for a broad action surface. The current conversation metadata contract is sufficient for inferred memory rules, but not for full chat-side action execution.

### 2.4 Core Gap

Maraithon already has the pieces for:

- durable Telegram turns
- long-lived preference memory
- operator memory summaries
- connected-account tools
- running agents with inspectable state

What it lacks is the service layer that turns those pieces into one coherent assistant and one coherent push channel.

## 3. Scope and System Boundary

### 3.1 In Scope for v1

- single-user Telegram DM chat
- tool-using contextual chat over connected systems
- agent inspection and lifecycle control from Telegram
- conversational create/update flows for agents using the existing builder contract
- proactive Telegram messages routed from insights, briefs, and agent-originated push candidates
- confirmation-gated external writes and destructive actions
- durable auditing of assistant runs, tool calls, prepared actions, and push decisions

### 3.2 Out of Scope for v1

- Telegram group chats or channel participation
- voice notes, audio replies, or image understanding
- public-facing chatbot features
- arbitrary remote web browsing beyond explicit connected-account tools
- exposing repo/filesystem tools like `read_file`, `file_tree`, `search_files`, or `http_get` through Telegram

### 3.3 Assistant Identity Boundary

The Telegram chat assistant is a system-owned orchestration service, not a user-created runtime agent entry in [`agents`](/Users/kent/bliss/maraithon/lib/maraithon/agents.ex).

That means:

- it is not created through `/agents/new`
- it is not listed in `/agents`
- it may inspect and control user agents
- it may delegate to user agents, but it remains the outer orchestrator and policy owner

## 4. UX and Interaction Model

### 4.1 Conversation Modes

The Telegram chat surface supports three user-visible modes:

| Mode | Trigger | Expected behavior |
|---|---|---|
| Freeform operator chat | User starts a DM or sends a new message | Assistant answers using memory, open work, tools, and agent context |
| Reply-thread interaction | User replies to a pushed item or prior assistant message | Assistant preserves thread context, explains, redrafts, executes, or learns from the reply |
| Proactive assistant push | System chooses to interrupt | Assistant sends the best content from insights, briefs, or running agents through one coherent outbox |

### 4.2 Core User Behaviors

The operator can say things like:

- "What do I owe today?"
- "What did the followthrough agent find?"
- "Stop Kent's Gmail agent."
- "Start the roadmap planner again."
- "Create a new GitHub planner for acme/widgets."
- "Reply to this and say I'll send the numbers Friday."
- "These receipt emails are noise."
- "Why did you send this?"

### 4.3 Message Semantics

Assistant replies fall into these message classes:

| Message class | Meaning |
|---|---|
| `assistant_reply` | Normal conversational response |
| `assistant_push` | Proactive content initiated by Maraithon |
| `approval_prompt` | Confirmation required before execution |
| `action_result` | Completed action or failure notice |
| `system_notice` | Linking, reauth, cooldown, or safety explanation |

### 4.4 Confirmation UX

For actions that require approval, the assistant must send:

- a short explanation of what it wants to do
- the exact target
- the exact write or mutation that will happen
- inline buttons when possible
- a text fallback such as `yes`, `confirm`, `no`, or `cancel`

The approval object must be durable, not implied by loose turn order.

## 5. Functional Requirements

### 5.1 Unified Context Assembly

Every inbound Telegram run must start from a normalized context snapshot containing:

- current linked user identity
- recent turns from the active Telegram conversation
- active preference rules from `PreferenceMemory`
- operator summaries from `OperatorMemory`
- open insights for the user
- connected-account snapshot with provider/service availability
- active agents and recent agent health state

This initial snapshot should be compact, not exhaustive. Raw source data is fetched on demand through tools.

### 5.2 Tool-Using Chat

The assistant must be able to retrieve additional context during a run using curated Telegram-safe tools.

The Telegram model surface must expose semantic tools, not raw registry internals. Telegram should not directly expose the full contents of [`Maraithon.Tools`](/Users/kent/bliss/maraithon/lib/maraithon/tools.ex).

Required read tool categories:

- Gmail search and message retrieval
- Calendar event listing
- Slack search and thread/context lookup
- Linear issue lookup and status inspection
- Notaui task lookup
- active agent listing and inspection
- open insight and delivery inspection

### 5.3 Agent Access

The unified assistant must be able to:

- list agents for the linked user
- inspect agent status, budgets, spend, logs, events, effect queue, and scheduled jobs
- start, stop, restart, and delete agents
- send a message to a running agent
- ask a running agent a question and wait for a bounded response window when the behavior supports it
- create or update agents through the `AgentBuilder` validation surface

### 5.4 Conversational Agent CRUD

Conversational create/edit flows must reuse the same launch contract as the web builder:

- `AgentBuilder.default_launch_params/0`
- `AgentBuilder.launch_params_for_behavior/1`
- `AgentBuilder.build_start_params/2`
- `AgentBuilder.launch_params_from_agent/1`

Telegram should not invent a second incompatible schema for agent definitions.

### 5.5 Proactive Push Behavior

The assistant may proactively send:

- insight alerts
- chief-of-staff or planner briefs
- follow-up questions when a high-confidence decision is blocked
- agent-originated status updates or escalations
- digest summaries when multiple lower-urgency items should be merged

Pushes must be arbitrated by one broker that applies:

- interruption policy
- quiet hours
- per-user rate limits
- dedupe
- recent conversation state
- active preference rules

### 5.6 Action Execution Policy

Action safety is class-based:

| Action class | Examples | v1 policy |
|---|---|---|
| Read-only | explain insight, inspect agent, list Gmail items, search Slack | no confirmation |
| Local state mutation | start agent, stop agent, restart agent, snooze item | execute immediately if target resolution is explicit and confidence is high; otherwise confirm |
| Destructive local mutation | delete agent, overwrite agent config | explicit confirmation required |
| External writes | send Gmail, post Slack message, create Linear issue, complete Notaui task | explicit confirmation required |
| Memory writes | save inferred durable rule | auto-save only at high confidence under policy; otherwise ask for confirmation |

### 5.7 Confirmation Requirements

Explicit confirmation is always required for:

- deleting an agent
- creating an agent
- editing agent subscriptions, tools, prompt, budgets, or runtime-critical config
- sending external messages
- creating or mutating third-party tasks/issues/comments
- disconnecting or changing account-linked behavior

### 5.8 Backward-Compatible Commands

The following command-style behaviors must continue to work:

- `/start`
- `/link`
- `/preferences`
- `/prefs`
- `/memory`
- `/prefer`
- `/forget`

Freeform chat becomes the primary interaction model, but commands remain valid shortcuts.

## 6. Data and Domain Model

### 6.1 Extend Existing Telegram Conversation Records

`telegram_conversations` stays the durable conversation root. No replacement table is needed.

Existing top-level fields remain valid:

- `user_id`
- `chat_id`
- `root_message_id`
- `linked_delivery_id`
- `linked_insight_id`
- `status`
- `summary`
- `last_intent`
- `last_turn_at`
- `metadata`

The normalized `metadata` contract must grow to support:

| Key | Type | Meaning |
|---|---|---|
| `mode` | enum | `general`, `linked`, `assistant`, `push_thread` |
| `active_run_id` | UUID nullable | current assistant run |
| `pending_clarification` | map nullable | active clarification prompt state |
| `latest_prepared_action_id` | UUID nullable | latest durable action awaiting decision |
| `last_push_origin` | map nullable | most recent proactive send source |

### 6.2 Extend Conversation Turns

`telegram_conversation_turns` must be extended with:

| Field | Type | Meaning |
|---|---|---|
| `turn_kind` | enum | `user_message`, `assistant_reply`, `assistant_push`, `approval_prompt`, `action_result`, `system_notice` |
| `origin_type` | enum nullable | `chat`, `insight`, `brief`, `agent_push`, `prepared_action`, `system` |
| `origin_id` | string nullable | id for the originating record |

The existing `structured_data` column remains the place for model output, render metadata, and tool/use context.

### 6.3 New `telegram_assistant_runs`

This table records one bounded orchestration cycle.

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | run id |
| `user_id` | string | linked user |
| `chat_id` | string | Telegram chat |
| `conversation_id` | UUID nullable | linked conversation |
| `trigger_type` | enum | `inbound_message`, `reply`, `agent_push`, `brief`, `insight_push`, `follow_up`, `scheduled_digest` |
| `status` | enum | `running`, `waiting_confirmation`, `completed`, `failed`, `cancelled`, `degraded` |
| `model_provider` | string | `openai`, etc. |
| `model_name` | string | concrete model |
| `prompt_snapshot` | map | summarized initial context |
| `result_summary` | map | top-level result |
| `started_at` | utc datetime | run start |
| `finished_at` | utc datetime nullable | run end |
| `error` | string nullable | failure summary |

### 6.4 New `telegram_assistant_steps`

This table records tool calls and execution detail within a run.

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | step id |
| `run_id` | UUID | parent run |
| `sequence` | integer | execution order |
| `step_type` | enum | `llm_request`, `llm_response`, `context_fetch`, `tool_call`, `agent_query`, `prepared_action`, `telegram_send`, `telegram_edit`, `push_decision` |
| `status` | enum | `running`, `completed`, `failed`, `skipped` |
| `request_payload` | map | normalized input |
| `response_payload` | map | normalized output |
| `error` | string nullable | failure reason |
| `started_at` | utc datetime | step start |
| `finished_at` | utc datetime nullable | step end |

### 6.5 New `telegram_prepared_actions`

Broad Telegram action control requires durable confirmation records.

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | prepared action id |
| `user_id` | string | linked user |
| `chat_id` | string | Telegram chat |
| `conversation_id` | UUID nullable | source conversation |
| `run_id` | UUID | source assistant run |
| `action_type` | enum | action category such as `gmail_send`, `agent_stop`, `agent_create`, `linear_create_issue` |
| `target_type` | enum | `agent`, `gmail_thread`, `slack_channel`, `linear_issue`, `task`, etc. |
| `target_id` | string nullable | concrete target |
| `payload` | map | executable normalized args |
| `preview_text` | string | human-visible confirmation text |
| `status` | enum | `awaiting_confirmation`, `confirmed`, `executed`, `rejected`, `expired`, `failed` |
| `expires_at` | utc datetime | confirmation deadline |
| `confirmed_at` | utc datetime nullable | operator confirmed |
| `executed_at` | utc datetime nullable | action executed |
| `error` | string nullable | failure reason |

### 6.6 New `telegram_push_receipts`

This table prevents spam and supports broker dedupe.

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | receipt id |
| `user_id` | string | linked user |
| `dedupe_key` | string | source fingerprint |
| `origin_type` | enum | `insight`, `brief`, `agent_push`, `assistant_digest` |
| `origin_id` | string nullable | source record id |
| `decision` | enum | `sent_now`, `queued_digest`, `suppressed`, `merged` |
| `conversation_turn_id` | UUID nullable | sent turn |
| `inserted_at` | utc datetime | decision time |

## 7. Backend and Service Design

### 7.1 `Maraithon.TelegramRouter`

`TelegramRouter` remains the webhook-facing orchestration entrypoint, but it should become thin.

It should own:

- Telegram identity resolution
- reply-to and delivery linking
- conversation lookup/creation
- command passthrough for legacy commands
- callback query routing
- delegation into the assistant runner

It should stop owning deep semantic interpretation directly.

### 7.2 New `Maraithon.TelegramAssistant`

Add a new service module, likely split into:

- `Maraithon.TelegramAssistant`
- `Maraithon.TelegramAssistant.Runner`
- `Maraithon.TelegramAssistant.Context`
- `Maraithon.TelegramAssistant.Toolbox`
- `Maraithon.TelegramAssistant.PushBroker`

Responsibilities:

- assemble compact initial context
- execute the model/tool loop
- create prepared actions
- send replies
- persist run/step audit data
- arbitrate proactive pushes

### 7.3 Replace One-Shot Interpretation With Multi-Step Runs

The current `TelegramInterpreter.interpret/3` flow should no longer be the primary path for full chat.

`TelegramInterpreter` may remain as:

- a degraded fallback when the full assistant is disabled
- a compatibility layer for old tests during rollout

But the main path must become a bounded assistant run with tool access.

### 7.4 LLM Provider Contract

The current LLM abstraction only exposes `complete/1`, which is insufficient for tool-oriented chat orchestration.

Required change:

- extend the provider abstraction with a Telegram-assistant-capable interface
- or introduce a Telegram-specific OpenAI Responses client wrapper that supports tool calls and response continuation

V1 assumption:

- full Telegram operator chat requires OpenAI Responses API support
- Anthropic remains acceptable for existing agents, but not as the full Telegram assistant backend unless tool-call parity is added later

### 7.5 Telegram-Safe Tool Surface

The Telegram assistant must use a curated tool surface, not the raw global registry.

Required Telegram-visible tools:

| Tool | Backing surface | Purpose |
|---|---|---|
| `get_open_work_summary` | insights + memory | summarize what the user owes |
| `gmail_search_messages` | Gmail tools | find relevant Gmail threads |
| `gmail_get_message` | Gmail tools | inspect one Gmail message |
| `calendar_list_events` | Calendar tools | inspect relevant events |
| `slack_search_messages` | Slack tools | search Slack context |
| `slack_get_thread_context` | Slack tools | inspect one thread |
| `linear_list_or_lookup` | Linear connectors/tools | inspect issue state |
| `notaui_list_tasks` | Notaui tools | inspect tasks |
| `list_agents` | `Agents.list_agents/1` | list active or stopped agents |
| `inspect_agent` | `Runtime`, `Admin`, `Agents` | inspect state, logs, spend, queues |
| `prepare_agent_action` | runtime/agent builder | stage create/update/control actions |
| `prepare_external_action` | existing write tools | stage sends/posts/issue updates |
| `query_agent` | runtime request/response broker | ask a running agent a question |

The Telegram assistant must not receive:

- `read_file`
- `list_files`
- `file_tree`
- `search_files`
- `http_get`

unless a future admin-only feature explicitly adds them.

### 7.6 User Context Injection

Telegram-visible tools must not trust the model to supply arbitrary `user_id`.

The execution layer must inject:

- linked `user_id`
- allowed provider/account scope
- allowed team/account defaults where resolvable

The model may choose target entities, but not ownership.

### 7.7 Agent Query Contract

Add a bounded request/response path for agents.

Suggested interface:

`Runtime.request_response(agent_id, message, metadata, opts)`

Behavior:

- send a correlated direct message to a running agent
- wait up to a bounded timeout for an `agent_response` or `agent_error`
- if a response arrives in time, use it in the Telegram run
- if not, return an accepted/queued result and tell the user the request was handed off

### 7.8 Conversational Agent Create/Update

For create and update flows:

- the assistant collects missing fields conversationally
- it validates against `AgentBuilder`
- it creates a `telegram_prepared_action`
- execution occurs only after explicit confirmation when the action is mutating or potentially expensive

### 7.9 Push Broker Migration

The following direct Telegram senders must move behind one broker:

- insight notification sends in `InsightNotifications`
- brief dispatches in `Briefs`
- new agent-originated push candidates

This is required so Telegram becomes one coherent product rather than three separate senders that happen to use the same bot token.

## 8. Run Loop and Control Flow

### 8.1 Inbound Message Run

Reference algorithm:

```text
1. Resolve Telegram chat to user.
2. Continue or create conversation.
3. Persist the inbound user turn.
4. Build compact context snapshot.
5. Start assistant run and persist run record.
6. Call model with context + tool schema.
7. While the model requests tools and step limits are not exceeded:
   a. validate tool call against Telegram policy
   b. execute tool with injected user scope
   c. persist run step
   d. continue the model
8. If the result is read-only:
   send assistant reply and persist assistant turn.
9. If the result is a mutating action:
   create prepared action, send approval prompt, persist approval turn.
10. If the result is a proactive follow-up or digest decision:
    send or queue through the push broker.
11. Mark run completed, waiting_confirmation, degraded, or failed.
```

### 8.2 Proactive Push Run

Reference algorithm:

```text
1. Receive a push candidate from an insight, brief, or agent.
2. Normalize it into one broker contract.
3. Fetch interruption context:
   recent turns, active conversation, quiet-hours rules, push receipts, active agents, open work.
4. Decide:
   send_now | queue_digest | merge_into_current_thread | suppress
5. Persist push decision.
6. If sending:
   a. create or continue a push-thread conversation when appropriate
   b. send Telegram message
   c. append assistant_push turn
```

### 8.3 Limits

Default v1 run limits:

- max 6 model turns per inbound run
- max 10 tool/agent steps per run
- max 60 seconds wall-clock per run
- max 20 inbound freeform user turns per 5-minute window per chat
- max 3 immediate proactive pushes per hour per user unless the item is explicitly high urgency

## 9. Push Arbitration and Agent Integration

### 9.1 Push Candidate Contract

Every proactive source must normalize into:

| Field | Meaning |
|---|---|
| `origin_type` | `insight`, `brief`, `agent_push`, `assistant_digest` |
| `origin_id` | source record id |
| `agent_id` | originating agent when present |
| `title` | short push title |
| `body` | push body |
| `urgency` | normalized 0..1 |
| `interrupt_now` | explicit interrupt recommendation |
| `why_now` | short explanation |
| `dedupe_key` | stable fingerprint |
| `suggested_actions` | optional quick actions |

### 9.2 Sources

The broker must support these sources in v1:

- existing `Insight` notifications
- existing briefs
- agent-originated push candidates emitted by behaviors
- assistant-generated digest messages summarizing queued lower-urgency items

### 9.3 Assistant Presentation

All pushes appear as coming from Maraithon, but each push should identify its source:

- source agent name when relevant
- source system when relevant
- why the assistant chose to interrupt now

## 10. Failure Modes, Edge Cases, and Backward Compatibility

### 10.1 Required Failure Behavior

| Failure | Required behavior |
|---|---|
| Telegram chat not linked | only linking/help flows work |
| Connected account missing | assistant explains what is not connected |
| Connected account reauth required | assistant returns reconnect guidance; no silent failure |
| Tool call fails | assistant summarizes the failure and offers a fallback |
| Agent not running | assistant offers to start it if appropriate |
| Agent target ambiguous | assistant asks which agent the user means |
| Prepared action expires | assistant requires a fresh confirmation |
| OpenAI assistant backend unavailable | assistant degrades to legacy reply/help behavior and does not attempt broad execution |
| Telegram send/edit failure | run is marked degraded and the failure is logged with run id |

### 10.2 Backward Compatibility

The implementation must preserve:

- existing `/start` chat linking
- existing memory commands
- existing inline callback actions for insights
- existing conversation and turn records
- existing insight explanation behavior, now routed through the unified assistant path

### 10.3 Safety Rules

- No cross-user access is allowed.
- The assistant cannot escape the linked user's provider scope.
- No raw secrets or OAuth tokens enter model prompts.
- External writes and destructive actions require durable confirmation.
- Telegram cannot become a raw shell or filesystem interface in v1.

## 11. Observability and Instrumentation

### 11.1 Telemetry Events

Required events:

| Event | Measurements | Metadata |
|---|---|---|
| `[:maraithon, :telegram, :assistant, :run, :start]` | none | run_id, trigger_type, user_id, conversation_id |
| `[:maraithon, :telegram, :assistant, :run, :stop]` | duration_ms, tool_steps, llm_turns | run_id, status, model_provider, model_name |
| `[:maraithon, :telegram, :assistant, :step]` | duration_ms | run_id, step_type, status |
| `[:maraithon, :telegram, :assistant, :prepared_action]` | none | action_type, target_type, status |
| `[:maraithon, :telegram, :push, :decision]` | none | origin_type, decision, urgency_bucket |
| `[:maraithon, :telegram, :agent, :delegation]` | duration_ms | agent_id, result_status |

### 11.2 Structured Logging

Every assistant run must log:

- run id
- user id
- chat id
- conversation id
- trigger type
- final status
- failure class when relevant

### 11.3 Operator Debugging

The system must make it possible to answer:

- why the assistant sent a proactive Telegram message
- what tools it used
- what agent it queried
- which confirmation object was executed
- why an action failed or was suppressed

## 12. Rollout and Migration Plan

### 12.1 Phase 1: Foundations

- add new schemas and migrations
- extend Telegram turn records
- add assistant run/step persistence
- add prepared action persistence
- add push receipt persistence

### 12.2 Phase 2: Read-Only Assistant

- build the new assistant run loop
- enable read-only contextual chat with connected-account tools
- keep existing `TelegramRouter` reply flows working

### 12.3 Phase 3: Confirmation-Gated Writes

- add prepared action creation
- enable external write previews and confirmations
- enable destructive/local mutating agent actions with confirmation policy

### 12.4 Phase 4: Agent Control and Delegation

- add agent inspect/list/control tools
- add bounded `Runtime.request_response/4`
- enable conversational create/update flows through `AgentBuilder`

### 12.5 Phase 5: Unified Push Broker

- reroute insights and briefs through the new push broker
- enable agent-originated push candidates
- turn on digest/suppression/merge policy

### 12.6 Feature Flags

Recommended flags:

- `telegram_full_chat_enabled`
- `telegram_assistant_write_tools_enabled`
- `telegram_agent_control_enabled`
- `telegram_unified_push_enabled`

## 13. Test Plan and Validation Matrix

### 13.1 Test Surfaces

Primary test artifacts:

- [`test/maraithon/telegram_router_test.exs`](/Users/kent/bliss/maraithon/test/maraithon/telegram_router_test.exs)
- [`test/support/capturing_telegram.ex`](/Users/kent/bliss/maraithon/test/support/capturing_telegram.ex)
- new assistant run/step tests
- new prepared action tests
- new push broker tests

### 13.2 Required Scenarios

| Scenario | Expected result |
|---|---|
| User asks "What do I owe today?" with Gmail, Calendar, and Slack connected | assistant uses compact memory + tools and returns a synthesized answer |
| User replies "Why did you send this?" to a linked insight | assistant explains using the shared detail contract |
| User says "Stop Kent's Gmail agent" | assistant resolves the target and performs or confirms the stop per policy |
| User asks for a new planner agent | assistant collects required fields, validates with `AgentBuilder`, and creates a prepared action |
| User asks a running agent a domain question | assistant delegates via bounded request/response and returns inline or queued status |
| Agent emits a high-urgency push candidate | push broker sends immediately and records a receipt |
| Multiple low-urgency pushes arrive | broker dedupes or queues them into a digest |
| Gmail send is requested | assistant drafts a prepared action and requires confirmation before sending |
| Connected account reauth is required | assistant returns reconnect guidance instead of failing silently |
| Freeform chat rate limit exceeded | assistant returns a rate-limit notice without losing conversation integrity |

### 13.3 Validation Gates

- [ ] Telegram chat uses the new assistant run loop, not only the old JSON interpreter.
- [ ] Read-only connected-account retrieval works for all linked providers in scope.
- [ ] Agent list/inspect/control flows work from Telegram.
- [ ] Prepared-action confirmations are durable and survive retries.
- [ ] Insights and briefs can route through the unified push broker.
- [ ] Push dedupe and quiet-hours policy are enforced.
- [ ] Existing callback-based insight actions still work.
- [ ] Existing preference commands still work.

## 14. Definition of Done

- [ ] A linked user can have a general Telegram conversation with Maraithon and get context-aware answers.
- [ ] The assistant can inspect connected-account context through curated tools.
- [ ] The assistant can inspect and control the user's agents from Telegram.
- [ ] The assistant can prepare and confirm external writes and destructive actions safely.
- [ ] Running agents can push useful content into the same Telegram relationship through one broker.
- [ ] Assistant runs, steps, prepared actions, and push decisions are persisted and observable.
- [ ] `mix precommit` passes with new Telegram assistant and push broker coverage.

## 15. Open Questions and Assumptions

- Assumption: full Telegram operator chat in v1 is built on OpenAI Responses API because the current OpenAI provider already targets that endpoint and is the practical path to tool-calling support.
- Assumption: Telegram-visible tools are a curated semantic wrapper layer, not the raw global tool registry.
- Assumption: the unified Telegram assistant is system-owned and not represented as a user-managed runtime agent record.
- Assumption: single-user DM is the only supported Telegram chat surface in v1, even if the connected Telegram bot later joins groups.
