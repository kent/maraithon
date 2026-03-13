# Conversation-Context-Aware Follow-Through Insights

Status: Draft v1
Purpose: Define how Gmail and Slack follow-through insights must evaluate full provider-native conversation context before deciding urgency, ownership, and operator-facing copy.

## 1. Overview and Goals

### 1.1 Problem Statement

The current follow-through pipeline often treats one triggering Gmail message or Slack message as the whole story. That works for obvious open loops, but it overstates urgency when the rest of the thread shows active progress.

In the observed Telegram example, Maraithon surfaced a high-importance Gmail insight that said a reply was still owed and a human was waiting. That framing was too strong because other people had already responded in the conversation and the thread was moving. Even if the situation still deserves attention, the wording should reflect the true state of the conversation, such as: `Charlie has responded and the conversation is moving along well.`

The feature in this spec makes follow-through insights conversation-aware rather than message-local. Maraithon should examine the full Gmail thread or Slack thread/DM context, determine whether the thread is stalled or progressing, determine whether ownership has shifted or been shared, and then choose notification posture and language that matches that state.

### 1.2 Goals

- Evaluate full provider-native conversation context for Gmail and Slack follow-through insights before persisting them.
- Distinguish `you owe a reply` from `the conversation is active but you may still own a later artifact`.
- Preserve actionable reminders when the user still owns meaningful follow-through, while softening copy when others have already responded or the thread is otherwise covered.
- Persist normalized conversation-context metadata so Telegram, dashboard, and detail/explanation surfaces stay aligned.
- Improve false-positive behavior without hiding real unresolved commitments.

### 1.3 Design Principles

- Full thread before strong claim. Do not say a reply is owed or a human is waiting unless the thread evidence still supports that claim.
- Separate urgency from visibility. An item may remain visible even when it should no longer interrupt as a high-urgency reply debt alert.
- Persist the judgment basis. Operator-facing copy must derive from stored conversation-context facts, not from fresh provider fetches during render.
- Provider-local first. v1 uses Gmail thread context for Gmail insights and Slack thread or conversation context for Slack insights. It does not infer cross-provider ownership transfer.

## 2. Current State and Problem

### 2.1 Gmail Today

Relevant surfaces:

- [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex)
- [`lib/maraithon/connectors/gmail.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/gmail.ex)

Current Gmail behavior:

- `incoming_email_candidates/3` flags reply debt from one incoming message plus the user's sent-mail history.
- `sent_commitment_candidates/3` flags unresolved commitments from one sent message plus later sent-mail follow-through.
- `find_sent_reply_for_thread/5` and `find_sent_followthrough_for_commitment/3` only look for later messages sent by the user.
- The candidate prompt passed to the LLM contains the triggering message and candidate metadata, but not a normalized summary of all later thread activity.

Current limitation:

- if another participant replies in the Gmail thread, names an owner, or provides an ETA, the system still tends to persist copy such as `Reply owed` or `no reply was detected` because the only closure signal it trusts is a later message from the user

### 2.2 Slack Today

Relevant surfaces:

- [`lib/maraithon/behaviors/slack_followthrough_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/slack_followthrough_agent.ex)
- [`lib/maraithon/connectors/slack.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/slack.ex)

Current Slack behavior:

- `commitment_candidates/4` and `reply_candidates/4` evaluate the triggering message plus later messages in the same batch/history window.
- `reply_sent_after?/3` only treats a later self-authored message as closure for reply debt.
- `followthrough_message/3` only treats later self-authored artifact delivery language as closure for commitments.
- When thread replies are not fully present in the scanned batch, the agent does not fetch a normalized thread summary before persisting the alert.

Current limitation:

- active Slack threads can still be framed as stalled or awaiting the user even when another teammate has replied, taken ownership, or committed to an ETA

### 2.3 Rendering Surfaces Today

Relevant surfaces:

- [`lib/maraithon/insight_notifications/actions.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications/actions.ex)
- [`lib/maraithon/insights/detail.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights/detail.ex)
- [`lib/maraithon/telegram_router.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_router.ex)

Current limitation:

- Telegram notification copy, dashboard summaries, and explanation detail all inherit wording from message-local candidate generation.
- There is no persisted contract that says whether the conversation is stalled, progressing, transferred, or effectively resolved.

## 3. Scope and Non-Goals

### 3.1 In Scope

- Gmail thread-aware classification for reply debt and unresolved commitments.
- Slack thread-aware or conversation-aware classification for reply debt and unresolved commitments.
- A normalized `conversation_context` metadata contract stored on each persisted insight.
- Notification, summary, and `why_now` copy rules that reflect thread momentum and ownership.
- Score and priority adjustments when the conversation is progressing without the user.
- Tests for provider-specific context evaluation and operator-facing copy.

### 3.2 Non-Goals

- Cross-provider reconciliation such as using Slack replies to resolve Gmail insights.
- Historical backfill of existing insights.
- Full natural-language understanding of every ownership transfer phrasing.
- Replacing the current insight categories in v1.
- Hiding all progressing threads. Some items should still surface as lower-interruption reminders.

## 4. UX / Interaction Model

### 4.1 Operator-Facing States

Every Gmail or Slack follow-through insight must map to one of these conversation postures:

| Posture | Meaning | Default operator expectation |
|---|---|---|
| `interrupt_now` | The thread is stalled or still clearly awaiting the user | Telegram-eligible, strong action language |
| `heads_up` | The thread is active or partially covered, but the user may still own a later artifact or final close-the-loop step | Visible, softer language, lower urgency |
| `resolved` | The thread shows clear completion evidence or explicit ownership transfer away from the user | Do not persist a new open insight |
| `insufficient_context` | The thread could not be fully evaluated | Fall back conservatively, but label the reason in metadata |

### 4.2 Copy Expectations

Copy must reflect the posture:

| Posture | Title/Summary style |
|---|---|
| `interrupt_now` | `Reply owed`, `No reply detected`, `You still owe...` |
| `heads_up` | `Conversation progressing`, `Charlie has responded`, `Thread is moving`, `Keep an eye on final follow-through` |
| `resolved` | no open insight |
| `insufficient_context` | keep current wording only when no better conversation-state claim can be made |

Concrete example for a Gmail thread:

- Bad current copy: `You still owe David a response and no sent follow-up was detected.`
- Desired `heads_up` copy: `Charlie has already responded in this thread and the conversation is moving. You may still need to close the loop on the final artifact or ETA.`

### 4.3 Recommended Actions

Recommended action text must also change with posture:

| Posture | Recommended action contract |
|---|---|
| `interrupt_now` | tell the user to reply now with owner / next step / ETA |
| `heads_up` | tell the user to monitor or close the loop if they remain the owner; do not claim the thread is unattended |
| `resolved` | no action because no open insight should be stored |

## 5. Functional Requirements

### 5.1 Full Conversation Evaluation

Before persisting a Gmail or Slack follow-through insight, Maraithon must evaluate the triggering message against the rest of the provider-native conversation.

Minimum v1 signals:

- whether the user replied after the triggering event
- whether any non-user participant replied after the triggering event
- who authored the most recent meaningful message
- whether a later message contains explicit owner or ETA language
- whether a later message contains completion or artifact-delivery language
- whether the thread is still active recently enough to be considered moving rather than stalled

### 5.2 Ownership And Momentum Classification

The evaluator must derive:

- `ownership_state`: `user_owner`, `shared_owner`, `other_owner`, or `unknown`
- `momentum_state`: `stalled`, `active`, or `resolved`
- `coverage_state`: `uncovered`, `covered_by_user`, `covered_by_other`, or `unknown`
- `notification_posture`: `interrupt_now`, `heads_up`, `resolved`, or `insufficient_context`

Minimum decision rules:

1. If later completion evidence exists, classify as `resolved`.
2. If another participant has replied after the trigger and the thread remains active, do not persist `reply owed` language unless the user is still the explicit owner of the unanswered artifact.
3. If another participant explicitly takes ownership or names an ETA, classify as `heads_up` or `resolved`, not `interrupt_now`.
4. If no one replied after the trigger and the user still appears to own the next response, classify as `interrupt_now`.
5. If thread fetch fails or context is incomplete, classify conservatively and persist `insufficient_context_reason`.

### 5.3 Provider-Specific Rules

#### Gmail

- Evaluate all messages in the Gmail thread, not only later sent messages by the user.
- Treat a later message from another participant as coverage evidence even if it does not resolve the underlying artifact.
- Use metadata-level fields available from Gmail thread responses first: sender, recipients, subject, snippet, thread order, and timestamps.
- v1 may infer owner or ETA from snippet/header text rather than full body download.

#### Slack

- For threaded channel conversations, prefer full thread replies from `conversations.replies`.
- For DMs and MPIMs, evaluate later conversation history in the same DM/MPIM window.
- Treat teammate replies in the same thread as coverage evidence.
- Continue treating explicit artifact-delivery language as strong completion evidence.

### 5.4 Persisted Copy Must Reflect Context

Persisted insight fields must be derived from the classified posture:

| Field | `interrupt_now` rule | `heads_up` rule |
|---|---|---|
| `title` | direct reply debt or unresolved commitment phrasing | conversation-progress phrasing |
| `summary` | explicit unattended/open-loop language | explicit progress-but-still-watch language |
| `recommended_action` | respond now | confirm owner / monitor / close final loop if still yours |
| `metadata.why_now` | immediate human wait or missed reply | thread active, someone responded, but final obligation may remain |
| `metadata.record.status` | remains `unresolved` | remains `unresolved` unless resolved |

### 5.5 Notification Thresholding

- `heads_up` items must remain eligible to persist as open insights.
- `heads_up` items should score lower than equivalent `interrupt_now` items.
- For Gmail LLM refinement, `interrupt_now` must no longer be hard-coded true for every actionable item.
- Telegram delivery eligibility should prefer `interrupt_now`, while `heads_up` depends more heavily on `telegram_fit_score` and priority.

## 6. Data and Domain Model

### 6.1 Normalized Conversation Context

Every persisted Gmail or Slack follow-through insight should include:

```elixir
%{
  "conversation_context" => %{
    "provider" => "gmail" | "slack",
    "thread_ref" => String.t(),
    "trigger_message_ref" => String.t(),
    "ownership_state" => "user_owner" | "shared_owner" | "other_owner" | "unknown",
    "momentum_state" => "stalled" | "active" | "resolved",
    "coverage_state" => "uncovered" | "covered_by_user" | "covered_by_other" | "unknown",
    "notification_posture" => "interrupt_now" | "heads_up" | "resolved" | "insufficient_context",
    "latest_actor" => String.t() | nil,
    "latest_actor_role" => "self" | "other" | "unknown",
    "latest_activity_at" => ISO8601 | nil,
    "other_participant_replied" => boolean(),
    "user_replied" => boolean(),
    "owner_mentioned" => String.t() | nil,
    "eta_mentioned" => String.t() | nil,
    "completion_evidence" => [String.t()],
    "coverage_evidence" => [String.t()],
    "insufficient_context_reason" => String.t() | nil
  }
}
```

### 6.2 Detail Contract Additions

`metadata.detail` must be enriched with conversation-state facts when present:

| Field | Description |
|---|---|
| `open_loop_reason` | must reflect the conversation posture |
| `checked_evidence` | include coverage and completion evidence from the thread evaluator |
| `conversation_summary` | short single-paragraph explanation such as `Charlie responded 14 minutes later and named Friday 3pm as ETA.` |

### 6.3 Backward Compatibility

- Older insights without `conversation_context` remain valid.
- Renderers must fall back to existing `record`, `why_now`, and `detail` fields when `conversation_context` is absent.

## 7. Backend / Service / Context Changes

### 7.1 Gmail Thread Fetching

Add a Gmail thread-reader surface in or near [`lib/maraithon/connectors/gmail.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/gmail.ex):

- `fetch_thread(user_id_or_token, thread_id, opts \\ [])`
- return ordered messages with `message_id`, `thread_id`, `from`, `to`, `subject`, `snippet`, `labels`, and timestamps

The inbox advisor must use that thread data when evaluating:

- incoming reply debt
- sent commitments

### 7.2 Slack Context Fetching

Add a shared Slack conversation evaluator that:

- uses existing scanned history for DM/MPIM cases when sufficient
- fetches `conversations.replies` when the candidate belongs to a threaded channel message
- normalizes participant activity into one ordered message list for classification

### 7.3 Shared Conversation Evaluator

Preferred new module:

- `Maraithon.Followthrough.ConversationContext`

Responsibilities:

- accept provider-specific normalized messages plus trigger metadata
- classify ownership, coverage, momentum, and notification posture
- emit summary/evidence suitable for persisted metadata

Pseudo-flow:

```elixir
trigger
|> load_provider_conversation()
|> normalize_messages()
|> extract_followthrough_signals()
|> classify_posture()
|> build_copy_contract()
|> attach_metadata()
```

### 7.4 Gmail LLM Contract Changes

For [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex):

- include `conversation_context` in candidate JSON passed to the LLM
- update prompt instructions so actionable items may be `interrupt_now: false` when the thread is active but still worth surfacing
- allow returned items with `notification_posture = "heads_up"`
- stop requiring `interrupt_now == true` for all actionable results

### 7.5 Slack Heuristic Changes

For [`lib/maraithon/behaviors/slack_followthrough_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/slack_followthrough_agent.ex):

- after candidate detection, run conversation-context classification before persisting
- suppress new insights for `resolved`
- persist softer title/summary/recommended-action text for `heads_up`
- lower priority/confidence for `heads_up` relative to `interrupt_now`

### 7.6 Notification And Detail Rendering

For [`lib/maraithon/insight_notifications/actions.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications/actions.ex):

- use `conversation_context.notification_posture` to decide whether Telegram copy says `reply owed` or `conversation moving`
- show a short coverage line when another participant already responded

For [`lib/maraithon/insights/detail.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights/detail.ex):

- include conversation-summary and coverage evidence in the normalized explanation
- prefer stored `conversation_context` over reconstructing from older fields

## 8. Frontend / UI / Rendering Changes

### 8.1 Dashboard Cards

Dashboard cards may continue using the existing layout, but the persisted `title`, `summary`, `recommended_action`, and `why_now` must reflect posture-specific copy.

### 8.2 Telegram Insight Messages

Telegram insight cards must render:

- strong unattended-language only for `interrupt_now`
- softer progress language for `heads_up`

Suggested copy blocks:

| Situation | Copy pattern |
|---|---|
| other participant already replied | `Charlie has responded and the conversation is moving.` |
| active thread but user still owns final artifact | `The thread is moving, but you may still need to send the final update.` |
| ownership transferred | `Another owner has picked this up.` |

## 9. Observability and Instrumentation

Emit conversation-awareness telemetry for both providers:

- `maraithon.followthrough.context_evaluated`
- `maraithon.followthrough.posture_selected`
- `maraithon.followthrough.context_fetch_failed`

Required metadata:

- `provider`
- `category`
- `notification_posture`
- `ownership_state`
- `coverage_state`
- `momentum_state`
- `used_thread_fetch`
- `persisted`

## 10. Failure Modes, Edge Cases, and Backward Compatibility

### 10.1 Thread Fetch Failures

- If Gmail thread fetch or Slack thread reply fetch fails, fall back to current heuristic behavior.
- Persist `conversation_context.notification_posture = "insufficient_context"` and a concrete `insufficient_context_reason`.
- Avoid strong copy such as `nobody replied` unless that fact was actually observed.

### 10.2 Partial Coverage

If another participant replied but did not clearly close the loop:

- do not suppress automatically
- downgrade to `heads_up`
- keep `record.status = unresolved`

### 10.3 Explicit Ownership Transfer

If later thread content clearly says someone else owns the next step:

- classify as `resolved` when the user's obligation is clearly gone
- otherwise classify as `heads_up` with `ownership_state = other_owner`

## 11. Rollout / Migration Plan

1. Add provider-native thread fetch helpers and the shared conversation evaluator.
2. Wire Gmail candidates through the new evaluator before LLM prompt construction and persistence.
3. Wire Slack candidates through the new evaluator before persistence.
4. Update persisted copy and detail rendering surfaces to consume `conversation_context`.
5. Run focused tests for Gmail, Slack, Telegram notification copy, and explanation detail.
6. No data backfill is required for existing insights.

## 12. Test Plan and Validation Matrix

### 12.1 Unit And Integration Coverage

- Gmail reply-debt candidate downgrades to `heads_up` when another participant replied later in the same thread.
- Gmail commitment candidate suppresses when later thread activity contains clear completion evidence.
- Slack threaded commitment downgrades to `heads_up` when a teammate replies with owner/ETA.
- Slack DM reply debt remains `interrupt_now` when no one else replied.
- Telegram notification copy uses progress language for `heads_up`.
- Dashboard/detail explanation includes stored conversation summary and coverage evidence.
- LLM merge path preserves `notification_posture` and does not require `interrupt_now == true` for all actionable Gmail items.

### 12.2 Validation Matrix

| Scenario | Expected result |
|---|---|
| Gmail thread has only the original ask and no later replies | `interrupt_now` |
| Gmail thread has teammate reply but no final artifact yet | `heads_up` |
| Gmail thread has explicit completion reply | suppressed / resolved |
| Slack thread has teammate saying `I’ll handle this by 3pm` | `heads_up` or resolved, not `reply owed` |
| Slack DM has unanswered question and no later messages | `interrupt_now` |
| Thread fetch fails | fallback with `insufficient_context` metadata |

## 13. Definition of Done

- [ ] Gmail and Slack follow-through insights evaluate full provider-native conversation context before persistence.
- [ ] Persisted metadata includes `conversation_context` for new Gmail and Slack insights.
- [ ] `reply owed` copy no longer appears for threads already covered by another participant unless the user still clearly owes the next action.
- [ ] Telegram and dashboard copy reflect `interrupt_now` versus `heads_up`.
- [ ] Tests cover downgrade, suppression, fallback, and rendering behavior.
- [ ] Project verification passes with `mix precommit`.

## 14. Open Questions / Assumptions

### 14.1 Assumptions

- v1 uses provider-local context only.
- Gmail thread metadata plus snippet is sufficient for initial owner/ETA inference.
- `heads_up` items should remain open insights when the user may still own a final artifact or explicit close-the-loop step.

### 14.2 Open Questions

- Should `heads_up` items use a separate dashboard badge or category in a later iteration, or is copy-only differentiation enough for now?
- Should Telegram delivery thresholds explicitly vary by `notification_posture` in a later follow-up, beyond lower `telegram_fit_score` and priority?
