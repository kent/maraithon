# Personal Assistant Agent Travel Prep

Status: Implemented v1
Purpose: Define an email-first Personal Assistant Agent that detects upcoming travel from Gmail, reconciles it against required Google Calendar evidence, and sends a structured Telegram trip brief the day before travel.
Depends on: [unified-telegram-operator-chat.md](/Users/kent/bliss/maraithon/docs/spectacula/specs/unified-telegram-operator-chat.md)

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon already has the building blocks for proactive operator help:

- connected Google and Telegram accounts
- Gmail and Calendar ingestion
- long-running user-scoped agents
- durable scheduled wakeups
- unified Telegram push delivery

What it does not have is a travel-aware assistant flow.

Today, if a user receives a flight confirmation and a hotel confirmation in email, Maraithon does not:

- recognize those messages as belonging to one upcoming trip
- assemble the practical details into one clean itinerary
- decide that the trip starts tomorrow
- proactively push a useful travel summary into Telegram

The desired behavior is specific and high-value: the day before travel, Maraithon should notice the upcoming trip and send a concise summary like the reference screenshot, with the flight and hotel details the operator actually needs.

### 1.2 Goals

- Add a new `personal_assistant_agent` behavior focused on proactive personal-assistant workflows, with travel prep as the first shipped slice.
- Make Gmail the primary source of truth for flight and hotel detection in v1.
- Require Google Calendar as corroboration and enrichment in v1, without making Calendar the source of record.
- Persist travel itineraries so detection, reconciliation, scheduling, and dedupe are durable across wakeups and restarts.
- Send a structured Telegram travel brief the day before the trip through the existing unified Telegram push path.
- Keep the brief actionable and compact: flight, hotel, dates, booking references, address, and contact details when present.
- Preserve the Telegram thread so the user can reply and continue the conversation from the pushed brief.

### 1.3 Non-Goals

- Building a fully general consumer personal assistant in v1.
- Booking, changing, or canceling travel reservations.
- Real-time delay tracking, gate changes, boarding alerts, or check-in automation.
- Parsing attachment-only itineraries such as PDFs when the email body lacks usable travel details.
- Supporting multi-user shared itineraries, family travel, or delegate workflows.
- Adding ground transportation, restaurant bookings, or packing lists in v1.

### 1.4 Product Decisions From This Request

- The product surface is a proactive "Personal Assistant Agent", not a one-off hardcoded notifier.
- The first workflow for that agent is travel prep.
- Gmail is the primary detection source.
- Calendar is required in v1 and is primarily used for corroboration, destination inference, and timezone help.
- Telegram is the outbound delivery channel.
- The target output is a screenshot-like structured message, not a generic insight title plus summary.
- Material itinerary changes after the first brief trigger a follow-up Telegram update.
- Send timing is computed per itinerary based on local trip timing, rather than configured as one fixed send hour.

## 2. Current State and Problem

### 2.1 Relevant Existing Systems

Relevant modules and artifacts:

- [`/Users/kent/bliss/maraithon/lib/maraithon/connections.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connections.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/connected_accounts.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connected_accounts.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/oauth/google.ex`](/Users/kent/bliss/maraithon/lib/maraithon/oauth/google.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/connectors/gmail.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/gmail.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/connectors/google_calendar.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/google_calendar.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/runtime/agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/runtime/agent.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/runtime/scheduler.ex`](/Users/kent/bliss/maraithon/lib/maraithon/runtime/scheduler.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/behaviors/founder_followthrough_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/founder_followthrough_agent.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/behaviors/chief_of_staff_brief_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/chief_of_staff_brief_agent.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/briefs.ex`](/Users/kent/bliss/maraithon/lib/maraithon/briefs.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/push_broker.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/push_broker.ex)

What already exists:

| Area | Current state |
|---|---|
| Google connection model | Gmail and Calendar are already represented as Google service splits in the connector dashboard. |
| Gmail ingestion | Gmail push watch setup and recent message fetch are implemented. |
| Calendar ingestion | Calendar push watch setup and event listing are implemented. |
| Agent runtime | User-scoped long-running agents can subscribe to topics, wake up on a schedule, persist state, and emit artifacts. |
| Proactive Telegram delivery | Insights and briefs already route through the Telegram assistant push broker. |
| Travel-adjacent precedent | The founder follow-through stack already scans Gmail and Calendar, persists structured findings, and sends Telegram briefs. |

### 2.2 Current Gaps

| Gap | Why it matters |
|---|---|
| No travel classification layer | Gmail messages are not currently classified as flight or hotel confirmations. |
| No itinerary domain model | There is nowhere to persist and reconcile a trip across multiple emails and Calendar evidence. |
| No day-before travel trigger | The runtime does not currently decide "you travel tomorrow" as a product event. |
| No travel-specific brief renderer | Existing insight and brief payloads are generic and do not produce the screenshot-style itinerary message. |
| No material-change tracking for a sent trip | The system cannot tell whether a later email updates or cancels an already-briefed itinerary. |

### 2.3 Why Existing Features Are Not Enough

The existing follow-through agent is about commitments, reply debt, meeting follow-ups, and recurring chief-of-staff summaries. It is not a reservation aggregator.

The existing Telegram assistant can answer questions about connected systems, but it does not proactively assemble travel details without a dedicated travel detection and scheduling flow.

The system therefore lacks the middle layer that turns raw travel emails into one high-confidence outbound assistant moment.

## 3. Scope and System Boundary

### 3.1 In Scope for v1

- A new agent behavior named `personal_assistant_agent`.
- Travel-prep detection for flights and hotels.
- Gmail-based extraction of reservation details from recent confirmation emails.
- Calendar-based corroboration and enrichment from required Google Calendar access.
- Durable itinerary persistence and dedupe.
- One day-before Telegram travel brief per itinerary.
- Reply-thread continuity by routing the brief through the unified Telegram push broker.
- Builder and connector UX changes needed to configure and launch this behavior.

### 3.2 Out of Scope for v1

- Airline status polling after the initial brief.
- Train, rental car, rideshare, restaurant, and meeting-room bookings.
- Attachment OCR, PDF parsing, or image understanding.
- Shared/team itinerary summaries.
- Automatic follow-up correction pushes for every minor travel update.
- Auto-provisioning the agent for every user by default.

### 3.3 Boundary Rules

- Email is the primary evidence source. Calendar corroboration is required in v1, but it does not override a newer reservation email unless the email explicitly states cancellation.
- Telegram delivery must reuse the existing assistant push thread model rather than a new direct-send side channel.
- v1 remains read-only against external travel systems.
- The first release is single-user and assumes one linked Telegram chat per user.

## 4. UX and Interaction Model

### 4.1 Trigger Contract

The user-visible contract is:

1. The Personal Assistant Agent watches Gmail continuously via event-driven wakeups and fallback scans.
2. It groups flight and hotel confirmations into an itinerary.
3. When the itinerary starts tomorrow in the user's local planning timezone, it prepares one travel brief.
4. The brief is delivered to Telegram at a computed day-before send time based on the itinerary start.

Default delivery timing for v1 is heuristic rather than fixed:

- departures before 8:00 AM local target a 6:00 PM local send the prior day
- departures before noon target a 5:00 PM local send the prior day
- departures before 6:00 PM target a 4:00 PM local send the prior day
- evening departures target a noon local send the prior day
- if the itinerary becomes ready after the computed send time but before travel begins, the brief should send immediately
- `travel_min_confidence` remains `0.80` by default for outbound delivery

If the itinerary is discovered too late on the night before travel, the system should still send the brief immediately as long as the trip has not started.

### 4.2 Message Contract

The message should feel like a clean operator brief, not like a raw parser dump.

Required rendering rules:

- Begin with a concise sentence that frames the brief as tomorrow's travel.
- Include separate sections for `FLIGHT` and `HOTEL` when both exist.
- Omit empty sections rather than showing placeholders.
- Show dates and times in the local timezone of the flight departure or hotel venue when known.
- Include booking or itinerary references when present.
- Include hotel phone and address when present.
- Do not include raw email metadata, message IDs, or parser confidence numbers.

Reference shape:

```text
Hey Kent! Here are your travel details for tomorrow (Mar 15):

FLIGHT
Air Canada AC 743 / UA 8272
Toronto YYZ -> San Francisco SFO
Sun, Mar 15, 2026
Booking Ref: BRSZC4

HOTEL
Courtyard by Marriott San Francisco Downtown/Van Ness Ave.
1050 Van Ness Avenue, San Francisco, CA 94109
Check-in: Sun, Mar 15 @ 3:00 PM
Check-out: Wed, Mar 18 @ Noon
Room: 1 King Bed
Itinerary #: 72072167688955
Hotel Phone: (415) 673-4711
```

The exact wording may vary, but the message must preserve this density and structure.

### 4.3 Threading and Follow-Up

The travel brief is sent as an assistant push through the existing Telegram push broker. That means:

- it creates or continues a push thread in the Telegram conversation store
- the user can reply to the brief directly
- later assistant replies can use the itinerary as the active context

v1 does not require custom travel write actions in the reply thread. Read-only follow-up, such as "what hotel is this?" or "what's the booking code?", is sufficient.

### 4.4 Copy Style

- Be concise, practical, and low-drama.
- Prefer details over commentary.
- Avoid marketing language and internal jargon.
- Do not mention "agent", "parser", "LLM", "confidence", or "inference" in the user-facing message.

## 5. Functional Requirements

### 5.1 Account Requirements

| Account or scope | Requirement level | Purpose |
|---|---|---|
| Google Gmail | Required | Primary travel detection source |
| Telegram | Required | Day-before push delivery |
| Google Calendar | Required | Corroboration, timezone help, and destination context |

Builder validation rules:

- launching `personal_assistant_agent` without Gmail must fail validation
- launching without Telegram must fail validation
- launching without Calendar must fail validation

### 5.2 Email Candidate Identification

The agent must evaluate recent Gmail messages for travel relevance using deterministic heuristics first.

Candidate signals include:

- sender domains commonly associated with airlines, hotels, travel agencies, or itinerary aggregators
- subjects containing terms such as `flight`, `hotel`, `reservation`, `booking`, `itinerary`, `trip`, `check-in`, or `confirmation`
- body patterns such as airport codes, confirmation codes, check-in/check-out labels, property addresses, room types, and itinerary numbers
- structured email markers such as `Booking Ref`, `Confirmation Number`, `Check-in`, `Departure`, or `Arrival`

The agent must not run expensive extraction across the entire inbox. It should:

- narrow the candidate set using Gmail queries and deterministic scoring
- fetch richer content only for likely travel messages
- keep a per-user watermark so repeated scans do not reprocess the entire history

### 5.3 Extraction Contract

After candidate selection, the system extracts normalized travel items.

v1 item types:

| Item type | Minimum required fields |
|---|---|
| `flight` | airline or carrier label, departure date or datetime, origin, destination |
| `hotel` | property name, check-in date or datetime, check-out date or datetime or stay length |

Preferred fields:

| Item type | Preferred fields |
|---|---|
| `flight` | flight number, confirmation code, operating carrier, arrival time, terminal, seat, passenger name |
| `hotel` | address, room type, confirmation or itinerary number, hotel phone, cancellation deadline |

Extraction strategy:

1. deterministic field extraction for obvious labels and patterns
2. LLM fallback only for messages that passed deterministic candidate scoring but remain partially parsed
3. normalization into typed itinerary items with evidence pointers back to Gmail message IDs

The LLM path must use a strict JSON shape and reject non-conforming responses rather than silently accepting freeform text.

### 5.4 Itinerary Reconciliation

The system must reconcile multiple travel items into one itinerary record.

Reconciliation inputs:

- confirmation codes
- travel dates
- destination city or venue
- email thread relationships
- vendor identity
- Calendar events around the same dates

Rules:

- one trip may contain multiple flight segments and one or more hotel items
- hotel-only itineraries are allowed
- one-way flight-only itineraries are allowed
- the same source email must not create duplicate items across rescans
- later emails may update an existing item instead of creating a new one

Itinerary status values:

| Status | Meaning |
|---|---|
| `collecting` | Candidate items exist but the trip is not ready for a brief |
| `ready` | Enough data exists to send the day-before brief when timing matches |
| `brief_sent` | The primary travel brief was already sent |
| `changed_after_send` | New evidence materially changed the itinerary after send |
| `cancelled` | A later email clearly cancelled the trip or reservation |

### 5.5 Calendar Corroboration

Because Calendar is required in v1, the agent must search a bounded event window around the itinerary dates.

Calendar is used to:

- confirm that the travel dates align with a known trip or meeting
- infer the operator's likely local planning timezone when needed
- improve destination labels when hotel or flight emails are incomplete
- raise confidence when email and calendar both point to the same trip

Calendar must not create a travel itinerary by itself in v1. Without email evidence, no travel brief is sent.

### 5.6 Day-Before Eligibility

An itinerary is eligible for a travel brief when all of these are true:

- status is `ready`
- confidence is at or above `travel_min_confidence`
- the itinerary's earliest start anchor is tomorrow in the operator planning timezone
- no prior brief exists for that itinerary and travel date
- the itinerary is not cancelled

The earliest start anchor is determined by:

1. first flight departure when any flight exists
2. otherwise first hotel check-in

### 5.7 Delivery and Dedupe

Outbound delivery should reuse the existing brief and Telegram push infrastructure.

Required behavior:

- the agent records a `Brief` with `cadence: "travel_prep"` and metadata containing the itinerary ID
- `Briefs.dispatch_telegram_batch/1` or the unified push path delivers the message
- dedupe key format is `travel_prep:<itinerary_id>:<local_trip_date>`
- once the message is sent, the itinerary transitions to `brief_sent`

If a material update arrives after send and before travel begins, the itinerary must transition to `changed_after_send` and queue a corrective follow-up push through the same Telegram delivery path.

### 5.8 Read-Only Travel Context in Telegram

When the user replies to a travel brief, the Telegram assistant should be able to inspect the stored itinerary and answer follow-up questions without rereading Gmail from scratch.

That requires:

- the push turn to store the linked itinerary ID in structured data or metadata
- the Telegram assistant context assembly to load the linked itinerary when the reply thread originates from a travel brief

## 6. Data and Domain Model

### 6.1 New Persistence

Add a new `Maraithon.Travel` context with two schemas:

- `travel_itineraries`
- `travel_itinerary_items`

### 6.2 `travel_itineraries`

| Field | Type | Notes |
|---|---|---|
| `id` | `:binary_id` | Primary key |
| `user_id` | `:string` | Owner |
| `agent_id` | `:binary_id` | Agent that manages the itinerary |
| `status` | `:string` | `collecting`, `ready`, `brief_sent`, `changed_after_send`, `cancelled` |
| `title` | `:string` | Human summary such as `Toronto -> San Francisco` |
| `destination_label` | `:string` | Best available destination label |
| `planning_timezone` | `:string` | User-local planning timezone or fallback |
| `starts_at` | `:utc_datetime_usec` | Earliest travel anchor |
| `ends_at` | `:utc_datetime_usec` | End of stay if known |
| `confidence` | `:float` | Normalized itinerary confidence |
| `briefed_for_local_date` | `:date` | Date already briefed |
| `last_evidence_at` | `:utc_datetime_usec` | Latest supporting email or calendar evidence |
| `metadata` | `:map` | Evidence summary, source counts, and rendering extras |

Indexes:

- `user_id + starts_at`
- `user_id + status`
- partial or composite lookup for `user_id + briefed_for_local_date + status`

### 6.3 `travel_itinerary_items`

| Field | Type | Notes |
|---|---|---|
| `id` | `:binary_id` | Primary key |
| `travel_itinerary_id` | `:binary_id` | Parent itinerary |
| `item_type` | `:string` | `flight` or `hotel` |
| `status` | `:string` | `active`, `updated`, `cancelled`, `superseded` |
| `source_provider` | `:string` | `gmail` or `google_calendar` |
| `source_message_id` | `:string` | Gmail message ID when present |
| `source_thread_id` | `:string` | Gmail thread ID when present |
| `fingerprint` | `:string` | Stable dedupe key for rescans |
| `vendor_name` | `:string` | Airline or hotel brand |
| `title` | `:string` | One-line summary |
| `confirmation_code` | `:string` | Booking or itinerary reference |
| `starts_at` | `:utc_datetime_usec` | Departure or check-in |
| `ends_at` | `:utc_datetime_usec` | Arrival or check-out |
| `location_label` | `:string` | Route or property location |
| `confidence` | `:float` | Item-level extraction confidence |
| `metadata` | `:map` | Route details, address, room, phone, evidence snippets |

Unique constraint:

- `travel_itinerary_id + fingerprint`

### 6.4 Outbound Artifact Reuse

No new outbound delivery table is required in v1.

The feature should reuse:

- [`/Users/kent/bliss/maraithon/lib/maraithon/briefs.ex`](/Users/kent/bliss/maraithon/lib/maraithon/briefs.ex) for durable pending/sent brief records
- [`/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/push_broker.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/push_broker.ex) for unified Telegram delivery and thread persistence

## 7. Backend / Service / Context Changes

### 7.1 New Behavior Registration

Add a new behavior:

- `Maraithon.Behaviors.PersonalAssistantAgent`

Register it in:

- [`/Users/kent/bliss/maraithon/lib/maraithon/behaviors.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors.ex)
- [`/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex)

Initial builder-facing scope for this behavior is explicitly "travel prep from Gmail and Calendar".

### 7.2 New Travel Context Modules

Add modules under `lib/maraithon/travel/`:

- `travel.ex` context
- `travel/itinerary.ex`
- `travel/itinerary_item.ex`
- `travel/extractor.ex`
- `travel/reconciler.ex`
- `travel/brief_renderer.ex`

Responsibilities:

| Module | Responsibility |
|---|---|
| `Travel` | public CRUD/query surface |
| `Extractor` | candidate scoring and normalized item extraction |
| `Reconciler` | merge items into itineraries and detect material updates |
| `BriefRenderer` | produce screenshot-style Telegram body text from a ready itinerary |

### 7.3 Control Flow

The Personal Assistant Agent should combine event-driven updates with periodic scans.

Subscriptions:

- `email:<user_id>`
- `calendar:<user_id>`

Periodic fallback:

- wake up every 30-60 minutes to catch missed webhooks, late OAuth reconnects, and overdue send windows

Reference algorithm:

```text
on wakeup or inbound Gmail/Calendar event:
  ensure Gmail + Telegram are connected
  fetch new candidate Gmail messages since watermark
  score travel likelihood for each message
  extract normalized flight/hotel items from likely candidates
  reconcile items into persisted itineraries
  enrich eligible itineraries with Calendar evidence when available
  compute local "tomorrow" eligibility
  for each eligible itinerary not yet briefed:
    render travel brief
    record Brief(cadence = "travel_prep", dedupe_key = ...)
    mark itinerary brief_sent
  advance watermark
```

### 7.4 Gmail Query Strategy

The agent must not fetch the full inbox on every wakeup.

Default strategy:

- event-driven path: hydrate from Gmail webhook history and only inspect changed messages
- periodic path: bounded Gmail queries against recent mail, default 14-30 day lookback
- candidate expansion only for travel-like subjects, senders, or reservation content

Configurable launch fields:

| Field | Default | Meaning |
|---|---|---|
| `email_scan_limit` | `25` | Max candidate Gmail messages per cycle |
| `event_scan_limit` | `25` | Max Calendar events inspected per cycle |
| `lookback_hours` | `720` | Periodic scan window |
| `min_confidence` | `0.80` | Minimum itinerary confidence |
| `timezone_offset_hours` | `-5` | Planning timezone fallback |
| `wakeup_interval_ms` | `1800000` | Fallback scan cadence |

The send time itself is computed from the itinerary's local start time rather than exposed as a builder input in v1.

### 7.5 Rendering Contract

`Travel.BriefRenderer` owns the final Telegram body string.

Rules:

- deterministic ordering: flight section first, hotel section second
- stable field ordering inside each section
- omit missing lines instead of printing blanks
- render times in a human-readable local format
- escape text safely for Telegram HTML if HTML parse mode is used

### 7.6 Telegram Assistant Context Hook

When a brief is delivered, the stored conversation turn should include:

- `origin_type: "brief"`
- `structured_data["brief_type"] = "travel_prep"`
- `structured_data["travel_itinerary_id"] = <id>`

The Telegram assistant context loader should recognize that marker and preload the itinerary on replies to the brief.

## 8. Frontend / UI / Rendering Changes

### 8.1 Agent Builder

Add a new behavior card in the builder for `personal_assistant_agent`.

The builder must show:

- summary focused on proactive travel prep
- Gmail required
- Telegram required
- Calendar required
- config inputs for Gmail scan limit, Calendar scan limit, lookback, timezone fallback, minimum confidence, and wakeup cadence

### 8.2 Connectors UI

The connectors surface should make it obvious that this behavior depends on:

- Google Gmail
- Google Calendar
- Telegram

If Gmail is connected but Calendar is not, the UI should block launch until Calendar access is connected and ready.

### 8.3 No New Standalone Dashboard Page in v1

v1 does not require a dedicated travel dashboard. The primary UX is:

- configure the behavior in the builder
- receive the brief in Telegram
- optionally inspect the agent or connected accounts from existing pages

## 9. Observability and Instrumentation

Emit telemetry and logs for:

| Event | Measurements | Metadata |
|---|---|---|
| `travel.candidate_scored` | `count` | user, agent, score bucket |
| `travel.item_extracted` | `count` | item type, source provider |
| `travel.itinerary_reconciled` | `count` | status, confidence bucket |
| `travel.brief_queued` | `count` | itinerary id, local trip date |
| `travel.brief_sent` | `count` | itinerary id, delivery channel |
| `travel.brief_skipped` | `count` | skip reason |
| `travel.material_update_detected` | `count` | itinerary id, changed fields |

Operational logging should capture:

- missing account prerequisites
- extraction failures
- invalid LLM JSON extraction responses
- delivery failures
- duplicate suppression decisions

## 10. Failure Modes, Edge Cases, and Backward Compatibility

### 10.1 Incomplete Itinerary

If only partial data is available:

- create or keep the itinerary in `collecting`
- do not send the brief unless minimum confidence is met
- retain the evidence so later emails can complete the trip

### 10.2 Duplicate Reservation Emails

The same reservation often arrives as:

- original confirmation
- itinerary reminder
- check-in reminder
- forwarded copy

Fingerprinting and reconciliation must prevent duplicate sections in the brief.

### 10.3 Changed or Cancelled Travel

If a new email clearly changes dates, hotel, or carrier before the trip:

- update the itinerary
- mark it `changed_after_send` if the brief already went out
- record the change for operator audit
- queue a `travel_update` Telegram brief with the latest itinerary snapshot

If a later email clearly cancels the trip:

- mark the relevant items and itinerary `cancelled`
- suppress any unsent brief

### 10.4 Calendar Missing or Wrong

Calendar mismatch must lower confidence or provide no enrichment. It must not override stronger email evidence.

If Calendar access is unavailable at runtime, the agent should skip outbound travel prep for that cycle and retry on the next wakeup after the connection is restored.

### 10.5 No Telegram Connection

The agent must not attempt delivery if Telegram is missing. Builder validation should prevent launch, but runtime checks should still degrade safely.

### 10.6 Backward Compatibility

- existing insights and chief-of-staff briefs must continue working unchanged
- the new `travel_prep` brief cadence must not break existing brief rendering
- users without the new behavior launched should see no behavior change

## 11. Rollout / Migration Plan

### 11.1 Phase 1

- add travel schemas and context
- add `personal_assistant_agent`
- add builder support
- support flight and hotel detection from Gmail
- render and deliver one day-before travel brief

### 11.2 Phase 2

- add more reservation types
- improve parser coverage for forwarded or noisier itinerary emails
- improve the diff copy in `travel_update` pushes so changes are summarized more explicitly

### 11.3 Data Migration

Add migrations for:

- `travel_itineraries`
- `travel_itinerary_items`

No backfill is required. The agent can build itineraries incrementally from the next scan window.

## 12. Test Plan and Validation Matrix

### 12.1 Unit Tests

- candidate scoring for travel-like and non-travel-like emails
- deterministic extraction of obvious flight and hotel labels
- reconciliation across duplicate or reminder emails
- day-before eligibility across timezone boundaries
- brief rendering with missing optional fields

### 12.2 Integration Tests

- Gmail event -> itinerary creation -> brief queued
- hotel-only itinerary -> brief sent
- flight + hotel itinerary -> both sections rendered in order
- Calendar-connected itinerary -> confidence/enrichment improves
- Telegram push thread stores `travel_itinerary_id` and supports reply follow-up
- material itinerary change after initial brief -> `travel_update` brief queued

### 12.3 Validation Matrix

| Scenario | Expected result |
|---|---|
| Flight confirmation email arrives 3 days before trip | itinerary stored, no brief yet |
| Hotel confirmation arrives later for same trip | itinerary updated, one combined brief later |
| Trip starts tomorrow and confidence is high | one Telegram travel brief sent |
| Same itinerary reminder email arrives again | no duplicate item and no duplicate brief |
| Calendar access is missing | launch is blocked or runtime skips outbound briefing until the connection is restored |
| Cancellation email arrives before send | brief suppressed |
| User replies to the brief in Telegram | assistant can inspect the stored itinerary context |

## 13. Definition of Done

- `personal_assistant_agent` exists and is launchable from the builder.
- Gmail, Calendar, and Telegram prerequisites are validated.
- Travel itineraries and itinerary items persist durably.
- Gmail-driven flight and hotel extraction works for the initial supported email shapes.
- Day-before eligibility and dedupe rules are implemented.
- Travel briefs are delivered through the unified Telegram assistant push path.
- Reply-thread context can load the linked itinerary.
- Automated tests cover extraction, reconciliation, scheduling, and delivery.
- Project verification passes for the implemented change set.

## 14. Resolved Decisions / Assumptions

### 14.1 Assumptions Used In This Draft

- The operator has one primary local planning timezone.
- The first release only needs flights and hotels.
- Gmail confirmation emails contain enough structured text for useful extraction without PDF parsing.
- A travel brief should be suppressed rather than sent when confidence is too low.
- Reusing the existing `Briefs` pipeline is preferable to creating a new outbound artifact type in v1.

### 14.2 Approved Decisions

- Calendar is required for the first release.
- v1 sends a corrective follow-up when a material itinerary change arrives after the first brief.
- The preferred travel send time is computed per itinerary based on local trip timing.
