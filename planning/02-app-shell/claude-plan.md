# Implementation plan: 02 · App shell

## 1. Context

Eikon is an iPhone and iPad app that will run Windows and Linux x86 games (through Wine, FEX-Emu and Box64) and Kirikiri and Ren'Py games natively, all inside the app process. Split 01 is done:
- It builds one app binary (XcodeGen + Makefile + `uv`-run Python scripts) and ships it as a Dopamine deb and an `.ipa` for AltStore and TrollStore.
- It turns JIT on where it can and reports whether the process has *usable* JIT.
- It exports a JSON device report and bundles an (empty) acknowledgements JSON.

The app is one status screen today.

This split builds **the app the user sees** and **the contracts every runtime split plugs into**:

1. **Game drives and the library.** Games sit flat inside *game drives*: folders on the device or on a USB drive. The default drive is the app's own folder, shown in Files as "On My iPad/Eikon" (or "On My iPhone/Eikon"). Import copies a game folder into a drive the user picks. Every drive is scanned automatically.
2. **Detection** of engine and architecture: Unity, Kirikiri, Ren'Py, GameMaker, BGI, PE i386/amd64, Linux ELF x86-64.
3. **Identity.** A random *game id* that settings, saves and later per-game data key on, found again through a content *fingerprint*. The game is recognized after a rename, a move, a patch copied over its files, and on a second device.
4. **A route picker.** It chooses among native Kirikiri, native Ren'Py, Wine+FEX, Wine+Box64, Linux+FEX, or unavailable. Every candidate gets a human-readable reason, and the user can override the choice.
5. **A runtime protocol and a full-screen game-session host.** The host pauses the game and stops Metal drawing when the app leaves the foreground.
6. **Next-launch crash reporting.** A session sentinel and breadcrumbs feed a banner, per-game history, a suggestion to try another route, and a prefilled GitHub issue.
7. **Per-game settings** stored as per-field last-writer-wins registers, ready for split 12's WebDAV sync.
8. **A persisted device-gate store** that later splits (05, 07) write to.
9. **A "This device" screen.** It is 01's status screen, extended with a route table and gates.
10. **A credits screen.**
11. **App text in `en.lproj`.**
12. **A collection scanner** that runs the same detection code against the owner's game share on the dev Mac.

No game runs in this split. The runtimes arrive in later splits: 03 (Kirikiri), 06–08 (Wine), 10 (Ren'Py), 13 (Linux) and 14 (Box64). Input mapping is 04, and sync is 12.

### 1.1 Decisions this plan rests on

| Topic | Decision | Why |
|---|---|---|
| Where new logic lives | A **new platform-neutral SwiftPM package, `Packages/EikonCore`** (iOS 15 + macOS 13, no UIKit). It holds detection, identity, hashing, route rules, the settings CRDT, the session sentinel, breadcrumbs, issue-URL building and the scanner. `EikonKit` depends on it for the pieces that face UIKit. | EikonKit imports UIKit and can't build on macOS. The scanner must run the *same* detection code on the Mac, and core tests run fast with `swift test`. |
| Library model | **Game drives.** The built-in drive is `Documents/`, which Files shows as "On My iPad/Eikon". Users can add folders on USB drives or other local storage. Each game is an immediate subfolder of a drive, or sits inside a single wrapper folder there. Import **copies** the game into the chosen drive. | The owner's choice. Flat folders make names unique per drive, which makes folder-name identity workable. Games on a USB drive run from the drive. |
| Identity | **Game id** = a random UUID, minted once. A location is matched to its game by (1) the same drive and folder (so an in-place patch keeps the id), (2) an exact content fingerprint, (3) the engine's own declared id, or (4) file-name similarity. Fingerprints are stored and synced only as HMACs under a library secret. | The owner's choice, after comparing launchers (research Part D). Names are never keys. Renames, moves, patches and a second device match silently, and prompts happen only on real ambiguity and never block. A mistake yields a duplicate entry, never shared saves. |
| Hashing | Identity needs no full-file hash. A fingerprint reads a listing, a few small files, and at most 2 MiB of the key file. Full SHA-256 remains only for diagnostics (scanner `--hash`, "Verify files"). | Fast, even on USB drives. No long "identifying" phase. |
| Crash recording | Session sentinel plus breadcrumbs. 02 installs **no** signal handler. A C fault hook is left for later runtimes. | FEX and Wine use SIGSEGV/SIGBUS for normal operation. Jetsam can't be caught anyway. |
| Crash reporting | A prefilled GitHub issue from an issue form (`crash.yml`), which the user reviews in Safari. Games appear in it only as a **report id**: the first 8 characters of the random game id. No file hashes. | Reports go to the owner with no Eikon-run service. A random id reveals nothing, whereas a file hash could be matched against hash databases. |
| Settings | A hand-rolled per-field LWW map with a hybrid logical clock. There is one file per device (replica). Unknown fields are preserved, reset is a tombstone, and a per-game `deletedAt` marker shadows older keys. | 12 merges per-device files over WebDAV with no locking and no migration. |
| Gates | An unmeasured gate lets a route run with a warning. A failed gate makes the route unavailable. A passed result expires when the app or OS build changes. A failed result persists, marked stale, until it is measured again. | The owner's choice. An update must not quietly turn a known failure into "allowed". |
| Override | Any route may be forced. If it can't run, the app warns and still allows it. | The owner's choice. |
| Unbuilt routes | They are chosen as normal and marked "planned — not in this build yet". | The route display is useful before splits 03 and later land. |
| Navigation | A sidebar split view on iPad (`NavigationView` in column style), collapsing to a stack on iPhone. | The owner's choice. The iOS 15 minimum rules out `NavigationSplitView` without a second code path. |
| Session host | A UIKit view controller, presented full screen from the topmost presented controller. | Only such a controller reliably controls the home indicator, status bar and edge gestures, and later splits embed UIKit render surfaces. |
| Strings | Moved to `App/en.lproj/Localizable.strings` and `Localizable.stringsdict`. Core code returns codes. | Split 09 then only adds languages. |

### 1.2 Constraints

- **No program titles anywhere**: not in the repo, logs, tests, reports, issue text, breadcrumbs or scanner output.
  - Folder names and display names are titles in practice. They stay on the device, in the local library cache and in settings, which 12 syncs only to the user's own server and never uses in paths.
  - Breadcrumbs accept only app-defined event codes and integers.
- **Test content is original.** Tests synthesize tiny fake game folders (magic bytes, layouts) in temp directories.
- **`/Volumes/Games` is read-only.** Only the scanner reads it, it opens files read-only, and nothing from it is committed.
- **Games run in-process.** A crash ends the app.
- **iOS 15 minimum.** Use `NavigationView` and `ObservableObject`. There is no `ShareLink`, `@Observable`, Swift `Atomic`/`Mutex` or `OSAllocatedUnfairLock`.
- **Swift 6 language mode** with complete concurrency checking.
- **01's style.** Small single-concept files; `Sendable` protocol seams with a `Live*` type and `.live`; pure logic in caseless enums; exhaustive enum→string-key switches with no `default:`.
- **Both builds are sandboxed.** Anything outside the container is reached only through security-scoped URLs from the document picker.
- **Tests are few and behavioral.** They don't lock in implementation details or hard-coded values (the owner's standing rule).

## 2. Package and file layout

### 2.1 New package `Packages/EikonCore`

```
Packages/EikonCore/
  Package.swift                 # tools 6.0; platforms iOS 15, macOS 13; Swift 6 mode
  Sources/
    CEikonSession/              # C: fault hook, breadcrumb slot writer, in-flight guard atomics
      include/CEikonSession.h
      CEikonSession.c
    EikonCore/
      Detection/
        BinaryInfo.swift            # PE / ELF header parsing, BinaryFormat, CPUArchitecture
        Engine.swift                # Engine, EngineDetails and their sub-enums
        DetectionResult.swift       # + GamePlatform, ExecutableInfo
        GameDetector.swift          # game root (incl. one wrapper level), detector order
        MainExecutable.swift        # exclusion table + scoring, exclusion counters
        FolderListing.swift         # case-insensitive, NFC-normalized directory lookup
        FolderReader.swift          # per-purpose seek+read budgets, zlib inflate (libz)
        PEVersionResource.swift     # minimal .rsrc VS_VERSIONINFO string reader
        UnityDetector.swift
        KirikiriDetector.swift
        RenPyDetector.swift
        GameMakerDetector.swift
        BGIDetector.swift
      Identity/
        GameIdentity.swift          # GameID, Fingerprint, Keyed, Keyed8
        NameNormalizer.swift        # NFC + trim + case-fold (listings, names)
        KeyFile.swift               # key file per engine
        EngineDeclaredID.swift      # Ren'Py save_directory, Unity app.info, GM name, exe version info + generic blocklist
        FingerprintBuilder.swift    # signals → keyed fingerprint
        IdentityMatcher.swift       # matching rules 5.4, merge links (pure)
        FileHasher.swift            # full SHA-256 for diagnostics only
      Routes/
        RouteID.swift
        GateName.swift              # RawRepresentable struct + known constants
        GateState.swift
        RuntimeCheck.swift          # .ok / .declined(RuntimeDeclineCode)
        RouteReason.swift
        RouteVerdict.swift          # + RouteCandidate, RouteDecision, RouteEnvironment
        RouteRules.swift
        RoutePicker.swift
      Settings/
        ReplicaID.swift
        HybridClock.swift
        JSONValue.swift
        LWWMap.swift
        SettingKey.swift            # typed keys, key builders, reserved namespaces
        SettingsStore.swift
      Sessions/
        SessionRecord.swift
        SessionSentinel.swift
        Breadcrumbs.swift           # BreadcrumbEvent + slot file
        FaultRecord.swift           # reads the C hook's file
        SessionOutcome.swift
        CrashHistory.swift
        CrashIssue.swift
      Library/
        GameDrive.swift             # GameDrive, DriveKind, DriveState, VolumeKind
        GameLocation.swift          # a game folder on a drive + IdentityState
        LibraryIndex.swift          # drives.json + locations.json, tolerant decoding
        FolderAccess.swift          # protocol + AccessToken
        Persisted.swift             # format header + future-format read-only rule, shared
      Scan/
        CollectionSummary.swift     # pure summary + formatting for eikon-scan
    eikon-scan/
      main.swift
  Tests/
    EikonCoreTests/
      Fixtures.swift
      DetectionTests.swift
      IdentityTests.swift
      RoutePickerTests.swift
      SettingsTests.swift
      SessionTests.swift
      ScannerTests.swift
```

- **Products:** the library `EikonCore` and the executable `eikon-scan`.
- **Dependencies:** `EikonCore` depends on `CEikonSession`, links system `libz` (`linkerSettings: [.linkedLibrary("z")]`), and uses CryptoKit, which is available on both platforms.

### 2.2 Changes to `Packages/EikonKit`

EikonKit adds a dependency on EikonCore (`.package(path: "../EikonCore")`) and these files:

```
Sources/EikonKit/
  Runtime/
    GameRuntime.swift             # protocol + LaunchableGame + GameSessionHost
    RuntimeRegistry.swift         # registration, cached checks per (game, fingerprint)
    RenderGate.swift              # Swift face of the C in-flight guard
    SceneEvents.swift             # injectable scene/audio/memory notification seam
    GameSessionHostViewController.swift
    GameSession.swift
    GameDataCleanup.swift         # hook protocol + registry (routes that own saves)
  Library/
    LibraryController.swift       # @MainActor ObservableObject
    DriveManager.swift            # add/remove/relink drives, reachability
    DriveScanner.swift            # per-drive diff, quiescence, re-detect, fingerprint + match
    ImportCoordinator.swift       # copy into a drive: space check, staging, progress, cancel
    LiveFolderAccess.swift
  Settings/
    SettingsController.swift
  Gates/
    GateStore.swift
  Diagnostics/
    CrashReportController.swift
  Credits/
    Acknowledgements.swift
```

`DeviceReport.make` gains a `gates` parameter. It defaults to empty so 01's call sites keep working.

### 2.3 App target

```
App/
  EikonApp.swift
  RootView.swift                  # sidebar: Library / Game drives / This device / Credits
  Library/
    LibraryView.swift
    LibraryRow.swift
    GameDetailView.swift
    RouteSection.swift
    IdentitySuggestion.swift      # non-blocking "same game as…?" card + merge/split actions
    ImportFlow.swift              # pick game → pick drive → "will be copied" → progress
    RemoveGameDialog.swift
    CrashBanner.swift
  Drives/
    DrivesView.swift              # list, add, relink, remove drives
  Device/
    StatusView.swift              # existing, extended
    RouteTableSection.swift
    DeveloperSection.swift
  Credits/
    CreditsView.swift
  Session/
    SessionPresenter.swift
    TestPatternRuntime.swift
  Strings/
    RouteStrings.swift            # and other exhaustive code → key maps
  en.lproj/
    Localizable.strings           # moved from App/Localizable.strings
    Localizable.stringsdict
  ReportExport.swift              # existing
```

### 2.4 Repo-level changes

- `.github/ISSUE_TEMPLATE/crash.yml`: a new file (§10.6).
- `project.yml`: add package `EikonCore` and link its product into the app. The scheme's test action adds `EikonCore/EikonCoreTests`.
- `Makefile`: add `test-core` (included in `test`) and `scan-collection`, and update `help`.
- `.github/workflows/ci.yml`: the macOS job runs `make test-core`.
- `App/Info.plist`: add `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, and `EKRepositoryURL` (`https://github.com/getBoolean/eikon`).
- `scripts/credits.py` and `tests/test_credits.py`: Eikon's own entry and the `isApp` flag (§15).
- `planning/requirements.md`, when landing: record in "Decisions" (and adjust the "No program titles" constraint's keying sentence) that game data is keyed by a random game id. Games are recognized by a fingerprint (engine-declared id, file listing, partial key-file hash) that is stored only as HMACs, rather than by a hash of the main executable. Games live flat in game drives. That sentence is a hard constraint today, so the change is an explicit owner decision (interview Q25–Q31).

## 3. Build and test wiring

- **`Packages/EikonCore/Package.swift`:** `swift-tools-version:6.0`, `platforms: [.iOS(.v15), .macOS(.v13)]`, `swiftLanguageModes: [.v6]`. Targets: `CEikonSession`, `EikonCore`, `eikon-scan` (executable) and `EikonCoreTests`.
- **`Packages/EikonKit/Package.swift`:** add the path dependency. The `EikonKit` target depends on `EikonCore`. There are no re-exports; the app imports both.
- **XcodeGen:** declare the local package and link `EikonCore` into the app. The scheme's test targets list both test bundles, so `scripts/test_swift.sh` runs both suites on the simulator unchanged.
- **Make targets:**
  - `make test-core` runs `swift test --package-path Packages/EikonCore` natively on the Mac.
  - `make test` becomes `test-core test-swift test-scripts`.
- **CI:** the macOS job adds `make test-core`. The Ubuntu job is unchanged.

## 4. Detection (EikonCore/Detection)

### 4.1 Types

```swift
public enum Engine: String, Codable, Sendable, CaseIterable {
    case unity, kirikiri, renpy, gameMaker, bgi, unknown
}
public enum GamePlatform: String, Codable, Sendable { case windows, linux }
public enum BinaryFormat: String, Codable, Sendable { case pe, elf }
public enum CPUArchitecture: String, Codable, Sendable {
    case i386, amd64, arm64, other            // arm64 covers ARM64, ARM64EC, ARM64X
}

public struct ExecutableInfo: Codable, Sendable, Equatable {
    public var path: String                   // relative to the game root
    public var format: BinaryFormat
    public var architecture: CPUArchitecture
    public var machine: UInt16                // raw COFF Machine / ELF e_machine
    public var isGUI: Bool?                   // PE subsystem; nil for ELF
}

public struct EngineDetails: Codable, Sendable, Equatable {
    public var unityScripting: UnityScripting?       // mono / il2cpp
    public var unityVersion: String?                 // best effort, display only
    public var kirikiriFlavor: KirikiriFlavor?       // krkr2 / krkrZ / unknown
    public var xp3ProtectedFlag: Bool?               // XP3 TVP_XP3_FILE_PROTECTED seen on an entry
    public var xp3IndexReadable: Bool?               // index decoded (raw or zlib)
    public var pluginFileNames: [String]             // .tpm and plugin/*.dll base names, sorted
    public var renpyVersion: RenPyVersion?           // major/minor/patch?, exact or era
    public var renpyNativeExtensions: [String]       // game-supplied native module base names
    public var gameMakerBuild: GameMakerBuild?       // vm / yyc
}

public struct DetectionResult: Codable, Sendable, Equatable {
    public var engine: Engine
    public var details: EngineDetails
    public var gameRoot: String                      // "" or the single wrapper subfolder name
    public var executables: [GamePlatform: ExecutableInfo]   // main exe per platform
    public var keyFile: String?                      // relative to gameRoot (§5.3)
    public var detectorVersion: Int                  // bump to force re-detection
}
```

- **Future values decode safely.** Every enum decodes an unknown raw value to a fallback: `unknown` for `Engine`, and `other` or `nil` elsewhere. A value written by a newer or older build therefore never fails a whole file.
- **Detection is a cache.** A stored result with an older `detectorVersion` is recomputed.
- **Names only.** Plugin and extension lists hold base names only.

### 4.2 Entry point

```swift
public enum GameDetector {
    /// Detects the game in a game folder (an immediate child of a game drive). Checks the
    /// folder itself; if no engine markers or executable are there and the folder holds
    /// exactly one subfolder that does, that subfolder is the game root. Read-only.
    public static func detect(folder: URL) throws -> DetectionResult?   // nil = no game found
}
```

**Detector order:** Ren'Py, Unity, Kirikiri, GameMaker, BGI.
- The first match wins. The order runs from most specific layout to least, so a Ren'Py or Unity game that ships an `.xp3` or `.arc` is not misread.
- If no engine matches but a main executable does, the result is `engine: .unknown` with its executables. That still lets Wine or Linux be offered.
- If there is neither, the result is `nil`, and the UI shows "No game found here".
- Directory entries are visited in sorted normalized-name order, so results are deterministic.

**`FolderListing`:**
- Every marker lookup goes through a directory listing, matched case-insensitively on NFC-normalized, case-folded names. It never uses `fileExists(atPath:)` with a literal case.
- Pairing `<stem>.exe` with `<stem>_Data` or `<stem>.py` uses the same normalization. This matters on case-sensitive APFS externals, on exFAT, and on the SMB mount.

**`FolderReader`**, with per-purpose budgets:
- **Never** writes, and never follows symlinks out of the folder.
- **Budgets:**

  | Purpose | Budget |
  |---|---|
  | PE / ELF headers | up to 64 KiB, following `e_lfanew` and section headers |
  | PE version resource | seeks into `.rsrc`; reads ≤256 KiB |
  | XP3 index | seek to the index offset; read ≤8 MiB compressed |
  | GameMaker chunk walk | reads only the 8-byte chunk headers across the file |
  | Small text files | ≤64 KiB (Ren'Py version files) |

- **Stops early.** Each detection stops early once its question is answered.
- **zlib:** decoded with system `libz` (`uncompress`/`inflate`), which handles the zlib header that the Compression framework does not.

### 4.3 Per-engine rules

- **Ren'Py**
  - *Recognition:* a `renpy/` dir and a `game/` dir, plus one of: `renpy/__init__.py[c|o]`, a `*.rpyc` or `*.rpa` file in `game/`, or `lib/`.
  - *Version*, first match wins:
    1. `game/script_version.txt` tuple
    2. `version = "M.m.p…"` in `renpy/vc_version.py`
    3. `version_tuple = (M, m, p` in `renpy/__init__.py`
    4. era from `lib/` names: bare `windows-*`/`linux-*` + `pythonlib2.7` means ≤7.3; `py2-*` means 7.4+; `py3-*` + `python3.9` means 8.0–8.3; `python3.12` means 8.4+
  - *Native extensions:* base names of `*.pyd`/`*.so`/`*.dll`/`*.dylib` under `game/`, including `game/python-packages/`.
  - *Executables:* the Windows exe whose stem has a sibling `<stem>.py`. The Linux executable is `lib/py*-linux-x86_64/<stem>` (the ELF, not the `.sh`).
- **Unity**
  - *Recognition:* `UnityPlayer.dll`/`.so`, **or** a `<stem>_Data/` directory containing `globalgamemanagers`, `mainData` or `data.unity3d`. The second form covers pre-2017 games that have no `UnityPlayer.dll`.
  - *Scripting backend:* IL2CPP if `GameAssembly.dll`/`.so` or `<stem>_Data/il2cpp_data/` exists. Mono if `<stem>_Data/Managed/Assembly-CSharp.dll` exists.
  - *Version* (best effort): from the big-endian SerializedFile header of `globalgamemanagers` (string at 0x14 for format 9–21, at 0x30 for ≥22), or from the second string after `UnityFS\0` in `data.unity3d`.
  - *Executables:* the `.exe` with a sibling `<stem>_Data/`, and the Linux `<stem>.x86_64`.
- **Kirikiri**
  - *Recognition:* any root `*.xp3` whose first 11 bytes are `58 50 33 0D 0A 20 0A 1A 8B 67 01`.
  - *Plugins:* base names of `*.tpm` in the root and in one level of subfolders, plus `plugin/*.dll`.
  - *Flavor:* taken from the main exe's version resource `ProductName`/`FileDescription` (`TVP(KIRIKIRI) 2` vs `Z`). If that fails, fall back to a bounded ASCII/UTF-16LE string scan.
  - *Index:* read the index of `data.xp3` (or the largest `.xp3`), following the v2 continuation header.
    - `xp3IndexReadable` records whether it decoded.
    - `xp3ProtectedFlag` records whether any `info` entry has bit 31 set. That bit is Kirikiri's "extraction protected" flag, **not** an encryption marker.
    - Encryption detection belongs to 03's can-run check. 02 makes no encryption claim.
- **GameMaker**
  - *Recognition:* `data.win` or `game.unx` with `FORM` at offset 0 and `GEN8` at offset 8.
  - *Build type:* walk the chunk headers. An absent or empty `CODE` chunk means YYC; otherwise VM.
- **BGI**
  - *Recognition:* an exe named `BGI.exe` (case-insensitive), or at least two root `*.arc` files whose first 12 bytes are `PackFile    ` or `BURIKO ARC20`.
- **PE**
  - *Header:* `MZ`; `e_lfanew` at 0x3C, sanity-checked (4-aligned, < 64 KiB, < file size); then `PE\0\0`.
  - *Machine:* `0x014C` → i386, `0x8664` → amd64, `0xAA64`/`0xA641`/`0xA64E` → arm64, anything else → other.
  - *Flags:* DLLs (Characteristics `0x2000`) are never executables. The subsystem is read from the optional header.
- **ELF**
  - *Header:* the `7F 45 4C 46` magic, then `EI_CLASS`, then `e_machine` at 0x12.
  - *Machine:* 62 → amd64, 3 → i386, 183 → arm64.

### 4.4 Main executable selection

1. **Candidates:** `*.exe` files in the game root. For Linux, root files carrying the ELF magic.
2. **Exclusions:** one static table of case-insensitive patterns.
   - Excluded names: `unins*`, `UnityCrashHandler*`, `vc_redist*`/`vcredist*`, `dxsetup`, `dotnet*`, `ndp*`, `notification_helper`, `crashpad_handler`, `CrashReport*`, `*setup*`, `*install*`, `oalinst`, `UE4PrereqSetup*`, `python*`, `zsync*`, `renpy.exe`.
   - DLLs are excluded too.
   - Each rule counts its hits. The scanner reports these counts so false exclusions show up on real data.
3. **Engine rules first:** the engine-specific executable choices in §4.3 are applied before general scoring.
4. **Scoring:** a GUI subsystem wins, then the largest file.

## 5. Identity (EikonCore/Identity)

This follows the common launcher pattern (Playnite, Heroic, Bottles): an **opaque id owned by Eikon**. The id is found again through a **content fingerprint**, as emulators do with disc ids and ROM hashes, and as PC engines do with their declared save ids.
- Names are never keys.
- Renames, moves between drives, patches and a second device match silently.
- The user is asked only on genuine ambiguity, and never in a blocking way.

Background is in `claude-research.md` Part D.

### 5.1 Types

```swift
public struct GameID: Hashable, Codable, Sendable { public let uuid: UUID }   // random, minted once

public struct Fingerprint: Codable, Sendable, Equatable {
    public var scheme: Int                   // bump to change how fingerprints are computed
    public var engineID: Keyed?              // engine-declared identity, keyed (see 5.3)
    public var exact: Keyed                  // listing with sizes + key-file partial hash, keyed
    public var names: [Keyed8]               // keyed 8-byte digests of top-level entry names (≤256)
}
public struct Keyed:  Hashable, Codable, Sendable { public let hex: String }   // HMAC-SHA256, 64 hex
public struct Keyed8: Hashable, Codable, Sendable { public let hex: String }   // truncated to 16 hex
```

A game id is a random UUID, minted when a folder matches no existing game. It never encodes anything about the game, so its first 8 characters can serve as the **report id** in crash issues (§10.5) with nothing to reverse.

### 5.2 Signals (`FingerprintBuilder`)

All signals are computed from the **game root**, never from the game folder's own name, so renaming the folder changes nothing.

- **Engine-declared id.** The identity the game's engine uses for its own saves, and the signal most likely to survive a patch:
  - *Ren'Py:* `config.save_directory`, read from `game/options.rpy` when shipped. The Ren'Py detector also scans `.rpyc` data; if the value can't be found, the signal is absent.
  - *Unity:* company and product from `<stem>_Data/app.info`, two lines of plain text.
  - *GameMaker:* the GEN8 `Name` and `DisplayName` strings.
  - *Windows executables (any engine, including Kirikiri, BGI and unknown):* `CompanyName` + `ProductName` from the main exe's version resource, **unless** they are an engine's generic values (such as `TVP(KIRIKIRI)`, `Unity`, `DefaultCompany`, `My project`). The generic values are one static blocklist table, and scanner data extends it.
  - The value is prefixed with the engine (`"renpy:" + value`).
- **Exact signal.** The sorted top-level listing of the game root (normalized names and file sizes, directories by name only), plus the key file's size and the SHA-256 of its first and last 1 MiB. Any real change to the game's files changes it.
- **Name set.** Normalized names of top-level entries in the game root, excluding generic names such as `data`, `save`, `savedata`, `plugin`, `lib`, `game`, `renpy`, `*_Data` and common DLLs. It is used for similarity (Jaccard) when the engine id is missing.

**The key file** is the game-specific file used in the exact signal:

| Engine | Key file (first that exists) |
|---|---|
| Kirikiri | `data.xp3`, then the largest root `.xp3`, then the main exe |
| GameMaker | `data.win` / `game.unx` |
| Unity | `GameAssembly.dll`/`.so`, `<stem>_Data/Managed/Assembly-CSharp.dll`, `<stem>_Data/globalgamemanagers` |
| Ren'Py | the largest `game/*.rpa`, then the largest `game/*.rpyc` |
| BGI / unknown | the main exe |

**Cost.** Computing a fingerprint reads a directory listing, a few small files and at most 2 MiB of the key file. That is fast even on a USB drive, so there is no full-file hashing and no long "identifying" phase.

### 5.3 Keyed values (privacy)

Plain signals contain titles, since engine ids and file names often are titles. They are never stored or synced in plain form.
- Every signal is stored as HMAC-SHA256(library secret, signal). `names` entries are truncated to 8 bytes.
- The **library secret** is 32 random bytes, created once in `Application Support/Eikon/library-secret`.
- A second device must use the **same** secret, so its fingerprints compare equal. Carrying the secret between the user's devices is split 12's job, through its pairing step and never in plain text on the server. Until then each device has its own secret, and cross-device matching starts working when 12 lands.
- The scanner uses a fixed, documented scanner secret. Its output is comparable across runs and is never the app's secret.

### 5.4 Matching (`IdentityMatcher`, pure)

Inputs:
- the new or changed location's fingerprint
- this device's locations and their game ids
- every known game's stored fingerprints, from settings

Each game's fingerprints are stored under `game/<id>/fp/<scheme>` (§7.2). Known games include those synced from other devices. A game can hold several fingerprints: one per distinct build seen, capped at the most recent 8.

Rules, applied in order:

1. **Known location.** Same drive, same folder name, and the location already has a game id: it keeps that id, **whatever changed inside**. This is how an **in-place update** is recognized: the user copies a patch over the game's files, or uses Import → *Replace existing copy*. The new fingerprint is added to the game.
2. **Exact match.** The exact signal equals a fingerprint of exactly one game: attach to it. This covers a rename, a move to another drive, a second copy on another drive (the game then has two locations), and the same game on another device.
3. **Engine-id match.** The engine id equals one of exactly one game's fingerprints:
   - If that game has **no live location on this device**, attach silently and add the fingerprint. This covers a patched copy that was moved, renamed or re-imported, and a newer version on another device.
   - If that game **does** have a live location here, this is a different version sitting beside the known one. Create a **new** game and post a non-blocking suggestion on it: *"Same game as <display name>, different version?"* Accepting merges (§5.5). Ignoring keeps them separate.
4. **Name similarity.** No engine id on either side, name-set Jaccard ≥ 0.8, and exactly one candidate game with no live location here: attach silently and add the fingerprint. This covers a patched and renamed or moved game from an engine with no declared id.
5. **Otherwise** mint a new game id. If more than one candidate matched under rule 2, 3 or 4, attach to none: create a new game and post the same non-blocking suggestion, listing the candidates.

**Deleted games** (with `deletedAt` set, §6.9) are never candidates. A game re-imported after its data was deleted starts fresh.

**Failure mode.** A mistake produces a duplicate entry, never two games sharing settings or saves. The user can always use **"Same game as…"** in the game's menu to merge, and **"This is a different game"** to split a location off into a new id. Both are rare, explicit, and never modal.

### 5.5 Merge and split

- **Merge A into B.**
  - Write the global setting `merged/<A>` = B, so other devices follow.
  - Copy A's settings into B where B has none.
  - Move A's fingerprints to B.
  - Point A's locations at B.
  - Run each registered `GameDataMerge` hook, so routes can move saves in their split (none in 02).
  - Resolving a game id follows `merged/` links for at most 4 hops. A cycle breaks to the lowest UUID.
- **Split a location off.** Mint a new id, copy the old game's settings into it (a fork, as Lutris does when it de-duplicates), move that location's fingerprint to it, and remove that fingerprint from the old game.

### 5.6 Hashing for diagnostics (`FileHasher`)

Full SHA-256 is not part of identity. `FileHasher` stays in EikonCore with two uses:
- the scanner's `--hash` (build hashes for the owner's records)
- a "Verify files" action in game detail's developer area

It streams 1 MiB chunks, reports progress, and supports cancellation.

## 6. Game drives and the library

### 6.1 Storage locations

All roots are resolved from `FileManager.url(for:in:)`. No absolute container path is stored.

- **`Documents/`** is the **built-in game drive**, shown in Files as "On My iPad/Eikon" or "On My iPhone/Eikon".
  - Its immediate subfolders are games.
  - `Inbox` and names starting with `.` are ignored.
  - It is excluded from backup; the flag is re-applied at launch.
- **`Library/Application Support/Eikon/`** holds:
  - `drives.json` and `locations.json` (the library index, local only)
  - `replica-id` and `library-secret`
  - `settings/<replica>.json`
  - `gates.json`
  - `sessions/`: `sentinel.json`, `breadcrumbs.bin`, `fault.bin`, `history.json`

### 6.2 Persisted-file rules (`Persisted`)

Every JSON file above carries a `format` integer and is written atomically: to a temp file, then renamed and fsynced.

- **Newer `format`:** a file with a newer `format` than the app knows is **read-only**. It is loaded as far as possible and never rewritten.
- **Tolerant decoding:** collections decode per element. A bad element is dropped from the in-memory view, but the raw element is kept and written back unchanged, so a downgrade doesn't destroy data.
- **Stale states:** a persisted in-progress fingerprinting state loads as `pending`.

### 6.3 Model

```swift
public struct GameDrive: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: DriveKind          // .builtIn / .folder(bookmark: Data)
    public var label: String            // user-visible, device-local (volume or folder name)
}
public enum DriveState: Sendable { case available, notConnected, needsRelink }

public struct GameLocation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var driveID: UUID
    public var folderName: String        // device-local only; never logged or exported
    public var detection: DetectionResult?          // cache
    public var fingerprint: Fingerprint?            // latest; nil until computed
    public var gameID: GameID?           // nil only until the first match runs
    public var lastSeen: LocationSeen    // listing digest + mtime, for re-detect/quiescence
    public var suggestion: [GameID]      // non-blocking "same game as…?" candidates
    public var dismissedSuggestions: [GameID]
}
```

The library the UI shows is a **list of games** (grouped by resolved game id). Each game has one or more locations.
- **Launch location:** launch uses a reachable location, preferring the built-in drive, then the most recently used.
- **Missing locations:** a location whose folder vanished while its drive is available is *missing*. It is shown on the game and removable, but it is never deleted automatically.
- **Games with no locations** are hidden. Their settings remain.

### 6.4 Folder access

```swift
public protocol FolderAccess: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func open(bookmark: Data) throws -> AccessOutcome   // .opened(AccessToken, refreshedBookmark: Data?) / .notConnected / .stale
    func volumeKind(of url: URL) -> VolumeKind           // .internal / .externalLocal / .ubiquitous / .network / .unknown
}
public final class AccessToken: @unchecked Sendable {
    public let url: URL
    public func close()                                  // idempotent; deinit closes as a backstop
}
```

`LiveFolderAccess` (in EikonKit) uses:
- `bookmarkData()`
- `URL(resolvingBookmarkData:bookmarkDataIsStale:)`. When the bookmark is stale, it re-bookmarks while it has access and returns the refreshed bookmark.
- start/stop of security-scoped access
- the resource values `volumeIsInternal`, `volumeIsLocal` and `isUbiquitousItem`

Tests use a fake.

### 6.5 Drives (`DriveManager`)

- **Add a drive:** "Add game drive…" opens `.fileImporter(allowedContentTypes: [.folder])`.
  - Accepted: `.externalLocal` (USB-C SSD, SD card) and `.internal` locations (for example a folder in On My iPad).
  - Refused, each with a one-line reason: `.ubiquitous` (iCloud Drive), `.network` (SMB) and `.unknown`. Evictable or network files are unsafe under an in-process emulator.
  - The bookmark is stored, and the drive is scanned.
- **Drive states:** re-evaluated at launch, on scene activation and before launching a game.
  - `available`: resolves and opens.
  - `notConnected`: the volume is absent.
  - `needsRelink`: stale and unresolvable. "Find folder…" re-picks the folder. If the new pick contains none of the drive's known folder names, the app asks for confirmation.
- **Remove a drive:** removes only the drive record. The files on it are untouched, and the settings stay.
- **The built-in drive** can't be removed and is always available.
- **During a session:** the host holds the drive's access token. Unplugging mid-game can crash the app. That is an accepted risk, and the sentinel reports it on the next launch.

### 6.6 Scanning (`DriveScanner`)

For each available drive, at launch and on scene activation, the scanner diffs the drive's immediate subfolders against its locations:
- **Skipped folders:** names starting with `.`, which includes Eikon's `.eikon-importing-*` staging folders, and `Inbox` on the built-in drive.
- **New folder:** a new location is created (`identity: pending`) and detection runs.
- **Changed folder:** if the folder's mtime or top-level listing fingerprint changed, or the last detection was `nil` or `unknown`, detection runs again.
- **Quiescence:** fingerprinting and matching start only after the same listing digest and key-file size and mtime are seen on two scans at least 10 seconds apart. Until then the location shows "Waiting for copy to finish…". This covers folders still being copied in, and **patches being copied over a game**.
- **Changed contents at a known location** (for example a patch copied over the files): the location keeps its game id (rule 1 of §5.4). Once the folder is quiescent again, the new fingerprint is computed and added to the game, and the game is re-detected, which may change its route.
- **Fingerprinting** runs on one serial background worker. The viewed location goes first. The worker holds the drive's access token while reading, and pauses while a game session is active. A read failure marks the location `failed(code)` with "Retry".
- **Vanished folder:** the location becomes `missing`.

Scans run off the main actor, publish results on it, and are **suspended while a game session is active**.

### 6.7 Import (`ImportCoordinator`)

1. **Pick the game.** `.fileImporter(allowedContentTypes: [.folder])` returns a security-scoped URL, and access is held for the whole import. `GameDetector.detect` runs on it. With no game found, the flow says so and stops.
2. **Pick the drive.** Available drives are listed with their free space. The built-in "On My iPad/Eikon" is preselected, and the copy's size is shown. The sheet states plainly: **"The game's files will be copied to <drive>. The original folder is not changed."**
3. **Name check.** If the drive already has a folder with the same normalized name, the user picks *Replace existing copy*, *Import with another name…* (a text field that must give a new normalized name), or *Cancel*.
4. **Space check.** Uses `volumeAvailableCapacityForImportantUsage` on internal drives and `volumeAvailableCapacity` on external ones, with a margin.
5. **Copy.**
   - Copy into `<drive>/.eikon-importing-<uuid>/<name>`: enumerate and total first, then copy file by file with clone-capable copy APIs, so same-volume copies are near-instant.
   - Progress is throttled. Cancel is checked between files and between chunks of large files.
   - Symlinks are never followed.
   - Reads from file-provider sources use `NSFileCoordinator` coordinated reading, so placeholders are downloaded first.
   - The work runs inside `beginBackgroundTask`. If the app is suspended or killed, the staging folder is deleted at the next launch (or on cancel or failure). The user restarts the import.
6. **Commit.**
   - For a new name, rename the staging folder to `<drive>/<name>`. This is atomic on the same volume.
   - For *Replace existing copy*, `FileManager.replaceItemAt` is used, so a failure never leaves neither copy.
   - The scanner then finds the folder as usual. Import registers the location first, so there is no duplicate.
7. **Settle.** Detection, fingerprinting and matching (§5.4) run. *Replace existing copy* keeps the existing location, and with it the game id (rule 1). That is how an update installed through Import stays the same game.

### 6.8 `LibraryController` (EikonKit, `@MainActor ObservableObject`)

It publishes:
- the drives and their states
- the games, grouped by resolved game id, with their locations, their fingerprinting state, and any non-blocking "same game as…?" suggestions
- each game's current `RouteDecision` (§8)

Its entry points:
- `addDrive`, `relinkDrive`, `removeDrive`
- `importGame(from:to:name:)`
- `rescan()`
- `merge(_:into:)`, `split(location:)`, `dismissSuggestion`
- `remove(game:deleteLocations:deleteData:)`
- `retryFingerprint`

It recomputes route decisions when any of these change:
- JIT status, which can flip from not usable to usable during a session
- gates
- overrides
- the runtime registry
- cached runtime checks

### 6.9 Remove a game (`RemoveGameDialog`)

The dialog has two independent choices:
1. **Delete game files:** one checkbox per location on an available drive. The dialog shows the size and the drive label. Files on drives that aren't connected can't be deleted, and the dialog says so.
2. **Delete settings and saves (on all devices):**
   - Writes `game/<id>/deletedAt`, which shadows every older key under the game's prefix, including keys this device never saw.
   - Runs each registered `GameDataCleanup` hook locally. 12 later runs the hooks on other devices when a merged `deletedAt` is newer than their local data. Save-owning routes (03, 08, 10) register hooks. 02 defines the protocol and registers none.

With neither choice selected, the game's locations are forgotten. Because drives are scanned, a location whose files remain will reappear. So when files are kept, the dialog says "This game will reappear while its folder is on a game drive" and offers only the two choices above.

## 7. Settings (EikonCore/Settings)

### 7.1 Model

- **`HybridTimestamp { wallMillis: Int64, counter: UInt32, replica: ReplicaID }`**, totally ordered.
  - `HybridClock.tick(now:)` never goes backwards, even when the wall clock does.
  - `observe(_:)` advances the clock past any merged timestamp.
- **`JSONValue`**: null, bool, number, string, array or object.
- **`LWWEntry { value: JSONValue, time: HybridTimestamp, isTombstone: Bool }`**.
- **`LWWMap`**:
  - `merge` keeps the entry with the greater timestamp for each key. It is commutative, associative and idempotent.
  - `set` and `reset` are both writes; reset writes a tombstone.
  - Unknown keys are kept and written back as they are.
- **Effective read.** A key under `game/<id>/` counts only if its timestamp is newer than that game's `deletedAt` timestamp, if there is one.
- **Replica file** `settings/<replica>.json` holds `{ format: 1, replica, clock, entries }`. Other replicas' files in `settings/` are merged in; there are none until 12 places them there.
  - **Unknown future format in another replica's file:** that file is merged read-only.
  - **Unknown future format in this device's own file** (after a downgrade): the store forks to a **new replica id**, keeps the old file untouched, merges it read-only, and flags the condition for the developer section.

### 7.2 Keys

```swift
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String            // stable dotted name
    public let scope: Scope            // .game / .global
}
```

- **Per-game keys** are stored as `game/<gameIDhex>/<name>`. Enum values are stored as their string raw values.
- **Keys defined in 02:**
  - per-game: `displayName`, `route.override`, `deletedAt`, and `fp/<scheme>/<n>`. The last holds the game's fingerprints (keyed values only; up to 8, most recent kept; each slot is a separate key, so two devices adding fingerprints don't overwrite each other).
  - global: `merged/<gameUUID>`, which points a merged game at the one it merged into (§5.5)
- **Reserved namespaces**, documented in `SettingKey.swift` together with the split that owns each: `fex.*` (05), `controls.*` (04), `codePage` (09).
- **Display name:** the default is the folder name of the game's first location, which is not stored as a setting until the user edits it. The display name never enters logs, reports or issues.

### 7.3 Store

`SettingsStore` (EikonCore) is file-backed, lock-guarded and `@unchecked Sendable`.
- **Reads:** typed accessors decode lazily. A decode failure counts as unset.
- **Writes:** writes update memory at once. Persistence is coalesced off the main thread: debounced about 0.5 s, and flushed on scene background and before a game session starts.
- **Game-wide operations:** `removeAll(game:)` writes `deletedAt`. `fingerprints(game:)` and `addFingerprint(_:game:)` manage `fp/*`.
- **Replica id:** a UUID created once in `replica-id`. The Dopamine and ipa installs have separate containers and are separate replicas.

`SettingsController` (EikonKit) is a `@MainActor ObservableObject` over the store.
- Display-name edits commit on submit, not on every keystroke.
- A location's settings are read-only in the UI until it has a game id. That takes a second or two after the folder is quiescent.

## 8. Routes (EikonCore/Routes)

### 8.1 Types

```swift
public enum RouteID: String, Codable, Sendable, CaseIterable {
    case nativeKirikiri = "native-kirikiri", nativeRenPy = "native-renpy"
    case wineFEX = "wine-fex", wineBox64 = "wine-box64", linuxFEX = "linux-fex"
}
public struct GateName: RawRepresentable, Hashable, Codable, Sendable {
    public static let x18: GateName          // "x18"
    public static let guestWindow: GateName  // "guestWindow"
}
public enum GateState: Sendable, Equatable { case passed, failed(stale: Bool), unmeasured }
public struct RuntimeDeclineCode: RawRepresentable, Hashable, Codable, Sendable { }  // owned by runtimes
public enum RuntimeCheck: Sendable, Equatable { case ok, declined(RuntimeDeclineCode) }

public enum RouteVerdict: Sendable, Equatable { case runnable, runnableWithWarnings, planned, unavailable }

public enum RouteReason: Sendable, Equatable {
    case engineNotHandled(Engine)
    case needsWindowsBinary, needsLinuxBinary
    case architectureUnsupported(CPUArchitecture)
    case needsJIT
    case box64Only32Bit
    case fexPreferredWithJIT          // Box64 demoted, still runnable
    case gateFailed(GateName, stale: Bool)
    case gateUnmeasured(GateName)
    case notInThisBuild
    case runtimeDeclined(RuntimeDeclineCode)
    case nativeFirst
    case overriddenByUser
}

public struct RouteCandidate: Sendable, Equatable { public var route: RouteID; public var verdict: RouteVerdict; public var reasons: [RouteReason] }
public struct RouteDecision: Sendable, Equatable {
    public var chosen: RouteCandidate?            // nil = unavailable
    public var candidates: [RouteCandidate]       // preference order
    public var isOverride: Bool
    public var overrideWarnings: [RouteReason]
}
public struct RouteEnvironment: Sendable {
    public var jitUsable: Bool
    public var gates: [GateName: GateState]       // missing = unmeasured
    public var builtRoutes: Set<RouteID>
    public var runtimeChecks: [RouteID: RuntimeCheck]   // for this game, from built runtimes
}
```

- **Strings.** The UI maps every reason through exhaustive switches.
  - Known `GateName` constants get their own strings. Any other name uses a generic "<gate> check" sentence with the raw name.
  - A `RuntimeDeclineCode` uses a string key built from its raw value, `route.decline.<raw>`, which the owning split adds. If the key is missing, a generic "This runtime can't run this game (<code>)" is shown.
- **Install method.** The picker doesn't take an install method. The install method matters only through JIT usability, and whenever `needsJIT` appears the UI shows 01's JIT reason, which names the install method and the fix.

### 8.2 Rules (`RouteRules`, one static table)

| Route | Applies to | Needs JIT | Required gates |
|---|---|---|---|
| native-kirikiri | engine `kirikiri` | no | none |
| native-renpy | engine `renpy` | no | none |
| wine-fex | a Windows executable, i386 or amd64 | yes | amd64: `x18`; i386: `x18`, `guestWindow` |
| wine-box64 | a Windows executable, i386 only | no | `x18`, `guestWindow` |
| linux-fex | a Linux executable, amd64 | yes | none |

Splits 05 and 07 write these gates and may adjust the table when they land.

### 8.3 Picking

`RoutePicker.decide(detection:environment:override:) -> RouteDecision` is a pure function.

1. **Evaluate every route.** A route gets its verdict from the first rule that applies:
   - Unmet engine, platform or architecture → `unavailable`, with the reason.
   - JIT required but not usable → `unavailable`, `needsJIT`.
   - A failed required gate → `unavailable`, `gateFailed`. A stale failure is still a failure.
   - Not in `builtRoutes` → `planned`, `notInThisBuild`.
   - A built runtime's check is `declined` → `unavailable`, `runtimeDeclined`.
   - Otherwise → `runnable`. It is `runnableWithWarnings` if a required gate is unmeasured, and each such gate adds a `gateUnmeasured` reason.
2. **Order.**
   - The engine's native route comes first. Wine candidates behind it get `nativeFirst`.
   - Then `wine-fex`, `wine-box64` and `linux-fex`.
   - When JIT is usable, `wine-box64` stays evaluated normally but is ordered after `wine-fex` and gets `fexPreferredWithJIT`. It is a demotion, not a removal, so Box64 still runs when FEX is planned, declined or gated out.
3. **Choose.**
   - The first `runnable` or `runnableWithWarnings` candidate wins.
   - If there is none, the first `planned` candidate is chosen.
   - If there is none of those either, `chosen` is nil.
4. **Override.** A forced route becomes `chosen` whatever its verdict. `overrideWarnings` carries its reasons when it isn't runnable.

## 9. Runtime interface and session host (EikonKit/Runtime)

### 9.1 Protocol

```swift
public protocol GameRuntime: AnyObject {
    static var route: RouteID { get }
    /// Game-specific check beyond RouteRules (plugins, Ren'Py version, ...). Runs off the
    /// main actor, may read files, must be cheap enough to run once per (game, build).
    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck
    @MainActor init()
    @MainActor func launch(_ game: LaunchableGame, in host: GameSessionHost) async throws
    @MainActor func pause()          // stop game time, audio, and GPU submission
    @MainActor func resume()
    @MainActor func stop() async     // tear down; release files
}

public struct LaunchableGame: Sendable {
    public var gameID: GameID
    public var root: URL             // game root, accessible for the session
    public var detection: DetectionResult
    public var route: RouteID
}

@MainActor public protocol GameSessionHost: AnyObject {
    var contentView: UIView { get }
    var renderGate: RenderGate { get }
    func runtimeDidEnd(error: Error?)
}
```

`RuntimeRegistry` (`@MainActor`):
- `register(_:)`, `builtRoutes` and `runtimeType(for:)`.
- `check(route:detection:root:cacheKey:) async -> RuntimeCheck`. Results are cached per (route, game id, exact fingerprint), so a patch that changes the files re-runs the check.
- The cache is invalidated when the registered runtimes change.

Runtimes are registered in `EikonApp.init`. In 02 none are registered, and the developer `TestPatternRuntime` is not a route.

### 9.2 `RenderGate`

The render gate is an in-flight guard built on C11 atomics in `CEikonSession`. iOS 15 has no Swift atomics.
- **Render threads** call `enter()` before encoding or committing GPU work and `leave()` after `commit()` returns. `enter()` returns false when the gate is closed, and the runtime then skips the frame.
- **The host** calls `close(timeout:) -> Bool`. It marks the gate closed and waits until the in-flight count is zero, polling with short sleeps and bounded at about 100 ms by default.
- **Main-thread safety:** the host never calls `close` while holding anything a render thread needs. Runtimes must not block their render path on the main thread between `enter` and `leave`. The protocol documentation states this.
- **Timeout:** if `close` times out, the host records breadcrumb `renderGateTimeout` and continues. It never waits unbounded on the main thread.

### 9.3 `GameSessionHostViewController`

- **Presentation.** `SessionPresenter` presents the controller full screen from the **topmost presented** view controller of the key window's scene. It overrides:
  - `prefersStatusBarHidden` → `true`
  - `prefersHomeIndicatorAutoHidden` → `true`
  - `preferredScreenEdgesDeferringSystemGestures` → `.all`
- **Events** reach the host through `SceneEvents`, an injectable seam. The live implementation filters notifications to the host's own window scene and also covers `AVAudioSession` interruptions, route changes and memory warnings.
  - *Will deactivate:* close the render gate, call `runtime.pause()`, add breadcrumb `sessionPaused`.
  - *Did enter background:* inside `beginBackgroundTask`, make sure the pause has completed and the gate is closed. Then set the sentinel phase to `background`, flush settings, and add breadcrumb `sessionBackgrounded`.
  - *Did activate:* set the sentinel phase to `running` and show a "Tap to resume" overlay. A tap opens the gate, calls `runtime.resume()`, and adds `sessionResumed`.
  - *Audio interruption began:* pause as for deactivation. *Ended:* show the overlay. Resume happens only through the overlay.
  - *Route change `oldDeviceUnavailable`:* pause and show the overlay.
  - *Memory warning:* breadcrumb `memoryWarning` plus a memory sample.
- **Menu.** A small auto-hiding menu button offers Resume and Quit. Quit calls `runtime.stop()`, ends the session and dismisses.

`GameSession` owns one session, in this order:
1. Flush settings.
2. Open the drive's access token.
3. Arm the sentinel (§10) and open the fault file.
4. Suspend scans and fingerprinting.
5. Create the runtime and call `launch`.

When the session ends, it stops the runtime, disarms the sentinel, closes the fault file and the token, and resumes background work. A periodic timer (every 30 s while running) records `memorySample(availableMB)` from `os_proc_available_memory()`.

### 9.4 Developer test-pattern session

`TestPatternRuntime` (App target) exercises the host contract without a game:
- It draws an animated pattern into a `CAMetalLayer` from its own render thread, using `enter`/`leave` around every commit.
- It counts command-buffer errors and shows the count in the overlay.

Both actions sit under **This device → Developer**, which is collapsed by default and present in every build:
- **Run test session** starts a session with the test-pattern runtime.
- **Simulate crash during session** starts a test session and calls `abort()` after 5 s.

Test sessions use a fixed synthetic game id, the hash of a constant domain string, and record their route as `test`.

## 10. Crash recording and reporting

### 10.1 Session record and sentinel (EikonCore)

```swift
public struct SessionRecord: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var gameID: GameID
    public var engine: Engine
    public var architecture: CPUArchitecture?
    public var route: String               // RouteID raw value or "test"
    public var appBuild: String
    public var startedAt: Date
    public var phase: Phase                // running / background
}
```

`SessionSentinel` generalizes 01's `ProbeSentinel`:
- `arm(_:)` writes the record atomically and fsyncs both the file and its directory.
- `setPhase(_:)` updates the phase.
- `disarm()` removes the sentinel, the breadcrumbs and the fault file.
- `consumeAtLaunch() -> ConsumedSession?` returns the record together with a snapshot of the breadcrumbs and any fault record. It always removes the files afterwards.

### 10.2 Breadcrumbs

- **Storage:** `breadcrumbs.bin` holds 64 fixed-size slots. A slot is `(seq: UInt64, time: Int64, event: UInt16, a: Int64, b: Int64)`.
- **Writing:** each append does a `pwrite` at slot `seq % 64` through a descriptor opened in advance, via a C helper in `CEikonSession`. That helper is async-signal-safe, so a later fault path can use it too. There is no fsync per append.
- **Reading:** sorted by `seq`.
- **Events:** only the closed Swift enum `BreadcrumbEvent`, whose raw values are stable and which later splits extend. The initial set:
  - `sessionStart`, `sessionPaused`, `sessionBackgrounded`, `sessionResumed`, `sessionStop`
  - `memoryWarning`, `memorySample(availableMB)`
  - `audioInterrupted`
  - `renderGateTimeout`
  - `runtimeError(code)`

### 10.3 Fault hook (`CEikonSession`)

- `eikon_session_fault_open(path, session_id_bytes)` opens `fault.bin` in advance and writes a header that carries the session id.
- `eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address)` does one `write(2)` of a fixed-size record, which is async-signal-safe.
- **02 installs no signal handler.** Runtimes in splits 05 and 06 call the hook from their own fault paths for faults they really do not handle.
- **Reading:** `FaultRecord` reads the file back, and accepts it only when the header's session id matches the sentinel's.

### 10.4 Next-launch classification (`SessionOutcome`)

| Evidence | Outcome | Banner |
|---|---|---|
| Phase `running` + a matching fault record | `crashed(signal, pc)` | yes |
| Phase `running` + a `memoryWarning` within 60 s of the last breadcrumb, or a last `memorySample` under 100 MB | `likelyMemoryKill` | yes |
| Phase `running`, nothing else | `endedUnexpectedly` (crash or system kill) | yes |
| Phase `background` | `killedInBackground` | no (history only) |

### 10.5 Consumers (`CrashReportController`, `CrashHistory`)

At launch, after `gatherFacts`, the consumed session is **snapshotted into `CrashHistory`** together with its breadcrumbs and fault record. History keeps the last 5 per game id, so a report can be filed later from the game's detail screen and not only from the banner.

**Banner.** For outcomes that warrant one, the banner shows:
- the outcome in words
- the game's display name (on screen only)
- the route and the time

**Banner actions:**
- *Try <route> next time.* Shown only when the picker has another **runnable** candidate for that game. It sets `route.override`. It is omitted for `test` records and for games that no longer exist.
- *Report on GitHub.*
- *Dismiss.*

**Issue URL.** `CrashIssue.url(repository:entry:device:reportID:)` in EikonCore is a pure function.
- It builds `<repo>/issues/new?template=crash.yml&labels=crash&title=<outcome, engine, route>&<field>=<value>…`.
- **Query values are percent-encoded explicitly**, including `+`, `&` and `=`.
- Fields:
  - `outcome`, `engine`, `arch`, `route`
  - `game` (the report id: the first 8 characters of the random game id)
  - `app` (version, build, commit)
  - `device` (model identifier, OS version and build)
  - `install` (install method)
  - `jit` (usable, source, reason code)
  - `fault` (signal and pc, when present)
  - `breadcrumbs` (the last 20, as lines of codes and integers)
- **No file hashes and no fingerprints.** `CrashIssue` takes no display name, folder name or fingerprint as input. It takes only the report id.

**Length limit.** If the URL would exceed 7,500 characters, breadcrumbs are dropped oldest-first until it fits. The full `DeviceReport` JSON (01's format, now with gates) goes to the clipboard, and the banner tells the user to paste it.

The URL opens with `UIApplication.open`, and the user reviews the issue in Safari before submitting.

### 10.6 `.github/ISSUE_TEMPLATE/crash.yml`

- **Form:** an issue form with `name: Crash report` and `labels: [crash]`.
- **Fields:** input or textarea fields whose `id`s match the fields above, plus one free-text "What were you doing?" field.
- **Description:** repeats the rule: no game titles.
- **Before first use:** the `crash` label must exist in `getBoolean/eikon` (a checklist item for the owner). Prefill from query parameters is verified once against the real repo.

## 11. Gate store (EikonKit/Gates)

`GateStore` is lock-guarded and file-backed (`gates.json`, following the §6.2 rules).

- **`record(_ name: GateName, _ result: GateResult)`** stores the result together with the current app build and OS build.
- **`states() -> [GateName: GateState]`** reports each gate as follows:

  | Stored result | Recorded under current app + OS build | State |
  |---|---|---|
  | Passed | yes | `passed` |
  | Passed | no | `unmeasured` |
  | Failed | yes | `failed(stale: false)` |
  | Failed | no | `failed(stale: true)`, until re-measured |
  | Unmeasured, or no result | either | `unmeasured` |

- **`current() -> [String: GateResult]`** returns the results that are still valid, for `DeviceReport.make`. Stale failures are included, with their original `measuredAt`.

The schema already allows any gate key. Nothing writes gates in 02. The developer section lists what the store holds.

## 12. Screens (App target)

### 12.1 Root

`RootView` is a `NavigationView` in column style.
- **Sidebar:** Library, Game drives, This device, Credits. On iPhone it collapses to a stack.
- **Launch screen:** the app opens on Library.
- **Crash banner:** when there is one, it sits at the top of Library.

`EikonApp.init` sets things up in this order:
1. `JITController.shared.gatherFacts()`.
2. Register runtimes (none in 02).
3. Create `SettingsController`, `GateStore`, `LibraryController` and `CrashReportController`. `CrashReportController` consumes the sentinel.
4. Clean stale `.eikon-importing-*` folders on the drives that are available.
5. Start the scans.

On `.active`, the app calls `jit.sceneBecameActive()`, re-evaluates drive states and rescans. On `.background`, it flushes settings.

### 12.2 Library

- **Toolbar:** **+ Import game**.
- **Empty state:** explains that games live in game drives. It covers:
  - the built-in "On My iPad/Eikon" folder in Files
  - adding a USB folder under Game drives
  - the Import button, which copies a game into a drive
- **Row (`LibraryRow`):**
  - the display name
  - engine and architecture
  - a route badge: chosen, planned, warning or override style, or "Unavailable"
  - a drive indicator when the game is only on a USB drive
  - a status line, one of:
    - Identifying…
    - Waiting for copy to finish
    - "Same game as …?" (non-blocking suggestion)
    - Drive not connected
    - Missing
    - Hashing failed
- **"Not recognized" section:** drive folders where no game was found, with the hint "Games must sit directly inside a game drive (one wrapper folder is fine)".

### 12.3 Game detail

- **Suggestion card (`IdentitySuggestion`),** when there is one. It reads *"This might be the same game as <display name> (a different version). Use one entry?"*, with **Merge** and **Keep separate**. The game is fully usable without answering.
- **Header:**
  - editable display name
  - engine details: Unity scripting, Ren'Py version with exact or era, Kirikiri flavor, plugin names, GameMaker build type
  - architecture per platform
  - locations: drive label, reachable or not, and missing
- **Route section:**
  - the chosen route and its reasons as sentences
  - every candidate with its verdict and reasons
  - an **Override** picker offering *Automatic* and every route. Unrunnable routes are selectable, with their reasons shown inline.
- **Launch button:**
  - Enabled when the location has a game id, is reachable, and the chosen route is built.
  - A forced route that can't run asks "Launch anyway?" and lists the reasons.
  - A planned route disables the button, with the caption "Not in this build yet".
- **Crash history:** the last 5 entries, each with outcome, route and date, and a *Report on GitHub* action.
- **Identity (collapsed):**
  - report id (the short game id)
  - how many fingerprints (versions) are known
  - **Same game as…** (merge into another game) and **This is a different game** (split this location off)
  - **Verify files** (full SHA-256 of the key file, for diagnostics)
- **Remove**, which opens `RemoveGameDialog`.

### 12.4 Game drives (`DrivesView`)

- **Built-in drive:** "On My iPad/Eikon" (or "On My iPhone/Eikon"), with free space and game count, and a note that it is visible in the Files app.
- **Other drives:** each with its label, state (available, not connected, needs relink), free space and game count, and the actions *Find folder…* and *Remove drive (files are not touched)*.
- **Add game drive…:** a folder picker. It refuses iCloud and network locations and says why.

### 12.5 This device

`StatusView` keeps its existing rows and gains:
- **Routes:** one row per route, showing its state here: available, needs JIT (with 01's reason), gate failed (stale marked), gate unmeasured, or not in this build. Each row has a caption listing the engines the route serves. Rows are computed from a synthetic detection per route.
- **Gates:** `x18` and `guestWindow`, each shown as passed, failed, stale or not measured, with its detail and date.
- **Developer (collapsed):**
  - Run test session
  - Simulate crash during session
  - gate store contents
  - replica id
  - a settings-fork warning, if the store forked (§7.1)

The existing pure presentation struct (`StatusContent`) is extended, so previews still render every state.

### 12.6 Credits

`CreditsView` loads the bundled `Acknowledgements.json` through `Acknowledgements.load(bundle:)`.
- **List:** the entry with `isApp: true` (Eikon) comes first, then each component with its name, SPDX license and revision.
- **Detail:** a scrollable, selectable license text plus the URL.
- **No third-party entries:** a caption says "Eikon includes no third-party components yet".
- **Missing or malformed JSON:** an error row, never a crash.

### 12.7 Strings

- **Move:** `App/Localizable.strings` moves to `App/en.lproj/Localizable.strings`, and its header is updated.
- **Plurals:** add `Localizable.stringsdict` for plural forms: games, files, bytes and drives.
- **Key namespaces:** `library.*`, `drives.*`, `import.*`, `identity.*`, `game.*`, `route.id.*`, `route.reason.*`, `route.verdict.*`, `route.decline.*`, `gate.*`, `engine.*`, `arch.*`, `crash.*`, `credits.*`, `developer.*`.
- **Mapping:** every enum→key mapping is an exhaustive switch in `App/Strings/`.
- **Previews:** DEBUG previews render every `RouteReason`, `RouteVerdict`, `SessionOutcome` and identity prompt, so a missing key shows up as a raw key.

## 13. Info.plist and entitlements

- **`App/Info.plist`:** add `UIFileSharingEnabled = YES` and `LSSupportsOpeningDocumentsInPlace = YES`. With both set, Files shows `Documents/` as "On My iPad/Eikon". Also add `EKRepositoryURL`.
- **Entitlements:** no changes.
- **Deb container:** the Dopamine deb has its own container through `container-required`. 01's device report already records the redacted home directory, which confirms it on the device.

## 14. Reason text rules

Reasons are short sentences a non-expert can act on. For example:
- `needsJIT`: "Needs JIT, which this install doesn't have: <01's JIT reason sentence>."
- `box64Only32Bit`: "Without JIT, only 32-bit Windows games can run."
- `fexPreferredWithJIT`: "Slower than Wine with FEX; used if that route can't run."
- `gateUnmeasured(.x18)`: "Not yet verified on this device (x18 check). It may not work."
- `gateFailed(stale: true)`: "Failed on this device before an update. Not re-checked yet."
- `notInThisBuild`: "Planned. Not in this build yet."

The detail screen shows every reason. The library row shows the verdict only.

## 15. Credits pipeline change

`scripts/credits.py app-json` prepends Eikon's own entry and adds an `isApp` flag to every entry. The Eikon entry has these fields:
- `name`: `Eikon`
- `url`: the repository URL
- `revision`: `getBoolean/eikon <VERSION>`
- `license`: `GPL-3.0-or-later`
- `licenseText`: read from `licenses/GPL-3.0-or-later.txt`
- `isApp`: `true`

Every other entry gets `isApp: false`. The generator is the only place this entry is defined.

`tests/test_credits.py`:
- Existing expectations that the app JSON is empty with no components change to "only the app entry".
- One behavioral test is added: the app entry carries the license text and is marked as the app.

## 16. Collection scanner

### 16.1 `eikon-scan`

```
eikon-scan [--root PATH] [--per-folder] [--hash]
```

- **Missing root:** the root defaults to `/Volumes/Games`. If it is absent, the scanner prints `skipped: <root> not mounted` and exits 0.
- **What it scans:** the root is treated like a game drive. Each immediate subfolder is scanned by `GameDetector.detect`, which includes the one-wrapper rule.
- **Read-only:** the scanner only opens files for reading. It never creates, modifies or sets attributes on anything under the root.
- **Output** is aggregate and title-free:
  - total folders
  - counts by engine
  - Unity: IL2CPP vs Mono, and how many were recognized via `UnityPlayer.dll`
  - Kirikiri: how many have `.tpm`, krkr2 vs Z, index readable, protected-flag seen
  - Ren'Py versions (exact or era)
  - GameMaker: YYC vs VM
  - "no game found"
  - main-executable architecture counts, overall and for files named `Game.exe`
  - plugin base names with occurrence counts
  - Ren'Py native-extension base names with counts
  - hit counts for each exclusion rule
- **Identity statistics:**
  - how many games have an engine-declared id, per engine
  - how many declared ids hit the generic blocklist
  - how many folders share an exact fingerprint or an engine id with another folder (collision risk)
- **`--per-folder`:** one line per folder, sorted by the exact fingerprint: the short exact fingerprint (under the fixed scanner secret) and the engine. Names are never printed.
- **`--hash`:** adds the full SHA-256 of the key file to each per-folder line. Progress goes to stderr, because hashing over SMB is slow.
- **Structure:** the summary logic is the pure `CollectionSummary`. The executable's top level stays synchronous, so detection runs synchronously and avoids friction with MainActor isolation.

### 16.2 Make target

`make scan-collection` runs `swift run --package-path Packages/EikonCore -c release eikon-scan --per-folder $(ARGS)`. Nothing is written into the repo.

### 16.3 Checking against requirements

- **Manual check.** On the dev Mac, run `make scan-collection` and compare the output with the "Games to support" table in `planning/requirements.md`:
  - Unity 29, of which 4 are IL2CPP
  - Kirikiri 21, of which 3 have `.tpm`
  - Ren'Py 4
  - GameMaker 3
  - BGI 2
  - `Game.exe`: 11 i386, 5 amd64
- **Resolving mismatches.** Fix detection, or correct the table where its counting method differed. For example, the table counts Unity by `UnityPlayer.dll`, and the scanner reports both numbers.
- **No counts in tests.** The expected numbers live only in `requirements.md`.
- **Optional automated check.** `tests/test_collection_scan.py` runs only when `/Volumes/Games` is mounted **and** `EIKON_SCAN_COLLECTION=1`. It runs the scanner and compares its engine counts with the counts it parses from the requirements table at run time.

## 17. Testing strategy

Tests are few, behavioral, and use original synthesized content.

### EikonCoreTests

Run with `swift test` on the Mac, and on the simulator through the scheme.

- **Fixtures.** `Fixtures.swift` builds minimal fake game folders, one per engine and variant. Names are generic (`Game.exe`, `Sample_Data`).
  - PE headers with a chosen machine type, including an `e_lfanew` beyond 4 KiB
  - a version resource
  - XP3 files with a raw or zlib index, and one with the protected bit
  - `FORM`/`GEN8` files with and without `CODE`
  - Ren'Py layouts for each era
  - Unity Mono, IL2CPP, and pre-2017 layouts
  - BGI `.arc` magics
  - ELF headers
  - folders that carry both Windows and Linux executables
  - mixed-case filenames
  - a single-wrapper folder
- **Detection.**
  - Each engine and variant is detected with the right architecture per platform, details and key file.
  - A single wrapper folder is accepted. A wrapper holding two games is not.
  - Case-insensitive markers are found.
  - Excluded executables are never chosen.
  - A folder with only a PE file yields `unknown` with its architecture.
  - An empty folder yields `nil`.
  - A future enum value in a stored `DetectionResult` decodes to the fallback.
- **Identity.**
  - Renaming a game folder doesn't change its fingerprint.
  - Changing a file's size, or the key file's head or tail, changes the exact signal but not the engine id.
  - Declared ids are read for Ren'Py, Unity (`app.info`), GameMaker and exe version info. Generic values are ignored.
  - Fingerprints contain no plain name or engine-id text, and two secrets give different values.
  - Matcher (table-driven, over each rule of §5.4):
    - a known location keeps its id after its contents change entirely (**an in-place patch**)
    - exact match attaches (rename, move, second drive)
    - an engine-id match attaches when the game has no live location here
    - an engine-id match suggests (never merges) when the game is live elsewhere
    - name similarity attaches when there is no engine id
    - multiple candidates create a new game plus a suggestion
    - no match creates a new game
  - Merge links resolve, and cycles break deterministically.
  - A split gives a new id and keeps the settings as a fork.
  - `FileHasher` reports monotone progress and honours cancellation.
- **Route picker** (table-driven).
  - Native routes come first for Kirikiri and Ren'Py.
  - With JIT, PE i386 or amd64 goes to wine-fex.
  - Without JIT, i386 goes to wine-box64, and amd64 is unavailable with `needsJIT`.
  - With JIT, when wine-fex is gated out or planned, wine-box64 is chosen for i386.
  - An unmeasured gate gives warnings. A failed gate, stale or fresh, makes the route unavailable.
  - When nothing runs, a planned route is chosen.
  - A declined runtime falls through to the next route.
  - An override is honoured with warnings.
  - A Unity folder with both Windows amd64 and Linux amd64 executables gets both Wine and Linux candidates.
- **Settings.**
  - Merge is commutative, associative and idempotent. This is checked with a seeded random operation loop.
  - A newer reset beats an older set.
  - Unknown keys round-trip.
  - The clock never goes backwards.
  - A replica file in a future format is never rewritten, and this replica's own future-format file causes a fork.
  - `deletedAt` hides older keys, including keys this replica never wrote, but not newer keys.
- **Sessions.**
  - An arm, consume round trip produces each outcome in §10.4.
  - Breadcrumbs stay bounded and ordered.
  - A fault record from another session is ignored.
  - The issue URL contains only its inputs, percent-encodes reserved characters, stays under the length limit by dropping breadcrumbs, and parses back to the given fields.
- **Scanner.** The summary over a synthesized collection counts engines, plugins, architectures and exclusions correctly, and its output contains none of the synthesized folder names.
- **Persisted files.** A file with a newer `format` is not rewritten. A bad element is preserved as raw data across a save.

### EikonKitTests (simulator)

- **Gate store.** A passed result expires under another build. A failed result becomes stale instead of disappearing.
- **Library,** with a fake `FolderAccess` and temp-directory drives:
  - Import copies into the chosen drive through a hidden staging folder, and the scanner never creates a duplicate location.
  - A name clash offers replace or rename.
  - A drive that is not connected makes its games unreachable.
  - Relinking to a folder with none of the known games asks for confirmation.
  - A folder that is still changing isn't fingerprinted until it is quiescent.
  - Overwriting a game's files in place (a simulated patch: resized key file, new files) keeps its game id and settings, and adds a fingerprint.
  - *Replace existing copy* through Import keeps the game id.
  - Renaming a game's folder keeps its game id.
  - Moving it to another drive keeps its game id.
  - A second, different version of a present game appears as a new game with a suggestion. Merging it moves its location under the first game.
- **Session host,** with a fake runtime and fake `SceneEvents`:
  - Deactivation closes the gate and pauses the runtime.
  - Background happens only after the gate is closed.
  - Activation waits for the overlay's resume.
  - Stop disarms the sentinel.
  - `RenderGate.close` waits for an in-flight frame to leave, and returns false after its timeout.
- **Credits.** `Acknowledgements.load` decodes the generated format, including the app entry.

### Python

- `test_credits.py` is updated as described in §15.
- `test_collection_scan.py` is opt-in, as described in §16.3.

### Device checks

These are manual. Record the results in a device report's notes, by engine and hash only.

- Import copies from Files "On My iPad" (a fast clone) into the built-in drive.
- Import copies from a USB-C drive, with working progress and cancel.
- A folder on a USB-C drive is added as a game drive and its games appear. When the drive is unplugged they show "Drive not connected". When it is replugged they are available again.
- A folder dropped into "On My iPad/Eikon" through Files appears on return to the app, after the quiescence delay.
- The same folder name on the built-in drive and on the USB drive, with different contents, triggers the same-or-different prompt.
- Test session:
  - Pulling down Control Center pauses it.
  - Going Home backgrounds it. After 30 s in the background, returning shows "Tap to resume", and the command-buffer error count is 0.
- Simulated crash: the relaunch shows the banner. *Report on GitHub* opens a prefilled issue containing only codes and the report id.

## 18. Implementation order

1. EikonCore package skeleton and build/test wiring (Package.swift, project.yml, Makefile `test-core`, CI). Includes the C target with the atomics and slot writer.
2. Folder listing and reader, binary parsing, engine detection, with fixtures and tests.
3. Identity: normalization, key files, engine-declared ids, fingerprints, matcher, merge/split, diagnostics hasher.
4. The collection scanner (`CollectionSummary`, CLI, make target). **Run it against the mount now** to validate detection on real data before any UI is built on it.
5. Persisted-file rules, the settings CRDT and the settings store.
6. Route types, rules and the picker.
7. Sessions: sentinel, breadcrumbs, fault hook, outcome, history, issue URL, and `crash.yml`.
8. EikonKit: the gate store and the `DeviceReport.make` gates parameter.
9. EikonKit: library (folder access, drives, scanner with fingerprinting, import, `LibraryController`).
10. EikonKit: runtime protocol, registry, render gate, scene events, session host, `GameSession`, cleanup hooks.
11. The crash report controller.
12. The strings move to `en.lproj`, plus the new keys.
13. App: root navigation, library, game detail (with suggestions and merge/split), import flow, drives, the remove dialog and the banner.
14. App: This device extensions (routes, gates, developer section, test-pattern runtime).
15. Credits: `credits.py` and the screen.
16. `requirements.md` decision update, device checks, and a device report.

## 19. Risks and open points

- **External drives:**
  - Bookmarks to exFAT and FAT volumes may fail to resolve after a reconnect. Re-link covers this, but it needs confirming on the owner's drive.
  - Unplugging a drive during a game can crash the app. This is accepted, and the sentinel reports it.
- **Local folders chosen as game drives** could sit inside a third-party file provider's local storage. iCloud (`isUbiquitousItem`) and network volumes are refused. Other providers can't be detected reliably, so the add-drive screen says games on cloud-synced folders may be evicted.
- **`NavigationView` column style on iOS 15 iPad has quirks** (the sidebar hides in portrait, and selection can reset). A later move to `NavigationSplitView` behind `#available(iOS 16)` is possible.
- **Kirikiri executables with an embedded XP3 and no `.xp3` files** would be missed. Step 4's scan shows whether any exist.
- **BGI key file = main exe,** which may be shared across games on one engine version. A false match shows up only as an attach *offer*, so the harm is contained.
- **Issue-form prefill** relies on GitHub accepting query parameters named after issue-form field ids. Verify it once on the real repo, and fall back to the clipboard report if a field doesn't prefill.
- **Display names sync to the user's own WebDAV server in split 12.** That fits the privacy rule, because names never become paths. Split 12 must keep names out of remote paths and logs.
- **MetricKit crash diagnostics** could enrich outcomes, but they probably aren't delivered to sideloaded, TrollStore or jailbreak installs. This is a follow-up only.
