# Companion Todos API

The macOS companion uses its paired-device bearer token for a least-privilege
Todo surface. It must not send that token to `/api/mobile`, and it must never
embed the operator API bearer.

## Authentication

Send the token stored by the companion in the macOS Keychain:

```http
Authorization: Bearer <paired-device-token>
```

The server hashes this token and resolves its non-revoked `companion_devices`
row. The authenticated device determines the user. Todo IDs are always scoped
to that user. A request cannot select or change its user.

A missing, invalid, or revoked token returns:

```json
{"error":"unauthorized"}
```

The client must clear account-backed Todo state and ask the user to pair again
when it receives `401`.

## List Todos

```http
GET /api/v1/companion/todos?status=active&sort=rank&dir=desc&limit=200&include_cards=true&open_cards_only=true
```

This is the same public JSON contract as the native mobile Todo endpoint.
`status=active` includes `open` and `snoozed`; `status=done` returns completed
items; `status=all` returns every status. `q`, `attention`, `source`, and `due`
filters are also supported. Responses include a strong `ETag` and
`Cache-Control: private, no-cache`.

```json
{
  "todos": [
    {
      "id": "uuid",
      "title": "Confirm the production rollout",
      "summary": "The launch owner needs confirmation.",
      "next_action": "Review the rollout and reply.",
      "source": "slack",
      "priority": 90,
      "status": "open",
      "due_at": "2026-08-27T17:00:00Z",
      "snoozed_until": null,
      "updated_at": "2026-08-26T19:00:00Z"
    }
  ],
  "pagination": {"limit": 200, "offset": 0, "count": 1, "next_offset": null}
}
```

With `include_cards=true`, each eligible open item can include the curated
public `action_card` used by Maraithon's action surfaces. Internal prompt,
model, and scoring metadata is never serialized.

## Get a Todo

```http
GET /api/v1/companion/todos/:id?include_cards=true
```

The response is `{"todo": TODO}`. A missing or different-user ID returns 404.
Completed todos include `closed_at` and may include a human-readable
`metadata.resolution_note`. The Mac shows that note as the completion
explanation and treats the original summary as historical context. It does
not display active-work advice or suggested replies for completed todos.

## Create a Manual Todo

```http
POST /api/v1/companion/todos
Content-Type: application/json
```

```json
{
  "request_id": "a UUID retained across retries of this draft",
  "title": "Review the launch checklist",
  "notes": "Optional context",
  "next_action": "Open the checklist and review outstanding items",
  "priority": 50,
  "due_at": "2026-09-07T17:00:00Z"
}
```

`request_id` and a nonblank title are required. The title must be 4–240
characters. Notes, next action, priority (0–100), and due time are optional.
An omitted next action uses the title. The response is `201 {"todo": TODO}`;
invalid input returns 422. Reusing a draft's request ID updates that same
manual item rather than creating a duplicate. Its key is scoped to the paired
device and user. A new draft must use a new UUID.

The server sets the source to `manual`, records user creation activity, and
uses the ordinary todo ranking and brief path. Input cannot choose another
user, owner, source, source item, metadata, or status.

## Complete a Todo

```http
POST /api/v1/companion/todos/:id/actions/done
```

This records the normal user completion lifecycle and outcome-learning event.
It is idempotent for an already completed Todo.

```json
{"action":"done","todo":{"id":"uuid","status":"done"}}
```

## Reopen a Todo

```http
POST /api/v1/companion/todos/:id/actions/reopen
```

This restores the Todo to `open` and clears close/snooze timestamps. It is
idempotent for an already open Todo.

```json
{"action":"reopen","todo":{"id":"uuid","status":"open"}}
```

## Dismiss a Todo

```http
POST /api/v1/companion/todos/:id/actions/dismiss
```

This records the normal user dismissal lifecycle and removes the Todo from the
active list. It is idempotent for an already dismissed Todo.

```json
{"action":"dismiss","todo":{"id":"uuid","status":"dismissed"}}
```

The companion cannot delete, reassign, or arbitrarily edit existing Todos.
Manual draft submission, completion, dismissal, and reopening are the only
paired-device Todo mutations.
