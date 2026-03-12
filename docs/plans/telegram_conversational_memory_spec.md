# Telegram Conversational Memory Specification

A memory-first Telegram interaction system for Maraithon that lets operators reply to suggestions, chat freely with the bot, trigger actions in natural language, and continuously improve future model behavior through durable long-running memory rather than brittle heuristics.

---

## Table of Contents

1. [Overview and Goals](#1-overview-and-goals)
2. [Product Contract](#2-product-contract)
3. [Conversation Ingestion and Routing](#3-conversation-ingestion-and-routing)
4. [Interpretation Engine](#4-interpretation-engine)
5. [Memory Model](#5-memory-model)
6. [Rule Learning and Confirmation](#6-rule-learning-and-confirmation)
7. [Action Execution from Telegram](#7-action-execution-from-telegram)
8. [Prompt Memory Assembly](#8-prompt-memory-assembly)
9. [Safety and Guardrails](#9-safety-and-guardrails)
10. [State Machines](#10-state-machines)
11. [Validation and Testing](#11-validation-and-testing)
12. [Definition of Done](#12-definition-of-done)

---

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon already sends Telegram notifications and supports inline button feedback, but the interaction surface is still too shallow. Operators need to be able to:

- reply directly to a Maraithon Telegram message
- send freeform messages to Maraithon in Telegram without needing a linked suggestion
- ask questions like “why did you send this?”
- give feedback like “these receipt emails are noise”
- issue action requests like “send that now but shorter”
- have the system learn from those interactions over time

The system must not depend on brittle heuristics. It should get smarter as models improve by storing durable memory and feeding that memory back into future model calls.

### 1.2 Goals

- Support general Telegram chat, not just button clicks.
- Resolve replies to the correct suggestion, insight, or action draft when possible.
- Learn durable user preferences from Telegram conversation.
- Distinguish one-off feedback from durable policy.
- Allow freeform action requests in Telegram.
- Ask clarifying questions when meaning is ambiguous.
- Auto-save inferred rules when confidence is high.
- Require confirmation when confidence is moderate.
- Improve future insight selection, drafting, interruption timing, and action choice using learned memory.
- Keep deterministic code focused on safety, routing, identity, and execution.

### 1.3 Non-Goals

- Full autonomous execution of destructive actions without approval.
- Heuristic intent classification via regex trees.
- Replacing existing inline callback actions; this feature extends them.
- Building a general-purpose consumer chatbot unrelated to Maraithon workflows.

### 1.4 Design Principles

**Memory-first, not heuristic-first.**  
We store raw interaction evidence, structured interpretations, and outcomes so future models can reason better over the same substrate.

**Model-owned semantics.**  
The model infers meaning, intent, generalization, ambiguity, and confidence.

**System-owned safety.**  
The app owns auth, linking, execution permissions, connector validity, confidence gating, and persistence.

**Durable evidence.**  
Every meaningful Telegram exchange should leave behind durable conversational and learning artifacts.

**Compounding intelligence.**  
As OpenAI models improve, the same stored memory should yield better inference, better filtering, and better actions without rewriting product logic.

---

## 2. Product Contract

### 2.1 Supported User Behaviors

The operator may:

- reply to a Maraithon Telegram suggestion
- reply to a Maraithon draft/action message
- start a new DM with Maraithon
- ask follow-up questions
- provide corrective feedback
- provide general feedback
- ask Maraithon to remember a rule
- ask Maraithon to act now
- ask Maraithon to redraft or change tone
- reject or confirm a proposed learned rule

### 2.2 Examples

**Reply to a suggestion**
- “This is noisy, receipts like this should usually be ignored.”

**Freeform DM**
- “What do I owe today?”

**Action request**
- “Reply to this and say I’ll send it Friday.”

**Clarification**
- “Why did you think this mattered?”

**Memory confirmation**
- “Yes, remember that.”
- “No, just for this one.”

### 2.3 Desired Product Behavior

| User Input Type | Expected Behavior |
|---|---|
| Specific feedback on a suggestion | Learn thread-local correction, maybe infer a durable rule |
| General policy statement | Infer and save or propose a durable rule |
| Ambiguous correction | Ask a follow-up question |
| Freeform action request | Draft or execute depending on safety |
| Question about an insight | Explain reasoning and evidence |
| General DM without linked insight | Start a new conversation and answer using memory |

---

## 3. Conversation Ingestion and Routing

### 3.1 Sources

Telegram events already arrive through:
- [webhook_controller.ex](/Users/kent/bliss/maraithon/lib/maraithon_web/controllers/webhook_controller.ex)
- [telegram.ex](/Users/kent/bliss/maraithon/lib/maraithon/connectors/telegram.ex)
- [insight_notifications.ex](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex)

This feature extends `handle_telegram_event/1` beyond:
- `/start`
- `/link`
- `/prefer`
- callback queries

### 3.2 Incoming Event Types

Supported Telegram update types for this feature:

- `message`
- `edited_message`
- `callback_query`

### 3.3 Routing Rules

Incoming message routing:

1. Resolve Telegram chat to Maraithon user.
2. If unresolved:
   - allow link/connect flow only
   - ignore learning/action behavior
3. If resolved:
   - inspect `reply_to_message_id`
   - look up matching prior Telegram delivery or conversation turn
   - determine whether this is:
     - reply to insight notification
     - reply to action draft
     - reply to rule confirmation
     - general DM

### 3.4 Deterministic Linking

The system must link a Telegram message using deterministic identifiers, not inference.

Resolution order:
1. Existing `telegram_conversation_turns.telegram_message_id`
2. Existing `insight_notifications_deliveries.provider_message_id`
3. Existing action draft metadata
4. Else create a general unlinked conversation

### 3.5 Conversation Creation Rules

Create or continue a `telegram_conversation`:
- continue an open linked conversation if replying in-thread
- continue an open general conversation if recent and same chat
- otherwise create a new conversation

### 3.6 Conversation Expiry

A conversation becomes inactive when:
- explicitly closed
- last activity older than configured threshold
- linked suggestion is resolved and no follow-up pending

Default expiry:
- linked conversation: 7 days
- general DM conversation: 24 hours idle

---

## 4. Interpretation Engine

### 4.1 Purpose

The interpretation engine converts Telegram text plus memory context into structured meaning.

It should not use brittle heuristics for semantic classification.

### 4.2 Inputs

Interpreter input:
- `user_id`
- `chat_id`
- raw Telegram text
- `reply_to_message_id`
- linked `delivery` if any
- linked `insight` if any
- linked `telegram_conversation`
- recent turns from this conversation
- active durable preference rules
- compact long-term memory summary
- optional linked action state

### 4.3 Outputs

Interpreter returns a JSON object:

```json
{
  "intent": "feedback_specific|feedback_general|preference_create|preference_update|preference_reject|action_execute|action_redraft|action_cancel|question_about_insight|clarification_answer|general_chat|unknown",
  "confidence": 0.0,
  "scope": "thread_local|durable|general",
  "needs_clarification": false,
  "clarifying_question": null,
  "assistant_reply": "short reply for Telegram",
  "candidate_rules": [],
  "candidate_action": null,
  "feedback_target": {
    "delivery_id": null,
    "insight_id": null
  },
  "memory_summary_updates": [],
  "explanation": "why this interpretation was chosen"
}
```

### 4.4 Intent Semantics

| Intent | Meaning |
|---|---|
| `feedback_specific` | Feedback about one suggestion/action only |
| `feedback_general` | Feedback that may generalize |
| `preference_create` | New durable preference candidate |
| `preference_update` | Modify an existing rule |
| `preference_reject` | Reject a proposed rule or inference |
| `action_execute` | Execute or proceed with an action |
| `action_redraft` | Rewrite an existing draft |
| `action_cancel` | Cancel pending action |
| `question_about_insight` | Ask why Maraithon surfaced this |
| `clarification_answer` | Answer a prior question from Maraithon |
| `general_chat` | General assistant interaction |
| `unknown` | Low-confidence / no reliable interpretation |

### 4.5 Confidence Policy

| Confidence Band | Behavior |
|---|---|
| `>= 0.90` | auto-apply if safe |
| `0.70 - 0.89` | ask confirmation |
| `< 0.70` | ask clarification or treat as local-only |

### 4.6 Clarification Requirement

The interpreter must set `needs_clarification=true` if:
- the message could map to multiple rules
- the user might mean local-only vs durable
- action target is unclear
- referenced item cannot be linked
- the requested action is underspecified

### 4.7 No-Heuristic Constraint

The interpreter may use deterministic rules only for:
- linking messages to entities
- reading known command prefixes
- checking connector availability
- checking confirmation state
- gating execution

All semantic understanding must be model-driven.

---

## 5. Memory Model

### 5.1 Overview

We need four memory layers:

1. `conversation memory`
2. `durable preference memory`
3. `learning event memory`
4. `summary memory`

### 5.2 Conversation Memory

#### `telegram_conversations`

| Field | Type | Description |
|---|---|---|
| `id` | UUID | conversation id |
| `user_id` | string | owner |
| `chat_id` | string | Telegram chat |
| `root_message_id` | string | first Telegram message in thread |
| `linked_delivery_id` | UUID nullable | linked Telegram delivery |
| `linked_insight_id` | UUID nullable | linked insight |
| `status` | enum | `open`, `awaiting_confirmation`, `closed` |
| `summary` | text | compact rolling summary |
| `last_intent` | string | most recent interpreted intent |
| `last_turn_at` | utc_datetime_usec | activity marker |
| timestamps | | |

#### `telegram_conversation_turns`

| Field | Type | Description |
|---|---|---|
| `id` | UUID | turn id |
| `conversation_id` | UUID | parent conversation |
| `role` | enum | `user`, `assistant`, `system` |
| `telegram_message_id` | string nullable | Telegram id |
| `reply_to_message_id` | string nullable | reply target |
| `text` | text | raw utterance |
| `intent` | string nullable | interpreted intent |
| `confidence` | float nullable | model confidence |
| `structured_data` | map | full interpretation/result |
| timestamps | | |

### 5.3 Durable Preference Memory

#### `insight_preference_rules`

| Field | Type | Description |
|---|---|---|
| `id` | UUID | rule id |
| `user_id` | string | owner |
| `status` | enum | `active`, `pending_confirmation`, `rejected`, `superseded` |
| `source` | enum | `telegram_explicit`, `telegram_inferred`, `feedback_inference`, `web`, `system` |
| `kind` | enum | `content_filter`, `urgency_boost`, `quiet_hours`, `routing_preference`, `action_preference`, `style_preference` |
| `label` | string | display label |
| `instruction` | text | human-readable policy |
| `applies_to` | map/array | sources affected |
| `filters` | map | structured selectors |
| `confidence` | float | inferred confidence |
| `evidence` | map | supporting evidence |
| `confirmed_at` | utc_datetime_usec nullable | confirmation time |
| `last_used_at` | utc_datetime_usec nullable | last applied |
| timestamps | | |

### 5.4 Learning Event Memory

#### `insight_preference_rule_events`

| Field | Type | Description |
|---|---|---|
| `id` | UUID | event id |
| `user_id` | string | owner |
| `rule_id` | UUID nullable | related rule |
| `conversation_id` | UUID nullable | originating conversation |
| `source_turn_id` | UUID nullable | originating turn |
| `source_delivery_id` | UUID nullable | linked delivery |
| `event_type` | enum | `proposed`, `auto_saved`, `confirmed`, `rejected`, `updated`, `applied`, `reverted` |
| `payload` | map | event details |
| timestamps | | |

### 5.5 Summary Memory

#### `operator_memory_summaries`

| Field | Type | Description |
|---|---|---|
| `id` | UUID | summary id |
| `user_id` | string | owner |
| `summary_type` | enum | `telegram_behavior`, `content_preferences`, `action_style`, `interrupt_policy` |
| `content` | text | compact model-facing summary |
| `source_window_start` | utc_datetime_usec | source range |
| `source_window_end` | utc_datetime_usec | source range |
| `confidence` | float | quality/confidence |
| timestamps | | |

### 5.6 Read Model

Keep [preference_memory.ex](/Users/kent/bliss/maraithon/lib/maraithon/preference_memory.ex) as the canonical read/query interface.

It should be extended to read from:
- `insight_preference_rules`
- `operator_memory_summaries`

The old `Profile.rules` blob can be retained temporarily as a compatibility summary or phased out later.

---

## 6. Rule Learning and Confirmation

### 6.1 Learning Sources

Rules may be learned from:
- freeform Telegram chat
- replies to suggestion messages
- replies to action drafts
- callback feedback
- explicit `/prefer` commands

### 6.2 Rule Lifecycle

```text
proposed -> pending_confirmation -> active
proposed -> active
proposed -> rejected
active -> updated
active -> superseded
```

### 6.3 Autosave Policy

Auto-save if all are true:
- confidence >= autosave threshold
- meaning is durable, not item-specific
- no ambiguity about scope
- no conflict with stronger existing rule
- no destructive behavior implied

### 6.4 Confirmation Policy

Ask confirmation when:
- confidence is moderate
- inferred rule is broad
- rule overlaps an existing active rule
- the user may mean “just this case”
- the inferred action-style preference is novel

### 6.5 Clarification Policy

Ask clarifying question when:
- message has multiple plausible meanings
- action target is unclear
- preference target is unclear
- user says “this is wrong” with no clear generalization
- referenced object cannot be resolved

### 6.6 Example Rule Candidates

```json
{
  "kind": "content_filter",
  "label": "Ignore routine receipts",
  "instruction": "Downrank routine transactional receipt emails unless they imply follow-up work.",
  "applies_to": ["gmail", "telegram"],
  "filters": {
    "topics": ["receipts", "transactional_receipts"]
  },
  "confidence": 0.91
}
```

```json
{
  "kind": "urgency_boost",
  "label": "Investors are urgent",
  "instruction": "Treat investor communications as high urgency for surfacing and interruption.",
  "applies_to": ["gmail", "calendar", "slack", "telegram"],
  "filters": {
    "topics": ["investor", "fundraising", "board"]
  },
  "confidence": 0.94
}
```

### 6.7 Rule Conflict Resolution

When a new rule conflicts:
1. prefer explicit over inferred
2. prefer confirmed over auto-saved
3. prefer newer when same trust level
4. log supersession event
5. include conflict note in model context

---

## 7. Action Execution from Telegram

### 7.1 Supported Freeform Actions

- send draft now
- rewrite draft
- shorten / sharpen / soften reply
- create task
- mark done
- snooze
- dismiss
- explain recommendation

### 7.2 Action Resolution

Freeform action requests should resolve against:
- linked delivery
- linked insight
- linked pending action draft
- recent conversation state

### 7.3 Execution Policy

| Action Class | Behavior |
|---|---|
| local / safe | execute directly |
| externally visible but high-confidence | draft then confirm |
| ambiguous | ask follow-up |
| unsupported | explain limitation |

### 7.4 Existing Reuse

This feature should reuse:
- [insight_notifications/actions.ex](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications/actions.ex)
- existing Gmail/Slack action paths
- existing Telegram message edit/send behavior

### 7.5 Action Memory

When a user says:
- “make it firmer”
- “shorter”
- “less apologetic”

That may become a durable `style_preference` if repeated and high-confidence.

---

## 8. Prompt Memory Assembly

### 8.1 Purpose

Each model call needs the right amount of memory, not raw dumps.

### 8.2 Memory Layers for Prompting

For Telegram interpretation:
- recent conversation turns
- linked insight summary if any
- active preference rules
- relevant operator summary memory

For insight generation:
- active preference rules
- accepted/rejected prior patterns
- interruption preferences
- summary memory

For action drafting:
- style preferences
- prior accepted edits
- linked source context
- relevant recent conversation

### 8.3 Prompt Assembly Order

```text
system role
-> user identity / connector context
-> linked insight / action context
-> recent local conversation turns
-> durable active rules
-> compact long-term summary memory
-> current user message
```

### 8.4 Compaction

Conversation memory should be compacted periodically:
- keep full recent turns
- summarize older turns
- preserve exact raw text for audit, but feed summaries into prompts

### 8.5 Summary Generation

Summary memory should be periodically regenerated from:
- accepted rules
- rejected rules
- common corrections
- repeated style preferences
- interruption outcomes

---

## 9. Safety and Guardrails

### 9.1 Deterministic Guardrails

Deterministic code must enforce:
- Telegram chat belongs to a linked user
- reply linkage is valid
- action target exists
- connector token is valid
- action type is permitted
- confirmation is present when required

### 9.2 No Semantic Heuristics

The app must not hardcode content semantics like:
- “if subject contains receipt then ignore”
- “if text contains investor then urgent”

Those are model-inferred and memory-conditioned decisions.

### 9.3 Protected Operations

Protected actions always require confirmation:
- outbound send to external recipients when no existing draft context
- destructive changes
- bulk/multi-target actions
- ambiguous redrafts that alter meaning

### 9.4 Reauth Handling

If an action cannot run due to OAuth issues:
- reply in Telegram with failure reason
- include reconnect link when possible
- keep conversation state open for retry

### 9.5 Abuse / Noise Control

General chat must still be bounded:
- per-user rate limits
- bounded context windows
- maximum clarification depth per thread
- refusal path for unsupported tasks

---

## 10. State Machines

### 10.1 Conversation State Machine

```text
open -> awaiting_confirmation
open -> closed
awaiting_confirmation -> open
awaiting_confirmation -> closed
```

Triggers:
- `open` on initial message
- `awaiting_confirmation` when Maraithon proposes a rule/action and needs approval
- `closed` when issue resolved or idle timeout reached

### 10.2 Rule State Machine

```text
proposed -> active
proposed -> pending_confirmation
pending_confirmation -> active
pending_confirmation -> rejected
active -> updated
active -> superseded
```

### 10.3 Action State Machine

Existing action state should be extended, not replaced:

```text
proposed -> drafted -> awaiting_approval -> approved -> executed
proposed -> canceled
drafted -> redrafted
executed -> closed
failed -> awaiting_reauth
```

---

## 11. Validation and Testing

### 11.1 Test Strategy

We need deep integration-style tests around the Telegram workflow, not just unit tests.

Existing foundations:
- [insight_notification_actions_test.exs](/Users/kent/bliss/maraithon/test/maraithon/insight_notification_actions_test.exs)
- [insight_notification_preferences_test.exs](/Users/kent/bliss/maraithon/test/maraithon/insight_notification_preferences_test.exs)
- [capturing_telegram.ex](/Users/kent/bliss/maraithon/test/support/capturing_telegram.ex)

### 11.2 Test Categories

1. conversation linking
2. general DM routing
3. rule inference
4. confirmation flows
5. clarification flows
6. freeform actions
7. memory application to future insight prompts
8. rejected inference handling
9. reauth failure behavior

### 11.3 Key Validation Rules

| Rule ID | Severity | Description |
|---|---|---|
| `telegram_user_resolved` | ERROR | Telegram message must map to a known user for learning/actions |
| `reply_target_exists` | WARNING | Reply target should map to a known delivery/turn if present |
| `rule_confidence_valid` | ERROR | inferred rule confidence must be between 0 and 1 |
| `rule_kind_valid` | ERROR | inferred rule kind must be recognized |
| `confirmation_required_for_moderate_confidence` | ERROR | moderate-confidence durable rules must not auto-save |
| `protected_action_requires_approval` | ERROR | protected outbound actions cannot execute without approval |
| `conversation_turn_has_role` | ERROR | every turn must have valid role |
| `conversation_summary_compactable` | WARNING | large conversations should have summary refresh support |

### 11.4 Rollout Phases

**Phase 1**
- reply-aware learning
- general chat support
- durable rule proposal/save
- clarification loop

**Phase 2**
- freeform action requests
- redraft and approval loops
- explanation mode

**Phase 3**
- summary memory generation
- richer style/action preferences
- operator memory inspection UI

---

## 12. Definition of Done

### 12.1 Conversation Ingestion

- [ ] Telegram replies to Maraithon messages create or continue linked conversations
- [ ] General Telegram DMs create or continue unlinked conversations
- [ ] Incoming Telegram messages are persisted as conversation turns
- [ ] Linked delivery and linked insight are resolved deterministically when available

### 12.2 Interpretation Engine

- [ ] A model-driven interpreter returns structured JSON intent outputs
- [ ] Interpreter supports the v1 intent set
- [ ] Confidence score is returned for each interpretation
- [ ] Ambiguous inputs produce clarification questions instead of brittle guesses
- [ ] No semantic routing depends on regex/keyword heuristics

### 12.3 Memory Model

- [ ] `telegram_conversations` schema exists
- [ ] `telegram_conversation_turns` schema exists
- [ ] `insight_preference_rules` schema exists
- [ ] `insight_preference_rule_events` schema exists
- [ ] `operator_memory_summaries` schema exists
- [ ] Existing preference read APIs can consume the new durable rule store

### 12.4 Rule Learning

- [ ] High-confidence durable rules auto-save
- [ ] Medium-confidence rules require confirmation
- [ ] Low-confidence or ambiguous cases ask clarifying questions
- [ ] Rule confirmations and rejections are persisted as events
- [ ] Conflicting rules are resolved deterministically

### 12.5 Telegram UX

- [ ] Maraithon replies in the same Telegram chat/thread
- [ ] Maraithon can explain why an insight was surfaced
- [ ] Maraithon can confirm when a rule was learned
- [ ] Maraithon can ask “should I remember this?” when needed
- [ ] Maraithon can gracefully decline unsupported or unsafe actions

### 12.6 Action Handling

- [ ] Freeform action requests can resolve against linked insights/actions
- [ ] Safe actions can execute directly
- [ ] Protected actions require approval
- [ ] Reauth failures surface Telegram reconnect guidance
- [ ] Existing callback-based Telegram actions continue to work

### 12.7 Prompt Memory Feedback Loop

- [ ] Future Telegram interpretations use stored conversation + durable memory
- [ ] Future insight generation uses learned rule memory
- [ ] Future drafts use stored style/action preferences
- [ ] Summary memory can be regenerated from raw history

### 12.8 Testing

- [ ] Reply-to-insight learning test passes
- [ ] General DM conversation test passes
- [ ] Auto-save durable rule test passes
- [ ] Confirmation-required rule test passes
- [ ] Clarification-needed test passes
- [ ] Freeform action request test passes
- [ ] Rejected rule does not become active
- [ ] Prompt memory affects later insight selection test passes
- [ ] `MIX_ENV=test mix precommit` passes

### 12.9 Cross-Feature Parity Matrix

| Test Case | Pass |
|---|---|
| Reply to a Telegram insight and learn a durable rule | [ ] |
| Reply to a Telegram insight and keep correction thread-local only | [ ] |
| Ask Maraithon a general DM question with no linked insight | [ ] |
| Ask Maraithon “why did you send this?” and get explanation | [ ] |
| Say “remember this” and create a durable rule | [ ] |
| Say something ambiguous and get a clarifying question | [ ] |
| Say “send that now” and execute an approved action | [ ] |
| Say “make it shorter” and redraft an existing action | [ ] |
| Reject a proposed rule and prevent activation | [ ] |
| Use learned memory in a later insight-generation prompt | [ ] |
| Use learned style preference in a later draft | [ ] |
| Handle stale OAuth by returning reconnect guidance in Telegram | [ ] |

### 12.10 Integration Smoke Test

End-to-end scenario:

1. Maraithon sends a Telegram suggestion about an email follow-up.
2. Operator replies:  
   `These Stripe receipts are usually noise unless they mention failed payment or reimbursement.`
3. System:
   - links reply to delivery/insight
   - persists conversation turn
   - interprets as likely durable content filter
   - asks confirmation if confidence is moderate, auto-saves if high
4. Rule becomes active.
5. Later Gmail/insight generation prompt includes the new preference memory.
6. Similar receipt-like suggestions are downranked unless follow-up criteria are met.
7. Operator can ask:  
   `why didn't you notify me about that one?`
8. Maraithon explains using active rule memory and current evidence.

---

## Appendix A: Recommended New Modules

| Module | Purpose |
|---|---|
| `Maraithon.TelegramConversations` | conversation CRUD/query API |
| `Maraithon.TelegramConversations.Conversation` | conversation schema |
| `Maraithon.TelegramConversations.Turn` | turn schema |
| `Maraithon.PreferenceMemory.Rule` | durable rule schema |
| `Maraithon.PreferenceMemory.RuleEvent` | rule event schema |
| `Maraithon.OperatorMemory` | summary-memory generation/query |
| `Maraithon.TelegramInterpreter` | model-driven Telegram interpretation |
| `Maraithon.TelegramRouter` | deterministic routing/orchestration |
| `Maraithon.TelegramResponder` | Telegram reply composition/send/edit helpers |

---

## Appendix B: Recommended Prompt Contracts

### Interpreter Prompt Contract

Returns only JSON:

```json
{
  "intent": "feedback_general",
  "confidence": 0.88,
  "scope": "durable",
  "needs_clarification": true,
  "clarifying_question": "Should I remember this as a general rule for future receipt-like emails, or only for this thread?",
  "assistant_reply": "I think you're telling me these are usually noise, but I want to confirm whether that should become a saved rule.",
  "candidate_rules": [],
  "candidate_action": null,
  "feedback_target": {
    "delivery_id": "uuid",
    "insight_id": "uuid"
  },
  "memory_summary_updates": [],
  "explanation": "The operator expressed a likely durable preference but did not clearly indicate whether it should generalize."
}
```

### Memory Summary Prompt Contract

Returns only JSON:

```json
{
  "summary_type": "content_preferences",
  "content": "The operator consistently dislikes routine transactional receipts unless they imply follow-up work, reimbursement, failed payment, or strategic vendor issues.",
  "confidence": 0.93
}
```

---

## Appendix C: Recommended Implementation Order

1. migrations and schemas
2. conversation persistence layer
3. Telegram reply/general-message routing
4. interpreter service
5. rule persistence + confirmation flow
6. prompt memory assembly
7. freeform action routing
8. summary memory generation
9. metrics and operator inspection UI
