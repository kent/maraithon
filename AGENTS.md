# Maraithon engineering rules

Maraithon is a todo list that keeps itself current. A user's Chief of Staff
agent reads their inbox, calendar, Slack, and other sources, turns commitments
and follow-ups into todos, keeps them ranked, marks them done when the world
says so, and briefs the user. Everything else in this repository (connectors,
runtime, mobile, companion) exists to make that todo list trustworthy. When a
change does not make the todo list more accurate, timelier, or easier to act
on, question it.

## Monorepo layout

- The Phoenix web app, API, connectors, OTP runtime, migrations, and Dockerfile
  live at the repository root.
- The native macOS companion app lives in `apps/companion`.
- The native iOS app lives in `apps/mobile`.
- The default loop is intentionally small for this single-user test app:
  `make build`, `make test`, and `make verify` compile the Phoenix app only,
  and `make deploy` uses the cached single-service deployment path.
- Full cross-stack work is explicit: use `make build-all`, `make test-full`,
  `make verify-full`, or `make deploy-hardened` only when Kent explicitly asks
  for that broader scope.
- Use independent targets when you only need one slice:
  `make build-web`, `make build-api`, `make build-static`,
  `make build-assets`, `make build-companion`, and `make build-mobile`.
- Native apps use XcodeGen. Treat each `project.yml` as the source of truth
  and do not commit generated `.xcodeproj` files.

## Product focus: the todo list

- The unit of value is a todo the user trusts: sourced from something real
  (an email, a meeting, a Slack thread), explained in one line, ranked, and
  closed automatically when evidence arrives. Todo surfaces (`/todos`, the
  mobile todo list, the daily brief) come first; connector and runtime pages
  are operational and stay row-oriented and quiet.
- The Chief of Staff (`Maraithon.Behaviors.AIChiefOfStaff` plus the skills in
  `lib/maraithon/chief_of_staff/skills`) wakes every 10 minutes by default,
  fetches a source bundle, runs its enabled skills as LLM effects, and emits
  todos, insights, and briefs. Recurring discovery schedules
  (`Maraithon.Runtime.RecurringJobs`) run every 1 to 30 minutes and fan work
  out to per-account and per-user partitions. Both must be observably alive in
  production; see "Runtime health" below.

## The exact OTP runtime

- PostgreSQL is the authority for ownership; BEAM processes are hints. Node
  incarnations, partitions, leaders, Agent leases, and task assignments are
  leased rows fenced by triggers. Never persist ownership or outcomes from a
  process that cannot prove its lease in the same transaction.
- `Maraithon.Runtime.Coordination.Session` (one per node) registers the node,
  renews node and partition leases every 2s, runs the planner, and publishes
  its scope to ETS. `Scope.current/0` reads that publication and never blocks
  on the GenServer. Do not add synchronous calls into the Session from inside
  database transactions that hold row locks.
- Exact-protocol storage verification (catalog fingerprints, roles, ACLs,
  manifest digest) is expensive on managed PostgreSQL. It runs through
  `StorageVerificationCache` (bounded, positive-only, cleared on activation).
  Activation preconditions and activation itself always verify uncached.
- Every write that records a task outcome, activates a task, or settles an
  assignment must set the transaction-local task action (`set_action!`)
  before touching `runtime_task_outcome_evidence` or
  `runtime_task_assignments`; the triggers reject anything else.
- Each user's Chief of Staff is a `gen_statem` (`Maraithon.Runtime.Agent`)
  with an `AgentWatcher` monitor, a durable restart guard (3 crashes per 10
  minutes trips it and stops the Agent), and checkpoint snapshots capped at
  1 MiB. Behaviors that carry large transient data implement
  `snapshot_state/1` to strip it before a checkpoint.
- A node that dies with unproven tasks leaves its partition `draining` until
  the tasks are proven terminated. Deploys drain the serving revision through
  `/api/v1/runtime/drain` before replacing it on the opt-in hardened path. The
  normal single-user test-app deploy intentionally uses a rolling combined
  service and relies on PostgreSQL leases instead of making drain proof a
  deployment gate. A stranded task needs an
  incident-role attestation (`mix maraithon.tasks.attest_terminated` for
  background jobs, `mix maraithon.effects.attest_terminated` for Effects,
  `mix maraithon.agents.attest_terminated` for Agents) with real destruction
  evidence; see `docs/exact-agent-runtime-cutover.md`.
- The six canonical database roles (`maraithon_object_owner`, `_migrator`,
  `_runtime`, `_payload_verifier`, `_incident_operator`,
  `_activation_operator`) are fingerprinted including their memberships. Never
  `GRANT` other roles to them; every readiness proof turns false and new
  revisions refuse to boot.

## Runtime health

Before calling the runtime healthy, check all of these in production:

- `runtime_partitions`: every row `ready` with a live lease; no `draining`.
- `runtime_task_assignments`: nothing stuck in `termination_requested`.
- `background_jobs WHERE queue = 'runtime_recurring'`: each schedule's
  `scheduled_at` is in the near future and advancing on its interval.
- The Chief of Staff logs `Exact Agent recovered, transitioning to idle`
  within seconds of a start, `effect_completed` events with matching
  `runtime_task_outcome_evidence` rows, and `checkpoint_created` events with
  no `snapshot_persist_failed`.
- `pg_stat_statements` (enabled) shows no verification or renewal query
  dominating total time.

Cloud SQL server logs (`resource.type="cloudsql_database"`) show trigger
messages the application redacts; read them first when the app reports
"database access failed".

## Project guidelines

- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- Deploy the test app to Google Cloud with `make deploy`. It is pinned to project `maraithon`, region `us-central1`, Cloud Run service `maraithon`, and Cloud SQL instance `maraithon-db`. Server-relevant pushes to `main` deploy through `.github/workflows/deploy-gcp.yml`; native-only, test-only, docs-only, and Markdown-only pushes do not. Use `make deploy-hardened` only when an exact staged rollout is explicitly requested.
- CI authenticates keylessly through the `maraithon-github` Workload Identity provider as `admin-deployer@maraithon.iam.gserviceaccount.com`; do not create or commit service-account keys.
- Keep operator credentials outside the repo and application secrets in Google Secret Manager. Never commit admin passwords, API bearer tokens, database URLs, LLM provider keys, or OAuth secrets.
- Production checks run as Cloud Run job executions with an `eval` override (`--args="^@^eval@<elixir>"`, `--update-env-vars POOL_SIZE=2`), never from a laptop against the database.

## Current verification mode

- [`docs/development-mode.md`](docs/development-mode.md) is the authoritative
  workflow policy until Kent explicitly changes it. It overrides test or
  verification commands embedded in historical plans, specs, reports, and
  release notes.
- Product iteration is manual-first. Do not run or add broad or focused tests
  by default. In particular, do not run `mix test`, `mix precommit`,
  `make test-full`, `make verify-full`, slice-specific test targets, Xcode test
  actions, or SwiftPM tests unless Kent explicitly asks.
- Use `make build` or the narrowest relevant compile/build sanity check.
  `make test` and `make verify` are retained as compile-only compatibility
  aliases and do not execute tests.
- Keep the dormant test suite intact. Do not delete, gut, skip, weaken, or game
  tests. When Kent explicitly requests hardening, restore the appropriate test
  discipline for that task.

## Testing principle

- Existing tests preserve useful hardening knowledge, but they are not part of
  the current routine loop. Only when testing is explicitly requested, a
  failure means either the product has a defect or the expectation is obsolete;
  fix one of those causes deliberately rather than working around the failure.

## Design guidelines

- Follow `DESIGN.md` for all product UI work. Treat it as a required design contract, not optional inspiration.
- Find components before building components. Use the app primitives in `lib/maraithon_web/components/core_components.ex` first, then the local Catalyst kit at `/Users/kent/bliss/aitools/catalyst-ui-kit`, then the Catalyst docs at https://catalyst.tailwindui.com/docs.
- Preserve the Catalyst/Tailwind UI look and feel across every surface. Do not add bespoke one-off Tailwind component systems when a shared primitive or Catalyst pattern exists.
- If a new UI primitive is necessary, make it a small reusable wrapper around a Catalyst pattern and use it consistently.
- Keep operational pages clean, minimal, and row-oriented. Prefer compact tables or list rows over large decorative cards.
- Summary pages should show the highest-signal rollup only. For connectors, the main row should show the connector name, status, and how many accounts are connected; individual accounts belong on the connector detail page.
- Make rows clickable when they drill into details. Keep secondary actions small, aligned, and visually quieter than the row content.
- Avoid gradient hero sections, oversized marketing copy, nested cards, and heavy shadows in the app UI. Use restrained borders, consistent spacing, and 8px or smaller border radii.
- When a page needs account-level detail, render each account as its own clean row with status, last update, and actions.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- When Kent has explicitly requested testing, debug failures with the narrowest
  file command (`mix test test/my_test.exs`) or the previously failed set
  (`mix test --failed`). These commands are not part of the default loop.
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- This section applies only when Kent explicitly requests testing; it does not
  re-enable tests in the current manual-first mode.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->
