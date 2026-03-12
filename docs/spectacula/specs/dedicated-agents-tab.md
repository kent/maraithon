# Dedicated Agents Tab

Status: Draft v1
Purpose: Define a dedicated web workspace for agent CRUD, lifecycle control, logs, and inspection, while narrowing `/dashboard` back to control-center duties.

## 1. Overview and Goals

### 1.1 Problem Statement

The current web UI overloads `/dashboard`. It is simultaneously acting as:

- the control center for insights, health, queues, and logs
- the main registry for user agents
- the only place to inspect agent runtime details
- the only place to edit, start, stop, and delete agents

That coupling creates two operator problems:

1. The page information architecture is wrong for day-to-day agent management. A user looking for agent CRUD and runtime inspection has to work through an insight-first dashboard.
2. The primary management actions are not trustworthy enough. The reported inability to stop or delete agents means the existing registry is not meeting the operational bar for a long-lived runtime.

The product needs a dedicated `Agents` tab that becomes the home for agent management. `/dashboard` should remain the place for fleet health, insights, failures, and logs.

### 1.2 Goals

- Add a top-level `Agents` tab in the authenticated web navigation.
- Create a dedicated `/agents` LiveView for user-scoped agent management.
- Move agent registry, row actions, and deep inspection out of `/dashboard`.
- Keep agent creation routed through the existing `/agents/new` builder.
- Support CRUD and lifecycle control from the Agents workspace:
  - inspect
  - edit
  - start
  - stop
  - delete
- Support runtime analysis for a selected agent using existing persisted and in-memory surfaces:
  - recent events
  - spend
  - queued work
  - agent logs
  - config snapshot
- Make start/stop/delete reliable and explicitly test them end to end in the LiveView.
- Preserve existing authenticated/API contracts where possible.

### 1.3 Non-Goals

- Replacing the existing `/agents/new` builder with a new creation surface.
- Introducing an LLM-generated “analysis” or recommendation layer for agents in v1.
- Reworking the JSON API shape under `/api/v1/agents`.
- Building multi-user or admin cross-user fleet control. This workspace remains scoped to the current authenticated user’s agents.
- Redesigning connectors, onboarding proof, or the dashboard insights system beyond the routing and navigation changes needed to separate responsibilities.

## 2. Current State and Operator Pain

### 2.1 Current Web Surface

Current authenticated web routes:

| Route | Surface | Current role |
|---|---|---|
| `/dashboard` | `MaraithonWeb.DashboardLive` | Insights, health, queue metrics, fly logs, raw logs, agent registry, agent create/edit, agent inspection |
| `/agents/new` | `MaraithonWeb.AgentBuilderLive` | Dedicated new-agent builder |

Current top navigation:

- `Dashboard`
- `Build Agent`
- `Connectors`
- `How it works`

Current dashboard agent-management areas:

- `Agent Registry` table with `Inspect`, `Edit`, `Start/Stop`, and `Delete`
- inline create/edit form
- `Agent Details` with spend, config, prompt, and runtime actions
- deeper inspection panels for events, queues, and logs lower on the page

### 2.2 Existing Backend Surface

Relevant existing modules:

- [`lib/maraithon_web/live/dashboard_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/dashboard_live.ex)
- [`lib/maraithon_web/live/agent_builder_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/agent_builder_live.ex)
- [`lib/maraithon_web/components/admin_navigation.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/components/admin_navigation.ex)
- [`lib/maraithon/runtime.ex`](/Users/kent/bliss/maraithon/lib/maraithon/runtime.ex)
- [`lib/maraithon/agents.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agents.ex)
- [`lib/maraithon/admin.ex`](/Users/kent/bliss/maraithon/lib/maraithon/admin.ex)

Existing action and inspection primitives already exist:

- `Runtime.start_existing_agent/1`
- `Runtime.stop_agent/2`
- `Runtime.delete_agent/1`
- `Runtime.update_agent/2`
- `Admin.safe_agent_snapshot/2`
- `Agents.list_agents(user_id: user_id)`
- `Agents.get_agent_for_user/2`

### 2.3 Current Problem Boundaries

The issue is not that the runtime lacks agent lifecycle APIs. The issue is that the web interaction model is fragmented and unreliable:

- management actions are mixed into a non-management page
- inspection is available only through dashboard selection state
- the builder and registry feel like separate products
- stop/delete behavior is currently perceived as broken from the operator’s point of view

The spec should therefore treat the dedicated Agents tab and the action-reliability fix as one workflow change, not two unrelated tasks.

## 3. Product Decisions

The user decisions that define this spec:

- `/dashboard` should stop being the primary agent-management page.
- The new `Agents` tab should be the top-level destination for agent CRUD and runtime inspection.
- New agents should still be created in `/agents/new`.
- “Analyze agents” in v1 means deeper operational inspection, not a new AI-generated analysis layer.
- The navigation should expose `Agents`, not `Build Agent`, as the management destination.

## 4. Information Architecture

### 4.1 Top Navigation

The authenticated top nav becomes:

- `Dashboard`
- `Agents`
- `Connectors`
- `How it works`
- `Settings` for admin users only

`/agents` and `/agents/new` both activate the `Agents` tab.

`Build Agent` is removed as a standalone top-level tab.

### 4.2 Dashboard After This Change

`/dashboard` remains the control center and keeps:

- actionable insights
- health and queue metrics
- recent failures
- raw logs
- fly/platform logs
- connector status or onboarding proof where already present

`/dashboard` removes:

- the `Agent Registry` section
- the inline create/edit agent panel
- the selected `Agent Details` inspection surface
- any deep-link behavior centered on `?id=<agent_id>`

Dashboard replacement CTAs:

- `Manage agents` -> `/agents`
- `New agent` -> `/agents/new`

### 4.3 Agents Workspace

`/agents` becomes the operational home for the current user’s agents.

The page has three conceptual layers:

1. `Header`
2. `Registry`
3. `Selected Agent Workspace`

#### Header

Contains:

- page title: `Agents`
- user-scoped count
- `New Agent` CTA linking to `/agents/new`
- optional helper copy such as `Create, inspect, edit, and control the agents running for your account.`

#### Registry

Shows user-scoped agents with:

- name
- behavior
- status
- subscriptions summary
- updated timestamp
- row actions

Registry controls:

- text search over agent name, behavior, and id
- status filter: `all`, `running`, `degraded`, `stopped`
- optional sort remains recency-first in v1 unless a filter/search is active

#### Selected Agent Workspace

Selecting a row patches the URL and opens the lower workspace for that agent.

The workspace has two modes:

- `Inspect`
- `Edit`

These are selected by query param and visible sub-navigation, not by separate top-level routes.

### 4.4 Builder Relationship

`/agents/new` remains the single creation flow in v1.

Required behavior changes:

- the builder’s “back” copy and links point back to `/agents`, not `/dashboard`
- successful creation navigates to `/agents?id=<new_agent_id>`
- authenticated nav still highlights `Agents` while in `/agents/new`

## 5. Route and State Contract

### 5.1 Web Routes

| Route | LiveView | Meaning |
|---|---|---|
| `/dashboard` | `DashboardLive` | Control-center only |
| `/agents` | `AgentsLive` | Agent registry and selected workspace |
| `/agents?id=<uuid>` | `AgentsLive` | Selected agent in inspect mode |
| `/agents?id=<uuid>&panel=edit` | `AgentsLive` | Selected agent in edit mode |
| `/agents/new` | `AgentBuilderLive` | New-agent builder |

### 5.2 Legacy Redirects

To preserve old entry points:

- `/dashboard?id=<uuid>` redirects or `push_navigate`s to `/agents?id=<uuid>`
- any code path that currently returns to `/dashboard?id=<uuid>` after agent creation or selection updates to `/agents?id=<uuid>`

This includes:

- `AgentBuilderLive` success redirects
- dashboard `Inspect` links that remain as compatibility CTAs during transition
- any other internal LiveView patch/navigation that assumes the dashboard owns selected-agent state

### 5.3 URL-State Rules For AgentsLive

Query params:

| Param | Allowed values | Meaning |
|---|---|---|
| `id` | UUID | Selected agent id |
| `panel` | `inspect`, `edit` | Selected workspace mode |
| `status` | `all`, `running`, `degraded`, `stopped` | Registry filter |
| `q` | string | Search text |

Rules:

- no `id` means no selected workspace
- `panel=edit` without valid `id` falls back to no selection
- invalid or unauthorized `id` clears selection and removes `id` from the URL
- missing `panel` with a valid `id` defaults to `inspect`

## 6. Functional Requirements

### 6.1 Registry Actions

Every row must expose:

- `Inspect`
- `Edit`
- `Start` or `Stop`
- `Delete`

Action behavior:

| Action | URL/state effect | Result |
|---|---|---|
| `Inspect` | patch to `/agents?id=<id>` | opens inspection workspace |
| `Edit` | patch to `/agents?id=<id>&panel=edit` | opens edit workspace |
| `Start` | no route change required | starts agent, refreshes row and workspace |
| `Stop` | no route change required | stops agent, refreshes row and workspace |
| `Delete` | if selected, clear `id` from URL | deletes agent, removes row, clears workspace if needed |

### 6.2 Action Reliability Requirements

This is a primary acceptance area.

Required rules:

- row actions must operate on the row’s agent id, not on ambient selection state
- selected-workspace actions must operate on the selected agent id
- in-flight action buttons disable to prevent double submission
- success paths refresh both registry data and selected workspace data
- delete requires confirmation
- start/stop/delete must surface success and error flash messages
- if an action fails because the agent no longer exists, the row is removed on refresh and selection clears if necessary

### 6.3 Selected Inspect Workspace

The selected agent workspace in `inspect` mode must expose:

- agent name, behavior, status, timestamps
- subscriptions and tools summary
- spend summary
- recent events
- effect queue / recent effects
- scheduled jobs / recent jobs
- recent agent logs
- config snapshot
- prompt text when available

This is a dedicated inspection surface, not just a small summary card.

The implementation may use stacked sections or sub-tabs, but it must make all of the above visible without returning to the dashboard.

### 6.4 Selected Edit Workspace

The `edit` mode should reuse the existing dashboard edit behavior rather than inventing a second edit model.

Required behavior:

- prefill the current saved definition
- support the existing editable fields already exposed on the dashboard
- save updates the agent record
- if the agent was running and current runtime behavior already restarts on update, preserve that contract
- after successful save, return to `inspect` mode for the same agent unless the user explicitly stays in edit mode

### 6.5 Empty States

Required empty states:

| Condition | Copy intent |
|---|---|
| No agents exist | Prompt to create first agent from `/agents/new` |
| No selected agent | Prompt user to select an agent from the registry |
| Search/filter returns no rows | Clear “no matches” message plus filter reset affordance |
| Selected agent deleted or missing | Clear selection and show transient flash |
| Inspection degraded | Reuse current degraded inspection messaging from `Admin.safe_agent_snapshot/2` |

## 7. Backend and LiveView Design

### 7.1 New LiveView

Add a new LiveView:

- `MaraithonWeb.AgentsLive`

Responsibilities:

- load the current user’s agent registry
- parse and own agent-management URL state
- load selected-agent inspection data
- execute edit/start/stop/delete actions
- refresh registry and workspace on a timer or after actions

### 7.2 Reuse vs Extraction

Expected reuse:

- existing runtime lifecycle calls from `Runtime`
- existing user-scoped agent queries from `Agents`
- existing inspection snapshot logic from `Admin`
- existing builder route and behavior specs from `AgentBuilder`

Likely extractions from `DashboardLive`:

- shared formatting helpers for agent names, subscriptions, tools, and timestamps
- selected-agent inspection rendering helpers
- existing inline edit form logic if it is still the intended edit surface

The spec does not require extracting every helper on day one, but the implementation should avoid copying large agent-management blocks directly from `DashboardLive` without cleanup.

### 7.3 Dashboard Simplification

`DashboardLive` should remove:

- agent registry assigns not needed for control-center rendering
- selected-agent query-param handling
- agent create/edit/start/stop/delete events
- selected-agent inspection refresh logic

Allowed dashboard agent data after this change:

- high-level health counts already used in fleet metrics
- optional lightweight CTA or summary block linking to `/agents`

### 7.4 Builder Changes

`AgentBuilderLive` changes:

- nav active state must map `/agents/new` to the `Agents` tab
- back link goes to `/agents`
- success redirect goes to `/agents?id=<created_id>`
- any internal `return_to` or connector reconnect flow that currently expects `/dashboard` should keep `/agents/new` as the builder return target when inside the builder

## 8. API and Compatibility Notes

### 8.1 JSON API

No required breaking API changes.

The existing `/api/v1/agents` surface remains the programmatic control plane for:

- list
- show
- create
- update
- start
- stop
- delete
- events
- spend

### 8.2 Internal Compatibility

Existing web/UI links that should be updated:

- nav entries
- dashboard `Inspect` links
- dashboard CTAs that currently say `Open Agent Builder`
- builder success redirects
- any static links in briefs or helper surfaces that point to `/dashboard?id=...`

### 8.3 Data Compatibility

No data migration is required for the dedicated Agents tab itself.

Assumption:

- agent ownership remains based on `agent.user_id`
- legacy rows without matching `user_id` remain outside the authenticated user workspace in v1

## 9. Failure Modes and Safeguards

### 9.1 Lifecycle Actions

| Failure mode | Required behavior |
|---|---|
| Agent not found | Refresh registry, clear selection if needed, flash error |
| Agent already running | Refresh row/workspace, show informational flash |
| Agent already stopped | Refresh row/workspace, show informational or no-op flash |
| Delete fails | Preserve row, show error flash |
| Runtime action raises | Catch, refresh visible state, show safe error message |

### 9.2 Inspection Data

| Failure mode | Required behavior |
|---|---|
| DB-backed inspection queries fail | Reuse degraded snapshot behavior from `Admin.safe_agent_snapshot/2` |
| Logs unavailable | Show empty log state, do not fail full page |
| Selected id unauthorized | Remove invalid `id` from URL and clear selection |

### 9.3 Navigation Safety

- `/agents/new` must not accidentally highlight `Dashboard`
- old `/dashboard?id=` links must not silently strand the user on a dashboard with missing detail panels
- the removal of dashboard management sections must not break onboarding or authenticated landing flows

## 10. Observability and Telemetry

Minimum telemetry for the new workspace:

### 10.1 Event Contract

| Event | Measurements | Metadata |
|---|---|---|
| `[:maraithon, :agents, :view, :loaded]` | `%{agent_count: integer}` | `%{has_selection: boolean, panel: atom | nil}` |
| `[:maraithon, :agents, :selection, :changed]` | `%{count: 1}` | `%{agent_id: String.t(), panel: atom}` |
| `[:maraithon, :agents, :action]` | `%{count: 1}` | `%{action: String.t(), surface: :row | :workspace, agent_id: String.t(), outcome: :ok | :error}` |
| `[:maraithon, :agents, :filter, :changed]` | `%{count: 1}` | `%{status: String.t(), has_query: boolean}` |

Telemetry purpose:

- verify that the new tab is actually used
- detect whether start/stop/delete errors persist after the move
- observe whether operators primarily act from the table or the selected workspace

## 11. Validation Plan

### 11.1 LiveView Tests

Add a dedicated test file:

- `test/maraithon_web/live/agents_live_test.exs`

Required coverage:

- nav highlights `Agents` for `/agents` and `/agents/new`
- `/dashboard` no longer renders the old registry/inspection surfaces
- `/agents` renders registry and empty state correctly
- selecting an agent patches to `/agents?id=<id>`
- `Edit` patches to `/agents?id=<id>&panel=edit`
- start action updates visible status
- stop action updates visible status
- delete removes the row and clears selection
- selected inspection shows logs, events, queue, spend, and config
- missing/unauthorized `id` clears selection safely
- `/dashboard?id=<id>` redirects to `/agents?id=<id>`
- builder success redirects to `/agents?id=<id>`

### 11.2 Existing Tests To Update

Expected impacted suites:

- `test/maraithon_web/live/dashboard_live_test.exs`
- `test/maraithon_web/live/agent_builder_live_test.exs`
- any navigation tests that assert the old tab set

### 11.3 Verification Gates

Required repo gates:

- `mix format`
- `mix precommit`

## 12. Rollout Plan

### 12.1 Implementation Sequence

1. Add `AgentsLive` route and navigation support.
2. Move registry and inspection rendering into the new page.
3. Update builder redirects and back links.
4. Simplify `DashboardLive` and remove selected-agent handling.
5. Add legacy redirect from `/dashboard?id=...`.
6. Add/adjust tests.
7. Run verification and deploy.

### 12.2 Deployment Expectations

Because this is a route and navigation change:

- internal links must be updated in the same deploy
- the legacy `dashboard?id` redirect must ship before or with the dashboard surface removal

## 13. Definition of Done

- There is a top-level `Agents` tab in authenticated nav.
- `/agents` is the primary web destination for agent management.
- `/dashboard` no longer contains the old registry, agent editor, or selected-agent inspection workspace.
- New agent creation still works through `/agents/new`.
- Builder success returns to `/agents?id=<new_id>`.
- Existing agent editing works from the Agents workspace.
- Operators can reliably start, stop, and delete from the Agents workspace.
- Operators can inspect logs, events, queue state, spend, and config without using `/dashboard`.
- Legacy `/dashboard?id=<id>` entry points redirect safely.
- `mix precommit` passes.

## 14. Open Questions and Assumptions

### 14.1 Assumptions

- “Analyze agents” in this request means operational inspection, not a new model-generated analysis feature.
- Edit will reuse the current dashboard edit form/contract unless implementation review finds it too coupled, in which case extraction is acceptable.
- The Agents workspace remains user-scoped and does not expose admin cross-user fleet control.

### 14.2 Open Questions

- None at spec time. The user has already chosen the core IA and flow decisions needed for implementation.
