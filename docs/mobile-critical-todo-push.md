# Critical todo push reminders

The server checks every five minutes for a reminder due at **09:00, 13:00, or
17:00 in the user's configured briefing timezone**, every day. Each slot has a
two-hour delivery window, so temporary holds can recover without replaying old
morning reminders at night. There is no LLM call in this path.

- Critical matches the mobile app: priority **90 or higher**.
- Only visible, actionable work owned by the user and owed by the user qualifies.
  Completed, dismissed, monitoring, waiting-on, and still-snoozed work is excluded.
- Each notification lists up to three current todo titles and opens the Work tab.
- No qualifying work means no notification. There are at most three critical-todo
  reminders per local day, not three pushes per todo.
- The existing broker enforces quiet hours, the shared hourly interruption budget,
  and durable per-user/slot deduplication. Ambiguous APNs delivery is not retried.
- Discovery is bounded and cursor-paged. Sends use the existing leased provider
  lane with an APNs partition, separate from long-running source model jobs.
- The iOS app retries pending registration on foreground, sends the APNs signing
  environment, and serializes an in-flight registration before sign-out removal.
  Development/simulator tokens use sandbox; distribution tokens use production.
  Legacy registrations retain the server's configured APNs environment.

## Activation dependency

The September 5 production audit found one active device registration for Kent,
but **no APNs configuration on the serving service and no APNs secrets in the
Maraithon GCP project**. No push receipts existed for that user in the preceding
three days. Registering a device alone does not enable delivery.

Supply an Apple Developer **APNs-enabled** `.p8` key, its key ID, and team ID.
An App Store Connect upload key is not a substitute. Store key material in Google
Secret Manager outside the repository and bind these Cloud Run variables:

- `APNS_PRIVATE_KEY`: secret reference containing the PEM key.
- `APNS_KEY_ID` and `APNS_TEAM_ID`: the corresponding Apple identifiers.
- `APNS_TOPIC`: `com.bliss.maraithonmobile` (the application default).
- `APNS_ENVIRONMENT`: `production` for existing TestFlight registrations.

`MOBILE_PUSH_ENABLED` defaults to true. An explicit
`TELEGRAM_UNIFIED_PUSH_ENABLED=false` still disables the shared broker; otherwise
configured mobile delivery works independently of Telegram and the LLM provider.
The normal fast deploy now retains these existing push variables and secret refs.

After configuration, open the app signed in and allow notifications in iOS
Settings. A successful APNs response establishes provider acceptance, not proof
that a banner was displayed; verify one reminder on the physical phone as well.

## Verification for this change

- Phoenix compiled with warnings treated as errors.
- iOS simulator Debug app build passed. No Xcode project regeneration was needed
  (no native source files or project settings were added).
- Deployment script passed Bash syntax validation.
- Automated tests were intentionally not run under the current development mode.
- End-to-end push delivery remains unverified until the APNs credentials exist.
