# Code Review Interview: Section 05 - Settings store

**Date:** 2026-09-29

No questions for the user; all findings auto-fixed.

## Auto-fixes

- #1 Fingerprints are keyed by value: `fp/<scheme>/<hash>` (SHA-256 of the sorted-keys JSON, 16 hex). Adding refreshes the same key; beyond `fingerprintCap` live keys the oldest are tombstoned; reads return the newest `fingerprintCap`. Two devices adding different fingerprints never collide; equal ones share a key. (Deviation from numbered slots.)
- #2 JSONValue gains exact integer cases (`int`, `uint`), tried before Double.
- #3 Undecodable entries in the own file are kept raw and re-emitted. Documented that adding top-level or per-entry fields requires a `format` bump.
- #4 On fork, the new replica file is written synchronously before `replica-id` is replaced.
- #5 `deinit` persists pending changes.
- #6 Clock ignores remote timestamps past year 9999 and clamps non-finite/huge dates; no overflow.
- #7 Scope mismatches read as nil / write nothing instead of trapping.
- #8 A failed persist re-arms the debounce.
- #9 `replica-id` is excluded from backup, so a restored device mints its own id and treats the restored file as a peer.
- #10 `reloadReplicaFiles` marks the store dirty when the merge changed anything.
- #11 Test: an Int setting and Int64 deletedAt round-trip through a reopen.
