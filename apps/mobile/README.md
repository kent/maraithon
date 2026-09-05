# Maraithon Mobile (iOS)

Native iOS app for mobile chief-of-staff workflows: Today, Todos, People, and
Chat.

## Build

From the monorepo root:

```sh
make generate-mobile
make build-mobile
```

From this directory:

```sh
xcodegen generate
xcodebuild -project MaraithonMobile.xcodeproj \
  -scheme MaraithonMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

`project.yml` is the source of truth. The generated `.xcodeproj` is ignored.
Automated tests are not part of the current manual-first loop. Do not run or
add them unless Kent explicitly asks; see
[`../../docs/development-mode.md`](../../docs/development-mode.md).

## Production Simulator Verification

Copy the example config, fill local values, then run from the repo root:

```sh
cp Config/production-verification.env.example Config/production-verification.env
make verify-production-mobile
```

This gate signs into production, exercises todos, people, and chat, then
checks the API for the expected writes.

## TestFlight

From the monorepo root:

```sh
make testflight-mobile
```

This is the deterministic dogfood path. It bumps `CURRENT_PROJECT_VERSION` in
`project.yml` to a UTC timestamp build number, regenerates the Xcode project,
archives and exports the IPA, verifies the IPA contains that build number, and
uploads it to App Store Connect/TestFlight. `make ship-mobile` is an alias for
the same path.

Use `MARAITHON_MOBILE_BUILD_NUMBER=<number> make testflight-mobile` only when an
exact build number is required.
