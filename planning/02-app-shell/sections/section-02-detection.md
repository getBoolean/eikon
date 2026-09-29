# Section 02: Detection (engine, architecture, main executable)

## Background

Eikon is an iPhone and iPad app. It will run Windows and Linux x86 games through Wine, FEX-Emu and Box64, and Kirikiri and Ren'Py games natively, all inside the app process. Split 02 ("app shell") builds the library, identity, route picker, session host and so on. This section builds the **detection layer** that everything else rests on. Given a game folder, it works out:
- which engine the game uses: Unity, Kirikiri, Ren'Py, GameMaker, BGI, or unknown
- engine-specific details, such as the Unity scripting backend, Kirikiri plugins and XP3 index state, the Ren'Py version and native extensions, and the GameMaker build type
- the main executable for each platform (Windows PE, Linux ELF) and its CPU architecture

Detection runs in two places:
- inside the app, from the library scanner and the import flow (later sections)
- on the dev Mac, from the `eikon-scan` collection scanner (section 04), against a read-only SMB share

This is why the code lives in the platform-neutral package `Packages/EikonCore`, which must build for both iOS 15 and macOS 13 with no UIKit.

### Dependencies

- **Requires section-01-core-package.** That section creates `Packages/EikonCore` with these properties:
  - tools 6.0, platforms iOS 15 and macOS 13, Swift 6 language mode
  - targets `CEikonSession` (C), `EikonCore`, `eikon-scan` and `EikonCoreTests`
  - system `libz` linked via `linkerSettings: [.linkedLibrary("z")]`
  - the `make test-core` target (`swift test --package-path Packages/EikonCore`)
- **Blocks:**
  - section-03-identity: fills `DetectionResult.keyFile`, reads engine-declared ids, and reuses `FolderListing`, `FolderReader` and `PEVersionResource`
  - section-04-collection-scanner: consumes `GameDetector`, `FolderListing` and the exclusion tally
  - section-06-route-picker: consumes `Engine`, `CPUArchitecture`, `GamePlatform` and `DetectionResult`
  - section-09-library-drives: caches `DetectionResult` in `GameLocation` and re-detects on `detectorVersion` change

### Hard constraints that apply here

- **No program titles anywhere.** That covers the repo, logs, tests, thrown errors, and anything detection returns for aggregate output.
  - Folder names are titles in practice. They may appear in `DetectionResult.gameRoot` (the wrapper name) and in executable paths, because those stay on the device.
  - Detection code must **never log**.
  - Errors must carry **codes only**, never paths or names.
  - Plugin and extension lists hold **base names only**.
- **Test content is original.** Tests synthesize tiny fake folders in temp directories, with generic names (`Game.exe`, `Sample_Data`, `data.xp3`). Nothing comes from a real collection.
- **Read-only.** Detection never creates, writes, renames or sets attributes on anything. It opens files read-only and never follows symlinks out of the folder.
- **Swift 6 complete concurrency checking.** No global mutable state: counters are passed explicitly, not stored in statics.
- **01's style:**
  - small, single-concept files
  - pure logic in caseless enums
  - exhaustive switches with no `default:`
  - `Sendable` value types
- **Tests are few and behavioral.** They don't assert constants such as `detectorVersion`, exact strings, or internal structure.

## Files

All paths are under `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonCore/`.

```
Sources/EikonCore/Detection/
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
Tests/EikonCoreTests/
  Fixtures.swift              # synthesizer for original fake game folders
  DetectionTests.swift
```

**zlib access.** Expose zlib to Swift by adding `#include <zlib.h>` to `Sources/CEikonSession/include/CEikonSession.h`, which section 01 creates. `EikonCore` already depends on `CEikonSession` and links `libz`, so `uncompress` and `inflate*` become callable from Swift. Use system zlib, not Apple's Compression framework, because Compression does not handle the zlib header. The test target uses the same header (`compress`) to build zlib fixtures.

## Tests first

Write these in `Tests/EikonCoreTests/DetectionTests.swift` with Swift Testing:
- `import Testing`
- free `@Test func` with behavior-named functions
- `#expect` / `#require`
- `@Test(arguments:)` for parameterized cases

Every test builds its folder in a fresh temp directory through `Fixtures`. Expected values come from how the fixture was built (for example, "the fixture's exe was built with machine amd64, so expect `.amd64`"). They are never typed-in magic.

### Types and entry point
- An empty folder detects as no game (`nil`).
- A folder containing only a PE exe detects as `.unknown`, with that exe's architecture under the `.windows` platform.
- A folder whose only child is a wrapper folder holding one game detects that game, and reports the wrapper as `gameRoot`.
- A wrapper holding **two** games is not accepted: the result is `nil`, or at least not either inner game.
- A stored `DetectionResult` JSON with an unknown engine or architecture value decodes to the fallback values instead of failing. Build the JSON by encoding a real result and substituting unknown raw strings.
- Detection returns the same result regardless of directory listing order. Build the same layout in two temp dirs, creating the files in opposite orders, and compare the results.

### FolderListing / FolderReader
- Markers whose letter case differs from the canonical name are found, for example `unityplayer.DLL` and `DATA.XP3`.
- `<stem>.exe` pairs with `<stem>_Data` when the two stems differ only in Unicode normalization form. Write one name in NFC and the other in NFD, for example a stem containing "é".
- A zlib-compressed XP3 index decodes, so `xp3IndexReadable == true`.

### Per-engine rules (parameterized over fixtures)
- **Ren'Py**
  - Each era layout reports Ren'Py with the matching version kind:
    - exact, from `game/script_version.txt`
    - exact, from `renpy/vc_version.py`
    - exact, from `renpy/__init__.py`
    - era, from `lib/` names
  - Native modules under `game/`, including `game/python-packages/`, are listed by base name. Engine files under `lib/` are not listed.
  - The Windows executable is the `<stem>.exe` next to `<stem>.py`. The Linux executable is the ELF under `lib/py3-linux-x86_64/`, not the `.sh`.
- **Unity**
  - Mono and IL2CPP layouts are told apart.
  - A pre-2017 layout (with `<stem>_Data/mainData` but no `UnityPlayer.dll`) is recognized.
  - The main exe is the one with a `_Data` sibling. `UnityCrashHandler64.exe` is never chosen, even when it is larger or GUI.
- **Kirikiri**
  - `.tpm` base names are reported.
  - A krkr2 or krkrZ version resource sets the flavor accordingly.
  - An index entry with the protected bit set sets `xp3ProtectedFlag`.
  - A garbage index gives `xp3IndexReadable == false`, and the game is still Kirikiri.
- **GameMaker**
  - A file with a `CODE` chunk is VM, and one without is YYC.
  - A file with `FORM` but no `GEN8` is not GameMaker.
- **BGI**
  - `BGI.exe` is recognized.
  - Two `.arc` files with either magic are recognized.
  - `.arc` files without the magic are not.
- **PE**
  - Each machine value maps to the right architecture (parameterized: i386, amd64, the three arm64 variants, and one other).
  - An `e_lfanew` beyond 4 KiB still parses.
  - A DLL is never an executable.
- **ELF**
  - x86-64 and aarch64 map correctly.
  - A `.sh` script is not an ELF.
- **Multi-platform**
  - A Unity folder with a Windows amd64 exe and a Linux `x86_64` binary reports both platforms.

### Main executable selection
- Installer, uninstaller and redistributable executables are never chosen when a real candidate exists, even if they are larger.
- Among the remaining candidates, a GUI-subsystem exe beats a larger console exe.
- The rule "each exclusion rule's hit count reflects the files it removed" is tested in section 04's `ScannerTests`, through the `CollectionSummary` API. This section must expose the tally publicly (see below) so that test can be written. Do not write a test against internal counters here.

## Fixtures (`Tests/EikonCoreTests/Fixtures.swift`)

This is a caseless `enum Fixtures` of static helpers. It produces minimal, **original** byte structures and layouts. Sections 03 and 04 extend it, so keep the helpers composable (byte builders plus layout builders), for example:

```swift
enum Fixtures {
    static func tempDir() throws -> URL                       // unique dir under FileManager.temporaryDirectory
    static func write(_ data: Data, to rel: String, in dir: URL) throws
    // Byte builders
    static func pe(machine: UInt16, gui: Bool = true, dll: Bool = false,
                   lfanew: Int = 0x80, versionStrings: [String: String] = [:],
                   padTo size: Int? = nil) -> Data
    static func elf(machine: UInt16) -> Data
    enum XP3Index { case raw, zlib, garbage }
    static func xp3(index: XP3Index, protectedEntry: Bool = false) -> Data
    static func gameMaker(hasGEN8: Bool = true, hasCode: Bool) -> Data
    static func bgiArc(magic: String) -> Data                 // "PackFile    " / "BURIKO ARC20" / other
    // Layout builders (each returns the folder URL it built)
    enum RenPyEra { case scriptVersion, vcVersion, initPy, libEra }
    static func renpy(_ era: RenPyEra, in dir: URL) throws -> URL
    enum UnityLayout { case mono, il2cpp, pre2017 }
    static func unity(_ layout: UnityLayout, linux: Bool = false, in dir: URL) throws -> URL
    static func kirikiri(flavor: String?, tpm: [String] = [], index: XP3Index = .raw,
                         protectedEntry: Bool = false, in dir: URL) throws -> URL
}
```

What the fixtures must be able to produce:
- PE headers with a chosen machine, subsystem and DLL flag, including an `e_lfanew` beyond 4 KiB
- a minimal `.rsrc` holding a `VS_VERSIONINFO` with chosen string values
- XP3 files with a raw, zlib or garbage index, with or without the protected bit on an entry, and optionally the v2 continuation header
- `FORM`/`GEN8` files with and without `CODE`
- Ren'Py layouts for each era
- Unity Mono, IL2CPP and pre-2017 layouts, optionally with a Linux binary
- BGI `.arc` magics
- ELF headers
- mixed-case file names
- a single-wrapper folder
- a wrapper with two games

File contents beyond the magic and headers can be a few padding bytes.

## Implementation

### Types (`Engine.swift`, `DetectionResult.swift`, `BinaryInfo.swift`)

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

**Sub-enums**, all in `Engine.swift`:
- `UnityScripting { mono, il2cpp }`
- `KirikiriFlavor { krkr2, krkrZ, unknown }`
- `GameMakerBuild { vm, yyc }`
- `RenPyVersion`: a struct with `major: Int`, `minor: Int`, `patch: Int?` and `kind: RenPyVersionKind { exact, era }`.
  - For an era, it also carries an upper bound (`maxMajor`/`maxMinor`, optional) so it can express "≤7.3", "7.4+", "8.0–8.3" and "8.4+".
  - The UI and the scanner format it. Detection never produces strings for display.

**Decoding fallbacks.** Future values must decode safely: a value written by a newer or older build must never fail a whole file. Give every enum a custom `init(from:)` that reads the raw string:
- `Engine`: an unknown value becomes `.unknown`.
- `CPUArchitecture`: an unknown value becomes `.other`.
- Optional detail enums (`UnityScripting?`, `GameMakerBuild?`, `RenPyVersionKind`): an unknown value becomes `nil`. `KirikiriFlavor` falls back to `.unknown`.
- `executables` entries with an unknown `GamePlatform` or `BinaryFormat` are **dropped** rather than failing the result.

**`executables` needs custom `Codable`.** A Swift `Dictionary` keyed by a non-`String` enum encodes as a flat array, and `CodingKeyRepresentable` needs iOS 15.4 while the minimum is iOS 15.0. So encode `executables` as a JSON object keyed by `GamePlatform.rawValue` (`[String: ExecutableInfo]`), and on decode skip keys that don't map to a known platform.

**Other type rules:**
- `EngineDetails` array fields default to `[]` when absent on decode, so older or partial files load.
- `detectorVersion` is `GameDetector.version`, a public static constant. Bump it whenever detection logic changes. A stored result with an older version is treated as a stale cache and recomputed (section 09 does the recomputing; this section only provides the constant).
- `keyFile` is declared here and left `nil` by this section. Section 03 adds the per-engine `KeyFile` selection and sets this field from `GameDetector.detect`.

### Entry point (`GameDetector.swift`)

```swift
public enum GameDetector {
    public static let version: Int
    /// Detects the game in a game folder (an immediate child of a game drive). Checks the
    /// folder itself; if no engine markers or executable are there and the folder holds
    /// exactly one subfolder that does, that subfolder is the game root. Read-only.
    public static func detect(folder: URL) throws -> DetectionResult?   // nil = no game found
    /// Same, also adding exclusion-rule hits to `tally` (used by the collection scanner).
    public static func detect(folder: URL, tally: inout ExclusionTally) throws -> DetectionResult?
}
```

**Game root:**
1. Evaluate the folder itself. It "has a game signal" if any engine detector recognizes it **or** main-executable selection yields at least one executable.
2. If it has none, list its non-hidden subfolders (names not starting with `.`). If there is **exactly one**, evaluate that subfolder the same way. If it has a signal, it is the game root, and `gameRoot` = that subfolder's name as listed. Loose files beside it are allowed.
3. Only one wrapper level is followed. Two or more subfolders means no wrapper. That makes a wrapper holding two games return `nil`.

**Detector order:** Ren'Py, Unity, Kirikiri, GameMaker, BGI.
- The first match wins. The order goes from the most specific layout to the least, so a Ren'Py or Unity game that ships an `.xp3` or `.arc` is not misread.
- If no engine matches but a main executable exists, return `engine: .unknown` with its executables. That still lets Wine or Linux be offered later.
- If there is neither, return `nil`. The UI shows "No game found here".

**Determinism.** Every directory walk visits entries in sorted normalized-name order, which `FolderListing` provides. Every "largest file" choice breaks ties by normalized name.

**Errors.** `detect` throws only when the folder itself can't be listed. Failures reading an individual file are treated as "this probe didn't match": a truncated or unreadable file, a budget exceeded, or a malformed header. Thrown error types carry an error code and no path.

### `FolderListing.swift`

This is a public value type describing one directory's immediate entries: name as listed, normalized key, kind (file / directory / symlink), and size. Section 04 uses it too.
- **Normalization:** NFC (`precomposedStringWithCanonicalMapping`) plus case-folding (`folding(options: [.caseInsensitive], locale: nil)`), and nothing else. Section 03's `NameNormalizer` adds trimming for display names. Keep this function reusable.
- **Lookups:**
  - `entry(named:)` does a case-insensitive, normalization-insensitive exact lookup.
  - `entries(withExtension:)` and `entries(matching:)` return results in sorted normalized order.
  - Directories can be looked up by name, and a child listing can be opened (`listing(of: entry)`).
- **Marker lookups** always go through a listing. Never call `fileExists(atPath:)` with a literal case. This matters on case-sensitive APFS externals, on exFAT, and on the SMB mount.
- **Stem pairing** (`<stem>.exe` with `<stem>_Data`, `<stem>.py`, `<stem>.x86_64`) compares normalized stems.
- **Symlinks** are recorded as `.symlink`. They are never opened, never descended, and never count as markers or candidates.
- **Hidden entries** (names starting with `.`) are kept in the listing but excluded from wrapper counting.

### `FolderReader.swift`

This is a read-only file reader with per-purpose budgets. It opens files read-only (`FileHandle(forReadingFrom:)`), seeks, reads bounded ranges, and closes them promptly. It never writes, never sets attributes, and never follows symlinks.

```swift
enum ReadPurpose { case binaryHeaders, versionResource, xp3Index, chunkHeaders, smallText }
struct FolderReader {
    init(root: URL)
    func read(_ relativePath: String, offset: UInt64, length: Int, for purpose: ReadPurpose) throws -> Data
    func size(of relativePath: String) -> UInt64?
    func text(_ relativePath: String) -> String?      // smallText budget, UTF-8 then Latin-1
    static func inflateZlib(_ data: Data, expectedSize: Int?, limit: Int) -> Data?   // via libz
}
```

**Budgets**, enforced per call and cumulatively per file per purpose. Exceeding a budget stops that probe (it throws internally and is treated as "no match").

| Purpose | Budget |
|---|---|
| PE / ELF headers | up to 64 KiB, following `e_lfanew` and section headers |
| PE version resource | seeks into `.rsrc`; reads ≤256 KiB |
| XP3 index | seek to the index offset; read ≤8 MiB compressed |
| GameMaker chunk walk | reads only the 8-byte chunk headers across the file |
| Small text files | ≤64 KiB (Ren'Py version files) |

**Early stop and inflate:**
- Each detection stops as soon as its question is answered.
- zlib inflate uses system libz: `uncompress` when the size is known, otherwise streaming `inflate`. Output is capped at a limit, so a hostile size can't exhaust memory. A decode failure returns `nil`.

### Binary parsing (`BinaryInfo.swift`)

`enum BinaryInfo` with `static func parse(_ reader: FolderReader, path: String) -> ParsedBinary?`. The result carries the format, architecture, raw machine, `isGUI`, `isDLL`, and the section table (for PE, used by `PEVersionResource`).

**PE:**
- The file starts with `MZ`. `e_lfanew` is a UInt32 LE at 0x3C.
- Sanity-check `e_lfanew`: 4-aligned, < 64 KiB, and < file size. Then require `PE\0\0` at that offset.
- COFF header fields:
  - Machine: UInt16 at +4
  - NumberOfSections: at +6
  - SizeOfOptionalHeader: at +20
  - Characteristics: at +22
- Machine mapping:
  - `0x014C` → i386
  - `0x8664` → amd64
  - `0xAA64`, `0xA641` and `0xA64E` → arm64
  - anything else → other
- Characteristics `0x2000` (DLL) means the file is **never** an executable.
- The subsystem is a UInt16 at optional header offset 68, the same for PE32 and PE32+. 2 (Windows GUI) → `isGUI = true`, anything else → `false`.
- Section headers (40 bytes each) follow the optional header. Keep their name, virtual address, raw size and raw pointer.

**ELF:**
- Magic `7F 45 4C 46`, then `EI_CLASS` at offset 4, then `e_machine` as a UInt16 LE at 0x12.
- Machine mapping: 62 → amd64, 3 → i386, 183 → arm64, anything else → other.
- A shell script (`#!`) is not an ELF.

### `PEVersionResource.swift`

This is a minimal reader that returns the `StringFileInfo` values (`[String: String]`, keys such as `ProductName`, `FileDescription`, `CompanyName`) from a PE's `.rsrc` section. Kirikiri flavor uses it here; section 03 uses it for engine-declared ids.
1. Find `.rsrc` in the section table.
2. Walk the resource directory: type 16 (`RT_VERSION`), the first name entry, then the first language entry, reaching the data entry. Convert its RVA to a file offset through the section.
3. Parse `VS_VERSIONINFO`, then `StringFileInfo`, then the first `StringTable`, then `String` children. Keys and values are UTF-16LE and null-terminated, and each child is 32-bit aligned.

All reads use the `versionResource` budget (≤256 KiB). Anything malformed returns an empty dictionary.

### Per-engine detectors

Each is a caseless enum with `static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch?`. An `EngineMatch` holds the engine, its details, and any engine-chosen executables per platform.

**Ren'Py (`RenPyDetector`)**
- *Recognition:* a `renpy/` dir and a `game/` dir, plus one of:
  - `renpy/__init__.py`, `.pyc` or `.pyo`
  - a `*.rpyc` or `*.rpa` file in `game/`
  - a `lib/` dir
- *Version*, first match wins:
  1. The `game/script_version.txt` tuple. It is exact.
  2. `version = "M.m.p…"` in `renpy/vc_version.py`. It is exact.
  3. `version_tuple = (M, m, p` in `renpy/__init__.py`. It is exact.
  4. The era, from `lib/` subfolder names:
     - bare `windows-*`/`linux-*` plus `pythonlib2.7` → ≤7.3
     - `py2-*` → 7.4+
     - `py3-*` plus `python3.9` → 8.0–8.3
     - `python3.12` → 8.4+
- *Native extensions:* base names of `*.pyd`, `*.so`, `*.dll` and `*.dylib` found anywhere under `game/`, including `game/python-packages/`. They are sorted and de-duplicated. Files under `lib/` are engine files and are never listed. Walk `game/` recursively in sorted order, never follow symlinks, and cap the depth and entry count so a huge tree stays bounded.
- *Executables:*
  - Windows: the root `.exe` whose stem has a sibling `<stem>.py`.
  - Linux: the ELF at `lib/py*-linux-x86_64/<stem>`, or the bare `lib/linux-x86_64/<stem>` in ≤7.3 layouts. This is never the `<stem>.sh` launcher.

**Unity (`UnityDetector`)**
- *Recognition:* `UnityPlayer.dll`/`UnityPlayer.so` in the root, **or** a `<stem>_Data/` directory containing `globalgamemanagers`, `mainData` or `data.unity3d`. The second form covers pre-2017 games that have no `UnityPlayer.dll`.
- *Scripting backend:*
  - IL2CPP if `GameAssembly.dll`/`.so` or `<stem>_Data/il2cpp_data/` exists.
  - Otherwise Mono if `<stem>_Data/Managed/Assembly-CSharp.dll` exists.
  - Otherwise `nil`.
- *Version* (best effort, display only):
  - From the big-endian SerializedFile header of `globalgamemanagers`: the format version is a UInt32 BE at 0x08. The version string is null-terminated at 0x14 for formats 9–21, and at 0x30 for 22 and later.
  - Otherwise from `data.unity3d`: after `UnityFS\0` and the 4-byte format number, it is the second null-terminated string.
  - Any failure gives `nil`.
- *Executables:*
  - Windows: the `.exe` whose stem has a sibling `<stem>_Data/`.
  - Linux: `<stem>.x86_64` with ELF magic.

**Kirikiri (`KirikiriDetector`)**
- *Recognition:* any root `*.xp3` whose first 11 bytes are `58 50 33 0D 0A 20 0A 1A 8B 67 01`.
- *Plugins:* base names of `*.tpm` in the root and one level of subfolders, plus `plugin/*.dll`. They are sorted and de-duplicated into `pluginFileNames`.
- *Flavor:*
  - Take it from the main exe's version resource `ProductName`/`FileDescription`: text identifying `TVP(KIRIKIRI) 2` means krkr2, and `TVP(KIRIKIRI) Z` means krkrZ.
  - If that fails, fall back to a bounded ASCII and UTF-16LE string scan of the exe within the version-resource budget.
  - Otherwise use `.unknown`.
- *Index:* read the index of `data.xp3`, or of the largest root `.xp3`.
  - The index offset is a UInt64 LE right after the 11-byte magic.
  - At the index offset, a flag byte selects the method: low bits 0 = raw (followed by a UInt64 size), 1 = zlib (followed by UInt64 compressed size and UInt64 decompressed size).
  - Kirikiri 2.3+ files begin with a **continuation header** (flag bit `0x80`) that points to the real index. Follow it once.
  - In the decoded index, walk the `File` chunks. For each `info` sub-chunk, the first UInt32 LE is the flags word.
  - Stay within the `xp3Index` budget.
  - Check these byte-level details against public XP3 format documentation when implementing. The fixtures must produce the same structure the reader consumes.
- *Detail fields:*
  - `xp3IndexReadable` records whether the index decoded and parsed.
  - `xp3ProtectedFlag` records whether any `info` entry has bit 31 set. That bit is Kirikiri's "extraction protected" flag, **not** an encryption marker.
  - 02 makes no encryption claim. That belongs to split 03's runtime check.
  - A garbage index still yields Kirikiri, with `xp3IndexReadable == false`.

**GameMaker (`GameMakerDetector`)**
- *Recognition:* `data.win` or `game.unx` with `FORM` at offset 0 and `GEN8` at offset 8.
- *Build type:*
  - Walk the chunk headers: a 4-byte tag plus a UInt32 LE size each, starting at offset 8 and reading only 8-byte headers.
  - An absent or zero-size `CODE` chunk means YYC. Otherwise it is VM.
  - Stop at the end of the file or at a size that overruns it.

**BGI (`BGIDetector`)**
- *Recognition:* either of these:
  - a root exe named `BGI.exe` (case-insensitive)
  - at least two root `*.arc` files whose first 12 bytes are `PackFile    ` (with four trailing spaces) or `BURIKO ARC20`

### Main executable selection (`MainExecutable.swift`)

1. **Candidates:**
   - Windows: `*.exe` files in the game root that parse as PE and are not DLLs.
   - Linux: root files carrying the ELF magic.
2. **Exclusions:** one static table of case-insensitive name patterns, matched against the normalized file name:
   - `unins*`
   - `UnityCrashHandler*`
   - `vc_redist*` and `vcredist*`
   - `dxsetup`
   - `dotnet*`
   - `ndp*`
   - `notification_helper`
   - `crashpad_handler`
   - `CrashReport*`
   - `*setup*`
   - `*install*`
   - `oalinst`
   - `UE4PrereqSetup*`
   - `python*`
   - `zsync*`
   - `renpy.exe`

   DLLs are excluded too, as their own rule. Each rule records a hit for every file it removes.
3. **Engine rules first:** when the engine detector chose an executable for a platform (Ren'Py `<stem>.py` pairing, Unity `<stem>_Data` pairing, Ren'Py `lib/` Linux ELF, Unity `<stem>.x86_64`), that choice wins over general scoring.
4. **Scoring for the rest:** a GUI subsystem wins, then the largest file, then the normalized name as a tiebreak.

**Exclusion tally.** This is public, so the scanner (section 04) can report false exclusions on real data:

```swift
public enum ExclusionRule: String, Sendable, CaseIterable { /* one case per table row, plus dll */ }
public struct ExclusionTally: Sendable, Equatable {
    public private(set) var hits: [ExclusionRule: Int]
    public mutating func add(_ rule: ExclusionRule)
    public mutating func merge(_ other: ExclusionTally)
}
```

- The tally is threaded through `GameDetector.detect(folder:tally:)` as `inout`. There is no global or static counter.
- `detect(folder:)` uses a throwaway tally.
- Rule raw values are pattern codes (for example `"unins"`), never file names.

## As built

The code is in `Sources/EikonCore/Detection/`, the files listed above, plus `ByteReading.swift`, which holds the bounds-checked integer and string reads on `Data`. There are 31 test cases in `DetectionTests.swift`, counting parameterized ones. Deviations from the plan, and choices it left open:

- **`FolderReader` is a `final class`, not a struct.** Budgets are cumulative, so the reader keeps state, and one reader serves one detection pass. It caches `ParsedBinary` per path (`binary(_:)`) and the version-resource strings (`versionStrings`), so each exe is parsed once per pass and section 03's `PEVersionResource.strings` reuses the result. Reads charge the bytes actually read. It opens files with `O_NOFOLLOW | O_NONBLOCK` and refuses anything that isn't a regular file. `text(_:)` reads the first 64 KiB of a larger file.
- **`FolderListing`:** `files(withExtension:)` (regular files only) stands in for `entries(withExtension:)`. `file(named:)`, `directory(named:)` and `file(key:)` look up by normalized key. `normalize` is NFC, then fold, then NFC again, so it is idempotent. Unreadable folders throw `DetectionError.folderUnreadable`.
- **Linux candidates:** only root files whose extension is empty or one of x86_64, x86, x86_32, x64, amd64, bin, elf, aarch64, arm64, arm32, appimage or run are probed for the ELF magic. Data files and `.so` libraries are never read or counted.
- **Exclusions:** name rules apply after the binary parses, so the tally counts only real binaries. Specific rules come before the generic `setup`/`install` ones. Every folder evaluated as a possible root counts, including one that isn't the game.
- **Kirikiri flavor** is resolved in `GameDetector` after main-exe selection. The fallback scan reads `.rdata`, `.data`, then `.rsrc`, within what is left of the versionResource budget.
- **XP3:** before anything is allocated, the declared unpacked size is capped at packed × 1032 (zlib's maximum ratio).
- **Ren'Py:** version files are found through the `game/` and `renpy/` listings. When `__init__.py` holds several `version_tuple`s (the 7.5/8.0 era), the lib layout decides between them: py3-*/python3.* picks major ≥ 8, and otherwise the lowest major wins. The "≤7.3" era is `from 0.0 through 7.3`. Plugin and extension names are de-duplicated by normalized key and sorted by it.
- **`DetectionResult`** encodes `executables` in `GamePlatform.allCases` order. An unknown `RenPyVersionKind` drops the whole `renpyVersion`.

## Done when

- All tests above pass with `make test-core` on the Mac, and in the scheme on the simulator.
- No code path in `Detection/` writes, logs, or puts paths or names into errors.
- `GameDetector`, `FolderListing`, `ExclusionTally`, `PEVersionResource` and all the result types are public, for use by sections 03, 04, 06 and 09.
