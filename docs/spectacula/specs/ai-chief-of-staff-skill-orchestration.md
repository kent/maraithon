# AI Chief of Staff Skill-Orchestrated Agent Architecture

Status: Draft v1
Purpose: Define how Maraithon should expose one user-facing `AI Chief of Staff` agent that composes inbox triage, follow-through, travel logistics, and recurring briefing as built-in skills rather than separate standalone agents.

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon currently exposes multiple workflow agents that each feel like a separate product:

- `founder_followthrough_agent` for Gmail, Calendar, Slack, and recurring open-loop briefs
- `personal_assistant_agent` for travel preparation
- `chief_of_staff_brief_agent` for recurring brief generation from existing insights

That structure works for implementation velocity, but it does not match the operator mental model. The user does not want to assemble a personal operating system from multiple narrow agents. The user wants one capable Chief of Staff that notices important things, understands context across domains, and uses specialized capabilities internally.

This mismatch creates product and systems problems:

- the builder presents multiple overlapping choices instead of one coherent assistant
- Gmail and Calendar are scanned by more than one behavior for related workflows
- urgency policy is fragmented across separate behavior-specific pipelines
- Telegram delivery can feel like multiple products speaking rather than one assistant
- operator memory and preferences exist globally, but the runtime model is still behavior-siloed

The desired architecture is one user-facing `AI Chief of Staff` agent with internal skills such as follow-through, inbox triage, travel logistics, and briefing. Those skills should remain technically rigorous and structured, but they should no longer be user-facing products.

### 1.2 Goals

- Introduce a new top-level behavior named `ai_chief_of_staff` as the canonical operator-facing assistant.
- Move domain capabilities behind a first-class skill contract rather than exposing them as separate products.
- Preserve the current deterministic and structured logic for travel and follow-through rather than collapsing them into one giant prompt.
- Reduce duplicate provider scans by introducing shared source acquisition for Gmail, Calendar, and Slack.
- Unify prioritization, interruption policy, and Telegram delivery under one assistant persona.
- Make travel logistics, inbox triage, and follow-through feel like built-in capabilities of the same assistant.
- Provide a staged migration path that keeps existing agents working while the new architecture is adopted.

### 1.3 Design Principles

- One assistant, many skills. The operator should configure one Chief of Staff, not a cluster of overlapping assistants.
- Structured capabilities stay structured. Travel extraction, commitment tracking, and similar workflows should remain deterministic systems with explicit schemas.
- Shared inputs, specialized reasoning. Fetch provider data once when possible, then let specialized skills evaluate the same normalized bundle.
- Skill isolation with assistant coherence. A failing skill must not take down the whole assistant, but the operator should still experience one coherent product.
- Migrate by composition first. v1 should reuse the existing travel and follow-through modules before attempting deeper rewrites.

## 2. Current State and Constraints

### 2.1 Current Runtime Model

Relevant modules:

- [`lib/maraithon/behaviors.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors.ex)
- [`lib/maraithon/agent_builder.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex)
- [`lib/maraithon/behaviors/founder_followthrough_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/founder_followthrough_agent.ex)
- [`lib/maraithon/behaviors/personal_assistant_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/personal_assistant_agent.ex)
- [`lib/maraithon/behaviors/chief_of_staff_brief_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/chief_of_staff_brief_agent.ex)

Today the runtime model is behavior-centric:

- one `agents` row maps to one behavior string
- `Maraithon.Behaviors` resolves that behavior to one module
- `AgentBuilder` presents behaviors as launch-time templates
- each behavior owns its own config shape, wakeup cadence, connector expectations, and result emission

This means the product boundary is currently aligned to implementation modules.

### 2.2 Existing Reusable Building Blocks

The repo already contains capability modules that can become internal skills:

| Existing surface | Current purpose | Reuse value for AI Chief of Staff |
|---|---|---|
| `FounderFollowthroughAgent` | Composes inbox/calendar follow-through, Slack follow-through, and recurring brief generation | Strong precedent for orchestration of sub-capabilities inside one behavior |
| `InboxCalendarAdvisor` | Gmail and Calendar-based commitment, reply debt, and meeting follow-up reasoning | Candidate `followthrough` or `inbox_triage` skill core |
| `SlackFollowthroughAgent` | Slack commitment and reply-debt detection | Candidate `followthrough` skill sub-component |
| `ChiefOfStaffBriefAgent` | Generates morning, end-of-day, and weekly briefs from current insight state | Candidate `briefing` skill |
| `Travel` and `PersonalAssistantAgent` | Detects and reconciles travel itineraries, then queues Telegram travel briefs | Candidate `travel_logistics` skill |
| `PreferenceMemory` and Telegram assistant flows | Durable operator preferences and single chat thread context | Shared memory and delivery substrate for one assistant |

### 2.3 Current Gaps

| Gap | Why it matters |
|---|---|
| No first-class skill abstraction | Composition is ad hoc and tied to behavior-specific module wiring |
| No shared source bundle | Gmail and Calendar can be scanned separately by separate behaviors for adjacent workflows |
| Separate builder products for one operator job | The UI teaches the wrong mental model: multiple narrow agents instead of one assistant |
| No unified urgency arbitration across travel and follow-through | Travel logistics and reply debt do not compete in one prioritization model |
| The current `ChiefOfStaffBriefAgent` is not a true assistant root | It only renders summaries from insights and does not own scanning or orchestration |

### 2.4 Constraints

- Existing standalone behaviors must continue to work during migration.
- The runtime behavior contract should remain compatible with `init/1`, `handle_wakeup/2`, `handle_effect_result/3`, and `next_wakeup/1`.
- Telegram delivery should keep using existing insights and briefs infrastructure rather than adding a parallel delivery system.
- v1 should minimize connector fetch amplification and avoid introducing a second overlapping orchestration stack.

## 3. Product Model

### 3.1 User-Facing Contract

The operator-facing product should become:

`AI Chief of Staff`

What the operator believes they are configuring:

- one assistant
- one Telegram voice
- one place to express durable interruption and priority preferences
- one connector checklist
- one set of built-in capabilities that can be enabled or disabled

What the operator should not have to think about:

- which internal skill owns travel versus follow-through
- whether a reminder came from one behavior or another
- whether Gmail was scanned twice by different subsystems

### 3.2 Initial Skill Catalog

v1 skill catalog for `AI Chief of Staff`:

| Skill ID | Purpose | Primary inputs | Primary outputs |
|---|---|---|---|
| `followthrough` | Commitments, reply debt, unresolved artifacts, post-meeting loops | Gmail, Calendar, Slack | Insights, recurring open-loop summaries |
| `travel_logistics` | Flight, hotel, and itinerary preparation | Gmail, Calendar | Travel briefs, itinerary updates |
| `briefing` | Morning, end-of-day, weekly summaries that synthesize current open state | Existing insights and briefs | Scheduled brief artifacts |

Likely future skills:

- `meeting_prep`
- `relationship_watch`
- `operator_preferences`
- `document_briefing`

### 3.3 Capability Semantics

Important product rule:

- a skill is an internal capability, not a user-facing agent
- a skill may produce insights, briefs, state updates, or proposed actions
- all operator-visible surfaces should attribute those results to `AI Chief of Staff`, with optional internal metadata describing the originating skill

## 4. Scope and Non-Goals

### 4.1 In Scope

- A new `ai_chief_of_staff` behavior in the behavior registry and builder.
- A first-class internal skill contract for Chief of Staff capabilities.
- Skill wrappers or adapters around existing follow-through, Slack, travel, and briefing logic.
- A shared config model with `enabled_skills` and per-skill configuration.
- Shared source acquisition for Gmail, Calendar, and Slack in the target architecture.
- Unified prioritization and delivery arbitration across skills.
- Migration strategy from the current behavior catalog.
- Tests for orchestration, config validation, skill isolation, and backward compatibility.

### 4.2 Non-Goals

- Rewriting every existing capability from scratch in the first pass.
- Replacing deterministic travel extraction with a purely prompt-driven system.
- Removing legacy behaviors immediately.
- Designing a generic plugin marketplace for arbitrary third-party skills.
- Introducing cross-user delegation or multi-operator shared assistants in v1.

## 5. Proposed Architecture

### 5.1 New Top-Level Behavior

Add a new behavior:

- behavior ID: `ai_chief_of_staff`
- user-facing label: `AI Chief of Staff`

Responsibilities:

- own the top-level wakeup cycle
- gather shared provider context or delegate to a shared acquisition layer
- execute enabled skills against a shared runtime context
- merge outputs into the existing insights and briefs infrastructure
- arbitrate final interruption priority and delivery sequencing
- present one assistant identity to the operator

### 5.2 Chief Of Staff Skill Contract

Introduce a dedicated internal behavior-independent skill interface, for example:

- [`lib/maraithon/chief_of_staff/skill.ex`](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skill.ex)

Proposed callback shape:

```elixir
defmodule Maraithon.ChiefOfStaff.Skill do
  @type source_bundle :: map()
  @type run_result :: %{
          state: map(),
          effects: [map()],
          insights: [map()],
          briefs: [map()],
          observations: [map()],
          telemetry: map()
        }

  @callback id() :: String.t()
  @callback requirements() :: [map()]
  @callback default_config() :: map()
  @callback subscriptions(config :: map(), user_id :: String.t()) :: [String.t()]
  @callback init(config :: map()) :: map()
  @callback next_wakeup(skill_state :: map()) ::
              {:relative, non_neg_integer()} | {:absolute, DateTime.t()} | :none
  @callback run(bundle :: source_bundle(), skill_state :: map(), context :: map()) ::
              {:ok, run_result()} | {:error, term()}
  @callback handle_effect_result(effect_result :: map(), skill_state :: map(), context :: map()) ::
              {:ok, %{state: map(), effects: [map()]}} | {:error, term()}
end
```

Design rules:

- skills do not own the runtime process
- skills operate within one assistant-owned runtime context
- skills may request effects, but the orchestrator routes effect results back to the originating skill
- skills return structured records rather than directly calling Telegram or bypassing persistence

### 5.3 Shared Assistant State

The `ai_chief_of_staff` behavior state should look like:

```elixir
%{
  user_id: String.t(),
  enabled_skills: ["followthrough", "travel_logistics", "briefing"],
  skill_states: %{
    "followthrough" => map(),
    "travel_logistics" => map(),
    "briefing" => map()
  },
  inflight_effects: %{
    effect_id => %{skill_id: String.t(), effect_type: String.t(), metadata: map()}
  },
  source_watermarks: %{
    "gmail" => map(),
    "calendar" => map(),
    "slack" => map()
  },
  last_cycle_at: DateTime.t() | nil
}
```

### 5.4 Shared Source Acquisition

The most important architectural shift after skillization is shared source acquisition.

Add a source-gathering layer, for example:

- [`lib/maraithon/chief_of_staff/source_bundle.ex`](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/source_bundle.ex)
- [`lib/maraithon/chief_of_staff/acquisition.ex`](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/acquisition.ex)

The orchestrator should collect a normalized bundle once per cycle:

```elixir
%{
  "gmail" => %{
    "messages" => [map()],
    "threads" => %{thread_id => [map()]},
    "watermark" => map()
  },
  "calendar" => %{
    "events" => [map()],
    "watermark" => map()
  },
  "slack" => %{
    "messages" => [map()],
    "threads" => %{thread_ref => [map()]},
    "watermark" => map()
  },
  "operator_context" => %{
    "preferences" => map(),
    "timezone_offset_hours" => integer(),
    "now" => DateTime.t()
  }
}
```

Design rules:

- Gmail and Calendar should be fetched once per cycle whenever possible
- event-triggered wakeups may populate only a partial bundle, but the shape stays stable
- skills may request richer hydration for a bounded subset of candidate items
- the acquisition layer owns watermarks and event-to-bundle normalization rather than each skill reinventing them

### 5.5 Skill Execution Model

Execution order for v1:

1. `followthrough`
2. `travel_logistics`
3. `briefing`

Reasoning:

- follow-through and travel consume raw source bundle data
- briefing should run after earlier skills have had a chance to persist or stage new structured outputs

The orchestrator should:

- call enabled skills in deterministic order
- isolate failures so one broken skill does not abort the whole cycle
- collect outputs into one merged result
- record skill-level telemetry and errors
- decide whether the top-level runtime returns `:idle`, `:emit`, or `:effect`

### 5.6 Output Merge Contract

The orchestrator should merge skill outputs into a shared assistant result:

```elixir
%{
  insights: [map()],
  briefs: [map()],
  effects: [map()],
  observations: [map()],
  skill_results: %{
    "followthrough" => %{status: "ok", counts: map()},
    "travel_logistics" => %{status: "ok", counts: map()},
    "briefing" => %{status: "ok", counts: map()}
  }
}
```

Output rules:

- persisted insights continue to use the existing `insights` table
- persisted summaries continue to use the existing `briefs` table
- every persisted artifact should include metadata showing `assistant_behavior: "ai_chief_of_staff"` and `origin_skill: "<skill_id>"`
- Telegram and dashboard surfaces should render the assistant label while keeping origin-skill metadata available for debugging and detail views

### 5.7 Unified Prioritization

The new architecture must unify prioritization across skills.

Travel logistics, for example, must not be treated as generic transactional noise just because they originate from structured airline or hotel mail. Follow-through and travel should compete in one prioritization model.

Add an assistant-level urgency contract:

| Field | Meaning |
|---|---|
| `origin_skill` | Which skill produced the candidate |
| `category` | `reply_debt`, `commitment`, `travel_logistics`, `travel_change`, `briefing`, etc. |
| `operational_impact` | `low`, `medium`, `high`, `critical` |
| `time_sensitivity` | Relative timing risk such as `none`, `today`, `within_24h`, `immediate` |
| `interrupt_posture` | `interrupt_now`, `heads_up`, `digest_only`, `silent_persist` |
| `reply_obligation` | Relevant for follow-through categories |
| `requires_user_action` | Whether operator action is actually needed |

Assistant-level arbitration rules:

- if a travel item has imminent operational impact, it can outrank open-loop follow-through
- if a follow-through item is a false-positive risk or digest-only, it must not crowd out high-impact travel logistics
- the final Telegram queue should be shaped by assistant-level priority, not by whichever skill ran first

### 5.8 Builder And UI Model

The builder should present one primary workflow product:

- `AI Chief of Staff`

Builder behavior:

- enable a default skill pack: `followthrough`, `travel_logistics`, `briefing`
- allow advanced users to toggle skills on or off
- show the union of connector requirements for the enabled skills
- show per-skill advanced settings inside collapsible sections
- keep one global timezone and one global interruption policy

Proposed config shape:

```json
{
  "name": "AI Chief of Staff",
  "user_id": "kent@example.com",
  "enabled_skills": ["followthrough", "travel_logistics", "briefing"],
  "timezone_offset_hours": -5,
  "skill_configs": {
    "followthrough": {
      "email_scan_limit": 14,
      "event_scan_limit": 12,
      "channel_scan_limit": 80,
      "dm_scan_limit": 50,
      "min_confidence": 0.72
    },
    "travel_logistics": {
      "lookback_hours": 720,
      "email_scan_limit": 25,
      "event_scan_limit": 25,
      "min_confidence": 0.8
    },
    "briefing": {
      "morning_brief_hour_local": 8,
      "end_of_day_brief_hour_local": 18,
      "weekly_review_day_local": 5,
      "weekly_review_hour_local": 16,
      "brief_max_items": 3
    }
  }
}
```

### 5.9 Migration Pattern

The migration should happen in phases.

#### Phase 1: Composition Root

- add `ai_chief_of_staff` to the behavior registry
- implement an orchestrator behavior that wraps existing capability modules
- keep existing standalone behaviors untouched
- expose `AI Chief of Staff` in the builder

#### Phase 2: Skill Adapters

- wrap existing follow-through, travel, and briefing logic in the new skill contract
- preserve existing deterministic services such as `Travel.sync_recent_trip_data/3`
- preserve current persistence tables and rendering surfaces

#### Phase 3: Shared Acquisition

- move Gmail, Calendar, and Slack fetch orchestration into a shared source-bundle layer
- stop duplicating scans across internal skills
- add assistant-level arbitration before Telegram staging

#### Phase 4: Product Simplification

- make `AI Chief of Staff` the default recommended launch
- de-emphasize or hide legacy standalone behaviors from the primary builder flow
- keep legacy behaviors available for tests, admin use, or advanced manual setups until adoption is proven

## 6. Data and Domain Model

### 6.1 Agent Config

`ai_chief_of_staff` config must support:

| Field | Type | Notes |
|---|---|---|
| `name` | string | Agent display name |
| `user_id` | string | Required |
| `enabled_skills` | array of strings | Required, validated against known skill IDs |
| `timezone_offset_hours` | integer | Global default |
| `wakeup_interval_ms` | integer | Top-level fallback cadence |
| `skill_configs` | map | Nested per-skill configuration |
| `global_interrupt_policy` | map | Optional future field for cross-skill quiet hours and escalation rules |

### 6.2 Skill Metadata On Persisted Artifacts

Persisted insights and briefs should include:

```elixir
%{
  "assistant_behavior" => "ai_chief_of_staff",
  "origin_skill" => "followthrough" | "travel_logistics" | "briefing",
  "assistant_priority" => number(),
  "assistant_interrupt_posture" => "interrupt_now" | "heads_up" | "digest_only" | "silent_persist"
}
```

Backward compatibility rule:

- legacy artifacts from standalone behaviors remain valid and render normally

### 6.3 Skill Registry

Add a separate skill registry, for example:

- [`lib/maraithon/chief_of_staff/skills.ex`](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skills.ex)

Responsibilities:

- map skill IDs to modules
- expose skill defaults and requirements
- support builder introspection
- validate `enabled_skills`

## 7. Backend Changes By Area

### 7.1 Behavior Registry

Update [`lib/maraithon/behaviors.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors.ex):

- add `ai_chief_of_staff`
- keep `founder_followthrough_agent`, `personal_assistant_agent`, and `inbox_calendar_advisor` for backward compatibility

### 7.2 New Chief Of Staff Modules

Add new modules:

- `lib/maraithon/behaviors/ai_chief_of_staff.ex`
- `lib/maraithon/chief_of_staff/skill.ex`
- `lib/maraithon/chief_of_staff/skills.ex`
- `lib/maraithon/chief_of_staff/orchestrator.ex`
- `lib/maraithon/chief_of_staff/acquisition.ex`
- `lib/maraithon/chief_of_staff/source_bundle.ex`
- `lib/maraithon/chief_of_staff/merge.ex`

### 7.3 Skill Adapters

Add initial skill modules:

- `lib/maraithon/chief_of_staff/skills/followthrough.ex`
- `lib/maraithon/chief_of_staff/skills/travel_logistics.ex`
- `lib/maraithon/chief_of_staff/skills/briefing.ex`

Implementation rule:

- v1 skill adapters may delegate into existing modules instead of re-implementing the domain logic immediately

### 7.4 Builder Changes

Update [`lib/maraithon/agent_builder.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agent_builder.ex) and the related LiveView/UI surfaces to:

- add `AI Chief of Staff` as the primary workflow template
- support `enabled_skills` and nested `skill_configs`
- compute connector requirements as the union of enabled skill requirements
- keep advanced legacy behaviors available behind a secondary path

### 7.5 Delivery And Rendering

Update insight and brief rendering surfaces so they can:

- display assistant-origin metadata cleanly
- hide internal skill jargon in primary operator copy
- preserve skill provenance in detail views and debugging surfaces

## 8. Failure Modes and Safeguards

### 8.1 Skill Failure Isolation

Failure mode:

- one skill raises or returns an error during a cycle

Safeguard:

- record skill-specific failure telemetry
- continue running remaining skills
- do not mark the whole assistant unhealthy unless failure is systemic across cycles

### 8.2 Duplicate Provider Work

Failure mode:

- v1 adapters accidentally fetch the same Gmail or Calendar data multiple times

Safeguard:

- phase the migration explicitly
- add telemetry counters for provider fetch count per assistant cycle
- treat duplicate fetch reduction as an explicit acceptance criterion in the shared acquisition phase

### 8.3 Conflicting Notifications

Failure mode:

- travel and follow-through both attempt to interrupt simultaneously with no arbitration

Safeguard:

- merge outputs through one assistant-level priority sorter before staging delivery
- cap same-cycle Telegram interruptions by assistant-level policy

### 8.4 Leaky Internal Product Boundaries

Failure mode:

- the UI still looks like separate hidden agents

Safeguard:

- one visible assistant label
- one builder entry point
- one settings model with advanced per-skill sections

## 9. Rollout and Migration Plan

### 9.1 Rollout Sequence

1. Ship the `ai_chief_of_staff` behavior behind a new builder template.
2. Back it with adapter-based skill wrappers around current travel, follow-through, and briefing code.
3. Validate that one assistant can produce the same or better operator-visible outcomes as the separate legacy behaviors.
4. Introduce shared acquisition and assistant-level prioritization.
5. Move legacy behaviors to advanced or hidden status after adoption proves stable.

### 9.2 Backward Compatibility

- existing running agents keep their current behavior IDs
- no migration of old agent rows is required in v1
- persisted insights and briefs keep existing schemas with additive metadata only
- tests for legacy behavior modules must remain green during the migration

## 10. Test Plan and Validation Matrix

### 10.1 Unit Tests

- skill registry validation for unknown or duplicate skill IDs
- `ai_chief_of_staff` config parsing and defaulting
- effect routing back to the originating skill
- wakeup merging across enabled skills
- output merge arbitration across travel and follow-through

### 10.2 Integration Tests

- `AI Chief of Staff` with `followthrough` only reproduces current follow-through behavior shape
- `AI Chief of Staff` with `travel_logistics` only reproduces current travel-brief behavior shape
- `AI Chief of Staff` with all default skills produces coherent merged outputs
- connector requirement validation reflects the union of enabled skills
- assistant-level prioritization favors imminent travel logistics over digest-only follow-through noise

### 10.3 Regression Tests

- legacy `founder_followthrough_agent` still works unchanged
- legacy `personal_assistant_agent` still works unchanged
- `ChiefOfStaffBriefAgent` continues to render recurring briefs correctly
- new assistant does not double-stage duplicate Telegram deliveries in one cycle

### 10.4 Verification Gates

- `mix format`
- `mix test`
- `mix precommit`
- targeted builder UI tests for the new assistant template
- final implementation review against this spec

## 11. Implementation Checklist

- [ ] Add `ai_chief_of_staff` to the behavior registry and builder catalog
- [ ] Introduce the Chief of Staff skill contract and skill registry
- [ ] Implement `followthrough`, `travel_logistics`, and `briefing` skill adapters
- [ ] Build the top-level orchestrator behavior and assistant state model
- [ ] Add builder support for `enabled_skills`, `skill_configs`, and requirement unioning
- [ ] Add assistant-level origin-skill metadata to persisted insights and briefs
- [ ] Add assistant-level priority and interruption arbitration
- [ ] Add tests for config parsing, skill orchestration, effect routing, and backward compatibility
- [ ] Run `mix precommit`
- [ ] Review the implementation against this spec before marking it done

## 12. Open Questions and Assumptions

### 12.1 Assumptions

- The operator wants one primary assistant product and is willing to treat current standalone agents as implementation details or advanced legacy options.
- Travel logistics, follow-through, and briefing are the correct first-party skills for the first `AI Chief of Staff` release.
- Existing persistence tables for insights and briefs are sufficient for v1, with additive metadata rather than new storage abstractions.
- Shared acquisition can be phased in after the first composition-root release if adapter-based reuse is materially faster and lower risk.

### 12.2 Open Questions

- Whether Slack should remain bundled into the initial `followthrough` skill or be modeled as a separate `slack_loops` skill in a later iteration.
- Whether the builder should expose skill toggles by default or keep them behind an advanced panel for the first release.
- Whether assistant-level prioritization should eventually own Telegram staging directly rather than relying on downstream score thresholds alone.
