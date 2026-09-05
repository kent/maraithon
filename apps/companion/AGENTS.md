# Engineering Rules — maraithon-mac

These rules apply to every contributor — human or agent. Read all of them
before touching code.

## Apple HIG north-stars

This app must feel native. Every UI ticket is judged against these rules.

1. **Use platform primitives.** `NavigationSplitView`, `Form`, `Table`,
   `Toolbar`, `Inspector`, `LabeledContent`, `ContentUnavailableView`.
   No reinvented chrome.
2. **Defer to content.** No decorative gradients, no custom shadows, no
   bordered cards. Translucent sidebar (`.background(.regularMaterial)`)
   is the only allowed "treatment."
3. **Type uses system styles.** `.title`, `.title2`, `.headline`, `.body`,
   `.callout`, `.footnote`, `.caption`. Never hardcode
   `.font(.system(size: …))` unless rendering monospaced log lines
   (`.body.monospaced()`).
4. **Color is semantic.** `.primary`, `.secondary`, `.tertiary` for text.
   `.green`/`.orange`/`.red` only for status semantics. `.accentColor`
   for interactive elements. No custom palette.
5. **Spacing on the 8pt grid.** Use values from `Tokens.Spacing`. No
   magic numeric paddings.
6. **Icons are SF Symbols** at the configured weight (`.medium` default).
   Always paired with a text label, never icon-only buttons (except the
   menubar status item).
7. **Sheets for one-off tasks** (auth, backfill, confirmation).
   Inspectors for ephemeral inline detail. Push-navigation is reserved
   for drilling into a list.
8. **Empty / loading / error states** are first-class for every pane.
   Use `ContentUnavailableView` with `systemImage`, title, description,
   and an optional action button.
9. **Animations are defaults.** `.transition(.opacity)`, `withAnimation`
   without spring overrides. Respect `Reduce Motion`.
10. **Full keyboard nav + VoiceOver.** Every interactive element
    reachable via Tab; every non-text view labeled with
    `.accessibilityLabel`.

**Banned in this codebase:**

- ❌ `.shadow(...)` outside of pure documentation.
- ❌ `LinearGradient` / `RadialGradient` outside system materials.
- ❌ `.cornerRadius(value)` — use `.clipShape(.rect(cornerRadius: ...))`
  with a token.
- ❌ `.font(.system(size: N))` literal numbers.
- ❌ `Color(red: ..., green: ..., blue: ...)` outside `Tokens.swift`.
- ❌ Hardcoded `.padding(13)` etc. — use `Tokens.Spacing`.
- ❌ Emoji in user-visible strings.
- ❌ Icon-only buttons (except menubar status item).
- ❌ `print(...)` for runtime logging — always go through `EventLog`.
- ❌ Force-unwraps (`!`) outside tests and `@IBOutlet`-style top-level
  view properties.

## Concurrency

- Swift strict concurrency is on. All non-Sendable cross-actor calls
  must be explicit.
- UI work runs on `@MainActor`. Sources, sync engine, and the HTTP
  client are non-isolated and use `async` everywhere.
- Never block the main thread on I/O — go through `async` or
  `DispatchQueue.global()`.

## Logging

- Every state transition in `DeviceAuth`, `IMessageSource`, `SyncEngine`,
  and `MaraithonClient` emits an `EventLog` entry with a structured
  payload (`[String: String]`).
- Levels: `.debug`, `.info`, `.warning`, `.error`. Pick the most
  conservative level that still surfaces useful info.
- Logs persist to `~/Library/Logs/Maraithon/companion.log` (rotated at
  10 MB × 5 files). Never log raw message body or full handles —
  redact via `Redactor` before logging.

## Testing

- The root [`../../docs/development-mode.md`](../../docs/development-mode.md)
  policy applies here. Do not add, update, or run `swift test`, Xcode test
  actions, or other tests unless Kent explicitly requests testing.
- Do not delete or weaken the dormant tests. When hardening is requested, keep
  parser coverage fixture-based and preserve the existing `SyncEngine` and
  `DeviceAuth` invariants.
- Run `swift build` for compile sanity before finishing companion changes.

## Style

- File header doc-comment for every file describes WHAT it does and what
  invariant it preserves.
- One type per file (except small enums/structs used only inside the
  file's main type).
- File length: <300 LOC. If a file outgrows that, split.
- Naming follows Apple's API design guidelines — no `getXyz`/`setXyz`.
- Functions are short. If a function won't fit on one screen, refactor.

## Privacy

- We sync only what the user explicitly consents to.
- Default-off telemetry. Crash reports on by default, opt-out in
  Settings.
- Blocklist filtering is local — blocked handles must never leave the
  device.
- Cloud-side deletes purge the data; do not soft-delete.

## Server contracts

The server lives at the monorepo root (`../..`). When adding a new
endpoint or changing an existing payload:

1. Update the server first.
2. Deploy server.
3. Then ship the client change.

The endpoint contracts live in the root `docs/` tree. Those specs are
authoritative; if the code drifts, fix the code.

## Releases

Releases happen via `scripts/release.sh`:

1. Bump version.
2. `xcodebuild archive` (once we have a real Xcode project).
3. `notarytool submit` + `stapler staple`.
4. Build DMG.
5. Upload + update Sparkle appcast on the Maraithon server.

Never ship an unsigned build to users.
