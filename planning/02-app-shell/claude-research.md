# Research for split 02 (app shell)

Three research passes: the existing codebase (split 01 as built), engine and architecture detection, and iOS app mechanics (import, crash recording, Metal lifecycle, CRDT-ready settings, storage). Web claims marked **[verify]** rest on thin or community sources and should be checked on a device.

---

## Part A — Codebase as of 0.2.x

### Build and layout
- **XcodeGen** (`project.yml`), not committed `.xcodeproj`. One target, `Eikon` (iOS app), sources `App/` plus the generated `build/generated/Acknowledgements.json` as a resource. `make project` is required (bare `xcodegen generate` fails on purpose). No build-phase scripts.
- **EikonKit** local SwiftPM package (`Packages/EikonKit`): `swift-tools-version:6.0`, `.iOS(.v15)`, Swift 6 language mode (complete strict concurrency). Targets: `CEikonJIT` (C), `EikonKit`, `EikonKitTests`. It imports UIKit, so `swift test` on macOS is not the path.
- `Config/Base.xcconfig`: iOS 15.0 deployment, `SWIFT_VERSION=6.0`, `SWIFT_STRICT_CONCURRENCY=complete`, arm64, devices 1,2, `INFOPLIST_FILE=App/Info.plist`.
- **Makefile**: `doctor bootstrap version generated project check test test-swift test-scripts archive ipa deb package verify all publish fetch-deps verify-deps pin-dep clean`. `generated` writes Version.xcconfig and runs `credits.py app-json`. `test` = `test-swift` + `test-scripts`.
- **Swift tests** run via `scripts/test_swift.sh`: `xcodebuild test` against the newest iPhone simulator (override `EIKON_SIM_DESTINATION`), scheme `Eikon` whose test action runs only `EikonKit/EikonKitTests`, then a launch smoke test (boot, install, launch, check PID). No app test target, no UI tests.
- **Python**: `pyproject.toml` (`eikon-scripts`, Python ≥3.12, no runtime deps, dev dep pytest, `package=false`). All scripts are stdlib-only and run through `uv run`. Tests: `uv run pytest tests/`.
- **CI** (`.github/workflows/ci.yml`): Ubuntu job runs pytest + `deps.py check` + `credits.py check` + `version.sh --check`; macOS job runs `make test-swift archive package verify`. Actions pinned by SHA.

### App target
- Pure **SwiftUI App lifecycle**, no AppDelegate/SceneDelegate. 01's spec: "SwiftUI for app screens. UIKit view controllers will host render and input surfaces in later splits."
- `EikonApp.swift`: `@main`, holds `JITController.shared` as `@ObservedObject`, calls `gatherFacts()` in `init()`, calls `sceneBecameActive()` on `.active` scene phase. Single `WindowGroup { StatusView(controller:) }`.
- `StatusView.swift` (474 lines): stateful wrapper + pure `StatusContent` presentation struct (previews render it). `NavigationView` + `.stack` + `List(.insetGrouped)` — iOS 15 compatible. Exhaustive enum→`LocalizedStringKey` switches with **no `default:`**, so a new case is a compile error. A DEBUG preview iterates every `JITReasonCode` so a missing string key shows as a raw key.
- `ReportExport.swift`: `@MainActor enum ReportExport` (pasteboard copy, temp file) and an `ActivityView: UIViewControllerRepresentable` (ShareLink needs iOS 16).
- **Strings**: single `App/Localizable.strings` (not yet in `en.lproj`; its header says split 09 moves it). Dotted keys (`status.*`, `install.method.*`, `jit.reason.<raw>`, `device.*`, `report.*`). `Text("key")` for UI, `Text(verbatim:)` for data, `localized(_:)` + `String(format:)` with positional `%1$@`.
- **Info.plist** has no document keys: no `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `CFBundleDocumentTypes`, or UT declarations. Custom keys `EKGitCommit`, `EKPackageKind` (rewritten by `package.sh`). Single scene (`UIApplicationSupportsMultipleScenes=false`), all orientations.
- **Entitlements**: `ipa.plist` = `get-task-allow`, `increased-memory-limit`, `extended-virtual-addressing`, `com.apple.private.memorystatus`. `deb.plist` = same + `com.apple.private.security.container-required = com.getboolean.eikon.rootless`. Both sandboxed; **no `no-sandbox`** (it caused a TrollStore SIGKILL at exec). So on every install method the app has a normal data container and cannot read arbitrary paths — import must go through the document picker / Files.

### EikonKit API that 02 consumes
- **JIT** (`JITTypes.swift`): `JITStatus { csDebugged, csDebuggedSeen, txm: TXMInfo, probe: ProbeOutcome, source: JITSource, reason: JITReasonCode? }`, `usable = csDebugged && probe.kind == .passed`. `JITSource`: `none, dopamine, rootlessJailbreak, trollStore, externalEnabler, preexisting, unknown`. `JITReasonCode` (CaseIterable): `dopamineJITOff, rootlessJailbreakNoJIT, trollStoreRequestPending, trollStoreTimedOut, sideloadedNoJIT, txmEnforced, txmUndetermined, probeSkippedAfterCrash, probeFailed, unknownInstallNoJIT, simulator`.
- `JITController` (`@MainActor final class ObservableObject`, `.shared`): `@Published status, installMethod, evidence, isRequestingTrollStoreJIT`; `gatherFacts()`, `sceneBecameActive()`, `retryTrollStoreJIT()`, `retryProbe()`. Full-injection designated init.
- `JITStatusStore.shared.current` — lock-guarded snapshot readable from any thread. **Consumers must tolerate `usable` flipping false→true** (TrollStore relaunch, enabler attaching later).
- `InstallMethod`: `dopamine, rootlessJailbreak, trollStore, trollStoreLite, sideloaded, simulator, unknown` (raw values are wire format and string keys).
- **DeviceReport** (`schemaVersion = 1`): `app, device, os, install, jit, memory, gates: [String: GateResult], notes`. `GateResult { passed: Bool?, detail: String, measuredAt: Date }`. `make(...)` always sets `gates: [:]` — there is no API yet to record or persist gate results on the device. `device-reports/schema.json` already allows arbitrary gate keys (no schema bump needed); 01's plan names future keys `"x18"`, `"guestWindow"`.
- **ProbeSentinel**: `arm()` (O_CREAT|O_TRUNC, write build number, fsync file + dir), `disarm()` (unlink), `consumeAtLaunch()` (true if present with this build; always deletes). Lives in `Library/Caches`. This is the pattern to reuse for game-session crash recording, in Application Support and with a richer payload.
- Other: `AppIdentity { packageKind, bundleIdentifier }` (bundle id read at run time — AltStore/LiveContainer rewrite it), `DeviceSystem` protocol + `LiveDeviceSystem`, `SystemInfo`, `ChipNames` (display only).

### Credits pipeline
- `scripts/credits.py app-json <out>` writes a flat JSON array of `{name, url, revision, license, licenseText}` (sorted keys, UTF-8). `make generated` writes `build/generated/Acknowledgements.json`; it is bundled at the app root and is `[]` today. **Nothing reads it yet.** Eikon's own GPL-3.0-or-later entry is only in `THIRD_PARTY_NOTICES.md`, not in the JSON — the credits screen should show it too (the app can bundle `LICENSE` text or the JSON can gain a first entry).
- `third_party/credits.toml` and `deps.toml` hold only format comments today (no deps yet).

### Conventions to follow
- **Swift Testing** (`import Testing`, free `@Test func` with behavior names, `#expect`/`#require`, `@Test(arguments:)`, `@MainActor async` tests). No `@Suite`. ~20 dense tests in 5 files. Fakes at the top of test files (`@unchecked Sendable` + NSLock, or plain structs). Temp directories for file tests. `DeviceReportTests` walks up from `#filePath` to read `tests/fixtures/` — a cross-language contract pattern.
- **pytest**: plain `def test_<sentence>()`, one-line module docstring, scripts loaded via `importlib` or run as subprocesses, `conftest.py` fixtures build throwaway repos in `tmp_path`. Values derived, not hard-coded.
- **Seams**: each OS surface behind a `Sendable` protocol with a `Live*` struct and `.live` via `extension P where Self == LiveP`. Pure logic in caseless `enum` namespaces with static functions. Singletons built from the full-injection init.
- **Style**: sparse `///` comments that explain *why*; small single-concept files (20–150 lines); models are `Codable, Sendable, Equatable` with explicit public inits; no custom actors; `ObservableObject`, not `@Observable` (iOS 17); `Task.sleep(nanoseconds:)` (iOS 15). Python collects `list[str]` problems ("empty means pass"), atomic writes.
- iOS 15 minimum: no `NavigationStack`, `ShareLink`, `@Observable`.

### Gaps 02 fills
No document/file-sharing plist keys; no `en.lproj`; nothing reads `Acknowledgements.json`; one screen only; no gate-result persistence; no app test target (new testable logic goes in EikonKit or a new package target that the scheme picks up); the scanner follows the `scripts/*.py` + `uv run` + pytest pattern.

---

## Part B — Engine and architecture detection

### Ren'Py
- **Recognize**: `renpy/` dir AND `game/` dir, plus one of `renpy/__init__.py[c|o]`, `*.rpyc`/`*.rpa` in `game/`, or `lib/`. (SteamDB: `(?:^|/)renpy(?:$|/)`, `\.rpyb$`.)
- **Era from `lib/`**: bare `windows-i686`/`linux-x86_64`/`darwin-x86_64` + `pythonlib2.7` → ≤7.3 (6.x/7.x); `py2-*` + `python2.7` → 7.4+; `py3-*` + `python3.9` → 8.0–8.3; `python3.12` → 8.4+.
- **Exact version**, in order: `game/script_version.txt` (Python tuple literal `(7, 4, 11)`, regex `\((\d+),\s*(\d+),\s*(\d+)`; may be absent) → `renpy/vc_version.py` `version = "8.3.4.xxxx"` (8.x; older builds hold only `vc_version = <int>`) → `renpy/__init__.py` `version_tuple = (7, 4, 11, vc_version)` (6.x/7.x) → fall back to lib-dir era. `.rpyc` magic `RENPY RPC2` confirms Ren'Py but carries no version; no header suggests old 6.x.
- **Native extensions**: `lib/<arch>/` native files are the engine's own runtime. Game-supplied native code = any `*.pyd/*.so/*.dll/*.dylib` under `game/` (incl. `game/python-packages/`) or non-stdlib modules in `lib/python*/`. These cannot load on iOS — record them (by file name only) so 10 can decide native vs Wine.
- Main exe: the `.exe` whose stem has a sibling `<stem>.py`.

### Unity
- **Recognize**: `UnityPlayer.{dll,so,dylib}`, or a `*_Data/` folder containing `globalgamemanagers`, `mainData` (old), or `data.unity3d`.
- **IL2CPP vs Mono**: `GameAssembly.dll`/`.so` or `*_Data/il2cpp_data/Metadata/global-metadata.dat` → IL2CPP; else `*_Data/Managed/Assembly-CSharp.dll` (+ `MonoBleedingEdge/`) → Mono.
- **Version** (optional, display/diagnostics): SerializedFile header of `globalgamemanagers` is big-endian; format 9–21 → NUL-terminated version string at 0x14, format ≥22 → at 0x30 (e.g. `2019.4.40f1`). `data.unity3d` starts `UnityFS\0`, u32 BE format, then two NUL-terminated strings (second is the engine revision).
- Main exe: the `.exe` whose stem has a sibling `<stem>_Data/`. Exclude `UnityCrashHandler(32|64).exe`.

### Kirikiri
- **Recognize**: any `*.xp3` (usually `data.xp3`) with the 11-byte magic `58 50 33 0D 0A 20 0A 1A 8B 67 01`. Also an exe with the XP3 magic appended/embedded counts. Plugins: `*.tpm` (PE DLLs with renamed extension) and `plugin/*.dll` (Kirikiri Z).
- **krkr2 vs Z**: search the exe for `TVP(KIRIKIRI) 2` vs `TVP(KIRIKIRI) Z` (ASCII or UTF-16LE). KiriKiri2 is always i386; Z may be amd64.
- **Encryption** (tri-state, useful to 03's hand-off): parse the index at the u64 offset at 0x0B (v2: if u32 at that offset is `0x80`, the real offset is at +9); flag byte 0 raw / 1 zlib. Any `info.flags & 0x80000000` → encrypted-flagged; undecodable index → custom/encrypted. Plugins such as cxdec live in `.tpm`s. 02 records plugin file names; whether native Kirikiri can run it is 03's call.

### GameMaker
- **Recognize**: `data.win` (Windows; also `game.unx` Linux, `game.ios`) starting `FORM` + u32 size + `GEN8` at offset 8 (require both to avoid generic IFF).
- GEN8 body: byte +1 bytecode version; +44..+56 major/minor/release/build (GMS2 always says 2.0.0.0). **YYC** has no or empty `CODE` chunk (walk chunks: 4-char tag + u32 length); **VM** has `CODE`. Some games embed the FORM in the exe.

### BGI / Ethornell
- **Recognize**: `BGI.exe` (often renamed) and/or root `*.arc` whose first 12 bytes are `PackFile    ` (v1) or `BURIKO ARC20` (v2). `.arc` collides with other engines, so require the magic.

### PE
- `MZ`; `e_lfanew` u32 at 0x3C (sanity: < file size, < 0x10000); `PE\0\0`; COFF `Machine` u16 at +4: `0x014C` i386, `0x8664` amd64, `0xAA64` arm64, `0xA641` arm64ec, `0xA64E` arm64x. Characteristics `0x2000` = DLL. Optional-header magic `0x10B` PE32 / `0x20B` PE32+. Subsystem 2 GUI / 3 console. A .NET AnyCPU exe reports i386 with a non-zero CLR directory. Reading the first 4 KiB is enough.

### ELF
- `7F 45 4C 46`; `EI_CLASS` at 4 (1=32, 2=64); `EI_DATA` at 5; `e_machine` u16 at 0x12: 3 i386, 62 x86-64, 183 aarch64. Linux layouts: Unity `<Name>.x86_64` + `UnityPlayer.so` + `<Name>_Data/`; Ren'Py `<Name>.sh` + `lib/py3-linux-x86_64/<Name>` (a `.sh` is not ELF); GameMaker `game.unx`.

### Choosing the main executable
1. Exclude (case-insensitive): `unins\d*`, `UnityCrashHandler*`, `vc_?redist*`, `dxsetup`, `dotnet*`, `ndp*`, `notification_helper`, `crashpad_handler`, `CrashReport*`, `*setup*`, `*install*`, `oalinst`, `UE4PrereqSetup*`, `python(w)?`, `zsync*`, `renpy.exe`; anything under `_CommonRedist/`, `Redist/`, `DirectX/`, `lib/`, `MonoBleedingEdge/`; DLLs.
2. Engine overrides: Unity stem with `<stem>_Data`; Ren'Py stem with `<stem>.py`; Kirikiri exe containing `TVP(KIRIKIRI)`; BGI `BGI.exe` or the sole remaining exe.
3. Boost: GUI subsystem, has version resource. Tie-break: largest size.
The spec keys identity on the main executable **or main archive** (e.g. `data.xp3`), which sidesteps weak exe choice for Kirikiri/GameMaker.

### Hashing for identity
- CryptoKit SHA-256 is ~1–2 GB/s CPU on Apple silicon; I/O dominates (local APFS fast, SMB/Wi-Fi ~50–110 MB/s). Multi-GB `.xp3`/`.assets` full hashes are slow off-device but fast once copied into the container.
- Options: (a) full SHA-256 of the key file; (b) a versioned **sampled fingerprint** (domain tag + scheme version, size, first/last 64 KiB, N evenly spaced 64 KiB chunks; files ≤1 MiB hashed in full). Include size. Version the scheme so it can change.
- Stability: a patched exe changes an exe-keyed identity. Research suggests separating a stable game id from a build id, but the requirements fix the key as "a hash of the main executable or main archive" — decide in the interview which file wins per engine and what happens when the key file changes (re-link vs new game).
- Note: identity must not incorporate folder names (no titles anywhere).

---

## Part C — iOS mechanics

### Import and storage
- Folder pick: `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` / `.fileImporter([.folder])`. Result is security-scoped; balance `start/stopAccessingSecurityScopedResource()`. Persist with plain `bookmarkData()` on iOS (`.withSecurityScope` is macOS-only); on `isStale`, re-bookmark while accessing.
- External (USB/SD/SMB) bookmarks break across reconnects (FAT/exFAT zero serial); iCloud/File Provider files can be evicted placeholders — `mmap`/`pread` on an evicted file can block, fail, or SIGBUS. Referenced folders are only safe on local APFS storage while access is held for the whole session.
- `FileManager.copyItem` clones on the same APFS volume (near-instant), but gives no progress/cancel. For external sources: enumerate and total bytes first, copy file-by-file (`copyfile` with `COPYFILE_CLONE`, or chunked), check cancel between chunks, copy into a staging `.partial` folder then atomic `moveItem`; clean leftover `.partial` at launch.
- Exposing Documents in Files.app needs **both** `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`; the folder appears once it has an item.
- **Recommendation**: copy by default (APFS clone makes on-device copies free); offer reference only for local sources, holding a bookmark, with a reachability check before launch. Store paths **relative** to a container root (container UUID changes on reinstall and differs per install method).
- **Locations**: `Documents/` user-visible and backed up (put the game library here if users drop folders via Files; mark it `isExcludedFromBackup`, re-applied after moves); `Library/Application Support/` private, never purged (library index, settings, diagnostics sentinel, import staging); `Library/Caches/` purgeable (thumbnails, shader caches). All roots from `FileManager.url(for:in:)`.
- **Dopamine deb**: 01 signs with `container-required = com.getboolean.eikon.rootless`, so it gets its own data container **[verify on device via NSHomeDirectory — log it]**. If home ever resolves to `/var/mobile`, fall back to an app-specific subfolder rather than colliding with `/var/mobile/Documents`.

### Crash recording (games run in-process)
- **MetricKit** crash diagnostics likely are not delivered to sideloaded/TrollStore/jailbreak installs **[verify]**; don't depend on it.
- **Jetsam/watchdog** kills are SIGKILL: no handler runs; detect by elimination on next launch.
- **Signal handlers vs. emulators**: FEX, Wine and friends take SIGSEGV/SIGBUS for expected faults (fastmem, SMC, guard pages), so a naive first-fault handler gives false positives. Mach exception ports conflict with JIT runtimes and debuggers (PLCrashReporter warns explicitly); avoid them. If a handler is used: async-signal-safe only (`write` to a pre-opened fd, then restore `SIG_DFL` and re-raise), `sigaltstack` + `SA_ONSTACK`, and chain correctly with the emulator's handler — or have runtimes expose an "unhandled fault" hook.
- **Minimal robust design**: a session sentinel in Application Support written and fsynced before entering the game, `{session id, game hash, route, build, started at, phase}`; phase updated `running`↔`background`; deleted on clean stop. Next launch: sentinel `running` + signal record → crash; `running` without record → likely jetsam/watchdog or a crash swallowed by the runtime; `background` → background kill (normal, low severity). Plus a small breadcrumb ring log (lifecycle events, memory warnings) through a pre-opened fd. This generalizes `ProbeSentinel`.

### Game session host and Metal lifecycle
- iOS rejects GPU submissions from the background ("Insufficient Permission (to submit GPU work from background)"). Stop new work on resign-active; by did-enter-background the render thread must be stopped and the last command buffer `waitUntilScheduled()`. Gate every `commit()` on an atomic "may render" flag, because notifications arrive on main while runtimes render on their own threads. `beginBackgroundTask` if the flush may take time.
- Observe **scene** notifications for the host view's `windowScene`, not app-wide ones. Pause on `willDeactivate`; resume only on `didActivate` (optionally behind a "tap to resume").
- Audio: `AVAudioSession.interruptionNotification` (pause on `.began`, check `.shouldResume` on `.ended`), route changes (headphones unplugged → pause), media-services reset.
- Present the game as a **fullscreen UIKit view controller** (`modalPresentationStyle = .fullScreen` from the root). A presented fullscreen VC controls `prefersHomeIndicatorAutoHidden`, `prefersStatusBarHidden`, `preferredScreenEdgesDeferringSystemGestures`; embedded via `UIViewControllerRepresentable` inside SwiftUI navigation, these are ignored unless the root hosting controller forwards `childFor…`. Deferring edges only requires a double swipe; it can't block the home gesture.

### CRDT-ready settings
- Per-field **LWW register** `(value, timestamp, replica id)`; merge keeps the larger `(timestamp, replica)`; ties broken by replica id so every device converges.
- Use a **hybrid logical clock** `(wall ms, counter, replica)` so a clock set backwards cannot lose writes.
- **Shape**: sparse map keyed by stable dotted field names; missing key = default; decode values as a JSON-value enum so unknown fields round-trip untouched (older app versions don't drop newer keys); typed accessors decode lazily and fall back to default. **Reset** is a write (tombstone `{v:null, reset:true}` with a fresh timestamp), not a delete. Put a `format` version in the file; treat unknown future formats as read-only. Enum values as strings.
- **Sync-ready layout**: one file per replica (`settings/<replica>.json`), written only by that device; effective state = fold over all replica files. That is exactly what 12 needs on WebDAV (no locking). Replica id = UUID stored once in Application Support.
- Libraries: automerge-swift (Rust core, opaque binary — heavy and awkward over WebDAV); heckj/CRDT (single release). A hand-rolled LWW map is ~150 lines and keeps the on-disk format under control — recommended.

## Sources (selected)
Ren'Py build/distribute docs and source (`distribute.rpy`, `script.py`, `versions.py`, `__init__.py`), SteamDB FileDetectionRuleSets `rules.ini`, AssetStudio `SerializedFile.cs`, UnityPack format docs, Unity IL2CPP manual, ArchiveTeam XP3, GARbro `ArcXP3.cs`, krkrz `tvpwin32.rc`, UndertaleModTool `UndertaleGeneralInfo.cs`, arc-reader `arc.c`, Microsoft PE format, elf(5), Eclectic Light (CryptoKit throughput), Apple Developer Forums 766646/131670/773373/104356/765329/76818/682320, Apple "Preparing your Metal app to run in the background", PLCrashReporter `PLCrashReporterConfig.h`, Sentry watchdog/OOM docs, Imfeld "CRDTs for Mortals", TrollStore README, Theos rootless docs.

---

## Part D — How other launchers identify games (added 2026-09-28, after the owner questioned folder-name identity)

| Tool | Identity key | Rename | Patch | Cross-device | Prompts |
|---|---|---|---|---|---|
| JoiPlay | library record → exe path (optional `game.cfg` id in folder) | breaks entry | survives | none | pick exe |
| Winlator | container + `.desktop` shortcut (exe path) | breaks | survives | none | manual |
| Lutris | `slug-timestamp` + pga.db; path is a field | survives (edit path) | survives | none | installer/manual |
| Heroic sideload / Bottles | random id / UUID; path is a field | survives (edit path) | survives | none | manual |
| Whisky | pinned path | breaks | survives | none | manual |
| Playnite / LaunchBox | per-entry GUID; DB match by id → filename → title | survives entry | survives | via DB id only | import |
| Dolphin / RPCS3 | disc GameID / TitleID | free | revisions handled | exact | none |
| PCSX2 | serial + CRC | free | CRC change drops config | exact | none |
| RetroArch | content filename | breaks | survives if same name | same filename only | none |
| Delta / Provenance (iOS) | ROM SHA-1 / MD5; sync paths are hashes only | free | patched ROM = new game | exact | none |
| Steam non-Steam shortcut | crc32(exe path + name) | breaks | survives | none | manual |
| Ludusavi | PCGamingWiki title (+ mapping.yaml) | fuzzy re-match | survives | title + manual redirects | config |
| GOG | `goggame-<id>` marker file in the folder | free | survives unless wiped | exact | none |

**Dominant patterns:**
- **A. Opaque local id + mutable path** (Playnite, Heroic, Bottles, Lutris).
  - Rename and patch don't matter to the record.
  - A moved folder shows as "missing" until relinked.
  - There is no cross-device match.
  - A copied folder becomes an unrelated duplicate.
- **B. Content-intrinsic key** (disc ids, ROM hashes, and engine-declared ids).
  - Rename, move and cross-device matching are free, with no prompts.
  - A whole-file hash changes on a patch.
  - Header or engine ids can collide.
  - Engine-declared ids include Ren'Py `config.save_directory`, Unity `companyName/productName`, and the GameMaker game name. Engines choose these so saves survive renames and patches.
- **C. Name- or path-derived key** (RetroArch filename, Steam crc(exe + name), Ludusavi title).
  - Every rename orphans data.
  - This is the folder-name design the owner rejected.
- **D. Marker file in the folder** (GOG, JoiPlay `game.cfg`).
  - Rename-proof.
  - Fails on read-only media.
  - Copying the folder duplicates the id.
  - Re-extracting a patch wipes it.

**Recommendation from the research:**
- **Identity:** an opaque random game id (UUID) owned by Eikon, located by a content fingerprint.
- **Fingerprint:** an engine-declared id (primary, survives patches) plus a structural signal: the top-level listing with sizes, and a partial hash of the main exe or archive.
- **Privacy:** fingerprints sync only as HMAC(user secret, signal), so the server sees opaque values while the user's devices compute equal ones.
- **Silent matching:**
  - known path → same game
  - unknown folder whose engine id and structure match an entry with no live path on this device → attach (rename, move, second device)
  - engine id matches with changed structure and exactly one candidate → attach (patch)
  - otherwise → new game
- **When to ask:** only on real ambiguity, such as a copied folder (two live folders match one entry) or several candidates. Even then the default is non-destructive: the folder at the recorded path keeps the id, and the other forks.
- **Failure mode:** a duplicate entry, never cross-wired saves.

Sources: joiplay/rga, Winlator101 shortcuts docs, Lutris config docs, Heroic issue 3757, Bottles issue 1335, Whisky issue 830, Playnite API docs, LaunchBox import docs, Dolphin GameINI wiki, RPCS3 FAQ, libretro overrides docs, Delta sync layout, Steam shortcut docs, Ren'Py issue 4186, GOG forum (goggame markers), Ludusavi backup-structure docs.
