# Opus Review

**Model:** claude-opus-5-5 (opus-plan-reviewer subagent)
**Generated:** 2026-09-28

---

Reviewed `claude-plan.md` against the spec, the interview, `requirements.md`, and the existing EikonKit/App code, project.yml, Makefile, CI and `scripts/credits.py`. The plan is thorough and well structured. The issues are listed by severity. The first few are real design bugs rather than polish.

## Critical — fix before implementing

1. **Folder-name game ids collide across different games** (§5.2, §5.4, §6.4).
   - Two unrelated games with the same folder name get the same game id, so they share settings, saves and (later) Wine prefixes and FEX overrides.
   - This will happen: generic names such as `Game`, `data`, `v1.0`, a circle name, trial folders, or the child folders produced by "N games found inside" expansion. Referenced entries make it worse, since two drives can both hold a `Game` folder.
   - §6.4's "same normalized name → same folder id → same game → Replace files (keeps settings and saves)" states the unsafe assumption directly.
   - **Fix:** when a new entry's folder id equals an existing game id whose known build id differs (and is not a known update), mint a distinct game id (for example a random UUID or H(folderID‖buildID)) and ask the user "same game (updated) or different game?". Replace-on-import should compare build ids before promising to keep saves.
2. **The container-folder flow can never trigger** (§4.2 vs §6.4 step 2). `detect(folder:)` searches two levels down and returns the first marker directory, so `gameSubfolders(of:)` is never reached.
   - **Fix:** count marker-bearing directories first. Use a deterministic traversal order.
3. **`RenderGate` as a plain atomic bool is a race** (§9.2). The runtime can check the flag, the host can close the gate, and the runtime then commits anyway.
   - **Fix:** use an in-flight guard, `enter()` → commit → `leave()`, where `close()` waits (bounded) until nothing is in flight.
   - On iOS 15 there is no `Atomic`/`Mutex`/`OSAllocatedUnfairLock`, so use C11 atomics or `os_unfair_lock` via C.
   - Beware main-thread waits on a render thread that hops to main.
4. **The file-reading limits contradict the detection rules** (§4.2 vs §4.3).
   - A 4 KiB / 64-byte cap cannot support: XP3 index parsing (offset near the end of the file, zlib, MBs, and the krkrZ redirect header), the GameMaker chunk walk, the "few MiB" flavor scan, or PE headers with `e_lfanew` past 4 KiB.
   - **Fix:** restate the rule as bounded seek+read budgets per purpose. Decide how zlib is handled: the Compression framework wants raw deflate, so either strip the header or link libz.
5. **`encryptedFlagged` measures the wrong thing** (§4.3). Bit 31 of `info` flags is `TVP_XP3_FILE_PROTECTED` (extraction protection), not encryption. Most encrypted titles (cxdec-style) set no flag.
   - **Fix:** rename it to `protectedFlag`, and add a heuristic or defer encryption detection to 03.
6. **Privacy: the folder-name hash is dictionary-reversible, and it goes into public GitHub issues** (§10.5, §5.2).
   - SHA-256 of a guessable title can be reversed, and a build id (the hash of a published game file) can be matched against known-hash databases.
   - **Recommendation:** drop the game id from issues, or send a keyed hash or short prefix. Send the build id only if the owner accepts the risk. This conflicts with interview Q23, so ask the owner.

## High

7. **Persisted Codable models can lose all data across versions** (§6.2, §10, §11).
   - A new enum case, or a downgrade, fails to decode the whole library. The next save then overwrites it, bookmarks included.
   - **Fix:** decode per entry and drop only the bad ones, give enums an unknown fallback, treat detection as a cache, and apply the future-format read-only rule to every persisted file.
8. **The cross-device attach check can't work.** Build ids are only local.
   - **Fix:** sync known build ids per game id (for example `game/<id>/builds`), or drop the claim.
9. **Alias chains and cycles** (A→B on one device, B→A on another).
   - **Fix:** bound the hops, break cycles deterministically, and write aliases to the resolved target.
10. **Settings written before an attach are orphaned.** Either lock settings until identity is known, or migrate them on accept.
11. **Removal gaps:**
    - `removeAll(game:)` only tombstones keys this replica knows about.
    - **Fix:** a per-game `deleted-at` tombstone that shadows the prefix.
    - "Delete saves on all devices" needs a synced deletion marker, compared by timestamp.
    - Aliases that point at a deleted game need handling.
12. **The runtime `check` signature:**
    - It requires a `buildID`, which isn't known during "identifying".
    - It is `@MainActor` and synchronous, but reads files on slow drives, and it is re-run on every JIT or gate change.
    - **Fix:** take `DetectionResult` + root, run it off main (async), cache it per (game, build), and define `RuntimeCheck` in EikonCore.
13. **`preferFEXWithJIT` makes a game unavailable** when FEX is planned, failed or declined but Box64 would run.
    - **Fix:** demote it instead.
14. **Multi-platform folders lose a route.** Ren'Py and Unity often ship both Windows and Linux binaries, but only one executable is stored.
    - **Fix:** store per-platform executables.
15. **The Ren'Py key-file fallback to the main exe is the shared launcher stub**, which contradicts §5.3.
    - **Fix:** fall back to the largest `game/*.rpyc`/`.rpy`, or a manifest hash.
16. **Keep-on-drive would be offered for third-party file-provider caches** on the internal volume.
    - **Fix:** offer keep-on-drive only for external local volumes (`volumeIsInternal == false && volumeIsLocal`). Copying from providers needs `NSFileCoordinator`.

## Medium

- **Drop-in vs import race:** the atomic move can be seen by a concurrent scan. Serialize them.
- **Partially copied drop-ins:**
  - Detection runs mid-copy and gets stuck as `unknown`.
  - **Fix:** re-detect on content or mtime change, and add a quiescence delay before hashing.
  - `Inbox` is in `Documents/`, not `Documents/Games`.
- **Import robustness:**
  - Check free space first.
  - Use `beginBackgroundTask`, and handle suspension mid-copy.
  - Don't follow symlinks.
  - Replace with `replaceItemAt`.
  - Hold the security scope for the whole copy.
- **Stuck state:** a persisted `.hashing` state must load as `.pending`.
- **Hashing queue:**
  - Throttle progress updates to main.
  - Prioritize the viewed entry and small files.
  - Suspend hashing, drop-in scans and reachability checks during a game session.
- **Marker matching:**
  - Match marker names case-insensitively via directory listings.
  - Normalize NFC/NFD when pairing `<stem>.exe` with `<stem>_Data`.
- **Session host:**
  - Present from the topmost presented controller.
  - Tests need an injection seam for scene notifications.
- **Breadcrumbs:**
  - Use fixed slots written with `pwrite` at `index % 64`, plus a sequence number.
  - Snapshot breadcrumbs and the fault record into `CrashHistory` at consume time, so a report is possible later.
  - Add a periodic `os_proc_available_memory()` breadcrumb.
- **Memory-kill classification** needs a time window.
- **Fault record:**
  - Write the session id into the header.
  - Add the file to the layout and to cleanup.
- **"Try another route"** should offer only runnable routes, and must handle `test` records and records for removed games.
- **Issue URL:**
  - Percent-encode `+`, `&` and `=` explicitly.
  - Make sure the `crash` label exists.
- **`gateFailed(String)`, `gateUnmeasured(String)` and `runtimeDeclined(code: String)`** can't be mapped by exhaustive switches.
  - **Fix:** use a `GateName` type with known constants, plus a fallback string for runtime codes.
- **When this replica's own settings file has a future format** (after a downgrade), writes go nowhere. Specify what happens.
- **Gate staleness:** failed gates silently become "unmeasured, allowed" after every app update. Confirm that is intended, or keep failed results until re-measured.
- **Main-thread fsync** on every setting write, including each display-name keystroke. Commit on submit, or persist off main.
- **`test_collection_scan.py`** would run a full SMB scan on every `make test` on the owner's Mac. Gate it behind an env var.

## Low / consistency

- `requirements.md` identity wording: §2.4 says "no change", §19 says "update". It is a hard constraint, so record the owner-approved change when landing.
- The Eikon credits entry location: §2.4 says project.yml, §15 says `credits.py`. `credits.py` is correct.
- The credits caption "no third-party components" is ambiguous now that the JSON always holds Eikon. Add an `isApp` marker, and update `test_credits.py`'s empty-JSON expectation.
- Missing homes in the layout: `CollectionSummary.swift`, `RuntimeCheck`, `GameDataCleanup`, `VolumeKind`, `AccessToken`, `KnownBuild`, `IdentityState`, `ReplicaID`, `GamePlatform`.
- `AccessToken` needs an explicit `close()`, with `deinit` only as a backstop.
- §9.3 `willDeactivate` step 3 is a note, not a step.
- Pre-2017 Unity games have no `UnityPlayer.dll`, so the `_Data` rule must cover them. Expect a possible mismatch with the requirements table's counting method.
- Kirikiri flavor: parse the PE version resource instead of a bounded scan.
- The `*setup*`/`*install*` exclusions may drop real game exes. Have the scanner report exclusions as a count.
- The test "folder id differs from a plain hash of the name" pins an implementation detail. Drop it.
- `eikon-scan` top-level code is MainActor-isolated in Swift 6. Keep detection synchronous or use an explicit async main.
- MetricKit `MXCrashDiagnostic` is optional enrichment, if it is delivered for these install methods.
