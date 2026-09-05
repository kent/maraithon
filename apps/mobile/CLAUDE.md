# Claude Development Instructions

You are working in a native iOS 26 SwiftUI codebase. Make changes as a senior iOS engineer: small, modular, testable, and aligned with the existing app structure.

The root manual-first policy in
[`../../docs/development-mode.md`](../../docs/development-mode.md) applies and
overrides testing instructions preserved in historical specs.

## Current App Shape

```text
MaraithonMobile/
  App/
  Core/
    Auth/
    DesignSystem/
    Models/
    Persistence/
    Utilities/
  Features/
    AppShell/
    Auth/
    Todos/
    CRM/
    Chat/
MaraithonMobileTests/
project.yml
```

The app uses SwiftUI, SwiftData, Observation, Swift Testing, and XcodeGen. Do not replace this architecture with a different pattern unless the user explicitly asks for a migration.

## Decision Principles

- Prefer Apple first-party APIs and platform conventions.
- Keep code DRY by centralizing real domain rules, not by inventing generic layers.
- Keep features modular. Feature-specific behavior belongs in `Features/<Feature>/`.
- Keep shared code narrow. Shared code belongs in `Core/` only when it is used across features or is foundational.
- Keep UI code declarative and direct.
- Keep business logic testable without launching the app.
- Avoid secrets, backend assumptions, and production credentials.
- Server deployment uses the root GCP fast path; do not introduce Fly
  credentials or depend on a `flyctl` account.

## Implementation Rules

### SwiftUI

- Use native SwiftUI navigation and presentation: `TabView`, `NavigationStack`, `NavigationLink`, `.sheet`, `.toolbar`, `.searchable`, `.swipeActions`, `Menu`, `Form`, and `List`.
- Scope each tab's navigation independently.
- Use semantic text styles and system colors.
- Use SF Symbols for icon buttons.
- Add accessibility labels for icon-only and destructive controls.
- Keep views composed from small subviews when readability benefits.

### State and Data

- Use `@State` only for view-local UI state.
- Use `@Bindable` when editing SwiftData models or observable state.
- Use `@Environment` for shared dependencies such as `SessionStore` and `modelContext`.
- Use SwiftData models for persisted app data.
- Use pure helper types for filtering, search matching, validation, naming, and deterministic response logic.

### Persistence

- Save after user-visible insert, update, delete, and reset operations.
- Prefer explicit reset/seed helpers in `Core/Persistence/`.
- Keep delete order relationship-safe.
- Treat schema changes as meaningful product changes and document their
  migration impact.

### Auth

- Keep authentication UI coupled to `SessionStore`, not to a concrete provider.
- Keep provider implementations behind `AuthProviding`.
- The local Magic Signin provider is for offline development. A production Magic provider must preserve the same contract.

### Testing

- Do not add, update, or run Xcode tests or other test suites unless Kent
  explicitly requests testing or hardening.
- Do not delete or weaken the dormant suite. Keep new behavior testable.
- When testing is requested, use Swift Testing, test pure helpers directly, use
  isolated auth state and in-memory persistence, and avoid brittle SwiftUI
  layout assertions.

## Commands

Regenerate the Xcode project after source additions/removals or `project.yml` edits:

```sh
xcodegen generate
```

Build:

```sh
xcodebuild -quiet -project MaraithonMobile.xcodeproj -scheme MaraithonMobile -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' build
```

Test:

```sh
xcodebuild -quiet -project MaraithonMobile.xcodeproj -scheme MaraithonMobile -destination 'platform=iOS Simulator,id=D8E48B6C-EC1D-40AF-9D4E-913F531CACCC' test
```

Do not run this test command unless Kent explicitly requests testing.

If a destination fails because a simulator is unavailable or busy, inspect available simulators:

```sh
xcrun simctl list devices available
```

## Quality Checklist

Before finalizing a change:

- Confirm the change follows the existing `Core/` and `Features/` boundaries.
- Confirm repeated logic is extracted into focused helpers.
- Confirm new helpers are structured so tests can be added when hardening resumes.
- Confirm user-visible mutations save or surface errors.
- Confirm UI uses native controls and remains accessible.
- Run generation/build as relevant; skip tests unless Kent asks for them.
- State any skipped check clearly.

## Anti-Patterns

- Do not introduce a broad MVVM framework or generic base classes.
- Do not move all state into view models by default.
- Do not add packages for simple UI, validation, formatting, or persistence behavior.
- Do not hide feature behavior in catch-all utilities.
- Do not silently ignore errors in new user-facing workflows.
- Do not hard-code secrets or production auth configuration.

Official Apple references used as the baseline for this guidance:
- SwiftUI: https://developer.apple.com/documentation/swiftui/
- SwiftUI navigation: https://developer.apple.com/documentation/SwiftUI/Bringing-robust-navigation-structure-to-your-swiftui-app
- SwiftUI state: https://developer.apple.com/documentation/swiftui/state
- Xcode testing and Swift Testing: https://developer.apple.com/documentation/xcode/testing
