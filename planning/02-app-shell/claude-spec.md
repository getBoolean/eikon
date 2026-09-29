# Spec: 02 · App shell (synthesized)

Sources: `spec.md` (the owner's split spec), `claude-research.md`, `claude-interview.md`, `planning/requirements.md`. Where they differ, the interview answers refine `spec.md`, and `requirements.md` constraints always hold.

## 1. Purpose

The app the user sees, and the contracts every runtime split plugs into:
- a game library with import (copy or keep on an external drive) and a Files.app drop-in folder
- engine and architecture detection
- game identity (a stable id and a build id)
- a route picker with human-readable reasons
- a runtime protocol and a game-session host view controller that owns app lifecycle
- next-launch crash reporting (banner, history, prefilled GitHub issue)
- per-game settings in a CRDT-ready shape
- a persisted device-gate store
- a "This device" capability screen extended from 01's status screen
- a credits screen
- localized app text in `en.lproj`
- a collection scanner for `/Volumes/Games` that runs the same detection code

Out: running any game (03+), input mapping (04), sync itself (12).

## 2. Starting point (from split 01, v0.2.x)

- XcodeGen + Makefile + `uv`-run Python scripts; iOS 15 minimum; Swift 6, complete strict concurrency.
- SwiftUI app lifecycle; single `StatusView` screen showing JIT, device, report export.
- `Packages/EikonKit` (imports UIKit; tested by `xcodebuild test` on a simulator via `scripts/test_swift.sh`): `JITController`/`JITStatusStore` (`usable`, `source`, `reason`), `InstallMethod`, `DeviceReport` with an open `gates: [String: GateResult]` slot always left empty, `ProbeSentinel` (arm/disarm/consume-at-launch).
- `credits.py app-json` produces `Acknowledgements.json` (`[{name,url,revision,license,licenseText}]`, empty today), bundled but unread.
- Both artifacts are sandboxed with a normal data container. No document/file-sharing Info.plist keys. Strings live in `App/Localizable.strings`.
- Conventions: Swift Testing, few behavior-only tests; seams as `Sendable` protocols with `Live*` + `.live`; pure logic in caseless enums; exhaustive enum→string-key switches without `default:`.

## 3. Requirements

### 3.1 Game drives and import (revised after plan review, interview Q25–Q28)
- Games live flat in **game drives**: folders whose immediate subfolders are games. One wrapper level holding exactly one game is accepted.
- The default game drive is the app's Documents folder, which Files shows as "On My iPad/Eikon" (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
- Users can add other drives: a folder on a USB-C drive or SD card, or a local folder. iCloud and network locations are refused. Drives are bookmarked, and they are scanned at launch and on each return to the foreground.
- A drive's state is one of: available, not connected, or needs re-link.
- **Import:** the user picks a game folder, then a destination drive. The UI says plainly that the game's files are **copied** to that drive. The copy has progress and cancel, runs after a free-space check, and goes through a hidden staging folder on the destination. A name clash offers replace or rename.
- Drop-ins are hashed only once the folder has stopped changing (quiescence).

### 3.2 Identity (revised again, interview Q31)
- **Game id** = a random UUID, minted when a folder matches no known game. Settings, saves and per-game data key on it.
- **Recognition** is by a fingerprint. It is computed from the game root, never the folder name, and is stored and synced only as HMACs under a library secret. It combines:
  - the engine-declared id (Ren'Py `save_directory`, Unity company/product, GameMaker name, exe version info)
  - an exact signal (file listing with sizes, plus a partial key-file hash)
  - a name set, for similarity
- **Matching order:**
  1. A known location keeps its id, **including after a patch is copied over its files** or installed through Import → Replace.
  2. An exact match.
  3. An engine-id match, when the game isn't present elsewhere.
  4. Name similarity.
  5. Otherwise, a new game.
- **Ambiguity** (a different version beside a present copy, or several candidates) creates a new game with a non-blocking "Same game as…?" suggestion. There are also manual Merge and Split actions.
- **Failure mode:** a mistake gives a duplicate, never shared saves.
- **Full SHA-256** is only for diagnostics.
- **Display name** defaults to the folder name and can be edited. It never appears in logs, reports or issues.
- **Crash issues** carry a report id: the first 8 characters of the random game id.

### 3.3 Detection
Unity (UnityPlayer, `*_Data`, IL2CPP via GameAssembly), Kirikiri (`.xp3` magic, `.tpm`/plugin names, krkr2 vs Z hint), Ren'Py (layout, version, game-supplied native extensions), GameMaker (`data.win` FORM/GEN8, YYC vs VM), BGI (`BGI.exe`, `.arc` magics). Also PE machine (i386/amd64/arm64) and Linux ELF x86-64. Main-executable selection with exclusions. The game root may be one or two levels below the picked folder.

### 3.4 Route picker
- **Inputs:** detection result, JIT usable (from 01), device gate states, which runtimes are built and registered, each built runtime's own can-run verdict, and the per-game override.
- **Routes:** native Kirikiri, native Ren'Py, Wine+FEX, Wine+Box64, Linux+FEX, or unavailable.
- **Order:** native first, then Wine (FEX when JIT is usable, Box64 for i386 when it is not); Linux+FEX for ELF x86-64.
- Every candidate carries a verdict and a structured reason, rendered as human-readable text.
- A route whose split hasn't landed is still chosen and shown as "planned — not in this build yet".
- An unmeasured gate allows the route with a warning. A failed gate makes it unavailable.
- **Override:** any route may be forced. If it can't run, the app warns (on the detail screen and at launch) but allows it.

### 3.5 Runtime interface and session host
- A protocol each route implements: identify its route, a can-run verdict with a reason for a given game, launch into a host view, pause, resume, stop. Runtimes register at app start.
- A UIKit `GameSessionHostViewController`, presented full screen, owns lifecycle:
  - pause on scene deactivation
  - stop Metal drawing before background, using a render gate that runtimes check before every GPU submit
  - resume on reactivation behind "tap to resume"
  - hide the status bar and home indicator, and defer edge gestures
- It arms the session sentinel before launch and disarms on clean stop.
- A developer-only test-pattern runtime exercises the host on a device.

### 3.6 Crash recording and reporting
- **Session sentinel + breadcrumbs, no signal handlers.** The sentinel is in Application Support and holds session id, game id, build id, engine, arch, route, app build, start time and phase (running/background). It is fsynced.
- **Breadcrumbs** are a bounded log of app-defined event codes (no free text), so titles cannot leak.
- **At next launch**, classify the outcome:
  - crash or kill while running
  - likely memory kill (memory warning seen)
  - killed in background (low severity)
- **The app then:**
  - shows a banner with what happened
  - keeps a per-game crash history (last few records)
  - suggests another runnable route if one exists
  - offers "Report on GitHub", which opens a prefilled issue using `.github/ISSUE_TEMPLATE/crash.yml` (label `crash`). The issue holds kind, engine, arch, route, game and build hashes, app build, device model, iOS, install method, JIT state and the last ~20 breadcrumbs. It never contains titles or display names. If the full device report doesn't fit in the URL, it goes to the clipboard.
- A fault-recording hook (async-signal-safe C function writing to a pre-opened fd) exists for later runtimes. 02 installs no handler.

### 3.7 Settings
- **Shape:** per-field LWW registers `(value, HLC timestamp, replica id)` in one file per replica, written only by that device. The effective state is the merge of all replica files.
- **Format:** sparse, keyed by stable dotted names under a game prefix. Unknown fields round-trip untouched. Reset is a tombstone write. The file has a format version.
- **Fields 02 implements:** display name, route override, folder→game alias.
- **Namespaces reserved:** `fex.*` (05), `controls.*` (04), `codePage` (09).
- **Removal** asks separately about deleting game files (copied games only; referenced files stay on the drive) and about deleting settings and saves, including the sync-server copy. Deletion is tombstones, which 12 propagates, plus a cleanup hook that save-owning routes register.

### 3.8 Gate store
Persisted in EikonKit, keyed by gate name: `GateResult` plus app build and OS build. It is invalidated when either changes. `DeviceReport.make` fills `gates` from it. 02 defines the gate names routes require. 05 and 07 write the results.

### 3.9 Screens
- **Navigation:** iPad sidebar split view (Library, This device, Credits); stack on iPhone.
- **Library:** rows show display name, engine, arch, route badge, storage (on drive), and status (identifying, drive not connected, needs re-link, missing).
- **Game detail:**
  - chosen route and reason, and every candidate with its verdict
  - override
  - display name
  - crash history
  - Launch
  - Remove
- **This device:** 01's rows plus a route table (each route with its status here and why) and gate results.
- **Credits:** Eikon itself (GPL-3.0-or-later) first, then every component from `Acknowledgements.json`, each with license text.
- **Text:** all app text moves to `App/en.lproj/Localizable.strings` plus `.stringsdict`. Core logic returns codes, never user-facing strings.

### 3.10 Collection scanner
- A Swift executable built from the same platform-neutral detection package. Run via `make scan-collection` on the dev Mac.
- Read-only. Prints only:
  - counts by engine
  - IL2CPP count
  - `.tpm`/plugin file names with counts
  - main-exe architecture counts
  - per-folder folder-id hash + engine
  - optionally build hashes
- Exits cleanly as "skipped" when `/Volumes/Games` is absent.

## 4. Constraints carried
- No titles in the repo, logs, tests, reports or issues.
- Test content is original, synthesized in tests.
- `/Volumes/Games` is read-only and nothing from it is committed.
- Games run in-process, so a crash ends the app.
- iOS 15 APIs: `NavigationView`, `ObservableObject`, no `ShareLink`.
- Both builds are sandboxed.
- Tests are few and behavioral. They don't pin implementation or hard-coded values.

## 5. Done when
- Original test folders for each engine are detected correctly. Each shows a route and a reason that fit the build and JIT state.
- `make scan-collection` against the mount reproduces the requirements table's counts (by engine, not title).
- Settings persist per game id. The capability and credits screens show real data.
- On a device: import (copy and keep-on-drive), identification, the drive-disconnected state, the test-pattern session's background/foreground behavior, and a forced crash's next-launch banner and issue link all work.
