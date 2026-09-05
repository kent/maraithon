# Claude Instructions

Follow `AGENTS.md` for engineering rules and `DESIGN.md` for product UI direction.
The current workflow policy is [`docs/development-mode.md`](docs/development-mode.md);
historical specs and reports do not override it.

## What this app is

Maraithon is a todo list kept current by an always-on Chief of Staff agent.
It reads a user's inbox, calendar, and Slack, turns commitments into ranked
todos, closes them when evidence arrives, and briefs the user. Prioritize
changes that make the todo list more accurate, timelier, or easier to act on.
Connector and runtime pages are operational surfaces: quiet, row-oriented.

## Runtime and deploys

- The single-user test app runs on GCP Cloud Run (project `maraithon`, region `us-central1`, Cloud SQL `maraithon-db`). Every server-relevant push to `main` uses the fast path (`make deploy` → cached Cloud Build → migrations only when migration files changed → one combined-service deploy → one health probe). `make deploy-hardened` retains the exact staged rollout for explicit use.
- The runtime is the exact OTP runtime described in `AGENTS.md`: PostgreSQL owns leases and proofs, the coordination `Session` renews them, each user's Chief of Staff is a `gen_statem` with a restart guard and checkpoints, and recurring schedules discover work. The Chief of Staff must wake every 10 minutes and recurring schedules every 1 to 30 minutes; verify with the "Runtime health" checklist in `AGENTS.md` before declaring anything fixed.
- A local `make deploy` needs `gcloud` access to the `maraithon` project. CI reads the Agent termination public key from the repo variable `AGENT_TERMINATION_ATTESTATION_PUBLIC_KEY`; local deploys reuse the current service setting when it is unset.
- Read-only production checks: execute the `maraithon-todo-validation` or `maraithon-migrate` Cloud Run job with `--args="^@^eval@<elixir>"` and `--update-env-vars POOL_SIZE=2`; read the printed marker back with `gcloud logging read`. The `eval` string must not contain `@`.
- Never `GRANT` anything to the six canonical `maraithon_*` database roles; the readiness proofs fingerprint their memberships and new revisions refuse to boot.
- Incident-role work (task/agent termination attestations after a node dies with unproven work) uses the incident operator role with real destruction evidence; see `docs/exact-agent-runtime-cutover.md`.
- Never commit GCP tokens, operator credentials, API tokens, database URLs, or OAuth secrets.

## Current Verification Mode

- Product iteration is manual-first. Do not run or add broad or focused tests
  unless Kent explicitly asks for testing or re-enables hardening.
- `make build` is the default compile check. `make test` and `make verify` are
  compile-only compatibility aliases; neither runs tests.
- Do not run `mix test`, `mix precommit`, full/slice test targets, Xcode test
  actions, or `swift test` by default. Keep the dormant suite intact.
- `make deploy` is the cached single-service path. Use `make deploy-hardened`
  only when Kent explicitly requests a hardened rollout.

## Testing Principle

- Existing tests preserve hardening knowledge but remain dormant in the current
  loop. When Kent explicitly requests testing, do not ignore, skip, or game a
  failure: fix the product defect or deliberately update an obsolete
  expectation with a rationale.

## Design Defaults

- Use the Catalyst/Tailwind UI look and feel from `DESIGN.md` on every app surface.
- Find components before building components: check `core_components.ex`, then `/Users/kent/bliss/aitools/catalyst-ui-kit`, then the Catalyst docs.
- Do not invent one-off UI systems or repeated raw Tailwind strings when a shared primitive or Catalyst pattern exists.
- Keep Maraithon clean, minimal, and row-oriented; the todo list is the product, everything else supports it.
- Summary pages should show rollups, not raw detail. Connector summary rows show how many accounts are connected; the detail page owns individual account rows.
- Make drill-in rows clickable and keep secondary actions compact.
- Avoid gradient heroes, nested cards, heavy shadows, and decorative layout.
