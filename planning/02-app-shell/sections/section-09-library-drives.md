# Section 09: Game drives and the library

## Summary

This section builds the game-drive library. It covers:

- **Models** in `EikonCore/Library`: `GameDrive`, `DriveKind`, `DriveState`, `VolumeKind`, `GameLocation` with its `IdentityState`, and `LibraryIndex`. The index is the local-only pair of files `drives.json` and `locations.json`.
- **`FolderAccess`** (the protocol and `AccessToken`) in EikonCore, and `LiveFolderAccess` in EikonKit.
- **In EikonKit:** `DriveManager` (add, remove and re-link drives), `DriveScanner` (diffing, quiescence, re-detection, and a serial fingerprint worker), `ImportCoordinator` (copying a game into a drive) and `LibraryController` (the `@MainActor ObservableObject` the UI binds to).
- **The remove-game flow**, with the `GameDataCleanup` and `GameDataMerge` hook protocols and their registries.
- **`Info.plist` file-sharing keys**, so that `Documents/` becomes the built-in game drive, shown in Files as "On My iPad/Eikon" or "On My iPhone/Eikon".

No UI is built here. `LibraryView`, `DrivesView`, `ImportFlow` and `RemoveGameDialog` belong to section 13, which binds to the controller API defined here.

## Dependencies

These must already be in place. Use their APIs; do not re-implement them.

- **section-01-core-package.** Provides the `Packages/EikonCore` package, the EikonKit → EikonCore dependency, the test targets and the shared `Persisted` rules (§6.2 below): the format header, the rule that a future-format file is read-only, tolerant per-element decoding that keeps raw bad elements, and atomic write + fsync.
- **section-02-detection.** Provides `GameDetector.detect(folder:) -> DetectionResult?`, `DetectionResult` (including `detectorVersion` and `keyFile`), `Engine`, `FolderListing`, and the test `Fixtures.swift` that synthesizes fake game folders.
- **section-03-identity.** Provides `GameID`, `Fingerprint`, `Keyed`, `NameNormalizer`, `FingerprintBuilder` (HMAC under the library secret: `build` is a full content hash with progress and cancellation; `engineID` is a few small reads; `contentStamp` is a cheap recursive stat digest), the pure `IdentityMatcher` (`quickMatch`: known location and engine id; `match`: known location, exact, engine id; file names never match), and the merge/split logic with `merged/` link resolution.
- **section-05-settings-store.** Provides `SettingsStore` with its per-game keys: `displayName`, `route.override`, `deletedAt` and fingerprints under `fp/<scheme>/<exact>`. It also provides `removeAll(game:)` (which writes `deletedAt`), `fingerprints(game:)` (oldest first, as `KnownGame.fingerprints` expects), `addFingerprint(_:game:)`, `removeFingerprint(_:game:)` (all matching on `exact`), `mergeLinks()` and the global `merged/<uuid>` key.
- **section-06-route-picker.** Provides `RoutePicker.decide(detection:environment:override:)`, `RouteDecision`, `RouteEnvironment` and `RouteID`.

Things this section does **not** depend on, but must leave room for:

- **Section 08's `GateStore`** and **section 10's `RuntimeRegistry` and `GameSession`.** `LibraryController` must not import them directly. It takes an injected route-environment provider and exposes suspend/resume entry points (details below). The app wires these together (section 12).
- **Section 12's `EikonApp.init`.** It calls this section's startup entry points in a fixed order (see "Startup and wiring").

## Background

Eikon is an iOS 15+ iPhone/iPad app, built in Swift 6 language mode with complete concurrency checking. Both builds are sandboxed. It will run Windows and Linux x86 games and native Kirikiri and Ren'Py games in-process.

- **Where games live.** Games sit flat inside **game drives**, which are folders on the device or on a USB drive.
  - The built-in drive is the app's own `Documents/`.
  - Each game is an immediate subfolder of a drive, or sits inside a single wrapper folder there. Detection already handles the wrapper.
  - Flat folders make folder names unique per drive.
- **Import copies** a game folder into a drive the user picks. Every drive is scanned automatically.
- **Game ids.** Settings, saves and other per-game data key on a random **game id**. A game is found again through a content **fingerprint**, which is stored only as HMACs.
  - Rule 1 of the matcher is "same drive + same folder name + already has a game id → keep the id, whatever changed inside". That is how an in-place patch keeps the game's identity.

Constraints that apply here:

- **No program titles anywhere.** Nothing may reach logs, reports, breadcrumbs or test assertions that print names.
  - Folder names and display names count as titles. They stay in the local library index and settings only, and are never logged or exported.
- **Test content is original.** Tests synthesize tiny fake game folders in temp directories using the section-02 fixtures. Names are generic (`Game.exe`, `Sample_Data`, `data.xp3`).
- **iOS 15 minimum.** No `@Observable`, no Swift `Atomic`/`Mutex`, no `OSAllocatedUnfairLock`. Use `ObservableObject` and `NSLock`-style locks.
- **01's style.**
  - Small single-concept files.
  - `Sendable` protocol seams with a `Live*` type and a `.live` accessor.
  - Pure logic in caseless enums.
  - Exhaustive enum switches with no `default:`.
- **Security-scoped URLs.** Anything outside the container is reached only through security-scoped URLs from the document picker.
- **Tests are few and behavioral.** They must not assert constants, exact strings, file contents or internal structure (the owner's standing rule).

## Tests first

### EikonCoreTests: library index persistence

File: `Packages/EikonCore/Tests/EikonCoreTests/LibraryIndexTests.swift`

The generic `Persisted` rules (a newer-format file is never rewritten; a malformed element is dropped from the view but kept on save) are already tested in section 01. Add only the library-specific behavior:

- Test: a location persisted mid-fingerprinting (an in-progress identity state) loads as `pending`.
- Test: a `locations.json` holding one malformed location still loads the others. After a save, the malformed element is still in the file. This is a quick check that `LibraryIndex` really uses the `Persisted` tolerant-collection path.

### EikonKitTests: drives, scanning, import

File: `Packages/EikonKit/Tests/EikonKitTests/LibraryTests.swift`, with its fakes at the top of the file:

- A fake `FolderAccess`. It maps bookmark `Data` to temp-dir URLs, and each bookmark can be scripted to return `.opened`, `.notConnected` or `.stale`, with a scripted `VolumeKind` per URL.
- An injected clock.
- A fake `GameDataCleanup` hook that counts its calls.

Drives are temp directories. Game folders come from section 02's `Fixtures`.

**Drives**

- Test: adding a drive refuses ubiquitous and network volumes (and unknown ones), and accepts external-local and internal ones.
- Test: a drive whose bookmark reports "not connected" makes its games unreachable, and their launch state reports that.
- Test: re-linking a drive to a folder that contains none of its known folder names asks for confirmation. A folder that contains them relinks silently.

**Scanning**

- Test: the scanner ignores dot folders, including an in-progress `.eikon-importing-*`, and ignores `Inbox` on the built-in drive.
- Test: a new subfolder becomes a location. A vanished one becomes missing, and is not deleted.
- Test: a folder whose contents keep changing, including files below the top level, gets no game id or fingerprint until two scans at least the quiescence interval apart see the same content stamp. Use the injected clock.
- Test: a fingerprint whose content stamp changed while it was being built is discarded and recomputed.
- Test: a location with a previous `unknown` or `nil` detection is re-detected on the next scan after its listing changes.

**Import**

- Test: an import lands at `<drive>/<name>`, never produces a duplicate location (even after a rescan), and leaves the source unchanged.
- Test: an import onto an existing name offers replace or rename. *Replace* keeps the existing game id and its settings, which is how an update arrives through import.
- Test: a cancelled or failed import leaves no staging folder and no partial game folder.
- Test: a leftover staging folder from an earlier run is removed at startup.
- Test: an import that needs more space than is free is refused before copying. Inject the free-space reading.
- Test: a symlink inside the source is not followed out of the source tree.

**Identity across drives**

- Test: copying a patch over a game's files on a drive, then rescanning, keeps the game's id and settings, re-runs detection and records a new fingerprint. A patch here replaces a file below the top level at the same size, plus a new file.
- Test: a newly quiescent game gets a game id (from `quickMatch`) before its full fingerprint is done, and its settings are editable then.
- Test: a provisional game with no user settings whose full fingerprint exact-matches another game is merged into it silently; one with settings gets a suggestion instead.
- Test: renaming a game folder on a drive, or moving it to another drive, keeps its game id.
- Test: the same game (an exact match) on two drives shows as one game with two locations.
- Test: a second, different version of a game that is already present (same engine id, different contents, while the first is live) appears as a new game with a suggestion. Merging it moves its location under the first game.

### EikonKitTests: fingerprint worker

- Test: while a session is marked active, fingerprinting makes no progress. It resumes after the session ends.
- Test: the viewed location is processed before the other queued ones.

### EikonKitTests: remove

- Test: removing with "delete settings and saves" makes all of the game's settings read as unset, calls the registered cleanup hooks once, and leaves other games untouched.
- Test: deleting files removes only the checked locations' folders, never a folder on another drive.

Keep assertions behavioral: ids equal or differ, a location exists or is missing, a folder exists or not, a hook was called once. Never assert exact strings, sizes or file contents.

## Implementation

### Files

EikonCore (platform-neutral, no UIKit):

```
Packages/EikonCore/Sources/EikonCore/Library/
  GameDrive.swift        # GameDrive, DriveKind, DriveState, VolumeKind
  GameLocation.swift     # GameLocation, IdentityState, LocationSeen
  LibraryIndex.swift     # drives.json + locations.json via Persisted
  FolderAccess.swift     # FolderAccess protocol, AccessOutcome, AccessToken
```

(`Persisted.swift` already exists in the same folder from section 01.)

EikonKit:

```
Packages/EikonKit/Sources/EikonKit/Library/
  LibraryController.swift
  DriveManager.swift
  DriveScanner.swift
  ImportCoordinator.swift
  LiveFolderAccess.swift
Packages/EikonKit/Sources/EikonKit/Runtime/
  GameDataCleanup.swift  # GameDataCleanup + GameDataMerge protocols and registries
```

App: `App/Info.plist`.

### Storage locations (§6.1)

Resolve every root from `FileManager.url(for:in:)`. Never store an absolute container path.

- **`Documents/`** is the built-in game drive.
  - Its immediate subfolders are games.
  - `Inbox` and names starting with `.` are ignored.
  - It is excluded from backup (`isExcludedFromBackup`). Re-apply the flag at every launch.
- **`Library/Application Support/Eikon/`** holds `drives.json` and `locations.json`. This is the library index, and it is local only.
  - The same directory also holds `library-secret` (section 03) and `settings/` (section 05). This section reads the secret through section 03's API.

### Persisted-file rules (§6.2, applied here)

`drives.json` and `locations.json` follow the shared `Persisted` rules from section 01:

- Each file carries a `format` integer.
- Writes are atomic (temp file, then rename and fsync).
- A newer `format` makes the file read-only: it is loaded as far as possible and never rewritten.
- Collections decode per element. A bad element is dropped from the in-memory view, but its raw form is kept and written back unchanged.
- **Library-specific rule:** a persisted in-progress fingerprinting state loads as `pending`.

### Models (§6.3)

```swift
public struct GameDrive: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: DriveKind          // .builtIn / .folder(bookmark: Data)
    public var label: String            // user-visible, device-local (volume or folder name)
}
public enum DriveState: Sendable { case available, notConnected, needsRelink }
public enum VolumeKind: Sendable { case `internal`, externalLocal, ubiquitous, network, unknown }

public struct GameLocation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var driveID: UUID
    public var folderName: String        // device-local only; never logged or exported
    public var detection: DetectionResult?          // cache
    public var fingerprint: Fingerprint?            // latest; nil until computed
    public var gameID: GameID?           // nil only until the first match runs
    public var identity: IdentityState   // pending / waitingForQuiescence / fingerprinting / identified / failed(code) / missing
    public var lastSeen: LocationSeen    // content stamp + top-level listing digest + when seen, for re-detect/quiescence
    public var fingerprintedStamp: String? // the content stamp the current fingerprint was built from
    public var lastUsedAt: Date?         // launch-location preference
    public var suggestion: [GameID]      // non-blocking "same game as…?" candidates
    public var dismissedSuggestions: [GameID]
}
```

- **Enum decoding.** `IdentityState` and `DriveKind` decode unknown future values to a safe fallback (`pending`), in line with the enum-fallback rule used everywhere. `fingerprinting` decodes as `pending`.
- **`failed(code)`** carries an app-defined code, never a path or name.
- **The library the UI shows** is a list of **games**, grouped by *resolved* game id (following `merged/` links, via section 03). Each game has one or more locations.
- **Launch location.** Launch uses a reachable location, preferring the built-in drive, then the most recently used (`lastUsedAt`). If none is reachable, the game's launch state reports "drive not connected".
- **Missing locations.** A location whose folder vanished while its drive is available is *missing*. It is shown on the game and can be removed, but it is never deleted automatically.
- **Games with no locations** are hidden. Their settings remain.

### Folder access (§6.4)

```swift
public enum AccessOutcome: Sendable {
    case opened(AccessToken, refreshedBookmark: Data?)
    case notConnected
    case stale
}

public protocol FolderAccess: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func open(bookmark: Data) throws -> AccessOutcome
    func volumeKind(of url: URL) -> VolumeKind
}

public final class AccessToken: @unchecked Sendable {
    public let url: URL
    public init(url: URL, onClose: @escaping @Sendable () -> Void)
    public func close()          // idempotent (lock-guarded flag); deinit closes as a backstop
}
```

`LiveFolderAccess` (EikonKit), with a `.live` accessor:

- **`makeBookmark`** uses `url.bookmarkData()`.
- **`open`**
  - Resolves with `URL(resolvingBookmarkData:bookmarkDataIsStale:)` and starts security-scoped access.
  - If the bookmark is stale but resolvable, it re-bookmarks while it has access and returns the refreshed bookmark.
  - If resolution fails because the volume is absent, it returns `.notConnected`. If the bookmark is stale and can't be resolved, it returns `.stale`.
  - The token's `onClose` stops security-scoped access.
- **`volumeKind`** reads the resource values `volumeIsInternal`, `volumeIsLocal` and `isUbiquitousItem`:
  - ubiquitous → `.ubiquitous`
  - not local → `.network`
  - internal → `.internal`
  - local but not internal → `.externalLocal`
  - unreadable → `.unknown`
- **The built-in drive** needs no bookmark. It opens as a no-op token over `Documents/`.

### Drives (`DriveManager`, §6.5)

- **Add a drive** from a URL chosen with `.fileImporter(allowedContentTypes: [.folder])`. The UI is section 13.
  - Accepted: `.externalLocal` (USB-C SSD, SD card) and `.internal` locations (for example a folder in On My iPad).
  - Refused: `.ubiquitous` (iCloud Drive), `.network` (SMB) and `.unknown`. Each refusal returns a distinct refusal code that the UI maps to a one-line reason. Evictable or network files are unsafe under an in-process emulator.
  - On acceptance, store the bookmark with the folder or volume name as the label, persist, and scan the drive.
- **Drive states** are re-evaluated at launch, on scene activation and before launching a game.
  - `available`: the bookmark resolves and opens.
  - `notConnected`: the volume is absent.
  - `needsRelink`: the bookmark is stale and can't be resolved.
  - When `open` returns a refreshed bookmark, persist it.
- **Re-link** ("Find folder…") takes a newly picked URL.
  - If the new folder contains none of the drive's known location folder names (compared normalized, via `NameNormalizer`), return a "needs confirmation" result. Only a confirmed call commits.
  - If it contains at least one known name, relink silently.
  - Either way, keep the drive's `id`, so its locations stay attached.
- **Remove a drive** removes only the drive record and its locations from the index. The files on it are untouched, and the settings stay.
- **The built-in drive** can't be removed and is always `available`.
- **During a session** the host holds the drive's access token. Unplugging mid-game can crash the app. That is an accepted risk, and the session sentinel (a different section) reports it on the next launch.

### Scanning (`DriveScanner`, §6.6)

For each available drive, at launch and on scene activation, the scanner diffs the drive's immediate subfolders against its locations:

- **Skipped folders:** names starting with `.` (including `.eikon-importing-*` staging folders) and `Inbox` on the built-in drive.
- **New folder:** create a location with `identity = .pending` and run detection (`GameDetector.detect`).
  - A `nil` result is kept as a location with no detection. The UI lists these under "Not recognized".
- **Changed folder:** run detection again when any of these hold:
  - the folder's mtime changed
  - the top-level listing digest changed
  - the content stamp (`FingerprintBuilder.contentStamp`) changed
  - the last detection was `nil` or `unknown`
  - the stored `detectorVersion` is older than the current one (detection is a cache)
- **Quiescence.** Matching and fingerprinting start only after the same **content stamp** (every file's path, size and mtime, at every depth, with the fingerprint's exclusions) has been seen on two scans at least 10 seconds apart. A top-level check isn't enough: a copy lays down top-level entries early while deep files are still arriving. Take the time from an injected clock. The stamp is cheap (stat only), but walking a huge tree still takes a moment, so compute it off the main actor.
  - Until then the location is `waitingForQuiescence` ("Waiting for copy to finish…").
  - This covers folders still being copied in, and patches being copied over a game.
- **Changed contents at a known location** (for example a patch copied over the files, at any depth): the content stamp differs from `fingerprintedStamp`. The location keeps its game id (matcher rule 1). Once quiescent, the new fingerprint is computed and added to the game (`addFingerprint`), and the game is re-detected, which may change its route.
- **Vanished folder:** the location becomes `missing`. Never delete it automatically.
- **Threading.** Scans run off the main actor and publish results on it. Scans are **suspended while a game session is active**.

**Identity in two passes.** The full hash can take minutes, and a game's settings and Launch wait on its id, so the id comes first:

1. **Quick pass**, as soon as a location is quiescent: `FingerprintBuilder.engineID` (a few small reads), then `IdentityMatcher.quickMatch` (known location, then engine id). The location gets its game id at once: kept, attached, or newly minted (**provisional** until the full pass confirms it).
2. **Full pass**, on the fingerprint worker below: `FingerprintBuilder.build`, then `IdentityMatcher.match`.
   - It agrees with the quick pass (same game): add the fingerprint.
   - It exact-matches a different game: the folder is a copy of that game. If the provisional game has no user data yet (no settings besides fingerprints), merge it into that game silently (`merged/` link, locations move). Otherwise keep it and set a suggestion naming that game.
   - Suggestions from either pass follow the usual rules (`dismissedSuggestions`).

**Fingerprint worker.** One serial background worker (a single task, or an actor draining a queue):

- It takes quiescent locations from a queue. The **currently viewed** location, set by the controller, jumps to the front.
- It records the content stamp before hashing and checks it again afterwards. If the stamp changed, the result is discarded and the location waits for quiescence again. Otherwise it stores the stamp as `fingerprintedStamp`.
- For each location, it opens the drive's access token, runs `FingerprintBuilder` on the detected game root, closes the token, then runs `IdentityMatcher` against:
  - **Note from section 03:** `FingerprintBuilder.build` hashes every file of the game (saves excluded), which can take minutes. Pass its `progress` to the location's UI state and an `isCancelled` that trips on `suspendBackgroundWork()` or removal; a cancelled location goes back on the queue and restarts later.
  - this device's locations
  - every known game's stored fingerprints from `SettingsStore`, excluding games with `deletedAt`
- It applies the match result:
  - assign or mint a `GameID`
  - add the fingerprint to the game (capped at 8, most recent kept; this is the store's job)
  - set `suggestion` for non-blocking candidates, minus any in `dismissedSuggestions`
- A read failure marks the location `failed(code)`, which the UI offers to retry with "Retry" (`retryFingerprint`).
- **Pausing.** The worker **pauses while a session is active**: it doesn't start new work and waits at a checkpoint between locations. It resumes afterwards.
  - Expose this as `suspendBackgroundWork()` / `resumeBackgroundWork()` on `LibraryController`, which forwards to both the scanner and the worker. Section 10's `GameSession` calls these.

### Import (`ImportCoordinator`, §6.7)

An `async` API with progress reporting (throttled, published on the main actor) and cancellation.

1. **Pick the game.** The source URL is security-scoped. Hold access for the whole import. Run `GameDetector.detect` on it. With no game found, return a "no game found" result and stop.
2. **Pick the drive.** Provide the available drives with their free space, and the copy's total size. The built-in drive is the default. The UI states that files are copied and the original is unchanged (section 13).
3. **Name check.** If the target drive already has a folder with the same normalized name, return a clash result. The caller then chooses:
   - *Replace existing copy*
   - *Import with another name…*, whose new name must normalize differently from every existing folder
   - *Cancel*
4. **Space check.** Use `volumeAvailableCapacityForImportantUsage` on internal drives and `volumeAvailableCapacity` on external ones, with a safety margin. If there isn't enough space, refuse **before** copying. Make the free-space reading injectable for tests.
5. **Copy.**
   - Copy into `<drive>/.eikon-importing-<uuid>/<name>`. Enumerate and total first, then copy file by file with clone-capable APIs (`FileManager.copyItem` clones on the same APFS volume), so same-volume copies are near-instant.
   - Check for cancellation between files and between chunks of large files. Throttle progress.
   - **Never follow symlinks.** A symlink is either skipped or recreated as a link. It must never be dereferenced out of the source tree.
   - Read from file-provider sources with `NSFileCoordinator` coordinated reading, so placeholders are downloaded first.
   - Run the work inside `UIApplication.beginBackgroundTask`.
   - On cancel or failure, delete the staging folder.
6. **Commit.**
   - For a new name, rename the staging folder's content to `<drive>/<name>`. This is atomic on the same volume. Then remove the staging folder.
   - For *Replace existing copy*, use `FileManager.replaceItemAt`, so a failure never leaves neither copy.
   - **Register the location in the index before the scanner can see the folder**, so the scanner never creates a duplicate.
7. **Settle.** Detection, fingerprinting and matching run as usual.
   - *Replace existing copy* keeps the existing location record, and with it the game id (matcher rule 1). That is how an update installed through Import stays the same game.

**Stale staging cleanup.** Provide `cleanStaleStaging()`. It deletes every `.eikon-importing-*` folder on each available drive. It is called at startup: if the app was suspended or killed mid-import, the leftover is removed, and the user restarts the import.

### `LibraryController` (§6.8)

`@MainActor final class LibraryController: ObservableObject`.

**Published state:**

- drives, with their `DriveState`, label, free space and game count
- games, grouped by resolved game id, each with:
  - its locations
  - an aggregate status (identifying / waiting for copy / suggestion / drive not connected / missing / fingerprinting failed)
  - its suggestions
  - its display name. This is the `displayName` setting, or else the first location's folder name. It is used on screen only.
- locations with no game found (for the "Not recognized" list)
- each game's current `RouteDecision`

**Entry points:**

- `addDrive(_ url:)`, `relinkDrive(_:to:confirmed:)`, `removeDrive(_:)`
- `importGame(from:to:name:)` plus cancel. The name-clash choice is passed in.
- `rescan()`, `reevaluateDriveStates()`
- `merge(_:into:)`, `split(location:)`, `dismissSuggestion(_:on:)`
- `remove(game:deleteLocations:deleteData:)`
- `retryFingerprint(_:)`
- `setViewedLocation(_:)`, which gives that location worker priority
- `suspendBackgroundWork()`, `resumeBackgroundWork()`
- `launchLocation(for:)`, which returns a reachable location or a "not connected" / "missing" state

**Merge and split** delegate to section 03's logic over the settings store.

- **Merge** writes `merged/<A>` = B, copies A's settings into B where B has none, moves the fingerprints, points A's locations at B, and runs every registered `GameDataMerge` hook.
- **Split** mints a new id, forks the settings, and moves that location's fingerprint.
- Persist the index afterwards.

**Route recomputation.** The controller takes an injected provider:

```swift
@MainActor public protocol RouteEnvironmentSource: AnyObject {
    func environment(for game: GameID, detection: DetectionResult) async -> RouteEnvironment
}
```

The app implements it from JIT status, `GateStore.states()`, `RuntimeRegistry.builtRoutes` and cached runtime checks.

- Recompute decisions when any of these change: JIT usability, gates, `route.override`, the runtime registry, or cached runtime checks. The controller exposes `invalidateRoutes()` for the app to call.
- For each game, call `RoutePicker.decide` with its detection and override.
- A missing environment source means no built routes, so every route is `planned`.

### Remove a game (§6.9)

`remove(game:deleteLocations:deleteData:)` takes two independent choices:

1. **Delete game files** for the chosen locations. Only locations on **available** drives can be deleted. Delete exactly those folders and nothing else. The UI shows sizes and notes the drives that aren't connected.
2. **Delete settings and saves (on all devices).**
   - Call `SettingsStore.removeAll(game:)`, which writes `game/<id>/deletedAt`. That shadows every older key under the game's prefix, including keys this device never saw.
   - Run each registered `GameDataCleanup` hook locally, once.

With neither choice selected, the game's locations are forgotten from the index. A location whose files remain will reappear on the next scan. The dialog (section 13) says so.

`GameDataCleanup.swift` (EikonKit/Runtime):

```swift
public protocol GameDataCleanup: Sendable {
    /// Delete route-owned data (saves etc.) for a game. Called once per removal on this device.
    func removeData(for game: GameID) async
}
public protocol GameDataMerge: Sendable {
    /// Move route-owned data from one game id to another after a merge.
    func mergeData(from: GameID, into: GameID) async
}
```

Also provide a registry for each protocol (`GameDataHooks`, `@MainActor`, with `register` and `all`). In 02 nothing is registered. Save-owning routes (03, 08, 10) register hooks later, and split 12 runs the cleanup hooks on other devices.

### `SettingsController` (§7.3)

Section 05 builds only the EikonCore `SettingsStore`. This section adds its EikonKit face, `Packages/EikonKit/Sources/EikonKit/Settings/SettingsController.swift`: a `@MainActor final class SettingsController: ObservableObject` over one `SettingsStore`.

- It exposes typed reads and writes for the 02 keys (`displayName`, `route.override`) and publishes a change so views and `LibraryController` refresh. `LibraryController` recomputes route decisions when `route.override` changes.
- Display-name edits commit on submit, not on every keystroke. The view (section 13) holds the draft and calls the controller once.
- A location's settings are read-only in the UI until the location has a game id. The quick identity pass gives one right after the folder is quiescent, without waiting for the full hash.
- `flush()` passes through to the store. `EikonApp` calls it on scene background, and `GameSession` (section 10) calls it before a session starts.
- It exposes the store's `replicaID` and `forkedFrom` for the Developer section (section 14).
- No automated test of its own. The store's behavior is covered by section 05's tests.

### `Info.plist` (§13)

Add to `App/Info.plist`:

- `UIFileSharingEnabled` = `YES`
- `LSSupportsOpeningDocumentsInPlace` = `YES`

With both set, Files shows `Documents/` as "On My iPad/Eikon". Entitlements are unchanged. Section 01's artifact verifier must still pass.

### Startup and wiring (called by section 12)

`EikonApp.init` (section 12) creates `LibraryController` after `SettingsController`/`GateStore`, then:

- `cleanStaleStaging()` on available drives
- starts the scans

On scene `.active` the app calls `reevaluateDriveStates()` and `rescan()`. Also re-apply the backup-exclusion flag on `Documents/` at launch.

### Privacy checklist for this section

- Never log `folderName`, drive labels, display names or plain fingerprint signals. Log codes and counts only.
- Failure codes are app-defined enums.
- Tests print no folder names in assertion messages beyond the generic fixture names.
