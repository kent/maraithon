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
   Status: implemented with a quoted, distinctive shared relationship
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
   Direct Mac verification initially showed 627 active work items; a refresh at
   20:33 UTC showed 941 after further source discovery.
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
   per source partition. Status: implemented in `a2d9dedc`; build passed;
   deployed in `maraithon-00200-zm4`.

10. **Planner leadership expires before otherwise valid worker leases.**
    Cloud SQL reported `expired leader incarnation cannot be revived` at
    19:25:27 UTC. Leadership had a 15-second lease while node and partition
    leases lasted 30 seconds; one coordination tick can also publish partitions
    and reconcile task proofs. Match the leader window to 30 seconds, bound
    proof reconciliation to ten assignments per tick, and renew leadership
    immediately before planning. An actually expired ready leader still needs
    a fresh node identity: detect that condition explicitly and retain the old
    identity for fenced cleanup instead of attempting a prohibited revival.
    Status: implemented in `a1f71b75`; build passed; deployed in
    `maraithon-00200-zm4`. Sustained runtime verification remains in progress.

11. **A transient post-deploy health request falsely reports rollout failure.**
    Workflow `34055148827` built and deployed revision `maraithon-00200-zm4`
    to 100% of traffic, then its single 15-second health request timed out.
    Both service URLs subsequently returned `ok` with the combined process
    role. Retry transient health transport/HTTP failures up to twice, and avoid
    an additional traffic update when the service already sends 100% to the
    latest revision. Retain the response-content check and a bounded retry
    window. Status: shell syntax verified; deployed in successful workflow
    `34055535413`, revision `maraithon-00201-srb`.

12. **Lease-loss cleanup skips reserved tasks and can strand a partition.**
    The 19:46:54 UTC snapshot isolated a new reserved, never-entered assignment
    `e398451c-7524-4eb8-9903-63663b0f57c8` on partition 31, epoch 166. Its
    expired node `b75c14e2-28c0-4dff-8a6e-2606f8c565c4` records the hosting
    revision `maraithon-00200-zm4`. Cleanup tried a running-only termination
    transition for reservations, then skipped the guardian when that failed.
    Route every local assignment through its exact guardian; it already
    persists never-activated proof or atomic termination intent plus monitored
    proof. Attempt all identities even when one proof must retry. Avoid repeating
    the already-completed workload-drain phases during normal shutdown.

    The same recovery showed a node expiry after slow coordination work.
    Refresh node, partition, and leader ownership before planning whenever
    preparation consumed a renewal interval. Reject expired provider-entry
    attempts with an ordinary authority-loss result before the trigger rejects
    them. Status: implemented in `03765c85`; `make build` passed; workflow
    `34056034289` deployed successfully as `maraithon-00202-fg4`.

    The Chief of Staff's three-failure guard tripped at 19:25:29 UTC and left it
    stopped. Its normal explicit start action checks that prior leases,
    operations, processing directives, and termination incidents are clear before
    resetting the guard. The normal start action reset the guard at 19:55:51 UTC;
    the Agent recovered at 19:55:59. Its snapshot advanced at 20:14:20 with
    zero subsequent crashes. Periodic-cycle verification exposed finding 14.

13. **An interrupted iPhone sync can retain a validator for unsaved data.**
    The first todo page stores the collection ETag before later pages and the
    SwiftData merge finish. A failure can then receive 304 on retry while the
    local todo list is still old. Clear that validator unless the complete list
    was fetched and saved; preserve a valid 304 response. The same cleanup also
    applies to a capped listing and local save failure. Bump the todo validator
    cache version so installed apps refetch any previously incomplete list.
    Simulator app build
    passed on iOS 26.4; no project generation was needed and tests were not run.
    Status: implemented in `5d8a42e2` and `26191c62`; workflow `34057077032`
    delivered TestFlight `1.0.1` build `20260906200907` and verified Founders
    access for Kent at 20:13:34 UTC.

14. **Source activity postpones the periodic Chief of Staff scan indefinitely.**
    At 20:14:28 UTC, the recovered Agent was running and had processed 105
    runs since the first recovery, but no new scheduled wakeup or Effect had
    occurred since 19:18. Every completed PubSub run replaced its pending
    periodic wakeup with another ten-minute delay. Continuous discovery traffic
    therefore prevented a full scheduled skill cycle. Preserve an earlier
    active wakeup within the periodic scope, atomically cancelling duplicates;
    still allow an earlier deadline and preserve unrelated one-shot scopes.
    Status: implemented in `cb580599`; `make build` passed. Workflow
    `34057595625` deployed `maraithon-00203-llz` successfully. Live periodic
    cycle verification remains pending.

15. **A source-event backlog delays already-delivered maintenance and scans.**
    At 20:19:21 UTC, checkpoint and heartbeat jobs due at 20:05 and 20:10 were
    delivered as durable Directives but still pending. At 20:22:21, 46 source
    events remained queued behind work from 19:21. Strict global oldest-first
    selection delays maintenance until the whole backlog drains. After eight
    ordinary directives, give the oldest due scheduled directive a turn, then
    resume ordinary selection. Keep all queued events and existing exact
    claim/settlement fences. Status: implemented in `89284da8`; `make build`
    passed; workflow `34057858237` deployed `maraithon-00204-r9k`.
    The 20:42:30 UTC observation had no pending/processing directives; fresh
    periodic-cycle and maintenance evidence on that worker remains pending.

16. **Native todo refresh spends most of its time building action cards.**
    The Mac's five 200-item pages took about a minute to load at 20:32 UTC.
    A Cloud Run read profile measured 617 ms for the 200-row list, 122 ms for
    source health, 47 ms for timezone, and 43 ms for related people. Serialization
    without cards took 813 ms; with cards it took 8,967 ms. Preserve the card's
    source evidence and actions while removing the repeated work identified by
    a narrower profile. The narrower sample found no per-item database queries:
    action cards took 6,843 ms, including a repeated 1,048 ms ranking pass.
    Reuse each card's ranking and sanitized metadata, and compile the public
    text-boundary expression once (`7e13bea0`). `make build` passed. A local synthetic
    200-card profile fell from 768 ms to 484 ms. The same 200 production rows
    serialized in 5,359 ms instead of 7,866 ms (32% faster), with all output
    maps identical. Workflow `34059096574` deployed `maraithon-00205-lj6`.

17. **A model-work backlog postpones other kinds of todo maintenance.**
    At 20:51:22 UTC, 68 discovery reasoning jobs still awaited their first turn
    since 20:15, while closure reasoning advanced from 65 to 82 completions.
    Another 88 todo briefs and a new Agent ingestion were pending. Exact tenant
    fairness preserves oldest-first ordering within one user, so an older
    fanout can occupy all model capacity before discovery or ingestion starts.
    Rotate model job types using the existing durable scheduling-watermark
    table, updated atomically with the exact reservation under the tenant lock.
    Preserve due-time admission, FIFO within each type, tenant quotas, urgent
    nudge/push precedence, and every execution-partition/task fence.
    Status: implemented in `40f630f9`; `make build` passed; workflow
    `34059463117` deployed revision `maraithon-00206-f8l`. At 21:01:45 UTC,
    durable workload watermarks covered eight job types. Since 20:56, discovery,
    closure, completion backstop, ingestion, and brief generation all completed
    work, proving rotation across the catch-up backlog.

18. **A drained process can rejoin after a later coordination error.**
    A database-side drain stopped node `d31038e4` from owning partitions, but
    its Session continued attempting leadership. At 20:50:45 UTC PostgreSQL
    rejected that attempt because the node was draining. The generic error
    recovery registered a fresh incarnation (`ee73283c`) at 20:50:49, which
    later owned 30 partitions despite the intended retirement. Persist local
    drain intent as a non-admitting `drain_pending` phase; observe a draining
    node on renewal, retry cleanup without leadership, and only allow explicit
    rejoin after drain completes. Retain the exact local proof and task fences.
    Status: implemented in `9ce17d46`; `make build` passed; workflow
    `34059647528` deployed `maraithon-00207-8zf` successfully at 21:02:37 UTC.

19. **The Mac bulk list fetches rich context it only needs in the inspector.**
    Request base todos for every list page and fetch one action card when its
    inspector opens. Preserve complete-list replacement, protect detail results
    against selection/refresh races, and display source evidence, the original
    source link, and a copyable suggested reply. `swift build` and the signed
    `make deploy-companion` build passed. Manual inspection showed 953 active
    items and loaded Gmail context in 0.324 seconds. A normal refresh took
    6.792 seconds, versus the earlier 37.305-second refresh with bulk cards;
    refreshing with the inspector open correctly reloaded its context.
    No todo was changed and no reply was sent during inspection.

20. **Local source cursor checks repeatedly deserialize the whole cursor.**
    The first Mac refresh still took 24.891 seconds. Its first HTTP page took
    0.986 seconds, but page two began about 20.6 seconds after page one.
    Calendar and Contacts scans completed during that gap. Both source loops
    call `shouldPush` for every record; each call reads and rebuilds the entire
    UserDefaults cursor on the main actor (4,213 calendar occurrences against
    6,899 cursor entries, plus 2,166 contacts). Snapshot each cursor once per
    cycle while retaining advancement only after acknowledged ingestion.
    Status: each scan now reuses a single cursor snapshot. Existing single-item
    callers retain their behavior, and acknowledged batches still advance the
    persisted cursor. `swift build` and signed `make deploy-companion` passed.
    The 21:09 startup fetched all 953 todos in 7.098 seconds; Calendar and
    Contacts retained the same scanned/tracked counts without new uploads.

21. **Mobile hides refreshed work until every rich-card page has arrived.**
    Today and Todos need card fields for their decision filters, so dropping
    cards from their list would change the product. Stream 200-item pages into
    SwiftData as they arrive, retaining full cards and the existing 5,000-item
    bound. Show a refresh indicator while later pages remain. Reconcile absent
    rows and retain the collection validator only after complete pagination;
    interrupted or capped listings retain useful pages and require another
    fetch. Reject late pages after sign-out, ignore rows older than local edits,
    and preserve locally created/changed items during deletion reconciliation.
    Validation: iOS 26.4 iPhone 17 simulator build passed. No project regeneration
    or schema change was needed. The app launched to sign-in; authenticated
    paging was not exercised locally because this simulator has no saved session.
    Tests were not run under the manual-first policy. Implemented in `871e245c`;
    successful workflow `34060595850` delivered TestFlight `1.0.1` build
    `20260906211723` and verified Founders access for Kent at 21:22:33 UTC.

22. **Large source graphs hold the User fence long enough to expire runtime leases.**
    Fresh stalls at 21:18:48 and 21:22:35 disproved sustained health. The live
    lock watch (`maraithon-todo-validation-q6l49`) captured the cause at 21:28:
    backend 1106004 kept one graph-preparation transaction open while repeatedly
    looking up and inserting child jobs. Its User lock blocked backend 1105011,
    which retained runtime authority locks and blocked node renewal on backend
    1106080. At 21:28:31, graph preparation had held its transaction for 27.35
    seconds; node renewal expired at 21:28:34. The Chief's restart guard tripped
    after three recent failures.

    Prepare child jobs in individual short transactions. Mark new children as
    staged and admit them only when the parent has completed and its exact
    outcome transaction has published their IDs. Failed preparation abandons
    that parent; staged children discard after parent failure, and a fresh
    source cycle retries. Reject reuse of a changed handoff. Finalizers retain
    the existing complete-coverage proof and atomic watermark settlement.
    Status: implemented in `49ab9b6b`; `make build` passed. Tests were not run
    under the manual-first policy. Workflow `34061363751` deployed revision
    `maraithon-00208-tvb` successfully at 21:35:23 UTC. The normal Agent start
    endpoint returned 200 and cleared its restart guard at 21:36:58; the Chief
    recovered to idle at 21:37:03. Live graph and sustained lease verification
    are pending.

23. **Contended renewals spend the next lease before it is committed.**
    Revision 208 lost ownership again at 21:42:29. The lock watch
    `maraithon-todo-validation-gbtr4` captured renewal backend 1106519 waiting
    18.63 seconds behind changing short transactions, rather than one long
    graph transaction. New shared lockers kept entering while renewal waited.
    The node UPDATE calculated its next deadline before acquiring the row lock;
    the Session then committed and entered a second lock queue to renew its
    partitions. Both waits depleted the available ownership window.

    Lock the live node before calculating its new deadline and retain that
    lock through partition renewal in the same transaction. Preserve the
    existing state, epoch, action-token, and database-clock expiry checks;
    expired incarnations still cannot be revived. This removes avoidable lease
    loss from the two renewal waits, but does not claim that arbitrary lock
    starvation is impossible. Status: implemented in `6ed443ba`; `make build`
    passed. Tests were not run under the manual-first policy. Workflow
    `34062219205` successfully deployed revision `maraithon-00209-mw8` at
    21:53 UTC. Fresh sustained processing evidence is pending.

24. **Failed source graphs keep consuming model capacity.**
    Execution `maraithon-todo-validation-gnrlk` confirmed that Gmail acquisition
    `2029a98b` had four ambiguous children and a failed finalizer, yet 21 children
    were pending and one was running. Slack acquisition `845cd582` likewise had
    17 ambiguous children, a failed finalizer, eight pending children, and two
    running children. These graphs cannot finalize, but their old reasoning
    jobs keep blocking healthy newer work and fresh recovery cycles.

    Before model execution, check the completed acquisition's published child
    and finalizer IDs for a terminal failure. Settle remaining work as
    `source_graph_abandoned` through the ordinary exact runner, without a model
    call. Apply this to staged graphs and older graphs with a proven child list.
    Preserve ambiguous outcomes, completed results, and cursors. The recurring
    scheduler can admit a fresh cycle when the abandoned work has cleared.
    Status: implemented; `make build` passed. Tests were not run under the
    manual-first policy. Workflow `34063346361` deployed `1f5cd979` in revision
    `maraithon-00210-5p8`. Execution `maraithon-todo-validation-2xv88` observed
    `source_graph_abandoned` settlements at 22:17 UTC. Replacement cycles and
    source catch-up remain in progress.

25. **Unchanged closure decisions generate unnecessary prose.** Exact closure
    sweeps require one explicit decision per todo, but the prompt also requested
    a reason for every negative decision. The sampled Slack batches made nine
    model calls for each group of 20 todos and found no supported completion.
    The prompt now requests only `todo_id` and `completed: false` for unchanged
    work without an acknowledgment. Completed work and acknowledgment-only
    replies retain full cited evidence, and the existing validator still requires
    the exact input todo-ID set with a Boolean decision for every item.
    **Status: implemented in `a37bfe8d`; compile passed and deployed in revision
    210.** This reduces
    requested output; latency and token savings have not yet been measured.

26. **The Mac todo list has no manual-entry action.** The paired-device API
    only exposes reads and done/dismiss/reopen, so users must switch surfaces
    to add their own work. Add a small native New Todo sheet with title, notes,
    next action, priority, and optional due time. Keep failed drafts available
    for retry, use one device-scoped UUID per draft to avoid duplicate rows,
    and retain ordinary ranking, briefs, and user activity records. The server
    allows only manual-entry fields; identity and source come from the server.
    Status: server endpoint implemented in `70589a6d` and `make build` passed.
    Native UI in `ce4b1fd1` passed `swift build` and signed `make build-companion`
    packaging with the same Apple Development identity as the installed app.
    Workflow `34063974077` deployed revision `maraithon-00211-94n`; the signed
    Mac app was installed at 22:30 UTC. Its native sheet saved manual check
    `a4471e76-f955-49b1-b1fb-d07783a4ff79` at 22:31:15, and a fresh list load
    retained it at 22:32:45. The first refresh received a transient Cloud Run
    `429 Rate exceeded`; the explicit retry succeeded. No tests were run.
    Manual entry exposed the wording defect in finding 27.

27. **Copy cleanup rewrites manually entered todos.** The live Mac entry check
    submitted `Verify Mac manual todo entry`, but the server stored and
    returned `Verify Mac manual work item entry`. The common copy-polishing
    path runs on both writes and public projections, including user text.
    Preserve wording and line breaks for `manual` and `mobile` sources, while
    retaining cleanup for generated work. Partial updates use the persisted
    source when the input omits it. Status: implemented; `make build` passed.
    Deployment and an exact-wording live check are pending. Tests were not run.

28. **Completed Mac todos still ask for action.** The live manual check moved
    to Done but retained `Needs action` and `Next:` labels. Completed rows also
    retained urgent priority styling and could say `Overdue`. Gate those cues
    on active status; retain the recorded due date and the Reopen action.
    The same detail review found that the Mac decoder omitted saved notes,
    so it now preserves and displays them in a selectable Notes section.
    Status: implemented; `swift build` and signed `make build-companion`
    packaging passed. Installation and live verification are pending. Tests
    were not run.

## Delivery state

Current server: `maraithon-00211-94n`, code through `ce4b1fd1`, deployed by
successful workflow `34063974077`. Current iPhone release: TestFlight `1.0.1`
build `20260906211723`, code through `871e245c`, available to Founders via
workflow `34060595850`. The signed local Mac development app is installed at
`~/Applications/Maraithon.app`; its 21:07 UTC refresh showed 953 active items
in 6.792 seconds with lazy source context. The subsequent cursor optimization
loaded all 953 items in 7.098 seconds on startup at 21:09 UTC.
No public Sparkle release was made.


The first batch through `f3dfb2d8` deployed successfully using GitHub's existing
keyless `make deploy` workflow, run `34053264882`. Revision
`maraithon-00195-x7j` initially served 100% of traffic. The previously unpushed history was
already deployed through `d2608e73`; this delivery adds the backstop and fast
deployment changes. The same push triggered the configured mobile release
workflow for the already-present native updates (`34053264885`). It completed
successfully: TestFlight version `1.0.1`, build `20260906185611`, Founders group.

The second server batch through `4a2ded25` deployed successfully in workflow
`34053477349`. Revision `maraithon-00196-k5d` initially served 100% of traffic and
`/health` reported `ok` with the combined process role.

Local deployment was unavailable: the shell's active service account belongs
to another project, Kent's cached organizational logins require reauthentication,
and the other checked credentials lack deployment access. No credentials or
IAM grants were changed. Server fixes were committed and
delivered through the keyless workflows recorded beside each finding. `591e1ba7` separately records physical
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


## Second recovery and stable processing

The reserved assignment in finding 12 belonged to retired revision
`maraithon-00200-zm4`, established by its node's physical Cloud Run metadata.
After verifying that no traffic targeted that revision, its deletion, absence,
and successful Cloud Audit deletion were recorded. Destruction evidence is
retained outside the repository in
`~/.config/maraithon/agent-termination-evidence/task-e398451c-7524-4eb8-9903-63663b0f57c8-destruction.json`,
SHA-256 `22ecb50d2e45bb85c21ed11f9f9aa935a4bb119c9e3c949678b5aeba73290ab5`.

Execution `maraithon-runtime-recovery-t9hgq` recorded the identity-bound task
termination proof and completed successfully at 19:55:57 UTC. The normal Chief
start action cleared its guard and persisted the desired running state; the
immediate response was `partition_not_owned` while reassignment converged.
The Watcher recovered the Agent eight seconds later at 19:55:59. Its successful
execution receipt is retained outside the repository, and the temporary
incident-role job was deleted. No cursor or ambiguous provider outcome was
rewritten.

At 20:14:28 UTC (`maraithon-todo-validation-f792r`), all 64 partitions were
ready with live leases, with three running tasks and no pending termination.
The serving node had remained the same since 19:52:02. The Agent guard had
zero crashes and no recovery requirement; its idle snapshot advanced at
20:14:20. All 1,108 outcome-known Effects retained matching evidence. Discovery
reasoning completions reached 158 since first recovery, with two pending and
three running; closure completions reached 61. All 18 recurring schedules
were scheduled ahead without persisted errors. Source cursors still awaited
complete graph coverage. No application errors were recorded on the current
revision between the Agent recovery and the 20:16 check. The moving periodic
wakeup described in finding 14 prevents calling the full loop verified yet.


At 20:19:21 UTC (`maraithon-todo-validation-98fj6`), Gmail account 2 discovery
had advanced at 20:14:44 and Slack discovery at 20:14:58. Open todos increased
to 942, with fresh source-backed discovery through 20:14:51. The second incident
assignment settled normally at 19:55:52 as `cancelled_before_provider`.

This sample also disproved sustained health: Cloud SQL reported another expired
node revival at 20:18:39 after a background task held a connection for 30 seconds.
This happened before the wakeup-fix deployment began. The runtime failed closed,
recorded one Agent crash, and settled four interrupted jobs as ambiguous instead
of inventing outcomes. No reserved task remained stranded; all 64 partitions
were ready/live again at 20:22:21. Execution
`maraithon-todo-validation-xcxn7` watches live database blockers to isolate the
remaining long transaction. Gmail account 1 and all closure cursors remain to
catch up, and full periodic work remains unverified.


At 20:42:30 UTC, all 64 partitions were ready/live on `maraithon-00204-r9k`.
The retired `maraithon-00202-fg4` node was draining and owned zero partitions.
The deployment's earlier best-effort HTTP drain had received 429. A temporary
zero-traffic revision tag reached a dormant instance, so no drain was requested
there; the tag was removed. A subsequent identity-checked invocation of
`Authority.begin_node_drain/1` committed the topology fence but returned
`partition_authority_lost` during workload cleanup. Ordinary reconciliation
completed the handoff; no incident attestation or outcome relabeling was used.
Two in-flight closure jobs were recorded as `provider_outcome_ambiguous` at
20:38:33 and require ordinary coverage recovery, not invented outcomes.

The latest sample had three running tasks, no termination requests, and no
queued/processing Agent directives. The Chief started at 20:39:10; its periodic
wakeup was due at 20:42:37. Fresh effects and checkpoints on this incarnation
still need observation. Closure reasoning had completed 75 jobs since initial
recovery, with 28 pending and two running. Discovery reasoning had completed
163, with 68 pending. Gmail account 1 and all closure cursors still lagged.
All 1,108 outcome-known Effects had matching exact evidence. The eight-minute
lock watch ending at 20:30:18 saw no transaction longer than 0.95 seconds; it
does not explain the earlier 30-second timeout.


At 20:46:00 UTC, the Chief's lease belonged to `maraithon-00204-r9k` and
remained live. Its scheduled wakeup fired at 20:42:37.783749, followed by two
settled, outcome-known completed Effects and a third running Effect. All 64
partitions remained ready/live. The retired 202 revision had no live Agent
lease, no owned partitions, and no active task assignments; its six historical
ambiguous outcomes remain intact. The 429 drain response was Cloud Run's
"no available instance" response, not an application authorization rejection.

The drained, zero-traffic revision `maraithon-00202-fg4` was deleted at
20:47 UTC after those ownership checks. No task outcome or proof was changed.


The Chief completed seven Effects in the scheduled cycle on revision 204 and
created a checkpoint at 20:49:36 UTC. The 20:51:22 observation landed during
revision 205's deployment drain (15 draining partitions, 49 unassigned, no
active tasks), so it is not evidence of post-handoff health. Kent's two intended
Google accounts and Slack workspace have tokens and are connected; the old
`kent@voteagora.com` Google connection has no tokens and reports `error`.
Its failed watch renewal does not explain the connected accounts' catch-up
backlog and must not be represented as a working source.


At 20:53:23 UTC, all 64 partitions were ready/live and the Chief was on revision
205. The database role can read/write the existing scheduling-watermark table.
The refreshed Mac displayed all 942 active items. Its five page requests ran
from 20:52:01.686762 through 20:52:38.658156, about 37 seconds in total; the
last three pages took 3.3–4.2 seconds each.

Deleting revision 202 did not immediately end its existing process: revision
logs and a newly registered node proved it remained alive. The companion has
a persistent WebSocket. Closing and relaunching the installed Mac app released
that connection, immediately followed by the old instance's SIGTERM at
20:58:16 UTC. This establishes that revision absence alone was not physical
termination evidence. No new incident attestation was recorded. Post-shutdown
ownership and proof cleanup remain to verify.


At 21:01:45 UTC (`maraithon-todo-validation-lprfk`), all 64 partitions were
ready/live on revision 206. No retired 202 node retained a live lease or owned
partitions; only its six previously recorded ambiguous outcomes remained.
The Chief held a live lease on 206, completed two new Effects, and persisted
an idle snapshot at 21:00:42. All 1,118 outcome-known Effects had matching
evidence. Three tasks were running and no task awaited termination. The
independent completion backstop and Agent ingestion both completed around
20:59. Closure/discovery cursors still awaited full coverage. Revision 207's
post-deployment observation (`maraithon-todo-validation-k6gj7`, successful)
followed at 21:08:06 UTC: all 64 partitions were ready/live on node `c7f08a86`,
the Chief held a live lease, three tasks were running, and none awaited
termination. The restart guard had no new crash since 20:18 and no recovery
requirement. All 18 recurring schedules had no persisted error. Slack discovery
advanced again at 21:03:15; Gmail and closure cursors still lagged. Since 21:02,
six discovery reasoning jobs, five closure reasoning jobs, and seven briefs
completed. Pending work included 58 discovery jobs and 81 briefs. The next Chief
wakeup was due at 21:10:42 and checkpoint at 21:13:15, so fresh periodic-cycle
proof on 207 remains outstanding. Between the 21:01 and 21:08 observations,
expensive verification accounted for about 2.53% of query execution time and
node renewal 7.71%. Cloud SQL recorded no error after the deployment through
the 21:08 log check.


At 21:13:46 UTC (`maraithon-todo-validation-z26vr`, successful), revision 207
still held all 64 ready/live partitions. Its scheduled wakeup fired at
21:10:43.484417, completed two Effects by 21:11:27, and created a checkpoint
at 21:13:15.590830. No new restart-guard crash was recorded. Discovery backlog
fell from 58 pending jobs at 21:08 to 24; briefs fell from 81 to 55. At 21:16:29
(`maraithon-todo-validation-xxsdc`), only one discovery reasoning job remained
pending, along with 38 briefs. However, Gmail account 1 closure repeatedly
references discovery acquisition `e5a82073`, whose finalizer failed. Discovery
and all closure cursors for that account still lag. This is a failed dependency
that needs inspection, not proof that catch-up has completed.


Execution `maraithon-todo-validation-wwdhh` explained the Gmail dependency:
63 of acquisition `e5a82073`'s 64 reasoning jobs completed, while job
`089197e1` became `provider_outcome_ambiguous` during the 21:02 deployment.
The finalizer correctly failed as `source_discovery_child_failed`. After the
remaining jobs finished, normal recurring discovery created acquisition
`2029a98b-1b2a-457c-ba3d-fecbd76b6b9d` at 21:17:22 with 66 fresh reasoning
partitions. This is ordinary recovery from an interrupted cycle; no receipt,
cursor, or ambiguous outcome was changed manually. The replacement cycle and
its dependent closure remain to finish before calling Gmail current.


The later observations supersede the earlier stable-looking revision-207
samples: further graph-preparation stalls interrupted work and tripped the
Chief's guard, as recorded in finding 22. Following that fix, execution
`maraithon-todo-validation-794nq` observed all 64 partitions ready/live on
revision 208 at 21:40:31 UTC, owned by node `8f5813b3`. The Chief had a ready,
live lease and zero new guard crashes; all 1,122 outcome-known Effects had
matching evidence. Its next wakeup and checkpoint were due at 21:47:01.
The large Gmail closure acquisition was still running, and no newly staged
graph was visible yet, so this sample does not prove graph publication.

That stable sample was superseded at 21:42:29 by another expired-node rejection.
Execution `maraithon-todo-validation-42sfn` observed three expired draining
partitions, 57 expired ready partitions, four unassigned partitions, and no
Agent lease at 21:43:33. The Chief's guard recorded one new crash, and Gmail
closure acquisition `1f5d8240` became `provider_outcome_ambiguous`. Source
catch-up, graph publication, and fresh automatic-completion provenance remain
outstanding. The ten-minute lock watch completed successfully at 21:48:35.

At 21:52:39 UTC, execution `maraithon-todo-validation-zxlc5` confirmed the
failed node's stored deadline was 21:42:28.854226, calculated at
21:41:58.854227 before its renewal lock wait completed. Normal recovery had
since restored all 64 ready/live partitions on revision 208; the Chief recovered
at 21:47:29, completed two Effects, and had matching evidence for all 1,124
outcome-known Effects. No task awaited termination. The workload still included
41 pending discovery reasoning jobs and 26 pending closure reasoning jobs.
No new staged graph or fresh automatic-completion provenance was visible.

Revision 209 recovered the Chief at 21:54:32 UTC. The observation execution
`maraithon-todo-validation-4w6j6` saw all 64 partitions ready/live on the same
node (`d07d5487`) at 21:55, 21:57, 21:59, and 22:01, with no new restart-guard
crash. Gmail closure acquisition `20ced29a` published 336 reasoning jobs and
completed at 21:56:26, demonstrating that large graphs now finish preparation
without the old long transaction. The scheduled Chief wakeup fired at 21:57:28
and completed two Effects by 21:58:16. Its next checkpoint remains to observe.

Execution `maraithon-todo-validation-64w64` inspected 12 completed closure
jobs. Each covered all 20 requested todos with no fetch/evaluation error and
found no supported closure. The sampled Slack batches each used nine model
calls for 411–415 source items, explaining part of catch-up latency. This proves
successful negative decisions, not a fresh automatic completion. Over the
21:59:07–22:01:07 query window, PostgreSQL spent 5.08 seconds executing queries
in total. The largest query accounted for 12.03%; the node write-lock query
accounted for 9.4%, and partition renewal for 4.92%. Expensive verification was
not among the top 12 queries. The execution completed successfully at 22:01:13.

The installed Mac app refreshed from 953 to 958 active items at 21:55 UTC.
Opening a todo loaded its source excerpt, Gmail link, suggested reply, and
actions successfully. No todo was completed, dismissed, or replied to during
this inspection; the app was left on its refreshed list.

The watch completed successfully at 22:05:42 UTC. Its final observation at
22:05:38 retained all 64 ready/live partitions on the same revision-209 node,
with a live Chief lease, no new guard crash, four running tasks, and nothing
awaiting termination. The scheduled checkpoint persisted at 22:04:32.512192;
all 1,126 outcome-known Effects had matching exact evidence. Four sampled
new Gmail children carried `parent_completion_v1` and belonged to their
completed parent's published 336-child list. They were still pending, so
execution of those new children remains to observe. At this point 25 discovery
reasoning jobs and 348 closure reasoning jobs were pending. Gmail account 2
discovery advanced at 22:04:40; Gmail account 1 discovery and all closure
cursors still lagged. Automatic completion with fresh provenance is still
unproven. These are remaining product outcomes, despite the improved runtime.
