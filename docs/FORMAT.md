# Note file format

Each note is `<uuid>.md` (lowercase UUID) in the notes folder: YAML frontmatter, then Markdown.

```markdown
---
schema: 1
id: "7c8f2a1e-1af2-4b2c-9de1-20e046a798c3"
title: "Optional explicit title"
labels:
  - backend
color: "#F5D76E"       # background, #RRGGBB
textColor: "#111111"
opacity: 0.95          # 0.3–1
reminder: "2026-10-15T13:00:00Z"   # ISO 8601 with Z or offset (required)
sticky: true
markdown: true         # live Markdown; false for raw source editing
created: "2026-10-11T18:30:00Z"
updated: "2026-10-11T22:20:00Z"
---
Body…
```

Rules

- `markdown` is per-note and defaults to `true` when absent. The app editing-mode preference applies only when creating a note.
- The **filename UUID is authoritative**; a differing `id` is reported and can be repaired from the editor.
- Unknown keys, key order, comments and malformed values are preserved. Only lines for fields that actually changed are rewritten; an unmodified note is written back byte-for-byte.
- No title ⇒ display title is the first non-empty body line (the body is never modified to set a title).
- Missing frontmatter ⇒ opens normally; "Initialize Metadata" prepends a block without touching the body.
- Unterminated or invalid YAML, or a newer `schema` ⇒ the file is kept verbatim and metadata edits are disabled; body edits still work.
- Window position/size, search index, reminder delivery state and preferences are **never** in the file.

## Attached images

Pasted images are stored as PNG files in the notes folder's `media/` directory
and referenced using relative Markdown paths such as
`![image](media/<uuid>_<suffix>.png)`. Back up and sync that directory with the
notes. The editor renders local PNG references under `media/`, not remote
images. Version-history snapshots contain Markdown text, not image data;
permanently deleting a note also removes its associated PNG files.

## Schema migration

`schema` is an integer. Migrations are additive, idempotent, and run only when a note is edited (never on open):

- **v0 → v1**: notes without `schema` (hand-written / other tools) get `schema: 1`.

Notes with a schema newer than the app are read-only for metadata (no downgrade). Add future steps in `NoteDocument.migrateSchemaIfNeeded()` and a test in `NoteDocumentTests`.

## Conflict copies

Names like `<uuid> 2.md` or `<uuid> (… conflicted copy …).md` are treated as sync conflicts: shown under Conflicts, never indexed as notes, resolved by Keep Both / Use Copy / Discard (the other side always goes to history first).
