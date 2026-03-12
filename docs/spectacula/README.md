# Spectacula

Canonical specs live in [specs](./specs). Each spec also has exactly one JSON manifest in the current stage directory:

- `specs/` for drafting and revision before approval
- `ready/` for approved specs waiting for implementation
- `inprogress/` for active implementation
- `done/` for completed work

Rules:

- Keep the Markdown spec in `specs/<slug>.md` as the source of truth.
- Move only the JSON manifest between stage directories.
- Do not duplicate the full spec body in manifests.
- Store enough metadata in the manifest to answer status questions and resume interrupted work.

Supporting directories:

- [templates](./templates) for reusable starting points
- [examples](./examples) for sample spec + manifest pairs

Recommended manifest fields:

- `spec_id`
- `slug`
- `title`
- `stage`
- `spec_path`
- `updated_at`
- `summary`
- `next_action`
- `resume_context`
- `history`

Recommended workflow:

1. Copy `templates/spec.template.md` into `specs/<slug>.md`
2. Copy `templates/manifest.template.json` into `specs/<slug>.json`
3. Draft until approved
4. Move the manifest to `ready/`
5. Move the manifest to `inprogress/` when implementation starts
6. Move the manifest to `done/` only after verification and final review against the spec
