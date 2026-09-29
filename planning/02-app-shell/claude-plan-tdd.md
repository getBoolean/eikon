# TDD plan: 02 · App shell

This file mirrors `claude-plan.md`. For each section it lists the tests to write **before** implementing.

**Tooling.**
- **Swift Testing** (`import Testing`, free `@Test func` with behavior names, `#expect`/`#require`, `@Test(arguments:)`):
  - `EikonCoreTests` runs with `swift test --package-path Packages/EikonCore` (`make test-core`) on the Mac, and on the simulator through the scheme.
  - `EikonKitTests` runs on the simulator via `scripts/test_swift.sh`.
- **pytest** through `uv run pytest tests/` for scripts.
- **Fakes** sit at the top of each test file, following 01's style.
- **Temp directories** are used for every file test.

**Fixtures.** `Fixtures.swift` in `EikonCoreTests` synthesizes **original** fake game folders:
- PE and ELF headers
- XP3, GameMaker and BGI magics
- Ren'Py, Unity, Kirikiri and BGI layouts

Names are generic (`Game.exe`, `Sample_Data`, `data.xp3`). Nothing comes from the real collection.

**Owner's rule.** Tests stay few and behavioral. They don't assert constants, exact strings, file contents or internal structure. Sections with no behavioral logic say so.

---

## 1. Context
No tests (descriptive).

## 2. Package and file layout
No tests. The build itself is the check: `make test-core` and `make test-swift` compile both packages, and CI runs them.

## 3. Build and test wiring
No unit tests.
- `make test-core` passes on the Mac.
- `make test-swift` runs both `EikonCoreTests` and `EikonKitTests` on the simulator. Confirm both suites appear in the xcodebuild output once, when wiring.

## 4. Detection

### 4.1–4.2 Types and entry point
- Test: an empty folder detects as no game (`nil`).
- Test: a folder containing only a PE exe detects as `unknown`, with that exe's architecture under the Windows platform.
- Test: a folder whose only child is a wrapper holding one game detects that game, and reports the wrapper as the game root.
- Test: a wrapper holding **two** games is not accepted.
- Test: a stored `DetectionResult` JSON carrying an unknown engine or architecture value decodes to the fallback values rather than failing.
- Test: detection returns the same result regardless of directory listing order.

### 4.2 `FolderListing` / `FolderReader`
- Test: markers with different letter case (`unityplayer.DLL`, `DATA.XP3`) are found.
- Test: `<stem>.exe` pairs with `<stem>_Data` when the two names differ only in Unicode normalization form (NFC vs NFD).
- Test: a zlib-compressed XP3 index decodes.

### 4.3 Per-engine rules (parameterized over fixtures)
- **Ren'Py.**
  - Test: each era layout reports Ren'Py with the matching version kind: exact from `script_version.txt`, exact from `vc_version.py`, exact from `__init__.py`, or era from `lib/` names.
  - Test: native modules under `game/` are listed by base name. Engine files under `lib/` are not listed.
  - Test: the Windows executable is the `<stem>.exe` next to `<stem>.py`. The Linux executable is the ELF under `lib/py3-linux-x86_64/`.
- **Unity.**
  - Test: Mono and IL2CPP layouts are told apart.
  - Test: a pre-2017 layout (with `_Data/mainData` but no `UnityPlayer.dll`) is recognized.
  - Test: the main exe is the one with a `_Data` sibling, and `UnityCrashHandler64.exe` is never chosen.
- **Kirikiri.**
  - Test: `.tpm` base names are reported.
  - Test: a krkr2 or Z version resource sets the flavor.
  - Test: an entry with the protected bit sets `xp3ProtectedFlag`.
  - Test: a garbage index gives `xp3IndexReadable == false` and is still Kirikiri.
- **GameMaker.**
  - Test: a file with a `CODE` chunk is VM, and one without is YYC.
  - Test: a file with `FORM` but no `GEN8` is not GameMaker.
- **BGI.**
  - Test: `BGI.exe` is recognized.
  - Test: two `.arc` files with either magic are recognized.
  - Test: `.arc` files without the magic are not.
- **PE.**
  - Test: each machine value maps to the right architecture.
  - Test: an `e_lfanew` beyond 4 KiB still parses.
  - Test: a DLL is never an executable.
- **ELF.**
  - Test: x86-64 and aarch64 map correctly.
  - Test: a `.sh` script is not an ELF.
- **Multi-platform.**
  - Test: a Unity folder with a Windows amd64 exe and a Linux x86_64 binary reports both platforms.

### 4.4 Main executable selection
- Test: installer, uninstaller and redistributable executables are never chosen when a real candidate exists.
- Test: among the remaining candidates, a GUI-subsystem exe beats a console one of larger size.
- Test: each exclusion rule's hit count reflects the files it removed. This is observed through the summary API, not through internal counters.

## 5. Identity

### 5.2 Signals and fingerprints
- Test: renaming the game folder (not its contents) leaves the fingerprint unchanged.
- Test: changing one file's size, or the key file's first or last MiB, changes the exact signal but leaves the engine id unchanged.
- Test: the engine-declared id is read for Ren'Py (`options.rpy` `config.save_directory`), Unity (`app.info`), GameMaker (GEN8 name) and exe version info.
- Test: a generic value such as `DefaultCompany`/`My project` or `TVP(KIRIKIRI)` yields no engine id.
- Test: the stored fingerprint contains none of the plain names or engine-id text.
- Test: the same folder under two different secrets gives different values.
- Test: the same folder under the same secret gives equal values.
- Test: the Ren'Py key file is never the launcher exe, and the Unity key file is never the player exe.

### 5.4 Matcher
Table-driven over in-memory state, one row per rule:
- Test: **in-place patch.** A known location whose contents changed entirely (new sizes, new files, new engine id) keeps its game id, and the new fingerprint is added.
- Test: an exact match of a folder under a new name or on another drive attaches to the existing game.
- Test: an engine-id match attaches silently when the game has no live location on this device. This covers a patched and moved copy, and a newer version on another device.
- Test: an engine-id match while the game is live elsewhere creates a new game with a suggestion, never a silent merge.
- Test: name-set similarity ≥ threshold with no engine id and a single candidate attaches. Below the threshold, it doesn't.
- Test: two candidates create a new game plus a suggestion listing both.
- Test: no match creates a new random id.
- Test: a game with `deletedAt` is never a candidate.
- Test: fingerprints beyond the cap keep the most recent ones.

### 5.5 Merge and split
- Test: after a merge, A's id resolves to B, A's locations belong to B, and B keeps its own settings where both had a value.
- Test: merge links in a chain resolve to the end, and a cycle resolves to the same id from either side.
- Test: a split gives the location a new id whose settings equal the old game's at split time. Later edits to either don't affect the other.

### 5.6 Diagnostics hasher
- Test: `FileHasher` equals an independent SHA-256, reports non-decreasing progress, and stops early on cancel.

## 6. Game drives and the library

### 6.2 Persisted-file rules (EikonCore)
- Test: a file with a newer `format` loads but is never rewritten by a save.
- Test: one malformed element in a collection is dropped from the loaded view but is still present after a save.
- Test: a location persisted mid-fingerprinting loads as `pending`.

### 6.4–6.7 Drives, scanning, import (EikonKitTests, fake `FolderAccess`, temp-directory drives)
- Test: adding a drive refuses ubiquitous and network volumes, and accepts external-local and internal ones.
- Test: a drive whose bookmark reports "not connected" makes its games unreachable, and their launch state reports that.
- Test: re-linking a drive to a folder that contains none of its known folder names asks for confirmation. A folder that contains them relinks silently.
- Test: the scanner ignores dot folders, including an in-progress `.eikon-importing-*`, and ignores `Inbox` on the built-in drive.
- Test: a new subfolder becomes a location. A vanished one becomes missing but is not deleted.
- Test: a folder whose contents keep changing is not fingerprinted until two scans at least the quiescence interval apart see the same listing and key file. Use an injected clock.
- Test: a location with a previous `unknown` or `nil` detection is re-detected on the next scan after its listing changes.
- Test: an import lands at `<drive>/<name>`, never produces a duplicate location, and leaves the source unchanged.
- Test: an import onto an existing name offers replace or rename. *Replace* keeps the existing game id and its settings (an update through import).
- Test: a cancelled or failed import leaves no staging folder and no partial game folder.
- Test: a leftover staging folder from an earlier run is removed at startup.
- Test: an import that needs more space than is free is refused before copying.
- Test: a symlink inside the source is not followed out of the source tree.
- Test: copying a patch over a game's files on a drive, then rescanning, keeps the game's id and settings, and re-runs detection.
- Test: renaming a game folder on a drive, or moving it to another drive, keeps its game id.
- Test: the same game (an exact match) on two drives shows as one game with two locations.

### 6.6 Fingerprint worker
- Test: while a session is marked active, no fingerprinting progresses. It resumes after the session ends.
- Test: the viewed location is processed before the others that are queued.

### 6.9 Remove
- Test: removing with "delete settings and saves" makes all of the game's settings read as unset, calls the registered cleanup hooks once, and leaves other games untouched.
- Test: deleting files removes only the checked locations' folders, never a folder on another drive.

## 7. Settings
- Test (property-style, seeded random operation sequences across three simulated replicas): merging in any order and any grouping gives the same state, and merging twice changes nothing.
- Test: a reset newer than a set wins. A set newer than a reset wins.
- Test: keys the store has no `SettingKey` for survive load and save unchanged.
- Test: with the wall clock moved backwards between writes, the second write still wins over the first.
- Test: a merged remote timestamp far in the future makes the next local write order after it.
- Test: another replica's future-format file is merged but never rewritten.
- Test: when this replica's own file is a future format, the store writes to a new replica file and leaves the old one byte-identical.
- Test: `deletedAt` hides older keys under the game, including a key only another replica wrote. A key written after `deletedAt` is visible.
- Test: a value that fails to decode as the key's type reads as unset.
- Test: writes are persisted after a flush, and a new store instance over the same directory reads them back.

## 8. Routes
Table-driven `@Test(arguments:)` over (detection, environment, override) rows:
- Test: Kirikiri and Ren'Py choose their native route when it is runnable. When the native runtime declines, Wine is chosen, carrying `nativeFirst`.
- Test: with JIT usable, Windows i386 and amd64 choose wine-fex.
- Test: without JIT, i386 chooses wine-box64, and amd64 is unavailable with `needsJIT`.
- Test: with JIT usable but wine-fex gated out, declined or planned, i386 chooses wine-box64. Box64 is demoted, not removed.
- Test: an unmeasured required gate gives `runnableWithWarnings` with a reason naming that gate.
- Test: a failed gate makes the route unavailable, and so does a stale failed gate.
- Test: with no built runtimes at all, the preferred route is chosen as `planned`.
- Test: an override to an unavailable route is chosen, with warnings listing its reasons.
- Test: an override to a runnable route has no warnings.
- Test: Linux amd64 chooses linux-fex only with JIT usable.
- Test: a multi-platform Unity folder lists both wine-fex and linux-fex candidates.
- Test: ARM64 PE and unknown architectures produce no runnable Wine candidate.

## 9. Runtime interface and session host (EikonKitTests)
Use a fake runtime that records its calls, plus fake `SceneEvents`.
- **RenderGate** (the C atomics are exercised through the Swift API):
  - Test: `enter()` succeeds while open and fails after `close`.
  - Test: `close` returns only after an in-flight `enter` has had its `leave`.
  - Test: `close` returns false when a frame never leaves within the timeout.
- **Lifecycle:**
  - Test: will-deactivate closes the gate and pauses the runtime.
  - Test: the sentinel phase becomes `background` only on did-enter-background, after the gate is closed.
  - Test: did-activate sets the phase to `running` but doesn't resume. The overlay's resume action opens the gate and resumes.
  - Test: an audio interruption pauses the runtime, and its end does not auto-resume.
  - Test: quit stops the runtime, disarms the sentinel and closes the access token.
- **Registry:**
  - Test: runtime check results are cached per (route, game, build), and re-queried after a new registration.
- **Presentation:**
  - Test: the presenter presents on the topmost presented controller. Use a stub controller hierarchy.

### 9.4 Test-pattern session
No automated tests. The device checks in §17 cover it.

## 10. Crash recording and reporting (EikonCoreTests)
- **Sentinel:**
  - Test: arm then consume returns the record. A second consume returns nothing.
  - Test: disarm then consume returns nothing, and the breadcrumbs and fault files are gone.
- **Outcome classification** (one parameterized test over the four rows of §10.4):
  - Test: the phase, fault record and breadcrumb inputs give the expected outcome and banner flag.
  - Test: a memory warning more than 60 s before the last breadcrumb does not count as a memory kill.
- **Breadcrumbs:**
  - Test: after more than 64 appends, only the last 64 remain, in order.
  - Test: reading after a simulated torn write yields the valid slots. Build the torn write by writing a partial slot directly.
- **Fault record:**
  - Test: a fault record written through the C hook is read back with its signal and pc.
  - Test: a fault file whose header names another session is ignored.
- **Crash history:**
  - Test: it keeps at most 5 entries per game, newest first, and each entry keeps its breadcrumbs snapshot.
- **Issue URL:**
  - Test: the URL's query parses back to exactly the provided fields.
  - Test: values containing `+`, `&`, `=` and spaces round-trip.
  - Test: with many breadcrumbs, the URL stays under the limit and the oldest breadcrumbs are the ones dropped.
  - Test: the URL contains the report id and no fingerprint value.

### 10.5 Crash report controller (EikonKitTests)
- Test: a consumed high-severity session publishes a banner.
- Test: a background kill adds history without a banner.
- Test: "Try another route" is offered only when another candidate is runnable. It is not offered for a `test` record or for a game that has been removed.

### 10.6 `crash.yml`
No automated test. The field ids are checked once against the URL builder during implementation. Prefill is verified manually on GitHub.

## 11. Gate store (EikonKitTests)
- Test: a passed result recorded under the current builds reads as `passed`. Under a different app or OS build, it reads as `unmeasured`.
- Test: a failed result under a different build reads as failed and stale, and is replaced when the gate is recorded again.
- Test: `DeviceReport.make` with the store's results includes them in `gates`. The existing device-report fixture contract test (`tests/fixtures/device-report.json`) still passes with an empty gates map.

## 12. Screens
No automated UI tests. 01 has no UI test target, and the owner's rule keeps tests few.
- **Previews:** DEBUG previews render every `RouteReason`, `RouteVerdict`, `SessionOutcome`, identity prompt, drive state and library status, so a missing string key shows up as a raw key.
- **Device checks:** see §17.

## 13. Info.plist and entitlements
No unit tests. The artifact verifier from 01 still passes. The device check is that the Eikon folder appears under "On My iPad" in Files.

## 14. Reason text rules
No tests (string content). Previews cover the keys.

## 15. Credits pipeline (pytest)
- Test: `app-json` for a repo with no third-party components produces exactly one entry, marked as the app, whose license text equals the repo's GPL license file.
- Test: with one component added (using the existing `Project` helper), the output has the app entry plus that component, and only the app entry is marked as the app.
- Update any existing test that expected an empty array.

### 15. Acknowledgements model (EikonKitTests)
- Test: `Acknowledgements.load` decodes JSON in the generator's format, and puts the app entry first.
- Test: malformed JSON reports an error rather than crashing.

## 16. Collection scanner
- **ScannerTests (EikonCoreTests)**, over a synthesized collection in a temp dir. The collection holds several engines, plugins and architectures, a wrapper folder and a non-game folder.
  - Test: the summary's per-engine counts, IL2CPP count, plugin-name counts, architecture counts and "no game found" count match the synthesized collection. Expected values are derived from how the fixture was built, not typed in.
  - Test: the formatted output contains none of the synthesized folder names.
  - Test: a missing root yields the "skipped" result.
- **`tests/test_collection_scan.py`** (pytest, opt-in):
  - Skipped unless `/Volumes/Games` is mounted **and** `EIKON_SCAN_COLLECTION=1`.
  - Test: the scanner's engine counts equal the counts parsed at run time from the "Games to support" table in `planning/requirements.md`.

## 17. Testing strategy
This section is the plan's summary of the tests above.

### Device checks
Manual, recorded by engine and hash only:
- import copy from Files "On My iPad"
- import copy from USB, with progress and cancel
- add a USB drive, unplug it, replug it
- drop a folder in through Files
- the same folder name on two drives with different builds
- test session:
  - Control Center
  - background for 30 s, then resume, with an error count of 0
- simulated crash, then relaunch: the banner appears, and the issue link carries codes and the report id only

## 18. Implementation order
Write each step's tests (from the sections above) before its implementation. Step 4's scanner run against the mount is a manual validation, not a test.

## 19. Risks
No tests.
