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
   Status: implemented; build passed; deployment and live execution pending.

2. **Fast deploy contains a drain-proof gate contrary to development policy.**
   It polls up to 48 times and refuses replacement without a strong drain
   proof. Keep a best-effort drain request to give graceful shutdown a head
   start, but continue the rolling replacement. Preserve database fences and
   the rejoin-on-failed-replacement recovery.
   Status: fixed in `6160e520`; shell syntax checked; next deployment pending.

3. **Cross-source completion is restricted by same-source linkage.**
   `CrossSourceCompletion.authorized_evidence?/4` requires an item-ID match or
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
   Status: open.

5. **Completion rotation stops at a fixed 500-row pool.**
   The general cross-source pass loads the oldest-updated 500 todos before
   rotating by `last_completion_checked_at`. Checking does not change
   `updated_at`, so todos outside that pool can remain excluded indefinitely.
   Order or page the durable candidate pool by completion coverage itself.
   Status: open.

6. **Live Gmail catch-up and runtime health require current evidence.**
   The September 5 report explicitly left Gmail catch-up unfinished. Inspect
   current source cursors, pending/failed graphs, schedule advancement,
   checkpoints, exact outcome evidence, and interval database load before
   calling this complete. Repair underlying causes instead of advancing
   unevaluated cursors or relabeling ambiguous outcomes.
   Status: production snapshot in progress.

7. **Verify the complete product loop for Kent.**
   Confirm source-backed discovery and closure, ranked manual work, useful
   explanations and corrections, and current mobile/companion consumption of
   server state. Native changes should follow demonstrated gaps, with narrow
   builds and installation/release only for affected apps.
   Status: remaining review and direct verification.

## Verification policy

Use `make build` and direct production observations. No automated tests are
authorized for this routine iteration. Run database diagnostics only inside
Cloud Run job executions with an `eval` override and `POOL_SIZE=2`. This report
is a working list, not a claim that the objective is complete.
