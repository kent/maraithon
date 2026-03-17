# Monitor-First Attention Model For Follow-Through Insights

Status: Draft v1
Purpose: Define the attention-mode model, tracked-thread lifecycle, and re-notification contract that let Maraithon separate `important` from `needs founder action now`.

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon's current follow-through pipeline is good at finding potentially important Gmail, Calendar, and Slack loops, but it still collapses two different judgments into one:

- `this thread matters`
- `this thread needs the founder to act now`

That conflation produces the false-positive pattern observed in the recent operator review:

- a promised laptop shipment that was already acknowledged still surfaced as an overdue founder debt
- a Cowrie update thread where another participant already replied and owned the next step still surfaced as `Reply owed`
- a Breck / Meta ad account thread that should remain tracked as important still surfaced as `You still owe Breck the send you promised`

The current system already contains partial conversation-awareness through the `heads_up` posture introduced in the earlier conversation-context work, but that posture is not yet a first-class product contract. It still flows through open-insight persistence, end-of-day debt summaries, and Telegram/action surfaces as if it were a founder-action item.

This spec formalizes a stronger model:

- `importance` and `attention mode` are separate axes
- `act_now` and `monitor` are different product behaviors
- `monitor` items remain tracked and can re-notify on meaningful change
- `monitor` items do not appear in debt-style summaries or direct-action copy

### 1.2 Goals

- Make `attention_mode` a first-class concept for follow-through insights.
- Preserve important threads that should stay on the radar even when immediate founder action is not required.
- Stop phrasing monitored threads as overdue founder debt.
- Exclude monitored threads from `Tonight's top actions`, overdue debt counts, and other direct-action summaries.
- Re-notify monitored Gmail threads only when material thread changes occur.
- Fit the design into the existing `InboxCalendarAdvisor -> Insights -> InsightNotifications -> Telegram/Dashboard/Briefs` pipeline with minimal conceptual churn.
- Define a buildable revisioning strategy that works with the current one-delivery-per-insight Telegram model.

### 1.3 Design Principles

- Importance is not urgency. A thread may be high-importance and still be `monitor`, not `act_now`.
- Copy follows state. Wording like `you still owe` or `reply owed` is valid only for `act_now`.
- Persist the monitoring decision. Renderers should not infer `monitor` ad hoc from scattered metadata.
- Re-notify on change, not on existence. Monitored threads should only resurface when the thread materially changes.
- Prefer conservative founder nudging. When thread ownership, closure, or reply obligation is ambiguous, bias toward `monitor` over `act_now`.

## 2. Current State and Problem

### 2.1 Current Pipeline

Relevant surfaces:

- [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex)
- [`lib/maraithon/followthrough/conversation_context.ex`](/Users/kent/bliss/maraithon/lib/maraithon/followthrough/conversation_context.ex)
- [`lib/maraithon/insights.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights.ex)
- [`lib/maraithon/insight_notifications.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex)
- [`lib/maraithon/behaviors/chief_of_staff_brief_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/chief_of_staff_brief_agent.ex)
- [`lib/maraithon_web/live/dashboard_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/dashboard_live.ex)
- [`lib/maraithon/telegram_assistant/context.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/context.ex)

Current behavior:

1. Provider-specific behaviors generate candidate follow-through items.
2. `InboxCalendarAdvisor` optionally refines Gmail and calendar candidates with an LLM pass.
3. Accepted items are persisted as `insights` rows by `Insights.record_many/3`.
4. `InsightNotifications.dispatch_telegram_batch/1` stages Telegram delivery for open insights whose score clears the threshold.
5. `ChiefOfStaffBriefAgent` builds morning / end-of-day briefs from open insights.
6. Dashboard and Telegram assistant context both read open insights directly.

### 2.2 Existing Conversation-Aware Work And Its Limit

The earlier conversation-context work already introduced:

- `conversation_context.notification_posture`
- `heads_up` copy when another participant has already replied
- `resolved` suppression when later thread activity clearly closes the loop

That work fixed one class of false positives: `the thread is moving, so do not say it is unattended`.

It did not fully solve the product problem because `heads_up` still behaves too much like debt:

- it remains part of the same open-insight pool
- it still contributes to `Tonight's top actions` because the brief builder filters by due / overdue, not by attention mode
- it still appears in general open-insight context as if it were a direct founder obligation
- it still inherits a persistence / delivery model designed around one-time actionable nudges

### 2.3 Delivery And Re-Notification Constraint

The current Telegram delivery model stages at most one delivery per `insight_id + channel + destination`:

- [`lib/maraithon/insight_notifications/delivery.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications/delivery.ex)
- [`lib/maraithon/insight_notifications.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex#L516)

This is a hard implementation constraint for monitored threads:

- if a monitor item is stored as one long-lived open insight row
- and if Telegram already delivered that row once
- the current system cannot notify again when the thread materially changes

Therefore, any first-class `monitor` design must define either:

- delivery revisioning, or
- insight revisioning

This spec chooses insight revisioning for v1 because it fits the existing `insights` and `insight_deliveries` contract with less storage and query complexity than reworking the delivery uniqueness model.

### 2.4 Observed Failure Cases

| Example | Current system behavior | Correct classification |
|---|---|---|
| David Cruz laptop shipment | Persisted as overdue founder commitment debt even after recipient acknowledgment | `resolved` in the common case; do not nudge |
| Cowrie Agora update | Persisted as `Reply owed` even though another participant replied and owned the next step with ETA | `monitor` |
| Breck / Meta thread | Persisted as `You still owe Breck...` even though the thread was acknowledged and should stay watched | `monitor` |

The first case proves that later recipient acknowledgment must count as stronger closure evidence than the current sent-mail-only logic. The second and third cases prove that a thread can still matter while no longer requiring immediate founder action.

## 3. Scope and Non-Goals

### 3.1 In Scope

- First-class `attention_mode` for persisted open insights.
- Gmail follow-through reclassification for `reply_urgent` and `commitment_unresolved` items emitted by `InboxCalendarAdvisor`.
- A stable tracked-thread identity and revisioning contract for monitor re-notification.
- Dashboard, briefs, Telegram notification, and Telegram assistant-context behavior for `act_now` vs `monitor`.
- Material-change detection rules for monitored Gmail threads.
- Migration of the existing `heads_up` concept into a first-class product model.

### 3.2 Non-Goals

- Cross-provider thread reconciliation, such as resolving Gmail items from Slack.
- A brand-new `tracked_threads` table in v1.
- Full retroactive backfill of historical closed insights.
- Rewriting the generic `insights` status model beyond `new`, `acknowledged`, `dismissed`, and `snoozed`.
- Extending source-specific attention-mode classification to Slack and Calendar in the same change. Those sources must be read-compatible with the new contract, but Gmail is the v1 classifier target because the motivating failures all come from Gmail follow-through.

## 4. UX / Interaction Model

### 4.1 Attention Modes

Every open follow-through insight must map to one of these persisted attention modes:

| Attention mode | Meaning | Founder action required now | Allowed product framing |
|---|---|---|---|
| `act_now` | The thread is both important and currently depends on direct founder action or reply | Yes | debt, urgency, explicit ask, reply owed |
| `monitor` | The thread is important enough to keep tracked, but immediate founder action is not currently required | No | watching, tracking, conversation moving, handoff in progress |
| `resolved` | The thread no longer belongs in the open set | No | no open insight |

`resolved` is not stored as an open `attention_mode`; it is the terminal outcome used to suppress or dismiss tracked items.

### 4.2 Surface Behavior Contract

| Surface | `act_now` behavior | `monitor` behavior |
|---|---|---|
| End-of-day brief | Included in `Tonight's top actions` | Excluded from `Tonight's top actions`; may appear in a separate `Watching` section only when recently changed |
| Morning brief | Included in `Focus today` | Optional `Watching` section, never mixed into the direct action list |
| Dashboard | Rendered in `Needs Action` | Rendered in `Watching` |
| Telegram proactive push | Eligible for immediate push subject to score threshold and interruption policy | Eligible only on material change and only with monitor copy |
| Telegram general chat / assistant context | Answered as an open item that needs founder action | Answered as a tracked thread that currently does not require direct action |

### 4.3 Copy Contract

| Mode | Allowed title/summary language | Disallowed language |
|---|---|---|
| `act_now` | `Reply owed`, `Overdue promise`, `You still owe`, `Needs response now` | none |
| `monitor` | `Watching`, `Thread moving`, `Breck thread still active`, `Monitor for blocker or ask-back` | `You still owe`, `Reply owed`, `No one has replied`, `overdue debt` |

For the Breck thread, the correct operator copy is approximately:

- Title: `Watching: Meta Ad Account thread with Breck`
- Summary: `Breck acknowledged the thread and is checking his side. No immediate action is required from you.`
- Recommended action: `Monitor for a blocker, a direct ask back to you, or a material change in thread state.`

## 5. Functional Requirements

### 5.1 Classification Dimensions

Every Gmail follow-through candidate must be classified on four orthogonal axes before persistence:

| Field | Type | Meaning |
|---|---|---|
| `importance_band` | `high` \| `medium` \| `low` | Whether the thread matters at all |
| `attention_mode` | `act_now` \| `monitor` \| `resolved` | Whether the founder needs direct action now |
| `founder_action_required` | boolean | Explicit boolean form of the same decision for downstream renderers |
| `ownership_state` | `user_owner` \| `shared_owner` \| `other_owner` \| `unknown` | Who appears to own the next meaningful step |

`importance_band` and `attention_mode` must not be derived from one another.

### 5.2 Gmail Rules For `act_now`

A Gmail follow-through candidate may be `act_now` only when all of the following are true:

1. The thread remains important.
2. There is a real outstanding ask, promise, blocker, or artifact still dependent on the founder.
3. Later thread evidence does not already cover the loop through acknowledgment, ownership transfer, or thread progress.
4. The copy can defensibly say the founder still owes a direct next step now.

Specific `act_now` requirements:

- `UNREAD` and `IMPORTANT` must never be sufficient by themselves.
- A real human sender must never be sufficient by itself.
- Another participant replying with owner + ETA must usually downgrade to `monitor`.
- Recipient acknowledgment such as `thanks`, `got it`, `appreciate it`, `sounds good`, or equivalent must usually suppress `act_now`.

### 5.3 Gmail Rules For `monitor`

A Gmail follow-through candidate must be `monitor` when:

- the thread is important, and
- the thread is still relevant to keep tracked, but
- immediate founder action is not currently required

Minimum `monitor` triggers in v1:

- another participant already replied and appears to own the next step
- another participant acknowledged the founder's promised send or handoff
- the thread remains strategically important, but the current next move is on someone else
- the thread may re-open if the next response or blocker routes back to the founder

The Breck thread must map here. The Cowrie thread must map here.

### 5.4 Gmail Rules For `resolved`

A Gmail follow-through candidate must be `resolved` and must not remain open when:

- later thread evidence clearly shows the founder replied and closed the loop
- later thread evidence clearly shows the recipient acknowledged receipt or completion and no fresh ask remains
- later conversation activity makes the original open-loop framing invalid and no future founder follow-through is still implied

The David Cruz laptop example must map here in the common case.

### 5.5 Material Change Rules For Monitored Threads

Monitored threads must only produce a new operator-visible revision when one of these material changes occurs:

- a new inbound message adds a direct question or explicit ask to the founder
- the thread shifts from `other_owner` or `shared_owner` back to `user_owner` or `unknown`
- blocker or risk language appears
- deadline / urgency language materially tightens
- the thread becomes stale past a configured timeout while the founder is still the likely final closer
- the thread transitions from `monitor` to `act_now`

The following must not create a new monitor revision by themselves:

- additional thanks / pleasantries
- non-substantive acknowledgments
- duplicate status chatter with no ownership change
- CC churn without a new ask

### 5.6 Re-Notification Contract

Monitor items may re-notify only when:

1. a new material change revision is created, and
2. the revision's attention mode remains `monitor` or escalates to `act_now`, and
3. channel policy for that revision allows proactive delivery

`monitor` re-notifications must never use debt or overdue wording.

### 5.7 Surface Filtering Rules

- `ChiefOfStaffBriefAgent` must use `attention_mode == "act_now"` when building `Tonight's top actions`.
- `overdue_count/3` and `due_today_count/3` used in debt framing must count only `act_now`.
- `monitor` items may appear in a separate `Watching` brief section when they are high-importance and changed recently.
- Dashboard and Telegram assistant context must expose `attention_mode` explicitly.

## 6. Data and Domain Model

### 6.1 Schema Changes

This spec resolves the earlier `heads_up` open question by making attention mode queryable at the schema level.

Add to `insights`:

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `attention_mode` | `:string` | false | `"act_now"` | Enum: `act_now`, `monitor` |
| `tracking_key` | `:string` | true in migration, required for new writes | none | Stable identifier for one underlying thread / obligation family |

Indexes:

| Index | Purpose |
|---|---|
| `[:user_id, :attention_mode, :status]` | fast brief/dashboard filters |
| `[:user_id, :tracking_key, :status]` | resolve prior open revisions for the same tracked thread |

`tracking_key` must be stable across revisions of the same thread. Examples:

- `gmail:thread:<thread_id>`
- `gmail:commitment:<thread_id>`

### 6.2 Metadata Contract

Persist the normalized attention decision under `metadata["attention"]`:

```elixir
%{
  "attention" => %{
    "mode" => "act_now" | "monitor",
    "importance_band" => "high" | "medium" | "low",
    "founder_action_required" => boolean(),
    "ownership_state" => "user_owner" | "shared_owner" | "other_owner" | "unknown",
    "material_change_kind" =>
      "initial_detection" |
      "new_direct_ask" |
      "ownership_shift" |
      "new_blocker" |
      "deadline_tightened" |
      "thread_stalled" |
      "monitor_escalated",
    "change_summary" => String.t() | nil,
    "revision_key" => String.t(),
    "re_notify_eligible" => boolean()
  }
}
```

### 6.3 Revisioning Model

To preserve the current one-delivery-per-insight behavior, v1 must version insights on material change instead of attempting multiple deliveries for one persistent row.

Rules:

1. `tracking_key` identifies the long-lived thread or commitment.
2. `revision_key` identifies one materially distinct state of that tracked item.
3. `dedupe_key` becomes revision-scoped, not merely thread-scoped.
4. When a new revision is emitted for an existing `tracking_key`, Maraithon must dismiss any prior open insight with the same `tracking_key` before inserting the new revision.
5. If no material change occurred, Maraithon must not emit a new revision.

Recommended v1 shape:

```text
tracking_key = gmail:thread:<thread_id>
revision_key = sha256(attention_mode + ownership_state + latest_activity_at + material_change_kind + due_bucket)
dedupe_key = <tracking_key>:<revision_key>
```

This preserves:

- one active open revision per tracked thread
- compatibility with the existing `insight_deliveries` uniqueness contract
- clear re-notify semantics

## 7. Backend / Service / Context Changes

### 7.1 `Followthrough.ConversationContext`

Enhance [`lib/maraithon/followthrough/conversation_context.ex`](/Users/kent/bliss/maraithon/lib/maraithon/followthrough/conversation_context.ex) to detect:

- recipient acknowledgment / gratitude
- ownership handoff phrasing
- no-fresh-ask acknowledgment after founder send
- stronger closure evidence beyond the current `sent/shared/done` terms

Add normalized fields that help the Gmail classifier decide between `monitor` and `resolved`, such as:

- `acknowledgment_evidence`
- `fresh_ask_after_acknowledgment`
- `handoff_evidence`
- `closure_state`

### 7.2 `InboxCalendarAdvisor`

Update [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex) so that:

- `reply_urgent` and `commitment_unresolved` candidate generation classify `attention_mode` explicitly
- `heads_up` is no longer treated as a softer version of debt; it becomes `monitor`
- insufficient Gmail thread context cannot create an `act_now` debt item unless the remaining evidence is extremely strong
- `UNREAD` / `IMPORTANT` contribute to scoring only after obligation is established
- recipient acknowledgment can suppress or downgrade a sent-commitment item

### 7.3 `Insights`

Update [`lib/maraithon/insights.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights.ex) and [`lib/maraithon/insights/insight.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights/insight.ex):

- accept and validate `attention_mode`
- accept and persist `tracking_key`
- add helper queries:
  - `list_open_act_now_for_user/2`
  - `list_open_monitor_for_user/2`
- add helper to dismiss prior open revisions for one `tracking_key`

### 7.4 `InsightNotifications`

Update [`lib/maraithon/insight_notifications.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex):

- `act_now` remains eligible for existing score-threshold staging
- `monitor` delivery requires both score clearance and `re_notify_eligible == true`
- `delivery_exists?/2` remains unchanged because new monitor notifications arrive as new insight revisions

### 7.5 `ChiefOfStaffBriefAgent`

Update [`lib/maraithon/behaviors/chief_of_staff_brief_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/chief_of_staff_brief_agent.ex):

- `Tonight's top actions` must be sourced from `act_now` only
- add an optional `Watching` section sourced from recently changed `monitor` items
- brief summaries must not describe `monitor` items as overdue debt

### 7.6 Telegram Assistant And Context

Update [`lib/maraithon/telegram_assistant/context.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/context.ex) and [`lib/maraithon/telegram_router.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_router.ex):

- serialized open insights must include `attention_mode`
- explanations for `monitor` items must say why Maraithon is still tracking them, not why the founder is delinquent
- general-chat queries such as `what do I owe?` should default to `act_now`
- general-chat queries such as `what are you watching?` should be able to surface `monitor`

## 8. Frontend / Rendering Changes

### 8.1 Dashboard

Update [`lib/maraithon_web/live/dashboard_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/dashboard_live.ex):

- split the current open-insight section into:
  - `Needs Action`
  - `Watching`
- retain the existing detail accordion for both sections
- show a visible attention-mode badge
- use monitor-safe copy and action affordances

`monitor` cards keep `dismiss` and `snooze`, but the primary action must be observational, not completion-oriented.

### 8.2 Telegram Insight Message

Update [`lib/maraithon/insight_notifications/actions.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications/actions.ex):

- render distinct header/body copy for `monitor`
- suppress action buttons like `Draft Email` or `Mark Done` when the current mode is `monitor` unless a linked task still truly belongs to the founder
- include change summary when the notification is a monitor re-alert

### 8.3 Brief Rendering

End-of-day and morning brief formatting must distinguish:

- `act_now`: debt language, due, overdue
- `monitor`: watch language, thread changed, no direct action required

## 9. Observability and Instrumentation

Add telemetry and structured logs for:

| Signal | Purpose |
|---|---|
| `followthrough_attention_mode_assigned` | distribution of `act_now` vs `monitor` |
| `followthrough_attention_mode_changed` | monitor-to-act_now, act_now-to-monitor, open-to-resolved |
| `followthrough_monitor_revision_created` | re-notify volume |
| `followthrough_monitor_revision_suppressed` | change detector effectiveness |
| `followthrough_false_positive_feedback` | measure whether monitor reduces not-helpful outcomes |

Recommended counters:

- open `act_now` count
- open `monitor` count
- monitor-to-act_now transition count
- resolved-without-founder-action count

## 10. Failure Modes, Edge Cases, and Backward Compatibility

### 10.1 Thread Fetch Failure

If Gmail thread fetch fails:

- do not create a new `act_now` item from a sent-commitment candidate unless the remaining evidence is extremely explicit
- prefer `monitor` or suppression over debt-style escalation
- persist the failure reason in `conversation_context.insufficient_context_reason`

### 10.2 Identity Resolution Failure

If the system cannot confidently map a later Gmail sender to the founder's own account identity:

- do not treat the thread as definitively resolved
- but also do not escalate to `act_now` solely because self-coverage could not be proven
- prefer `monitor`

### 10.3 Existing Open Insights

Backward-compatibility rules:

- existing rows without `attention_mode` default to `act_now`
- existing rows with `conversation_context.notification_posture == "heads_up"` may be migrated to `monitor` in a targeted backfill for currently open rows
- renderers must tolerate missing `tracking_key` and `metadata.attention`

## 11. Rollout / Migration Plan

1. Add schema fields and indexes.
2. Ship read-compatible rendering with defaults for rows missing `attention_mode`.
3. Enable Gmail attention-mode classification behind a feature flag such as `followthrough_attention_modes_enabled`.
4. Backfill currently open `heads_up` Gmail insights to `monitor` where safe.
5. Enable brief splitting so `monitor` stops polluting `Tonight's top actions`.
6. Enable monitor revisioning and material-change re-notification behind a second flag such as `followthrough_monitor_renotify_enabled`.

## 12. Test Plan and Validation Matrix

### 12.1 Required Regression Scenarios

| Scenario | Expected outcome |
|---|---|
| Recipient acknowledges promised send, no fresh ask | `resolved`, no open debt insight |
| Another participant replies with owner + ETA | `monitor`, not `act_now` |
| Important handoff thread remains strategically relevant | `monitor` persists |
| Monitor thread receives new direct ask to founder | new revision, `act_now` |
| Monitor thread only receives pleasantries | no new revision |
| Brief builder with mixed `act_now` + `monitor` open items | top actions show only `act_now` |
| Telegram delivery for existing monitor item after material change | new revision can notify once |

### 12.2 Implementation Tests

- unit tests for Gmail attention-mode classification
- unit tests for acknowledgment / handoff / reopen detection in `ConversationContext`
- unit tests for tracking-key revisioning and dismissal of prior open revisions
- integration tests for `ChiefOfStaffBriefAgent` sectioning
- integration tests for Telegram message copy and button behavior by `attention_mode`
- regression tests for the David Cruz, Cowrie, and Breck examples

### 12.3 Verification Gates

- `mix test` for focused suites while iterating
- `mix precommit` before moving the spec into implementation-complete state

## 13. Definition of Done

- [ ] `attention_mode` and `tracking_key` exist on persisted insights
- [ ] Gmail follow-through emits `act_now` vs `monitor` explicitly
- [ ] recipient acknowledgment and ownership handoff no longer surface as debt
- [ ] `Tonight's top actions` excludes `monitor`
- [ ] dashboard shows separate `Needs Action` and `Watching` sections
- [ ] monitor re-notification works through revisioned insights without breaking delivery uniqueness
- [ ] Telegram copy for `monitor` is observational, not debt-framed
- [ ] regression tests cover the motivating examples
- [ ] `mix precommit` passes

## 14. Open Questions / Assumptions

- Assumption: v1 classification work is Gmail-first because the motivating failures and current operator pain are Gmail-based.
- Assumption: `monitor` should remain visible in dashboard and assistant context even when no proactive Telegram push is sent.
- Assumption: insight revisioning is the preferred v1 solution for monitor re-notify; a dedicated tracked-thread store is deferred.
- Open question: whether the `Watching` section should appear in every daily brief or only when a monitor item changed within the lookback window.
- Open question: whether very high-importance `monitor` items should support a dedicated Telegram template distinct from the general insight card.
