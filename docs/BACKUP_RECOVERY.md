# Backup and Recovery

**Your saved notes are the files.** Back up the entire notes folder, including
`media/` for attached images and `.trash/` for deleted notes, using Time Machine
or another backup tool. This restores saved content and note metadata, not local
preferences, window positions, version history, or unsaved drafts.

## Local Data

NoteLume also stores data under `Library/Application Support/NoteLume/` in its
app sandbox container. This data stays on the current Mac and is not synced:

- `index.sqlite`: search data, window positions, preferences, and reminder
  delivery state. Use Settings > Data > Rebuild Search Index to rebuild search
  data without changing notes or discarding device settings. Deleting the whole
  database also loses those settings. A database that fails to open is moved
  aside as `index.sqlite.corrupt-<time>` before a new one is created.
- `Backups/<note-uuid>/`: Markdown snapshots taken before edits, external
  changes, conflicts, and deletion. The default policy keeps at most 100 versions
  per note, prunes versions older than 90 days when new snapshots are written,
  and protects the newest 10 from age-based pruning. Edit snapshots may be
  coalesced within two minutes. Images are not included in these snapshots.
- `Recovery/`: unsaved-edit drafts, offered at launch when they differ from
  saved files.

History and draft writes are best-effort, not a replacement for independent
backups. Include the local support directory in your backup if you also want
to retain history and drafts. Quit NoteLume before manually copying or replacing
its local database, including any adjacent `-wal` and `-shm` files.

## Recovery Procedures

- **Undo an edit or bad sync:** open the note's menu, choose Version History,
  select a snapshot, then Restore This Text.
- **Restore a deleted note:** choose Restore in Trash. Permanent deletion
  attempts a final text snapshot in local history, but also removes the note's
  attached images. If a snapshot is available, copy it into the notes folder
  as `<uuid>.md`; restore missing images from your independent backup.
- **Lost index or new Mac:** select the restored notes folder; NoteLume rebuilds
  search data from the saved files. Local settings and history do not follow
  the notes unless separately backed up.
- **Crash:** relaunch and choose Restore or Discard for offered drafts. Discard
  attempts to preserve the draft text in local history before removing it.
- **Folder offline:** NoteLume reports the unavailable folder. Missing notes
  are removed from the index only after a 60-second grace period and a scan
  of a reachable folder; this does not delete note files.

## Sync and Privacy

Sync the notes folder, including `media/`, rather than the local database,
history, or drafts. Reminders are stored in note metadata, so each Mac with
notifications enabled may alert. Disable reminders on individual Macs in
Settings > Reminders when needed.

Notes, images, history, and drafts are not encrypted by NoteLume. A sync provider
you choose may have access to synced files. NoteLume does not provide its own
cloud-sync service. Opening external links can launch another application;
that application's network and privacy policies apply.
