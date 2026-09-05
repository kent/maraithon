# Maraithon Goals

> **Status (2026-05-20): Active through a narrow double-down proof window.** Complete the 30-day Chief of Staff dogfood run, onboard 3 alpha candidates, and keep building only what proves Telegram-first open-loop capture. See [Maraithon 6-month Path Decision](docs/decisions/2026-05-09-maraithon-path.md).

Updated: September 5, 2026

## North Star

Maraithon is a cloud-resident, Telegram-mediated personal operating system for busy people.

Its job is to help the user keep track of every open loop, relationship, commitment, context, and next action without needing to sit at a desktop app. The user should be able to live in Telegram and ask Maraithon what matters, what is waiting, what they owe people, what people owe them, and what to do next.

Maraithon should be both reactive and proactive:

- Reactive: the user can ask natural questions in Telegram and the assistant can inspect context, call tools, update state, draft actions, and answer in a Telegram-friendly way.
- Proactive: the system can watch connected sources, create durable todos, build relationship context, remember preferences, and interrupt only when the model decides the user should see something now.
- Always-on: the Chief of Staff should wake every 10-15 minutes, scan what changed across connected sources, update durable open-loop state, and look for ways to improve the user's life.

The goal is not another dashboard. The goal is an agent-powered operating system that helps the user accomplish what they need to in the world.

## Product Bet

Busy people do not fail because they lack task apps. They fail because commitments are scattered across email, Slack, calendar, Telegram, texts, WhatsApp, meetings, relationships, and memory. The assistant must turn that scattered surface area into durable, inspectable, actionable state.

Maraithon wins if it becomes the trusted place where the user can ask:

- What are my open loops?
- What do I owe this person?
- Who am I waiting on?
- What should I do next with 15 minutes?
- What did I promise yesterday?
- What relationship needs attention?
- What should I not forget?
- What should I ignore because it is noise?

## Non-Negotiable Principles

1. Telegram is the primary interaction surface.
   The cloud app and web UI are control planes. The daily user experience happens in Telegram.

2. Durable state beats transient summaries.
   If something is actionable, it should become a todo. If it is relationship context, it should become CRM data. If it is a durable preference, correction, or relevance signal, it should become memory.

3. Model-level intelligence makes semantic decisions.
   The app should not rely on keyword heuristics for relevance, dedupe, prioritization, routing, next action, memory recall, relationship interpretation, or whether to interrupt the user. The runtime may validate schemas, enforce safety, batch work, and execute tools; the model should decide what the information means.

4. Everything important needs a tool surface.
   Todos, People, relationships, memory, open loops, source access, and proactive delivery all need explicit tools/MCP-style capabilities so the Chief of Staff and Telegram assistant can operate on real data instead of prose.

5. The system should learn from correction.
   If the user says something is relevant, not relevant, helpful, not helpful, important, noise, or should never be surfaced again, Maraithon should record that as durable memory and use it in future decisions.

6. Proactive should be respectful and useful.
   Interruptions must be model-decided, deduped, auditable, and Telegram-native. A proactive message should explain what changed and what the user can do next.

7. Always-on means supervised and frequent, not noisy.
   The Erlang/Elixir runtime should keep the Chief of Staff alive with 10-15 minute wakeups. Each wakeup should gather current source context and let the model decide whether to create todos, update CRM, write memory, hold quietly, or send a Telegram check-in.

## Current State

Maraithon is a live single-user test app at `maraithon.com`.

The current test-app shape is:

- Phoenix 1.8 + LiveView web app.
- One combined Phoenix/runtime service on Google Cloud Run in `us-central1`.
- Postgres-backed durable state.
- Encrypted credentials with Cloak.
- Magic-link sign-in.
- Telegram bot/webhook interaction.
- OTP runtime for long-lived agents, wakeups, event handling, and recovery.
- GitHub Actions uses the cached fast path for server-relevant pushes to
  `main`; migrations run only when migration files change and automated tests
  are not part of the current loop.

Shipped primitives:

- Connectors for GitHub, Gmail, Google Calendar, Google Contacts, Slack, Notaui MCP, WhatsApp, Linear, Telegram, and Notion OAuth scaffolding.
- Projects as scoped context.
- Agents as installable workers with prompt, state, connectors, tools, and schedules.
- Chief of Staff behavior with skills.
- Durable app-level background jobs for slow user-scoped work such as source ingestion, relationship learning, and open-loop refreshes.
- Generic PromptAgent behavior.
- Live operator workspace for control, briefings, todos, and connector status.
- Event logs, effect logs, scheduled jobs, runtime supervision, and spend instrumentation.

## Core Data Model

### Todos

Todos are the durable open-loop object layer.

Each todo should be per user and include:

- Source: Slack, Gmail account, calendar account, Telegram, manual capture, agent, future iMessage/WhatsApp, etc.
- Source account and source item references.
- Title.
- Actual todo summary.
- Due date.
- Notes and metadata.
- Suggested next action.
- Draft or plan for the next action.
- Owner, defaulting to the main user.
- Status: open, snoozed, done, dismissed.
- Priority and attention mode for internal ranking, not user-facing numeric priority.
- Semantic dedupe key and evidence.

Todos should be created by model-level intelligence from Chief of Staff skills, Telegram requests, source scans, briefings, and connector events. Dedupe should be smart and semantic, not exact-string or keyword matching.

The todo list is not just a list. It is the current operating snapshot of the user's obligations.

### People and CRM

Maraithon needs a built-in CRM because most work is relationship-shaped.

Each person should include:

- First name.
- Last name.
- Display name.
- Contact details, including email, Slack id, Telegram id, phone, and future WhatsApp/iMessage identifiers.
- Preferred communication method, learned from how the user actually communicates with them.
- Relationship to the user.
- How often they speak.
- Notes and metadata.

There should be a join/link model between People and user-owned data:

- Todos.
- Emails.
- Slack threads.
- Calendar events.
- Briefs.
- Memories.
- Projects.
- Future message threads and external objects.

The assistant should make it easy to ask:

- Who is this person?
- How do I know them?
- How should I contact them?
- What do I owe them?
- What are they waiting on?
- When did we last talk?
- What context should I remember before replying?
- Look through my connected sources and figure out who this is.

CRUDing people and relationship links should be tool-callable by the Chief of Staff, Telegram assistant, and future MCP clients.

The user should not have to manually declare which relationships matter. If the same parent, teacher, spouse, assistant, teammate, investor, customer, or other proxy repeatedly contacts the user across email, texts, calendar, Slack, Telegram, WhatsApp, or future sources about another person, the model should recognize that pattern, create or enrich the relevant People records, write durable relationship memory, and link the source items and todos. For example, if Emma's mom, school, or teacher keeps sending messages about forms, schedule changes, or logistics, Maraithon should learn that Emma is important context and frame the resulting todo as what Kent needs to do as a parent.

### Memory

Memory is a first-class runtime primitive, not a side feature.

Maraithon should store and recall:

- Durable user preferences.
- Relevance feedback.
- Corrections.
- Relationship facts.
- Operating style.
- Content preferences.
- Interrupt preferences.
- User goals and priorities.
- Things the system should avoid surfacing.

Memory should be able to influence the main assistant loop. Before answering or deciding whether to interrupt, the model should have access to relevant memory and should be able to write new memory when the user teaches the system.

Examples:

- "School calendar emails are relevant when they affect pickup, forms, or schedule changes."
- "VC newsletters are not relevant unless they mention a direct opportunity."
- "Charlie prefers Slack and I talk to him weekly."
- "Do not surface automated receipts unless they require action."

## Model-First Harness

Maraithon needs a new kind of assistant harness.

The harness should provide:

- A compact Telegram assistant context.
- Tool catalogs for todos, people, memory, open loops, connectors, projects, agents, and prepared actions.
- A first-class connected-context review primitive that can inspect CRM, Gmail, contacts, Slack, calendar, open loops, and memory for a person, topic, or vague reference.
- A model-level planner that chooses which tools to call.
- A model-level proactive planner that decides whether to send, hold, or send todo cards.
- Schema validation and safety checks around model output.
- Push receipts for audit and dedupe.
- Telegram-friendly response shaping.

The runtime may enforce hard constraints:

- Validate JSON shape.
- Reject empty proactive sends.
- Enforce confirmation for dangerous writes.
- Persist audit logs.
- Dedupe delivery.
- Respect connector availability.

The runtime should not decide semantic relevance with hardcoded heuristics where a model should decide.

## Chief of Staff

The Chief of Staff is the flagship agent.

Its job:

- Maintain the user's open loops.
- Create todos from source activity.
- Create and update People and relationship links.
- Write memory from durable user feedback.
- Deliver morning briefings.
- Run commitment tracking.
- Surface proactive check-ins.
- Help the user decide what to do next.

Chief of Staff activities should add durable todos, people, links, and memories as they work. Briefings and summaries are not enough; the system should leave behind structured operating state.

The Chief of Staff should be always on. By default it should wake every 10 minutes, with lean modes allowed to stretch to 15 minutes. This cadence is the reason to use Erlang/Elixir and OTP: the assistant is a supervised, long-lived process that repeatedly comes alive, scans changes, updates state, and returns to sleep without losing context.

## Background Work Queue

Maraithon needs a durable queue for slow or repeated user-scoped work so Telegram replies, web requests, source webhooks, and database request paths do not block while the assistant thinks or scans.

The queue should handle:

- Email and source processing.
- Relationship and CRM enrichment.
- Open-loop and todo checks.
- Memory extraction and feedback learning.
- Future connector ingestion from Slack, iMessage, WhatsApp, Notion, Linear, and other sources.

Queued jobs should be per user, deduped, retried with backoff, observable in admin surfaces, and safe to resume after deploys or process restarts. Semantic decisions still belong to the model and tool layer; the queue exists to make that work durable, fast, supervised, and non-blocking.

## Commitment Tracker

Commitment Tracker is a Chief of Staff skill.

Its job is to scan connected work sources for promises Kent made, asks Kent received, pending replies, and time-bound commitments, then write model-deduped todos to Maraithon's built-in todo list.

Current source boundary:

- Gmail: available.
- Google Calendar: available for scanning.
- Telegram: delivery surface.
- iMessage, WhatsApp, OmniFocus writeback, and calendar write/delete mirror: future integrations unless explicit tool access exists.

Commitment Tracker should:

- Use full message bodies, not sender/subject/snippet-only guesses.
- Filter personal/family/social/non-actionable noise.
- Extract who, what, when, source, source ref, quote/context, and direction.
- Create People records when durable relationship data appears.
- Link todos to People.
- Record relevance and operating memories when learned.
- Preserve OmniFocus/project routing intent in metadata when useful, without claiming it wrote to OmniFocus unless the tool exists.
- Produce Telegram-friendly summaries with no fragile tables.

Future direction:

- Add iMessage and WhatsApp ingestion.
- Add optional OmniFocus sync for users who still want OmniFocus as an external task mirror.
- Add Google Calendar time-block mirroring for truly time-bound commitments.
- Add reconciliation between completed todos and downstream mirrors.

## Telegram Experience

Telegram should feel like the command line for your life, but forgiving and conversational.

The user should be able to type or speak:

- "What are my open loops?"
- "What do I owe Charlie?"
- "Who is Dan Bourke?"
- "Look through my email to find it."
- "What did I promise this week?"
- "What should I do next?"
- "What can I handle in 15 minutes?"
- "Add renew the domain this week."
- "Snooze that until Monday."
- "Handled the billing thing, what else?"
- "Who is Elena and what do I owe her?"
- "Remember that this kind of school email is relevant."
- "That newsletter was not useful."
- "Run Commitment Tracker."
- "Give me a morning briefing."

Telegram output should be:

- Short.
- Actionable.
- Friendly to mobile screens.
- Split into individual todo cards when the result is a todo list.
- Easy to reply to with "done", "snooze", "dismiss", "draft reply", or "what else?"

## What Would Make It Better for Busy People

### 1. Mobile quick capture

The fastest path into the system should be Telegram voice/text capture:

- "Remind me to..."
- "Capture this..."
- "I owe..."
- "Waiting on..."
- "Remember..."

The model should decide whether the capture is a todo, person update, memory, project note, or follow-up question.

### 2. Today mode

Busy users need a small answer to "what matters today?"

Today mode should combine:

- Due todos.
- Overdue commitments.
- Pending replies.
- Calendar context.
- Relationship-sensitive follow-ups.
- Travel/time constraints.
- User memory about priorities.

Output should be a tight Telegram digest plus individual cards for actions.

### 3. Waiting-on tracker

Open loops are two-sided. Maraithon should track:

- What Kent owes others.
- What others owe Kent.
- When Kent last nudged them.
- Whether a follow-up is appropriate.
- The best channel to use.

This should be CRM-linked and source-backed.

### 4. Relationship maintenance

The CRM should not just answer questions; it should notice relationship drift.

Examples:

- "You usually talk to Charlie weekly, but it has been 18 days."
- "Elena is waiting on two Runner items."
- "You have three open asks from investors."
- "This person prefers email, but your last two replies were in Slack."

The model should decide whether the observation is worth surfacing.

### 5. Action drafting

Todos should carry drafts and plans.

For many todos, the next best step is a message:

- Draft the email.
- Draft the Slack reply.
- Draft the Telegram reply.
- Draft the intro.
- Draft the calendar invite.

The assistant should prepare actions and ask for confirmation before sending.

### 6. Source transparency

Trust requires source trails.

Every todo, memory, and relationship update should retain:

- Source system.
- Account.
- Message/thread/event id when available.
- Quote or evidence.
- Model rationale.
- Last reviewed time.

Telegram replies should expose sources when the user asks "why?" or "where did that come from?"

### 7. Connected context review

When the user asks a vague but reasonable question like "Who is Charlie?",
"What do I owe Charlie?", "Who is Dan Bourke?", or "Look through my email to
find it", Maraithon should not stop at the current CRM snapshot or ask the user
for a last name first. It should review connected source context, learn any
durable person or relationship context it finds, and answer like a chief of
staff:

- Who the person appears to be.
- How Maraithon knows that from source evidence.
- Why they are likely reaching out.
- What Kent owes them or what they owe Kent.
- The recommended next action.
- Confidence and source caveats, only when useful.

### 8. Undo, correction, and feedback loops

Busy people will correct the assistant quickly.

Supported corrections should include:

- "Not relevant."
- "Wrong person."
- "Already done."
- "Never show me this again."
- "This is important."
- "This should be Runner, not Agora."
- "Remember that."

Corrections should update todos, CRM, memory, and future model prompts.

### 9. Quiet hours and interruption budget

Proactive Telegram is powerful but dangerous.

The system should maintain:

- Quiet hours.
- Urgency thresholds.
- Interrupt budget.
- "Hold until briefing" decisions.
- User-specific examples of good and bad interruptions.

The model should make send/hold decisions using this context.

### 10. Connector health as product UX

If the system cannot see a source, it cannot protect the user from missed loops.

Telegram should proactively explain missing source access:

- "Telegram is connected; Gmail is not."
- "Calendar scan failed; reconnect Google."
- "WhatsApp is not available yet, so this run only covers Gmail and calendar."

This should be useful, not noisy.

### 11. Reviewable audit trail

The user should be able to ask:

- "What did you add today?"
- "What did you ignore?"
- "What did you learn about me?"
- "Why did you ping me?"
- "What changed since yesterday?"

This should come from durable event, todo, memory, CRM, and push receipt data.

## Six-Month Definition of Done

Maraithon is working if, six months from now:

- Kent can run his day from Telegram without opening the web app except for setup/debugging.
- The system captures commitments from Gmail and calendar daily.
- The todo list is the trusted source of open loops.
- People and relationships are automatically enriched as agents encounter them.
- Memory materially changes future behavior after user feedback.
- Proactive messages are useful enough that Kent leaves them enabled.
- The assistant can answer "what am I missing?" with source-backed confidence.
- At least 5 external users have connected Telegram and one work source.
- At least 2 external users are weekly active because the system catches things they would otherwise miss.

## Near-Term Roadmap

### Now

- Keep Telegram connected as the required first connector.
- Keep the Chief of Staff always on with 10-15 minute supervised wakeups.
- Make the built-in todo list the source of truth for all Chief of Staff output.
- Keep Commitment Tracker model-backed and source-aware.
- Ensure every broad "what should I do?" answer reads todos/open loops first.
- Make every "who is this?" and "what do I owe them?" answer review connected context before asking the user for more details.
- Make correction and relevance feedback write to memory.
- Continue removing semantic heuristics from assistant decisions.

### Next

- Add first-class iMessage and WhatsApp source ingestion.
- Add optional OmniFocus sync as a downstream mirror, not the primary database.
- Add calendar time-block creation for deadline commitments.
- Add richer relationship timelines in CRM.
- Add "today mode" and "waiting-on mode".
- Add voice-message ingestion from Telegram.
- Add an audit view for what the assistant created, skipped, remembered, and pushed.

### Later

- Multi-user alpha onboarding.
- Personal setup wizard in Telegram.
- Connector failure recovery from Telegram.
- Calendar-aware planning and rescheduling.
- Delegation and handoff tracking.
- External MCP surface for other agents to CRUD todos, people, relationships, and memory.

## Non-Goals For Now

- A large dashboard-first productivity suite.
- A generic visual agent builder.
- Marketplace before dogfood retention.
- Multi-tenant enterprise administration before a personal workflow is excellent.
- Replacing every source app immediately.
- Calendar/OmniFocus writes that pretend to work before the tools exist.

## Relationship To Runner

Runner is the commercial chief-of-staff product direction. Maraithon is the agentic-first OTP implementation of the same thesis: long-lived, supervised agents with durable memory, tools, and proactive behavior.

The question is no longer whether Maraithon can be an always-on runtime. It can.

The better question is whether this Telegram-first, durable-open-loop operating system is the right product shape for Runner, Maraithon, or both.

If Maraithon continues, it should double down on the Telegram operating system thesis. If it folds into Runner, the things to preserve are:

- Built-in todos as durable open-loop state.
- CRM as the relationship layer.
- Deep memory as runtime steering context.
- Model-level tool use and semantic dedupe.
- Proactive Telegram check-ins with push receipts.
- Chief of Staff skills that leave structured state behind.
