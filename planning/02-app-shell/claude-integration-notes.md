# Integration notes: Opus review, iteration 1

The review is in `reviews/iteration-1-opus.md`. The owner decided three review points directly (Q25–Q30 in `claude-interview.md`). This file records what changed in `claude-plan.md` and what didn't, and why.

## Owner decisions that reshaped the plan

- **Game drives replace copy-vs-reference** (review #1, #2, #16).
  - Games live flat inside *game drives*. The default drive is the app's Documents folder, which Files shows as "On My iPad/Eikon". Users can add folders on USB drives or local storage.
  - Import copies a game folder into a chosen game drive, and the UI states plainly that files are copied.
  - Every drive is auto-scanned.
  - This removes the "reference an arbitrary folder" mode, the container-folder expansion, and most of the keep-on-drive volume classification.
  - Folder names are unique within a drive by construction.
- **Same folder name on two drives** (#1): the same game if the build ids match. On a mismatch, the user is asked whether it is the same game (updated) or a different one. A different game gets game id H(folder id ‖ build id), recorded in a synced alias.
- **Wrapper folders:** one level down is accepted when it contains exactly one game (Q28). This replaces the two-level search that caused #2.
- **Privacy in issues** (#6): an HMAC(per-install secret, game id) short id. No build id, no folder id.
- **Gate staleness** (Medium item): passed results expire on an app or OS build change. Failed results persist, marked stale, until re-measured.

## Integrated

| # | Change |
|---|---|
| 3 | `RenderGate` becomes an in-flight guard (`enter`/`leave`/`close` waits, bounded), implemented with C11 atomics in the C target, since iOS 15 has no Swift `Atomic`/`Mutex`. `close()` never blocks main on work that needs main. |
| 4 | `FolderReader` restated as per-purpose seek+read budgets. zlib is handled by linking system `libz` (available on iOS and macOS). |
| 5 | `encryptedFlagged` renamed `protectedFlag`, with the XP3 bit-31 meaning documented. Encryption detection is deferred to 03, and the scanner doesn't claim an encryption count. |
| 7 | Persisted files decode per entry. Every enum has an `unknown`/raw fallback. Detection is a re-derivable cache. The future-format read-only rule applies to every persisted file. A persisted `.hashing` state loads as `.pending`. |
| 8 | Known build ids sync as settings keys `game/<id>/build/<hex>` (an add-only set via LWW keys), so attach and mismatch checks work across devices. |
| 9 | Alias resolution: at most 4 hops. A cycle is broken by picking the lowest hex. Aliases are always written to the resolved target. |
| 10 | Settings and launch stay locked until identity is settled: hashed, and any attach or mismatch question answered. |
| 11 | A per-game `game/<id>/deletedAt` marker shadows every older key under the prefix, including keys this replica never saw. Cleanup hooks run locally and when a merged `deletedAt` is newer than local data (12 triggers the latter). Aliases pointing to a deleted id resolve to "deleted", and a new import mints a fresh id. |
| 12 | Runtime check takes `DetectionResult` + root + optional build id, is `nonisolated` and async, and its result is cached per (game id, build id or detection fingerprint). `RuntimeCheck` moves to EikonCore. |
| 13 | `preferFEXWithJIT` is a demotion: Box64 stays runnable and ranks after FEX. |
| 14 | `DetectionResult` holds per-platform executables (`windows`, `linux`), so both Wine and Linux routes are evaluated. |
| 15 | The Ren'Py key-file fallback is the largest `game/*.rpyc`, then a hash of the sorted `game/` file manifest (names + sizes). Never the launcher stub. |
| Med | Drop-in scan vs import race: import copies into a hidden `.eikon-importing-<uuid>` folder on the destination drive, which the scanner skips, then renames. Same-volume rename is atomic. |
| Med | Partial drop-ins: re-detect when a folder's mtime or top-level listing changes, or when detection was `unknown`. Hash only after a quiescence window (size and mtime unchanged across two scans ≥10 s apart). |
| Med | Import robustness: free-space check, `beginBackgroundTask`, resumable-by-restart (a partial destination is removed on failure or at next launch), no symlink following, coordinated reads (`NSFileCoordinator`) from file-provider sources, and security scope held for the whole copy. Replace-existing uses `replaceItemAt`. |
| Med | The hashing queue throttles progress (≤4 updates/s), prioritizes the viewed entry and smaller files, and pauses (together with drive scans and reachability checks) while a game session is active. |
| Med | Marker filenames match case-insensitively from directory listings. Stem pairing uses NFC-normalized, case-folded names. |
| Med | The session is presented from the topmost presented controller. Scene notifications arrive through an injectable `SceneEvents` seam for tests. |
| Med | Breadcrumbs are fixed-size slots written with `pwrite` at `seq % 64`, which is async-signal-safe. A periodic `os_proc_available_memory()` breadcrumb is added. The breadcrumbs and fault record are snapshotted into `CrashHistory` at consume time, so a report can be filed later from the game's history. |
| Med | Memory-kill classification: a memory warning within 60 s of the last breadcrumb, or low available memory in the last memory sample. |
| Med | The fault file header carries the session id. The file is listed in the layout and in cleanup. |
| Med | "Try another route" offers only runnable routes. Test-session records and records for removed games show no route suggestion. |
| Med | Issue query values are percent-encoded explicitly (including `+ & =`). Creating the `crash` label is a checklist item. |
| Med | `GateName` becomes a `RawRepresentable` struct with known constants, and runtime decline codes are a `RawRepresentable` struct. Unknown values fall back to a generic localized sentence plus the raw code. |
| Med | If this replica's own settings file is a future format (after a downgrade), the store forks to a new replica id and shows a warning in the developer section. The old file is kept untouched. |
| Med | `SettingsStore` persists off main with coalescing (debounced ~0.5 s, and flushed on background). Display-name edits commit on submit. |
| Med | `test_collection_scan.py` needs both the mount and `EIKON_SCAN_COLLECTION=1`. |
| Low | The `requirements.md` identity wording is updated when landing (a step in the implementation order). The contradictory "no change" line is removed. |
| Low | The credits entry is generated only by `credits.py`, and entries gain an `isApp` flag. `test_credits.py` expectations are updated. |
| Low | The layout lists every new type's file. `AccessToken` has an explicit `close()`, with `deinit` as a backstop. The §9.3 wording is fixed. |
| Low | Unity detection covers pre-2017 games (via `_Data` markers). A scanner mismatch with the requirements table's `UnityPlayer.dll` count is expected to be a table correction, and the scanner reports both counts. |
| Low | Kirikiri flavor is read from the PE version resource, with the bounded string scan kept as a fallback. |
| Low | The scanner reports how many executables each exclusion rule removed, so false exclusions show up on real data. |
| Low | The "folder id ≠ plain hash" test is dropped. |
| Low | `eikon-scan` keeps detection synchronous at top level. |

## Not integrated

- **MetricKit enrichment.** It is not expected to deliver for sideloaded, TrollStore or jailbreak installs, and the value is marginal. It is left as a possible follow-up in the risks section.
- **Build id in issues (#6).** Excluded by the owner's choice.
- **Random-UUID game ids.** The owner wants game ids derivable from the folder name, so they match across devices without sync.

## Addendum: identity redesign (interview Q31, after the TDD draft)

The owner rejected the folder-name identity: folder names are fragile, there were too many prompts, and it was too complex. After a comparison of launchers (research Part D), the owner chose **random game ids + content fingerprints**. Later the owner added that a patch copied over a game's files must stay the same game. Changes:

- **§5 rewritten.**
  - `GameID` is a random UUID.
  - A `Fingerprint` holds a keyed engine-declared id, a keyed exact signal (listing + sizes + key-file head/tail hash) and a keyed name set.
  - `IdentityMatcher` has five ordered rules. Rule 1 (a known location keeps its id) covers in-place patches and Import → Replace.
  - Merge and split are explicit, non-modal actions.
- **Removed:** folder id, build id, aliases, attach and same-or-different prompts, the full-hash `HashingQueue`, and `install-secret`/`ReportID`.
  - The report id is now the first 8 characters of the random id, which reveals nothing.
  - `FileHasher` is kept only for diagnostics.
- **Settings keys:**
  - `game/<id>/fp/<scheme>/<n>` for fingerprints (append-only slots, capped at 8).
  - The global `merged/<uuid>` replaces the `alias/*` and `build/*` keys.
- **Scanner:** reports how often declared ids are present, generic, or colliding, and collisions of exact fingerprints. That tells the owner how well matching will work on the real collection.
- **Split 12 dependency:** cross-device matching needs the library secret carried between devices by 12's pairing step. Before 12, fingerprints are per-device, and that's harmless because nothing syncs yet.
- **Review items this makes moot:** #1 (folder-name collisions), #8 (cross-device builds), #9 (alias cycles; merge links have the same bounded resolution), #10 (orphaned pre-attach settings; ids are assigned within seconds, and attach is silent) and #15 (the Ren'Py stub key file; the key file is only part of the exact signal, and still never a stub).
