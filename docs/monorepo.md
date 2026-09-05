# Maraithon Monorepo

The current manual-first workflow is defined in
[`development-mode.md`](development-mode.md). That policy takes precedence over
verification commands preserved in historical specifications and reports.

This repository owns the full Maraithon stack:

- `.`: Phoenix web app, API, connectors, OTP runtime, and GCP deployment.
- `apps/companion`: native macOS companion app for local data sync.
- `apps/mobile`: native iOS app for on-the-go chief-of-staff workflows.

The Phoenix app intentionally remains at the repository root. That keeps the
current Cloud Run release, `mix` aliases, Dockerfile, migrations, and production
runtime stable while the native clients live under `apps/`.

## Commands

Use the root `Makefile` for cross-stack work:

```sh
make generate                 # regenerate Xcode projects
make build                    # fast Phoenix compile (default loop)
make test                     # fast Phoenix compile; broad tests are opt-in
make verify                   # fast Phoenix compile; broad checks are opt-in
make build-all                # explicit request: build every stack slice
make test-full                # explicit request: all web and native tests
make verify-full              # explicit request: full verification loop
make build-web                # compile the Phoenix web/API runtime
make build-api                # alias for the Phoenix API/runtime build
make build-static             # digest and validate Phoenix/PWA static files
make build-assets             # build web static and native asset catalogs
make build-companion          # build only the macOS companion app
make build-mobile             # build only the iOS app
make verify-native            # explicit request: native verification loop
make verify-production-mobile # production simulator flow, requires local config
make deploy                   # cached single-service GCP test-app deploy
make deploy-hardened          # explicit request: staged exact-runtime rollout
```

The opt-in full verification scripts use language-native tooling:

- Phoenix: `mix precommit`
- macOS companion: `swift build`, `swift test`, and `xcodebuild`
- iOS mobile: `xcodegen` and `xcodebuild` against an available simulator
- Assets: `mix phx.digest` for Phoenix/PWA static files and `actool` for
  native asset catalogs

Set `IOS_DESTINATION='platform=iOS Simulator,id=<UDID>'` when you want a
specific simulator. Otherwise the scripts pick an available iPhone simulator.

## Generated Files

Both native apps use XcodeGen. `project.yml` is the source of truth and
`.xcodeproj` files are generated on demand, not committed. This avoids noisy
project-file conflicts and keeps source ownership clear.

## Local Config

Production mobile verification uses local, ignored config:

```sh
cp apps/mobile/Config/production-verification.env.example \
  apps/mobile/Config/production-verification.env
```

Fill in a local simulator UDID and verification account values before running
`make verify-production-mobile`.

The fast server deploy uses keyless GCP credentials and the pinned Maraithon
project settings. Local deploys require an authenticated `gcloud` session;
GitHub Actions uses Workload Identity Federation.

## CI Shape

Server-relevant pushes use the cached single-service deploy. Native-only,
test-only, docs-only, and Markdown-only changes do not trigger a server deploy,
and a newer push cancels the superseded run. CI does not run the dormant test
suite in the current mode.

Production simulator verification is explicit because it creates real API data
and requires local operator credentials.
