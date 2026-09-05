# September 5 server remediation

Scope: the transient todo-brief provider failure, nudge timeout, and reported
storage-verification load; CRM and Gmail discovery failures found while checking
the same serving revision. Times below are UTC.

## Checklist

- [x] Reserve a bounded retry for transient brief failures, including when the
  brief and primary model are identical (`33942dcd`).
- [x] Reserve a bounded nudge-decision retry inside the existing cycle deadline,
  before any delivery/cadence side effects (`240668e9`). After a real 45s/15s
  retry pair timed out, use the full existing 120s cycle budget with a 90s first
  attempt and 30s reserve (`5efa7341`); output quality/limits are unchanged.
- [x] Keep due nudges ahead of same-tenant source fan-outs. The 20:40 check
  found the retry still pending since 20:29 behind dozens of discovery jobs.
  Priority is inside tenant fairness, after all concurrency/rate/lease checks;
  it does not preempt running work or grant a tenant extra capacity (`ecc83576`).
- [x] Replace CRM window unique-violation recovery with conflict-safe insertion
  and row locking (`117769f9`); reselect if a concurrent flush wins the race
  (`39f592f1`).
- [x] Render known Gmail HTML as readable evidence before budgeting it, retaining
  links, descriptive attributes, and the original encrypted provider source
  (`0bb0d46f`). Genuine plain text and the evidence/request limits are unchanged.
- [x] Separate historical PostgreSQL totals from live interval measurements.
- [x] Repair the three unattached Gmail observations left by earlier CRM
  failures, without replaying message imports or contact counters.
- [x] Verify the final deployed revision, source progress, and exact-runtime
  health after the follow-up fixes.

## Final deployment and checks

Revision `maraithon-00193-kpc` serves 100% of traffic from commit `ecc83576`.
The cached build took 1m24s; unchanged migrations were skipped. `/health` is
`ok`, and the Exact Agent recovered at 20:46:08.

The 20:47:08 production check confirmed:

- Nudge job `24cc7ee9-43fd-4c00-8262-9404610f2d05`, previously pending after its
  timeout, completed at 20:47:07 with `last_error = NULL`.
- All 64 partitions ready with live leases; one live node and leader; no
  non-ready partitions or termination-requested tasks.
- All 17 active recurring schedules had no persisted error and none were more
  than a minute overdue.
- Two fresh `effect_completed` events, latest at 20:47:05. All 1,100 known
  Effect outcomes matched their full outcome evidence.
- A successful checkpoint at 20:36:45 and a fresh idle snapshot at 20:47:08;
  no `snapshot_persist_failed` events in the verification window.
- No remaining unattached CRM observations from September 5.

Gmail catch-up is **not yet complete**: 24 reasoning jobs were pending and two
were running. Fresh reasoning jobs are completing after the HTML fix, but the
two Gmail discovery watermarks have not yet advanced. Their finalizers keep the
cursor closed until complete coverage is proven. Some older graphs contain
provider-ambiguous tasks from deployment cancellation and are superseded through
normal rediscovery; those historical failures have not been erased. Slack's
watermark has advanced. No further code change is queued for this catch-up.

## Evidence so far

- Revision `maraithon-00189-dz9` deployed the brief/nudge changes. A real nudge
  decision completed at 19:47:31; 21 briefs completed by the 20:07 check without
  a new persisted brief error.
- The 20:06:40 Cloud SQL error was a concurrent insert into the partial unique
  index `crm_ingest_windows_open_per_source_index`. Catching the constraint
  violation inside the transaction left that transaction aborted.
- Revision `maraithon-00190-mvn` deployed the first CRM fix. Startup had transient
  connection timeouts; the Exact Agent recovered at 20:15:37. The 20:18:10
  database check found 64 ready/live partitions, one live node and leader, and
  zero termination-requested tasks. All 17 active recurring schedules had no
  persisted error and future scheduled times. Historical terminal schedule rows
  are retained and are not the active schedules.
- Failed discovery handoffs contained 101–109 KB HTML bodies mislabeled as text,
  and repeated HTML in thread context. These were rejected before an LLM call.
  Raw source bodies remain encrypted and intact; rendering is a prompt projection,
  not permission to discard evidence or advance an unevaluated source cursor.
- A read-only production projection of eight failing handoffs (34 source
  records) admitted every record below the unchanged evidence limit. The largest
  reconstructed record was 81,472 bytes; no model decision or cursor mutation
  was performed by this diagnostic.
- Revision `maraithon-00191-7gb` deployed `0bb0d46f` and the CRM flush follow-up.
  The Exact Agent recovered at 20:25:28; real model calls began completing at
  20:25:34. `/health` returned `ok` and the revision serves 100% of traffic.
- At 20:30:17, the scoped CRM repair linked the three pre-20:06:41 orphan
  observations to window `b235fa6c-64eb-4732-952b-6c46e13fda1a` and queued normal
  relationship job `2bc41a10-9fe2-454f-bdce-bf1b6c60e8fa`. Linking, window count,
  and enqueue were one transaction under the user privacy fence. Participant
  resolution and interaction counters were not rerun. A repeat repair sees no
  eligible unattached rows and does not create duplicate work.
- By 20:30:17, 22 discovery reasoning jobs had completed since Agent recovery;
  Slack's discovery cursor advanced at 20:27:31. Gmail replacement cycles were
  still draining their queued source partitions. One oversized pre-fix handoff
  failed request validation; fresh acquisitions repartition the rendered evidence.
- All 1,098 historical Effect assignments with `outcome_known` have outcome
  evidence. The 11 settled assignments without evidence were explicitly
  `cancelled_before_provider` with `provider_boundary = 'not_entered'`.
  Historical ambiguous outcomes remain recorded; they were not relabeled or
  erased to make health checks pass.
- The CRM recovery job and its window completed normally. At 20:40:27 there
  were zero unattached observations from September 5, all 64 partitions were
  ready/live, all 17 active recurring schedules had no persisted error, and
  a fresh checkpoint/snapshot had succeeded at 20:36:45 with no snapshot failures.
  The full Effect-evidence comparison (assignment, activation, claim, node,
  supervisor, local task, and outcome) found zero missing evidence.

## Database-load interpretation

`pg_stat_statements` was last reset on August 28. The reported 42.5% was a
cumulative share dominated by older verification queries, not current steady-state
load. Existing positive-only, single-flight verification caching remains intact;
activation remains uncached. No statistics were reset and no leases/fences were
weakened.

Aligned observations from 19:51:08 to 20:07:48 showed:

- Total PostgreSQL execution-time delta: 171,142.83 ms.
- Current combined storage verification: three calls, 909.39 ms, **0.53%**.
- Node/partition/leader renewals together: 31,068.57 ms, **18.15%** of this
  interval's execution time, or approximately 31 ms per wall-clock second.
  This is real coordination cost, not a demonstrated verification-cache defect.
  The two-second renewal cadence is unchanged. The renewal share must not be
  represented as having fallen simply because historical percentages differed.

A later stable-revision interval, 20:36:43–20:40:27, included both the combined
storage check and the separate role/catalog check: 489.18 ms out of 19,579.50 ms,
or **2.50%**. Renewals were 3,487.24 ms (**17.81%**), approximately 16 ms per
wall-clock second. A larger share after expensive verification disappears is
not, by itself, evidence that lease renewal became slower.

## Verification mode

Changed code compiles with `mix compile --warnings-as-errors`. No broad test
suite was run. An earlier narrow LLM test attempt stopped during local test
database migration with unrelated durable-payload catalog drift, before tests
could execute. No migration/fingerprint check was bypassed. Subsequent work uses
compile checks and production diagnostics, consistent with development mode.
