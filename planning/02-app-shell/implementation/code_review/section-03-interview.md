# Code Review Interview: Section 03 - Identity

**Date:** 2026-09-29

## Discussed with user

- **#1 Rule 4 silently attaching on name similarity.** User: "never match if the only case is file similarity."
  Follow-up: "don't even suggest if the only similarity is file similarity."
  Follow-up: "it must be 100% identical to be determined to be the same game by files alone (excluding save files)."
  Asked how to check "identical": user chose **full content hash**.
  Decisions:
  - Rule 4 is removed: no attach and no suggestion from file names. The name set (`Fingerprint.names`, `Keyed8`, Jaccard, `nameSimilarityThreshold`, `MatchRule.nameSimilarity`) is removed, since nothing reads it.
  - The exact signal is an HMAC over the whole recursive tree: every normalized relative path, every file's size and full SHA-256. Save folders (save, saves, savedata, savegame, savegames at any depth), dot-files and OS metadata are excluded; symlinks are recorded by name, never followed.
  - `FingerprintBuilder.build` takes `progress` / `isCancelled`; callers run it in the background. The key file no longer feeds the fingerprint (DetectionResult.keyFile stays for detection/scanner output).

## Auto-fixes

- #2 Skip dot-files and OS metadata (Thumbs.db, desktop.ini) in the exact signal and name set; test that a .DS_Store / AppleDouble file leaves the fingerprint unchanged.
- #3 Superseded by full hashing: any unreadable file throws `IdentityError.fileUnreadable` instead of being dropped.
- #4 LibrarySecret: create with no-replace semantics (temp file + link(), read back the winner on EEXIST); random bytes from `SymmetricKey(size: .bits256)`.
- #5 merge resolves both ids.
- #6 merge keeps B's builds newest (A's added first, then B's re-added).
- #7 Content-change test changes an existing file's size, and a same-size byte deep in the tree; a save-folder test shows saves don't count.
- #9 `LocationKey.folderName` is `public private(set)`.
- #10 app.info keeps empty lines, so an empty company line doesn't shift the product.
- #11 Document that `match` expects resolved ids.

## Let go

- #8 Engine-id prefix from `detection.engine` for exe version info: the plan specifies the engine prefix; a classification change is a detector-version event anyway.
