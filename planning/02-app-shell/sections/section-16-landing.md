# Section 16: Landing

## What this section is

This is the last step of split 02 (App shell). It writes no new product code. It closes out the split:

1. Record the owner's identity and game-drive decision in `planning/requirements.md`.
2. Run the full test and release pipeline: `make test`, archive, package, verify.
3. Run the collection scanner against the owner's game share and reconcile its counts with the requirements table.
4. Make sure the `crash` label exists on GitHub, and confirm that issue-form prefill works on the real repo.
5. Run the manual device checks, record the results by engine and hash only, and file a device report.

**Dependencies.** Everything below assumes these sections are done:
- section-04-collection-scanner: `eikon-scan`, `make scan-collection`, and `tests/test_collection_scan.py`.
- section-13-library-ui: library, import, drives, game detail and the crash banner.
- section-14-device-screen: the "This device" screen, the developer section and `TestPatternRuntime`.
- section-15-credits.

Transitively it also needs every earlier section: EikonCore, detection, identity, settings, routes, sessions and crash, the gate store, the library and drives, the session host, the crash report controller, and strings and navigation.

## Background

Eikon is an iPhone and iPad app. One app binary ships as two artifacts: a Dopamine rootless deb (`com.getboolean.eikon.rootless`) and an `Eikon-<v>.ipa` for AltStore and TrollStore (`com.getboolean.eikon`). Both builds are sandboxed.

Split 02 added the following:
- a platform-neutral SwiftPM package, `Packages/EikonCore`, containing detection, identity, routes, the settings CRDT, sessions, the library model and the `eikon-scan` CLI
- EikonKit pieces for the library, runtime host, gates, crash reporting and credits
- app screens: Library, Game drives, This device, Credits

**Constraints that apply to everything in this section:**

- **No program titles anywhere.** That covers the repo, commits, logs, tests, device-report notes, issue text and scanner output. Folder names and display names count as titles. Record real-game results by engine and hash only.
- **`/Volumes/Games` is read-only.** The owner's SMB share (`smb://desktop-boolean/Games`) is mounted there. Only the scanner reads it. Nothing from it is committed: no titles, folder names, paths, screenshots or game text.
- **Tests stay few and behavioral.** This section adds no tests. Expected collection counts live only in `requirements.md`, never in test code.
- **Outward-facing actions need the owner's explicit approval.** Ask first before pushing commits, creating GitHub labels, opening real issues, or running the `file-report` workflow.

## Tests first

This section adds no new automated tests. Its checks are:

1. **The full suite passes.** `make test` now runs `test-core test-swift test-scripts`:
   - `test-core`: `swift test --package-path Packages/EikonCore` on the Mac
   - `test-swift`: both `EikonCoreTests` and `EikonKitTests` on the simulator via `scripts/test_swift.sh`
   - `test-scripts`: `uv run pytest tests/`, including the updated `test_credits.py`
2. **Opt-in collection test.** `tests/test_collection_scan.py` is skipped unless `/Volumes/Games` is mounted **and** `EIKON_SCAN_COLLECTION=1`. It runs the scanner and compares its engine counts with the counts it parses at run time from the "Games to support" table in `planning/requirements.md`. Run it once, after the reconciliation in step 3:
   ```
   EIKON_SCAN_COLLECTION=1 uv run pytest tests/test_collection_scan.py
   ```
3. **The artifact verifier still passes.** Run `make verify` (`uv run scripts/verify_artifacts.py dist/`) against the new packages. The Info.plist file-sharing keys added in split 02 must not break it.
4. **The device-report contract still holds.** The existing fixture test (`tests/fixtures/device-report.json`) passes with an empty `gates` map, and a report exported from the new build validates against `device-reports/schema.json`, which already requires `gates` and allows `notes`.

## Implementation steps

### 1. Update `planning/requirements.md`

The "Constraints" section currently says, in the **No program titles** bullet: "Game data is keyed by a hash of the main executable or archive." That is a hard constraint today. Split 02 replaces it by an explicit owner decision (interview Q25–Q31).

**Edits:**

- **The "No program titles" bullet in Constraints.** Replace the keying sentence. Game data is keyed by a **random game id** (a UUID minted once per game). A game is recognized by a **fingerprint**, not by a hash of the main executable. The fingerprint is built from:
  - an engine-declared id
  - a full content hash of the game's files, excluding saves and OS metadata

  Fingerprints are stored and synced **only as HMACs** under a library secret. Keep the rest of the bullet ("in the repo, logs, tests, or depictions", "Test content is original").
- **The "Decisions" section.** Add a dated entry: "Made by the owner on <date of landing>", or append to the existing list with a date. It should state:
  - **Identity.**
    - Game data is keyed by a random game id.
    - A location is matched to its game by, in order:
      1. the same drive and folder, so an in-place patch keeps the id
      2. an exact content fingerprint: files alone identify a game only when 100% identical, saves excluded
      3. the engine's declared id
    - File-name similarity never matches or suggests.
    - Prompts appear only on real ambiguity and never block.
    - A mistake gives a duplicate entry, never shared saves.
    - Full-file SHA-256 also serves diagnostics: scanner `--hash` and "Verify files".
  - **Game drives.**
    - Games sit flat in game drives: the app's own `Documents/`, shown in Files as "On My iPad/Eikon" or "On My iPhone/Eikon", plus user-added folders on USB or other local storage.
    - Each game is an immediate subfolder of a drive, or sits inside one wrapper folder there.
    - Import **copies** a game into a drive the user picks.
    - Games on a USB drive run from the drive.
  - **Crash reports.** A game is identified by a report id (the first 8 characters of the random game id) and, in the issue the user reviews before submitting, its display name. They never carry file hashes, fingerprints or folder names.
- **Consistency pass (owner review).** Other sentences still say "keyed by the game's hash":
  - "Cloud saves": "Syncs, per game and keyed by the game's hash"
  - "Privacy": "Remote paths use game hashes, never titles"
  - "Prior art": "keep per-game FEX settings keyed by game hash, not by app id"
  - the split 02 row in `planning/project-manifest.md`: "hashing by main executable or archive"

  Propose the matching wording ("game id") for each and let the owner confirm. Don't silently rewrite owner-decision text.
- Don't add any collection-derived detail beyond counts, and change counts only in step 3.

### 2. Final build: test, archive, package, verify

From the repo root:

```
make check
make test
make archive
make package
make verify
```

`make all` runs the same chain. Specifically:
- `make package` clears `dist/`, builds the ipa and deb, and writes `dist/SHA256SUMS`.
- `make verify` runs the artifact verifier.

Both builds must still be sandboxed and carry split 01's entitlements unchanged. The only Info.plist additions are these three keys:
- `UIFileSharingEnabled`
- `LSSupportsOpeningDocumentsInPlace`
- `EKRepositoryURL` = `https://github.com/getBoolean/eikon`

Also confirm that CI's macOS job runs `make test-core`. `make help` must list `test-core` and `scan-collection`.

Cutting a release (version bump, GitHub Release, `make publish`) follows 01's normal release flow. It is outward-facing, so do it only with the owner's go-ahead. The device checks in step 5 should use the released artifacts, as the device-reports runbook requires.

### 3. Scan the collection and reconcile

On the dev Mac, with the share mounted:

```
make scan-collection
```

This runs `swift run --package-path Packages/EikonCore -c release eikon-scan --per-folder $(ARGS)` and writes nothing into the repo. If the mount is absent, it prints `skipped: <root> not mounted` and exits 0.

**Output format.** The output is aggregate and title-free. It covers:
- counts by engine
- Unity IL2CPP vs Mono, and how many were recognized via `UnityPlayer.dll`
- Kirikiri: how many have `.tpm`, krkr2 vs Z, index readable, protected flag seen
- Ren'Py versions
- GameMaker: YYC vs VM
- "no game found"
- architecture counts, overall and for `Game.exe`
- plugin and native-extension base names
- exclusion-rule hits
- identity statistics: declared-id coverage per engine, blocklist hits, collision risk

With `--per-folder`, the scanner also prints one line per folder with a short fingerprint and the engine.

**Target table.** Compare the output with the "Games to support" table in `planning/requirements.md`:

| Engine | Expected |
|---|---|
| Unity | 29, of which 4 are IL2CPP (the table counts Unity by `UnityPlayer.dll`) |
| Kirikiri | 21, of which 3 have `.tpm` |
| Ren'Py | 4 |
| GameMaker | 3 |
| BGI | 2 |
| `Game.exe` architectures | 11 i386, 5 amd64 |

**Resolving mismatches:**
- If detection is wrong, fix it in EikonCore. Add a synthesized fixture case to the detection tests using original content only, and re-run `make test-core`.
- If the table's counting method differed (for example, Unity counted by `UnityPlayer.dll` versus detected Unity), correct the table in `requirements.md`, and say how it now counts where that is ambiguous.
- Check the risk noted in the plan: Kirikiri executables with an embedded XP3 and no `.xp3` files would be missed. If the scan shows candidates (for example, PE files in "no game found" folders), record the count and raise it with the owner.
- Record identity collision risk (folders sharing an exact fingerprint or engine id) as a count only.

**Recording rule.** Record any finding in commits or notes by engine, count and hash only, never by folder name. Don't paste `--per-folder` output into the repo or commit messages.

Then run the opt-in pytest from "Tests first" item 2 and confirm it passes.

### 4. The `crash` label and issue-form prefill

`.github/ISSUE_TEMPLATE/crash.yml` (from section 07) is an issue form:
- `name: Crash report`
- `labels: [crash]`
- field `id`s matching the URL builder's fields: `outcome`, `engine`, `arch`, `route`, `game`, `name`, `app`, `device`, `install`, `jit`, `fault`, `breadcrumbs`
- a free-text "What were you doing?" field

The app builds `<repo>/issues/new?template=crash.yml&labels=crash&title=…&<field>=<value>…` with explicitly percent-encoded values.

**Owner checklist:**
1. **The `crash` label exists** in `getBoolean/eikon`. Check with `gh label list`. If it is missing, ask the owner before running `gh label create crash`.
2. **Prefill works.** From a real simulated-crash banner on the device (step 5), tap *Report on GitHub* and confirm in Safari that:
   - the template, label and title are applied
   - every field above is prefilled, with reserved characters (`+`, `&`, `=`) intact
   - the `game` field is the 8-character report id, and `name` holds the game's display name (empty for a test session)
   - no folder name, fingerprint or file hash appears anywhere

   Don't submit the issue unless the owner wants a real test issue.
3. **Fallback.** If a field doesn't prefill, the fallback is the clipboard device report, which the banner already tells the user to paste. Record which fields failed. If the cause is a mismatch between the field ids and the URL builder, fix it in `crash.yml` or `CrashIssue`. If GitHub doesn't support prefill for that field type, note it under the plan's risks.

### 5. Device checks and the device report

**Setup.** Install the released artifacts on the owner's devices, following `device-reports/README.md`:
- iPad Pro 12.9" M2 on iPadOS 17.0, with TrollStore or Dopamine
- iPhone 13 mini (A15) on iOS 27.0, with AltStore
- one install method at a time, and Dopamine's "Allow JIT in Apps" off for the non-Dopamine cases

Use original test content where possible. Where a real game from the share is used, record it only by engine and a hash, such as the key-file SHA-256 from `eikon-scan --hash` or "Verify files".

**Checks (manual):**
- **Import from "On My iPad".** Import copies a game folder from Files "On My iPad" (a fast clone) into the built-in drive. The Eikon folder appears under "On My iPad" in Files.
- **Import from USB-C.** Import copies from a USB-C drive, with working progress and cancel.
- **USB-C game drive.**
  - Add a folder on a USB-C drive as a game drive; its games appear.
  - Unplug it; they show "Drive not connected".
  - Replug it; they are available again.
  - If an exFAT or FAT bookmark fails to resolve after reconnecting, confirm that Re-link recovers it, and record the volume format.
- **Drop via Files.** A folder dropped into "On My iPad/Eikon" through Files appears on return to the app, after the quiescence delay.
- **Same name, different contents.** The same folder name on the built-in drive and on the USB drive, with different contents, triggers the same-or-different prompt.
- **Test session** (This device → Developer → run a test session):
  - Pulling down Control Center pauses it.
  - Going Home backgrounds it. After 30 s in the background, returning shows "Tap to resume", and the command-buffer error count is 0.
- **Simulated crash** (Developer → simulate a crash):
  - Relaunch shows the crash banner.
  - *Report on GitHub* opens a prefilled issue containing codes and the report id (no name, since it is a test session). This doubles as step 4's prefill check.

**Filing:**
1. On each device used, export the device report from This device (**Copy report** / **Share report**). It now includes `gates`, which is expected to be empty because nothing writes gates in 02.
2. Add the check results to the report's `notes`: pass or fail per check, the engine and hash for any real game, and the volume format for USB. No titles, folder names or device-identifying data.
3. File it:
   - **Workflow:** the `file-report` workflow via `gh workflow run file-report.yml -f report="$(cat report.json)"`. Ask the owner first, because it commits.
   - **Local:** `uv run scripts/file_device_report.py <path>`, which writes `device-reports/<date>-<model>-<method>-<hash>.json`.

   Commit the filed report. Pushing it needs the owner's approval.
4. Optionally extend `device-reports/README.md` with a short split 02 section: these checks, their expected results, and a dated "Results so far" line.

### 6. Close out the split

- Update the plan's open risks with what the checks settled:
  - bookmark behavior on exFAT and FAT
  - whether issue-form prefill works
  - whether any embedded-XP3 Kirikiri executables were found
- Mark split 02 done wherever split 01 was closed out in the docs, for example `planning/project-manifest.md` and the handoff. Use the same style as the "Close out split 01 in the docs" commit.

## Files touched

- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/planning/requirements.md`: Decisions, the No program titles constraint, the count corrections if any, and the consistency wording after owner review
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/planning/project-manifest.md`: the split 02 row wording and the done status, after owner review
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/device-reports/<date>-<model>-<method>-<hash>.json`: new, written by `scripts/file_device_report.py`
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/device-reports/README.md`: optional split 02 checks section
- Detection sources and fixtures in `Packages/EikonCore/Sources/EikonCore/Detection/` and `Packages/EikonCore/Tests/EikonCoreTests/`, only if reconciliation finds a detection bug
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/.github/ISSUE_TEMPLATE/crash.yml` or `Packages/EikonCore/Sources/EikonCore/Sessions/CrashIssue.swift`, only if prefill verification finds a field-id mismatch

## Done when

- `make all` passes locally, and CI (including `make test-core`) is green.
- `requirements.md` records the game-id, fingerprint and game-drive decision, and the old "keyed by a hash of the main executable" sentence is gone.
- `make scan-collection` output agrees with the "Games to support" table, after fixes or table corrections, and the opt-in collection pytest passes.
- The `crash` label exists, and a prefilled crash issue was verified in Safari.
- Every device check is recorded, by engine and hash only, in a filed device report.
