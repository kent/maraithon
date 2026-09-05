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

No companion route creates, deletes, edits, or reassigns a Todo. Completion,
dismissal, and reopening are the only paired-device Todo mutations.
