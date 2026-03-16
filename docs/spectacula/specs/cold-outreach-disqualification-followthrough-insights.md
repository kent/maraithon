# Cold-Outreach Disqualification For Follow-Through Insights

Status: Draft v1
Purpose: Define how Maraithon's Gmail follow-through pipeline must disqualify unsolicited sales outreach before it becomes an actionable insight or Telegram interruption.

## 1. Overview and Goals

### 1.1 Problem Statement

The current Gmail follow-through pipeline is biased toward escalation once it sees a real human sender, reply-like language, unread labels, or an "important" label. That works for legitimate customer, partner, or teammate loops, but it fails on outbound sales sequences and other unsolicited prospecting.

In the observed failure, Maraithon sent a Telegram insight telling the operator that Ayoub Rezala was waiting on a reply and that the thread was unattended. The underlying email was actually cold sales outreach for an outbound prospecting tool. A human sender existed, but there was no real reply obligation.

This feature makes the Gmail follow-through pipeline disqualify cold outreach before it is framed as a founder obligation. The fix must prefer false negatives over false positives for long-running push agents.

### 1.2 Goals

- Prevent unsolicited sales outreach from being persisted or pushed as a `reply_urgent` insight unless the user has clearly engaged or made an explicit commitment.
- Require the model to reason with both positive and negative evidence before classifying a thread as reply debt.
- Introduce explicit outreach indicators and thread-level engagement signals into candidate metadata and the LLM contract.
- Preserve real work threads, even when they contain sales-like wording, when the user has already engaged or committed.
- Extend durable preference memory so operators can express policies such as "ignore sales outreach unless I've engaged."

### 1.3 Design Principles

- Disqualification before escalation. The model's first job is to prove a real obligation exists, not to reword a weak heuristic.
- Human sender is not enough. A real person, a follow-up, or an unread label does not imply reply debt.
- Conservative defaults. When evidence is mixed or ambiguous, the candidate must not become an actionable insight or Telegram interruption.
- Deterministic guardrails around model output. The implementation must reject clearly disqualified outreach even if the model returns an overconfident item.
- Reuse current delivery semantics. v1 must fit the existing `InboxCalendarAdvisor -> Insights -> InsightNotifications` flow without introducing a new digest queue.

## 2. Current State and Problem

### 2.1 Gmail Reply Debt Today

Relevant surfaces:

- [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex)
- [`lib/maraithon/followthrough/conversation_context.ex`](/Users/kent/bliss/maraithon/lib/maraithon/followthrough/conversation_context.ex)
- [`lib/maraithon/connectors/gmail.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/gmail.ex)

Current behavior:

- `incoming_email_candidates/3` turns an incoming Gmail message into a `reply_urgent` candidate when it sees reply-ish terms or `UNREAD` / `IMPORTANT`.
- The candidate metadata includes thread context and evidence, but not a structured disqualification contract for sales outreach.
- The LLM prompt asks the model to exclude receipts and generic marketing, but it does not explicitly model cold sales outreach or require negative evidence.
- `actionable_llm_item?/2` accepts a returned item as long as it is actionable, human-facing, unresolved, and below the false-positive-risk cap.

Current failure mode:

- An unsolicited sales email can look like a legitimate founder obligation because it contains a real name, a follow-up, a same-day CTA, and no completion evidence.
- Once the model returns an actionable item, the existing pipeline can persist it and stage a Telegram push if `telegram_fit_score` clears the threshold.

### 2.2 Existing Thread Context Is Necessary But Not Sufficient

The earlier conversation-context work already softens wording when another participant has replied later in the thread. That solves "thread is moving" false positives, but not "thread never deserved a reply-owed insight" false positives.

Cold outreach often has these characteristics:

- the sender is real and personalized
- the thread contains multiple sender follow-ups
- the user has never replied in the thread
- the sender includes meeting-booking language or a Calendly link
- the email references a public post, compares tools, or pitches a service/tool/platform

Those signals should bias the system toward disqualification, not urgency.

## 3. Scope and Non-Goals

### 3.1 In Scope

- Gmail `reply_urgent` candidate generation in `InboxCalendarAdvisor`.
- Candidate metadata additions for thread classification, engagement, and positive/negative evidence.
- Prompt contract changes for the Gmail/Calendar follow-through LLM pass.
- Deterministic post-LLM acceptance rules that reject cold outreach without engagement.
- Durable preference-memory prompt coverage for `sales_outreach` and `cold_outreach`.
- Regression tests for the Ayoub/Outly-style false positive and the stricter LLM contract.

### 3.2 Non-Goals

- A separate digest storage or delivery system.
- New Gmail provider fetches beyond the existing thread metadata fetch.
- Contact-book integration or CRM-based sender reputation.
- Historical backfill of previously persisted insights.
- A generic cross-provider outreach classifier for Slack, Telegram, or Calendar in v1.

## 4. Operator Model

### 4.1 Desired Outcomes

For a cold email sequence, Maraithon should behave as if the burden of proof is on the sender, not on the operator.

Expected outcomes:

| Case | Expected result |
|---|---|
| Unsolicited sales outreach, no user engagement, no explicit commitment | No actionable insight persisted |
| Outreach-like thread with weak evidence and no clear obligation | No actionable insight persisted |
| Outreach thread where the user already engaged materially | Candidate may proceed to the model |
| Outreach thread where the user explicitly promised something | Candidate may proceed to the model |
| Legitimate external request from customer / partner / investor | Existing reply-debt behavior should remain eligible |

### 4.2 "Digest, Not Telegram" Interpretation In v1

The current pipeline only persists actionable insights, then stages Telegram delivery from persisted insight rows. It does not have a separate low-urgency digest queue for Gmail follow-through candidates.

For this feature's v1 contract:

- `importance = "important"` means the model believes the item is eligible to persist as an actionable insight.
- `importance = "digest"` or `importance = "drop"` means the item must not be persisted by `InboxCalendarAdvisor`.
- This effectively keeps ambiguous outreach out of Telegram and out of the actionable-open-loop set, which matches the repo's current runtime shape.

Future digest-specific storage is explicitly out of scope.

## 5. Functional Requirements

### 5.1 Candidate Metadata Must Include Disqualification Signals

Every Gmail reply-debt candidate considered by the LLM must carry structured metadata describing:

| Field | Type | Meaning |
|---|---|---|
| `thread_type_hint` | enum string | Initial heuristic such as `cold_sales_outreach`, `direct_human_request`, or `unknown` |
| `solicited_hint` | boolean | Whether the thread appears solicited based on prior user participation or commitment |
| `prior_user_engagement` | boolean | Whether the user authored a message earlier in the thread |
| `explicit_user_commitment` | boolean | Whether the user previously made an explicit promise in the thread or in a prior sent message on the thread |
| `importance_hint` | enum string | `drop`, `digest`, or `important` |
| `reply_obligation_hint` | boolean | Whether the heuristic pass believes a reply obligation plausibly exists |
| `outreach_indicators` | string list | Matched indicators such as `saw your post`, `calendly`, `book time` |
| `evidence_for_reply_owed` | string list | Positive evidence, excluding "real human sender" by itself |
| `evidence_against_reply_owed` | string list | Negative evidence such as no engagement or sales-sequence indicators |

### 5.2 Clear Cold Outreach Must Be Suppressed Before The LLM

The implementation must skip candidate creation entirely when all of the following are true:

1. The incoming thread strongly matches cold outreach indicators.
2. The user has not participated earlier in the thread.
3. No explicit user commitment is found.

Minimum strong indicators in v1:

- sequence follow-up with no user reply
- `saw your post` / `saw your tweet` / similar social-reference language
- `calendly`, `book time`, `book a time`, `quick call`, `quick chat`, `15-minute`, or `demo`
- tool / agency / outbound prospecting pitch language such as `sales on autopilot`, `prospecting`, or `outbound sales`

### 5.3 The LLM Must Reason With Positive And Negative Evidence

The prompt must tell the model:

- first disqualify, then escalate
- a real human sender does not imply reply debt
- cold sales outreach, recruiting spam, and networking pitches are non-actionable unless the user engaged or committed
- if the only positive evidence is "human sender followed up" or label-based urgency, omit the candidate
- if positive and negative evidence conflict materially, omit the candidate rather than force an actionable insight

Returned items must include:

| Field | Type | Rules |
|---|---|---|
| `thread_type` | enum string | Includes `cold_sales_outreach`, `customer_work`, `vendor_active`, `internal_work`, `recruiting_outreach`, `networking_pitch`, `unknown` |
| `solicited` | boolean | True only when prior engagement or context supports it |
| `prior_user_engagement` | boolean | Must reflect thread history |
| `explicit_user_commitment` | boolean | Must reflect prior promise evidence |
| `reply_obligation` | boolean | Must be true only when a real obligation remains |
| `importance` | enum string | `important`, `digest`, or `drop` |
| `evidence_for_reply_owed` | string list | Concise positive evidence |
| `evidence_against_reply_owed` | string list | Concise negative evidence |
| `decision_reason` | string | One-sentence summary of the decision |

### 5.4 Deterministic Acceptance Rules Must Reject Disqualified Outreach

`actionable_llm_item?/2` or an equivalent acceptance gate must reject any returned item when:

- `reply_obligation` is false
- `importance` is not `important`
- `evidence_for_reply_owed` is empty
- the item is classified as `cold_sales_outreach` and both `prior_user_engagement` and `explicit_user_commitment` are false

The implementation may use the returned fields first and candidate hints as fallback defaults when the model omits a field.

### 5.5 Preference Memory Must Support This Content Class

The durable preference-memory prompts and examples must explicitly support content-filter topics:

- `sales_outreach`
- `cold_outreach`

Supported operator intent examples:

- `ignore sales outreach unless I've engaged`
- `ignore cold outreach unless I explicitly asked for the info`

The v1 requirement is prompt-level and rule-schema-level support. Separate synchronous enforcement of content filters at Telegram staging is not required for this spec.

## 6. Data and Domain Model

### 6.1 Candidate Metadata Contract

These fields live under `candidate.metadata` before the LLM call:

```elixir
%{
  "thread_type_hint" => "cold_sales_outreach" | "direct_human_request" | "unknown",
  "solicited_hint" => boolean(),
  "prior_user_engagement" => boolean(),
  "explicit_user_commitment" => boolean(),
  "importance_hint" => "drop" | "digest" | "important",
  "reply_obligation_hint" => boolean(),
  "outreach_indicators" => [String.t()],
  "evidence_for_reply_owed" => [String.t()],
  "evidence_against_reply_owed" => [String.t()]
}
```

### 6.2 Persisted Metadata Contract

For persisted items that survive the gate, the merged insight metadata should retain:

```elixir
%{
  "thread_type" => String.t(),
  "solicited" => boolean(),
  "prior_user_engagement" => boolean(),
  "explicit_user_commitment" => boolean(),
  "reply_obligation" => boolean(),
  "importance" => "important",
  "evidence_for_reply_owed" => [String.t()],
  "evidence_against_reply_owed" => [String.t()],
  "decision_reason" => String.t()
}
```

Older insights without these keys remain valid.

## 7. Backend Changes

### 7.1 Conversation Context Enrichment

`Maraithon.Followthrough.ConversationContext` must expose enough thread-level engagement data for the Gmail classifier to know whether the user participated earlier in the thread.

Minimum added fields:

- total thread message count
- total self-authored message count
- total other-authored message count
- `prior_user_participation`
- count of prior other-authored messages before the trigger

### 7.2 Gmail Reply Candidate Classification

`incoming_email_candidates/3` must:

1. build conversation context
2. derive outreach indicators and engagement facts
3. build positive and negative evidence arrays
4. suppress clear cold outreach before candidate creation
5. attach disqualification metadata to any remaining candidate

The implementation must avoid using `UNREAD` or `IMPORTANT` alone as sufficient evidence for `reply_obligation_hint`.

### 7.3 LLM Prompt Upgrade

The prompt in `build_llm_prompt/3` must:

- explicitly describe the disqualification-first workflow
- describe cold sales outreach as a distinct exclusion class
- reference candidate `importance_hint` and evidence arrays when present
- require the new output fields
- instruct the model to omit all non-`important` items from the actionable output

### 7.4 Merge And Acceptance Upgrade

`merge_llm_item/3` must preserve the new fields in persisted metadata.

`actionable_llm_item?/2` must incorporate the deterministic rejection rules from section 5.4.

## 8. Observability and Instrumentation

The implementation should log enough structured context to debug classification mistakes without storing raw provider bodies.

Minimum logging additions:

- candidate suppressed as clear cold outreach
- number of outreach indicators matched
- whether prior user engagement was detected
- whether the returned item was rejected because `importance != important` or `reply_obligation == false`

This may remain logger-based in v1; new telemetry events are optional.

## 9. Failure Modes, Edge Cases, and Backward Compatibility

### 9.1 Edge Cases

- A real customer email may include `quick call` or `Calendly`; user participation or prior commitment must prevent over-suppression.
- A tool vendor thread may become actionable once the user engages and asks for material; prior engagement must keep the door open.
- A user may explicitly promise a response in a sales thread; that commitment is actionable even if the thread started as cold outreach.
- A missing Gmail thread fetch must not automatically produce `cold_sales_outreach`; fall back to conservative hints from the trigger message only.

### 9.2 Backward Compatibility

- Existing persisted insights remain readable.
- Existing prompt consumers continue to work because the agent still returns a JSON array of actionable items.
- The stricter acceptance gate may reduce insight volume. That is an intended behavior change.

## 10. Rollout Plan

1. Add the classifier metadata and prompt contract.
2. Add deterministic acceptance rules.
3. Add regression tests for the Ayoub/Outly-style case and for retained legitimate reply debt.
4. Run `mix precommit`.
5. Deploy and watch for a drop in not-helpful feedback on Gmail `reply_urgent` insights.

## 11. Test Plan and Validation Matrix

| Scenario | Expected result |
|---|---|
| Clear cold sales outreach with no engagement and multiple outreach indicators | No candidate / no LLM call or no persisted insight |
| Legitimate human request with direct ask and no outreach indicators | Candidate proceeds and can persist |
| Sales thread with prior user engagement | Candidate may proceed |
| LLM returns `importance = digest` | Item is rejected and not persisted |
| LLM returns `reply_obligation = false` | Item is rejected and not persisted |
| Preference parsing for `ignore sales outreach unless I've engaged` | Rule persists with `content_filter` and `sales_outreach` / `cold_outreach` topics |

## 12. Definition of Done

- Canonical Spectacula spec is stored in `docs/spectacula/specs`.
- Gmail cold outreach without engagement is not persisted as a `reply_urgent` insight.
- The LLM prompt and acceptance gate both understand positive and negative evidence.
- `sales_outreach` and `cold_outreach` appear in preference-memory prompt guidance and test coverage.
- The Ayoub/Outly-style regression test passes.
- `mix precommit` passes.

## 13. Assumptions

- v1 uses Gmail metadata-level thread context only; it does not fetch full decoded bodies for every thread.
- "Digest" is interpreted as "not actionable in the current insight pipeline" because the repo has no separate Gmail digest queue today.
- Prompt-level preference support is sufficient for this feature's first pass; deterministic content-filter enforcement outside quiet hours can be added later if needed.
