# section-04-collection-scanner

## Purpose

This section builds the **collection scanner**. It runs the app's own detection and identity code (from `EikonCore`) on the Mac against the owner's game share at `/Volumes/Games`, and prints an aggregate report with no titles in it. It exists to check detection against real data **before any UI is built on it**. It has four parts:

1. `CollectionSummary`: pure aggregation and formatting in `EikonCore`.
2. The `eikon-scan` executable: a thin, synchronous CLI over `GameDetector`, `FingerprintBuilder` and `FileHasher`.
3. The `make scan-collection` target.
4. An opt-in pytest, `tests/test_collection_scan.py`, that compares the scanner's engine counts with the "Games to support" table in `planning/requirements.md`, parsed at run time.

Finally, run the scanner against the mount and reconcile what it finds with `requirements.md`.

## Background

Eikon is an iPhone/iPad app that will run Windows and Linux x86 games (Wine, FEX-Emu, Box64) and Kirikiri and Ren'Py games natively. Split 02 adds a new platform-neutral SwiftPM package, `Packages/EikonCore` (iOS 15 + macOS 13, Swift 6 language mode, no UIKit). Detection, identity and hashing live there so the same code runs in the app and on the dev Mac. The package declares two products: the library `EikonCore` and the executable `eikon-scan`.

### Dependencies

This section depends on the following. Use their APIs; do not re-implement them.

- **section-01-core-package** provides:
  - the `Packages/EikonCore` package, including the `eikon-scan` executable target declaration and the `EikonCoreTests` test target
  - the Makefile skeleton: `test-core`, the `help` text, and a `scan-collection` entry. If section 01 only stubbed `scan-collection`, finish it here as described below.
- **section-02-detection** provides:
  - `GameDetector.detect(folder:) throws -> DetectionResult?`, which includes the one-wrapper-folder rule
  - `DetectionResult`, with `engine`, `details: EngineDetails`, `gameRoot`, `executables: [GamePlatform: ExecutableInfo]`, `keyFile` and `detectorVersion`
  - `Engine`, `CPUArchitecture` and `ExecutableInfo`
  - the main-executable exclusion table with per-rule hit counters
  - `Fixtures.swift` in `EikonCoreTests`, which synthesizes fake game folders
- **section-03-identity** provides:
  - `FingerprintBuilder` (keyed with a secret), `Fingerprint` (`exact`, `engineID`), `Keyed`
  - **Note from section 03:** the exact signal is now a **full content hash of the whole game tree** (saves and OS metadata excluded), so building a fingerprint reads every byte. The scanner therefore builds fingerprints only under `--hash`; the default run uses `EngineDeclaredID.read` alone.
  - `EngineDeclaredID`, including its generic blocklist
  - `KeyFile`
  - `FileHasher` (streaming SHA-256 with progress and cancellation)

Relevant `EngineDetails` fields the summary aggregates:

- `unityScripting` (mono/il2cpp)
- `kirikiriFlavor` (krkr2/krkrZ/unknown)
- `xp3ProtectedFlag`
- `xp3IndexReadable`
- `pluginFileNames` (base names)
- `renpyVersion` (exact or era)
- `renpyNativeExtensions` (base names)
- `gameMakerBuild` (vm/yyc)

Only section-16-landing depends on this section. It re-runs the scanner at landing time.

### Hard constraints

- **No program titles anywhere.** Nothing may carry a title: not scanner output, test code, test names, fixtures, commits or logs. Folder names and display names count as titles. The scanner **never prints folder names**, not even in `--per-folder` mode. Plugin and native-extension lists are file base names only (for example `.tpm` or `.pyd` stems). They are engine or plugin names, not game titles.
- **`/Volumes/Games` is read-only.** The scanner only opens files for reading. It never creates, modifies, or sets attributes (including xattrs or timestamps) on anything under the root. Nothing read from the share is committed. Do not record titles anywhere, including in reconciliation notes.
- **Test content is original.** Scanner tests use a collection synthesized in a temp directory with `Fixtures.swift`, using generic names.
- **Tests are few and behavioral.** They don't assert constants, exact strings, output formatting or internal structure. Expected counts are **derived from how the fixture was built**, not typed in as literals. The real collection's counts live **only** in `planning/requirements.md`, never in tests.
- **Swift 6 mode** with complete concurrency checking. Follow 01's style: small single-concept files, pure logic in caseless enums or plain structs, and exhaustive switches with no `default:`.

## Tests first

### `Packages/EikonCore/Tests/EikonCoreTests/ScannerTests.swift` (Swift Testing)

Use `import Testing`, free `@Test func` functions with behavior names, and `#expect`/`#require`. Fakes and helpers go at the top of the file. Build a synthesized collection in a temp directory with the section-02 `Fixtures.swift` builders. It should include:

- several engines: at least Unity Mono, Unity IL2CPP, Kirikiri with `.tpm` plugins, Ren'Py, GameMaker and BGI
- more than one main-executable architecture (i386 and amd64 PE, plus an ELF)
- at least one file named `Game.exe`
- at least one folder whose game sits inside a single **wrapper** subfolder
- at least one **non-game** folder (for example, only a text file)
- at least one excluded executable (an uninstaller or redistributable) next to a real main exe, so an exclusion rule gets a hit

Keep the fixture spec (which folders were built with which engine, plugins and architectures) in a small local table in the test. Compute the expected values from that table.

Tests:

1. **The summary counts match the synthesized collection.** Run the scan over the temp root, then compare against the values derived from the fixture table:
   - per-engine counts
   - IL2CPP count
   - plugin-name occurrence counts
   - main-executable architecture counts
   - the "no game found" count
   - the exclusion rule that should have fired reports a nonzero hit count (observed through the summary, not through internal counters)
2. **The formatted output contains no folder names.** Format the summary, with `--per-folder` lines included, and assert that none of the synthesized folder names (wrapper names included) appear as substrings.
3. **A missing root gives the "skipped" result.** Point the scan at a temp path that doesn't exist. The result is the skipped case, not a thrown error or an empty summary that looks like zero games.

Stub shape:

```swift
import Testing
@testable import EikonCore

@Test func summaryCountsMatchSynthesizedCollection() throws { /* build fixture table → folders; scan; compare derived expectations */ }
@Test func formattedOutputContainsNoFolderNames() throws { /* ... */ }
@Test func missingRootIsSkipped() throws { /* ... */ }
```

### `tests/test_collection_scan.py` (pytest, opt-in)

- **Skip condition:** the module skips with `pytest.mark.skipif` unless `/Volumes/Games` exists (is mounted) **and** the environment has `EIKON_SCAN_COLLECTION=1`. In CI and in ordinary `make test` runs it always skips.
- **Test:** the scanner's per-engine counts equal the counts parsed at run time from the "Games to support" table in `planning/requirements.md`.
  - Locate the repo with the `REPO_ROOT` pattern already in `tests/conftest.py` (`Path(__file__).resolve().parent.parent`).
  - Parse the markdown table under the heading `## Games to support, in priority order`. Its columns are `Engine | Folders | How it is recognized | Notes`. Take the `Engine` → `Folders` integers. Map engine display names (`Unity`, `Kirikiri`, `Ren'Py`, `GameMaker`, `BGI`) to the scanner's engine keys with a small mapping in the test. Do **not** hard-code the counts.
  - Run the scanner with `swift run --package-path Packages/EikonCore -c release eikon-scan --root /Volumes/Games`, or through `make scan-collection`, and parse the per-engine counts from its output. The scanner's output therefore needs a stable, easily parsed line per engine count. A simple `engine.<raw>: <n>` style works. Use one format and document it in `CollectionSummary`.
  - Compare only the engines present in the table.

## Implementation

### Files

- Create `Packages/EikonCore/Sources/EikonCore/Scan/CollectionSummary.swift`: the pure summary and formatting.
- Create `Packages/EikonCore/Sources/eikon-scan/main.swift`: the CLI.
- Create `Packages/EikonCore/Tests/EikonCoreTests/ScannerTests.swift`.
- Create `tests/test_collection_scan.py`.
- Modify `Makefile`: the `scan-collection` target and the `help` line, if section 01 didn't complete them.
- Modify `planning/requirements.md`, only as a result of reconciliation (see below).

### `CollectionSummary` (EikonCore/Scan, pure)

This is a value type that folds per-folder results into aggregate counts and formats them as title-free text. It does no I/O. The CLI and the tests feed it.

Suggested shape (signatures only; adjust names to fit sections 02 and 03):

```swift
/// One scanned folder's contribution. Carries no folder name.
public struct ScannedFolder: Sendable {
    public var detection: DetectionResult?        // nil = no game found
    public var declaredID: EngineDeclaredID.Result? // in memory only; never printed
    public var fingerprint: Fingerprint?          // only with --hash, under the fixed scanner secret
}

public enum ScanOutcome: Sendable {
    case skipped(root: String)                    // root absent → "skipped: <root> not mounted"
    case scanned(CollectionSummary)
}

public struct CollectionSummary: Sendable {
    public init(folders: [ScannedFolder], exclusionHits: [String: Int])
    // aggregate accessors used by tests (engine counts, il2cpp count, plugin counts, arch counts, noGame, exclusion hits, ...)
    public func formatted(perFolder: Bool) -> String
}

public enum CollectionScan {
    /// Treats `root` like a game drive: each immediate, non-dot subfolder goes through
    /// GameDetector.detect (with the wrapper rule) and EngineDeclaredID.read; with `hash`,
    /// also FingerprintBuilder under the scanner secret (full reads). Synchronous and
    /// read-only. Returns .skipped if root is absent.
    public static func run(root: URL, hash: Bool, progress: ((Int, Int) -> Void)?) -> ScanOutcome
}
```

Put the scan driver (`CollectionScan.run`, or similar) in EikonCore rather than in `main.swift`, so `ScannerTests` can call it on the temp collection. That is how the tests observe exclusion hit counts through the summary API. Keep the driver synchronous.

**Output content** (aggregate only, no names):

- total folders scanned
- counts by engine (`unity`, `kirikiri`, `renpy`, `gameMaker`, `bgi`, `unknown`)
- **Unity:**
  - IL2CPP vs Mono
  - how many were recognized via `UnityPlayer.dll`, as opposed to the `_Data` marker. The requirements table counts Unity by `UnityPlayer.dll`, so report both numbers.
- **Kirikiri:**
  - how many have `.tpm` plugins
  - krkr2 vs krkrZ vs unknown flavor
  - how many have a readable index
  - how many had the protected flag seen
- **Ren'Py:** version counts, exact versions and eras listed separately
- **GameMaker:** YYC vs VM
- the "no game found" count
- **Main-executable architecture counts:** overall, and separately for files named `Game.exe` (case-insensitive). The requirements table quotes `Game.exe` counts.
- plugin base names with occurrence counts
- Ren'Py native-extension base names with occurrence counts
- the hit count of each exclusion rule (from section 02's counters), so false exclusions show up on real data
- **Identity statistics:**
  - how many games have an engine-declared id, per engine
  - how many declared ids hit the generic blocklist. This comes from section 03's `EngineDeclaredID` and its blocklist. The scanner needs to know when a value was found but rejected as generic, so expose that from section 03's API if it isn't already, or compute it in the driver.
  - how many share an engine id with another folder (collision risk; compared in memory by engine plus declared value, never printed)
  - with `--hash`: how many folders share an exact fingerprint with another folder (identical copies)

**Per-folder lines (`--per-folder`):**

- One line per folder, in visit order, holding the engine.
- With `--hash`, lines are **sorted by exact fingerprint** and each starts with the short exact fingerprint (a prefix of the keyed hex).
- **Never** print the folder name, game root name, key-file path or declared-id text.

**Scanner secret.** Fingerprints use a **fixed, documented scanner secret**, a constant defined next to the driver with a comment explaining it. Its output is then comparable across runs. It is never the app's library secret, and the app never uses it.

### `eikon-scan` CLI (`Sources/eikon-scan/main.swift`)

```
eikon-scan [--root PATH] [--per-folder] [--hash]
```

- **Arguments:** parse them by hand (no ArgumentParser dependency). `--root` defaults to `/Volumes/Games`. An unknown flag prints usage to stderr and exits nonzero.
- **Missing root:** if the root doesn't exist, print `skipped: <root> not mounted` to stdout and **exit 0**.
- **Scanning:** the root is treated like a game drive.
  - Each immediate subfolder is passed to `GameDetector.detect`, which applies the one-wrapper rule.
  - Skip entries whose names start with `.`.
  - Visit folders in a deterministic order.
- **Read-only:** go only through section 02's `FolderReader`/`FolderListing` and section 03's `FileHasher`, which open files read-only and never follow symlinks out of the folder. Never write, never set attributes, and never create caches under the root.
- **`--hash`:**
  - Builds each detected game's `Fingerprint` (full content hash through `FileHasher`).
  - Progress goes to **stderr**, because hashing over SMB is slow. Stdout stays clean for parsing.
- **Structure:** the top level is **synchronous**, with no `async` main and no Tasks, so detection avoids MainActor isolation friction under Swift 6. `main.swift` only parses arguments, calls the EikonCore driver, and prints `formatted(perFolder:)`.
- **Errors:** a detection or read error on one folder must not abort the run. Count it in the output as an error count, with no name, and continue.

### Make target

The target builds release and passes extra arguments through `ARGS`. It writes nothing into the repo:

```make
scan-collection:
	swift run --package-path Packages/EikonCore -c release eikon-scan --per-folder $(ARGS)
```

Make sure the `help` text lists `scan-collection` and explains that it scans `/Volumes/Games` read-only and prints skipped when the share isn't mounted. `scan-collection` is **not** part of `make test`.

### Running against the mount and reconciling

This step validates detection on real data before any UI is built. It is a manual step, not a test.

1. On the dev Mac, with `/Volumes/Games` mounted, run `make scan-collection`. Optionally also run `make scan-collection ARGS=--hash`.
2. Compare the output with the "Games to support" table in `planning/requirements.md`. The table currently says:
   - Unity 29, of which 4 are IL2CPP (the table counts Unity by `UnityPlayer.dll`)
   - Kirikiri 21, of which 3 have `.tpm`
   - Ren'Py 4
   - GameMaker 3
   - BGI 2
   - `Game.exe` files: 11 i386, 5 amd64
3. Resolve each mismatch:
   - either fix detection (in section 02 or 03 code, adding a synthesized fixture test for the case)
   - or correct the table where its counting method differed. For example, the scanner reports Unity both by `UnityPlayer.dll` and overall.
4. Watch these outputs for problems:
   - **Exclusion hit counts:** false exclusions of real main executables.
   - **Generic-blocklist hits and engine-id collisions:** extend section 03's generic blocklist table when real data shows a generic value.
   - **Kirikiri games with no `.xp3` files** (possible embedded XP3): these show up as `unknown` or "no game found".
5. Optionally, run `EIKON_SCAN_COLLECTION=1 uv run pytest tests/test_collection_scan.py`.
6. **Record findings by engine and count only.** Never write a folder name, title or per-folder line from the share into the repo, a commit message or an issue.

## Done when

- `make test-core` passes, including the three `ScannerTests`.
- `make test` passes, with `test_collection_scan.py` skipped.
- `make scan-collection` prints `skipped: /Volumes/Games not mounted` and exits 0 when the share is absent. With the share mounted it prints a title-free aggregate report.
- The scanner has been run against the mount. Detection has been fixed, or the requirements table corrected, so that the engine counts agree.
