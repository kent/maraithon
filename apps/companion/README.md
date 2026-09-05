# Maraithon Companion (macOS)

A native macOS companion app for [Maraithon](../..) that syncs local
context — starting with iMessage — to your Maraithon account so the assistant
sees what's happening on your machine.

## Status

In active development. v1 ships iMessage sync only; the daemon shell is
designed to grow into additional sources (Files, Voice Memos, Notes).

## Build

Two build paths are available. The current manual-first policy runs builds, not
tests, unless Kent explicitly requests hardening; see
[`../../docs/development-mode.md`](../../docs/development-mode.md).

**SwiftPM (fast inner loop, CLI binary):**

```sh
swift build
swift run Maraithon
```

**Xcode project (real `.app` bundle, signing, entitlements):**

```sh
brew install xcodegen           # one-time
xcodegen generate               # regenerates Maraithon.xcodeproj
open Maraithon.xcodeproj        # or:
xcodebuild -project Maraithon.xcodeproj -scheme Maraithon \
           -configuration Debug -destination 'platform=macOS' build
```

The dormant SwiftPM and Xcode test suites remain available for an explicitly
requested hardening pass; they are not part of the default loop.

From the repository root, prefer `make build-companion` for CLI app-bundle
builds. The monorepo helper supplies an ad-hoc signing fallback on fresh clones
and verifies the built `.app` signature before reporting success.

For local runs that need Full Disk Access, use the root launcher from the repo
root:

```sh
make run-companion
```

It builds the Debug app with stable local signing, then refreshes
`~/Applications/Maraithon.app` in place so macOS keeps granting Full Disk
Access to the same app copy across rebuilds and reloads.

When the local signing identity is first pinned or changes, the launcher clears
stale Maraithon Full Disk Access rows once before opening the app. Grant
`~/Applications/Maraithon.app` after that reset; normal `make run-companion`
reloads do not reset Full Disk Access.

If macOS still points Full Disk Access at an old development copy, reset the
privacy row manually:

```sh
make reset-companion-fda
```

The `.xcodeproj` is **not** committed — it's regenerated from
[`project.yml`](project.yml) every time. Treat `project.yml` as the source
of truth; never hand-edit the generated project.

Requires macOS 14+ and Xcode 15+ (Swift 5.9).

## Entitlements

App Sandbox is intentionally **off** so the app can read
`~/Library/Messages/chat.db` after the user grants Full Disk Access.
Distribution still ships under Hardened Runtime + Developer ID
notarization. See
[`Sources/Maraithon/Resources/Maraithon.entitlements`](Sources/Maraithon/Resources/Maraithon.entitlements).

## Project layout

Mirrors the companion desktop design specs in the root Maraithon repo.

```
Sources/Maraithon/
  App/            @main, AppEnvironment DI
  Auth/           DeviceAuth, Keychain, URL scheme handler
  Sources/        SourceProtocol, iMessage source
  Sync/           SyncEngine, MaraithonClient
  Logging/        EventLog ring buffer + persistence
  UI/             SwiftUI views
    Sidebar/
    Sources/      Per-source detail views
    Logs/
    Onboarding/
    Menubar/
  Resources/      Localizable.strings, assets
```

## Authentication model

Mirrors the Maraithon server's `UserSession` pattern:

1. App generates a per-install `device_id` (UUID).
2. User opens the pair URL in their browser, approves consent.
3. Server issues a long-lived bearer token, stores SHA-256 hash in
   `companion_devices` table.
4. Token redirected back to the app via `maraithon://device-token/<token>`.
5. App stores the plaintext token in macOS Keychain
   (`com.maraithon.companion.device_token`).
6. Every API request sends `Authorization: Bearer <token>`.
7. Revocation is server-side; the app surfaces re-pair on 401.

## Engineering rules

See [`AGENTS.md`](AGENTS.md) for the codebase conventions every contributor
(human or agent) must follow.

## License

Private.
