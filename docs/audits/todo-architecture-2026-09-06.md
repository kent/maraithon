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
   `maraithon-00195-x7j`. The independent backstop completed at 19:23:48 UTC
   with no retries or recorded error.

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
   Status: implemented locally with a quoted, distinctive shared relationship
   anchor for cross-source/manual work, while retaining confidence, exact quote,
   timestamp, account, and stale-row checks. Thread context now keeps each
   reply's actual timestamp and sender instead of inheriting the delta timestamp.
   Calendar evidence uses creation/update time rather than a future event start.
   Build passed; deployed in workflow `34054801166`, revision
   `maraithon-00199-6vt`.

4. **Automatic closure needs explicit provenance and stale-decision protection.**
   Cross-source completion writes a free-text resolution note through ordinary
   `mark_done/3`. That call locks the current row but does not compare it with
   the todo the model evaluated. Record the verified evidence and method, and
   prevent a delayed model response from closing work the user changed.
   Review reopening and feedback across clients as part of this change.
   Status: provenance and row-locked snapshot protection implemented in
   `93bf5406`; build passed and deployed in `maraithon-00196-k5d`.
   Reopening now records a correction and requires newer evidence across
   deterministic and model checks. Existing mobile and companion reopen
   actions use this shared server path; build passed and deployed in
   `maraithon-00197-thz`.

5. **Completion rotation stops at a fixed 500-row pool.**
   The general cross-source pass loads the oldest-updated 500 todos before
   rotating by `last_completion_checked_at`. Checking does not change
   `updated_at`, so todos outside that pool can remain excluded indefinitely.
   Order or page the durable candidate pool by completion coverage itself.
   Status: fixed in `c109e4e3`; the query orders by the completion-check stamp
   before applying its bound and applies the age filter in SQL. Build passed
   and deployed in `maraithon-00196-k5d`.

6. **Live Gmail catch-up and runtime health require current evidence.**
   The September 5 report explicitly left Gmail catch-up unfinished. Inspect
   current source cursors, pending/failed graphs, schedule advancement,
   checkpoints, exact outcome evidence, and interval database load before
   calling this complete. Repair underlying causes instead of advancing
   unevaluated cursors or relabeling ambiguous outcomes.
   Initial status: **unhealthy**, verified at 18:56 UTC on revision
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
   Deployed in `maraithon-00196-k5d`. The stranded partition was recovered
   as described below; source catch-up remains in progress.

7. **Verify the complete product loop for Kent.**
   Confirm source-backed discovery and closure, ranked manual work, useful
   explanations and corrections, and current mobile/companion consumption of
   server state. Native changes should follow demonstrated gaps, with narrow
   builds and installation/release only for affected apps.
   The Mac client ignored pagination after its first 200 todos. It now fetches
   every page before replacing the list, deduplicates overlapping rows, and
   rejects malformed/nonterminating pagination. Swift build passed; the signed
   local app was rebuilt, installed, and launched at `~/Applications/Maraithon.app`.
   iPhone pagination and manual create/reopen paths already use the shared API.
   Direct Mac verification showed all 627 active work items after loading.
   Source catch-up remains in progress.

8. **Todo deduplication blocks the Agent's lease renewal.**
   At 19:14:11 UTC the Chief completed an effect, then entered another model
   call inside a skill's result callback. At 19:15:55 its next write failed
   with `runtime_lease_expired`. Morning briefing, commitment tracker, and
   holiday ingestion all contain this synchronous path. Move those ingestions
   to the durable model queue, retaining encrypted candidates and idempotent
   queue keys; attach results to the originating brief after ingestion.
   Yield between skills and renew authority at each continuation boundary.
   Status: implemented in `97362cfd`; build passed; deployed in workflow
   `34054609844`, revision `maraithon-00198-pzq`.

9. **Closure repeats source context too often for a large todo list.**
   The exact matrix used batches of ten todos. Increase both the fanout and
   inner checker batch to twenty and scale the response-token allowance with
   the admitted todo count. Existing prompt splitting and complete coverage
   requirements remain; Kent's 626-item list needs 32 batches instead of 63
   per source partition. Status: implemented locally; build passed; deployment pending.

10. **Planner leadership expires before otherwise valid worker leases.**
    Cloud SQL reported `expired leader incarnation cannot be revived` at
    19:25:27 UTC. Leadership had a 15-second lease while node and partition
    leases lasted 30 seconds; one coordination tick can also publish partitions
    and reconcile task proofs. Match the leader window to 30 seconds, bound
    proof reconciliation to ten assignments per tick, and renew leadership
    immediately before planning. An actually expired ready leader still needs
    a fresh node identity: detect that condition explicitly and retain the old
    identity for fenced cleanup instead of attempting a prohibited revival.
    Status: implemented locally; build passed; deployment pending.

## Delivery state

The first batch through `f3dfb2d8` deployed successfully using GitHub's existing
keyless `make deploy` workflow, run `34053264882`. Revision
`maraithon-00195-x7j` initially served 100% of traffic. The previously unpushed history was
already deployed through `d2608e73`; this delivery adds the backstop and fast
deployment changes. The same push triggered the configured mobile release
workflow for the already-present native updates (`34053264885`). It completed
successfully: TestFlight version `1.0.1`, build `20260906185611`, Founders group.

The second server batch through `4a2ded25` deployed successfully in workflow
`34053477349`. Revision `maraithon-00196-k5d` serves 100% of traffic and
`/health` reports `ok` with the combined process role.

Local deployment was unavailable: the shell's active service account belongs
to another project, Kent's cached organizational logins require reauthentication,
and the other checked credentials lack deployment access. No credentials or
IAM grants were changed. Later fixes listed above are committed locally and
were delivered by the second workflow. `591e1ba7` separately records physical
Cloud Run revision/service identity on new runtime nodes and logs their node
IDs. This and the reopening fix (`3ffe1482`) deployed successfully in workflow
`34054377367`, revision `maraithon-00197-thz`, serving 100% of traffic.

## Stranded partition recovery

The 19:03 UTC snapshot isolated partition 31, epoch 160. No Agent leases or
unreconciled Agent incidents remain. The blocker is reserved background-task
assignment `efde0e1f-c57f-499d-9be8-26f8cfcade5a`, for closure acquisition job
`b7b6e422-b6d4-40ab-b42c-702db7a86748`, node
`0f3f3c54-7106-45dd-b55d-500de76ef9e2`. Its provider boundary is `not_entered`.
It blocks 148 connector, 99 model, and 13 provider jobs at that observation.

A reconciled Agent incident on that exact node carries owner generation
`3bbe378e-e0a9-4266-b8e7-f2e83f5760c9`. Cloud Run's 21:11:37 September 5 crash
log names that exact owner under revision `maraithon-00194-xqs`, establishing
the hosting revision independently of the reused protocol/deployment revision.

After verifying no traffic targeted it and the replacement served normally,
the retired revision was deleted. Its absence and successful deletion audit
were verified. Destruction evidence is retained outside the repo at
`~/.config/maraithon/agent-termination-evidence/task-efde0e1f-c57f-499d-9be8-26f8cfcade5a-destruction.json`,
SHA-256 `408e3071957eda76ed7fdc36f0cc0c0a05e7f26ccb6c264954f587a55d071d9c`.

Execution `maraithon-runtime-recovery-b778p` recorded the identity-bound
proof at 19:10:48 UTC through `TaskTerminationAttestations.record/4` and the
existing incident-role secret inside Cloud Run with two database connections.
Ordinary runtime reconciliation settled the task as `cancelled_before_provider`
at 19:10:49. The Chief of Staff recovered at 19:10:54. The temporary incident-role
job was deleted after saving its successful execution receipt outside the repo.
The first recovery execution was cancelled before use to add the API-token
secret reference required by release startup configuration.

At 19:12:54 UTC, all 64 partitions were ready with live leases, with no pending
termination requests. Eight discovery reasoning jobs had completed since
recovery, with more source work running. The Chief of Staff completed two
effects; all 1,104 outcome-known effect assignments matched complete outcome
evidence. Source watermarks and the latest checkpoint had not yet advanced;
the backlog and the active agent cycle still needed to finish. These observations
prove recovery, not yet complete source catch-up or full runtime health.

At 19:16:20 UTC, 21 discovery reasoning jobs had completed since recovery,
with ten left pending/running in that graph. All 64 partitions remained live.
Across the 205-second interval since the prior sample, storage verification
used 245 ms of 106,778 ms total database execution time (0.23%). Node renewal
used 17,194 ms (16.1%), and partition renewal 523 ms (0.49%). Verification is
no longer the dominant load. The Agent restart described in finding 8 still
prevented a fresh checkpoint, and account cursors awaited finalization.

## Verification policy

Use `make build` and direct production observations. No automated tests are
authorized for this routine iteration. Run database diagnostics only inside
Cloud Run job executions with an `eval` override and `POOL_SIZE=2`. This report
is a working list, not a claim that the objective is complete.

At 19:22:43 UTC, all 64 partitions remained ready/live and a new idle snapshot
was saved at 19:22:39. Since recovery, 28 discovery reasoning jobs and 44 closure
reasoning jobs had completed, with 1,108 outcome-known Effects and no missing
evidence. The cursors still awaited graph finalization. This sample predates
the deferred-ingestion deployment and does not validate that fix.

At 19:26:52 UTC, Slack discovery had advanced at 19:23:45 and the independent
completion backstop had completed at 19:23:48. Since recovery, 31 discovery
reasoning jobs and 54 closure reasoning jobs had completed. The leader-expiry
recovery was still converging: 13 partitions were ready, four draining, three
preparing, and 44 unassigned, with no active or termination-requested tasks.
This is a recovery observation, not a steady-state health result. Gmail catch-up,
freshly failed source graphs, deferred ingestion, and a complete periodic Agent
cycle/checkpoint remain to verify after the next deployment.

At 19:33:33 UTC, all 64 partitions had returned to ready/live, with two running
tasks and no termination requests. Discovery reasoning completions reached 74
since recovery; 90 were pending and two running. All 18 recurring schedules
were advancing without recorded errors, and all 1,108 outcome-known Effects
still had matching evidence. The next Agent checkpoint and wakeup were due at
19:35:07 and 19:35:25, respectively.

Querying failures by `failed_at` rather than historical aggregate strings found
eight interrupted model jobs recorded as `provider_outcome_ambiguous` since
recovery, plus three dependent graph/acquisition failures. No new invalid-JSON
or incomplete-decision failures appeared in this interval. Preserve those
ambiguous outcomes and let subsequent source cycles reevaluate unfinished
coverage. The deployment/recovery interruptions explain the current failures;
fresh Gmail cursor advancement still depends on completing its source graphs.
