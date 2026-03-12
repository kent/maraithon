# Telegram Assistant Liveness Feedback

Status: Draft v1
Purpose: Define native Telegram typing feedback, contextual long-run progress messaging, timeout behavior, and the implementation contract for inbound Telegram assistant runs.
Depends on: [unified-telegram-operator-chat.md](/Users/kent/bliss/maraithon/docs/spectacula/specs/unified-telegram-operator-chat.md)

## 1. Overview and Goals

### 1.1 Problem Statement

The Telegram assistant currently accepts a user message, runs the full assistant loop, and stays visually silent until it has a final reply or a degraded failure.

That behavior feels broken in practice:

- fast runs are acceptable
- medium runs feel like the bot may be dead
- long runs cause users to resend or rephrase the same question
- the assistant looks less capable than it is because there is no sign of life

The request is to make Telegram feel natural and alive:

- use Telegram’s native typing indicator as the default sign of life
- avoid immediate noisy feedback for sub-second replies
- if a run stays active for longer than a few seconds, add a contextual progress note
- if something is wrong and the run crosses a 30-40 second budget, tell the user explicitly

### 1.2 Goals

- Add Telegram-native liveness feedback to inbound assistant questions without changing the assistant’s core reasoning contract.
- Keep quick replies clean by delaying visible feedback briefly.
- Use native `typing` first, then one contextual progress note only for slower runs.
- Prevent silent waits beyond the accepted timeout window.
- Preserve reply threading and conversation persistence without storing transient typing events as normal turns.
- Keep failures in liveness delivery non-fatal to the actual assistant run.

### 1.3 Non-Goals

- Streaming partial assistant answers token by token.
- Replacing the final answer with a chain of progress-only messages.
- Adding group-chat presence behavior.
- Redesigning the assistant model loop or tool surface.
- Changing push notifications, insight delivery UX, or legacy preference-memory-only flows in v1.

### 1.4 Product Decisions From This Request

- Primary sign of life is Telegram’s native typing indicator.
- Typing should feel natural, not instant; use a short 1-2 second grace window.
- If a run is still active after 7 seconds, send a contextual progress note.
- If the run reaches the 30-40 second timeout window, send an explicit failure/update message.

## 2. Current State and Problem

### 2.1 Current Inbound Flow

The current single-user DM path is:

1. [`WebhookController.telegram/2`](/Users/kent/bliss/maraithon/lib/maraithon_web/controllers/webhook_controller.ex#L118) verifies the webhook and synchronously invokes `InsightNotifications.handle_telegram_event/1`.
2. [`InsightNotifications.handle_telegram_event/1`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex#L53) routes message events into [`TelegramRouter.handle_message/1`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_router.ex#L21).
3. `TelegramRouter.handle_message/1` persists the user turn, then calls [`TelegramAssistant.handle_inbound/1`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant.ex#L59).
4. [`TelegramAssistant.Runner.run_inbound/1`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/runner.ex#L16) performs context fetch, the tool loop, and final delivery.
5. The first assistant-visible outbound message is only sent in [`deliver_final_response/5`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/runner.ex#L255) or degraded failure handling.

There is no interim feedback surface anywhere in that flow.

### 2.2 Current Repository Gaps

| Area | Current state | Gap |
|---|---|---|
| Telegram Bot API wrapper | [`Connectors.Telegram`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/telegram.ex) supports `send_message`, `edit_message_text`, and callbacks | No `sendChatAction` support |
| Assistant runtime | `Runner` records steps and final responses | No liveness lifecycle or timeout notice ownership |
| Reply persistence | `TelegramAssistant.send_turn/4` always sends or replies with final text | No contract for editing a progress placeholder into the final reply |
| Tests | [`CapturingTelegram`](/Users/kent/bliss/maraithon/test/support/capturing_telegram.ex) records sends, edits, and callback answers | No capture surface for chat actions |
| Timeout behavior | Runner hard-stops at 60 seconds | Too long for silent user waits; no earlier user-facing timeout notice |

### 2.3 Why The Existing UX Fails

The assistant is already capable of doing multi-step work, including connected-account reads and agent queries. The UX problem is not lack of work; it is lack of visible progress.

For Telegram, silence is interpreted as failure. The current behavior causes:

- duplicate user messages
- unnecessary retries
- reduced trust in longer-running tool calls
- poor perceived responsiveness relative to simpler bots

## 3. Scope and System Boundary

### 3.1 In Scope for v1

- inbound Telegram DM messages that are handled by `TelegramAssistant.handle_inbound/1`
- reply-thread questions that enter the same assistant run loop
- native `typing` presence during slow assistant runs
- one contextual long-run progress note per run
- explicit timeout messaging within the accepted 30-40 second user budget
- final-response reconciliation when a progress note already exists

### 3.2 Out of Scope for v1

- legacy `TelegramInterpreter` fallback runs
- `/start` or `/link` command handling
- preference-memory confirmation flows that do not invoke the assistant run loop
- proactive pushes from insights, briefs, or agent-originated content
- callback-only confirmation actions after an approval prompt

### 3.3 Boundary Rule

This feature changes only the operator-chat execution surface. It does not change:

- how runs choose tools
- the assistant prompt contract
- push broker routing
- permission checks
- database schema ownership

## 4. UX and Interaction Model

### 4.1 Timing Contract

| Phase | Default timing | User-visible behavior |
|---|---|---|
| Grace window | `0-1200ms` | No visible feedback |
| Typing phase | `>=1200ms` until final/timeout | Bot emits native Telegram `typing` and refreshes it periodically |
| Long-run progress | `>=7000ms` | Bot sends one contextual progress note as a reply to the user’s message |
| Timeout notice | `>=35000ms` | Bot edits the progress note into a failure/update message, or sends one if no note exists |
| Hard stop | `>=40000ms` | Run is treated as timed out for user-facing delivery; late final answers are suppressed |

These defaults should be configurable, but the product contract for v1 is:

- do not show typing instantly
- do show typing for medium runs
- do show a concrete contextual note for slow runs
- do not stay silent past the timeout budget

### 4.2 Message Semantics

The UX should feel like one continuous reply, not multiple stacked bot messages.

Rules:

- If the run completes before 7 seconds, use typing only and send one normal final reply.
- If a contextual progress note was sent, the final answer should edit that note in place when possible.
- If the run times out, the timeout notice should reuse the progress message when possible.
- Transient typing events are not persisted as conversation turns.
- The contextual progress note is operational UI, not a durable assistant answer unless it becomes the final edited reply.

### 4.3 Copy Style

The progress note should be short, specific, and non-technical.

Allowed examples:

- `Still working on that.`
- `Still checking Gmail and Calendar.`
- `Still asking your agents.`
- `Still reviewing your open work.`

Disallowed patterns:

- mentioning “LLM”, “tools”, “model”, or internal module names
- exposing raw IDs, provider tokens, or stack traces
- sending multiple distinct progress messages for one run

### 4.4 Timeout Copy

The timeout message should be explicit that something went wrong or took too long.

Default copy contract:

`Something went wrong on my side. I didn’t finish that in time. Try again, or ask for one narrower step.`

If the run has enough context to say more safely, the copy may append a short reason class such as:

- connection issue
- agent response timeout
- provider lookup delay

It must not expose raw exception strings to the user.

## 5. Functional Requirements

### 5.1 Liveness Session Ownership

Every eligible inbound assistant run must start an ephemeral liveness session after the run record is created and before the tool loop begins.

The liveness session owns:

- grace timer
- typing heartbeat timer
- long-run progress timer
- timeout timer
- optional progress message ID
- terminal state

### 5.2 Typing Indicator Rules

- The first `typing` action must not be sent before the grace window expires.
- After the first typing action, it must be refreshed before Telegram clears it.
- Default refresh interval is `4000ms`.
- Typing continues until one of these happens:
  - final response sent or edited
  - timeout notice sent
  - run cancelled or degraded before any user-visible delivery

### 5.3 Contextual Progress Rules

- At 7 seconds, if the run is still active, the system sends one progress note.
- The progress note must reply to the source Telegram message ID when one exists.
- The text is chosen from the latest known progress hint category.
- If no specific hint exists yet, fall back to `Still working on that.`
- v1 sends at most one explicit progress note before finalization.

### 5.4 Hint Derivation Rules

Progress hints are derived from assistant milestones and tool names.

| Hint category | Triggering evidence | Default text |
|---|---|---|
| `thinking` | No completed tool call yet | `Still working on that.` |
| `open_work` | `get_open_work_summary`, `inspect_open_insight` | `Still reviewing your open work.` |
| `connected_accounts` | Gmail, Calendar, Slack, Linear, or Notaui read tools | `Still checking your connected accounts.` |
| `agents` | `list_agents`, `inspect_agent`, `query_agent` | `Still asking your agents.` |
| `actions` | `prepare_agent_action`, `prepare_external_action` | `Still preparing that action.` |

Provider-specific refinement is allowed when safe and obvious:

- `gmail_*` only -> `Still checking Gmail.`
- `calendar_list_events` only -> `Still checking your calendar.`
- `gmail_*` plus `calendar_list_events` -> `Still checking Gmail and Calendar.`

If multiple categories are encountered, the latest materially-specific category wins.

### 5.5 Final Response Reconciliation

When the run completes successfully:

- if no progress note exists, deliver the final response normally
- if a progress note exists, edit that message into the final response
- persist exactly one assistant turn for the final visible answer

The progress note itself should not create a separate durable assistant turn if it is later edited into the final answer.

### 5.6 Timeout Behavior

At `35000ms`, if the run is still active:

- send or edit a timeout notice to the user
- mark the liveness session terminal
- mark the run as timed out for user-facing delivery

At `40000ms`, the runner must not emit a normal final answer for that run even if late work completes afterward.

Late completions may still update internal run audit data, but they must not create a second visible Telegram reply.

### 5.7 Failure Isolation

Failures in liveness delivery must not crash the assistant run.

Examples:

- if `sendChatAction` fails, log and continue
- if the progress note cannot be sent, continue with typing and final reply behavior
- if editing the progress note fails, fall back to sending a fresh final reply

## 6. Data and Domain Model

### 6.1 New Ephemeral Runtime Entity

No database migration is required for v1. The feature adds an in-memory per-run session process.

Recommended runtime entity: `Maraithon.TelegramAssistant.LivenessSession`

| Field | Type | Meaning |
|---|---|---|
| `run_id` | string | Assistant run ID |
| `conversation_id` | string or nil | Telegram conversation ID |
| `chat_id` | string | Telegram chat ID |
| `reply_to_message_id` | string or nil | Source Telegram message being answered |
| `phase` | enum | `pending`, `typing`, `progress_visible`, `timed_out`, `completed`, `cancelled` |
| `progress_message_id` | string or nil | Telegram message ID for the contextual progress note |
| `hint_category` | enum | Latest derived hint category |
| `hint_labels` | list(string) | Optional provider labels like `Gmail`, `Calendar`, `agents` |
| `typing_started_at` | integer monotonic ms or nil | When typing first became visible |
| `timed_out?` | boolean | Whether a timeout notice was already emitted |
| `final_delivery_mode` | enum or nil | `send`, `edit_progress`, `timeout_only`, `suppressed_after_timeout` |

### 6.2 Run Audit Enrichment

No schema change is required because `telegram_assistant_runs.result_summary` already accepts map data.

The final run summary should include a small `liveness` sub-map:

| Field | Meaning |
|---|---|
| `typing_started` | Whether native typing was ever emitted |
| `progress_note_sent` | Whether the 7-second note was sent |
| `timeout_notice_sent` | Whether timeout messaging occurred |
| `final_delivery_mode` | How the final user-visible message was delivered |

## 7. Backend and Service Design

### 7.1 Telegram Connector Changes

Add `send_chat_action/2` to [`Maraithon.Connectors.Telegram`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/telegram.ex).

Required contract:

- method: `sendChatAction`
- required params: `chat_id`, `action`
- v1 supported action from Maraithon: `typing`

Add a responder wrapper in [`Maraithon.TelegramResponder`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_responder.ex):

- `send_chat_action(chat_id, :typing)`

Test support changes:

- extend [`CapturingTelegram`](/Users/kent/bliss/maraithon/test/support/capturing_telegram.ex) to record `%{type: :chat_action, chat_id: ..., action: "typing"}` events

### 7.2 Liveness Session Service

Add a dedicated OTP-owned process rather than scattered timers in the runner process.

Recommended modules:

- `Maraithon.TelegramAssistant.LivenessSession`
- `Maraithon.TelegramAssistant.LivenessSupervisor`

Recommended supervision shape:

- add a dedicated supervisor tree under [`Maraithon.Application`](/Users/kent/bliss/maraithon/lib/maraithon/application.ex)
- include:
  - `Registry` for session lookup by `run_id`
  - `DynamicSupervisor` for one liveness session per active inbound run

This is preferable to a bare `Task` because the session owns timers, mutable phase state, and finalization rules.

### 7.3 Runner Integration

`TelegramAssistant.Runner.run_inbound/1` should:

1. create the run record
2. start the liveness session with `run_id`, `chat_id`, `conversation_id`, and `source_message_id`
3. emit session milestones as the run progresses
4. finalize the liveness session before any final user-visible delivery

Milestone updates required:

| Runner point | Liveness update |
|---|---|
| After context fetch | mark `thinking` active |
| Before each LLM request | no copy change unless still generic |
| After each successful tool call | derive hint from `tool_name` and arguments |
| On degraded failure | ask liveness session for terminal failure delivery path |
| On final response | ask liveness session whether to `send`, `edit_progress`, or suppress |

### 7.4 Progress Message Delivery

The progress note should be created by the liveness session, not by the normal final-send path.

Delivery contract:

- use `TelegramResponder.reply/4` when `reply_to_message_id` exists
- otherwise use `TelegramResponder.send/3`
- store the resulting `progress_message_id`
- do not append a durable assistant turn yet

### 7.5 Final Reply Editing

The assistant needs a final-delivery path that can edit the progress message into the final answer.

Recommended change:

- extend `TelegramAssistant.send_turn/4` or add a sibling helper to support:
  - `send_mode: :edit`
  - `message_id: <progress_message_id>`

When editing succeeds:

- persist the final assistant turn with the edited `telegram_message_id`
- preserve existing turn kinds such as `assistant_reply` and `approval_prompt`

When editing fails:

- log the edit failure
- fall back to the existing normal reply/send path

### 7.6 Timeout Finalization

Timeout ownership belongs to the liveness session, not to ad hoc runner rescue logic.

When timeout triggers:

- if a progress note exists, edit it into the timeout copy
- otherwise send a fresh timeout reply to the source message
- mark the liveness session terminal
- notify the runner that late final delivery is suppressed

The runner may still complete internal bookkeeping after this point, but it must not send a second user-visible answer.

### 7.7 Reference Flow

```text
Inbound Telegram message
  -> TelegramRouter persists user turn
  -> TelegramAssistant.Runner starts run
  -> LivenessSession starts timers
  -> grace window passes
  -> sendChatAction(typing) every 4s
  -> runner emits tool milestones
  -> if 7s passes, LivenessSession sends one contextual progress reply
  -> if response finishes before timeout:
       if progress note exists -> edit note into final answer
       else -> send normal final reply
  -> if 35s timeout fires first:
       send/edit timeout notice
       suppress late normal reply
```

## 8. Configuration Specification

Configuration lives under `:maraithon, :telegram_assistant`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `telegram_liveness_enabled` | boolean | `true` when `telegram_full_chat_enabled` is true | Master toggle |
| `typing_initial_delay_ms` | integer | `1200` | Grace window before first typing action |
| `typing_refresh_ms` | integer | `4000` | Typing heartbeat interval |
| `contextual_progress_delay_ms` | integer | `7000` | Delay before contextual progress note |
| `timeout_notice_ms` | integer | `35000` | User-visible timeout threshold |
| `hard_timeout_ms` | integer | `40000` | Suppress late final replies beyond this point |

Precedence rules:

- explicit config wins
- otherwise use defaults above
- when `telegram_liveness_enabled` is false, the assistant reverts to current silent-until-final behavior

## 9. Observability and Instrumentation

Emit exact Telemetry events for production verification.

| Event | Measurements | Metadata |
|---|---|---|
| `[:maraithon, :telegram_assistant, :liveness, :started]` | `%{count: 1}` | `run_id`, `user_id`, `chat_id` |
| `[:maraithon, :telegram_assistant, :liveness, :chat_action]` | `%{count: 1}` | `run_id`, `action: "typing"`, `phase` |
| `[:maraithon, :telegram_assistant, :liveness, :progress_note]` | `%{count: 1}` | `run_id`, `hint_category`, `delivery_mode: "send"` |
| `[:maraithon, :telegram_assistant, :liveness, :timeout]` | `%{count: 1}` | `run_id`, `hint_category`, `llm_turns`, `tool_steps` |
| `[:maraithon, :telegram_assistant, :liveness, :completed]` | `%{duration_ms: ...}` | `run_id`, `final_delivery_mode`, `typing_started`, `progress_note_sent`, `timed_out` |

Operational goals:

- prove typing is emitted for medium/slow runs
- measure how often long-run notes are needed
- detect timeout frequency after deploy
- verify that late duplicate replies are not occurring

## 10. Failure Modes, Edge Cases, and Backward Compatibility

### 10.1 Quick Replies

Runs that complete before `typing_initial_delay_ms` must produce no extra liveness output.

This prevents noisy typing flashes on fast answers.

### 10.2 Telegram API Failures

`sendChatAction`, progress-note send, or progress-note edit failures must:

- log a warning
- emit telemetry
- leave the assistant run alive

They must not cause a degraded user-facing failure on their own.

### 10.3 Long Blocking Tool Calls

If a single external call blocks long enough that the timeout session fires first:

- the timeout notice still goes out because it is owned by a separate session process
- the later final answer is suppressed

This is the main reason the liveness controller must not live only inside the blocking runner process.

### 10.4 Fallback Interpreter

Legacy fallback behavior remains unchanged in v1.

If `TelegramAssistant.handle_inbound/1` returns `{:fallback, reason}` before the assistant run is meaningfully underway, no liveness session should continue running.

### 10.5 Duplicate User Retries

If the user sends a second message after a timeout, that is a new run with a new liveness session.

The system must not try to resume or edit the first run’s timeout notice.

## 11. Rollout Plan

### 11.1 Deployment Sequence

1. Add connector and responder support for `sendChatAction`.
2. Add the liveness supervisor and session module.
3. Integrate runner milestone updates and final-edit behavior.
4. Extend the Telegram test harness.
5. Enable the feature with config on local/test first, then production.

### 11.2 Migration Notes

- No Ecto migration is required.
- No existing Telegram conversation rows need backfill.
- Existing run records remain compatible because `result_summary` is already schemaless map data.

### 11.3 Rollback

Rollback is configuration-first:

- disable `telegram_liveness_enabled`
- keep the rest of the assistant runtime intact

No schema rollback is needed.

## 12. Test Plan and Validation Matrix

### 12.1 Required Test Coverage

| Test area | Required validation |
|---|---|
| Telegram connector | `send_chat_action/2` hits `sendChatAction` with correct payload |
| Recorder stub | `CapturingTelegram` records `:chat_action` events |
| Fast run | no `:chat_action`, no progress note, one final reply |
| Medium run | at least one `:chat_action`, no progress note, one final reply |
| Slow run | `:chat_action` plus one contextual progress note that is later edited into the final reply |
| Timeout run | `:chat_action`, progress note or timeout reply, no later normal reply |
| Edit failure fallback | failed edit still results in one final visible reply |
| Telemetry | liveness events emit expected metadata and delivery mode |

### 12.2 Test Strategy Notes

Use the existing Telegram harness in:

- [`telegram_assistant_test.exs`](/Users/kent/bliss/maraithon/test/maraithon/telegram_assistant_test.exs)
- [`telegram_router_test.exs`](/Users/kent/bliss/maraithon/test/maraithon/telegram_router_test.exs)
- [`capturing_telegram.ex`](/Users/kent/bliss/maraithon/test/support/capturing_telegram.ex)

Implementation guidance for reliable tests:

- use `start_supervised!/1` for any blocking stub agents or session processes
- do not rely on `Process.sleep/1`
- use test stubs that block on explicit messages so the test controls whether the run is fast, medium, slow, or timeout
- use `:sys.get_state/1` or recorder state reads as synchronization points before asserting captured Telegram events

### 12.3 Acceptance Checks

- Asking a simple question that finishes quickly shows no flicker and still replies normally.
- Asking a question that takes around 2-6 seconds shows typing.
- Asking a question that takes longer than 7 seconds shows typing and then one contextual progress note.
- When that long-running question eventually succeeds, the user sees one final answer, not a stacked progress trail plus answer.
- When a run crosses the timeout budget, the user is told that something went wrong or took too long.
- A timed-out run does not later post a second final answer.

## 13. Definition of Done

- `sendChatAction` support exists in the Telegram connector and responder.
- Inbound Telegram assistant runs start a liveness session with the configured timing contract.
- Typing is emitted only after the grace window and refreshed while the run remains active.
- One contextual progress note appears for runs that cross 7 seconds.
- Final responses edit the progress note when available.
- Timeout notices are emitted in the 30-40 second window and suppress late final replies.
- Liveness failures do not crash normal assistant runs.
- Telemetry events and run summary metadata are emitted.
- Automated coverage exists for fast, medium, slow, timeout, and edit-failure paths.
- `mix precommit` passes after implementation.

## 14. Open Questions and Assumptions

### 14.1 Assumptions

- v1 uses only the Telegram `typing` chat action, not other activity types.
- v1 sends at most one explicit long-run progress note before finalization.
- v1 applies only to assistant-owned inbound message runs, not legacy interpreter or push flows.

### 14.2 Deferred Follow-Up

- Whether callback-confirmed prepared actions should use the same liveness session.
- Whether future versions should support streaming partial answers instead of edit-in-place progress notes.

## 15. External Reference

- Telegram Bot API `sendChatAction`: https://core.telegram.org/bots/api#sendchataction
