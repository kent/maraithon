# Todo architecture review — September 6, 2026

Objective: discover actionable commitments and decisions from connected apps,
rank them beside manually added work, and automatically close work when fresh
evidence proves it was handled. Ship small changes to the single-user test app
for `kent@runner.now`, using the manual-first development policy.

## Architecture to retain

- PostgreSQL owns runtime leases, task outcomes, and source progress. OTP
  processes schedule and execute work without replacing durable authority.
- `RecurringJobs` discovers work; `PeriodicJobs` creates per-account provider
  jobs and bounded model jobs. Gmail/Slack discovery and closure have separate
  cursors, encrypted source handoffs, and finalizers that require full coverage.
- `AIChiefOfStaff` coordinates skills and attention every ten minutes. Its
  regular cycles can reuse account-worker results instead of refetching every
  mailbox. OpenRouter calls use bounded shared model capacity.
- Completion already checks quoted evidence, timestamps, and todo ownership.
  The public todo APIs serve web, mobile, and companion clients.

## Findings and work list

1. **Calendar and companion completion coverage disappears for connected users.**
   The recurring sweep selects only users without connected Gmail/Slack for
   its general completion pass. Account closure acquisitions explicitly fetch
   Gmail or Slack; they cannot replace calendar, reminder, or local-message
   evidence. Add an independent, bounded user backstop that reads those sources
   without duplicating mailbox or Slack acquisition. Also propagate completion
   errors to the durable runner so failed model calls retry.
   Status: implemented in `581e8fa5`; build passed; deployed in
   `maraithon-00195-x7j`. Live execution pending runtime recovery.

2. **Fast deploy contains a drain-proof gate contrary to development policy.**
   It polls up to 48 times and refuses replacement without a strong drain
   proof. Keep a best-effort drain request to give graceful shutdown a head
   start, but continue the rolling replacement. Preserve database fences and
   the rejoin-on-failed-replacement recovery.
   Status: fixed in `6160e520`; shell syntax checked and deployed successfully.

3. **Cross-source completion is restricted by same-source linkage.**
   `CrossSourceCompletion.matching_evidence/4` requires an item-ID match or
   matching source channel, account label, and counterparty text. A real Slack
   reply normally has a different ID and channel from a Gmail todo, so a valid
   model decision can be rejected. Replace this with evidence-grounded
   cross-source relationship validation while retaining quote and time checks.
   Status: open; inspect identity fields and implement the complete path.

4. **Automatic closure needs explicit provenance and stale-decision protection.**
   Cross-source completion writes a free-text resolution note through ordinary
   `mark_done/3`. That call locks the current row but does not compare it with
   the todo the model evaluated. Record the verified evidence and method, and
   prevent a delayed model response from closing work the user changed.
   Review reopening and feedback across clients as part of this change.
   Status: provenance and row-locked snapshot protection implemented in
   `93bf5406`; build passed. Reopening/feedback review remains open.

5. **Completion rotation stops at a fixed 500-row pool.**
   The general cross-source pass loads the oldest-updated 500 todos before
   rotating by `last_completion_checked_at`. Checking does not change
   `updated_at`, so todos outside that pool can remain excluded indefinitely.
   Order or page the durable candidate pool by completion coverage itself.
   Status: fixed in `c109e4e3`; the query orders by the completion-check stamp
   before applying its bound and applies the age filter in SQL. Build passed;
   deployment pending.

6. **Live Gmail catch-up and runtime health require current evidence.**
   The September 5 report explicitly left Gmail catch-up unfinished. Inspect
   current source cursors, pending/failed graphs, schedule advancement,
   checkpoints, exact outcome evidence, and interval database load before
   calling this complete. Repair underlying causes instead of advancing
   unevaluated cursors or relabeling ambiguous outcomes.
   Status: **unhealthy**, verified at 18:56 UTC on revision
   `maraithon-00194-xqs`. One partition is draining with an expired lease;
   63 are ready/live. Gmail and Slack source queues have pending work dating
   to September 5 at 21:05–21:09. Gmail discovery cursors last advanced on
   September 2 (account 1) and September 5 (account 2); Gmail closure cursors
   are still on September 2. There are 626 open todos, so the scan-limit
   problem is relevant to Kent's actual account. All 18 active recurring
   schedules had no persisted error, which alone is insufficient evidence
   that their child work is running.

   Cloud SQL and application logs show 30-second database timeouts at
   September 5 21:07 and 21:11, followed by coordination-process crashes.
   One trigger rejected revival of an expired node incarnation. `3b62894f`
   catches database failures in the coordination tick, retains the incarnation
   for cleanup, and publishes uncertainty before cleanup; build passed.
   The existing stranded partition still needs diagnosis and recovery.

7. **Verify the complete product loop for Kent.**
   Confirm source-backed discovery and closure, ranked manual work, useful
   explanations and corrections, and current mobile/companion consumption of
   server state. Native changes should follow demonstrated gaps, with narrow
   builds and installation/release only for affected apps.
   Status: remaining review and direct verification.

## Delivery state

The first batch through `f3dfb2d8` deployed successfully using GitHub's existing
keyless `make deploy` workflow, run `34053264882`. Revision
`maraithon-00195-x7j` serves 100% of traffic. The previously unpushed history was
already deployed through `d2608e73`; this delivery adds the backstop and fast
deployment changes. The same push triggered the configured mobile release
workflow for the already-present native updates (`34053264885`).

Local deployment was unavailable: the shell's active service account belongs
to another project, Kent's cached organizational logins require reauthentication,
and the other checked credentials lack deployment access. No credentials or
IAM grants were changed. Later fixes listed above are committed locally and
will form the next small deployment after the first run settles.

## Verification policy

Use `make build` and direct production observations. No automated tests are
authorized for this routine iteration. Run database diagnostics only inside
Cloud Run job executions with an `eval` override and `POOL_SIZE=2`. This report
is a working list, not a claim that the objective is complete.
