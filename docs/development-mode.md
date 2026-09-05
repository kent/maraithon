# Current Development and Deployment Mode

Status: active until Kent explicitly changes it.
Last updated: 2026-09-05.

Maraithon is currently a single-user test application. Optimize for short
edit-to-live-feedback cycles. Kent manually tests the product after deployment;
routine engineering work must not recreate production-grade verification or
rollout ceremony around that loop.

This policy applies across the Phoenix app, runtime, macOS companion, iOS app,
CI, and deployment scripts. It is the current source of truth for workflow
choices. Test commands in old plans, completed specs, audit reports, or release
notes are historical evidence, not authorization to run them now.

## Default Development Loop

- Use `make build` or the narrowest relevant compile/build command.
- `make build` compiles the Phoenix application only.
- `make test` and `make verify` are compatibility aliases that also compile the
  Phoenix application only; they do not run test suites.
- Build a native app only when the change touches that app. Do not build every
  stack slice as a routine precaution.
- Prefer one fast compile/build check over layered lint, test, evaluation, and
  smoke-test gates.

## Testing Policy

- Do not run broad or focused automated tests by default.
- Do not run `mix test`, `mix precommit`, `make test-full`, `make verify-full`,
  `make test-web`, native test targets, Xcode test actions, or `swift test`
  unless Kent explicitly asks for testing or re-enables a hardened mode.
- Do not spend routine implementation time adding or updating tests unless the
  task explicitly calls for them.
- Keep the existing test suite intact. Do not delete, skip, weaken, or game
  tests to manufacture a green result.
- If testing is explicitly requested, treat failures honestly: fix the product
  defect or deliberately update an obsolete expectation with a rationale.

## Default Deployment Loop

- `make deploy` is the normal path.
- It uses the shared Docker layer cache, runs migrations only when migration
  files changed, deploys one combined Phoenix/runtime Cloud Run service, and
  performs one `/health` request.
- Do not add tests, full verification, Todo validation, staged revision gates,
  controller locks, drain-proof waits, traffic proofs, or repeated health loops
  to the default path.
- Server-relevant pushes to `main` deploy automatically. Docs-only, test-only,
  Markdown-only, and native-only pushes do not deploy the server. A newer push
  cancels a superseded in-progress deploy.
- The app remains pinned to GCP project `maraithon`, region `us-central1`, Cloud
  Run service `maraithon`, and Cloud SQL instance `maraithon-db`.

The application still relies on PostgreSQL leases and write fences for runtime
correctness. Removing deployment ceremony does not authorize bypassing those
in-application data-integrity rules.

## Explicit Opt-In Paths

The slower paths remain available for a deliberate hardening task:

- `make build-all`
- `make test-full`
- `make verify-full`
- `make deploy-hardened`

Do not infer permission to use them from risk, habit, a historical spec, or the
fact that they exist. Kent must explicitly request testing, full verification,
or a hardened rollout.

## Handoff Expectations

Report the narrow build/compile check that ran. State that tests were not run
under this policy. Only report a deployment when the task actually requested
one; changing deployment code does not itself authorize a live deployment.
