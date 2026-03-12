# Notaui OAuth Client Specification

Status: Draft v1
Purpose: Define the production Notaui OAuth client for Maraithon, including browser connect, PKCE code exchange, refresh handling, post-auth account discovery, and account-aware MCP request routing.

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon currently has a partial Notaui integration, but it is not aligned with the production OAuth contract that Notaui provided on March 12, 2026.

The current repository shape has three problems:

- default endpoints point at `mcp.notaui.com`, not the verified production `api.notaui.com` OAuth server
- the connector still treats `client_credentials` as the primary access path for some flows
- Maraithon does not discover or store the user’s accessible Notaui accounts after connect, so it cannot reliably target non-default accounts with `X-Notaui-Account-ID`

The immediate goal is to fix the OAuth client first. That means Maraithon must support a production-safe browser connect flow for a single signed-in user, persist refreshable Notaui tokens, discover accessible accounts right after authorization, and route later MCP calls against the correct account context.

### 1.2 Goals

- Use a standard authorization-code browser connect flow for Notaui at `/auth/notaui`.
- Use PKCE (`S256`) on the authorization redirect.
- Exchange the code on Maraithon’s backend with `client_secret_basic`.
- Store `access_token` and `refresh_token` under provider `notaui` in the existing OAuth token model.
- Call Notaui account discovery immediately after a successful token exchange.
- Persist a stable default Notaui account selection for the user without introducing a new schema in v1.
- Ensure Notaui MCP calls send `X-Notaui-Account-ID` when a request targets a non-default account.
- Surface Notaui readiness and connection status in the existing Connectors UI.

### 1.3 Non-Goals

- Building a dedicated multi-account Notaui management UI.
- Dynamic client registration via Notaui’s `REGISTER_URL`.
- Replacing every existing app-level `client_credentials` Notaui path in the same change.
- Designing higher-level Notaui agent behavior beyond account-aware connector access.
- Adding a new standalone Notaui settings page outside the existing Connectors surfaces.

### 1.4 External Contract From Notaui

The user provided the following production contract for Maraithon’s OAuth client:

| Field | Value |
|---|---|
| Redirect URI | `https://maraithon.fly.dev/auth/notaui/callback` |
| Scopes | `tasks:read tasks:write projects:read projects:write tags:write` |
| Token endpoint auth method | `client_secret_basic` |
| Issuer | `https://api.notaui.com` |
| Authorize URL | `https://api.notaui.com/oauth/authorize` |
| Token URL | `https://api.notaui.com/oauth/token` |
| Register URL | `https://api.notaui.com/oauth/register` |
| MCP URL | `https://api.notaui.com/mcp` |
| Protected resource metadata | `https://api.notaui.com/.well-known/oauth-protected-resource` |
| Auth server metadata | `https://api.notaui.com/.well-known/oauth-authorization-server` |

Production credentials are deployment secrets, not repository content. Maraithon should continue to read `NOTAUI_CLIENT_ID` and `NOTAUI_CLIENT_SECRET` from environment or secret storage and must not commit literal secret values into source control.

## 2. Current State and Problem

### 2.1 Relevant Repository Surfaces

The Notaui implementation surface already exists, but it is only partially correct for the new contract:

- [`Maraithon.OAuth.Notaui`](/Users/kent/bliss/maraithon/lib/maraithon/oauth/notaui.ex) builds auth URLs and exchanges codes, but its defaults still point to `mcp.notaui.com`.
- [`MaraithonWeb.OAuthController`](/Users/kent/bliss/maraithon/lib/maraithon_web/controllers/oauth_controller.ex) already exposes `/auth/notaui` and `/auth/notaui/callback` and stores a PKCE verifier in provider state.
- [`Maraithon.Connectors.Notaui`](/Users/kent/bliss/maraithon/lib/maraithon/connectors/notaui.ex) already supports bearer-token MCP calls, but it does not perform post-auth account discovery and does not support `X-Notaui-Account-ID`.
- [`Maraithon.Connections`](/Users/kent/bliss/maraithon/lib/maraithon/connections.ex) already renders a Notaui card in `/connectors`, but it only shows basic token metadata.
- [`Maraithon.ConnectedAccounts`](/Users/kent/bliss/maraithon/lib/maraithon/connected_accounts.ex) and [`ConnectedAccount`](/Users/kent/bliss/maraithon/lib/maraithon/accounts/connected_account.ex) can already persist one provider-level connected account row with metadata and `external_account_id`.

### 2.2 Gaps Relative To The Production Contract

| Area | Current state | Required change |
|---|---|---|
| OAuth endpoints | Defaults use `https://mcp.notaui.com` | Switch defaults to `https://api.notaui.com` |
| OAuth contract | Partial auth-code+PKCE support | Align fully to verified production values |
| Account discovery | None | Call `account.list` immediately after auth |
| Account persistence | One provider row only, no Notaui account snapshot contract | Define metadata contract for discovered Notaui accounts |
| Account targeting | No `X-Notaui-Account-ID` support | Add header only when request targets a non-default account |
| Connectors UI | Shows generic Notaui connection | Show discovered-account summary and default account |

### 2.3 Why The Existing Shape Is Risky

Without account discovery and account-aware routing, Maraithon may connect successfully but operate against the wrong Notaui account or have no way to target secondary accounts at all. Without aligning the default URLs to `api.notaui.com`, the browser connect flow is pointed at the wrong production authority.

## 3. Scope and System Boundary

### 3.1 In Scope For This Spec

- Notaui browser connect from the existing Connectors UI
- Notaui OAuth helper and controller behavior
- runtime configuration and provider setup copy
- token refresh and revoke behavior for provider `notaui`
- post-auth `account.list` discovery
- persistence of default-account and discovered-account metadata
- account-aware request routing in the Notaui MCP connector
- tests for the OAuth flow, account discovery, and header behavior

### 3.2 Explicitly Out Of Scope

- a dedicated account picker UI in the dashboard or Telegram
- full Notaui task/product UX beyond connector correctness
- migrating every historical Notaui token or account record in place
- dynamic registration against `REGISTER_URL`

### 3.3 Boundary Rule

This spec fixes the Notaui OAuth client and the account context needed for later Notaui operations. It does not define new end-user workflows beyond “connect Notaui successfully and operate against the right account.”

## 4. UX and Interaction Model

### 4.1 Connect Flow

The user flow remains within the existing Connectors surface:

1. The signed-in user opens `/connectors` or `/connectors/notaui`.
2. The Notaui card shows `Connect Notaui` when disconnected.
3. Clicking connect routes to `/auth/notaui?user_id=<current_user_id>&return_to=/connectors/notaui`.
4. Maraithon redirects the browser to Notaui’s authorize URL with PKCE challenge and requested scopes.
5. After consent, Notaui redirects back to `/auth/notaui/callback`.
6. Maraithon exchanges the code, stores tokens, calls `account.list`, stores the default account and account snapshot, and returns the user to the requested Connectors page.

### 4.2 Post-Connect UI Expectations

After a successful connect:

- the Notaui card status becomes `connected`
- the details section shows the default account label and the number of discovered accounts when available
- the details section still shows the granted scopes
- if account discovery succeeds with zero accounts, the connection is still stored but the card status becomes `partial` or `needs_attention` via a metadata-driven detail note rather than silently looking healthy

This spec does not require a new visual status enum. If the existing provider card model cannot cleanly represent this case, v1 may keep `connected` and add an explicit warning detail line.

## 5. Functional Requirements

### 5.1 Configuration Contract

Maraithon must use these environment-backed settings for Notaui:

| Env var | Required | Default | Notes |
|---|---|---|---|
| `NOTAUI_CLIENT_ID` | yes | empty | Production client id stored outside the repo |
| `NOTAUI_CLIENT_SECRET` | yes | empty | Production client secret stored outside the repo |
| `NOTAUI_REDIRECT_URI` | yes | empty | Production value is `https://maraithon.fly.dev/auth/notaui/callback` |
| `NOTAUI_SCOPE` | no | `tasks:read tasks:write projects:read projects:write tags:write` | Scope string, space-delimited |
| `NOTAUI_ISSUER` | no | `https://api.notaui.com` | Informational and diagnostic |
| `NOTAUI_AUTH_URL` | no | `https://api.notaui.com/oauth/authorize` | Used by the browser redirect |
| `NOTAUI_TOKEN_URL` | no | `https://api.notaui.com/oauth/token` | Used for code exchange and refresh |
| `NOTAUI_MCP_URL` | no | `https://api.notaui.com/mcp` | Used for MCP requests |
| `NOTAUI_REGISTER_URL` | no | `https://api.notaui.com/oauth/register` | Informational only in v1 |
| `NOTAUI_AUTH_SERVER_METADATA_URL` | no | `https://api.notaui.com/.well-known/oauth-authorization-server` | Informational only in v1 |
| `NOTAUI_PROTECTED_RESOURCE_METADATA_URL` | no | `https://api.notaui.com/.well-known/oauth-protected-resource` | Informational only in v1 |
| `NOTAUI_TIMEOUT_MS` | no | `10000` | Existing request timeout behavior |
| `NOTAUI_TOPIC_PREFIX` | no | `notaui` | Existing PubSub sync behavior |

`NOTAUI_BASE_URL` may remain as a legacy escape hatch, but the v1 contract should prefer explicit per-endpoint config and should default to `api.notaui.com`, not `mcp.notaui.com`.

### 5.2 Authorization Redirect Contract

`GET /auth/notaui` must:

- require an authenticated user and a valid `user_id`
- generate a PKCE verifier/challenge pair using the existing controller helper
- encode the `code_verifier` inside the signed provider state payload
- request the verified default scope string unless a later repository requirement introduces a narrower scope override
- redirect to `https://api.notaui.com/oauth/authorize`

The redirect query must include:

- `response_type=code`
- `client_id`
- `redirect_uri`
- `scope`
- `state`
- `code_challenge`
- `code_challenge_method=S256`

### 5.3 Callback And Token Exchange Contract

`GET /auth/notaui/callback` must:

1. validate provider state and authenticated-user match
2. exchange the code at `TOKEN_URL` using `grant_type=authorization_code`
3. include `redirect_uri`
4. include the original PKCE `code_verifier`
5. authenticate to the token endpoint with `client_secret_basic`
6. store the returned `access_token`, `refresh_token`, `expires_in`, `scope`, and token type under provider `notaui`
7. immediately perform account discovery before final success response

If account discovery fails after the token exchange succeeds, Maraithon must still persist the OAuth token, mark the connected account metadata with a discovery error, and return the user to the Connectors page with a degraded success message rather than throwing away the new grant.

### 5.4 Refresh And Disconnect Contract

- `OAuth.get_valid_access_token/2` for provider `notaui` must continue to refresh via `grant_type=refresh_token`.
- Refresh requests must also use `client_secret_basic`.
- Successful refresh replaces the stored `access_token`, `refresh_token` when present, `expires_at`, and `scopes`.
- Disconnect must revoke when a revocation URL is configured; otherwise it may continue to behave as a local disconnect.
- Local disconnect must mark the Notaui connected account row as disconnected and clear bearer tokens as today.

### 5.5 Account Discovery Contract

Immediately after a successful code exchange, Maraithon must discover the user’s accessible Notaui accounts.

v1 contract:

- call the Notaui MCP endpoint with the newly issued bearer token
- perform an `account.list` operation
- normalize the result into a repository-owned account snapshot

Assumption: `account.list` is exposed through the same MCP JSON-RPC `tools/call` surface used by existing Notaui tool calls, with tool name `account.list`. If Notaui instead requires a different MCP method shape, the implementation must adapt the transport while preserving the same repository contract below.

### 5.6 Account Snapshot Contract

The provider-level Notaui connected account row must store:

| Field | Source | Contract |
|---|---|---|
| `provider` | constant | `notaui` |
| `external_account_id` | derived | Default Notaui account id |
| `status` | derived | `connected`, `error`, or `disconnected` using existing model |
| `metadata.default_account_id` | derived | Same as `external_account_id` |
| `metadata.default_account_label` | derived | Human-readable label for the default account |
| `metadata.accounts` | discovery | Array of normalized account summaries |
| `metadata.account_count` | discovery | Integer count |
| `metadata.discovery_at` | system | ISO8601 timestamp |
| `metadata.discovery_error` | system | Last discovery failure payload when present |
| `metadata.mcp_url` | config | Effective MCP URL |
| `metadata.issuer` | config | Effective issuer |

Each normalized account summary should contain:

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Stable Notaui account id |
| `label` | yes | Best-effort human-readable name |
| `is_default` | no | Use provider-supplied default marker if available |
| `raw` | no | Omit unless needed for debugging; do not store sensitive token material |

### 5.7 Default Account Selection Rules

Default-account resolution must be deterministic:

1. If Notaui marks one account as default, use that account.
2. Else if exactly one account is returned, use it.
3. Else choose the first normalized account sorted by `label`, then `id`.

If zero accounts are returned:

- keep the OAuth token
- set `external_account_id` to `nil`
- store `metadata.accounts` as `[]`
- record a detail note so the Connectors UI shows that the grant succeeded but no accessible Notaui accounts were discovered

### 5.8 MCP Request Routing Rules

All user-scoped Notaui MCP calls must support an optional `account_id` argument at the connector boundary.

Routing algorithm:

```text
if request.account_id is nil:
  call MCP with bearer token only
else if request.account_id == connected_account.default_account_id:
  call MCP with bearer token only
else:
  call MCP with bearer token
  add header X-Notaui-Account-ID: <request.account_id>
```

The header must never be sent with an empty value.

If a caller provides an `account_id` that is not present in the persisted Notaui account snapshot, the connector should fail fast with a domain error such as `{:error, :unknown_account_id}` instead of sending a likely-invalid downstream request.

### 5.9 Tool And Connector Behavior

For this first spec phase:

- `Maraithon.Connectors.Notaui` should become the source of truth for account-aware Notaui MCP calls
- user-scoped functions such as `list_tasks/2`, `complete_task/3`, and `update_task/3` should accept optional account context internally or via an expanded argument shape
- existing app-level `client_credentials` flows may remain only for explicitly app-scoped automation paths such as sync or snapshot publishing
- user-triggered Connectors and assistant/tool flows must prefer the user OAuth grant

## 6. Data and Domain Model

### 6.1 No New Schema In v1

This spec should not introduce a new Notaui accounts table in the first pass. The existing storage model is sufficient if Maraithon treats the provider-level connected account row as the summary record for the connected Notaui tenant set.

### 6.2 Token Metadata Contract

The OAuth token row for provider `notaui` should store:

- `metadata.issuer`
- `metadata.mcp_url`
- `metadata.account_count`
- `metadata.default_account_id`
- `metadata.default_account_label`

This keeps token inspection and Connectors rendering consistent without requiring a join back to `connected_accounts` for every simple summary.

### 6.3 Connected Account Metadata Is Canonical For Account Selection

The connected account row is the canonical source of truth for:

- default Notaui account id
- discovered account summaries
- last discovery result

The OAuth token row is supporting metadata only. If the two drift, the connected account row wins for request routing.

## 7. Backend / Service / Context Changes

### 7.1 `config/runtime.exs`

- update Notaui defaults from `mcp.notaui.com` to `api.notaui.com`
- add issuer and metadata URL config keys
- keep endpoint overrides environment-driven
- do not embed production secrets in source

### 7.2 `Maraithon.OAuth.Notaui`

- update default URLs to the verified production endpoints
- keep auth-code + PKCE support
- keep refresh support
- expose normalized config helpers as needed for downstream discovery and diagnostics

### 7.3 `MaraithonWeb.OAuthController`

- keep the existing `/auth/notaui` and callback route shape
- after storing tokens, call a Notaui account-discovery helper before final redirect
- write success and degraded-success response payloads that include default-account summary when available

### 7.4 `Maraithon.Connectors.Notaui`

- add a dedicated account discovery function
- normalize account discovery results
- add optional account-aware header injection
- validate requested `account_id` against the persisted snapshot before dispatch
- preserve current `Req` usage and existing timeout handling

### 7.5 `Maraithon.Connections`

- update provider setup details to the new production endpoints and env names
- render default-account and discovered-account details on the Notaui card
- show a reconnect/attention message when discovery failed or no accounts were found

## 8. Frontend / UI / Rendering Changes

No new page is required. The change is limited to the existing Connectors UI:

- `/connectors` card copy for Notaui
- `/connectors/notaui` detail view
- provider setup metadata rendered by `Connections.provider_setup/1`

The Notaui connector display should include:

- connection state
- default account label when known
- discovered account count
- granted scopes
- operator-facing setup notes for redirect URI, PKCE, and `client_secret_basic`

## 9. Observability and Instrumentation

The implementation should emit or log enough detail to debug OAuth and discovery failures without leaking secrets.

Required telemetry/logging points:

- Notaui auth redirect initiated
- token exchange success/failure
- token refresh success/failure
- account discovery success/failure
- MCP request rejected due to unknown `account_id`

Required metadata:

- `provider: "notaui"`
- `user_id`
- `account_count` when discovery succeeds
- failure class, not raw secret-bearing payloads

Tokens, authorization codes, refresh tokens, and raw `Authorization` headers must never be logged.

## 10. Failure Modes, Edge Cases, and Backward Compatibility

### 10.1 Expected Failures

| Case | Expected behavior |
|---|---|
| Missing Notaui env config | Notaui shows `not_configured`; `/auth/notaui` rejects cleanly |
| OAuth callback missing `code` or invalid `state` | Return existing bad-request behavior |
| Token exchange fails | Do not store token; show provider-specific failure |
| Token exchange succeeds, discovery fails | Store token; mark discovery error in metadata; return degraded success |
| Discovery returns zero accounts | Store token and empty account snapshot; show warning detail |
| Refresh succeeds without new refresh token | Keep old refresh token if provider contract permits |
| Caller supplies unknown `account_id` | Fail locally with domain error |
| Caller uses default account or no account id | Do not send `X-Notaui-Account-ID` |

### 10.2 Backward Compatibility

- Existing Notaui code paths that still use `client_credentials` may remain temporarily for app-level automation only.
- Existing users with Notaui records created against old endpoints should reconnect rather than relying on silent migration.
- No destructive data migration is required for the first pass; stale metadata can be replaced on the next successful connect.

## 11. Rollout / Migration Plan

1. Update runtime defaults and provider setup text to the verified `api.notaui.com` endpoints.
2. Land the OAuth helper/controller/account-discovery implementation.
3. Deploy production secrets through Fly or the current secret manager:
   - `NOTAUI_CLIENT_ID`
   - `NOTAUI_CLIENT_SECRET`
   - `NOTAUI_REDIRECT_URI`
4. Verify `/auth/notaui` end to end in production.
5. Reconnect any pre-existing Notaui grant so account discovery data is populated under the new contract.

No database migration is required unless implementation discovers that the existing metadata payload is too large or too ambiguous to support account routing safely.

## 12. Test Plan and Validation Matrix

| Area | Required validation |
|---|---|
| OAuth helper | authorize URL uses `api.notaui.com`, includes PKCE params, scope string, and redirect URI |
| Token exchange | backend code exchange uses `client_secret_basic` and includes `code_verifier` |
| Refresh | refresh request uses `client_secret_basic` and updates stored tokens correctly |
| Callback success | `/auth/notaui/callback` stores token and account snapshot |
| Callback degraded success | callback stores token even when `account.list` fails |
| Account normalization | default account selection is deterministic for 0, 1, and many accounts |
| Connector routing | `X-Notaui-Account-ID` added only for non-default account requests |
| Unknown account guard | invalid `account_id` fails locally |
| Connections UI | Notaui card renders default account, count, and setup guidance |

`mix precommit` is the required verification gate once implementation begins.

## 13. Definition of Done

- Notaui browser connect works against `https://api.notaui.com`.
- `/auth/notaui/callback` stores refreshable tokens under provider `notaui`.
- Post-auth account discovery runs automatically and persists a default account plus account snapshot.
- The Connectors UI reflects the new Notaui connection details.
- User-scoped Notaui connector requests support account-aware routing with `X-Notaui-Account-ID`.
- Tests cover the OAuth flow, discovery behavior, and request-header rules.
- Production secrets are documented as env requirements, not committed to source.

## 14. Assumptions and Open Questions

### 14.1 Assumptions

- Notaui’s `account.list` capability is callable over the same authenticated MCP transport as other Notaui operations.
- The account discovery payload contains a stable account id and enough display fields to derive a usable label.
- `X-Notaui-Account-ID` is required only when targeting a non-default account and should be omitted otherwise.

### 14.2 Open Questions

- Whether Notaui exposes a revocation endpoint suitable for real token revocation remains unconfirmed.
- Whether account discovery should be re-run automatically after every successful refresh is deferred; v1 requires it immediately after initial connect only.
- Whether future assistant/tool surfaces should expose account choice directly is intentionally deferred until the OAuth client is stable.
