# 12 · Cloud saves over WebDAV

## Purpose

Sync each game's saves, its Eikon settings, and its translation glossary across the owner's devices, through a WebDAV server the user runs. Sync uses CRDTs so that concurrent changes merge on their own wherever the data allows. The user is asked only when two devices changed the same save file.

## Read first

- `planning/requirements.md`: Goal 9. "Cloud saves", "Constraints" (privacy, no program titles).
- `planning/deep_project_interview.md`: rounds 4 and 5 (backend choice, scope, conflicts, the CRDT decision).
- `planning/02-app-shell/spec.md` (settings in a CRDT-ready shape) and `planning/11-translation/spec.md` (glossary).

## Decisions already made

- **WebDAV only.** No iCloud or CloudKit (they need an Apple developer signature that none of the install methods have). No Files-folder mode, and no Dropbox or Google Drive APIs.
- **Syncs:** game saves, per-game settings, and the glossary. **Never** game files.
- **CRDTs:**
  - Settings and the glossary are CRDTs (for example, last-writer-wins registers per field, and an add-wins map for glossary entries). Concurrent edits merge without asking.
  - Each game's **set of save files** is a CRDT with per-file version vectors, so changes to different files merge without asking.
  - A save file's **contents** are opaque and can't be merged. When two devices changed the same file, the app shows both with device and time. The user picks one, and the other is kept as a backup.
  - Each device writes only its own state and op-log files on the server and merges the others'. Sync doesn't rely on WebDAV locking.
- Server credentials live in the Keychain. Remote paths use game hashes, never titles.
- Works on every build and install method.

## Scope

**In:**
- **A WebDAV client:** PROPFIND/GET/PUT/MKCOL/DELETE, ETags, HTTPS, basic and digest auth, and self-signed certificate handling as an explicit user choice. Test against Nextcloud and a plain WebDAV server.
- **Server layout** keyed by hash and device id: a per-device state or op log, and content-addressed save blobs.
- **CRDT implementation.** **Open decision:** a small purpose-built set of CRDTs or an existing library. Also: device identity, clocks, and log compaction or garbage collection.
- **Save-location interface:** each route declares where a game's saves live. This split fills it in for:
  - Wine prefix paths (AppData, Documents, and so on) and registry keys that games save to (exported and imported per key)
  - Kirikiri `savedata` (03)
  - Ren'Py save directories (10)
  - Also discovery: finding where an unknown Windows game saved, by watching the prefix.
- **When sync runs:** before launch (pull), after exit (push), and in the background where iOS allows. Offline edits queue. A game never runs on a save set that's being synced.
- **Conflict UI and backups:** retention policy, and restoring from a backup.
- **Settings UI:** server URL, credentials, per-game on/off, a last-sync status, and errors.
- **Privacy:** data goes only to the configured server. **Open question:** client-side encryption of blobs at rest on the server.

**Out:** the settings and glossary schemas themselves (02, 11), which must already be CRDT-ready.

## Needs

- 02 (settings, identity), 11 (glossary), and save locations from 03, 08, and 10.

## Done when

- Saves from original test games on each available route round-trip between two devices through a WebDAV server.
- Concurrent edits to different save files, to settings, and to the glossary merge without a prompt.
- A same-file conflict shows both versions, and the version not picked is recoverable from backup.
- A test verifies that no title appears in any remote path or payload metadata.
