# Evidence-First Insight Detail

Status: Draft v2
Purpose: Define inline expandable detail for dashboard insight cards, the shared explanation contract behind that detail, and the rollout and validation scope for trust-focused evidence rendering.

## 1. Overview and Goals

### 1.1 Problem Statement

The dashboard currently shows each open insight as a compact card with category, priority, confidence, summary, recommended action, and optional `why_now` or follow-up ideas. That supports quick triage, but it does not earn trust. A user cannot inspect the exact promise behind the insight, who asked for the work, whether Maraithon checked delivery evidence, or why the system still believes the loop is open.

Trust is the gating metric for long-running follow-through. If Maraithon cannot explain its open-loop claims with concrete persisted evidence, users will dismiss or ignore the cards instead of relying on them.

### 1.2 Goals

- Add a collapsed-by-default inline accordion to every open insight card on the dashboard.
- Show the exact promise text when available, not only a compressed summary.
- Show who asked for the work when that information can be derived from stored metadata.
- Show the source-side and delivery-side evidence Maraithon checked, using persisted data only.
- Show stored rationale verbatim when available, and a clearly labeled derived explanation when not.
- Keep dashboard and Telegram "why did you send this?" explanations aligned through a shared normalization contract.
- Degrade gracefully for older or less-structured insight categories without hiding data gaps.
- Emit concrete telemetry events that let operators measure whether deeper explainability improves trust and actionability.

### 1.3 Design Principles

- Evidence before recommendation. The detail view exists to justify the card, not to add more generic advice.
- One explanation contract across surfaces. The dashboard and Telegram may render different formats, but they must derive from the same normalized detail shape.
- Persisted data only. The render path must not fetch fresh provider data or invoke the model again.
- Honest gaps over silent omission. Missing provenance must be shown explicitly.

## 2. Current State and Problem

### 2.1 Dashboard Surface Today

The current dashboard flow is:

- [`lib/maraithon_web/live/dashboard_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/dashboard_live.ex) renders open insights from `Insights.list_open_for_user/2`.
- The LiveView refreshes every 5 seconds and replaces `@insights` with a fresh query result.
- Each card currently shows category, priority, confidence, due date, title, source/account label, summary, recommended action, optional `why_now`, optional follow-up ideas, and the `acknowledge`, `snooze`, and `dismiss` buttons.

Current limitations:

- no inline evidence drill-down
- no exact promise or requester display
- no delivery history on the dashboard
- no explicit refresh contract for detail state

### 2.2 Persisted Inputs Available Today

Relevant repository surfaces:

- [`lib/maraithon/insights.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights.ex) reads persisted `insights` rows ordered by priority, due date, and recency.
- [`lib/maraithon/insights/insight.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insights/insight.ex) stores the core insight fields plus a generic `metadata` map.
- [`lib/maraithon/insight_notifications/delivery.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications/delivery.ex) stores notification delivery outcomes such as `channel`, `destination`, `status`, `sent_at`, `feedback`, and `error_message`.
- [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex) already persists structured follow-through metadata such as `record.commitment`, `record.person`, `record.status`, `record.evidence`, `record.next_action`, `why_now`, and `follow_up_ideas`.

Important current-state fact: the `Delivery` schema is channel-generic, but the delivery staging path in [`lib/maraithon/insight_notifications.ex`](/Users/kent/bliss/maraithon/lib/maraithon/insight_notifications.ex) currently inserts `channel: "telegram"` rows only. The upgraded spec must therefore define a Telegram-safe label contract now, while remaining extensible for future channels.

### 2.3 Existing Explanation Surface Outside The Dashboard

[`lib/maraithon/telegram_router.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_router.ex) already contains `explain_insight/3`, which renders "Why now", "Evidence checked", and the recommended action from the same persisted insight metadata. Today that explanation path is independent from the dashboard render path.

Without an explicit shared contract, the dashboard and Telegram can drift and explain the same insight differently. This upgrade closes that gap.

## 3. Scope and Non-Goals

### 3.1 In Scope

- A universal inline accordion interaction for every open dashboard insight card.
- A normalized detail builder that converts an `Insight` and its related deliveries into a renderer-friendly detail payload.
- A new insight-listing context function that batch-loads deliveries and preserves current ordering and filtering semantics.
- A shared explanation contract that both the dashboard and Telegram explanation surface can use.
- A privacy-safe delivery presentation rule that never exposes raw destinations in the dashboard UI.
- Telemetry event emission for detail interaction and detail coverage.
- Tests and acceptance checks for state behavior, fallback behavior, privacy, and explanation parity.

### 3.2 Non-Goals

- Creating a standalone detail page.
- Fetching live provider data during expansion.
- Re-ranking insights or changing notification thresholds.
- Replacing the existing `acknowledge`, `snooze`, or `dismiss` actions.
- Backfilling historical rows to add `metadata.detail`.
- Building a raw payload inspector for Gmail, Slack, or Telegram data.

## 4. UX / Interaction Model

### 4.1 Card Layout

Each card in the `Actionable Insights` list gets a compact secondary control, such as `Show evidence` / `Hide evidence`, rendered below the summary block and above the existing action buttons. The card stays scannable when collapsed.

Expanded section order:

1. `Exact promise`
2. `Who asked`
3. `Evidence checked`
4. `Delivery evidence checked`
5. `Why Maraithon still thinks this is open`
6. `Data gaps`

### 4.2 Expand And Collapse Behavior

- Cards are collapsed by default on first render.
- Multiple cards may be expanded at the same time.
- Expanding a card must not navigate away from the dashboard.
- Expand and collapse must not interfere with `acknowledge`, `snooze`, or `dismiss`.
- Detail state is per LiveView session only. A full page reload resets all cards to collapsed in v1.
- The toggle control must expose `aria-expanded` and clearly reference the expanded region.

### 4.3 Refresh And Action Semantics

The dashboard refreshes every 5 seconds. The detail contract must define what happens when the visible insight set changes:

- Expanded state is keyed by `insight.id`, not card position.
- If an expanded insight remains in the refreshed result set, it stays expanded after refresh.
- If an insight disappears because it was acknowledged, dismissed, or snoozed into the future, its id is pruned from all detail-state assigns.
- If ordering changes, the expansion follows the insight id to its new position.
- Manual refresh and timed refresh use the same pruning logic.
- A successful action refreshes the list and removes only state for ids no longer present. Other expanded cards stay expanded.

Recommended state update logic:

```elixir
cards = Insights.list_open_with_details_for_user(user_id, limit: 20)
visible_ids = cards |> Enum.map(& &1.insight.id) |> MapSet.new()

assign(socket,
  insights: cards,
  expanded_insight_ids: MapSet.intersection(socket.assigns.expanded_insight_ids, visible_ids),
  detail_opened_insight_ids:
    MapSet.intersection(socket.assigns.detail_opened_insight_ids, visible_ids)
)
```

### 4.4 Missing-Data Copy Rules

The UI must use explicit, stable empty states rather than hiding sections silently:

| Section | Empty-state copy |
|---|---|
| `Exact promise` | `Exact promise not captured for this insight.` |
| `Who asked` | `Requester not captured for this insight.` |
| `Evidence checked` | `No persisted evidence bullets were captured for this insight.` |
| `Delivery evidence checked` | `No delivery attempts recorded.` |
| `Why Maraithon still thinks this is open` | `Open-loop reason could not be reconstructed from persisted data.` |

If any of these empty states render, the same reason must also be reflected in `data_gaps`.

## 5. Functional Requirements

### 5.1 Section Content Contract

| Section | Preferred content | Required labeling rules |
|---|---|---|
| `Exact promise` | Most literal stored obligation text | Label as `Stored` or `Reconstructed` |
| `Who asked` | Human requester or counterparty | Label as `Stored` or `Derived` when needed |
| `Evidence checked` | Concise persisted evidence bullets | Never render raw provider payloads |
| `Delivery evidence checked` | Delivery timeline/list with safe destination label | Never show raw `destination` |
| `Why Maraithon still thinks this is open` | Stored rationale first, else derived explanation | Label as `Stored rationale` or `Derived from persisted evidence` |
| `Data gaps` | Explicitly missing fields or unsupported detail | Only show when non-empty |

### 5.2 Derivation Rules

- `promise_text` source order:
  1. `metadata.detail.promise_text`
  2. `metadata.record.commitment`
  3. top-level `metadata.commitment`
  4. reconstructed text from `title`, `summary`, or `recommended_action`

- `requested_by` source order:
  1. `metadata.detail.requested_by`
  2. `metadata.record.person`
  3. top-level `metadata.person`
  4. other normalized sender or counterparty fields when present

- `evidence_checked` source order:
  1. `metadata.detail.checked_evidence`
  2. `metadata.record.evidence`
  3. top-level `metadata.evidence`
  4. fallback synthesized items from `source_id`, `source_occurred_at`, `due_at`, and status fields

- `open_loop_reason` source order:
  1. `metadata.detail.open_loop_reason`
  2. top-level `metadata.why_now`
  3. top-level `metadata.context_brief`
  4. derived explanation from persisted factors such as unresolved status, missing completion evidence, due date, and delivery outcomes

Derived explanations must include `factors`, so the renderer and Telegram explanation path can disclose why the reason was inferred.

### 5.3 Category Coverage

- Every open insight category uses the same accordion affordance.
- Commitment-style categories such as `commitment_unresolved` and `meeting_follow_up` should render the richest detail because current metadata already supports them.
- Less-structured categories such as `tone_risk` or `product_opportunity` may show reconstructed promise text, partial evidence, and a derived reason.
- v1 does not create category-specific detail layouts.

## 6. Data And Domain Model

### 6.1 Normalized Detail View Model

The preferred normalization module is `Maraithon.Insights.Detail`.

```elixir
%{
  promise_text: %{text: String.t(), origin: :stored | :reconstructed} | nil,
  requested_by: %{text: String.t(), origin: :stored | :derived} | nil,
  evidence_checked: [
    %{
      kind: :source_evidence | :record_status | :deadline | :delivery | :other,
      label: String.t(),
      detail: String.t() | nil,
      occurred_at: DateTime.t() | nil,
      source_ref: String.t() | nil
    }
  ],
  delivery_evidence: [
    %{
      channel: String.t(),
      destination_label: String.t() | nil,
      status: String.t(),
      sent_at: DateTime.t() | nil,
      feedback: String.t() | nil,
      feedback_at: DateTime.t() | nil,
      error_message: String.t() | nil
    }
  ],
  open_loop_reason: %{
    text: String.t(),
    origin: :stored | :derived,
    factors: [String.t()],
    evaluated_at: DateTime.t() | nil
  } | nil,
  data_gaps: [String.t()]
}
```

### 6.2 Source Precedence And Compatibility

The reader must remain backward-compatible with current data. Source precedence is:

1. `metadata.detail.*`
2. `metadata.record.*`
3. current top-level metadata such as `why_now`, `evidence`, `person`, `commitment`, `status`, `deadline`, `context_brief`
4. core insight fields such as `title`, `summary`, `recommended_action`, `due_at`, `source_id`, and `source_occurred_at`
5. related `insight_deliveries`

The writer path may become more structured over time, but the reader must treat older insights as first-class inputs.

### 6.3 Delivery Presentation And Privacy Contract

The dashboard must never render raw `Delivery.destination`. It renders a safe `destination_label` only.

| Channel | `destination_label` rule in v1 |
|---|---|
| `telegram` | `Telegram linked chat` |
| Known future channel with safe human label stored in delivery metadata | Render the stored safe label |
| Any other channel | Render `<Channel> destination` using the channel name only |

Additional privacy rules:

- Do not show raw chat ids, email addresses, Slack channel ids, or opaque provider ids in the dashboard detail body.
- `provider_message_id` is not displayed in v1.
- `error_message` may be shown only after truncation or normalization if the raw string includes destination-like content.

### 6.4 Writer-Side Metadata Contract

New or updated emitters should populate a stable block under `metadata.detail` when practical:

```json
{
  "detail": {
    "promise_text": "Send the revised pricing doc to Sarah by Friday.",
    "requested_by": "Sarah Chen",
    "open_loop_reason": "The thread contains the promise and a deadline, but no sent artifact or follow-up reply confirms delivery.",
    "checked_evidence": [
      {
        "kind": "source_evidence",
        "label": "Promise stated in email thread",
        "detail": "I'll send the revised pricing doc by Friday.",
        "source_ref": "gmail:thread:abc123"
      },
      {
        "kind": "deadline",
        "label": "Deadline passed",
        "detail": "Due 2026-03-11T17:00:00Z"
      }
    ],
    "evaluated_at": "2026-03-12T13:55:10Z"
  }
}
```

The first writer to upgrade should be [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex), because it already emits the richest follow-through metadata. No historical backfill is required.

## 7. Backend / Service / Context Changes

### 7.1 Detail Builder Responsibilities

`Maraithon.Insights.Detail` should own:

- normalization of `Insight` plus deliveries into the detail view model
- fallback reconstruction rules
- privacy-safe delivery label generation
- derived-reason factor generation
- helper functions for condensed explanation text reuse

The detail builder must not:

- fetch provider data
- invoke the model
- mutate persisted insights

### 7.2 Context Query Contract

Add a new function such as:

```elixir
list_open_with_details_for_user(user_id, opts \\ []) ::
  [%{insight: Insight.t(), detail: map()}]
```

Required behavior:

- preserve the same filtering and ordering as `list_open_for_user/2`
- batch-load deliveries in one query for the returned insight ids
- group deliveries by `insight_id`
- build detail payloads without N+1 queries

`list_open_for_user/2` must remain unchanged because it is still used by other flows, including delivery staging.

### 7.3 Shared Explanation Parity

The dashboard and Telegram explanation flows must share the same source contract:

- The dashboard renders the full normalized detail payload.
- `TelegramRouter.explain_insight/3` should use the same detail builder or a helper built on top of it, such as `Maraithon.Insights.Detail.summary_text/1`.
- If the fallback logic for `open_loop_reason` or `evidence_checked` changes, both surfaces pick up the change together.

Telegram can still render a compact text response, but it must derive that response from the same normalized inputs used by the dashboard.

### 7.4 Refresh-Safe LiveView State

`DashboardLive` should add:

- `expanded_insight_ids` to track currently open cards
- `detail_opened_insight_ids` to track cards that were opened at least once during the current LiveView session
- `toggle_insight_detail` event for UI interaction

`detail_opened_insight_ids` exists for telemetry and does not drive rendering. This keeps action-after-expansion analytics correct even if the user collapses a card before clicking `acknowledge`, `snooze`, or `dismiss`.

## 8. Frontend / UI / Rendering Changes

### 8.1 Dashboard Card View Model

Replace the current `@insights` list of plain schema structs with a list of card maps:

```elixir
%{
  insight: %Insight{},
  detail: %{...}
}
```

Rendering rules:

- top-level card summary remains unchanged
- the detail body is appended inline beneath the summary block
- action buttons stay in the same relative location
- the accordion body does not change card ownership, routing, or actions

### 8.2 Section Rendering Rules

- `Exact promise` shows the stored or reconstructed text with a small origin badge.
- `Who asked` shows the requester text with an origin badge when derived.
- `Evidence checked` renders concise bullets ordered by `occurred_at` when present.
- `Delivery evidence checked` renders a short timeline or list. Each row shows `channel`, `destination_label`, `status`, timestamps, feedback, and any safe error text.
- `Why Maraithon still thinks this is open` renders the reason text and, for derived reasons, a small factor list.
- `Data gaps` renders only when `data_gaps` is non-empty.

### 8.3 Interaction Constraints

- The detail toggle must be a button, not a link.
- Expanding or collapsing a card must not interfere with other cards.
- If an action removes the current card from the refreshed result set, the card disappears normally and leaves no stale expansion state behind.
- If an expanded card remains present after refresh, it stays open and shows the latest normalized detail payload.

## 9. Observability And Instrumentation

### 9.1 Telemetry Event Contract

Emit the following events via `:telemetry.execute/3`:

| Event | Measurements | Metadata | Emission point |
|---|---|---|---|
| `[:maraithon, :dashboard, :insight_detail, :expanded]` | `%{count: 1}` | `category`, `reason_origin`, `has_promise_text`, `data_gap_count`, `has_delivery_evidence` | when a card is expanded |
| `[:maraithon, :dashboard, :insight_detail, :collapsed]` | `%{count: 1}` | `category`, `reason_origin`, `has_promise_text`, `data_gap_count`, `has_delivery_evidence` | when a card is collapsed |
| `[:maraithon, :dashboard, :insight_detail, :action]` | `%{count: 1}` | `action`, `category`, `reason_origin`, `detail_opened_before_action`, `has_delivery_evidence` | when `acknowledge`, `snooze`, or `dismiss` succeeds |
| `[:maraithon, :dashboard, :insight_detail, :coverage]` | `%{insight_count: n, with_promise_text: n, with_any_reason: n, with_stored_reason: n, with_delivery_evidence: n}` | `source: :dashboard_refresh` | after each insight refresh completes |

### 9.2 Derived Indicators

These events must support:

- expansion rate on open insights
- action-after-expansion rate
- dismiss-without-expansion rate
- percentage of open insights with stored promise text
- percentage of open insights with stored or derived rationale
- percentage of open insights with at least one delivery record shown

### 9.3 Telemetry Integration Note

The implementation must emit the events even if no custom metrics reporter is configured yet. Adding explicit entries in [`lib/maraithon_web/telemetry.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/telemetry.ex) is recommended but not the source-of-truth requirement; the source-of-truth requirement is event emission plus tests that assert those events fire with the expected metadata.

## 10. Failure Modes, Edge Cases, And Backward Compatibility

| Risk | Safeguard |
|---|---|
| Historical insights missing structured metadata | Render partial sections plus `data_gaps`; never hide the accordion completely |
| N+1 delivery lookups | Batch-query deliveries by insight id before normalization |
| Raw destination leakage | Render `destination_label` only; never render raw `destination` |
| Derived rationale sounds too certain | Label as derived and expose the `factors` list |
| Delivery exists but completion proof is absent | Show delivery history and open-loop reason side by side |
| Periodic refresh invalidates expanded ids | Intersect state with currently visible ids on every refresh |
| Dashboard and Telegram explanations drift | Share one detail builder or helper contract |
| Unknown future channel appears in `Delivery` | Fall back to generic `<Channel> destination` label without exposing raw destination |

Backward compatibility rules:

- `Insights.list_open_for_user/2` remains available and unchanged.
- The first implementation must work without `metadata.detail`.
- Historical insights are interpreted at read time; no migration or backfill is required for v1.

## 11. Rollout / Migration Plan

### 11.1 Phase 1: Reader-First Launch

Ship together:

- the detail builder
- the new context query
- the dashboard accordion UI
- the refresh-safe state behavior
- the Telegram explanation parity change
- the telemetry events

Phase 1 uses existing persisted data only. No writer upgrades are required to launch the feature.

### 11.2 Phase 2: Writer Enrichment

Incrementally update emitters to populate `metadata.detail`, starting with `InboxCalendarAdvisor`.

Writer enrichment goals:

- reduce reconstruction
- improve requester and promise fidelity
- provide more stable evidence bullets
- provide a stored `open_loop_reason` when available

### 11.3 No Backfill Policy

- No historical backfill job is required for this feature.
- Older rows continue to render via the reader fallback path.
- If future telemetry shows poor coverage for key fields, the next iteration may propose targeted backfills, but that is out of scope here.

### 11.4 Rollback Safety

If the UI needs to be rolled back, the product can remove the accordion render path and continue using the existing summary cards because the feature does not change the underlying insight schema or core open-insight query contract.

## 12. Test Plan And Validation Matrix

### 12.1 Required Test Layers

- Unit tests for `Maraithon.Insights.Detail`
- Context tests for `list_open_with_details_for_user/2`
- LiveView tests for dashboard interaction and refresh semantics
- Explanation-parity tests for Telegram reuse of the normalized detail contract
- Telemetry tests asserting emitted events and metadata

### 12.2 Required Test Cases

- current `metadata.record.*` follow-through payloads
- newer `metadata.detail.*` payloads
- insights with delivery records
- insights without delivery records
- derived rationale fallback
- partial-data cases
- expanded cards stay expanded across refresh when the same ids remain visible
- stale expanded ids are pruned when cards disappear after `acknowledge`, `snooze`, or `dismiss`
- card order changes do not move expansion state to the wrong card
- raw `destination` values are not shown in the dashboard
- Telegram explanation text stays consistent with the detail builder's `open_loop_reason` and evidence inputs

### 12.3 Validation Matrix

| Scenario | Expected result | Test layer |
|---|---|---|
| Expand a commitment-style insight | All major sections render with stored content when present | LiveView |
| Expand a sparse non-commitment insight | Accordion renders partial detail plus `data_gaps` | LiveView |
| Refresh while one card is expanded | Same insight remains expanded if still present | LiveView |
| Acknowledge an expanded insight | Card disappears if no longer open; stale state is pruned | LiveView |
| Historical insight without `metadata.detail` | Builder falls back to `metadata.record` or reconstructed fields | Unit |
| Delivery row exists with raw Telegram chat id | UI shows `Telegram linked chat`, not raw id | Unit / LiveView |
| Telegram "why did you send this?" | Uses same normalized reason and evidence contract as dashboard | Unit / Integration |
| Coverage event after refresh | Counts reflect current visible cards | Telemetry |

### 12.4 Verification Gates

- Run `mix test`.
- Run `mix precommit`.
- Review the final implementation against this spec before moving the manifest out of `specs`.

## 13. Definition Of Done

- [ ] `Maraithon.Insights.Detail` exists and normalizes current persisted insight metadata plus deliveries.
- [ ] `Insights.list_open_with_details_for_user/2` exists and preserves current ordering and filtering.
- [ ] Dashboard cards render the accordion inline without breaking existing actions.
- [ ] Expanded state survives refresh for retained ids and is pruned for removed ids.
- [ ] Telegram explanation uses the same detail contract or a helper built directly on top of it.
- [ ] Delivery evidence never exposes raw `destination` values.
- [ ] Telemetry events fire with the documented metadata.
- [ ] Unit, context, LiveView, parity, and telemetry tests cover the validation matrix.
- [ ] `mix test` passes.
- [ ] `mix precommit` passes, or any existing unrelated failure is recorded explicitly before handoff.

## 14. Open Questions And Assumptions

No blocking product questions remain for this upgrade. The spec makes the following explicit assumptions:

- Every open insight card gets the same accordion affordance, even if some categories only have partial evidence on day one.
- Showing explicit data gaps is better for trust than hiding unavailable sections entirely.
- Detail expansion state does not persist across full page reloads or navigation in v1.
- Telegram is the only currently staged delivery channel, but the privacy contract must already be safe for future channels.
